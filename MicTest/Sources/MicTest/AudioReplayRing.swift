//
//  AudioReplayRing — a short rolling window of the microphone's own audio, kept so that a
//  NEW recognition request can be handed the seconds the previous one never transcribed.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
//  `SFSpeechAudioBufferRecognitionRequest` only ever hears audio appended to IT. When one
//  request dies — the 20 s rotation that keeps requests young enough to dodge the measured
//  ~35 s wedge, or a recognition error whose backoff restart takes up to 8 s — every buffer
//  that arrives before its successor exists reaches nobody. Measured (trace 14:26-14:29 and
//  the 21/21 rotation sample): that is a hole in the typed text at every seam of continuous
//  speech, in every app, which is exactly the "words get cut" report this file was written
//  to end.
//
//  So the tap's buffers are ALSO written here, into a fixed 12 s ring, and the successor
//  request is fed `[t0, now]` from the ring before it is installed. The predecessor's
//  flushed final covers `[start, t0]`; the replay covers `[t0, now]`. Nothing in between
//  goes unheard.
//
//  12 s, not more: it must cover the worst chain this app can produce — the 8 s maximum
//  error backoff, plus the ≤2 s flush timeout, plus scheduling — with headroom, while
//  staying small enough that a successor handed the whole window is still young in AUDIO
//  CONSUMED terms when its own 20 s rotation arrives (see `LiveRecognizer`'s wedge-margin
//  note). At 48 kHz Float32 that is ~2.3 MB per channel, allocated once.
//
//  ── THE ISOLATION RULE, INHERITED VERBATIM FROM `LiveRecognizer` ────────────────────────
//
//  `write(_:)` is called from AVFAudio's realtime render thread, from inside `LiveRecognizer
//  .append`, from inside an `installTap` closure. This app has already hard-crashed once
//  (EXC_BREAKPOINT in `_dispatch_assert_queue_fail`) because a tap closure silently
//  inherited `@MainActor` isolation. Therefore:
//
//    * This type is NOT `@MainActor` and must never become one.
//    * `@unchecked Sendable` is honest: an `OSAllocatedUnfairLock` provides the mutual
//      exclusion the compiler cannot see. Unfair, not `NSLock`, because unfair locks
//      participate in priority donation — a `replay` running on the low-priority session
//      queue must never leave the high-priority audio thread spinning.
//    * `write` does ONE lock acquisition and ONE bounded memcpy (≤ one tap buffer, ~16 KB
//      at 1024 frames × 4 bytes). No allocation, no I/O, no tracing, no Speech calls,
//      nothing that can take an unbounded amount of time. `prepare` does the allocating,
//      off the audio thread.
//    * `replay(from:into:)` runs on `LiveRecognizer`'s session queue. It allocates and it
//      calls into Speech — neither of which may ever move onto the audio path.
//
//  ── LOCK ORDERING ──────────────────────────────────────────────────────────────────────
//
//  `LiveRecognizer` reads `totalSamplesWritten` while holding ITS lock, so the acquisition
//  order is always (LiveRecognizer.lock → AudioReplayRing.lock). This file never calls back
//  into `LiveRecognizer` — no callbacks, no delegates, no closures stored — so the reverse
//  edge does not exist and the order cannot cycle. Do not add a callback to this type.
//

import AVFAudio
import Foundation
import Speech
import os

final class AudioReplayRing: @unchecked Sendable {

    // MARK: - Tuning

    /// Ring capacity. See the header for why 12 s and not 4 or 30.
    static let capacitySeconds: Double = 12

    /// Maximum audio per replayed `AVAudioPCMBuffer`. Each chunk is a FRESH allocation
    /// because Speech consumes appended buffers asynchronously: reusing one buffer across
    /// chunks would rewrite audio the request may not have read yet. 0.5 s keeps the number
    /// of allocations for a full 12 s window at 24 and each one at ~96 KB.
    private static let replayChunkSeconds: Double = 0.5

    /// Residual threshold when no buffer has been written yet. The real threshold is the
    /// largest tap buffer this ring has actually seen (`largestWriteFrames`), which on this
    /// machine is the 1024 frames `installTap` is asked for — ~21 ms at 48 kHz.
    private static let assumedTapFrames = 1024

    /// Hard cap on the chase loop. Replay feeds audio far faster than the microphone
    /// produces it (a memcpy plus an `append` per 0.5 s chunk), so convergence takes two or
    /// three passes in practice. The cap exists so a pathological producer can never spin
    /// this loop forever on the session queue; hitting it is reported, not swallowed.
    private static let maxChasePasses = 64

    // MARK: - Reports

