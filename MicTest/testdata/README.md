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
