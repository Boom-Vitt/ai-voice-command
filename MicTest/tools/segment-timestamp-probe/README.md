# Segment-timestamp probe

A throwaway diagnostic, kept because its logs are the only evidence behind a rule the app now
relies on. It is **not part of the MicTest build**: `MicTest/build.sh` compiles
`Sources/MicTest/*.swift` only, and nothing in this directory is on that path.

The analysis written from these logs is `../../TEST-2026-08-31-seam-rerun.md`, under
"`covered=0.0s` vs `12.0s`: RESOLVED". This file covers the artifacts themselves — how they
were produced, what is in them, and where they stop short.

## The question

`TEST-2026-08-30.md:137` recorded a single trace line —
`partial-lag: covered=12.0s wall=14.4s lag=2.4s segs=8` — and read it as "th-TH does report
segment timestamps". Every round that followed disagreed. Across the three preserved traces —
`../../TEST-2026-08-30-run4-trace.txt` (39 `partial-lag` lines) and the run5 and run6 traces
(70 each) — all **179** say `covered=0.0s` and not one reports a non-zero.
`TEST-2026-08-30-seam.md:446` carried the contradiction as unexplained.

`covered` is `segments.last.timestamp + segments.last.duration`. Either the recogniser reports
segment timestamps for th-TH or it does not, and one line disagreed with 179.

Deciding it by hand was not practical: the app only reaches this code with a live microphone
and a human talking. So the probe reproduces the app's exact recogniser configuration —
`SFSpeechAudioBufferRecognitionRequest`, th-TH, `requiresOnDeviceRecognition = true`,
`addsPunctuation`, `.dictation` hint, a 20-term `contextualStrings` glossary, fed from
1024-frame chunks at 48 kHz mono float32 — and then varies **one thing at a time** around it,
17 conditions in all, so that whatever explains the zeros can be named rather than guessed at.

## The finding

> **Non-zero segment timestamps appear only on a result with
> `result.speechRecognitionMetadata != nil`.**

Stated one-way deliberately: that direction is proven over all 882 callbacks, the converse
over 107. See the first bullet under "What this does not establish".

Measured over **882 callbacks (865 partial, 17 final) across 17 conditions** on macOS 26.5.1
(build 25F80). Exactly **18** callbacks reported a non-zero `covered`, and all 18 carry
`meta=true`.

- On **continuous speech** every partial reports `timestamp=0, duration=0` for every segment,
  so `covered` is 0.0 s however high `segs` climbs. C1 reaches `segs=42` still at `0.000`.
- A **pause** produces an end-of-utterance endpoint: exactly ONE metadata-bearing *non-final*
  result, ~1.8–2.5 s after speech stops, carrying real timestamps. Partials reset to zero
  after it.
- It is **not locale-specific and not flag-specific.** The zeros reproduce on th-TH and en-US,
  buffer and URL request, paced and unpaced, and with or without punctuation, task hint and
  `contextualStrings`. C6 (`shouldReportPartialResults = false`) is not part of that list: it
  delivered 1 callback and 0 partials, so it has nothing to say about partial zeros. What it
  does show is that the final still arrives with metadata and real timestamps when partials
  are switched off.
- It is **not** "partials zero, finals real". In L4, L7, L17, C10 and C11 the final is *empty*
  — `segs=1 covered=0.000 chars=0 meta=false` — while the endpointed *partial* carried the
  whole transcript. Anyone reading these logs will trip on that; it is the expected shape.

### Endpoint lag, all five endpoint events

The lag between the end of speech and the metadata-bearing partial, across every condition
that produced one:

| speech | condition | log | `covered` | `wall` | lag |
|---|---|---|---|---|---|
| 4 s  | `L4`        | sweep | 4.050s  | 6.1s  | 2.05s |
| 7 s  | `L7`        | sweep | 6.990s  | 9.5s  | 2.51s |
| 8 s  | `C12`       | pause | 8.010s  | 10.2s | 2.19s |
| 12 s | `C10`,`C11` | pause | 11.970s | 14.3s | 2.33s |
| 17 s | `L17`       | sweep | 17.010s | 18.8s | 1.79s |

`covered` tracks the speech length to within 50 ms while the lag stays in a 1.79–2.51 s band
with **no trend across n = 5** — the 17 s case has the *smallest* lag. That is what an
endpoint timeout looks like, and it is the reason the original line's 2.4 s is not treated as
a coincidence of that one run.

Two cautions on this table, because it is easy to misread:

- The `for L in [4.0, 7.0, 17.0]` sweep in `probe.swift` is only rows 1, 2 and 5. The 8 s and
  12 s rows come from the **pause** conditions, which are differently shaped clips.
- `C12` is 8 s speech + 6 s silence + 8 s speech, so its 8.010 s point is the endpoint of the
  **first** island, not of a single utterance.

An earlier draft of `TEST-2026-08-31-seam-rerun.md` merged these two experiments into a single
four-row "length sweep", dropping `L7` and presenting `C12` and `C10` as sweep points. That
report now carries the same five rows with the source of each named, so the two tables agree.

### Why the app's own runs never see a timestamp

