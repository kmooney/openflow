#!/bin/sh
# Synthetic clips via macOS `say`. VALID for latency/RTF measurement.
# NOT valid for WER or "is raw output good enough" — synthetic speech has no
# natural hesitation, no false starts, and a TTS voice reading "um" is not the
# same signal as a person actually hesitating. Those numbers need real audio.
set -e
cd "$(dirname "$0")/.."
V=${VOICE:-Samantha}
mk() { say -v "$V" -o "audio/$1.wav" --data-format=LEI16@16000 "$2"; }

mk s05 "Let's ship the new auth flow today. I'll write the migration and you review it."

mk s10 "The deploy failed on the third node because the config map wasn't updated. \
I think we should roll back to the previous release, verify the health checks, \
and try again after lunch."

mk s20 "Okay, notes from the architecture review. We agreed the driver contract \
should be stable before anything else ships, because changing it later breaks \
other people's code. The formatter runs on the client wherever the device can \
carry it, and the server is only a fallback. Two open items remain: how we \
handle model downloads on first run, and whether the console needs a graph."

mk s30 "Here's the summary of yesterday's incident. At about two fifteen in the \
afternoon the primary database started returning connection errors. The on call \
engineer paged the platform team within four minutes, which is well inside our \
target. Root cause was a connection pool exhaustion caused by a slow query that \
had been deployed the previous evening. We rolled back that change, connections \
recovered immediately, and total customer impact was roughly eleven minutes. \
Follow up items are to add a query timeout, alert on pool saturation, and add a \
load test that would have caught this before release."

mk disfluent "Um, so, the the deploy failed and uh I think we should roll back. \
Um, the config map wasn't updated on the third node. New paragraph. \
Let's verify the health checks first and uh try again after lunch."
