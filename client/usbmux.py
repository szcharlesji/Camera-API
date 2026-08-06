"""Speak Apple's usbmux protocol directly, with nothing but the standard library.

`usbmuxd` — the daemon that multiplexes TCP connections to an attached iOS device
over USB — ships in every distro's `usbmuxd` package and runs as a system service.
The *client* tools normally used to talk to it (`iproxy`, from `libusbmuxd-tools`)
often are not installed, and installing them needs root.

They are not needed. The daemon listens on a world-writable Unix socket and speaks
a small plist-over-socket protocol. This module implements it, which gives you:

  * `list_devices()`  — what is plugged in
  * `connect(port)`   — a socket wired straight to a TCP port on the device
  * `forward(...)`    — a local TCP listener, i.e. exactly what `iproxy` does
  * `UsbmuxHTTPHandler` — a urllib transport, so no local port is needed at all

Command line:

    python3 usbmux.py list
    python3 usbmux.py forward 8080:8080      # drop-in replacement for iproxy
"""

from __future__ import annotations

import http.client
import os
import plistlib
import socket
import socketserver
import struct
import sys
import threading
import urllib.request
from typing import Optional

__all__ = [
    "UsbmuxError",
    "DeviceNotFound",
    "ConnectionRefused",
    "list_devices",
    "find_device",
    "connect",
    "forward",
    "UsbmuxHTTPConnection",
    "UsbmuxHTTPHandler",
    "socket_address",
]

# Protocol constants. The header is 4 little-endian uint32s: total length
# (including the header), protocol version, message type, and a caller tag.
_HEADER = struct.Struct("<IIII")
_VERSION_PLIST = 1
_MESSAGE_PLIST = 8

_RESULT_NAMES = {
    0: "OK",
    1: "BadCommand",
    2: "BadDevice",
    3: "ConnectionRefused",
    5: "BadVersion",
}

_CLIENT_INFO = {
    "ClientVersionString": "camera-api-python",
    "ProgName": "camera-api",
    "kLibUSBMuxVersion": 3,
}


class UsbmuxError(RuntimeError):
    """usbmuxd is unreachable or returned an error."""


class DeviceNotFound(UsbmuxError):
    pass


class ConnectionRefused(UsbmuxError):
    """Nothing is listening on that port inside the device."""


def socket_address() -> str:
    """Where the daemon listens. Honours `USBMUXD_SOCKET_ADDRESS`."""
    override = os.environ.get("USBMUXD_SOCKET_ADDRESS")
    if override:
        return override
    for path in ("/var/run/usbmuxd", "/run/usbmuxd"):
        if os.path.exists(path):
            return path
    return "/var/run/usbmuxd"


def _open_daemon(timeout: float) -> socket.socket:
    address = socket_address()
    try:
        if ":" in address and not address.startswith("/"):
            host, _, port = address.rpartition(":")
            sock = socket.create_connection((host, int(port)), timeout=timeout)
        else:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect(address)
    except FileNotFoundError:
        raise UsbmuxError(
            f"No usbmuxd socket at {address}. Install the `usbmuxd` package and "
            f"make sure the service is running (systemctl status usbmuxd)."
        ) from None
    except ConnectionRefusedError:
        # The socket file outlives the daemon. usbmuxd is socket-activated and
        # exits once the last device is unplugged, so a refused connection on an
        # existing socket almost always means "no device attached".
        raise UsbmuxError(
            f"usbmuxd is not listening on {address} (the socket file is stale). "
            f"This normally means no iOS device is plugged in — usbmuxd exits when "
            f"the last device is removed. Check the cable, then `lsusb | grep -i apple`."
        ) from None
    except OSError as exc:
        raise UsbmuxError(f"Cannot reach usbmuxd at {address}: {exc}") from None
    return sock


