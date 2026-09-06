import Foundation

var checks = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor func verify(_ name: String, typed: String, staleCount: Int, replacement: String,
            expected: String, physicalReplacement: String, contextCount: Int) {
    guard let plan = TailRepair.plan(typed: typed, staleCount: staleCount, replacement: replacement) else {
        check(false, "\(name): valid input refused")
        return
    }
    check(plan.expected == expected, "\(name): wrong verified span")
    check(plan.replacement == physicalReplacement, "\(name): wrong replacement")
    check(plan.count == expected.count, "\(name): count is not in graphemes")
    check(plan.contextCount == contextCount, "\(name): wrong context count")
    check(String(typed.suffix(plan.count)) == plan.expected, "\(name): selection exceeds known tail")

    // Exercise the physical edit. Padding must change neither the resulting
    // document nor any text preceding the caller's original stale tail.
    let documentPrefix = "ข้อความเดิม 👩‍💻 | "
    let actual = documentPrefix + String(typed.dropLast(plan.count)) + plan.replacement
    let wanted = documentPrefix + String(typed.dropLast(staleCount)) + replacement
    check(actual == wanted, "\(name): context padding changes final document")
    print("PASS: \(name)")
}

verify("Thai trailing tone mark", typed: "ไปก", staleCount: 1, replacement: "ก่",
       expected: "ไปก", physicalReplacement: "ไปก่", contextCount: 2)
verify("Thai tone mark plus new speech", typed: "สวัสดีครั", staleCount: 1, replacement: "รับผม",
       expected: "ดีครั", physicalReplacement: "ดีครับผม", contextCount: 2)
verify("two-grapheme stale tail", typed: "abcxy", staleCount: 2, replacement: "XYZ",
       expected: "cxy", physicalReplacement: "cXYZ", contextCount: 1)
verify("combining context stays intact", typed: "ก่ขค", staleCount: 1, replacement: "ฆ",
       expected: "ก่ขค", physicalReplacement: "ก่ขฆ", contextCount: 2)
verify("emoji context stays intact", typed: "👩‍💻ก่ข", staleCount: 1, replacement: "ค",
       expected: "👩‍💻ก่ข", physicalReplacement: "👩‍💻ก่ค", contextCount: 2)
verify("one-grapheme utterance has no context", typed: "ก", staleCount: 1, replacement: "ก่",
       expected: "ก", physicalReplacement: "ก่", contextCount: 0)
verify("partial context is insufficient", typed: "ขก", staleCount: 1, replacement: "ก่",
       expected: "ก", physicalReplacement: "ก่", contextCount: 0)
verify("two-grapheme utterance has no context", typed: "กข", staleCount: 2, replacement: "คฆ",
       expected: "กข", physicalReplacement: "คฆ", contextCount: 0)
verify("pure one-grapheme retraction", typed: "ก่ขค", staleCount: 1, replacement: "",
       expected: "ก่ขค", physicalReplacement: "ก่ข", contextCount: 2)
verify("pure two-grapheme retraction", typed: "abcd", staleCount: 2, replacement: "",
       expected: "bcd", physicalReplacement: "b", contextCount: 1)
verify("already long span stays unchanged", typed: "abcdef", staleCount: 3, replacement: "DEFG",
       expected: "def", physicalReplacement: "DEFG", contextCount: 0)
verify("whole long utterance stays unchanged", typed: "ก่ขคง", staleCount: 4, replacement: "ใหม่",
       expected: "ก่ขคง", physicalReplacement: "ใหม่", contextCount: 0)
verify("append does not expand selection", typed: "abc", staleCount: 0, replacement: "d",
       expected: "", physicalReplacement: "d", contextCount: 0)
verify("empty input and no-op", typed: "", staleCount: 0, replacement: "",
       expected: "", physicalReplacement: "", contextCount: 0)

check(TailRepair.plan(typed: "abc", staleCount: -1, replacement: "x") == nil,
      "negative count must be refused")
check(TailRepair.plan(typed: "abc", staleCount: 4, replacement: "x") == nil,
      "count past ledger must be refused")
check(TailRepair.plan(typed: "ก่", staleCount: 2, replacement: "x") == nil,
      "UTF-16 count must not masquerade as grapheme count")
check(TailRepair.plan(typed: "abc", staleCount: Int.max, replacement: "x") == nil,
      "oversized count must be refused without arithmetic overflow")
print("ALL PASS (\(checks) checks)")
