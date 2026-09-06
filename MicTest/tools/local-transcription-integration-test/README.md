# Local transcription integration check

This harness reads synthetic WAV fixtures through `AVAudioFile`, feeds the real
`AudioPipeline(mode: .localDictation)`, sends its final chunks using the production
`LocalWhisperTranscriber`, then verifies `LocalTranscriptionQueue` delivery and drain.
It opens no microphone or UI and starts or stops no server process.

Use an existing **MicTest-owned** full large-v3 server with Silero VAD loaded.
The port is explicit and defaults to the evaluation server at 18181.

From the repository root:

```sh
mkdir -p MicTest/build/local-transcription-integration-test
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -O \
  MicTest/Sources/MicTest/AudioPipeline.swift \
  MicTest/Sources/MicTest/LocalTranscriptionQueue.swift \
  MicTest/Sources/MicTest/LocalWhisperTranscriber.swift \
  MicTest/Sources/MicTest/SpeechAudioGain.swift \
  MicTest/Sources/MicTest/RefuseRedirects.swift \
  MicTest/tools/local-transcription-integration-test/IntegrationTest.swift \
  -o MicTest/build/local-transcription-integration-test/integration-test
MicTest/build/local-transcription-integration-test/integration-test --port 18181
```

Optional arguments: `--repo PATH`, `--corpus PATH`, `--output DIRECTORY`.
The corpus must contain `manifest.json` with the seed structure and 16 kHz mono
WAV files. Defaults use `thaiasr/corpus` and create a timestamped output directory.
Recompile after changing any production component.

For a bounded repeatability probe, use `--probe-fixture cs4.wav --repeat 5`.
Every request then receives a byte-identical pipeline WAV, saved as `probe-input.wav`
in the report directory. `--gain-proof-only` validates that gain leaves all normal
seed PCM16 chunks byte-identical and returns before sending any inference request.

The report includes every fixture/chunk transcript and request latency, effective
prompt, component source hashes, sample counts, English preservation, and ordered
capture-drained events. It asserts that:

- All eight seed English terms survive the real request path.
- Three and eight seconds of digital silence reach VAD and return empty text.
- Deterministic white noise and 60 Hz hum at input RMS 0.03 remain empty after
  production gain normalization raises them toward RMS 0.04.
- Quiet speech below the RMS boundary threshold keeps all its samples.
- Quiet speech preserves its expected English term after gain and model VAD.
- Repeated stop-time flush drains all 24 seconds as two capped chunks.
- Polled segmentation produces multiple chunks without losing more than the
  documented subminimum final tail.
- Reverse provider completion still produces ordered, complete, one-time delivery.

Quiet-fixture recognition and exact Thai reference matching are reported separately
from sample preservation. These synthetic checks do not establish real microphone
accuracy, and do not exercise Accessibility text insertion.

Pure signal checks require no server:

```sh
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -O \
  MicTest/Sources/MicTest/SpeechAudioGain.swift \
  MicTest/tools/local-transcription-integration-test/GainTest.swift \
  -o MicTest/build/local-transcription-integration-test/gain-test
MicTest/build/local-transcription-integration-test/gain-test
```

These verify the RMS target, gain and peak caps, unchanged silence/normal audio,
PCM16 extrema, byte counts, canonical header validation, invalid tuning values and
nonzero-index Data slices.

Segment joining checks likewise require no server:

```sh
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -O \
  MicTest/Sources/MicTest/LocalWhisperTranscriber.swift \
  MicTest/Sources/MicTest/SpeechAudioGain.swift \
  MicTest/Sources/MicTest/RefuseRedirects.swift \
  MicTest/tools/local-transcription-integration-test/ClientTextTest.swift \
  -o MicTest/build/local-transcription-integration-test/client-text-test
MicTest/build/local-transcription-integration-test/client-text-test
```

To compare the same 24-second PCM stream as `20 + 4` and `10 + 10 + 4` seconds:

```sh
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -O \
  MicTest/Sources/MicTest/AudioPipeline.swift \
  MicTest/Sources/MicTest/LocalWhisperTranscriber.swift \
  MicTest/Sources/MicTest/SpeechAudioGain.swift \
  MicTest/Sources/MicTest/RefuseRedirects.swift \
  MicTest/tools/local-transcription-integration-test/ChunkCapComparison.swift \
  -o MicTest/build/local-transcription-integration-test/cap-comparison
MicTest/build/local-transcription-integration-test/cap-comparison \
  --port 8177 --wav PATH_TO_GENERATED_MULTI_CHUNK_24S_WAV
```

