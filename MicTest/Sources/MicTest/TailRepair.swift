import Foundation

/// A caret-anchored replacement that includes enough known text for the
/// injector's three-grapheme content check. Context is selected and written
/// back unchanged; it is not part of the recognizer's actual revision.
struct TailRepair {
    let expected: String
    let replacement: String
    let contextCount: Int

    var count: Int { expected.count }

    /// `typed` is the caller's existing delivery ledger; `replacement` replaces
    /// its last `staleCount` Characters. No context is taken from outside that
    /// ledger. The injector must still verify the resulting `expected` against
    /// the actual field before changing anything.
    ///
    /// Keep repair caps, counters, and chunk-ledger updates based on the
    /// original stale tail, not this expanded physical selection.
    static func plan(typed: String, staleCount: Int, replacement: String) -> TailRepair? {
        guard staleCount >= 0, staleCount <= typed.count else { return nil }

        let expected = String(typed.suffix(staleCount))
        let original = TailRepair(expected: expected, replacement: replacement, contextCount: 0)
        let minimumVerifiedCount = 3
        guard staleCount > 0, staleCount < minimumVerifiedCount,
              typed.count >= minimumVerifiedCount else {
            return original
        }

        let contextCount = minimumVerifiedCount - staleCount
        let context = String(typed.dropLast(staleCount).suffix(contextCount))
        return TailRepair(
            expected: context + expected,
            replacement: context + replacement,
            contextCount: contextCount
        )
    }
}
