#!/usr/bin/env python3
"""Record an episode with everything needed to align it to external telemetry.

    python3 timed_episode.py [seconds] [outdir]

Produces, for each episode:

    video.mov          the recording
    timing.json        clock syncs, the PTS anchor, per-frame times, drop counts
    sha256.txt         checksum of the video

The phone copy is deleted only after the download is verified and ffprobe agrees
with what the API reported. Until then it is the only copy.
"""

import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from camera_api import CameraAPI, frame_times  # noqa: E402

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
OUTDIR = sys.argv[2] if len(sys.argv) > 2 else "episodes"


def ffprobe_frame_pts(path):
    """Per-frame presentation times from the file, relative to its own zero.

    Reads *packets*, not frames. `-show_entries frame=` decodes, and the decoder
    does not flush its last picture, so it returns one timestamp fewer than the
    file holds. Packets carry the complete set; frame_times() sorts them, since
    packets arrive in decode order when the stream has B-frames.
    """
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "packet=pts_time", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line for line in out.split() if line and line != "N/A"]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    cam = CameraAPI(usbmux=True, timeout=120)
    cam.wait_until_ready()

    # Short GOP so training can seek to a random frame cheaply.
    status = cam.configure(width=1920, height=1080, fps=60, codec="h264",
                           audio=False, key_frame_interval=12,
                           allow_frame_reordering=False)
    config = status["session"]["config"]
    print(f"configured {config['width']}x{config['height']} @ {config['fps']:g} fps, "
          f"keyframe every {config['keyFrameInterval']} frames")

    # Let AE/AF settle, then pin everything so takes are comparable.
    time.sleep(1.5)
    controls = cam.lock_everything(converge=True)
    print(f"locked: lens {controls['lensPosition']:.3f}, "
          f"1/{1 / controls['exposureDurationSeconds']:.0f}s, ISO {controls['iso']:.0f}")

    sync_before = cam.sync_clock(samples=20)
    print(f"clock offset {sync_before['offset']:+.6f}s "
          f"+/- {sync_before['uncertainty'] * 1e3:.3f}ms")

    started = cam.start_recording(name="episode")
    # start_recording returns when the request is handled; the first frame comes
    # later. Poll until the anchor exists so t=0 is a real frame, not a request.
    anchor = None
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        progress = cam.recording_progress()
        if progress and progress.get("firstVideoPTSSeconds") is not None:
            anchor = progress["firstVideoPTSSeconds"]
            break
        time.sleep(0.02)
    if anchor is None:
        cam.stop_recording()
        print("no frame arrived after starting the recording", file=sys.stderr)
        return 1
    print(f"first frame at capture clock {anchor:.6f} "
          f"(local {anchor - sync_before['offset']:.6f})")

    time.sleep(SECONDS)
    meta = cam.stop_recording(timeout=120)
    sync_after = cam.sync_clock(samples=20)

    timing = meta["timing"]
    drops = timing["captureDrops"] + timing["writerBackpressureDrops"] + timing["appendFailures"]
    print(f"captured {meta['durationSeconds']:.3f}s, {meta['framesWritten']} frames, "
          f"{drops} dropped ({timing['captureDrops']} capture / "
          f"{timing['writerBackpressureDrops']} backpressure / {timing['appendFailures']} append)")
    print(f"drift {CameraAPI.drift_ppm(sync_before, sync_after):+.1f} ppm over the episode")

    if timing["interruptions"]:
        print(f"WARNING: {len(timing['interruptions'])} interruption(s) — footage has gaps:")
        for entry in timing["interruptions"]:
            print(f"  {entry['reason']} at capture clock {entry['captureClockSeconds']:.3f}")

    # Download into a .partial directory; promote only once validated.
    episode = os.path.join(OUTDIR, meta["name"] + "_" + meta["id"][:8])
    staging = episode + ".partial"
    os.makedirs(staging, exist_ok=True)
    video = os.path.join(staging, "video." + meta["container"])

    cam.download(meta["id"], video)
    print(f"downloaded {os.path.getsize(video) / 1e6:.1f} MB")

    file_pts = ffprobe_frame_pts(video)
    if len(file_pts) != meta["framesWritten"]:
        print(f"WARNING: the file holds {len(file_pts)} packets but the API reported "
              f"{meta['framesWritten']} frames", file=sys.stderr)

    with open(os.path.join(staging, "timing.json"), "w") as handle:
        json.dump({
            "recording": meta,
            "clock_sync_before": sync_before,
            "clock_sync_after": sync_after,
            "drift_ppm": CameraAPI.drift_ppm(sync_before, sync_after),
            "frame_pts_capture_clock": frame_times(meta, file_pts),
            "frame_time_local": frame_times(meta, file_pts, sync_before),
        }, handle, indent=2)

    checksum = sha256(video)
    with open(os.path.join(staging, "sha256.txt"), "w") as handle:
        handle.write(f"{checksum}  video.{meta['container']}\n")

    os.replace(staging, episode)
    print(f"finalised {episode}")

    # Only now is the phone copy redundant.
    cam.delete(meta["id"])
    print("phone copy deleted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
