#!/usr/bin/env python3
"""Record the VM's screen as an MP4, with the clicks circled and an agent's captions and highlights on it.

  record.py run OUT.mp4 MAX_SECONDS   record until SIGTERM or MAX_SECONDS (guest.sh starts it in the background)
  record.py caption TEXT [SECONDS] [--highlight REGION]... [--no-dim] [--say SPEECH]
                                      show TEXT from now on: until the next caption, or for SECONDS ("" clears it),
                                      and those regions highlighted (highlight.py's) as long, or until the next click
                                      (the screen changes); an empty TEXT with regions highlights without words;
                                      --say speaks SPEECH (the narration voice, below) from now, and returns just before it ends,
                                      so the next step lands on its last words

On a VM with no QMP (tart's macOS VMs) the frames come from its own connection to the VM's VNC server (vnc.py), and
only what changed crosses it. Otherwise they come from QEMU's second QMP socket (REC_SOCK, <run dir>/rec.sock): the first serves one client at a time,
so a recorder holding it would hold back every click and keystroke until it stopped. Each frame is a PPM screendump
(about 8 ms; a PNG takes 200), piped to ffmpeg at a fixed rate and encoded as it comes by the Mac's hardware H.264
encoder. While it runs, <run dir>/recording names the events file captions and vm.py's clicks go to; once it stops,
the captions and click rings (drawn by overlay.js with AppKit: this ffmpeg has no text filter) go over the raw video.
A still screen longer than VM_RECORD_STILL_S (default 3; 0 keeps everything) is cut, so an agent's slow step (a vm_run,
its own thinking) is not dead air in the demo: a caption or a click counts as a change, so each new one stays readable.
Narration is never cut. Once a recording has any, a still screen is cut to VOICE_BEAT_S, and so is the wait after a
line until the next step (moving or not): a person narrating pauses a beat, not for the next line to be written.

The voice is Kokoro's once vmt voice setup has installed it (vm/kokoro.py; VM_VOICE), else macOS's say, far more
robotic. VM_TTS replaces both: a command with {text} and {out} (a WAV) in it.
"""
import json
import os
import shlex
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import highlight  # noqa: E402
import vm  # noqa: E402

FPS = 15
RING = 56
HIGHLIGHT_AFTER_CLICK = 0.5  # seconds a highlight stays after a click in it
STILL_S = float(os.environ.get("VM_RECORD_STILL_S") or 3)
VOICE_BEAT_S = 0.6  # the pause a narrated recording keeps after a line
VOICE_LEAD_S = 0.5  # caption --say returns this long before its speech ends: the next click falls on its last words
VOICE = os.path.join(os.environ.get("VM_ROOT") or os.path.dirname(vm.VM_HOME), "voice", "venv", "bin", "python")
STRIDE = 97  # bytes between the samples two frames are compared on (prime: they fall on every column over the rows)
HERE = os.path.dirname(os.path.abspath(__file__))
RUN_DIR = os.environ.get("VM_RUN_DIR") or vm.VM_HOME


def say(s):
    print(f"record: {s}", file=sys.stderr, flush=True)


def ffmpeg(*args):
    return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args])


def still(a, b):
    """Whether frame b shows what a did: equal, or under 5 of its samples differ (a blinking caret, a clock's tick)."""
    if a is None or a == b:
        return a is not None
    return sum(x != y for x, y in zip(a[::STRIDE], b[::STRIDE])) < 5


def shift(cuts):
    """Time in the cut video of a moment of the recording (seconds from its start): cuts are (start, end) pairs."""
    return lambda t: t - sum(min(max(t - s, 0), e - s) for s, e in cuts)


