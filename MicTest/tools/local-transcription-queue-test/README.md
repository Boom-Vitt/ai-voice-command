# Local transcription queue tests

Run `bash MicTest/tools/local-transcription-queue-test/run.sh` from the repository root.
The Swift 6 test uses a controlled fake provider with explicit response gates. It
does not launch the app, record audio, contact a server or change other processes.

Coverage includes delayed and out-of-order responses, a new capture while an older
capture is pending, ordered provider failures, repeated stop, complete draining,
stop before work starts, foreign/stale callbacks, capture/chunk/byte bounds,
backpressure with caller-retained audio and retry, and exact Thai/English text.

## Integration contract

Keep `LocalTranscriptionQueue<Data, String>` on MainActor alongside capture targets.
The queue is a value-type state machine, so do not copy it into provider tasks.

1. `beginCapture()` returns a capture ID; save its text target separately.
2. Submit each final WAV with `enqueue(wav, byteCount: wav.count, in: captureID)`.
   Catch rejection before discarding the WAV. Retain/spool and retry it, or stop
   recording with a visible error. A too-large WAV needs splitting or spooling;
   waiting cannot make it fit.
3. `nextWork()` returns each WAV once. Perform transcription outside MainActor;
   return `.success(text)` or `.failure(reason)` through `complete(work.id, with:)`.
   The caller controls worker concurrency and request timeouts. Every claimed
   request needs a terminal outcome, including cancellation and timeout.
4. Drain `takeReadyEvents()` after completions and stops. Only these ordered events
   may insert text. Results remain pending behind an unfinished older request.
5. First flush and enqueue all remaining captured audio, then `stopCapture(id)`.
   Stop seals enqueueing; it leaves accepted work alive. Release the capture's text
   target only on `.captureDrained(id)`, which follows all its result events.

Starting another capture neither cancels nor replaces previous work. If a previous
capture is still open, it blocks later delivery until explicitly stopped. The
queue accounts for input bytes until ordered delivery; it does not bound arbitrary
provider result size or audio the caller keeps outside the queue.
