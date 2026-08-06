#!/usr/bin/env python3
"""Tail the server-sent event stream and react to what the phone reports.

    python3 watch_events.py

Useful as a supervisor: it notices when the app gets backgrounded (which suspends
capture) and when a max-duration recording auto-stops.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from camera_api import CameraAPI  # noqa: E402


def main() -> int:
    cam = CameraAPI()

    print(f"Connecting to {cam.base_url}/events — Ctrl-C to stop.")
    try:
        for name, envelope in cam.events():
            payload = envelope.get("payload", {})
            stamp = envelope.get("timestamp", "")[:19]

            if name == "hello":
                config = payload["session"]["config"]
                print(f"{stamp}  connected · {config['width']}x{config['height']} @ {config['fps']:g} fps")

            elif name == "recording.started":
                print(f"{stamp}  ▶ {payload['name']} ({payload['id']})")

            elif name == "recording.stopped":
                effective = (payload["framesWritten"] / payload["durationSeconds"]
                             if payload["durationSeconds"] else 0)
                print(f"{stamp}  ■ {payload['name']} · {payload['durationSeconds']:.2f}s · "
                      f"{payload['framesWritten']} frames ({effective:.1f} fps) · "
                      f"{payload['sizeBytes'] / 1e6:.1f} MB")

            elif name == "recording.autostopped":
                print(f"{stamp}  ■ auto-stopped: {payload['message']}")

            elif name == "session.interrupted":
                print(f"{stamp}  ⚠ capture interrupted: {payload['message']}")
                if payload["message"] == "video_device_not_available_in_background":
                    print("       The app left the foreground. Enable Guided Access "
                          "(Settings › Accessibility) to prevent this.")

            elif name == "session.resumed":
                print(f"{stamp}  ✓ capture resumed")

            elif name == "error":
                print(f"{stamp}  ✗ {payload['message']}")

            else:
                print(f"{stamp}  {name}: {payload}")

            sys.stdout.flush()
    except KeyboardInterrupt:
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
