#!/usr/bin/env python3
"""record.test.py: vm/record.py's narration, without a VM: caption --say renders through VM_TTS (a fake that makes a
tone), notes the clip on the recording's events and waits for it; compose lays the clips on the video as one audio
track, at their captions' times. Needs ffmpeg.
  python3 -I tests/record.test.py
"""

import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
VM = os.path.join(HERE, "..", "skills", "vm", "scripts", "vm")
fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += not ok
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f": got {got!r}, want {want!r}"))


def probe(path, entry):
    return subprocess.run(["ffprobe", "-v", "error", "-show_entries", entry, "-of", "csv=p=0", path],
                          capture_output=True, text=True).stdout.split()


with tempfile.TemporaryDirectory() as run:
    env = dict(os.environ, VM_RUN_DIR=run, VM_HOME=run, VM_ROOT=run,
               VM_TTS="ffmpeg -loglevel error -y -f lavfi -i sine=frequency=440:duration=1.5 {out}")
    events = os.path.join(run, "video-1.mp4.events")
    open(events, "w").close()
    with open(os.path.join(run, "recording"), "w") as f:
        f.write(f"{time.time() - 2}\n{events}\n")

    t = time.time()
    p = subprocess.run([sys.executable, os.path.join(VM, "record.py"), "caption", "", "--say", "So, let's hit Connect."],
                       env=env, capture_output=True, text=True)
    waited = time.time() - t
    ev = json.loads(open(events).read().splitlines()[0])
    check("caption --say succeeds", p.returncode, 0)
    check("its event carries the clip and its length", (os.path.exists(ev["audio"]), ev["audio_s"]), (True, 1.5))
    check("it returns just before the line ends (1.5 s less the lead)", 0.9 < waited < 2.5, True)

    env["VM_TTS"] = "false {out} {text}"
    p = subprocess.run([sys.executable, os.path.join(VM, "record.py"), "caption", "Still a caption", "--say", "Hi"],
                       env=env, capture_output=True, text=True)
    ev2 = json.loads(open(events).read().splitlines()[1])
    check("a voice that fails still captions, silently", (p.returncode, "audio" in ev2, "could not speak" in p.stderr),
          (0, False, True))

    # compose: a 4 s video, the clip from 1 s (no caption text, no click: nothing for AppKit to draw)
    raw = os.path.join(run, "raw.mp4")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=gray:size=320x180:rate=15:duration=4",
                    "-pix_fmt", "yuv420p", raw], check=True)
    with open(events, "w") as f:
        f.write(json.dumps({"caption": "", "audio": ev["audio"], "audio_s": 1.5, "t": 1.0}) + "\n")
    sys.path.insert(0, VM)
    os.environ.update(VM_RUN_DIR=run, VM_HOME=run)
    import record  # noqa: E402
    out = os.path.join(run, "video-1.mp4")
    check("compose succeeds", record.compose(raw, events, out, 4.0, (320, 180)), 0)
    check("the video has a video and an audio track", probe(out, "stream=codec_type"), ["video", "audio"])
    check("the audio runs as long as the video", abs(float(probe(out, "format=duration")[0]) - 4.0) < 0.15, True)
    vol = subprocess.run(["ffmpeg", "-i", out, "-af", "atrim=0:0.9,volumedetect", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    check("silent before the line's time", "max_volume: -91" in vol, True)
    check("the clip is removed once on the video", os.path.exists(ev["audio"]), False)

print("record: " + ("all passed" if not fails else f"{fails} failed"))
sys.exit(1 if fails else 0)
