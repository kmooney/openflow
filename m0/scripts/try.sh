#!/bin/bash
# Hands-on push-to-talk loop. Speak -> Enter -> see the same words in every
# register, with the one you picked on your clipboard.
#
# A terminal standing in for the global hotkey, so you can judge latency and
# the null-vs-rules-vs-tone question before we build the Mac app.
#
#   ./scripts/try.sh                      formal on the clipboard
#   ./scripts/try.sh --tone very-casual   very casual on the clipboard
#   ./scripts/try.sh --model base.en      faster, less accurate
#   ./scripts/try.sh --file audio/x.wav   replay a clip instead of recording
#   ./scripts/try.sh --list               show input devices
set -uo pipefail
cd "$(dirname "$0")/.."

MODEL=${MODEL:-small.en}
DEV=${DEV:-:default}
MAX=${MAX:-120}
TONE=${TONE:-formal}
FILE=""
BIN=whisper.cpp/build/bin/whisper-cli
FMT=../target/release/of-fmt
VOCAB=${VOCAB:-vocab.txt}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$2; shift 2;;
    --tone)  TONE=$2;  shift 2;;
    --file)  FILE=$2;  shift 2;;
    --vocab) VOCAB=$2; shift 2;;
    --no-vocab) VOCAB=""; shift;;
    --list)  ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/audio devices/,$p'; exit 0;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done
MPATH=whisper.cpp/models/ggml-$MODEL.bin

[ -f "$MPATH" ] || { echo "no model at $MPATH"; exit 1; }
[ -x "$FMT" ]   || { echo "build it first: (cd formatter && cargo build --release)"; exit 1; }

# Whisper's initial prompt biases decoding toward these spellings. It is a
# STYLE prime as well as a vocabulary prime: a bare comma list makes the model
# drop punctuation, so the hint is phrased as a punctuated sentence.
build_prompt() {
  [ -n "$VOCAB" ] && [ -f "$VOCAB" ] || return 0
  local words
  words=$(grep -v '^[[:space:]]*#' "$VOCAB" | grep -v '^[[:space:]]*$' \
          | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  [ -n "$words" ] && printf 'The following names may appear in this recording: %s.' "$words"
}

show() {
  local wav=$1 log=/tmp/of-try.$$.log raw prompt
  prompt=$(build_prompt)
  raw=$("$BIN" -m "$MPATH" -f "$wav" -t 8 -nt ${prompt:+--prompt "$prompt"} 2>"$log" \
        | grep -v '^[[:space:]]*$' | sed 's/^ *//' | tr '\n' ' ' | sed 's/ *$//')
  if [ -z "$raw" ]; then echo "  (heard nothing)"; rm -f "$log"; return; fi
  python3 scripts/show.py "$raw" "$TONE" "$FMT" "$log"
  rm -f "$log"
}

if [ -n "$FILE" ]; then show "$FILE"; exit 0; fi

mkdir -p audio/try
vcount=0
[ -n "$VOCAB" ] && [ -f "$VOCAB" ] && vcount=$(grep -cv '^[[:space:]]*\(#\|$\)' "$VOCAB")
echo "model: $MODEL   device: $DEV   clipboard gets: $TONE   vocab: $vcount words ($VOCAB)"
echo "Press ENTER to start talking, ENTER again to stop. Ctrl-C to quit."
echo "(First run, macOS asks your terminal for Microphone permission.)"
n=0
while true; do
  read -r -p $'\n> ready ' _ || break
  n=$((n+1)); wav="audio/try/take-$n.wav"
  ffmpeg -hide_banner -loglevel error -f avfoundation -i "$DEV" \
         -ar 16000 -ac 1 -t "$MAX" -y "$wav" </dev/null >/dev/null 2>&1 &
  pid=$!
  if ! kill -0 $pid 2>/dev/null; then echo "  mic failed — try --list"; continue; fi
  read -r -p "  ● recording… ENTER to stop " _
  kill -INT $pid 2>/dev/null; wait $pid 2>/dev/null
  [ -s "$wav" ] || { echo "  (no audio captured)"; continue; }
  show "$wav"
done
