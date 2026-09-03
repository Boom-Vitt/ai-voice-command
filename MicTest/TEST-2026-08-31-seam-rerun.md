# Seam re-run on the fixed metric — 2026-08-31

Closes the item `TEST-2026-08-30-seam.md` left outstanding: every `+N` in that report was
measured against a baseline that moved, and the fix (commit `49f7c2d`) was verified by
arithmetic on one surviving trace rather than by a run. This is the run.

Two raw traces preserved verbatim: **`TEST-2026-08-31-run5-trace.txt`** (the measurement this
report is built on) and **`TEST-2026-08-31-run6-trace.txt`** (the signed-delta fix verified on
a run; excluded as a measurement — see "focus drifted again"). Neither contains recognised
text: the app traces lengths and metadata only, confirmed by grepping the Thai codepoint
range in both — **0 lines each**.

---

## Headline

| | |
|---|---|
| Build | **green**, `-swift-version 6 -O -wmo`, rebuilt 13:43 before the run |
| Binary carries the fix | **yes** — `partial at flush` ×3, `last partial len` ×0 |
| Seams observed | **4** (20/40/60/80 s) on one 90.7 s capture |
| Replay carrying real audio | **4 of 4** (0.1 s, 1 buffer each, `residual 0 ms dropped`) |
| Thai typed end to end | **1,317 chars**, `injectFailures=0`, `divergencesRefused=0` |
| Frame accounting | **delta 0** — 4252 buffers × 1024 = 4,354,048 = `frames` exactly |
| Focus integrity | TextEdit frontmost **before and after** (run 5) — but see below: run 5 was clean because nothing else finished during it, not because the precaution is sound. Run 6 drifted and is excluded |
| `covered=0.0s` vs `12.0s` | **RESOLVED** — endpoint/metadata rule, 882 callbacks. One comment wrong as stated, one verdict inert |
| Signed seam delta | **fixed and verified on a run** — a real `-4` now prints as `-4`, was `+0` |
| A **human** speaker across a seam | **still not tested** — synthetic voice, as before |

**The metric fix works as specified.** Both trace lines now quote one latched number, and
movement between flush and final is reported separately, with its sign. Every figure below
is a real measurement rather than a lower bound.

---

## The four seams

`partial at flush` is latched in the same critical section that sets the flush mark and the
replay window. `final` is what the flush returned. The two now describe the same instant.

| Seam | Flush latency | Partial at flush | Final | Headline | **True delta** | Partial moved after flush |
|---|---|---|---|---|---|---|
| 1 — 20 s | 127 ms | 174 | 179 | `+5` | **+5** | +5, to 179 |
| 2 — 40 s | 118 ms | 179 | 173 | `+0` | **−6** | +4, to 183 |
| 3 — 60 s | 121 ms | 185 | 188 | `+3` | **+3** | none |
| 4 — 80 s | 148 ms | 173 | 176 | `+3` | **+3** | +4, to 177 |

Flush latency is tight and consistent: 118–148 ms, four for four.

---

## The finding this run produced: contractions are REAL

Seam 2 returned a final **six characters shorter** than the latched flush baseline
(`final 173 vs partial at flush 179`). The baseline could not have moved — it is latched
under the same lock that stops `append` feeding the request.

This matters because it contradicts an argument made in the fix's own commit message.
`49f7c2d` reasoned:

> `final 183 vs last partial 184` and `final 186 vs last partial 189` are last partials
> LONGER than their finals, **which a retraction does not produce and a moving baseline
> does**.

The *fix* was right and is not in question — run 4's surviving trace proved the baseline
moved, and corrected `+0`/`+5` to `+4`/`+8` arithmetically. But the *supporting claim* — that
a partial longer than its final can only come from a moving baseline — is now falsified by
measurement. With the baseline latched, seam 2 still came back 6 short. **Speech does retract.**
A shrinking final is a real recogniser behaviour, not only a measurement artefact.

The repair path absorbed it without incident. Seam 2's final reconciliation:

```
DIVERGENCE: repaired in place (final reconciliation) —
            kept 90 common chars, replaced 93 stale chars with 83 chars
```

93 characters of already-typed text replaced by 83, `diverged=false`, `injectFailures=0` — the
retraction was absorbed correctly. Nothing is broken here; what changed is what we know.