The seam harness feeds `../../testdata/thai-continuous.txt`, which that fixture's README says
is *"deliberately written with no sentence-final punctuation and no paragraph breaks, because
`say` inserts a pause at every one of them"*. No pauses means no endpoints, which means no
metadata, which means `covered=0.0s` **by construction**. The fixture was built to eliminate
the one thing that produces a timestamp.

### The probe is measuring the same thing the app is

C1's per-callback segment counts are
`1, 3, 5, 9, 12, 16, 19, 20, 23, 26, 28, 32, 34, 38, 41, 41`.
The app's own `segs=` sequence in `../../TEST-2026-08-30-run4-trace.txt` opens with those same
16 values before its 20 s session rotation resets the count to 1. Same recogniser, same audio,
same growth — so the probe's zeros are the app's zeros and not an artifact of the harness.

## What these logs do NOT prove

- **Only one direction of the "⟺" is closed.** *Non-zero ⟹ metadata* is proven across all 882
  callbacks: a non-zero `covered` unconditionally forces a log line, the per-condition
  `callbacksWithNonZeroCovered` counters sum to 18, and all 18 logged non-zero lines say
  `meta=true`. The converse is **not** equally established. `meta` is not one of the logging
  triggers (`isFinal || covered != 0 || cb#1 || once per second`) and the probe keeps no
  metadata counter, so a metadata-bearing partial with `covered=0` could have gone unlogged.
  A per-callback line carries `meta=`, and only **107 of the 882 callbacks** produced one
  (38 full / 39 pause / 30 sweep; `grep -cE "meta=(true|false)" segprobe_*.log`). Match the
  VALUE, not the bare key: the C9 redaction marker quotes `meta=` in its own prose, so a
  plain `grep -c "meta="` returns 39 for the full log and 108 overall — the same
  counting-non-callback-lines mistake that produced the retracted 124. Within those 107 the two
  sets coincide exactly — 18 `meta=true`, 89 `meta=false`, no counterexample — but beyond them
  the reverse direction is unmeasured. An earlier draft of this file said 124, which counted
  the 17 `recognizer: available=` header lines as callbacks.
- **The "server" conditions could not be shown to have used a server.** With
  `requiresOnDeviceRecognition = false`, C2 and C2u returned a final in `wall=0.3s` for a 20 s
  clip with text byte-identical to the on-device runs — macOS 26.5.1 appears to have served
  them on-device anyway. That leg is **untested, not passed**. Do not cite it as evidence that
  off-device behaves the same.
- **The original `covered=12.0s` line cannot be shown to have taken this path.** Its raw trace
  never survived; it exists only as a hand-copied line at `TEST-2026-08-30.md:137`. The probe
  proves the endpoint path exists and reproduces its three numbers; it cannot prove that line
  took it.
- **`segs=8` does not match.** The original reported 8 segments over 12 s (1.5 s/seg); the
  probe's endpointed partial reported 24 over the same 12 s (0.5 s/seg). Timing matches,
  granularity does not. Most likely a slower human speaker with fewer words — unverified.
- **The probe is not fully reproducible as preserved.** The English control text was spoken
  into `/tmp/eng.aiff` and never written down. All that survives of it is what the recogniser
  made of it, and the logs truncate transcripts at 160 characters — so even that is only the
  first 160 of a 341-character recognition, not the source. `eng.aiff` cannot be regenerated exactly; the
  en-US conditions (C7, C8) can be re-run only with substitute English audio.

## Build and run

Run from an **interactive terminal**: macOS shows a TCC dialog that a non-interactive session
cannot surface. The commands below are reconstructed from the preserved artifacts — the
original build script was not kept — and are known to match the signed bundle that produced
these logs, with one exception noted in step 2.

### 1. Prepare the audio

```bash
say -v Kanya -o /tmp/thai.aiff -f MicTest/testdata/thai-continuous.txt
say -v Samantha -o /tmp/eng.aiff "<any ~20 s of English prose>"
```

The Thai side is the tracked fixture and reproduces exactly. The English side does **not**: the
original text was never saved, and the only trace of it is a *recognised* transcript truncated
at 160 characters, which is recogniser output rather than the source. Any ~20 s of English
speech will do for C7 and C8 — just do not expect their transcripts to match the logs.

### 2. Build and sign an `.app` bundle

```bash
swiftc -O probe.swift -o segprobe
mkdir -p SegProbe.app/Contents/MacOS
cp probe.plist    SegProbe.app/Contents/Info.plist
cp segprobe       SegProbe.app/Contents/MacOS/segprobe
codesign --force --sign 06A6DF4F3FF0A89E2B74786D7C36220260ACA82E SegProbe.app
```

A **bundle** is required rather than a bare CLI binary — see "TCC" below. The signing identity
is the same Developer ID `MicTest/build.sh` uses (team `59CAS739TY`); ad-hoc signing gives a
cdhash-based designated requirement, so the speech-recognition grant is discarded on every
rebuild and re-prompts.

One difference from the bundle that produced these logs: `probe.plist` carries `LSUIElement`,
and the Info.plist inside the signed `SegProbe.app` had 8 keys without it. The probe therefore
ran with a Dock icon. Nothing in the measurement depends on it.

