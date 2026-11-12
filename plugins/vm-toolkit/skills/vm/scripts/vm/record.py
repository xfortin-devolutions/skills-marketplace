#!/usr/bin/env python3
"""Record the VM's screen as an MP4, with the clicks circled and an agent's captions on it.

  record.py run OUT.mp4 MAX_SECONDS   record until SIGTERM or MAX_SECONDS (guest.sh starts it in the background)
  record.py caption TEXT [SECONDS]    show TEXT from now on: until the next caption, or for SECONDS ("" clears it)

The frames come from QEMU's second QMP socket (REC_SOCK, <run dir>/rec.sock): the first serves one client at a time,
so a recorder holding it would hold back every click and keystroke until it stopped. Each frame is a PPM screendump
(about 8 ms; a PNG takes 200), piped to ffmpeg at a fixed rate and encoded as it comes by the Mac's hardware H.264
encoder. While it runs, <run dir>/recording names the events file captions and vm.py's clicks go to; once it stops,
the captions and click rings (drawn by overlay.js with AppKit: this ffmpeg has no text filter) go over the raw video.
"""
import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vm  # noqa: E402

FPS = 15
RING = 56
HERE = os.path.dirname(os.path.abspath(__file__))
RUN_DIR = os.environ.get("VM_RUN_DIR") or vm.VM_HOME


def say(s):
    print(f"record: {s}", file=sys.stderr, flush=True)


def ffmpeg(*args):
    return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args])


def record(out, max_s):
    raw, events = out + ".raw.mp4", out + ".events"
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    vm.SOCK = os.environ.get("REC_SOCK") or os.path.join(RUN_DIR, "rec.sock")
    try:
        q = vm.Qmp()
    except OSError:
        say("this VM was started without the recorder's QMP socket: vmt down and up again to record")
        return 1
    ff = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "image2pipe", "-c:v", "ppm",
                           "-framerate", str(FPS), "-i", "-", "-c:v", "h264_videotoolbox",
                           "-q:v", "70", "-pix_fmt", "yuv420p", raw], stdin=subprocess.PIPE)
    frame = out + ".ppm"
    t0 = time.time()
    open(events, "w").close()
    with open(vm.RECORDING, "w") as f:
        f.write(f"{t0}\n{events}\n")
    n = 0
    try:
        while not stop and time.time() - t0 < max_s:
            try:
                q.cmd("screendump", {"filename": frame, "format": "ppm"})
                with open(frame, "rb") as f:
                    data = f.read()
                if n == 0:
                    width = int(data.split(b"\n", 2)[1].split()[0])  # PPM: P6, then "width height"
                # Frame k shows second k/FPS: a grab that ran late fills the frames it missed, so the video keeps the
                # events' clock (ffmpeg's own timestamps start when it has read enough to probe, late).
                k = max(n + 1, round((time.time() - t0) * FPS))
                for _ in range(k - n):
                    ff.stdin.write(data)
            except (OSError, RuntimeError, ValueError):
                break  # the VM went down (vmt down, the idle reaper, a checkpoint): keep what was recorded
            n = k
            wait = t0 + n / FPS - time.time()
            if wait > 0:
                time.sleep(wait)
    finally:
        for p in (vm.RECORDING, frame):
            if os.path.exists(p):
                os.remove(p)
        ff.stdin.close()
        ff.wait()
    secs = n / FPS
    if ff.returncode != 0 or n == 0:
        say(f"ffmpeg failed (exit {ff.returncode}) after {n} frames")
        return 1
    rc = compose(raw, events, out, secs, width)
    if rc == 0:
        os.remove(raw)
        print(f"{out} {secs:.0f}s, {os.path.getsize(out) // 1024} KB")
    return rc


def overlay(*args):
    """An overlay image (overlay.js); False when AppKit could not draw it (the video then goes without it)."""
    p = subprocess.run(["osascript", "-l", "JavaScript", os.path.join(HERE, "overlay.js"), *args],
                       capture_output=True, text=True)
    if p.returncode != 0:
        say(f"could not draw a {args[0]}: {p.stderr.strip()}")
    return p.returncode == 0


def compose(raw, events_path, out, secs, w):
    """The raw video with its captions and click rings over it, re-encoded small."""
    evs = [json.loads(line) for line in open(events_path) if line.strip()]
    caps = [e for e in evs if "caption" in e]
    clicks = [e for e in evs if "click" in e]
    inputs, chain, last = [], [], "0:v"
    work = out + ".overlays"
    os.makedirs(work, exist_ok=True)
    for i, c in enumerate(caps):
        end = caps[i + 1]["t"] if i + 1 < len(caps) else secs
        if c.get("seconds"):
            end = min(end, c["t"] + c["seconds"])
        if not c["caption"].strip() or end <= c["t"]:
            continue
        png = os.path.join(work, f"caption-{i}.png")
        if not overlay("caption", png, str(w), c["caption"]):
            continue
        inputs += ["-i", png]
        k = len(inputs) // 2
        chain.append(f"[{last}][{k}:v]overlay=x=(W-w)/2:y=H-h-64:enable='between(t,{c['t']},{end})'[v{k}]")
        last = f"v{k}"
    png = os.path.join(work, "ring.png")
    if clicks and overlay("ring", png, str(RING)):
        inputs += ["-i", png]
        ring = len(inputs) // 2
        for j, c in enumerate(clicks):
            x, y = c["click"]
            chain.append(f"[{last}][{ring}:v]overlay=x={x - RING // 2}:y={y - RING // 2}:"
                         f"enable='between(t,{c['t']},{c['t'] + 0.7})'[c{j}]")
            last = f"c{j}"
    args = ["-i", raw, *inputs]
    if chain:
        script = os.path.join(work, "filter.txt")
        with open(script, "w") as f:
            f.write(";\n".join(chain))
        args += ["-filter_complex_script", script, "-map", f"[{last}]"]
    # x264 for the kept video: a desktop that barely moves takes a fifth of what the hardware encoder makes of it.
    args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]
    rc = ffmpeg(*args).returncode
    for f in os.listdir(work):
        os.remove(os.path.join(work, f))
    os.rmdir(work)
    os.remove(events_path)
    if rc != 0:
        say(f"could not put the captions and clicks on the video (ffmpeg exit {rc}); the raw one is {raw}")
    return rc


def main():
    op, a = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if op == "run" and len(a) == 2:
        return record(os.path.abspath(a[0]), float(a[1]))
    if op == "caption" and len(a) in (1, 2):
        ev = {"caption": a[0]}
        if len(a) == 2:
            ev["seconds"] = float(a[1])
        if not vm.add_event(ev):
            say("nothing is recording: app record start first")
            return 1
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
