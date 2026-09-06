// Standalone check of the divergence-repair cap. `commonPrefixLength` and
// `commonSuffixLength` are copied VERBATIM from main.swift (as free functions), and the
// gate below is the same formula and the same two constants `repairDivergence` uses.
import Foundation

let reanchorMaxStaleChars = 10
let retractionMaxStaleChars = 4

func commonPrefixLength(_ a: String, _ b: String) -> Int {
    var n = 0
    var ia = a.startIndex
    var ib = b.startIndex
    while ia < a.endIndex, ib < b.endIndex, a[ia] == b[ib] {
        n += 1
        ia = a.index(after: ia)
        ib = b.index(after: ib)
    }
    return n
}

func commonSuffixLength(_ a: String, _ b: String) -> Int {
    var n = 0
    var ia = a.endIndex
    var ib = b.endIndex
    while ia > a.startIndex, ib > b.startIndex {
        let pa = a.index(before: ia)
        let pb = b.index(before: ib)
        guard a[pa] == b[pb] else { break }
        n += 1
        ia = pa
        ib = pb
    }
    return n
}

enum Verdict: String { case repairs = "REPAIRS", refusedTooLarge = "REFUSED (too large)",
                            refusedRetraction = "REFUSED (retraction)" }

/// Exactly the decision `repairDivergence` makes on `expected` (stale tail) and
/// `replacement`, both already cut at the common prefix.
func gate(expected: String, replacement: String) -> (Verdict, suffix: Int, effective: Int) {
    let staleCount = expected.count
    let suffix = commonSuffixLength(expected, replacement)
    let effectiveChange = staleCount - suffix
    if replacement.isEmpty, staleCount > retractionMaxStaleChars {
        return (.refusedRetraction, suffix, effectiveChange)
    }
    if effectiveChange > reanchorMaxStaleChars {
        return (.refusedTooLarge, suffix, effectiveChange)
    }
    return (.repairs, suffix, effectiveChange)
}

var failures = 0
@MainActor func check(_ name: String, expected: String, replacement: String,
           want: Verdict, wantSuffix: Int? = nil, wantEffective: Int? = nil) {
    let (got, suffix, eff) = gate(expected: expected, replacement: replacement)
    var ok = got == want
    if let s = wantSuffix, s != suffix { ok = false }
    if let e = wantEffective, e != eff { ok = false }
    // The suffix must be a whole number of Characters of BOTH strings, and the cut it
    // implies must sit on a cluster boundary in each: re-slicing by Character and
    // comparing is the check, because Character iteration cannot split a cluster.
    let tailA = String(expected.suffix(suffix)), tailB = String(replacement.suffix(suffix))
    if tailA != tailB || tailA.count != suffix { ok = false }
    let cutA = expected.index(expected.endIndex, offsetBy: -suffix)
    if let sc = expected[cutA...].unicodeScalars.first,
       sc.properties.generalCategory == .nonspacingMark
        || sc.properties.generalCategory == .spacingMark { ok = false }
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    print("      stale \(expected.count)  replacement \(replacement.count)  "
        + "common suffix \(suffix)  effective change \(eff)  → \(got.rawValue)")
}

// Distinct Thai clusters to build long strings whose prefix/suffix content is controlled.
// Each is base+mark or a pre-posed vowel pair, so cluster counts differ from scalar counts.
let pool = ["ก่","ขี","คุ","ง้","จ๋","ฉั","ชิ","ซื","ญู","ด็","ตํ","ถี","ที","ธ์","นั","บ่","ป้","ผู","ฝึ","พั"]
func clusters(_ n: Int, seed: Int) -> String {
    (0..<n).map { pool[($0 * 7 + seed) % pool.count] }.joined()
}
let sharedTail170 = clusters(170, seed: 3)
precondition(sharedTail170.count == 170)

