import Foundation

/// A completed-text ledger. Failed writes remain pending until the same captured
/// target is ready, or until the caller offers the complete transcript for copy.
struct PendingTranscript {
    private(set) var transcript = ""
    private(set) var pendingText = ""
    private var cancellationReason: String?

    mutating func cancelDelivery(reason: String) { cancellationReason = reason }

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        let addition = (transcript.isEmpty ? "" : " ") + text
        transcript += addition
        pendingText += addition
    }

    @discardableResult
    mutating func deliver(using insert: (String) -> String?) -> String? {
        if let cancellationReason { return cancellationReason }
        guard !pendingText.isEmpty else { return nil }
        if let reason = insert(pendingText) { return reason }
        pendingText = ""
        return nil
    }
}
