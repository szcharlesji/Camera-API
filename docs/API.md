# CameraAPI HTTP reference

Base URL through a USB tunnel: `http://127.0.0.1:8080`

All request and response bodies are JSON unless noted. Timestamps are ISO 8601.
Every field in a request body is optional unless marked **required**; omitted
fields keep their current value.

`GET /` returns a plain-text summary of everything below, straight from the device.

## Conventions

### Errors

Non-2xx responses carry:

```json
{ "error": "bad_request", "message": "fps must be between 0 and 240." }
```

| `error` | Status | Meaning |
|---|---|---|
| `bad_request` | 400 | Malformed or out-of-range input. The message names the valid range. |
| `unauthorized` | 401 | Missing or wrong bearer token. |
| `not_found` | 404 | No such route or recording id. |
| `method_not_allowed` | 405 | Wrong verb for this path. |
| `conflict` | 409 | Already recording, or not recording, or reconfiguring mid-recording. |
| `body_too_large` | 413 | Request body over 4 MiB. |
| `range_not_satisfiable` | 416 | `Range` header cannot be met. |
| `headers_too_large` | 431 | Request headers over 64 KiB. |
| `internal_error` | 500 | Asset writer or capture failure. The message carries the underlying reason. |
| `unavailable` | 503 | No camera, or the session is not running. |

### Authentication

When a token is configured, send it on every request except `/health`:

```
Authorization: Bearer <token>
```

### Connections

HTTP/1.1 with keep-alive and request pipelining. Request bodies must use
`Content-Length`; chunked request bodies are rejected. `HEAD` is answered like
`GET` with the body suppressed.

---

## Discovery

### `GET /health`

Liveness probe. Never requires a token — safe for a supervisor loop.

```json
{ "ok": true, "message": "CameraAPI 1.0.0" }
```

### `GET /status`

Everything about the device and session in one document. This is the endpoint to
poll.

```json
{
  "api": {
    "name": "CameraAPI",
    "version": "1.0.0",
    "uptimeSeconds": 412.8,
    "port": 8080,
    "accessMode": "usb_only",
    "authRequired": false,
    "httpConnections": 1,
    "mjpegClients": 0,
    "eventClients": 1
  },
  "device": {
    "name": "iPhone",
    "model": "iPhone",
    "systemName": "iOS",
    "systemVersion": "27.0",
    "thermalState": "nominal",
    "batteryLevel": 0.87,
    "batteryState": "charging",
    "lowPowerModeEnabled": false,
    "freeDiskBytes": 84129382400
  },
  "session": {
    "running": true,
    "interrupted": false,
    "interruptionReason": null,
    "cameraPermission": "authorized",
    "microphonePermission": "authorized",
    "config": {
      "camera": "com.apple.avfoundation.avcapturedevice.built-in_video:0",
      "cameraPosition": "back",
      "width": 1280,
      "height": 720,
      "fps": 60,
      "codec": "h264",
      "bitrate": 5529600,
      "audioEnabled": true,
      "rotationDegrees": 0,
      "stabilization": "off",
      "formatIndex": 12
    },
    "lastError": null
  },
  "controls": {
    "focusMode": "auto",
    "lensPosition": 0.82,
    "exposureMode": "auto",
    "exposureDurationSeconds": 0.0166,
    "iso": 320,
    "exposureTargetBias": 0,
    "whiteBalanceMode": "auto",
    "temperature": 5100,
    "tint": 4.2,
    "zoom": 1,
    "torchOn": false,
    "torchLevel": 0
  },
  "recording": null,
  "stream": { "fps": 15, "quality": 0.6, "maxWidth": 640, "clients": 0 },
  "storage": { "recordingCount": 3, "totalBytes": 48211004, "freeDiskBytes": 84129382400 }
}
```

`thermalState` is worth watching on long runs: at `serious` the system throttles
and frame drops begin. `session.interrupted` goes `true` whenever the app leaves
the foreground.

### `GET /cameras`

```json
{
  "cameras": [
    {
      "uniqueID": "com.apple.avfoundation.avcapturedevice.built-in_video:0",
      "localizedName": "Back Camera",
      "position": "back",
      "deviceType": "AVCaptureDeviceTypeBuiltInWideAngleCamera",
      "isActive": true,
      "minZoom": 1,
      "maxZoom": 123.75,
      "hasTorch": true
    }
  ]
}
```

### `GET /formats`

| Query | Default | Meaning |
|---|---|---|
| `camera` | active camera | `back`, `front`, or a `uniqueID` |

Enumerates every capture format. **Check this before asking for a frame rate** —
which resolutions reach 60, 120 or 240 fps varies by camera and by phone.

```json
{
  "camera": { "uniqueID": "…", "localizedName": "Back Camera", "position": "back", "isActive": true },
  "cameras": [ … ],
  "formats": [
    {
      "index": 12,
      "width": 1280,
      "height": 720,
      "minFrameRate": 1,
      "maxFrameRate": 60,
      "pixelFormat": "420v",
      "isBinned": true,
      "fieldOfView": 68.5,
      "maxZoomFactor": 16,
      "supportsVideoStabilization": true,
      "isActive": true
    }
  ]
}
```

