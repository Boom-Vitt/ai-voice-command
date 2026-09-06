# Local dictation audio preservation tests

Run `bash MicTest/tools/audio-pipeline-local-test/run.sh` from the repository root.
This Swift 6 test generates known 16 kHz PCM and exercises the real converter,
ring, polling, finalization and WAV encoding. It never opens a microphone or server.

`AudioPipeline(inputFormat: format, mode: .localDictation)` preserves quiet audio,
emits final chunks only, caps chunks at 20 seconds and lowers explicit flush's
duration floor to 0.15 seconds. Model VAD must reject non-speech downstream. Natural
silence finalization still needs 0.4 seconds above RMS 0.0025, then 0.6 seconds of
silence; insufficient RMS evidence leaves audio intact until cap or explicit flush.

When a running local capture reaches its 20-second cap, it searches the preceding
two seconds in 10 ms frames for the latest quiet run lasting at least 120 ms. The
seam moves to that run's midpoint. The threshold follows local frame RMS and peak,
is capped at RMS 0.0025, and limits transient influence so uniformly quiet voice
does not become a false gap. No suitable gap means the existing hard cap remains.
Explicit stop/flush uses its existing full-sized chunks and short-tail rules.

Omitting `mode` retains `.correction`: 0.25-second idle pre-roll, 1-second interims,
10-second final cap and 0.4-second explicit flush floor.

Assertions cover exact retained samples, quiet onsets, repeated polling, short
words, silent VAD input, continuous speech, multiple flush leftovers, ring wrap,
reset and the existing correction behavior. These are deterministic audio transport
and segmentation checks; they do not measure speech recognition accuracy.
Cap-seam cases also verify latest-gap selection, the 120 ms minimum, scaled quiet
voice, peak interruption, constant-voice/all-silence fallback, old-gap exclusion,
and byte-exact preservation of audio across the moved seam.

Use a single consumer for both `takeChunk()` and `flush()`. Poll independently of
inference so the 30-second ring never fills. After audio stops, loop over `flush()`
until nil to enqueue every remaining chunk before sealing the transcription queue.
