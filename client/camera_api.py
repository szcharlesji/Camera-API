"""Python client for the CameraAPI iPhone app.

Standard library only — no pip install required on the Linux host.

    from camera_api import CameraAPI

    cam = CameraAPI()                       # 127.0.0.1:8080, i.e. through iproxy
    cam.configure(width=1280, height=720, fps=60)
    with cam.record(name="take1") as rec:
        time.sleep(5)
    cam.download(rec.result["id"], "take1.mov")

See docs/API.md for the full endpoint reference.
"""

from __future__ import annotations

import contextlib
import json
import os
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Iterator, Optional

__all__ = [
    "CameraAPI",
    "CameraAPIError",
    "HTTPError",
    "Recording",
    "pts_to_local",
    "frame_times",
    "DEFAULT_HOST",
    "DEFAULT_PORT",
]

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8080


class CameraAPIError(RuntimeError):
    """Base class for every error this client raises."""


class HTTPError(CameraAPIError):
    """The API returned a non-2xx status.

    ``code`` and ``message`` come from the server's JSON error body when present,
    so ``except HTTPError as e: if e.code == "conflict"`` is a reliable check.
    """

    def __init__(self, status: int, code: str, message: str):
        super().__init__(f"HTTP {status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message


@dataclass
class Recording:
    """Handle returned by :meth:`CameraAPI.record`.

    ``result`` is populated with the finished recording's metadata when the
    context manager exits.
    """

    id: str
    name: str
    started: dict = field(default_factory=dict)
    result: Optional[dict] = None


class CameraAPI:
    """A connection to one iPhone running the CameraAPI app."""

    def __init__(
        self,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_PORT,
        token: Optional[str] = None,
        timeout: float = 30.0,
        usbmux: bool = False,
        udid: Optional[str] = None,
    ):
        """
        By default this talks plain TCP to ``host:port``, which is what an
        ``iproxy`` tunnel gives you.

        With ``usbmux=True`` it speaks the usbmux protocol to the local daemon
        instead, tunnelling straight to ``port`` *inside the device*. That needs
        no ``iproxy`` binary and no root — useful on machines where you cannot
        install ``libusbmuxd-tools``. ``udid`` picks a device when more than one
        is attached.
        """
        self.host = host
        self.port = port
        self.token = token or os.environ.get("CAMERA_API_TOKEN") or None
        self.timeout = timeout
        self.usbmux = usbmux or os.environ.get("CAMERA_API_USBMUX") in ("1", "true", "yes")
        self.udid = udid or os.environ.get("CAMERA_API_UDID") or None

        if self.usbmux:
            from usbmux import UsbmuxError, UsbmuxHTTPHandler

            self._opener = urllib.request.build_opener(UsbmuxHTTPHandler(udid=self.udid))
            # usbmux failures surface from inside urllib's handler chain. They are
            # RuntimeErrors, not OSErrors, so urllib does not wrap them in URLError
            # and they would otherwise reach the caller as a raw traceback.
            self._transport_errors: tuple = (UsbmuxError,)
        else:
            self._opener = urllib.request.build_opener()
            self._transport_errors = ()

    # ------------------------------------------------------------------ plumbing

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def _url(self, path: str, params: Optional[dict] = None) -> str:
        url = f"{self.base_url}{path}"
        if params:
            clean = {k: v for k, v in params.items() if v is not None}
            if clean:
                url += "?" + urllib.parse.urlencode(clean)
        return url

    def _headers(self) -> dict:
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def _open(
        self,
        method: str,
        path: str,
        body: Optional[dict] = None,
        params: Optional[dict] = None,
        timeout: Optional[float] = None,
        extra_headers: Optional[dict] = None,
    ):
        """Issues a request and returns the raw response object."""
        data = None
        headers = self._headers()
        if extra_headers:
            headers.update(extra_headers)
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(
            self._url(path, params), data=data, headers=headers, method=method
        )
        try:
            return self._opener.open(
                request, timeout=self.timeout if timeout is None else timeout
            )
        except urllib.error.HTTPError as exc:
            raise self._to_error(exc) from None
        except self._transport_errors as exc:
            raise CameraAPIError(str(exc)) from None
        except urllib.error.URLError as exc:
            raise CameraAPIError(f"Could not reach {self.base_url}: {exc.reason}. {self._hint()}") from None
        except socket.timeout:
            raise CameraAPIError(f"Request to {path} timed out after {timeout or self.timeout}s") from None

    def _hint(self) -> str:
        """Names the most likely cause of a connection failure."""
        if self.usbmux:
            return "Is the app installed and in the foreground?"
        # A live usbmuxd socket with no tunnel is the common case on hosts where
        # libusbmuxd-tools was never installed.
        if os.path.exists("/var/run/usbmuxd") or os.path.exists("/run/usbmuxd"):
            return (
                f"No listener on {self.host}:{self.port}, but usbmuxd is running. "
                f"Either start 'iproxy {self.port}:{self.port}', or skip it entirely "
                f"with CameraAPI(usbmux=True) / camctl --usbmux."
            )
        return f"Is the app in the foreground and 'iproxy {self.port}:{self.port}' running?"

    @staticmethod
    def _to_error(exc: urllib.error.HTTPError) -> CameraAPIError:
        raw = exc.read()
        try:
            payload = json.loads(raw)
            return HTTPError(exc.code, payload.get("error", "error"), payload.get("message", ""))
        except (ValueError, TypeError):
            return HTTPError(exc.code, "error", raw.decode("utf-8", "replace")[:500])

    def _json(
        self,
        method: str,
        path: str,
        body: Optional[dict] = None,
        params: Optional[dict] = None,
        timeout: Optional[float] = None,
    ) -> Any:
        with self._open(method, path, body=body, params=params, timeout=timeout) as response:
            raw = response.read()
        if not raw:
            return None
        return json.loads(raw)

    # ------------------------------------------------------------------- discovery

    def health(self) -> dict:
        """Liveness probe. Never requires an auth token."""
        return self._json("GET", "/health")

    def status(self) -> dict:
        """Everything: device, session, controls, recording, stream, storage."""
        return self._json("GET", "/status")

    def cameras(self) -> list:
        return self._json("GET", "/cameras")["cameras"]

    def formats(self, camera: Optional[str] = None) -> dict:
        """Every resolution/frame-rate combination the camera supports."""
        return self._json("GET", "/formats", params={"camera": camera})

    def supported_modes(self, camera: Optional[str] = None, min_fps: float = 0) -> list:
        """Convenience view of :meth:`formats` as ``(width, height, max_fps)`` tuples."""
        formats = self.formats(camera)["formats"]
        modes = {
            (f["width"], f["height"], f["maxFrameRate"])
            for f in formats
            if f["maxFrameRate"] >= min_fps
        }
        return sorted(modes, key=lambda m: (m[0] * m[1], m[2]))

    def wait_until_ready(self, timeout: float = 30.0, interval: float = 0.5) -> dict:
        """Blocks until the server answers and the capture session is running.

        Useful right after launching the app or starting ``iproxy``, when the
        listener may not be up for another moment.
        """
        deadline = time.monotonic() + timeout
        last_error: Optional[Exception] = None
        while time.monotonic() < deadline:
            try:
                status = self.status()
                if status["session"]["running"]:
                    return status
                last_error = CameraAPIError(
                    "Session not running: " + str(status["session"].get("lastError") or "unknown")
                )
            except CameraAPIError as exc:
                last_error = exc
            time.sleep(interval)
        raise CameraAPIError(f"Camera not ready after {timeout}s ({last_error})")

    # --------------------------------------------------------------------- clock

    def clock(self) -> dict:
        """One reading of the phone's capture clock.

        ``captureClockSeconds`` is the timebase every video PTS is expressed in.
        Use :meth:`sync_clock` rather than calling this directly — a single
        reading carries no information about transport delay.
        """
        return self._json("GET", "/clock")

    def sync_clock(
        self,
        samples: int = 20,
        keep_fraction: float = 0.25,
        settle: float = 0.0,
    ) -> dict:
        """Estimate the offset between the phone's capture clock and this host.

        Standard NTP-style estimation: time each round trip, assume the phone
        read its clock at the midpoint, and keep only the fastest samples —
        a fast round trip has less room to be asymmetric, which is the error
        that actually matters.

        Returns a dict whose ``offset`` satisfies::

            local_monotonic ~= capture_clock_pts - offset

        so a frame's PTS maps onto this machine's timeline with
        :func:`pts_to_local`. ``uncertainty`` is a bound, not a standard
        deviation: with a best round trip of *r*, an adversarially asymmetric
        path can hide at most *r/2* of error.

        Repeat this periodically over a long recording. Phone and host crystals
        drift by tens of ppm, which is milliseconds over minutes; fit a line
        through several syncs rather than trusting one.
        """
        if samples < 1:
            raise ValueError("samples must be >= 1")

        readings = []
        available = True
        for _ in range(samples):
            before = time.monotonic()
            reading = self.clock()
            after = time.monotonic()

            available = available and reading.get("captureClockAvailable", True)
            rtt = after - before
            # Best guess at the local time when the phone sampled its clock.
            local_mid = (before + after) / 2
            readings.append({
                "rtt": rtt,
                "offset": reading["captureClockSeconds"] - local_mid,
                "local_mid": local_mid,
                "capture_minus_host": reading.get("captureMinusHostSeconds", 0.0),
            })
            if settle:
                time.sleep(settle)

        readings.sort(key=lambda r: r["rtt"])
        keep = max(1, int(round(len(readings) * keep_fraction)))
        best = readings[:keep]
        offsets = sorted(r["offset"] for r in best)
        median_offset = offsets[len(offsets) // 2]

        all_rtts = sorted(r["rtt"] for r in readings)

        return {
            "offset": median_offset,
            "uncertainty": readings[0]["rtt"] / 2,
            "offset_spread": offsets[-1] - offsets[0],
            "best_rtt": all_rtts[0],
            "median_rtt": all_rtts[len(all_rtts) // 2],
            "worst_rtt": all_rtts[-1],
            "samples": len(readings),
            "kept": keep,
            # Anchors for computing drift between two syncs.
            "at_local_monotonic": best[0]["local_mid"],
            "at_wall_clock": time.time(),
            "capture_clock_available": available,
            "capture_minus_host": best[0]["capture_minus_host"],
        }

    @staticmethod
    def drift_ppm(first: dict, second: dict) -> float:
        """Clock drift between two :meth:`sync_clock` results, in ppm.

        Positive means the phone clock runs fast relative to this host.
        """
        elapsed = second["at_local_monotonic"] - first["at_local_monotonic"]
        if elapsed <= 0:
            raise ValueError("second sync must be later than the first")
        return (second["offset"] - first["offset"]) / elapsed * 1e6

    # --------------------------------------------------------------- configuration

    def configure(
        self,
        camera: Optional[str] = None,
        width: Optional[int] = None,
        height: Optional[int] = None,
        fps: Optional[float] = None,
        codec: Optional[str] = None,
        bitrate: Optional[int] = None,
        audio: Optional[bool] = None,
        rotation_degrees: Optional[int] = None,
        stabilization: Optional[str] = None,
        format_index: Optional[int] = None,
        key_frame_interval: Optional[int] = None,
    ) -> dict:
        """Reconfigures the capture session. Omitted arguments are left alone.

        Returns the full status document so you can confirm what was actually
        selected — the app snaps to the nearest supported format and reports it.
        """
        body = {
            "camera": camera,
            "width": width,
            "height": height,
            "fps": fps,
            "codec": codec,
            "bitrate": bitrate,
            "audio": audio,
            "rotationDegrees": rotation_degrees,
            "stabilization": stabilization,
            "formatIndex": format_index,
            "keyFrameInterval": key_frame_interval,
        }
        return self._json("POST", "/configure", body={k: v for k, v in body.items() if v is not None})

    def controls(self) -> dict:
        return self._json("GET", "/controls")

    def control(
        self,
        focus: Optional[dict] = None,
        exposure: Optional[dict] = None,
        white_balance: Optional[dict] = None,
        zoom: Optional[float] = None,
        torch: Optional[dict] = None,
    ) -> dict:
        body = {
            "focus": focus,
            "exposure": exposure,
            "whiteBalance": white_balance,
            "zoom": zoom,
            "torch": torch,
        }
        return self._json("POST", "/control", body={k: v for k, v in body.items() if v is not None})

    def focus_once(self, point: Optional[list] = None) -> dict:
        """Single-shot autofocus — the AF-S of a normal camera.

        Sweeps the lens once, then holds it. Nothing re-focuses afterwards, so
        every subsequent recording keeps the same focus. This call does not
        return until the sweep has finished, so the ``lensPosition`` in the
        result is where the lens actually ended up.

        ``point`` optionally steers what it focuses on, as ``[x, y]`` in 0...1.
        """
        focus: dict = {"mode": "single"}
        if point is not None:
            focus["pointOfInterest"] = point
        return self.control(focus=focus)

    def lock_everything(self, converge: bool = False) -> dict:
        """Stops focus, exposure and white balance drifting between takes.

        By default this freezes all three exactly where they currently are.
        With ``converge=True`` each one runs a single-shot pass first and locks
        on that result — safer when the camera has not settled yet, since
        freezing immediately can pin a blurry or badly-metered frame.
        """
        mode = "single" if converge else "locked"
        return self.control(
            focus={"mode": mode},
            exposure={"mode": mode},
            white_balance={"mode": mode},
        )

    def set_stream_settings(
        self,
        fps: Optional[float] = None,
        quality: Optional[float] = None,
        max_width: Optional[int] = None,
    ) -> dict:
        body = {"fps": fps, "quality": quality, "maxWidth": max_width}
        return self._json("POST", "/stream/settings", body={k: v for k, v in body.items() if v is not None})

    # ------------------------------------------------------------------- recording

    def start_recording(
        self,
        name: Optional[str] = None,
        container: str = "mov",
        max_duration_seconds: Optional[float] = None,
    ) -> dict:
        body = {"name": name, "container": container, "maxDurationSeconds": max_duration_seconds}
        return self._json("POST", "/record/start", body={k: v for k, v in body.items() if v is not None})

    def stop_recording(self, timeout: float = 60.0) -> dict:
        """Finalises the file and returns its metadata.

        Blocks while the asset writer flushes, which is why the socket timeout is
        raised above the default.
        """
        return self._json("POST", "/record/stop", timeout=timeout)

    def recording_progress(self) -> Optional[dict]:
        """Progress of the in-flight recording, or ``None`` if idle."""
        result = self._json("GET", "/record")
        return None if result.get("ok") else result

    @contextlib.contextmanager
    def record(
        self,
        name: Optional[str] = None,
        container: str = "mov",
        max_duration_seconds: Optional[float] = None,
    ) -> Iterator[Recording]:
        """Records for the duration of the ``with`` block.

            with cam.record(name="take1") as rec:
                time.sleep(5)
            print(rec.result["sizeBytes"])

        The recording is stopped even if the block raises.
        """
        started = self.start_recording(name, container, max_duration_seconds)
        handle = Recording(id=started["id"], name=started["name"], started=started)
        try:
            yield handle
        finally:
            try:
                handle.result = self.stop_recording()
            except HTTPError as exc:
                # A max-duration auto-stop may have finished it already.
                if exc.code != "conflict":
                    raise
                handle.result = self.get_recording(handle.id)

    def clip(self, seconds: float, name: Optional[str] = None, container: str = "mov") -> dict:
        """Records for ``seconds`` and returns the finished recording's metadata."""
        with self.record(name=name, container=container) as handle:
            time.sleep(seconds)
        return handle.result

    # ----------------------------------------------------------------------- files

    def list_recordings(self) -> list:
        return self._json("GET", "/files")["recordings"]

    def storage(self) -> dict:
        result = self._json("GET", "/files")
        return {"totalBytes": result.get("totalBytes", 0), "freeDiskBytes": result.get("freeDiskBytes")}

    def get_recording(self, recording_id: str) -> dict:
        return self._json("GET", f"/files/{recording_id}")

    def download(
        self,
        recording_id: str,
        destination: str,
        resume: bool = True,
        chunk_size: int = 1 << 20,
        progress: Optional[Callable[[int, int], None]] = None,
        timeout: float = 600.0,
    ) -> str:
        """Downloads a recording to ``destination``.

        With ``resume=True`` an interrupted transfer is continued using an HTTP
        Range request instead of starting over — worth having on a USB link that
        can be unplugged.

        ``progress`` is called as ``progress(bytes_done, total_bytes)``.
        """
        meta = self.get_recording(recording_id)
        total = meta["sizeBytes"]

        already = 0
        mode = "wb"
        if resume and os.path.exists(destination):
            already = os.path.getsize(destination)
            if already == total:
                if progress:
                    progress(total, total)
                return destination
            if already > total:
                already = 0
            else:
                mode = "ab"

        headers = {"Range": f"bytes={already}-"} if already else None
        with self._open(
            "GET", f"/files/{recording_id}/download", extra_headers=headers, timeout=timeout
        ) as response:
            with open(destination, mode) as handle:
                done = already
                while True:
                    chunk = response.read(chunk_size)
                    if not chunk:
                        break
                    handle.write(chunk)
                    done += len(chunk)
                    if progress:
                        progress(done, total)

        actual = os.path.getsize(destination)
        if actual != total:
            raise CameraAPIError(
                f"Download of {recording_id} is short: got {actual} bytes, expected {total}."
            )
        return destination

    def delete(self, recording_id: str) -> dict:
        return self._json("DELETE", f"/files/{recording_id}")

    def delete_all(self) -> dict:
        return self._json("DELETE", "/files", params={"confirm": "true"})

    def pull(self, recording_id: str, destination: str, delete_after: bool = False, **kwargs) -> str:
        """Downloads a recording and optionally frees the space on the phone."""
        path = self.download(recording_id, destination, **kwargs)
        if delete_after:
            self.delete(recording_id)
        return path

    # ------------------------------------------------------------------------ live

    def snapshot(
        self,
        max_width: int = 1920,
        quality: float = 0.85,
        timeout: float = 10.0,
    ) -> bytes:
        """Returns a single JPEG captured from the next frame."""
        with self._open(
            "GET",
            "/snapshot",
            params={"maxWidth": max_width, "quality": quality},
            timeout=timeout,
        ) as response:
            return response.read()

    def save_snapshot(self, destination: str, **kwargs) -> str:
        with open(destination, "wb") as handle:
            handle.write(self.snapshot(**kwargs))
        return destination

    def stream_mjpeg(
        self,
        fps: Optional[float] = None,
        quality: Optional[float] = None,
        max_width: Optional[int] = None,
        timeout: float = 30.0,
    ) -> Iterator[bytes]:
        """Yields JPEG frames from the live stream, forever.

            for jpeg in cam.stream_mjpeg(fps=30):
                ...

        Each yielded value is a complete JPEG file. Break out of the loop to
        disconnect.
        """
        params = {"fps": fps, "quality": quality, "maxWidth": max_width}
        response = self._open("GET", "/stream.mjpeg", params=params, timeout=timeout)
        try:
            yield from _iter_multipart_jpeg(response)
        finally:
            response.close()

    def events(self, timeout: float = 300.0) -> Iterator[tuple]:
        """Yields ``(event_name, payload_dict)`` from the server-sent event stream.

        The first event is always ``hello`` carrying a full status document.
        A ``keepalive`` comment arrives every 15s; it is filtered out here.
        """
        response = self._open("GET", "/events", timeout=timeout)
        try:
            yield from _iter_sse(response)
        finally:
            response.close()

    # ---------------------------------------------------------------------- server

    def set_server_settings(
        self,
        port: Optional[int] = None,
        access_mode: Optional[str] = None,
        auth_token: Optional[str] = None,
    ) -> dict:
        """Rebinds the listener. The current connection will drop."""
        body = {"port": port, "accessMode": access_mode, "authToken": auth_token}
        return self._json("POST", "/server/settings", body={k: v for k, v in body.items() if v is not None})


# ------------------------------------------------------------------ time alignment


def pts_to_local(pts_seconds, sync: dict):
    """Map a capture-clock timestamp onto this machine's ``time.monotonic()``.

    ``pts_seconds`` may be a single value or an iterable. ``sync`` is the result
    of :meth:`CameraAPI.sync_clock`.
    """
    offset = sync["offset"]
    if isinstance(pts_seconds, (int, float)):
        return pts_seconds - offset
    return [p - offset for p in pts_seconds]


def frame_times(recording: dict, file_pts_seconds, sync: Optional[dict] = None):
    """Absolute time for every frame of a finished recording.

    The written movie always restarts its timeline at zero, so the absolute
    capture time of frame *i* is ``firstVideoPTSSeconds + file_pts[i]``. Pass
    ``file_pts_seconds`` from ffprobe::

        ffprobe -v error -select_streams v:0 \\
                -show_entries frame=pts_time -of csv=p=0 video.mov

    Without ``sync`` the result is on the phone's capture clock. With ``sync``
    it is on this machine's monotonic clock, ready to align against telemetry.
    """
    timing = recording.get("timing")
    if not timing:
        raise CameraAPIError(
            "This recording has no timing metadata — it was captured by a build "
            "predating firstVideoPTSSeconds. Re-record to get an alignable file."
        )
    first = timing["firstVideoPTSSeconds"]
    absolute = [first + float(p) for p in file_pts_seconds]
    return pts_to_local(absolute, sync) if sync else absolute


# --------------------------------------------------------------------- stream parsing


def _read_line(stream) -> bytes:
    """Reads one CRLF-terminated line without over-reading into the body."""
    line = bytearray()
    while True:
        byte = stream.read(1)
        if not byte:
            return bytes(line)
        line += byte
        if line.endswith(b"\r\n"):
            return bytes(line)


def _iter_multipart_jpeg(stream) -> Iterator[bytes]:
    """Parses ``multipart/x-mixed-replace`` into individual JPEG payloads."""
    while True:
        # Skip forward to the next part boundary.
        line = _read_line(stream)
        if not line:
            return
        if not line.startswith(b"--"):
            continue

        length = None
        while True:
            header = _read_line(stream)
            if not header or header == b"\r\n":
                break
            name, _, value = header.decode("latin-1").partition(":")
            if name.strip().lower() == "content-length":
                length = int(value.strip())

        if length is None:
            # Without a length there is no safe way to find the payload end.
            raise CameraAPIError("MJPEG part is missing Content-Length")

        payload = bytearray()
        while len(payload) < length:
            chunk = stream.read(length - len(payload))
            if not chunk:
                return
            payload += chunk

        yield bytes(payload)


def _iter_sse(stream) -> Iterator[tuple]:
    """Parses ``text/event-stream`` into ``(event, payload)`` pairs."""
    event = "message"
    data_lines = []
    while True:
        raw = stream.readline()
        if not raw:
            return
        line = raw.decode("utf-8", "replace").rstrip("\n").rstrip("\r")

        if not line:
            if data_lines:
                blob = "\n".join(data_lines)
                try:
                    payload = json.loads(blob)
                except ValueError:
                    payload = {"raw": blob}
                yield event, payload
            event = "message"
            data_lines = []
            continue

        if line.startswith(":"):
            continue  # keepalive comment
        field, _, value = line.partition(":")
        value = value[1:] if value.startswith(" ") else value
        if field == "event":
            event = value
        elif field == "data":
            data_lines.append(value)
