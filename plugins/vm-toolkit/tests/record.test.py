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

    caption = [sys.executable, os.path.join(VM, "record.py"), "caption", "Look here"]
    p = subprocess.run(caption, env=env, capture_output=True, text=True)
    check("a silent caption once a line was spoken says nothing more", "silent" in p.stdout, False)
    kept = open(events).read()
    open(events, "w").close()
    p = subprocess.run(caption, env=env, capture_output=True, text=True)
    check("a silent caption in a recording with no line yet asks for narration", (p.returncode, "--say" in p.stdout),
          (0, True))
    open(events, "w").write(kept)

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

# Pace: what the video keeps, on frames of 2000 samples (LOOSE: 10 of them) and a clock in seconds.
SAMPLES = 2000
BASE = bytes(record.STRIDE * SAMPLES)


def frame(*changed):
    b = bytearray(BASE)
    for i in changed:
        b[i * record.STRIDE] = 1
    return bytes(b)


class Run:
    """Frames and events fed to a Pace at 15 fps, from t; cut() tells which moments it cut."""

    def __init__(self, still_s=3.0):
        self.pace, self.evs, self.t = record.Pace(0.0, still_s), [], 0.0

    def event(self, **ev):
        self.evs.append(dict(ev, t=self.t))

    def feed(self, seconds, frames):
        """Feed for seconds, frames(i) the i-th; the moments cut, as (time, cut) pairs."""
        out, i = [], 0
        end = self.t + seconds
        while self.t < end - 1e-9:
            out.append((round(self.t, 3), self.pace.cut(self.t, frames(i), len(self.evs), lambda: list(self.evs))))
            self.t += 1 / 15
            i += 1
        return out


def first_cut(moments):
    return next((t for t, c in moments if c), None)


still = frame()
r = Run()
m = r.feed(5, lambda i: still)
check("a still screen is kept 3 s, then cut", 3.0 < first_cut(m) < 3.3, True)
check("and cut from then on", all(c for t, c in m if t > 3.3), True)
check("a change ends the cut, on its own frame", r.feed(0.1, lambda i: frame(*range(20)))[0][1], False)
r = Run()
m = r.feed(6, lambda i: frame(1, 2) if i % 7 < 3 else still)
check("a blinking caret (under 5 samples) is a still screen", 3.0 < first_cut(m) < 3.4, True)
r = Run()
r.feed(4, lambda i: still)
m = r.feed(4, lambda i: frame(*range(8)))
check("a small change that happens once (a tooltip, a tick) is kept, then its own 3 s",
      (m[0][1], 3.0 < first_cut(m) - m[0][0] < 3.3), (False, True))
r = Run()
anim = [frame(), frame(*range(6)), frame(*range(3, 9))]
m = r.feed(6, lambda i: anim[i % 3])
check("a small animation that never stops (RDM's Quick start) is a still screen", 3.0 < first_cut(m) < 3.6, True)
r = Run()
m = r.feed(6, lambda i: frame(*range(i // 2)))
check("a small change that keeps going (a progress bar) is kept as it goes", first_cut(m), None)
r = Run()
r.event(caption="", audio_s=4.0)
m = r.feed(6, lambda i: still)
check("a line is never cut, nor its beat (0.6 s) after it", 4.6 < first_cut(m) < 4.8, True)
r = Run()
r.feed(4, lambda i: still)
r.event(caption="The app hangs: 10 s", keep=True)
m = r.feed(10, lambda i: still)
check("a caption with keep keeps a still screen while it shows (a hang)", first_cut(m), None)
r.event(caption="")
m = r.feed(4, lambda i: still)
check("until the next caption: then the still screen is cut again", 3.0 < first_cut(m) - m[0][0] < 3.3, True)
r = Run()
r.event(caption="Waiting", seconds=5, keep=True)
m = r.feed(10, lambda i: still)
check("a keep with seconds ends with them", 8.0 < first_cut(m) < 8.3, True)
r = Run()
r.feed(5, lambda i: still)
r.event(input="click")
check("an event ends the cut (a click, a key, a caption)", r.feed(0.1, lambda i: still)[0][1], False)
check("VM_RECORD_STILL_S=0 keeps everything", first_cut(Run(0).feed(10, lambda i: still)), None)

print("record: " + ("all passed" if not fails else f"{fails} failed"))
sys.exit(1 if fails else 0)
