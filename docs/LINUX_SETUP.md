# Linux host setup

Everything needed to reach the iPhone over USB, plus the failure modes you are
likely to hit.

## 1. Install the tools

**Debian / Ubuntu**

```bash
sudo apt install usbmuxd libimobiledevice6 libimobiledevice-utils libusbmuxd-tools
```

**Fedora**

```bash
sudo dnf install usbmuxd libimobiledevice libimobiledevice-utils
```

**Arch**

```bash
sudo pacman -S usbmuxd libimobiledevice
```

`usbmuxd` runs as a systemd service and is usually socket-activated on plug-in.
Confirm it is alive:

```bash
systemctl status usbmuxd
```

## 2. Pair the device

Plug the phone in, unlock it, then:

```bash
idevicepair pair
```

The phone shows a **Trust This Computer?** prompt. Tap Trust, enter the passcode,
and run the command again. You want:

```
SUCCESS: Paired with device <udid>
```

Verify:

```bash
ideviceinfo -k DeviceName && ideviceinfo -k ProductVersion
```

The pairing record lives in `/var/lib/lockdown/` (or `/var/db/lockdown/`) and
survives reboots. It is invalidated by "Reset Location & Privacy" on the phone,
by a factory reset, and occasionally by a major iOS update.

## 3. Forward the port

```bash
iproxy 8080:8080
```

This binds `127.0.0.1:8080` on Linux and forwards every connection to
`127.0.0.1:8080` inside the phone, where the app is listening. Leave it running.

With more than one device attached, target one by UDID:

```bash
iproxy -u <udid> 8080:8080
```

Multiple phones at once, each on its own local port:

```bash
iproxy -u <udid-a> 8081:8080 & iproxy -u <udid-b> 8082:8080 &
```

Then point the client at each: `camctl --port 8081 status`.

## 4. Check it works

```bash
curl -s http://localhost:8080/health
```

```json
{ "message": "CameraAPI 1.0.0", "ok": true }
```

If that answers, everything downstream will work.

## Running it as a service

`iproxy` under systemd, so the tunnel comes back after a reboot or a replug:

```ini
# /etc/systemd/system/iproxy-camera.service
[Unit]
Description=USB tunnel to CameraAPI iPhone
After=usbmuxd.service
Wants=usbmuxd.service

[Service]
ExecStart=/usr/bin/iproxy 8080:8080
Restart=always
RestartSec=2
User=nobody

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now iproxy-camera.service
```

`Restart=always` matters: `iproxy` exits when the device is unplugged, and this
brings it straight back when the cable returns.

To start it only when a specific iPhone appears, a udev rule is cleaner:

```
# /etc/udev/rules.d/99-cameraapi.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", TAG+="systemd", ENV{SYSTEMD_WANTS}="iproxy-camera.service"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Connection refused` on port 8080 | `iproxy` not running, or the app is not in the foreground | Start `iproxy`; bring the app to the front |
| `No device found` from `iproxy` | Not paired, or `usbmuxd` is not running | `idevicepair pair`; `systemctl start usbmuxd` |
| `ERROR: Please accept the trust dialog` | Trust prompt not confirmed | Unlock the phone, tap Trust, re-run `idevicepair pair` |
| Pairing succeeds then fails later | `usbmuxd` and a running `usbmuxd` from another source both claiming the device | `systemctl stop usbmuxd` and let socket activation handle it |
| Tunnel opens but `/status` hangs | The app is backgrounded — iOS froze the process | Foreground the app; use Guided Access to stop it happening |
| `503 unavailable`, "No camera is available" | Running in the Simulator, or camera permission denied | Run on hardware; check Settings › Camera API |
| `400`, "No format … supports 60 fps" | That camera cannot do that rate at that resolution | `camctl formats --min-fps 60` and pick a listed mode |
| `session.interrupted` events | App backgrounded, camera taken by another app, or thermal pressure | See `interruptionReason`; check `thermalState` in `/status` |
| Downloads stall part-way | Cable or `usbmuxd` hiccup | Re-run the download — `Range` support means it resumes rather than restarts |
| Frame rate lower than requested | Thermal throttling, or the encoder falling behind | Check `framesDropped` and `device.thermalState`; lower resolution or bitrate |

### Permissions

If `idevice*` tools only work under `sudo`, your user is not in the group that
owns the usbmuxd socket:

```bash
sudo usermod -aG plugdev $USER
```

Log out and back in.

## Throughput expectations

Lightning is USB 2.0: expect roughly **20–35 MB/s** in practice through the mux.
USB-C iPhones can do better, but do not design around it.

| Workload | Bandwidth | Fits over USB? |
|---|---|---|
| 720p60 H.264 @ 8 Mbps | 1 MB/s | Comfortably |
| 1080p60 H.264 @ 20 Mbps | 2.5 MB/s | Comfortably |
| 4K60 HEVC @ 50 Mbps | 6 MB/s | Yes |
| MJPEG 640×480 @ 30 fps | ~1.5 MB/s | Yes |
| Raw 720p BGRA @ 60 fps | 220 MB/s | No — record locally and pull |
| ProRes | ~190 MB/s | No — record locally and pull |

Remember that **recording is not affected by any of this**. The phone writes to
its own flash; USB only matters for streaming and for downloading afterwards.

## Reading recordings without HTTP

The app sets `UIFileSharingEnabled`, so its Documents directory is mountable
directly. Useful for bulk offload:

```bash
ifuse --documents com.szcharlesji.cameraapi /mnt/iphone
```

```bash
ls /mnt/iphone/Recordings/
```

```bash
fusermount -u /mnt/iphone
```

Each recording is a media file plus a JSON sidecar of the same basename, so the
catalogue is readable straight off the mount.

Treat this as a convenience, not the primary path: the `house_arrest` service
that backs `--documents` has been unreliable on recent iOS releases. The HTTP
download endpoint has no such dependency.

## Recipes

**Preview**

```bash
ffplay -fflags nobuffer 'http://localhost:8080/stream.mjpeg?fps=30'
```

**Transcode the live stream to a file on Linux**

```bash
ffmpeg -i 'http://localhost:8080/stream.mjpeg?fps=30&maxWidth=1280' -c:v libx264 -preset veryfast out.mp4
```

**Timed capture, downloaded and cleared off the phone**

```bash
./client/camctl clip 30 -o take.mov
```

**Pull everything, then wipe the device**

```bash
./client/camctl files pull --all -o ./footage --delete
```

**Watch state live**

```bash
./client/camctl watch
```

**Log every event with timestamps**

```bash
./client/camctl events | tee -a capture.log
```

**Snapshot on a cron schedule**

```bash
./client/camctl snapshot -o "frame-$(date +%s).jpg"
```

**OpenCV**

```python
import cv2
capture = cv2.VideoCapture("http://localhost:8080/stream.mjpeg")
while True:
    ok, frame = capture.read()
    if not ok:
        break
    cv2.imshow("iphone", frame)
    if cv2.waitKey(1) == 27:
        break
```