// 1. run 5 line 115 shape, but the last 170 clusters identical: only the head differs.
check("stale 175 / replacement 178, last 170 identical (legitimate tail re-emit)",
      expected: clusters(5, seed: 1) + sharedTail170,
      replacement: clusters(8, seed: 2) + sharedTail170,
      want: .repairs, wantSuffix: 170, wantEffective: 5)

// 2. run 5 line 115 as it actually was: the whole sentence rewritten, nothing shared.
check("stale 175 / replacement 178, no common suffix (the run-5 wipe)",
      expected: clusters(175, seed: 1),
      replacement: clusters(178, seed: 2),
      want: .refusedTooLarge, wantSuffix: 0, wantEffective: 175)

// 3. run 5 line 86 shape with an 80-cluster shared tail: 13 destroyed, the borderline.
let sharedTail80 = clusters(80, seed: 5)
check("stale 93 / replacement 83, 80-cluster suffix (borderline: 13 > cap 10)",
      expected: clusters(13, seed: 1) + sharedTail80,
      replacement: clusters(3, seed: 2) + sharedTail80,
      want: .refusedTooLarge, wantSuffix: 80, wantEffective: 13)

// 4. run 5 lines 34/123: a 3-cluster pure delete stays allowed (≤ 4).
check("stale 3 / replacement 0 (pure retraction within cap 4)",
      expected: clusters(3, seed: 1), replacement: "",
      want: .repairs, wantSuffix: 0, wantEffective: 3)

// 5. an 18-cluster pure delete is refused as a retraction, not merely as too large.
check("stale 18 / replacement 0 (pure retraction past cap 4)",
      expected: clusters(18, seed: 1), replacement: "",
      want: .refusedRetraction, wantSuffix: 0, wantEffective: 18)

// 6. Thai with combining marks, run through the real prefix cut first.
do {
    let ledger = "สวัสดีครับ", text = "สวัสดีคร้าบ"
    let lcp = commonPrefixLength(ledger, text)
    let expected = String(ledger.dropFirst(lcp)), replacement = String(text.dropFirst(lcp))
    print("      (lcp \(lcp): expected \"\(expected)\" [\(expected.count)], "
        + "replacement \"\(replacement)\" [\(replacement.count)])")
    check("Thai combining marks: สวัสดีครับ → สวัสดีคร้าบ",
          expected: expected, replacement: replacement,
          want: .repairs, wantSuffix: 1, wantEffective: 1)
}

// 7. the cut must never land inside a cluster: a scalar walk would call these one unit
//    alike (both end in U+0E48); a Character walk says they share nothing.
check("cluster integrity: บ่ vs ก่ share a mark but not a cluster → suffix 0",
      expected: "บ่", replacement: "ก่", want: .repairs, wantSuffix: 0, wantEffective: 1)

// 8. the shorter tail is a proper suffix of the longer: the recogniser INSERTED before
//    it, nothing typed is lost, effective change 0.
check("insertion before an identical tail: stale 2 / replacement 3, suffix 2",
      expected: "BC", replacement: "ABC", want: .repairs, wantSuffix: 2, wantEffective: 0)

// 9. run 5 line 144: a small revision with a burst of new speech behind it. Measured on
//    what is DESTROYED this repairs; a bound on max(stale, replacement) would refuse it
//    and the re-anchor would drop nine clusters of speech.
check("run 5 line 144: stale 3 / replacement 12, no suffix (growth is not a wipe)",
      expected: clusters(3, seed: 1), replacement: clusters(12, seed: 2),
      want: .repairs, wantSuffix: 0, wantEffective: 3)

// 10. exactly at the cap: 10 destroyed repairs, 11 does not.
check("exactly at cap: stale 10 / replacement 10, no suffix",
      expected: clusters(10, seed: 1), replacement: clusters(10, seed: 2),
      want: .repairs, wantEffective: 10)
check("one past cap: stale 11 / replacement 11, no suffix",
      expected: clusters(11, seed: 1), replacement: clusters(11, seed: 2),
      want: .refusedTooLarge, wantEffective: 11)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
