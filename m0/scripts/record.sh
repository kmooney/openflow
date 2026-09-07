#!/bin/sh
# Capture real dictation for the M0 quality questions.
#
# Synthetic `say` audio measures latency fine, but it cannot answer "is raw
# Whisper output good enough to send unedited" -- that depends on natural
# hesitation, false starts, and self-correction, which TTS does not produce.
# So these have to be spoken, not read. SPEAK, don't read a script: the point
# is the disfluency.
set -e
cd "$(dirname "$0")/.."
mkdir -p audio/real
DEV=${DEV:-:default}
SECS=${SECS:-30}

prompt() {
  echo
  echo "  [$1]  $2"
  echo "  Recording ${SECS}s in 2s... speak naturally, don't rehearse. Ctrl-C to skip."
  ffmpeg -hide_banner -loglevel error -f avfoundation -i "$DEV" \
         -ar 16000 -ac 1 -t "$SECS" -y "audio/real/$1.wav" </dev/null || true
  echo "  -> audio/real/$1.wav"
}

echo "Recording ${SECS}s clips. List input devices with:"
echo "  ffmpeg -f avfoundation -list_devices true -i \"\" 2>&1 | grep -A9 audio"
echo "Override with: DEV=':1' SECS=20 ./scripts/record.sh"

prompt 01-standup   "What did you work on yesterday, and what's blocking you today?"
prompt 02-explain   "Explain OpenFlow's driver contract to a colleague, out loud."
prompt 03-email     "Dictate an email asking someone to review a pull request."
prompt 04-list      "Describe three things you'd fix about your current setup."
prompt 05-correct   "Tell a short story and deliberately correct yourself mid-sentence."
prompt 06-technical "Describe a bug you debugged recently, with specifics."

echo
echo "Done. Now run:  python3 scripts/bench.py 3   (picks up audio/real/ too)"