def _exchange(sock: socket.socket, request: dict, tag: int = 1) -> dict:
    """Sends one plist message and reads the single plist reply."""
    payload = plistlib.dumps({**request, **_CLIENT_INFO})
    sock.sendall(_HEADER.pack(_HEADER.size + len(payload), _VERSION_PLIST, _MESSAGE_PLIST, tag) + payload)

    header = _recv_exactly(sock, _HEADER.size)
    length, _version, _message, _tag = _HEADER.unpack(header)
    if length < _HEADER.size:
        raise UsbmuxError(f"usbmuxd sent a malformed header (length {length})")
    return plistlib.loads(_recv_exactly(sock, length - _HEADER.size))


def _recv_exactly(sock: socket.socket, count: int) -> bytes:
    chunks = []
    remaining = count
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise UsbmuxError("usbmuxd closed the connection unexpectedly")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def list_devices(timeout: float = 10.0) -> list:
    """Returns one dict per attached device: `device_id`, `udid`, `connection_type`."""
    sock = _open_daemon(timeout)
    try:
        reply = _exchange(sock, {"MessageType": "ListDevices"})
    finally:
        sock.close()

    devices = []
    for entry in reply.get("DeviceList", []):
        properties = entry.get("Properties", {})
        devices.append({
            "device_id": entry.get("DeviceID"),
            "udid": properties.get("SerialNumber"),
            "connection_type": properties.get("ConnectionType"),
            "product_id": properties.get("ProductID"),
            "location_id": properties.get("LocationID"),
        })
    return devices


def find_device(udid: Optional[str] = None, timeout: float = 10.0) -> dict:
    """Picks a device by UDID, or the only attached one."""
    devices = list_devices(timeout)
    if not devices:
        raise DeviceNotFound(
            "No iOS device is attached. Check the cable, and that the device is "
            "unlocked and trusts this computer."
        )
    if udid:
        for device in devices:
            if device["udid"] == udid:
                return device
        available = ", ".join(str(d["udid"]) for d in devices)
        raise DeviceNotFound(f"No device with UDID {udid}. Attached: {available}")

    if len(devices) > 1:
        available = ", ".join(str(d["udid"]) for d in devices)
        raise DeviceNotFound(
            f"{len(devices)} devices attached; pass a UDID to choose one. Attached: {available}"
        )
    return devices[0]


def connect(
    port: int,
    udid: Optional[str] = None,
    device_id: Optional[int] = None,
    timeout: float = 30.0,
) -> socket.socket:
    """Returns a socket connected to `port` on the device's loopback interface.

    Read and write it exactly like an ordinary TCP socket — the daemon tunnels
    the bytes over USB.
    """
    if device_id is None:
        device_id = find_device(udid, timeout)["device_id"]

    sock = _open_daemon(timeout)
    try:
        reply = _exchange(sock, {
            "MessageType": "Connect",
            "DeviceID": device_id,
            # usbmuxd wants the port in network byte order.
            "PortNumber": socket.htons(port),
        })
    except Exception:
        sock.close()
        raise

    number = reply.get("Number")
    if number != 0:
        sock.close()
        name = _RESULT_NAMES.get(number, f"unknown ({number})")
        if number == 3:
            raise ConnectionRefused(
                f"Nothing is listening on port {port} inside the device. "
                f"Is the CameraAPI app installed and in the foreground?"
            )
        raise UsbmuxError(f"usbmux Connect to port {port} failed: {name}")

    # Past this point the socket carries raw application bytes.
    sock.settimeout(timeout)
    return sock


# ----------------------------------------------------------------- urllib transport


class UsbmuxHTTPConnection(http.client.HTTPConnection):
    """An `HTTPConnection` whose socket comes from usbmux instead of TCP.

    Everything above the socket — request framing, chunked reads, keep-alive —
    is stock `http.client`, so `urllib` works unchanged.
    """

    def __init__(self, host, port=None, timeout=30.0, udid=None, device_id=None, **kwargs):
        super().__init__(host, port, timeout=timeout)
        self._udid = udid
        self._device_id = device_id

    def connect(self):
        timeout = self.timeout if isinstance(self.timeout, (int, float)) else 30.0
        self.sock = connect(
            self.port, udid=self._udid, device_id=self._device_id, timeout=timeout
        )


