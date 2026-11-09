# VeilGardeAudio: the watermark on sound

This target carries VeilGarde's watermark to audio. A clip is drawn as its spectrogram, and `Watermark.sign` signs that picture unchanged. Nothing is written into the sound. The picture goes back to sound through the exact inverse transform.

These notes direct the research. **For now the research is speech protection only.** Music results are held as observations and are not being pursued.

Status on 2026-11-08, when the work was closed for the day:

| Question | Answer today |
|---|---|
| Does v1 on sound pass its acceptance on speech, with today's matcher? | No. Killed: 30.8% of cuts found with their offset, under the 60% bar |
| Does it pass when the matcher reads the grid at every frame? | Yes, as an experiment: every cut found at its exact column, 85% recall at 0.86 with no false match |
| …and with quarter-hop offsets of the cut too? | Yes, as an experiment on 20 clips: median cut score 0.974, 90% recall at 0.95 with no false match |
| Has the shipped default changed? | No. The matcher reads four phases until the owner picks a proposal |
| Do the macOS voices leave a synthesis step the residual can see? | No. 0 of 56 utterances at 8 ms resolution; only prosody |
| Does a recorded human voice differ from a generated one? | Not measured. There is no recorded speech yet |

## What exists

- **The speech profile.** 16 kHz mono, 1024-sample frames every 256, a picture 512 rows tall, 16 tile rows. One tile is 512 ms by 500 Hz. A half cut of a 9 s utterance holds 320 to 564 bits.
- **The picture.** Each bin's magnitude as one of 256 grey levels on a fixed scale from −96 to 0 dBFS, the highest bin in the top row, in the 8-bit bitmap the lens already reads. The exact inverse returns the sound at 129 to 130 dB SNR; from the 8-bit picture alone, a median of 43 dB on speech.
- **The acceptance** (`veilgarde audio accept`), mirrored from the image watermark's with the same kill criterion: a half-length cut at a random sample, an AAC re-encode, a cross match against the next clip. `--phases 0,1,…,31` reads the grid at every frame. `--sub-hop 4` also tries the cut at quarter-hop offsets and keeps the best.
- **The time-phase study** (`veilgarde audio phases`). The fragility read at every time phase as a trace dense in time, the residual's slope per picture column beside it, sections of 0.5 to 2 s compared with the whole clip, and the traces' spectra read for time steps. Rules are fixed before a run in a `rules.md`, and `judge.py` reads every hypothesis row off the reports.
- **The corpus.** `Scripts/audio-corpus.sh` renders 56 utterances: seven macOS voices reading eight fixed sentences. One fixture, `say_samantha_12s.wav`, is pinned in the tests.

## Phase 1: the carrier

v1 on speech was killed by its acceptance, 39 utterances, seed 0:

| Measure | Result | Bar |
|---|---|---|
| Self-match | 100% | 100% |
| A half cut matched with its offset | 30.8% | at least 60% |
| AAC at 64 kb/s, median score | 0.907 | at least 0.75 |
| Best recall at any threshold | 69.2% | 80% at most 5% false |
| False matches at 0.75 | 0% | at most 5% |

What held: every cut that started on a tile boundary matched, 39 of 39. Gain of −6 dB and 16-bit requantization matched on every utterance. What failed: cuts landed between the matcher's four grid phases, every 8 frames apart; cuts 1 to 4 frames off matched 1 of 23. White noise at 30 dB broke the signature on 33 of 39 utterances. Speed changes matched none.

## Phase 2: the time phases

**The study.** On all 56 utterances at quarter hop, a column every 4 ms: no time step between 8 and 20 ms, 0 of 56; one unconfirmed line at 8 ms; every line above the bar was prosodic, 211 to 1986 ms. The AAC frame left no step in 16 re-encodes. No utterance had a recurring section. These voices leave no synthesis step the residual can see at this resolution.

**The matcher.** The first fallback named before phase 1, a finer time-phase search, was measured with the kill criterion unchanged:

| Search | Clips | Cut found with its offset | Cut score, median | False at 0.75 | Operating point |
|---|---|---|---|---|---|
| 4 phases, today's default | 39 | 30.8% | 0.712 | 0% | 80% recall not reached |
| A: 32 phases | 39 | 100% | 0.911 | 2 of 39 | 0.86: recall 85%, false 0% |
| B: 32 phases × quarter hops | 20 | 100% | 0.974 | 2 of 20 | 0.95: recall 90%, false 0% |

The prediction written before A held. B's median cut score rose 0.063 over A, past the 0.05 rule set beforehand, so the sub-hop shift matters. Cost per clip: 2 s today, 5 s for A, 18 s for B.

