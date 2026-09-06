import Foundation

var checks = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Catch the regression where unreadable AXSelectedTextRange disables a safe
// clipboard insertion even though AXSelectedText proves there is no selection.
check(TextTargetPolicy.insertionDecision(.selectedText(isEmpty: true)) == .ready,
      "an empty selected-text value permits insertion without a range")

// These cases catch weakening the no-replacement rule while adding fallback.
let selectionCases: [(TextTargetPolicy.Selection, TextTargetPolicy.Insertion, String)] = [
    (.range(location: 4, length: 0), .ready, "known caret"),
    (.range(location: 4, length: 3), .collapseSelection, "known selection must collapse first"),
    (.range(location: -1, length: 0), .refused(.invalidSelection), "negative location"),
    (.range(location: 0, length: -1), .refused(.invalidSelection), "negative length"),
    (.range(location: Int.max, length: 1), .refused(.invalidSelection), "overflowing selection"),
    (.selectedText(isEmpty: false), .refused(.selectionUnavailable), "text selected without range"),
    (.unavailable, .refused(.selectionUnavailable), "unknown selection")
]
for (selection, expected, name) in selectionCases {
    check(TextTargetPolicy.insertionDecision(selection) == expected, name)
}

// Literal identity fixtures protect against sending a delayed result to a new
// app, another field in the same window, or another window in the same app.
let identityCases: [(Bool, Bool?, Bool?, Bool, TextTargetPolicy.Refusal?, String)] = [
    (true, true, true, true, nil, "same editable field"),
    (false, true, true, true, .applicationChanged, "different application"),
    (true, false, true, true, .fieldChanged, "different field in same window"),
    (true, nil, true, true, .fieldUnavailable, "window alone cannot identify a field"),
    (true, true, false, true, .windowChanged, "different window"),
    (true, true, nil, true, nil, "exact field identity is sufficient without a window attribute"),
    (true, true, true, false, .notEditable, "focused control is not editable")
]
for (app, field, window, editable, expected, name) in identityCases {
    check(TextTargetPolicy.identityRefusal(sameApplication: app, sameElement: field,
                                          sameWindow: window, editable: editable) == expected, name)
}

// A window may stand in for an unavailable AX field only while the user has
// not interacted. These fixtures catch accidentally treating one whole app as
// one text target or allowing a field change after capture.
check(TextTargetPolicy.identityRefusal(sameApplication: true, sameElement: nil,
                                      sameWindow: true, editable: false,
                                      unchangedInput: true, allowsWindowFallback: true) == nil,
      "untouched same window permits explicit dictation without an AX text field")
for (window, unchanged, field, expected) in [
    (Optional(true), false, Optional<Bool>.none, TextTargetPolicy.Refusal.userInteracted),
    (Optional(false), true, Optional<Bool>.none, .windowChanged),
    (Optional<Bool>.none, true, Optional<Bool>.none, .fieldUnavailable),
    (Optional(true), true, Optional(false), .fieldChanged)
] {
    check(TextTargetPolicy.identityRefusal(sameApplication: true, sameElement: field,
                                          sameWindow: window, editable: false,
                                          unchangedInput: unchanged, allowsWindowFallback: true) == expected,
          "changed or unverified window target must refuse")
}
check(TextTargetPolicy.identityRefusal(sameApplication: true, sameElement: true,
                                      sameWindow: true, editable: true,
                                      unchangedInput: false) == .userInteracted,
      "manual input invalidates even an identifiable field")
check(TextTargetPolicy.insertionDecision(.unavailable, allowsWindowFallback: true) == .ready,
      "untouched window fallback uses explicit dictation selection semantics")
check(TextTargetPolicy.insertionDecision(.range(location: 0, length: 3),
                                        allowsWindowFallback: true) == .collapseSelection,
      "known selection must still collapse in a window fallback")

let activity = TextInputActivity()
let captured = activity.generation
activity.record(.modifier)
activity.record(.synthetic)
check(activity.generation == captured, "hotkey modifiers and our paste preserve the target")
activity.record(.nonactivatingControl)
check(activity.generation == captured, "HUD Stop preserves the pending target because it cannot take focus")
activity.record(.input)
check(activity.generation != captured, "a user key or mouse click invalidates the target")
let afterInput = activity.generation
activity.record(.activation)
check(activity.generation != afterInput, "switching away and back invalidates the target")
print("ALL PASS (\(checks) checks including input activity)")