The comparison verifies stop-time and polled chunk equality, saves every input WAV,
and runs exactly two repetitions of each split (ten requests). Reference scoring
includes only fully spoken seed phrase occurrences before the 24-second cutoff.
English scoring counts exact tokens; Thai scoring measures the longest retained
sequence of Thai Unicode scalars and does not penalize inserted words. It is a
retention diagnostic, not an overall accuracy score.

Use `--cap20-only` to run exactly two repetitions of the **polled** production
20-second-cap chunks instead (four requests for the current 24-second fixture).
This exercises the running-capture quiet-seam selector; explicit stop-time flush
retains its hard cap. The report includes each actual chunk duration and pipeline
source hash, and records whether stop-time and polled chunk WAVs are equal.

## Measured cap comparison — 2026-09-06

The [bounded comparison report](../../build/local-transcription-integration-test/cap-comparison-2026-09-05T21-33-57Z/report.json)
contains ten requests against MicTest's owned server on port 18181, using the same
24-second PCM stream, production gain, prompt and timestamp settings.

| Split | English retained, repeats 1 / 2 | Thai scalars retained, repeats 1 / 2 |
| --- | --- | --- |
| 20 + 4 seconds | 8/9, 9/9 | 35/98, 86/98 |
| 10 + 10 + 4 seconds | 5/9, 5/9 | 78/98, 72/98 |

Stop-time and polled 20-second input WAVs were byte-identical. Their text differences
therefore did not come from different pipeline samples. The 10-second boundary fell
116 ms into the commit/push/branch/main phrase; the second chunk omitted the rest of
that phrase in both trials. The production cap stays at 20 seconds: reducing it to
10 seconds did not improve English retention here. Long-speech transcription accuracy
remains a measured limitation despite verified sample retention and ordered drainage.

## Running-cap quiet-seam validation — 2026-09-06

After rebuilding both harnesses against frozen production source, the
[full integration run](../../build/local-transcription-integration-test/run-2026-09-05T21-43-29Z/report.json)
passed all 49 checks across 14 requests and 12 captures on the owned server at
port 18181. The five seed references matched exactly, preserving 8/8 English
terms. Quiet speech matched its reference; 3/8-second silence, white noise and
60 Hz hum returned empty text. Queue order and complete drain passed. The long
fixture's assertions cover sample retention and queue behavior, with transcript
quality measured separately below.

The [two-repeat running-cap probe](../../build/local-transcription-integration-test/cap-comparison-2026-09-05T21-43-41Z/report.json)
used the same existing 24-second fixture, production client, prompt, gain and
timestamp settings as the earlier comparison. The quiet-seam selector moved the
running-capture split to **19.335 + 4.665 seconds**.

| Input split | English retained, repeats 1 / 2 | Thai scalars retained, repeats 1 / 2 |
| --- | --- | --- |
| Prior hard 20 + 4 seconds | 8/9, 9/9 | 35/98, 86/98 |
| Running cap with quiet seam | 9/9, 9/9 | 98/98, 98/98 |

The two new repetitions produced identical text and preserved every fully spoken
phrase. The incomplete final phrase is excluded from these scores. This is one
synthetic fixture with two fixed repetitions, not a general accuracy guarantee.
Explicit stop-time flush still splits at 20 + 4 seconds; its current integration
output still omitted Thai words and misrecognized `commit`. The improvement applies
to the running-cap path tested here.

Stop-time and polled **chunk files now differ**, as expected from the moved seam.
Their concatenated PCM is byte-identical, preserving all 384,000 samples. The
[verification record](../../build/local-transcription-integration-test/cap-comparison-2026-09-05T21-43-41Z/verification.json)
contains that proof, the unchanged client/gain comparison, and all five frozen
production source SHA-256 values. `AudioPipeline.swift` was
`5377623ae70ddef8850be3ca50671c8ef3b0f8ff65718294f85b933fb7d752d5`.

Commands run after the compile commands above:

```sh
MicTest/build/local-transcription-integration-test/integration-test --port 18181
MicTest/build/local-transcription-integration-test/cap-comparison \
  --port 18181 \
  --wav MicTest/build/local-transcription-integration-test/run-2026-09-05T21-27-04Z/multi-chunk-24s.wav \
  --cap20-only
```

No microphone, UI, model/prompt changes or server lifecycle operations were used.
