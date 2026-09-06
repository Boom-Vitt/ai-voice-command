import Foundation

/// Pure decisions shared by the Accessibility adapter and its component tests.
/// Missing window evidence is acceptable only with exact field identity.
enum TextTargetPolicy {
    enum Refusal: Equatable {
        case applicationChanged, fieldChanged, fieldUnavailable, windowChanged
        case notEditable, selectionUnavailable, invalidSelection, userInteracted
    }

    enum Selection {
        case range(location: Int, length: Int)
        case selectedText(isEmpty: Bool)
        case unavailable
    }

    enum Insertion: Equatable {
        case ready, collapseSelection
        case refused(Refusal)
    }

    static func identityRefusal(sameApplication: Bool, sameElement: Bool?,
                                sameWindow: Bool?, editable: Bool,
                                unchangedInput: Bool = true,
                                allowsWindowFallback: Bool = false) -> Refusal? {
        guard sameApplication else { return .applicationChanged }
        guard unchangedInput else { return .userInteracted }
        if sameElement == false { return .fieldChanged }
        if sameWindow == false { return .windowChanged }
        if allowsWindowFallback, sameWindow == true { return nil }
        guard let sameElement else { return .fieldUnavailable }
        guard sameElement else { return .fieldChanged }
        guard editable else { return .notEditable }
        return nil
    }

    static func insertionDecision(_ selection: Selection,
                                  allowsWindowFallback: Bool = false) -> Insertion {
        if case .selectedText(isEmpty: true) = selection { return .ready }
        if case .unavailable = selection, allowsWindowFallback { return .ready }
        guard case .range(let location, let length) = selection else {
            return .refused(.selectionUnavailable)
        }
        guard location >= 0, length >= 0, !location.addingReportingOverflow(length).overflow else {
            return .refused(.invalidSelection)
        }
        return length == 0 ? .ready : .collapseSelection
    }
}

/// The event monitors can call back outside the main actor. Record only an
/// epoch, never key codes, positions or typed content.
final class TextInputActivity: @unchecked Sendable {
    enum Event { case input, activation, modifier, synthetic, nonactivatingControl }
    private let lock = NSLock()
    private var epoch: UInt64 = 0

    var generation: UInt64 { lock.withLock { epoch } }

    func record(_ event: Event) {
        switch event {
        case .input, .activation: lock.withLock { epoch &+= 1 }
        case .modifier, .synthetic, .nonactivatingControl: break
        }
    }
}