### 3. Configure and run

Configuration comes from `/tmp/segprobe.cfg`, one `KEY=VALUE` per line — **not** the
environment. `open --env` produced an environment that AppKit's own startup path trapped on,
and the probe needs no environment at all.

```bash
cat > /tmp/segprobe.cfg <<'EOF'
PROBE_LOG=/tmp/segprobe_full.log
PROBE_THAI=/tmp/thai.aiff
PROBE_ENG=/tmp/eng.aiff
PROBE_SECONDS=20
PROBE_ONLY=C3,C1,C1u,C2,C2u,C4,C5,C6,C7,C8,C9
EOF
open -W -n SegProbe.app
```

`PROBE_ONLY` selects conditions by id; leave it empty to run all 17. The three preserved logs
were three consecutive runs — the ids above, then `C10,C11,C12`, then `L4,L7,L17`.

Click **Allow** on the speech-recognition dialog on first run. Output goes to `PROBE_LOG`; the
app is launched with `open`, so stdout is redirected to that file and nothing appears in the
terminal.

## Two things that cost time

**TCC.** A bare CLI binary is refused speech-recognition authorization; a signed `.app` bundle
launched with `open` is granted it. What is *unresolved* is the middle option. The tracked
`experiments/README.md` states that linking the plist into a bare binary with
`-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist` **does**
satisfy TCC, and gives the working `swiftc` line for `thaiASR`. The session that built this
probe recorded the opposite conclusion, that `-sectcreate` does not satisfy it — but that
claim survives in no preserved artifact here, and the evidence in the bundle is neutral:
neither `probeauth` (the bare CLI that failed) nor the `segprobe` binary inside `SegProbe.app`
carries a `__TEXT,__info_plist` section at all. So the failing attempt was genuinely bare, the
successful one used an external `Contents/Info.plist`, and the `-sectcreate` variant was
simply never tried on this probe. Treat `experiments/README.md` as the tested path until
someone re-tests it here.

**The main queue.** Speech delivers `recognitionTask(with:resultHandler:)` callbacks on the
**main queue**. Blocking the main thread on a semaphore deadlocks before the first partial
ever arrives — measured: the log stopped dead after `recognizer: available=true` and the
process hung. `probe.swift` therefore runs the matrix on a detached thread and leaves
`RunLoop.main` pumping.

## Files

| file | |
|---|---|
| `probe.swift` | the probe: 17 conditions, clip construction, per-callback logging |
| `probe.plist` | the Info.plist the bundle needs; `NSSpeechRecognitionUsageDescription` is the load-bearing key |
| `segprobe_full.log` | C3, C1, C1u, C2, C2u, C4, C5, C6, C7, C8, C9 — the 11 continuous-speech conditions on a 20 s clip. Establishes that the zeros are not caused by locale, request type, on-device, pacing, or any flag. All 11 finals carry metadata and real timestamps. |
| `segprobe_pause.log` | C10, C11, C12 — the pause conditions, and the ones that answer the question. C10 (12 s speech + digital silence) and C11 (12 s + low noise) each produce one metadata-bearing partial at `covered=11.970s`, then an empty final. C12 (8 s + silence + 8 s) endpoints mid-clip at `8.010s` and then carries a real final at `22.140s`. |
| `segprobe_sweep.log` | L4, L7, L17 — the length sweep, showing the lag does not track utterance length. |
| `auth.swift`, `authlog.swift` | standalone authorization helpers used to get the TCC grant settled before the matrix was run. `authlog.swift` is `auth.swift` with output redirected to a file and a 60 s rather than 25 s wait, for the `open`-launched bundle case. Neither is needed to reproduce the measurement. |

Not preserved, deliberately: the compiled `SegProbe.app`, `segprobe` and `probeauth` binaries;
the patch scripts and diff used to edit the app during the same session; and a superseded
`segprobe.log` from a C3-only run whose content is a strict subset of `segprobe_full.log`.

## Recognised speech in these logs

Unlike the repo's `*-trace.txt` files, which record character *counts*, these logs contain
recognised **transcripts**. All of it is synthetic voice reading tracked or generic material:
the Thai is `say -v Kanya` reading `../../testdata/thai-continuous.txt`, whose README notes it
"contains nothing personal"; the English is a pangram plus sentences describing the probe.

One line looked alarming and was not, and it has been **redacted anyway**. C9 feeds the
**Thai** audio to an **en-US** recogniser on purpose, to separate locale from audio content.
The result is phonetic nonsense that happens to contain name-shaped tokens and one
crude-sounding phrase — a machine mis-transcription of the tracked fixture, not content anyone
spoke, and not a privacy issue.

It was redacted regardless, at `segprobe_full.log:300`, on a cost/benefit the reader should be
able to check: that `text(...)` line carries **none** of C9's evidence — the finding lives
entirely in the `segs=`, `covered=`, `meta=` and `SUMMARY` lines around it, all of which are
intact — while committing it would put the string in git history permanently. Nothing else in
any log is altered; this is the only redaction, and the line names itself as one.
