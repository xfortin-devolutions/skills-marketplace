#!/bin/bash
# voice.sh: the narration voice for recordings (record.py caption --say), Kokoro in <VM root>/voice/.
#   voice.sh setup        installs it once (~350 MB): its own Python (uv) with kokoro-onnx, and the model and voices
#   voice.sh try <text>   speaks the text with VM_VOICE (default af_heart) on this Mac, to choose one
# Without it, a recording speaks with macOS's say (far more robotic). VM_TTS overrides both (record.py). bash 3.2.
set -eu
X=$(cd "$(dirname "$0")" && pwd)
D=${VM_ROOT:?}/voice
URL=https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0
MODEL_SHA=7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5
VOICES_SHA=bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d

fetch() {  # fetch <file> <sha256>
  if [ -f "$D/$1" ] && [ "$(shasum -a 256 "$D/$1" | cut -d' ' -f1)" = "$2" ]; then return; fi
  echo "downloading $1"
  curl -fL --progress-bar -o "$D/$1.part" "$URL/$1"
  [ "$(shasum -a 256 "$D/$1.part" | cut -d' ' -f1)" = "$2" ] || { rm -f "$D/$1.part"; echo "voice: $1 does not match its checksum" >&2; exit 1; }
  mv "$D/$1.part" "$D/$1"
}

case "${1:-}" in
  setup)
    command -v uv > /dev/null || { echo "voice: needs uv for its Python (3.10 or later): brew install uv" >&2; exit 1; }
    mkdir -p "$D"
    [ -x "$D/venv/bin/python" ] || uv venv -q -p 3.12 "$D/venv"
    VIRTUAL_ENV=$D/venv uv pip install -q kokoro-onnx==0.6.1 soundfile==0.14.0
    fetch kokoro-v1.0.onnx "$MODEL_SHA"
    fetch voices-v1.0.bin "$VOICES_SHA"
    "$D/venv/bin/python" "$X/kokoro.py" "$D/check.wav" "Ready." && rm -f "$D/check.wav"
    echo "voice ready in $D: recordings speak with Kokoro's ${VM_VOICE:-af_heart} (VM_VOICE)" ;;
  try)
    [ $# -ge 2 ] || { sed -n '2,5p' "$0" >&2; exit 2; }
    [ -x "$D/venv/bin/python" ] || { echo "voice: not set up: vmt voice setup" >&2; exit 1; }
    out=$(mktemp -t vmt-voice).wav
    "$D/venv/bin/python" "$X/kokoro.py" "$out" "$2"
    afplay "$out"; rm -f "$out" ;;
  *) sed -n '2,5p' "$0" >&2; exit 2 ;;
esac