    /// Outcome of `prepare(format:)`, so the caller can trace it. This type never traces:
    /// it has no business owning a file handle, and `LiveRecognizer` already owns the one
    /// trace format the app uses.
    enum PrepareOutcome: Sendable {
        /// Freshly allocated. Carries a human-readable summary for the trace.
        case prepared(String)
        /// Already prepared for an equivalent format — nothing was reallocated.
        case unchanged
        /// This ring cannot serve that format; `write` stays a no-op and `replay` will say
        /// so. Carries the reason.
        case unsupported(String)
    }

    /// What one `replay(from:into:)` actually did. All scalars, so it crosses threads freely
    /// and contains nothing that could leak audio or transcript text into a log.
    struct ReplayReport: Sendable {
        /// Audio fed into the request.
        let seconds: Double
        /// Number of `AVAudioPCMBuffer`s appended.
        let buffers: Int
        /// Audio deliberately dropped at the tail: the chase loop stops once the remainder
        /// is within one tap buffer, because chasing a live writer to zero never terminates.
        let residualMilliseconds: Double
        /// Audio the window asked for that the ring no longer held — the requested start had
        /// already been overwritten. Non-zero means the gap outlived the 12 s ring and those
        /// seconds are genuinely lost.
        let truncatedSeconds: Double
        /// Anything abnormal (ring unprepared, allocation failure, chase cap, rejected tap
        /// buffers). Nil on the ordinary path.
        let note: String?

        static let notPrepared = ReplayReport(
            seconds: 0, buffers: 0, residualMilliseconds: 0, truncatedSeconds: 0,
            note: "the ring is not prepared; nothing was replayed")
    }

    // MARK: - State

    /// Guards every stored property below. Held for the bounded memcpy in `write` and for
    /// one copy-out per `replay` chunk — never across an allocation, never across a Speech
    /// call, never across a callback (there are none; see the header).
    private let lock = OSAllocatedUnfairLock()

    /// Channel-major flat storage: channel `c`'s frame `i` lives at `storage[c * capacity +
    /// i]`. One allocation rather than an array of arrays, so `write` is a plain memcpy per
    /// channel with no bridging, no retain traffic and no chance of a copy-on-write
    /// allocation firing on the render thread.
    private var storage: UnsafeMutablePointer<Float>?
    /// Frames per channel. 0 until `prepare` succeeds.
    private var capacity = 0
    private var channelCount = 0
    private var sampleRate: Double = 0
    /// The exact format `write` accepts and `replay` reproduces. Held as the tap's own
    /// format object — see `prepare` for why nothing is converted.
    private var format: AVAudioFormat?

    /// Next frame index to write (wraps at `capacity`).
    private var writeIndex = 0
    /// Valid frames per channel, saturating at `capacity`.
    private var filled = 0
    /// Monotonic count of frames ever accepted. This is the clock the whole mechanism is
    /// stated in: a replay window is a pair of values of this counter. Deliberately NOT
    /// reset by `reset()` — a window recorded before a reset must read as "evicted", which
    /// is true and traceable, rather than silently becoming a valid window into new audio.
    private var totalWritten: UInt64 = 0
    /// Largest tap buffer seen, which is what "one tap buffer's worth" means for the chase
    /// loop's stopping rule. Measured rather than assumed: the tap size is chosen in
    /// main.swift and this file must not encode a copy of that constant.
    private var largestWriteFrames = 0
    /// Buffers `write` refused because their shape did not match what was prepared. The
    /// audio thread cannot trace, so it counts instead and `replay` reports it.
    private var rejectedWrites: UInt64 = 0

    deinit {
        storage?.deallocate()
    }

    // MARK: - Preparation (never on the audio thread)

