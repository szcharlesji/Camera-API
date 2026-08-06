#!/usr/bin/env python3
"""Consume the live MJPEG stream.

    python3 live_stream.py              # measure throughput, no dependencies
    python3 live_stream.py --show       # display frames (needs opencv-python)

For a viewer with no code at all, just point ffplay at the URL:
    ffplay http://localhost:8080/stream.mjpeg
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from camera_api import CameraAPI  # noqa: E402

SHOW = "--show" in sys.argv


def main() -> int:
    cam = CameraAPI()
    cam.wait_until_ready()

    display = None
    if SHOW:
        try:
            import cv2  # noqa: F401
            import numpy as np  # noqa: F401
            display = cv2
        except ImportError:
            print("opencv-python and numpy are needed for --show; falling back to stats only.")

    # A preview does not need capture-quality frames.
    cam.set_stream_settings(fps=30, quality=0.7, max_width=960)

    frames = 0
    total_bytes = 0
    started = time.monotonic()
    last_report = started

    print("Streaming — Ctrl-C to stop.")
    try:
        for jpeg in cam.stream_mjpeg():
            frames += 1
            total_bytes += len(jpeg)

            if display is not None:
                import numpy as np
                image = display.imdecode(np.frombuffer(jpeg, np.uint8), display.IMREAD_COLOR)
                if image is not None:
                    display.imshow("iphone", image)
                    if display.waitKey(1) == 27:  # Esc
                        break

            now = time.monotonic()
            if now - last_report >= 1.0:
                elapsed = now - started
                print(f"\r{frames} frames · {frames / elapsed:5.1f} fps · "
                      f"{total_bytes / elapsed / 1e6:5.2f} MB/s · "
                      f"{total_bytes / frames / 1024:.0f} KB/frame", end="")
                sys.stdout.flush()
                last_report = now
    except KeyboardInterrupt:
        pass
    finally:
        if display is not None:
            display.destroyAllWindows()

    elapsed = time.monotonic() - started
    print(f"\n{frames} frames in {elapsed:.1f}s ({frames / elapsed:.1f} fps average)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
