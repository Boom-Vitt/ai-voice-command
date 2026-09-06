import Foundation

/// Holds revisable speech output until the caller reaches an utterance
/// boundary. Each utterance can produce at most one complete insertion.
struct StableTranscriptBuffer {
    private var pending: String?
    private var finished = false

    mutating func updatePartial(_ text: String) {
        guard !finished, Self.hasText(text) else { return }
        pending = text
    }

    /// Prefer a nonblank final; otherwise preserve the last nonblank partial.
    /// Finishing consumes the utterance even when it contains no text. Late
    /// callbacks are ignored until the next explicit reset.
    mutating func finish(final: String? = nil) -> String? {
        guard !finished else { return nil }
        finished = true
        let result = final.flatMap { Self.hasText($0) ? $0 : nil } ?? pending
        pending = nil
        return result
    }

    mutating func reset() {
        pending = nil
        finished = false
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
