#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# WHAT: Render the audio acceptance's speech corpus with macOS's own voices: seven standard voices
#       reading eight fixed sentences each, one AIFF an utterance, into <out>/speech/.
# IN:   --out <folder> (required). A voice this Mac does not have is skipped and named.
# OUT:  <out>/speech/<voice>_<n>.aiff, mono 22.05 kHz 16-bit, a line per voice on stderr. Measured
#       2026-11-08: 56 utterances of 7.9 to 10.6 s, one under the speech profile's 8 s admission.
# PIN:  The voices and the sentences are fixed here, before any acceptance number: Samantha,
#       Daniel, Fred, Karen, Moira, Rishi, Tessa; sentences 1 to 8 below, unchanged once measured.
#       `say` renders through the system's speech engine, so a macOS update may change the samples;
#       the acceptance's report names the date it ran.
#
#   Scripts/audio-corpus.sh --out "$VEILGARDE_WORK_AREA/audio/corpus"
#
set -euo pipefail

out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        *) echo "audio-corpus: unknown argument $1" >&2; exit 64 ;;
    esac
done
[ -n "$out" ] || { echo "audio-corpus: --out <folder> is required" >&2; exit 64; }
mkdir -p "$out/speech"

voices=(Samantha Daniel Fred Karen Moira Rishi Tessa)
sentences=(
    "The river carried the last of the autumn leaves past the old mill, where a heron stood in the shallows and waited for the light to change before it moved again."
    "Every morning the baker opened the shutters at six, set the first loaves on the counter, and wrote the day's soup on a small slate beside the door for anyone passing."
    "The train left the coast an hour late, climbed slowly through the hills in the rain, and reached the city just as the street lamps came on along the wide avenue."
    "She tuned the piano by ear, one string at a time, listening for the slow beat between two notes to fade until the chord rang clear across the empty hall."
    "Four friends rented a small boat for the weekend, argued about the map for most of the morning, and finally found the island by following a line of gulls."
    "The library kept its oldest maps in a cool room downstairs, and a visitor could ask to see them on Thursday afternoons if they promised to wear the cotton gloves."
    "A storm crossed the valley before dawn, knocked out the power for two hours, and left the orchard covered in small green apples that the children gathered in baskets."
    "In the workshop the clockmaker laid out every gear on a soft cloth, cleaned each one with a fine brush, and then put the whole movement back together without a pause."
)

for voice in "${voices[@]}"; do
    if ! say -v '?' | grep -q "^${voice}[[:space:]]"; then
        echo "audio-corpus: no voice ${voice} on this Mac, skipped" >&2
        continue
    fi
    n=1
    for sentence in "${sentences[@]}"; do
        say -v "$voice" -o "$out/speech/$(echo "$voice" | tr 'A-Z' 'a-z')_${n}.aiff" "$sentence"
        n=$((n + 1))
    done
    echo "audio-corpus: ${voice}: ${#sentences[@]} utterances" >&2
done
echo "audio-corpus: $(ls "$out/speech" | grep -c '\.aiff$') utterances in $out/speech" >&2
