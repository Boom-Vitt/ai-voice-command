import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print((ok ? "  PASS " : "  FAIL ") + what)
    if !ok { failures += 1 }
}
func bytes(_ s: String) -> Int { s.utf8.count }
func validUTF8(_ s: String) -> Bool { String(data: Data(s.utf8), encoding: .utf8) == s }

// 1. The eight measured terms (P1/P2 in TEST-2026-09-03-turbo-server-5clip.txt).
let measured = ["deploy", "refactor", "function", "commit", "push", "branch", "main", "meeting"]
let p8 = P.promptString(from: measured)
print("[1] 8 measured terms -> \(bytes(p8)) bytes, \(p8.count) chars")
print("    \(p8)")
check(measured.allSatisfy { p8.contains($0) }, "contains every term")
check(!p8.contains(","), "contains no comma")
check(bytes(p8) <= 800, "<= 800 bytes")
check(validUTF8(p8), "valid UTF-8 round trip")

// 2. The app's full glossary (cloudKeyterms, main.swift) — size for the doc comment.
let appGlossary = ["deploy", "commit", "branch", "main", "refactor",
                   "push", "merge", "rebase", "pull request", "API",
                   "database", "function", "variable", "debug", "build",
                   "test", "server", "client", "endpoint", "repository"]
let p20 = P.promptString(from: appGlossary)
print("[2] app's 20-term glossary -> \(bytes(p20)) bytes, \(p20.count) chars")
print("    \(p20)")
check(appGlossary.allSatisfy { p20.contains($0) }, "contains every term")
check(!p20.contains(","), "contains no comma")
check(bytes(p20) <= 800, "<= 800 bytes")

// 3. Sixty long terms: must truncate by dropping WHOLE terms, stay <= 800 bytes,
//    and end on a complete Character.
var long: [String] = []
for i in 0..<60 {
    long.append(i % 2 == 0
        ? "ระบบทดสอบการรู้จำเสียงภาษาไทยหมายเลข\(i)"          // Thai, with combining marks
        : "long_english_identifier_number_\(i)_padding")   // ASCII
}
let p60 = P.promptString(from: long)
let kept60 = long.filter { p60.contains($0) }
let dropped60 = long.filter { !p60.contains($0) }
print("[3] 60 long terms -> \(bytes(p60)) bytes, kept \(kept60.count), dropped \(dropped60.count)")
print("    \(p60)")
check(bytes(p60) <= 800, "<= 800 bytes")
check(kept60.count < 60 && !dropped60.isEmpty, "some terms were dropped")
// Every kept term appears whole, and the output is EXACTLY the kept terms joined
// by the opening + rotating connectives — i.e. nothing was cut.
let connectives = ["แล้ว", "กับ", "ก่อน", "แล้วค่อย"]
func rebuild(_ terms: [String]) -> String {
    var s = ""
    for (k, t) in terms.enumerated() {
        s += (k == 0 ? "วันนี้จะ " : " " + connectives[(k - 1) % 4] + " ") + t
    }
    return s
}
check(p60 == rebuild(kept60), "output == kept terms joined whole (no term cut)")
check(p60.last == kept60.last?.last, "last Character is the last term's last Character")
check(validUTF8(p60), "valid UTF-8 round trip")
// A dropped term must not appear even partially at the tail.
check(dropped60.allSatisfy { d in !p60.hasSuffix(String(d.prefix(5))) }, "no partial term at tail")

// 4. Skip-and-continue at the cap: a term that does not fit is dropped and LATER
//    shorter terms are still tried. Sizes chosen so "commit" lands on exactly 800.
// Four distinct 135-byte Thai terms (a digit suffix would add bytes and shift the sum).
let k45a = String(repeating: "ก", count: 45)
let k45b = String(repeating: "ง", count: 45)
let k45c = String(repeating: "จ", count: 45)
let k45d = String(repeating: "ฉ", count: 45)
let k50 = String(repeating: "ข", count: 50)   // 150 bytes (clampTerms keeps 50 chars)
let k50b = String(repeating: "ค", count: 50)  // 150 bytes — will not fit
// 160 + 149 + 146 + 149 + 176 = 780, k50b (+164) dropped, " แล้ว commit" (+20) = 800,
// " กับ push" (+15) would be 815 and is dropped.
let atCap = [k45a, k45b, k45c, k45d, k50, k50b, "commit", "push"]
let pCap = P.promptString(from: atCap)
print("[4] cap test -> \(bytes(pCap)) bytes")
check(pCap.contains(k50), "50-char term that fits is kept")
check(!pCap.contains(k50b), "50-char term that does not fit is dropped whole")
check(pCap.contains("commit"), "'commit' after the dropped term is still tried and kept")
check(!pCap.contains("push"), "'push' after that does not fit and is dropped")
check(bytes(pCap) == 800, "exactly 800 bytes (arithmetic check)")

// 5. Empty and all-blank glossaries render to "".
check(P.promptString(from: []) == "", "empty list -> empty string")
check(P.promptString(from: ["  ", "\n\t", ""]) == "", "all-blank list -> empty string")

// 6. Terms with Thai combining marks (sara am, tone marks, leading vowels) stay whole.
let thai = ["กำลัง", "เดี๋ยว", "น้ำ", "ที่", "ผู้ใช้", "แล้วก็"]
let pThai = P.promptString(from: thai)
print("[6] Thai combining marks -> \(pThai)")
check(thai.allSatisfy { pThai.contains($0) }, "every Thai term present whole")
check(pThai == rebuild(thai), "output == terms joined (no cluster split)")
check(pThai.unicodeScalars.count == rebuild(thai).unicodeScalars.count, "scalar count matches")
check(validUTF8(pThai), "valid UTF-8 round trip")

// 7. Internal whitespace collapses; duplicates removed by clampTerms.
let messy = ["pull\nrequest", "a  b", "deploy", "deploy", " commit "]
let pMessy = P.promptString(from: messy)
print("[7] messy -> \(pMessy)")
check(!pMessy.contains("\n"), "no newline in output")
check(pMessy.contains("pull request") && pMessy.contains("a b"), "internal whitespace collapsed")
check(pMessy.components(separatedBy: "deploy").count == 2, "duplicate dropped")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
