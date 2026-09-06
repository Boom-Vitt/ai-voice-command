import Foundation

/// Capture-scoped work and ordered delivery for a local transcription worker.
///
/// Keep this value on one actor (normally MainActor). It performs no audio, network,
/// UI or task work. Claim WAVs with `nextWork()`, run the provider outside that actor,
/// then return its outcome with `complete`. Results may arrive in any order; only
/// `takeReadyEvents` releases them, in capture order and then chunk order.
///
/// Stopping seals a capture against new chunks; it never cancels accepted work.
/// Starting another capture likewise leaves earlier work and delivery intact. An
/// earlier capture must be stopped before a later capture can deliver any results.
///
/// Bounds include queued, running and completed-but-undelivered chunks. Enqueue
/// failure changes nothing and leaves the payload with the caller. On backpressure,
/// the caller MUST retain/spool the WAV and retry, or visibly stop recording and
/// report the failure. Ignoring a rejection would lose audio outside this queue.
struct LocalTranscriptionQueue<Payload: Sendable, Value: Sendable>: Sendable {
    struct Limits: Sendable {
        let captures: Int
        let chunks: Int
        let inputBytes: Int

        init(captures: Int = 8, chunks: Int = 64, inputBytes: Int = 16 * 1024 * 1024) {
            precondition(captures > 0 && chunks > 0 && inputBytes > 0)
            self.captures = captures
            self.chunks = chunks
            self.inputBytes = inputBytes
        }
    }

    struct CaptureID: Hashable, Sendable {
        fileprivate let queue: UUID
        /// Monotonic within this queue, starting at zero.
        let sequence: Int
    }

    struct ChunkID: Hashable, Sendable {
        let capture: CaptureID
        /// Monotonic within this capture, starting at zero.
        let sequence: Int
    }

    enum Pressure: Error, Sendable, Equatable {
        case captures(limit: Int)
        case chunks(limit: Int)
        case inputBytes(limit: Int)
    }

    enum EnqueueError: Error, Sendable, Equatable {
        case unknownCapture
        case captureStopped
        case invalidByteCount
        /// This payload cannot fit even when the queue is empty. Split or spool it.
        case payloadTooLarge(bytes: Int, limit: Int)
        case backpressure(Pressure)
    }

    struct Work: Sendable {
        let id: ChunkID
        let payload: Payload
        let byteCount: Int
    }

    enum Outcome: Sendable {
        case success(Value)
        /// Includes provider failures, explicit cancellation and timeouts. The
        /// consumer receives the failure in the same ordered slot as a success.
        case failure(String)
    }

    enum Event: Sendable {
        case result(ChunkID, Outcome)
        /// Emitted exactly once, after every accepted chunk in this capture.
        case captureDrained(CaptureID)
    }

    enum StopResult: Sendable, Equatable {
        case stopped
        case alreadyStopped
        case unknownCapture
    }

    enum CompletionResult: Sendable, Equatable {
        case accepted
        case duplicate
        case notClaimed
        case unknownChunk
    }

    private enum State: Sendable {
        case queued(Payload)
        case running
        case completed(Outcome)
    }

    private struct Entry: Sendable {
        let byteCount: Int
        var state: State
    }

    private struct Capture: Sendable {
        var stopped = false
        var nextSequence = 0
        var nextClaimSequence = 0
        var nextDeliverySequence = 0
        var entries: [Int: Entry] = [:]
    }

    let limits: Limits
    private let identity = UUID()
    private var nextCaptureSequence = 0
    private var captureOrder: [CaptureID] = []
    private var captures: [CaptureID: Capture] = [:]

    /// Capacity is released on ordered delivery, not provider completion. This
    /// also bounds outcomes blocked behind a slow earlier request.
    private(set) var pendingChunkCount = 0
    private(set) var pendingInputBytes = 0
    var pendingCaptureCount: Int { captureOrder.count }

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Throws `Pressure.captures` before creating anything if capture capacity
    /// is full. A stopped but undrained capture still occupies one slot.
    mutating func beginCapture() throws -> CaptureID {
        guard captureOrder.count < limits.captures else {
            throw Pressure.captures(limit: limits.captures)
        }
        let id = CaptureID(queue: identity, sequence: nextCaptureSequence)
        nextCaptureSequence += 1
        captures[id] = Capture()
        captureOrder.append(id)
        return id
    }