def record(out, max_s):
    raw, events = out + ".raw.mp4", out + ".events"
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    vm.SOCK = os.environ.get("REC_SOCK") or os.path.join(RUN_DIR, "rec.sock")
    try:
        q = vm.connect()
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
    cut, cuts = 0.0, []  # seconds cut so far; when (from the start, wall clock)
    prev, since, seen, last = None, None, 0, t0
    voiced, speaking, hush = False, t0, None  # narrated at all; until when the voice speaks; the beat after it ends
    try:
        # A stop while the voice speaks (the agent stops right after its last line) waits for the line, and a beat.
        while (not stop or time.time() < speaking + VOICE_BEAT_S) and time.time() - t0 < max_s:
            try:
                q.cmd("screendump", {"filename": frame, "format": "ppm"})
                with open(frame, "rb") as f:
                    data = f.read()
                if n == 0:
                    width, height = map(int, data.split(b"\n", 2)[1].split()[:2])  # PPM: P6, then "width height"
                now, size = time.time(), os.path.getsize(events)
                if size != seen:
                    for line in open(events).read().splitlines():
                        ev = json.loads(line) if line.strip() else {}
                        if ev.get("audio_s"):
                            voiced, speaking = True, max(speaking, t0 + ev["t"] + ev["audio_s"])
                            hush = speaking + VOICE_BEAT_S
                        else:
                            hush = None
                if size == seen and still(prev, data) and now >= speaking:
                    since = since or now
                else:
                    prev, since, seen = data, None, size
                limit = VOICE_BEAT_S if voiced else STILL_S
                # After a line, until the next step, the agent is only writing (and the voice rendering) the next one:
                # cut by the events, not the pixels, which an animation on the screen would keep moving.
                if STILL_S and (since and now - since > limit or hush and now > hush and size == seen):
                    if cuts and cuts[-1][1] == last - t0:
                        cuts[-1] = (cuts[-1][0], now - t0)
                    else:
                        cuts.append((last - t0, now - t0))
                    cut += now - last
                    last = now
                    time.sleep(1 / FPS)
                    continue
                # Frame k shows second k/FPS of the video, the recording's clock less the cuts: a grab that ran late
                # fills the frames it missed (ffmpeg's own timestamps start when it has read enough to probe, late).
                k = max(n + 1, round((now - t0 - cut) * FPS))
                for _ in range(k - n):
                    ff.stdin.write(data)
            except (OSError, RuntimeError, ValueError):
                break  # the VM went down (vmt down, the idle reaper, a checkpoint): keep what was recorded
            n, last = k, now
            wait = t0 + cut + n / FPS - time.time()
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
    rc = compose(raw, events, out, secs, (width, height), shift(cuts))
    if rc == 0:
        os.remove(raw)
        print(f"{out} {secs:.0f}s, {os.path.getsize(out) // 1024} KB" + (f" ({cut:.0f}s of still screen cut)" if cut >= 1 else ""))
    return rc


def overlay(*args):
    """An overlay image (overlay.js); False when AppKit could not draw it (the video then goes without it)."""
    p = subprocess.run(["osascript", "-l", "JavaScript", os.path.join(HERE, "overlay.js"), *args],
                       capture_output=True, text=True)
    if p.returncode != 0:
        say(f"could not draw a {args[0]}: {p.stderr.strip()}")
    return p.returncode == 0


def speak(text, out):
    """text spoken into the WAV out by the narration voice; its length in seconds, or None when it could not be."""
    if os.environ.get("VM_TTS"):
        tts = shlex.split(os.environ["VM_TTS"])
    elif os.path.exists(VOICE):
        tts = [VOICE, os.path.join(HERE, "kokoro.py"), "{out}", "{text}"]
    else:
        tts = ["say", "-o", "{out}", "--data-format=LEI16@24000", "{text}"]
    cmd = [w.replace("{text}", text).replace("{out}", out) for w in tts]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0 or not os.path.exists(out):
        say(f"could not speak ({tts[0]} exit {p.returncode}): {p.stderr.strip()[-300:]}")
        return None
    d = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out],
                       capture_output=True, text=True).stdout.strip()
    return float(d) if d else None