`index` is what you pass to `configure` as `formatIndex` to pin an exact format.

---

## Configuration

### `POST /configure`

Rebuilds the capture session. Returns the full `/status` document, so you can
confirm what was actually selected — the app snaps to the nearest supported
format and reports the real values back.

```json
{
  "camera": "back",
  "width": 1280,
  "height": 720,
  "fps": 60,
  "codec": "h264",
  "bitrate": 8000000,
  "audio": true,
  "rotationDegrees": 0,
  "stabilization": "off",
  "formatIndex": 12
}
```

| Field | Type | Notes |
|---|---|---|
| `camera` | string | `back`, `front`, or a `uniqueID` |
| `width`, `height` | int | Matched to the closest supported format |
| `fps` | number | **Hard constraint.** No format that reaches it ⇒ `400` naming the device maximum |
| `codec` | string | `h264` or `hevc` |
| `bitrate` | int | Bits/sec. Omit to derive from resolution × frame rate |
| `audio` | bool | Silently becomes `false` if the microphone permission is denied |
| `rotationDegrees` | int | `0`, `90`, `180`, `270`. Rotates the buffers, so recordings and the stream agree |
| `stabilization` | string | `off`, `standard`, `cinematic`, `cinematicExtended`, `auto` |
| `formatIndex` | int | Bypasses resolution/fps matching; applies to this call only |

Returns `409` if a recording is in progress.

`rotationDegrees` defaults to `0` — the sensor's native landscape orientation.
A quarter turn swaps the recorded dimensions.

### `GET /controls`

Returns the `controls` block from `/status`.

### `POST /control`

Applies any subset of the manual controls. Ranges are validated against the
*active format*, and the error message names the valid range.

```json
{
  "focus":        { "mode": "manual", "lensPosition": 0.75, "pointOfInterest": [0.5, 0.5] },
  "exposure":     { "mode": "manual", "durationSeconds": 0.008, "iso": 400, "targetBias": 0 },
  "whiteBalance": { "mode": "manual", "temperature": 5000, "tint": 0 },
  "zoom": 2.0,
  "torch": { "on": true, "level": 0.8 }
}
```

| Group | `mode` | Extra fields |
|---|---|---|
| `focus` | `auto`, `locked`, `manual` | `lensPosition` 0.0 (near) – 1.0 (far), required for `manual`. `pointOfInterest` `[x, y]` in 0–1 |
| `exposure` | `auto`, `locked`, `manual` | `durationSeconds` (shutter), `iso`, both clamped to the active format. `targetBias` is EV compensation in `auto` |
| `whiteBalance` | `auto`, `locked`, `manual` | `temperature` in Kelvin, `tint` −150…150 |
| `zoom` | — | Between the camera's `minZoom` and `maxZoom` |
| `torch` | — | `on`, and `level` 0.0–1.0 |

Returns the resulting control state.

> For repeatable capture, lock all three of focus, exposure and white balance
> before the first take. Otherwise the camera re-meters between takes and your
> footage will not match. `camctl lock` and `CameraAPI.lock_everything()` do this
> in one call.

### `POST /stream/settings`

Adjusts the MJPEG preview without touching what gets recorded.

```json
{ "fps": 15, "quality": 0.6, "maxWidth": 640 }
```

`fps` 1–60, `quality` 0.1–1.0, `maxWidth` 64–3840 (applied to the longest edge).

### `POST /server/settings`

Rebinds the listener. **The current connection drops** — the response is sent
first, then the server restarts about 250 ms later.

```json
{ "port": 8080, "accessMode": "usb_only", "authToken": "" }
```

`accessMode` is `usb_only` (accept only connections originating on the device,
which is what `usbmuxd` produces) or `network` (accept anything). Send
`"authToken": ""` to clear the token.

---

## Recording

### `POST /record/start`

```json
{ "name": "take1", "container": "mov", "maxDurationSeconds": 30 }
```

`name` is sanitised to `[A-Za-z0-9._-]` and defaults to the generated id.
`container` is `mov` (default) or `mp4`. `maxDurationSeconds` auto-stops the
recording and emits a `recording.autostopped` event.

`201 Created`:

```json
{
  "id": "9C1F…",
  "name": "take1",
  "startedAt": "2026-08-06T15:04:11Z",
  "durationSeconds": 0,
  "framesWritten": 0,
  "framesDropped": 0,
  "bytesWritten": 0,
  "maxDurationSeconds": 30
}
```

`409` if already recording; `503` if the session is not running.

### `POST /record/stop`

| Query | Default | Meaning |
|---|---|---|
| `timeout` | `30` | Seconds to wait for the asset writer to finalise |

Blocks while the file is flushed, then returns the finished recording:

