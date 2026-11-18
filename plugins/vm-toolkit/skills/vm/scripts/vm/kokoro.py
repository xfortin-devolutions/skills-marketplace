#!/usr/bin/env python3
"""Speech for a recording's narration with Kokoro (Apache 2.0, offline): run by the voice's own Python (voice.sh setup).

  kokoro.py OUT.wav TEXT   OUT is TEXT spoken in VM_VOICE (default af_heart) at VM_VOICE_SPEED (default 1.0)

The model and its voices are in <VM root>/voice/ (VM_ROOT). Punctuation shapes the delivery: commas and an ellipsis are
pauses, a question rises.
"""
import os
import sys

import soundfile
from kokoro_onnx import Kokoro


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    d = os.path.join(os.environ.get("VM_ROOT") or os.path.expanduser("~/VMs/factory"), "voice")
    k = Kokoro(os.path.join(d, "kokoro-v1.0.onnx"), os.path.join(d, "voices-v1.0.bin"))
    samples, rate = k.create(sys.argv[2], voice=os.environ.get("VM_VOICE") or "af_heart",
                             speed=float(os.environ.get("VM_VOICE_SPEED") or 1.0), lang="en-us")
    soundfile.write(sys.argv[1], samples, rate)
    return 0


if __name__ == "__main__":
    sys.exit(main())
