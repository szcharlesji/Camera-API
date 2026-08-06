# CameraAPI

Turn an iPhone into a programmable camera you drive from a Linux machine over USB.

The iPhone runs an HTTP server. Linux reaches it through `usbmuxd`, Apple's USB
multiplexer, which forwards a local TCP port to a port on the device. No MFi
program, no jailbreak, no custom USB protocol — just `curl` over a cable.

```
Linux                                        iPhone
─────                                        ──────
your script ──HTTP──> localhost:8080
                           │
                      iproxy 8080:8080
                           │
                       usbmuxd
                           │
                      ═══ USB ═══>  127.0.0.1:8080
                                         │
                                   NWListener (CameraAPI.app)
                                         │
                              AVCaptureSession → AVAssetWriter
```

## The mental model that matters

**Recording happens on the phone, at full quality, to the phone's flash.** The USB
link is not in the capture path, so it never limits your frame rate. 1080p60 records
exactly as well over USB as it does untethered.

Three separate data paths, each with different constraints:

| Path | What it is | Limited by |
|---|---|---|
| **Record** | `AVAssetWriter` → phone storage | The camera and the encoder. Not USB. |
| **Download** | `GET /files/<id>/download` after the fact | USB throughput (~20–35 MB/s on Lightning) |
| **Live stream** | `GET /stream.mjpeg`, downscaled and throttled | USB throughput; tune with `fps`/`quality`/`maxWidth` |

So: record at whatever the sensor supports, stream a cheap preview alongside it,
and pull the full-quality file when the take is done.

## Quick start

### 1. Install the app on the iPhone

Open `Camera API.xcodeproj` in Xcode, select your device, set your signing team,
and run. Grant camera access when prompted.

The app must stay in the **foreground** — iOS suspends `AVCaptureSession` in the
background. See [Keeping it running](#keeping-it-running).

### 2. Set up the Linux host

```bash
sudo apt install usbmuxd libimobiledevice-utils libusbmuxd-tools
```

```bash
idevicepair pair
```

(Unlock the phone and tap **Trust**, then run `idevicepair pair` again.)

### 3. Open the tunnel

```bash
iproxy 8080:8080
```

### 4. Drive it

```bash
curl http://localhost:8080/status
```

Or with the bundled CLI:

```bash
./client/camctl status
```

```bash
./client/camctl formats --min-fps 60
```

```bash
./client/camctl configure --width 1280 --height 720 --fps 60
```

```bash
./client/camctl clip 10 -o take1.mov
```

That last one records ten seconds, downloads the file, and clears it off the phone.

Full host setup, systemd units and troubleshooting: **[docs/LINUX_SETUP.md](docs/LINUX_SETUP.md)**
Every endpoint with request and response bodies: **[docs/API.md](docs/API.md)**

## Python client

Standard library only — nothing to `pip install`.

```python
import sys, time
sys.path.insert(0, "client")
from camera_api import CameraAPI

cam = CameraAPI()                      # 127.0.0.1:8080 through iproxy
cam.wait_until_ready()

cam.configure(width=1280, height=720, fps=60, codec="h264")
cam.lock_everything()                  # freeze focus/exposure/WB for repeatable takes

with cam.record(name="take1") as rec:
    time.sleep(10)

print(rec.result["framesWritten"], "frames")
cam.download(rec.result["id"], "take1.mov")
cam.delete(rec.result["id"])
```

See [client/examples/](client/examples/) for a live-stream consumer and an event tail.

## What the API covers

- **Discovery** — every camera, and every resolution/frame-rate/format combination each one supports
- **Configuration** — resolution, frame rate, codec (H.264/HEVC), bitrate, rotation, stabilization, audio on/off
- **Manual controls** — focus (incl. manual lens position), exposure (shutter + ISO), white balance (Kelvin), zoom, torch
- **Recording** — start/stop, live progress, optional auto-stop after N seconds
- **Files** — list, download with HTTP Range (resumable), delete
- **Live** — single JPEG snapshots, and an MJPEG stream that `ffmpeg`, OpenCV, VLC and browsers all read natively
- **Events** — server-sent events for recording start/stop, session interruptions and errors

## Consuming the live stream

The MJPEG stream needs no client library:

```bash
ffplay http://localhost:8080/stream.mjpeg
```

```bash
ffmpeg -i http://localhost:8080/stream.mjpeg -c:v libx264 preview.mp4
```

```python
import cv2
capture = cv2.VideoCapture("http://localhost:8080/stream.mjpeg")
```

The stream is deliberately independent of what is being recorded: it is downscaled
and rate-limited so a preview never steals bandwidth from the capture. Tune it with
`?fps=30&quality=0.7&maxWidth=960`.

## Security

The server binds all interfaces but **rejects any connection that does not originate
on the device itself**. Because `usbmuxd` proxies host traffic through the phone's
loopback interface, USB clients work while nobody on the Wi-Fi network can reach it.
This is the `usb_only` default.

Switching to `network` mode in the app (or via `POST /server/settings`) accepts
connections from anywhere. Set a bearer token when you do:

```bash
curl -X POST http://localhost:8080/server/settings \
  -H 'Content-Type: application/json' \
  -d '{"accessMode":"network","authToken":"some-long-random-string"}'
```

Then pass `--token` to `camctl`, or set `CAMERA_API_TOKEN`.

## Keeping it running

iOS interrupts `AVCaptureSession` the moment the app leaves the foreground —
`GET /events` reports this as `session.interrupted` with reason
`video_device_not_available_in_background`. For an unattended rig:

- The app already disables the idle timer, so the screen will not lock.
- Keep the device on power. USB provides it.
- For a real kiosk, supervise the device with Apple Configurator and enable
  **Single App Mode**. That is the only way to make the app genuinely
  un-leaveable. Guided Access (Settings › Accessibility) is the manual equivalent.

Also note: a free Apple ID signs the app for **7 days**; a paid developer account
for a year. Budget for reinstalling.

## Project layout

```
Camera API/
  App/          SwiftUI dashboard, app wiring, live preview
  Capture/      AVCaptureSession, AVAssetWriter recording, format selection, JPEG encoding
  Server/       HTTP/1.1 server on NWListener, routing, MJPEG and SSE broadcasters
client/
  camera_api.py Python client library (stdlib only)
  camctl        Command line interface
  examples/     Runnable examples
docs/
  API.md        Endpoint reference
  LINUX_SETUP.md  Host setup, systemd, troubleshooting
```

## Implementation notes

- Capture uses `AVCaptureVideoDataOutput` + `AVAssetWriter` rather than
  `AVCaptureMovieFileOutput`, so the same buffers feed both the recording and the
  MJPEG stream, and the codec, bitrate and keyframe interval are all under
  explicit control.
- Video and audio sample buffers share one serial dispatch queue, which is the
  only queue that touches the asset writer — no locking around it.
- Frame rate is treated as a hard constraint during format selection. Asking for
  60 fps on a camera that cannot deliver it returns a `400` naming the device
  maximum rather than silently recording at 30.
- Buffers are rotated by the capture connection, so recordings and the MJPEG
  stream always agree on orientation. `rotationDegrees` defaults to `0`, the
  sensor's native landscape.
- The writer uses the pre-iOS-27 synchronous `AVAssetWriterInput` API on purpose;
  buffers arrive on a serial queue and appending inline preserves ordering and
  back-pressure without bridging every frame into an async context. The
  deprecation warnings this produces are expected.