That repair is an **illustration** of a retraction being absorbed, not corroboration of the
contraction, and it should not be read as the latter. Repair direction does not track seam
delta. Three of the four seams needed a final reconciliation — 2, 3 and 4; only seam 1 did not
— and two of those repairs shortened: seam 2 (93→83) at a true delta of **−6**, but seam 4
as well (67→66) at **+3**, while seam 3 lengthened (175→178) at that same **+3**. The two
quantities are not commensurable in any case: a reconciliation measures already-typed text
against the final, a seam delta measures the final against the latched flush baseline — which
is why seam 2's repair moves −10 where its seam moves −6. The contraction rests on the latched
baseline alone, 173 against 179, and needs nothing else.

### The headline number hid the sign — FIXED, and verified on a run

`+0` was printed for a **−6** seam. `max(0, …)` floored it, so a true no-change seam and a
6-character retraction printed the same headline. The parenthetical made the sign recoverable
by subtraction, exactly as `49f7c2d` intended — but a reader skimming the `+N` column would
misread seam 2, and this report's own table needed a separate "true delta" column to say what
had happened.

The floor is removed. `gained` is now signed, formatted with the same `> 0 ? "+" : ""`
convention the `drift` value five lines below already used — a convention whose own comment
had stated the correct principle all along (*"a negative value is not an error — Speech may
retract as well as extend — so it is reported with its sign rather than clamped away"*). The
file held both the right idea and its contradiction, ten lines apart.

**Verified by a run, not by reading.** A second capture on the rebuilt binary produced a real
contraction and rendered it correctly (raw trace preserved as `TEST-2026-08-31-run6-trace.txt`,
line 115):

```
rotation: flushed final after 161 ms, -4 chars beyond partial at flush (final 185 vs partial at flush 189)
```

Under the old code that line would have read `+0`.

One deliberate consequence: a genuine no-change seam now prints `0 chars`, not `+0`. That is
what makes it distinguishable from a contraction. No documented reproduction recipe greps for
the literal `+0`; the remaining `+0` hits in this directory are preserved historical traces.
The grep string `partial at flush` is unchanged (3 occurrences in the binary).

### That second run was NOT a valid measurement — focus drifted again

Its seam figures are deliberately excluded from the table above, and it is recorded here
because the failure mode matters more than the numbers.

Focus left TextEdit ~11 s into the run. The tell is in the trace at 13:57:21 —
`focused element does not accept AX text replacement`, followed by `IN-PLACE REPAIR DISABLED:
focused app structurally refused it` — where run 5's TextEdit had accepted 27 in-place repairs.
`divergencesRefused=21` (run 5: `0`), `divergencesRepaired=0` (run 5: `27`), and the frontmost
app *after* the run was the Claude desktop app. Up to ~1,179 characters of Thai went into it.

This is the identical failure `TEST-2026-08-30-seam.md` recorded for its run 1 (~541 characters,
`divergencesRefused=5`), and it recurred **despite** a fresh TextEdit document being made
frontmost immediately before launch. The mechanism, now identified: **a background process
completing can surface its window mid-run and take focus.** The precaution in the previous
report — check focus before *and* after — detects the problem but does not prevent it.

**Run 5 was not clean because the precaution worked.** It was clean because nothing else
happened to finish during its 90 s. The same setup, run 25 minutes later with background work
outstanding, failed. Run 5's validity is luck that was checked afterwards, not method — which
is why the caution below is phrased as *quiesce everything first* rather than *set focus first*.

The trace line remains valid evidence for the signed-format fix regardless, because
`Self.trace` is written by the recogniser and does not depend on where text is injected.

---

## `covered=0.0s` vs `12.0s`: RESOLVED

This was carried as "unexplained" by the previous report. It is now settled, by a probe that
reproduced the app's exact recogniser configuration and by the repo's own history. Both lines
of evidence agree.

The imbalance that made it look like a puzzle: across the three traces this repo has actually
preserved there are **179 `partial-lag` lines — 39 + 70 + 70 — and not one carries a non-zero
`covered`**, against the single 12.0 s line reported from a run whose trace did not survive.
(Verify: `grep -c "partial-lag:" TEST-2026-08-30-run4-trace.txt TEST-2026-08-31-run5-trace.txt
TEST-2026-08-31-run6-trace.txt`.) Earlier drafts quoted "141", which decomposed as nothing:
run 5 and run 6 have 70 each, and the truncated runs 1–3 recorded more lines than survive to be
counted. The point is the direction and it is not close.

### The rule, measured

> **Non-zero segment timestamps appear only on a result with
> `result.speechRecognitionMetadata != nil`.**

Stated as a one-way implication on purpose. **The two directions are not equally proven**, and
an earlier draft of this report asserted the biconditional (`⟺`) on evidence that only supports
one half:

- **non-zero ⟹ metadata: holds across all 882 callbacks.** Every non-zero result is
  force-logged, the per-condition counters sum to 18, and all 18 say `meta=true`.
- **metadata ⟹ non-zero: checkable over 107 callbacks, not 882.** `meta` is not itself a logging
  trigger and the probe keeps no metadata counter, so a metadata-bearing partial with
  `covered=0` could have gone unlogged. No such case was seen; none was ruled out either.

The direction this report actually relies on is the first, which is the fully proven one.

Across **882 callbacks / 865 partials**, 17 conditions, macOS 26.5.1.
The probe and its raw logs are preserved under `MicTest/tools/segment-timestamp-probe/` —
`probe.swift` plus `segprobe_full.log`, `segprobe_pause.log` and `segprobe_sweep.log` — so this
rule can be re-derived rather than taken on trust. The per-condition `SUMMARY` lines in those
three logs sum to exactly the figures quoted here: 17 conditions, 882 callbacks, 865 partials.

- On **continuous speech**, every partial reports `timestamp=0, duration=0` for every segment.
  So `covered` is 0.0 s no matter how high `segs` climbs.
- A **pause** produces an end-of-utterance endpoint: exactly ONE metadata-bearing non-final
  result, ~1.8–2.5 s after speech stops, and that one carries real timestamps. After it,
  partials reset to zero.

The probe reproduced the mystery line almost exactly. Original: `covered=12.0s wall=14.4s
lag=2.4s`. Probe, 12 s of speech then silence: **`11.970 / 14.3 / 2.33`**.

`lag` is an endpoint timeout, independent of utterance length — so the 2.4 s was not a
coincidence of that one run. Five endpoints, from two different experiments, and the source of
each is named because an earlier draft of this report silently merged them into one "length
sweep" and dropped a row:

| speech before the endpoint | `covered` | `wall` | `lag` | where from |
|---|---|---|---|---|
| 4 s | 4.050s | 6.1s | 2.05s | sweep, `segprobe_sweep.log:26` |
| 7 s | 6.990s | 9.5s | **2.51s** | sweep, `segprobe_sweep.log:62` |
| 8 s | 8.010s | 10.2s | 2.19s | C12 (8 s / silence / 8 s), first island — `segprobe_pause.log:120` |
| 12 s | 11.970s | 14.3s | 2.33s | C10 and C11, identical — `segprobe_pause.log:38,82` |
| 17 s | 17.010s | 18.8s | **1.79s** | sweep, `segprobe_sweep.log:114` |

The actual sweep in `probe.swift:451` is `for L in [4.0, 7.0, 17.0]` — three points, not four,
and the 8 s and 12 s rows are pause-log conditions rather than sweep points. Spread is
**1.79–2.51 s over n=5, with no trend**: the longest utterance has the *smallest* lag, which is
what "independent of length" should look like and what a monotonic table would have hidden.

**It is not locale-specific, and on-device is not the cause.** The zeros reproduce on th-TH
*and* en-US, on-device *and* nominally off-device, buffer *and* URL request, with and without
punctuation, task hint and contextualStrings, paced and unpaced. Nobody should try switching
locale or disabling on-device to "fix" this — though the off-device leg is untested rather than
passed, for the reason recorded under "What stays unproven" below. It is also *not* "partials
zero, finals real" — a final can carry `meta=false` and `covered=0.000` too.

### Why our runs never see it — the fixture guarantees it

The seam harness feeds `testdata/thai-continuous.txt`, which `testdata/README.md` says is
*"deliberately written with no sentence-final punctuation and no paragraph breaks, because
`say` inserts a pause at every one of them"*. No pauses means no endpoints, which means no
metadata, which means `covered=0.0s` — **by construction**. The fixture was designed to
eliminate the very thing that produces a timestamp.

History agrees, independently. The code cannot be the cause: `LiveRecognizer.swift` is
byte-identical across both rounds (blob `efb93f45`, unchanged 08-28 17:59 through `4277ebe`;
`git diff cbc3676 4277ebe -- LiveRecognizer.swift` is empty), the `covered` expression has
never changed since it was introduced, and under `MicTest/` the only assignment form that has
ever existed is `requiresOnDeviceRecognition = true` — checked across every commit *and* every
dangling commit `git fsck` exposes. The scope is deliberate: outside `MicTest/`,
`experiments/thaiASR.swift:7` has carried `req.requiresOnDeviceRecognition = onDevice` since
`9bba5c9`, but that standalone probe is not this app and never fed these traces. What differed
was the **audio path**, and it correlates perfectly:

| Round | Audio | Result |
|---|---|---|
| `TEST-2026-08-30.md` | **real microphone**, ambient room | `covered=12.0s`, one line |
| `TEST-2026-08-30-seam.md` | synthetic file injection | 71 lines, all 0.0 s |
| this run | synthetic file injection | 70 lines, all 0.0 s |

A human in a room pauses. `say -v Kanya` reading a fixture built to have no pauses does not.

### What stays unproven, stated plainly

- **The 12.0 s line itself is unverifiable.** Its raw trace never survived; it exists as a
  hand-copied line at `TEST-2026-08-30.md:137`. Thin provenance is not on its own grounds for
  dismissal — this report's own 882 callbacks were equally unbacked in the tree until their
  artifacts were preserved (above), and the standard has to be the same in both directions.
  The substantive reason to hold the line at arm's length is `segs`, next. The probe proves the
  endpoint path exists and reproduces its three numbers; it cannot prove that line took it.
- **`segs=8` does not match.** The original had 8 segments over 12 s (1.5 s/seg); the probe's
  endpointed partial had 24 over 12 s (0.5 s/seg). Timing matches, granularity does not.
  Most likely a slower human speaker with fewer words — unverified.
- **The "server" conditions did not demonstrably use the server.** With
  `requiresOnDeviceRecognition=false` the final still came back in `wall=0.3s` with
  byte-identical text; macOS 26.5.1 appears to have served it on-device anyway.

### The consequence for the code's own verdict

The `partial-lag` comment in `handle(session:result:error:)`, in the block guarded by
`admitLagTrace`, read *"this locale reports no timing"* as of `4736bb4`. That **is wrong as
stated**: the locale reports timing; it reports it only on metadata-bearing results. The
comment is corrected in this change, so the quoted wording is no longer in the file — what a
reader should find under that same `admitLagTrace` guard now is the block headed *"WHY
`covered` READS 0.0s"*.

The verdict named at `beginSession` is the load-bearing casualty:

> a successor born from a replay should read its first `lag` as **negative** by roughly the
> window; a first `lag` near zero at a seam is the failing case

Measured here, the first post-seam lag was `+1.0 s` and `+0.7 s` — positive at every seam, as
it must be when `lag = wall − 0`. **The check the code names as the verdict on its one
load-bearing assumption cannot fire during continuous speech**, which is the only condition
under which a seam occurs.

It is inert, but **not structurally dead**, and the distinction is worth keeping: a replay
window whose audio *ends in silence* could make the successor's first partial an endpointed
one, carrying real timestamps and possibly reading negative. That case is untested, not ruled
out. Today, `replay: fed Xs` is the only reliable evidence the replay works — 4 of 4 seams here,
10 of 10 previously.

One thing this makes *more* clearly correct: `AudioReplayRing` counts the replay window in
**samples**, not in segment timestamps. Segment timestamps are unavailable exactly when audio
flows continuously — which is precisely when a seam happens. Had the window been sized from
`covered`, it would have been zero at every seam in this report.

---

## Replay: 12 s ring, 0.1 s fed — by design, checked

The ring arms at 12 s but feeds ~0.1 s at every seam. That looked like an under-drain and is not:

- `pendingReplayFrom` is set to `replayRing.totalSamplesWritten` **at the flush instant**, in
  `beginFlushRotation(of:)` in `LiveRecognizer.swift`, under the `if pendingReplayFrom == nil`
  first-write-wins guard. So the window is `[flush → successor installed]` — the flush latency
  itself, 118–148 ms here.
- `0.1 s` against a 118–148 ms flush is the correct duration, and `1 buffer` is right because
  the ring chunks at **0.5 s** (`AudioReplayRing.replayChunkSeconds`); a 0.1 s window is one
  partial chunk.
- The 12 s capacity is sized for the **backoff chain** (0.3 s → 8 s of retries), not for a
  healthy rotation. A rotation that only needs 0.12 s from a ring built for 8 s of failure is
  the ring doing its job cheaply.
- `residual 0 ms dropped` at all four seams: nothing was lost to the chunk boundary.

---

## Regressions checked and clear

- **Post-`stop()` buffer (previous review finding 1): still fixed.** `SYNTH: stopped — fed 4252
  buffers` × 1024 frames = 4,354,048, and `AUTOSTART SUMMARY … frames=4354048`. Delta **0**.
  The microphone stayed open and contributed nothing, as the harness requires.
- **Focus drift (run 1's invalidating failure): did not recur.** A fresh TextEdit document was
  made frontmost before the run and was still frontmost after it. `divergencesRefused=0`
  (run 1's tell was 5). All 1,317 characters landed in the intended window.
- `sessions=1 partials=258 finals=5 secureInputRefusals=0`.

---

## What this run does NOT prove

Unchanged from the previous report, and still the honest limit:

- **The voice is synthetic.** `say -v Kanya` through `SyntheticAudioSource`. A human crossing a
  seam remains untested, and remains the last real gap.
- **Phase 1a (`collapseStandingSelection`, M1) still unexercised** — it needs a *failed* repair
  to enter, and this run refused zero. 27 repairs, all successful.
- **The cloud pass is still untested end to end**, and stays that way by decision: audio does
  not leave this machine.
- **The pre-task-append assumption named in `beginSession` remains unproven.** The check the
  code names for it cannot fire during continuous speech (above). `replay: fed Xs` is
  corroboration, not proof — it reports what was handed to the request, not what the request
  kept.
- **New, and cheap to close:** a replay window whose audio *ends in silence* should make the
  successor's first partial an endpointed one carrying real timestamps — the one case where
  the negative-`lag` verdict could still fire. A fixture with a deliberate pause placed just
  before a 20 s boundary would test it. This round's fixture is built to have no pauses at all,
  so it cannot.

---

## Reproducing

```bash
cd MicTest && ./build.sh                       # the binary MUST be rebuilt; see below
say -v Kanya -o /tmp/thai.aiff -f testdata/thai-continuous.txt
osascript -e 'tell application "TextEdit" to activate' \
          -e 'tell application "TextEdit" to make new document'
pkill -9 -f "MicTest.app/Contents/MacOS/MicTest"; : > /tmp/mictest_trace.txt
open -W -n -g --env MICTEST_AUTOSTART=1 --env MICTEST_AUTOSTART_HOLD=90 \
     --env MICTEST_AUDIO_FILE=/tmp/thai.aiff -a ~/Desktop/MicTest.app
cp /tmp/mictest_trace.txt MicTest/TEST-<date>-run<N>-trace.txt   # BEFORE the next run
grep -nE "rotation:|replay:|SYNTH:|FINAL:|partial at flush" /tmp/mictest_trace.txt
```

Three cautions, each earned by a wasted round:

1. **Rebuild first, and verify it.** The binary on disk was two metric-fixing commits stale at
   the start of this session. Running against it would have reproduced the old numbers with
   nothing in the trace to announce it. Check:
   `strings ~/Desktop/MicTest.app/Contents/MacOS/MicTest | grep -c "partial at flush"` → 3.
2. **Give the run its own target window, check focus AFTER, and let nothing else finish while
   it runs.** The app types into whatever holds keyboard focus *at each moment*. This has now
   cost two runs — ~541 characters in the previous round's run 1, ~1,179 in this round's run 6 —
   and the second happened *with* a fresh TextEdit window made frontmost immediately before
   launch. Making a window frontmost is not enough: any background process that completes and
   surfaces a window during the 90 s capture will take focus from it. Quiesce everything else
   first. The tell is `divergencesRefused` > 0 against a target that accepts AX repair, and
   `focused element does not accept AX text replacement` in the trace.
3. **Copy the trace out before the next run.** Each run truncates `/tmp/mictest_trace.txt`; that
   is why runs 1–3's seams are permanently lower bounds.