class UsbmuxHTTPHandler(urllib.request.HTTPHandler):
    """Plug into `urllib.request.build_opener()` to route http:// over USB.

    The URL's host is ignored; only its port is used, and it names the port
    *inside* the device. Subclassing `HTTPHandler` rather than
    `AbstractHTTPHandler` matters: it makes `build_opener` drop the stock
    handler instead of registering two competing `http_open` implementations.
    """

    def __init__(self, udid=None, device_id=None, debuglevel=0):
        super().__init__(debuglevel)
        self.udid = udid
        self.device_id = device_id

    def http_open(self, req):
        def factory(host, timeout=30.0, **kwargs):
            return UsbmuxHTTPConnection(
                host, timeout=timeout, udid=self.udid, device_id=self.device_id
            )
        return self.do_open(factory, req)


# --------------------------------------------------------------------- port forward


class _ForwardServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, local_address, device_port, device_id, quiet):
        super().__init__(local_address, _ForwardHandler)
        self.device_port = device_port
        self.device_id = device_id
        self.quiet = quiet


class _ForwardHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            device = connect(
                self.server.device_port, device_id=self.server.device_id, timeout=None
            )
        except UsbmuxError as exc:
            if not self.server.quiet:
                print(f"  connect failed: {exc}", file=sys.stderr)
            return

        # A timeout here would tear down long-lived streams (MJPEG, SSE).
        device.settimeout(None)
        self.request.settimeout(None)

        def pump(source, sink):
            try:
                while True:
                    data = source.recv(65536)
                    if not data:
                        break
                    sink.sendall(data)
            except OSError:
                pass
            finally:
                # Half-close so the other direction can drain before shutdown.
                try:
                    sink.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        upstream = threading.Thread(target=pump, args=(self.request, device), daemon=True)
        upstream.start()
        pump(device, self.request)
        upstream.join(timeout=5)
        device.close()


def forward(
    local_port: int,
    device_port: int,
    udid: Optional[str] = None,
    bind: str = "127.0.0.1",
    quiet: bool = False,
) -> _ForwardServer:
    """Starts a local TCP listener that tunnels to `device_port` on the device.

    This is what `iproxy local:device` does. Returns the server; call
    `serve_forever()` to block, or `shutdown()` to stop. Use it when a tool needs
    a real TCP endpoint — ffmpeg, VLC, OpenCV. For Python callers,
    `UsbmuxHTTPHandler` skips the local port entirely.
    """
    device = find_device(udid)
    server = _ForwardServer((bind, local_port), device_port, device["device_id"], quiet)
    if not quiet:
        print(
            f"Forwarding {bind}:{server.server_address[1]} -> device port {device_port} "
            f"(udid {device['udid']})",
            file=sys.stderr,
        )
    return server


# ---------------------------------------------------------------------------- CLI


def _main(argv) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0

    command = argv[1]

    if command == "list":
        devices = list_devices()
        if not devices:
            print("No devices attached.")
            return 1
        for device in devices:
            print(f"DeviceID={device['device_id']}  UDID={device['udid']}  "
                  f"connection={device['connection_type']}")
        return 0

    if command == "forward":
        if len(argv) < 3:
            print("usage: usbmux.py forward LOCAL:DEVICE [--udid UDID] [--bind ADDR]",
                  file=sys.stderr)
            return 2
        local_text, _, device_text = argv[2].partition(":")
        if not device_text:
            print("usage: usbmux.py forward LOCAL:DEVICE", file=sys.stderr)
            return 2

        udid = None
        bind = "127.0.0.1"
        rest = argv[3:]
        for index, token in enumerate(rest):
            if token == "--udid" and index + 1 < len(rest):
                udid = rest[index + 1]
            elif token == "--bind" and index + 1 < len(rest):
                bind = rest[index + 1]

        try:
            server = forward(int(local_text), int(device_text), udid=udid, bind=bind)
        except UsbmuxError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1

        try:
            server.serve_forever()
        except KeyboardInterrupt:
            server.shutdown()
        return 0

    print(f"unknown command '{command}'. Try: list, forward", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
