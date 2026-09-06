# Test fixtures

## `thai-continuous.txt`

Continuous Thai prose, deliberately written with **no sentence-final punctuation and no
paragraph breaks**, because `say` inserts a pause at every one of them and a pause landing on
the 20 s session rotation is exactly the case the seam test must avoid: it would produce
`+0 chars` for a reason that has nothing to do with the code under test.

Rendered through `say -v Kanya` it is ~134 s of unbroken speech, which covers a 90 s capture
(four seams at 20/40/60/80 s) without `SyntheticAudioSource` ever having to loop.

Used by the seam measurement in `../TEST-2026-08-30-seam.md`:

```bash
say -v Kanya -o /tmp/thai.aiff -f MicTest/testdata/thai-continuous.txt
pkill -9 -f "MicTest.app/Contents/MacOS/MicTest"; : > /tmp/mictest_trace.txt
open -W -n -g --env MICTEST_AUTOSTART=1 --env MICTEST_AUTOSTART_HOLD=90 \
     --env MICTEST_AUDIO_FILE=/tmp/thai.aiff -a ~/Desktop/MicTest.app
grep -nE "rotation:|replay:|SYNTH:|FINAL:" /tmp/mictest_trace.txt
```

The text is ordinary everyday prose (weather, a walk, a market, a trip) chosen so that a
misrecognition is obvious to a Thai reader at a glance. It contains nothing personal.

## `thai-english-continuous.txt`

Eight short **Thai+English code-switched** sentences, one per line, each ending in a full stop.
The intent is the opposite of the seam fixture above: a real pause after every sentence, so
`AudioPipeline` finalises one chunk per sentence and the correction pass gets one utterance
each. The English is the app's glossary plus the word the user reported as failing (`time`) and
one the 2026-09-03 measurements could not fix on this voice (`commit`; `check` is deliberately
absent — see `TEST-2026-09-03-oog-english.txt`). Line 8 is a pure-Thai control. The file is its
own reference transcript, which is why the pause markers below are injected at render time and
not stored here.

**Do not render this file as-is.** Measured 2026-09-03: `say -v Kanya` pauses only **~0.32 s**
at a full stop (`silencedetect`, −50 dB, matching the pipeline's RMS floor of 0.0025 ≈ −52 dBFS),
under the 0.6 s `finalSilenceSeconds`, so a plain render yields **zero** per-sentence finals and
the run tests nothing while looking fine. Inject an explicit silence instead:

```bash
sed 's/\.$/. [[slnc 900]]/' MicTest/testdata/thai-english-continuous.txt > /tmp/thai-en-slnc.txt
say -v Kanya -o /tmp/thai-en.aiff -f /tmp/thai-en-slnc.txt      # ~49 s, 8 gaps of ~1.1 s
ffmpeg -i /tmp/thai-en.aiff -af silencedetect=noise=-50dB:d=0.6 -f null - 2>&1 | grep -c silence_end   # expect 8
# then the harness recipe from TEST-2026-09-03-local-correction.md with MICTEST_AUDIO_FILE=/tmp/thai-en.aiff
```

Same caveat as above, louder: this is a Thai TTS voice reading English words. `commit` came
out as `เกิมี` on every engine from it. A misrecognition here says nothing about a human until
the same lines are recorded in a real voice (`python3 -m thaiasr record` in `thaiasr/`).
