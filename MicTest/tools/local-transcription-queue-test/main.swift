import Foundation

typealias Queue = LocalTranscriptionQueue<String, String>

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

/// The test controls responses explicitly. No timers, model, audio device, HTTP,
/// Accessibility or guessed sleeps are involved in callback-order assertions.
actor ControlledProvider {
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var registrations = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func transcribe(_ input: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending[input] == nil)
            pending[input] = continuation
            registrations += 1
            let ready = waiters.filter { $0.0 <= registrations }
            waiters.removeAll { $0.0 <= registrations }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRegistrations(_ count: Int) async {
        guard registrations < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func succeed(_ input: String, text: String) {
        guard let continuation = pending.removeValue(forKey: input) else {
            preconditionFailure("test resolved unregistered input")
        }
        continuation.resume(returning: text)
    }

    func fail(_ input: String, reason: String) {
        guard let continuation = pending.removeValue(forKey: input) else {
            preconditionFailure("test resolved unregistered input")
        }
        continuation.resume(throwing: TestFailure(description: reason))
    }
}

@MainActor
final class Harness {
    var queue: Queue
    let provider = ControlledProvider()
    var tasks: [Queue.ChunkID: Task<Void, Never>] = [:]

    init(limits: Queue.Limits = .init()) {
        queue = Queue(limits: limits)
    }

    func launchAll() {
        while let work = queue.nextWork() {
            tasks[work.id] = Task {
                let outcome: Queue.Outcome
                do {
                    outcome = .success(try await provider.transcribe(work.payload))
                } catch {
                    outcome = .failure(String(describing: error))
                }
                precondition(queue.complete(work.id, with: outcome) == .accepted)
            }
        }
    }

    func wait(_ id: Queue.ChunkID) async {
        await tasks[id]!.value
    }
}

@main
struct QueueTests {
    @MainActor static var checks = 0

    @MainActor
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        checks += 1
        guard condition() else { throw TestFailure(description: description) }
    }

    static func describe(_ events: [Queue.Event]) -> [String] {
        events.map {
            switch $0 {
            case .captureDrained(let id): return "end\(id.sequence)"
            case .result(let id, .success(let text)):
                return "\(id.capture.sequence).\(id.sequence)=\(text)"
            case .result(let id, .failure(let reason)):
                return "\(id.capture.sequence).\(id.sequence)!\(reason)"
            }
        }
    }

    @MainActor
    static func expectEnqueueError(_ expected: Queue.EnqueueError,
                                   _ action: () throws -> Void) throws {
        do {
            try action()
            throw TestFailure(description: "expected enqueue error \(expected)")
        } catch let error as Queue.EnqueueError {
            try check(error == expected, "wrong enqueue error: \(error), wanted \(expected)")
        }
    }

    @MainActor
    static func delayedOrderAndRapidRestart() async throws {
        let h = Harness()
        let first = try h.queue.beginCapture()
        let a = try h.queue.enqueue("audio-a", byteCount: 7, in: first)
        let b = try h.queue.enqueue("audio-b", byteCount: 7, in: first)
        let c = try h.queue.enqueue("audio-c", byteCount: 7, in: first)
        try check(h.queue.stopCapture(first) == .stopped, "first stop must seal capture")
        try check(h.queue.stopCapture(first) == .alreadyStopped, "repeat stop must be idempotent")
        let second = try h.queue.beginCapture()
        let d = try h.queue.enqueue("audio-d", byteCount: 7, in: second)
        h.queue.stopCapture(second)
        h.launchAll()
        await h.provider.waitForRegistrations(4)

        await h.provider.succeed("audio-d", text: "second capture")
        await h.wait(d)
        await h.provider.succeed("audio-c", text: "push")
        await h.wait(c)
        await h.provider.fail("audio-b", reason: "decoder timed out")
        await h.wait(b)
        try check(h.queue.takeReadyEvents().isEmpty,
                  "new capture and later chunks must wait for first chunk")
        try check(h.queue.pendingChunkCount == 4 && h.queue.pendingInputBytes == 28,
                  "out-of-order completions must retain bounded pending capacity")

        await h.provider.succeed("audio-a", text: "ขอ deploy ก่อน")
        await h.wait(a)
        try check(describe(h.queue.takeReadyEvents()) == [
            "0.0=ขอ deploy ก่อน", "0.1!decoder timed out", "0.2=push", "end0",
            "1.0=second capture", "end1"
        ], "stop must drain every accepted success/failure in capture and chunk order")
        try check(h.queue.takeReadyEvents().isEmpty, "results must deliver only once")
        try check(h.queue.pendingChunkCount == 0 && h.queue.pendingInputBytes == 0
                  && h.queue.pendingCaptureCount == 0, "drain must release all budgets")
        try check(h.queue.complete(a, with: .success("late wrong text")) == .duplicate,
                  "late callback must not reopen old capture")
        try check(h.queue.stopCapture(first) == .alreadyStopped,
                  "stop remains idempotent after capture was drained")
        print("PASS: delayed provider, rapid restart, ordered failures and complete drain")
    }

    @MainActor
    static func pressureRetainsAudio() async throws {
        let h = Harness(limits: .init(captures: 2, chunks: 2, inputBytes: 8))
        let capture = try h.queue.beginCapture()
        let a = try h.queue.enqueue("AAAA", byteCount: 4, in: capture)
        let b = try h.queue.enqueue("BBBB", byteCount: 4, in: capture)
        let retainedAudio = "CCCC"
        try expectEnqueueError(.backpressure(.chunks(limit: 2))) {
            _ = try h.queue.enqueue(retainedAudio, byteCount: 4, in: capture)
        }
        h.launchAll()
        await h.provider.waitForRegistrations(2)
        await h.provider.succeed("BBBB", text: "two")
        await h.wait(b)
        try expectEnqueueError(.backpressure(.chunks(limit: 2))) {
            _ = try h.queue.enqueue(retainedAudio, byteCount: 4, in: capture)
        }
        try check(h.queue.takeReadyEvents().isEmpty, "completion must not bypass slow first slot")
        await h.provider.succeed("AAAA", text: "one")
        await h.wait(a)
        try check(describe(h.queue.takeReadyEvents(limit: 1)) == ["0.0=one"],
                  "bounded delivery should release only requested prefix")
        let c = try h.queue.enqueue(retainedAudio, byteCount: 4, in: capture)
        try check(c.sequence == 2, "rejected input must not consume a sequence number")
        try check(h.queue.pendingChunkCount == 2 && h.queue.pendingInputBytes == 8,
                  "retry must occupy exactly the newly available budget")
        h.queue.stopCapture(capture)
        h.launchAll()
        await h.provider.waitForRegistrations(3)
        await h.provider.succeed(retainedAudio, text: "three")
        await h.wait(c)
        try check(describe(h.queue.takeReadyEvents()) == ["0.1=two", "0.2=three", "end0"],
                  "retained WAV retry must deliver without loss or duplication")
        print("PASS: explicit backpressure retains caller audio and retry order")
    }

    @MainActor
    static func captureBoundariesAndIdentity() throws {
        var queue = Queue(limits: .init(captures: 2, chunks: 4, inputBytes: 100))
        let open = try queue.beginCapture()
        let later = try queue.beginCapture()
        let laterChunk = try queue.enqueue("later", byteCount: 5, in: later)
        try check(queue.nextWork()?.id == laterChunk,
                  "idle earlier capture should not prevent starting accepted work")
        queue.complete(laterChunk, with: .success("later"))
        queue.stopCapture(later)
        try check(queue.takeReadyEvents().isEmpty,
                  "later capture cannot deliver past an open earlier capture")
        do {
            _ = try queue.beginCapture()
            throw TestFailure(description: "capture bound must be enforced")
        } catch let pressure as Queue.Pressure {
            try check(pressure == .captures(limit: 2), "wrong capture capacity error")
        }
        queue.stopCapture(open)
        try check(describe(queue.takeReadyEvents()) == ["end0", "1.0=later", "end1"],
                  "empty stopped capture must produce one boundary and unblock next")
        let next = try queue.beginCapture()
        try check(next.sequence == 2, "failed start must not consume capture ID")

        var foreignQueue = Queue()
        let foreign = try foreignQueue.beginCapture()
        let foreignChunk = try foreignQueue.enqueue("foreign", byteCount: 7, in: foreign)
        try check(queue.stopCapture(foreign) == .unknownCapture, "foreign capture must be rejected")
        try check(queue.complete(foreignChunk, with: .success("wrong")) == .unknownChunk,
                  "foreign callback must not target same numeric sequence in another queue")
        try expectEnqueueError(.unknownCapture) {
            _ = try queue.enqueue("wrong", byteCount: 5, in: foreign)
        }
        try expectEnqueueError(.captureStopped) {
            _ = try queue.enqueue("late", byteCount: 4, in: open)
        }
        queue.stopCapture(next)
        try check(describe(queue.takeReadyEvents()) == ["end2"], "empty next capture drains once")
        print("PASS: overlapping captures, empty stops, bounded capture history and identity")
    }

    @MainActor
    static func invalidInputAndCompletion() throws {
        var queue = Queue(limits: .init(captures: 2, chunks: 8, inputBytes: 8))
        let capture = try queue.beginCapture()
        try expectEnqueueError(.invalidByteCount) {
            _ = try queue.enqueue("invalid", byteCount: -1, in: capture)
        }
        try expectEnqueueError(.payloadTooLarge(bytes: Int.max, limit: 8)) {
            _ = try queue.enqueue("huge", byteCount: .max, in: capture)
        }
        let first = try queue.enqueue("first", byteCount: 5, in: capture)
        try expectEnqueueError(.backpressure(.inputBytes(limit: 8))) {
            _ = try queue.enqueue("next", byteCount: 4, in: capture)
        }
        try check(queue.pendingChunkCount == 1 && queue.pendingInputBytes == 5,
                  "all rejected submissions must leave counters unchanged")
        try check(first.sequence == 0, "invalid inputs must not consume chunk IDs")
        try check(queue.complete(first, with: .success("unstarted")) == .notClaimed,
                  "completion cannot invent a provider response before work starts")
        try check(queue.nextWork()?.payload == "first", "claim must preserve the original payload")
        try check(queue.nextWork() == nil, "a request must never be claimed twice")
        let exact = "  e\u{0301} ก่ 👩‍💻 auto fix correction\n"
        try check(queue.complete(first, with: .success(exact)) == .accepted,
                  "claimed completion must be accepted")
        try check(queue.complete(first, with: .failure("duplicate")) == .duplicate,
                  "duplicate callback cannot replace the first outcome")
        guard case .result(let delivered, .success(let text)) = queue.takeReadyEvents().first else {
            throw TestFailure(description: "expected original success")
        }
        try check(delivered == first && Array(text.utf8) == Array(exact.utf8),
                  "queue must preserve exact Thai/English/Unicode result bytes")
        queue.stopCapture(capture)
        try expectEnqueueError(.captureStopped) {
            _ = try queue.enqueue("late", byteCount: 4, in: capture)
        }
        try check(describe(queue.takeReadyEvents()) == ["end0"], "already delivered capture still ends once")
        print("PASS: byte budget, invalid input, exact Unicode and duplicate callback defenses")
    }

    @MainActor
    static func manyCapturesAndQueuedStop() throws {
        var queue = Queue(limits: .init(captures: 1, chunks: 4, inputBytes: 100))
        for iteration in 0..<1_000 {
            let capture = try queue.beginCapture()
            let chunk = try queue.enqueue("audio", byteCount: 5, in: capture)
            queue.stopCapture(capture)
            try check(queue.nextWork()?.id == chunk, "stopping cannot cancel unclaimed audio")
            queue.complete(chunk, with: .failure("explicit failure"))
            try check(describe(queue.takeReadyEvents()) == [
                "\(iteration).0!explicit failure", "end\(iteration)"
            ], "long session history must not affect ordered stop/drain")
            try check(queue.pendingCaptureCount == 0 && queue.pendingChunkCount == 0
                      && queue.pendingInputBytes == 0, "drained history must release all capacity")
        }
        print("PASS: 1,000 captures and stop before work starts")
    }

    @MainActor
    static func incrementalEventDrain() throws {
        var queue = Queue()
        let first = try queue.beginCapture()
        let a = try queue.enqueue("a", byteCount: 1, in: first)
        let b = try queue.enqueue("b", byteCount: 1, in: first)
        queue.stopCapture(first)
        let empty = try queue.beginCapture()
        queue.stopCapture(empty)
        let last = try queue.beginCapture()
        let c = try queue.enqueue("c", byteCount: 1, in: last)
        queue.stopCapture(last)
        while queue.nextWork() != nil {}
        queue.complete(c, with: .success("three"))
        queue.complete(b, with: .failure("failed second"))
        queue.complete(a, with: .success("one"))

        // Copy only as a deterministic snapshot for comparing API modes. Production
        // keeps one coordinator on MainActor and never copies it into async workers.
        var unlimited = queue
        let expected = ["0.0=one", "0.1!failed second", "end0", "end1", "2.0=three", "end2"]
        try check(describe(unlimited.takeReadyEvents()) == expected,
                  "default unlimited delivery must still return the complete ready prefix")
        var incrementallyDelivered: [String] = []
        let remainingCaptures = [3, 3, 2, 1, 1, 0]
        let remainingChunks = [2, 1, 1, 1, 0, 0]
        for (step, expectedEvent) in expected.enumerated() {
            let events = queue.takeReadyEvents(limit: 1)
            try check(events.count == 1 && describe(events) == [expectedEvent],
                      "limit 1 must preserve every result and drained boundary at step \(step)")
            incrementallyDelivered += describe(events)
            try check(queue.pendingCaptureCount == remainingCaptures[step]
                      && queue.pendingChunkCount == remainingChunks[step]
                      && queue.pendingInputBytes == remainingChunks[step],
                      "incremental drain must release only the delivered event's budget at step \(step)")
        }
        try check(incrementallyDelivered == expected, "paced drain must equal unlimited drain")
        try check(queue.takeReadyEvents(limit: 1).isEmpty && queue.takeReadyEvents().isEmpty,
                  "completed paced drain must not redeliver events")
        print("PASS: limit 1 incrementally preserves every result and capture-drained boundary")
    }

    @MainActor
    static func main() async throws {
        try await delayedOrderAndRapidRestart()
        try await pressureRetainsAudio()
        try captureBoundariesAndIdentity()
        try invalidInputAndCompletion()
        try manyCapturesAndQueuedStop()
        try incrementalEventDrain()
        print("ALL PASS (\(checks) checks)")
    }
}