def compose(raw, events_path, out, secs, size, at=lambda t: t):
    """The raw video with its highlights, captions and click rings over it (in that order: a caption or a click is never
    dimmed), re-encoded small; size is the screen's (width, height), at(t) an event's time in the video."""
    evs = [json.loads(line) for line in open(events_path) if line.strip()]
    for e in evs:
        if e.get("seconds"):
            e["until"] = at(e["t"] + e["seconds"])
        e["t"] = round(at(e["t"]), 2)
    caps = [e for e in evs if "caption" in e]
    voice = [e for e in caps if e.get("audio")]
    clicks = [e for e in evs if "click" in e]
    for i, c in enumerate(caps):  # a caption, and its highlight, last until the next one (or its seconds)
        c["end"] = caps[i + 1]["t"] if i + 1 < len(caps) else secs
        if c.get("seconds"):
            c["end"] = min(c["end"], c["until"])
    w = size[0]
    inputs, chain, last = [], [], "0:v"
    work = out + ".overlays"
    os.makedirs(work, exist_ok=True)
    for i, c in enumerate(caps):
        if not c.get("highlight") or c["end"] <= c["t"]:
            continue
        # A click changes the screen the highlight points at (a dialog opens): it ends just after the first one, so
        # its ring shows in it and the box never outlines what is no longer there.
        end = min([c["end"]] + [e["t"] + HIGHLIGHT_AFTER_CLICK for e in clicks if c["t"] <= e["t"] < c["end"]])
        png = os.path.join(work, f"highlight-{i}.png")
        if not highlight.draw(png, *size, c["highlight"], c.get("dim", True)):
            continue
        inputs += ["-i", png]
        k = len(inputs) // 2
        chain.append(f"[{last}][{k}:v]overlay=format=yuv444:enable='between(t,{c['t']},{end})'[h{k}]")
        last = f"h{k}"
    for i, c in enumerate(caps):
        end = c["end"]
        if not c["caption"].strip() or end <= c["t"]:
            continue
        png = os.path.join(work, f"caption-{i}.png")
        if not overlay("caption", png, str(w), c["caption"]):
            continue
        inputs += ["-i", png]
        k = len(inputs) // 2
        chain.append(f"[{last}][{k}:v]overlay=format=yuv444:x=(W-w)/2:y=H-h-64:enable='between(t,{c['t']},{end})'[v{k}]")
        last = f"v{k}"
    png = os.path.join(work, "ring.png")
    if clicks and overlay("ring", png, str(RING)):
        inputs += ["-i", png]
        ring = len(inputs) // 2
        for j, c in enumerate(clicks):
            x, y = c["click"]
            chain.append(f"[{last}][{ring}:v]overlay=format=yuv444:x={x - RING // 2}:y={y - RING // 2}:"
                         f"enable='between(t,{c['t']},{c['t'] + 0.7})'[c{j}]")
            last = f"c{j}"
    # The video every player plays (yuv420p) keeps one colour per 2x2 pixels: the screen's own colour detail (ClearType
    # text, a thin outline) would smear. Twice the size, each pixel a 2x2 block, it loses none, and a Retina screen shows
    # it pixel for pixel instead of stretching it; about 3 times the bytes. The overlays go on in full colour (yuv444)
    # before that: ffmpeg's default, 4:2:0, would halve each one's.
    chain.append(f"[{last}]scale=iw*2:ih*2:flags=neighbor[out]")
    first = len(inputs) // 2 + 1
    for j, e in enumerate(voice):
        inputs += ["-i", e["audio"]]
        ms = int(e["t"] * 1000)
        chain.append(f"[{first + j}:a]aresample=48000,adelay={ms}:all=1[a{j}]")
    if voice:
        chain.append("".join(f"[a{j}]" for j in range(len(voice))) + f"amix=inputs={len(voice)}:normalize=0,apad[aout]")
    script = os.path.join(work, "filter.txt")
    with open(script, "w") as f:
        f.write(";\n".join(chain))
    args = ["-i", raw, *inputs, "-filter_complex_script", script, "-map", "[out]"]
    if voice:
        args += ["-map", "[aout]", "-c:a", "aac", "-b:a", "96k", "-t", f"{secs:.2f}"]
    # x264 for the kept video: a desktop that barely moves takes a fifth of what the hardware encoder makes of it.
    args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]
    rc = ffmpeg(*args).returncode
    for f in os.listdir(work):
        os.remove(os.path.join(work, f))
    os.rmdir(work)
    os.remove(events_path)
    for e in voice:
        if os.path.exists(e["audio"]):
            os.remove(e["audio"])
    if rc != 0:
        say(f"could not put the highlights, captions and clicks on the video (ffmpeg exit {rc}); the raw one is {raw}")
    return rc


def main():
    op, a = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if op == "run" and len(a) == 2:
        return record(os.path.abspath(a[0]), float(a[1]))
    if op == "caption":
        regions, dim, rest, speech = [], True, [], ""
        try:
            while a:
                x = a.pop(0)
                if x == "--no-dim":
                    dim = False
                elif x == "--say" and a:
                    speech = a.pop(0)
                elif x == "--highlight" and a:
                    regions += highlight.parse([a.pop(0)])[0]
                else:
                    rest.append(x)
            if len(rest) not in (1, 2):
                raise ValueError("record.py caption TEXT [SECONDS] [--highlight REGION]... [--no-dim]")
            ev = {"caption": rest[0]}
            if len(rest) == 2:
                ev["seconds"] = float(rest[1])
        except ValueError as e:
            say(str(e))
            return 2
        if regions:
            ev["highlight"], ev["dim"] = regions, dim
        if not os.path.exists(vm.RECORDING):
            say("nothing is recording: app record start first")
            return 1
        if speech.strip():
            events = open(vm.RECORDING).read().split("\n")[1].strip()
            clip = f"{events}.voice-{time.time():.3f}.wav"
            seconds = speak(speech, clip)
            if seconds:
                ev["audio"], ev["audio_s"] = clip, round(seconds, 2)
        if not vm.add_event(ev):
            say("nothing is recording: app record start first")
            return 1
        if ev.get("audio_s"):
            vm.pause(max(ev["audio_s"] - VOICE_LEAD_S, 0))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