    /// Byte count accounts for the retained input (for a WAV, `wav.count`).
    /// No sequence number or budget is consumed when this method throws.
    mutating func enqueue(_ payload: Payload, byteCount: Int,
                          in id: CaptureID) throws -> ChunkID {
        guard var capture = captures[id] else {
            throw wasIssued(id) ? EnqueueError.captureStopped : .unknownCapture
        }
        guard !capture.stopped else { throw EnqueueError.captureStopped }
        guard byteCount >= 0 else { throw EnqueueError.invalidByteCount }
        guard byteCount <= limits.inputBytes else {
            throw EnqueueError.payloadTooLarge(bytes: byteCount, limit: limits.inputBytes)
        }
        guard pendingChunkCount < limits.chunks else {
            throw EnqueueError.backpressure(.chunks(limit: limits.chunks))
        }
        // Subtract rather than add so even a malicious Int.max byte count cannot
        // overflow the capacity check.
        guard byteCount <= limits.inputBytes - pendingInputBytes else {
            throw EnqueueError.backpressure(.inputBytes(limit: limits.inputBytes))
        }
        let chunk = ChunkID(capture: id, sequence: capture.nextSequence)
        capture.nextSequence += 1
        capture.entries[chunk.sequence] = Entry(byteCount: byteCount, state: .queued(payload))
        captures[id] = capture
        pendingChunkCount += 1
        pendingInputBytes += byteCount
        return chunk
    }

    /// Returns each accepted payload exactly once, oldest first. Multiple claimed
    /// requests can run concurrently; keeping one in flight is the caller's choice.
    mutating func nextWork() -> Work? {
        for id in captureOrder {
            guard var capture = captures[id],
                  capture.nextClaimSequence < capture.nextSequence else { continue }
            let sequence = capture.nextClaimSequence
            guard var entry = capture.entries[sequence],
                  case .queued(let payload) = entry.state else {
                preconditionFailure("unclaimed chunk must have a queued payload")
            }
            entry.state = .running
            capture.entries[sequence] = entry
            capture.nextClaimSequence += 1
            captures[id] = capture
            return Work(id: ChunkID(capture: id, sequence: sequence),
                        payload: payload, byteCount: entry.byteCount)
        }
        return nil
    }

    /// Stale/duplicate callbacks cannot replace a result or reopen a capture.
    @discardableResult
    mutating func complete(_ id: ChunkID, with outcome: Outcome) -> CompletionResult {
        guard var capture = captures[id.capture] else {
            return wasIssued(id.capture) ? .duplicate : .unknownChunk
        }
        guard id.sequence >= 0, id.sequence < capture.nextSequence else { return .unknownChunk }
        guard id.sequence >= capture.nextDeliverySequence else { return .duplicate }
        guard var entry = capture.entries[id.sequence] else { return .unknownChunk }
        switch entry.state {
        case .queued: return .notClaimed
        case .completed: return .duplicate
        case .running:
            entry.state = .completed(outcome)
            capture.entries[id.sequence] = entry
            captures[id.capture] = capture
            return .accepted
        }
    }

    @discardableResult
    mutating func stopCapture(_ id: CaptureID) -> StopResult {
        guard var capture = captures[id] else {
            return wasIssued(id) ? .alreadyStopped : .unknownCapture
        }
        guard !capture.stopped else { return .alreadyStopped }
        capture.stopped = true
        captures[id] = capture
        return .stopped
    }

    /// Removes only the ready prefix. Use events exactly once, on the same actor
    /// as the captured text target. A provider failure never skips another slot.
    /// `limit: 1` supports a separately paced insertion worker. The limit counts
    /// both results and capture-drained boundaries; remaining events stay queued.
    mutating func takeReadyEvents(limit: Int = .max) -> [Event] {
        precondition(limit > 0)
        var events: [Event] = []
        while events.count < limit, let id = captureOrder.first,
              var capture = captures[id] {
            if let entry = capture.entries[capture.nextDeliverySequence],
               case .completed(let outcome) = entry.state {
                let chunk = ChunkID(capture: id, sequence: capture.nextDeliverySequence)
                capture.entries.removeValue(forKey: chunk.sequence)
                capture.nextDeliverySequence += 1
                captures[id] = capture
                pendingChunkCount -= 1
                pendingInputBytes -= entry.byteCount
                events.append(.result(chunk, outcome))
            } else if capture.stopped, capture.nextDeliverySequence == capture.nextSequence {
                captures.removeValue(forKey: id)
                captureOrder.removeFirst()
                events.append(.captureDrained(id))
            } else {
                break
            }
        }
        return events
    }

    // No tombstone collection grows with session history: these IDs are issued
    // monotonically, and queue identity rejects callbacks from another instance.
    private func wasIssued(_ id: CaptureID) -> Bool {
        id.queue == identity && id.sequence >= 0 && id.sequence < nextCaptureSequence
    }
}