**The controls.** A click train every quarter second is found under the music profile, 5 of 5. Under the speech profile its line stands at z 19 to 22 in every clip, but the rule wants both the second and third harmonic, and it confirms 1 of 5. Noise and silence show nothing.

## What the numbers do not cover

Read the passes narrowly:

- **One synthetic corpus.** Seven classic macOS voices, clean, no room, no microphone. No recorded human speech, and no neural voice.
- **Few clips.** 39 and 20. With 20 strangers, a false-match rate of 2 in 20 at 0.75 could be anywhere from about 1% to 30%.
- **Few bits.** A half cut carries a few hundred bits; a stranger's median score is 0.71.
- **Clean cuts.** The cuts come from the same decoded samples. Noise, rooms, phone codecs and re-recording were not part of the passing runs, and in phase 1 noise at 30 dB broke 33 of 39.

## Where speech protection goes next

In order, each with its rule written before it runs:

1. **Choose the proposal.** A is cheap and passes; B is sharper and slower. The owner decides; the default does not move until then (ledger decision-150).
2. **Record real speech.** A `veilgarde audio record` command, raw PCM from the default input, through one of the two AVFoundation doors, and a corpus of recorded voices reading the same sentences (ledger question-33). This is what the generated-against-recorded question needs.
3. **A bigger, harder corpus.** Hundreds of clips from many speakers, so false matches are measured on more than 40 strangers.
4. **Speech's real transforms.** Noise at 10 to 30 dB, room reverberation, a speaker-to-microphone re-recording, telephone bandwidth and codecs (8 kHz narrowband, Opus, AMR), speed and pitch. Noise is the first: it broke phase 1.
5. **More bits per second.** Speech pictures hold 16 tile rows; a short clip is thin. A profile with more rows, or a matcher that pools several cuts, is a proposal to measure, not a change.
6. **The theory.** A neural voice beside the classic ones and beside recorded speech, through `audio phases` at quarter or eighth hop.
7. **Instrument fixes**, for the study's third pass: confirm a line by any two of its first three harmonics, so the click train under speech passes; widen the harmonic tolerance with the line's width.

## Returning to it

```sh
# the carrier's tests, with the GPU; the pins hold the three clips exactly
VEILGARDE_MLX_TESTS=1 Scripts/test.sh --filter VeilGardeAudioTests

W=$VEILGARDE_WORK_AREA
export VEILGARDE_CONFIG=release
# the speech corpus, if the work area lacks it
Scripts/audio-corpus.sh --out $W/audio/corpus
# experiment A and B, the kill criterion unchanged
Scripts/cli.sh audio accept --audio $W/audio/corpus/speech --profile speech --segment 0 --n 40 --seed 0 --phases $(seq -s, 0 31) --out $W/audio/accept_speech_phases32_n40.json
Scripts/cli.sh audio accept --audio $W/audio/corpus/speech --profile speech --segment 0 --n 20 --seed 0 --phases $(seq -s, 0 31) --sub-hop 4 --out $W/audio/accept_speech_phases32_subhop4_n20.json
# the time-phase study on speech, and its judge
Scripts/cli.sh audio phases --audio $W/audio/corpus/speech --profile speech --sub-hop 4 --out $W/research/audio-phases-<date>/s
python3 -I $W/research/audio-phases-20261108/judge.py $W/research/audio-phases-<date>
```

The 2026-11-08 record: the reports under `<work area>/audio/` and `<work area>/research/audio-phases-20261108/` (`rules.md`, `summary.md`, `judge.py`), the site's chapter 11 and trails AR, AM and AT, and the ledger's amendments 29 to 32, decisions 137 to 151 and commands 123 to 143. One MLX workload at a time: check `ioreg -r -c AGXDeviceUserClient -l` before a long run.

## Music, held

Under the music profile phase 1 was killed by false matches between neighbouring seconds of one track. The time-phase study found the beat as the dominant step in every segment of three masters, and no step under 20 ms. The finer search was not run on music. None of this is pursued while speech is the focus.

## Where the code lives

| Folder | Holds |
|---|---|
| `Audio/` | the clip; the two doors, `AudioFiles.swift` and `AudioConverting.swift`, the only files that import AVFoundation; the transforms |
| `Spectrogram/` | the two profiles, the analysis signal, the framing, the transform and its inverse, the grey mapping, the picture, the lag finder |
| `Watermark/` | sign and match through the image watermark, the time phases, the round trips |
| `Acceptance/` | synthetic clips, the corpus sample, the acceptance and its kill criterion |
| `Research/` | the time-phase study: the trace, the section recurrence, the periodicity scan, the study's rows and reports |