    /// Frames accepted since this process started. The mark that defines a replay window.
    ///
    /// Read by `LiveRecognizer` while it holds ITS lock — see the header's lock-ordering
    /// note. Never read this from `write`'s caller expecting it to be free: it is a lock
    /// take, and the audio path already has the one it is allowed.
    var totalSamplesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalWritten
    }

    /// Allocate the ring for the tap's own format. Call from the session queue or any
    /// ordinary thread — NEVER from `write`'s caller on the audio path.
    ///
    /// ── WHY THE TAP FORMAT, VERBATIM, ALL CHANNELS ─────────────────────────────────────
    /// `LiveRecognizer.append` hands Speech the tap's buffers exactly as they arrive, so a
    /// replayed buffer must be indistinguishable from a live one. Ringing channel 0 only and
    /// replaying mono would hand ONE request two different formats over its lifetime (mono
    /// replay first, then multi-channel live audio) — an avoidable risk for an API whose
    /// contract on mid-request format changes is not documented, in exchange for saving
    /// 2.3 MB on a machine whose microphone tap is mono anyway. Ringing every channel keeps
    /// the replay byte-shaped like the live path and needs no DSP decision at all.
    ///
    /// Non-interleaved Float32 is required rather than converted: that is what
    /// `AVAudioEngine`'s input node produces, and a converter here would be a second signal
    /// path to keep correct, on the file whose entire job is "the audio the recognizer
    /// missed". An unsupported format is reported and leaves the ring inert.
    @discardableResult
    func prepare(format newFormat: AVAudioFormat) -> PrepareOutcome {
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            return .unsupported("tap format is \(newFormat.sampleRate) Hz "
                + "×\(newFormat.channelCount) — no usable input device")
        }
        guard newFormat.commonFormat == .pcmFormatFloat32, !newFormat.isInterleaved else {
            return .unsupported("tap format is not non-interleaved Float32 "
                + "(commonFormat=\(newFormat.commonFormat.rawValue) "
                + "interleaved=\(newFormat.isInterleaved)); the ring does not convert")
        }

        lock.lock()
        let alreadyMatching = storage != nil
            && sampleRate == newFormat.sampleRate
            && channelCount == Int(newFormat.channelCount)
        lock.unlock()
        if alreadyMatching { return .unchanged }

        let frames = Int(newFormat.sampleRate * Self.capacitySeconds)
        let channels = Int(newFormat.channelCount)
        // Allocated and zero-filled OUTSIDE the lock: 2.3 MB per channel of
        // `initialize(repeating:)` is far too much work to do while the render thread may be
        // waiting on it.
        let fresh = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
        fresh.initialize(repeating: 0, count: frames * channels)

        lock.lock()
        let stale = storage
        storage = fresh
        capacity = frames
        channelCount = channels
        sampleRate = newFormat.sampleRate
        format = newFormat
        writeIndex = 0
        filled = 0
        largestWriteFrames = 0
        rejectedWrites = 0
        lock.unlock()

        // Freed after the swap, outside the lock, so no `write` can be mid-memcpy into it.
        // (`write` only ever touches `storage` while holding the lock, so once the swap has
        // been observed nobody can reach the old block.)
        stale?.deallocate()

        let megabytes = Double(frames * channels * MemoryLayout<Float>.size) / 1_048_576
        return .prepared("\(Int(newFormat.sampleRate)) Hz ×\(channels), "
            + "\(String(format: "%.0f", Self.capacitySeconds)) s "
            + "(\(String(format: "%.1f", megabytes)) MB)")
    }

    /// Drop the audio currently held without freeing the allocation, e.g. at the start of a
    /// new capture. `totalSamplesWritten` keeps counting — see its doc.
    func reset() {
        lock.lock()
        writeIndex = 0
        filled = 0
        rejectedWrites = 0
        lock.unlock()
    }

    // MARK: - Realtime audio thread

    /// Called on the REALTIME AUDIO THREAD, once per tap buffer, from
    /// `LiveRecognizer.append`.
    ///
    /// One lock acquisition, one bounded memcpy per channel, unlock. Everything that could
    /// take an unbounded amount of time — allocation, conversion, tracing — happens in
    /// `prepare` or `replay` instead. A buffer that does not match what was prepared (wrong
    /// channel count, ring not prepared yet) is counted and dropped; the audio thread cannot
    /// trace, so `replay` reports the count instead.
    func write(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let source = buffer.floatChannelData else { return }
        // `mNumberBuffers` rather than `buffer.format.channelCount`: a pointer read into the
        // AudioBufferList, with none of the ObjC object return and retain/release traffic
        // that reading the `format` property would put on the render thread. For a
        // non-interleaved buffer it IS the channel count.
        let sourceChannels = Int(buffer.audioBufferList.pointee.mNumberBuffers)

        lock.lock()
        defer { lock.unlock() }
        guard let storage, capacity > 0, sourceChannels >= channelCount, channelCount > 0
        else {
            // Not a no-op: an unprepared ring is the ordinary state for the first instants
            // of a capture, but a channel-count mismatch would silently produce an empty
            // window, so it is counted either way.
            if storage != nil { rejectedWrites &+= 1 }
            return
        }

        if frames > largestWriteFrames { largestWriteFrames = frames }

        var done = 0
        var index = writeIndex
        while done < frames {
            let n = min(capacity - index, frames - done)
            for channel in 0..<channelCount {
                (storage + channel * capacity + index)
                    .update(from: source[channel] + done, count: n)
            }
            index = (index + n) % capacity
            done += n
        }
        writeIndex = index
        filled = min(filled + frames, capacity)
        totalWritten &+= UInt64(frames)
    }

    // MARK: - Replay (session queue only)

    /// Feed everything written since `start` into `request`, in order, as fresh buffers.
    ///
    /// Call this BEFORE the request is installed as the delivery owner. If live audio were
    /// already flowing into it, the replay's chunks would interleave with buffers that come
    /// AFTER them in time and the request would hear the seam out of order.
    ///
    /// ── THE CHASE LOOP ────────────────────────────────────────────────────────────────
    /// The microphone does not stop while the replay runs, so "everything since `start`" is
    /// a moving target. Each pass re-reads `totalWritten` and feeds what has appeared since
    /// the last one. Replay is orders of magnitude faster than realtime (a memcpy and an
    /// `append` per 0.5 s of audio), so the remainder collapses within two or three passes.
    /// It is stopped once the remainder is within one tap buffer — ~21 ms — because chasing
    /// a live writer to exactly zero never terminates. That residual is DROPPED, and
    /// reported so nobody has to wonder: it is the one thing this mechanism knowingly loses,
    /// and it is smaller than a single phoneme.
    ///
    /// A `start` older than the ring is clamped to the oldest sample still held and the
    /// difference is reported as `truncatedSeconds` — replay what survives rather than
    /// refuse the whole window.
    func replay(from start: UInt64,
                into request: SFSpeechAudioBufferRecognitionRequest) -> ReplayReport {
        lock.lock()
        let ringFormat = format
        let rate = sampleRate
        let residualLimit = max(largestWriteFrames, Self.assumedTapFrames)
        let ready = (storage != nil && capacity > 0)
        lock.unlock()

        guard ready, let ringFormat, rate > 0 else { return .notPrepared }

        let chunkFrames = max(1, Int(rate * Self.replayChunkSeconds))
        var cursor = start
        var fedFrames = 0
        var buffers = 0
        var truncatedFrames = 0
        var residualFrames = 0
        var note: String?
        var passes = 0

        while passes < Self.maxChasePasses {
            passes += 1

            // Allocated before the critical section, at full chunk size, so the lock never
            // covers an allocation. A final pass that finds nothing left to feed wastes one
            // ~96 KB buffer, which is the right trade against holding the audio thread off.
            guard let out = AVAudioPCMBuffer(pcmFormat: ringFormat,
                                             frameCapacity: AVAudioFrameCount(chunkFrames)),
                  let destination = out.floatChannelData
            else {
                note = "could not allocate a replay buffer after \(buffers) buffers"
                break
            }

            var produced = 0
            var evicted = 0
            var remaining = 0

            lock.lock()
            if let storage, capacity > 0, channelCount > 0 {
                let held = UInt64(min(filled, capacity))
                let oldest = totalWritten &- held
                if cursor < oldest {
                    evicted = Int(oldest - cursor)
                    cursor = oldest
                }
                let available = totalWritten > cursor
                    ? Int(min(totalWritten - cursor, UInt64(Int.max)))
                    : 0
                if available > residualLimit {
                    produced = min(available, chunkFrames)
                    // Position of global frame `cursor` in the ring: `writeIndex` is where
                    // the NEXT frame goes, so the frame `back` positions ago sits at
                    // `writeIndex - back`, modulo the capacity.
                    let back = Int(totalWritten - cursor)
                    var readIndex = writeIndex - back
                    if readIndex < 0 { readIndex += capacity }
                    var done = 0
                    while done < produced {
                        let n = min(capacity - readIndex, produced - done)
                        for channel in 0..<channelCount {
                            (destination[channel] + done)
                                .update(from: storage + channel * capacity + readIndex,
                                        count: n)
                        }
                        readIndex = (readIndex + n) % capacity
                        done += n
                    }
                    cursor &+= UInt64(produced)
                    remaining = available - produced
                } else {
                    remaining = available
                }
            }
            let rejected = rejectedWrites
            lock.unlock()

            truncatedFrames += evicted
            residualFrames = remaining
            if rejected > 0 && note == nil {
                note = "\(rejected) tap buffers were rejected by the ring (format mismatch)"
            }

            guard produced > 0 else { break }

            out.frameLength = AVAudioFrameCount(produced)
            request.append(out)
            fedFrames += produced
            buffers += 1

            if passes == Self.maxChasePasses {
                note = "the chase loop hit its \(Self.maxChasePasses)-pass cap with "
                    + "\(remaining) frames still outstanding"
            }
        }

        return ReplayReport(
            seconds: Double(fedFrames) / rate,
            buffers: buffers,
            residualMilliseconds: Double(residualFrames) / rate * 1000,
            truncatedSeconds: Double(truncatedFrames) / rate,
            note: note)
    }
}
