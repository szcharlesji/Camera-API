#!/usr/bin/env python3
"""Configure the camera, record a locked-down take, pull it to Linux.

    python3 record_and_pull.py [seconds]

Assumes `iproxy 8080:8080` is already running.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from camera_api import CameraAPI  # noqa: E402

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0


def main() -> int:
    cam = CameraAPI()

    print("Waiting for the camera…")
    cam.wait_until_ready(timeout=30)

    # Show what this phone can actually do at 60 fps before asking for it.
    modes = cam.supported_modes(min_fps=60)
    print(f"{len(modes)} mode(s) reach 60 fps; smallest is {modes[0][0]}x{modes[0][1]} @ {modes[0][2]:g} fps")

    status = cam.configure(width=1280, height=720, fps=60, codec="h264", audio=False)
    config = status["session"]["config"]
    print(f"Configured {config['width']}x{config['height']} @ {config['fps']:g} fps, "
          f"{config['bitrate'] / 1e6:.1f} Mbps {config['codec']}")

    # Let auto-exposure settle, then freeze everything so repeat takes match.
    time.sleep(1.0)
    controls = cam.lock_everything()
    print(f"Locked: focus {controls['lensPosition']:.2f}, "
          f"1/{1 / controls['exposureDurationSeconds']:.0f}s, ISO {controls['iso']:.0f}, "
          f"{controls['temperature']:.0f}K")

    print(f"Recording {SECONDS:g}s…")
    with cam.record(name="take1") as handle:
        time.sleep(SECONDS)

    meta = handle.result
    effective = meta["framesWritten"] / meta["durationSeconds"] if meta["durationSeconds"] else 0
    print(f"Captured {meta['durationSeconds']:.2f}s · {meta['framesWritten']} frames "
          f"({effective:.1f} fps effective, {meta['framesDropped']} dropped) · "
          f"{meta['sizeBytes'] / 1e6:.1f} MB")

    if meta["framesDropped"]:
        print("  note: frames were dropped — check thermal state or lower the bitrate")

    destination = f"{meta['name']}.{meta['container']}"

    def show(done, total):
        sys.stdout.write(f"\r  downloading {done * 100 // total}%")
        sys.stdout.flush()

    cam.download(meta["id"], destination, progress=show)
    print(f"\nSaved {destination}")

    cam.delete(meta["id"])
    print("Cleared from device.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