```json
{
  "id": "9C1F…",
  "name": "take1",
  "filename": "9C1F….mov",
  "createdAt": "2026-08-06T15:04:11Z",
  "durationSeconds": 10.02,
  "sizeBytes": 12882910,
  "width": 1280,
  "height": 720,
  "fps": 60,
  "codec": "h264",
  "container": "mov",
  "hasAudio": true,
  "framesWritten": 601,
  "framesDropped": 0,
  "cameraPosition": "back",
  "rotationDegrees": 0,
  "downloadPath": "/files/9C1F…/download"
}
```

Compare `framesWritten` against `durationSeconds × fps` to confirm you actually
got the frame rate you asked for. `framesDropped` counts buffers the encoder
could not keep up with.

`409` if no recording is in progress.

### `GET /record`

Progress of the in-flight recording, same shape as the `/record/start` response.
When idle, returns `{ "ok": true, "message": "No recording in progress." }`.

---

## Files

### `GET /files`

```json
{
  "recordings": [ { … same shape as the /record/stop response … } ],
  "totalBytes": 48211004,
  "freeDiskBytes": 84129382400
}
```

Newest first.

### `GET /files/<id>`

One recording's metadata. `404` if unknown.

### `GET /files/<id>/download`

The media file. Supports `Range`, so interrupted transfers resume instead of
restarting:

```
Range: bytes=4194304-
```

Responds `206 Partial Content` with `Content-Range`, or `416` if the range cannot
be met. `Accept-Ranges: bytes` is always advertised. Single ranges only.

### `DELETE /files/<id>`

```json
{ "deleted": ["9C1F…"], "freedBytes": 12882910 }
```

### `DELETE /files?confirm=true`

Deletes every recording. The `confirm=true` parameter is required; without it you
get a `400`.

---

## Live

### `GET /snapshot`

| Query | Default | Range |
|---|---|---|
| `maxWidth` | `1920` | 64–8192, applied to the longest edge |
| `quality` | `0.85` | 0.0–1.0 |
| `timeout` | `5` | Seconds to wait for the next frame |

Returns `image/jpeg` captured from the next frame off the sensor. `503` if no
frame arrives within `timeout`.

### `GET /stream.mjpeg`

`multipart/x-mixed-replace; boundary=cameraapiframe` — an endless sequence of:

```
--cameraapiframe
Content-Type: image/jpeg
Content-Length: 24196

<JPEG bytes>
```

`fps`, `quality` and `maxWidth` query parameters update the shared stream settings,
so quality is tunable from the URL alone:

```bash
ffplay 'http://localhost:8080/stream.mjpeg?fps=30&quality=0.7&maxWidth=960'
```

A client that reads more slowly than frames are produced has its excess frames
**dropped**, never queued — a stalled viewer cannot grow memory on the phone or
slow down the recorder. `/stream` is an alias.

### `GET /events`

`text/event-stream`. The first event is always `hello`, carrying a full `/status`
document. A `: keepalive` comment arrives every 15 s.

```
event: recording.started
data: {"type":"recording.started","timestamp":"2026-08-06T15:04:11Z","payload":{ … }}
```

| Event | Payload |
|---|---|
| `hello` | Full status document |
| `recording.started` | The active-recording object |
| `recording.stopped` | The finished recording object |
| `recording.autostopped` | `{ "message": "max_duration_reached" }` |
| `session.interrupted` | `{ "message": "video_device_not_available_in_background" }` |
| `session.resumed` | `{}` |
| `error` | `{ "message": "…" }` |

```bash
curl -N http://localhost:8080/events
```

Interruption reasons: `video_device_not_available_in_background`,
`audio_device_in_use_by_another_client`, `video_device_in_use_by_another_client`,
`video_device_not_available_with_multiple_foreground_apps`,
`video_device_not_available_due_to_system_pressure`,
`sensitive_content_mitigation_activated`.

---

## A complete session in curl

```bash
curl -s localhost:8080/formats | jq '.formats[] | select(.maxFrameRate >= 60)'
```

```bash
curl -s -X POST localhost:8080/configure -H 'Content-Type: application/json' \
  -d '{"camera":"back","width":1280,"height":720,"fps":60,"codec":"h264","audio":false}'
```

```bash
curl -s -X POST localhost:8080/control -H 'Content-Type: application/json' \
  -d '{"focus":{"mode":"locked"},"exposure":{"mode":"locked"},"whiteBalance":{"mode":"locked"}}'
```

```bash
ID=$(curl -s -X POST localhost:8080/record/start -H 'Content-Type: application/json' -d '{"name":"take1"}' | jq -r .id)
```

```bash
sleep 10 && curl -s -X POST localhost:8080/record/stop | jq '{durationSeconds, framesWritten, framesDropped, sizeBytes}'
```

```bash
curl -o take1.mov "localhost:8080/files/$ID/download" && curl -X DELETE "localhost:8080/files/$ID"
```
