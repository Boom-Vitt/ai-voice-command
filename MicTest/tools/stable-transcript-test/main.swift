import Foundation

var checks = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor func verifySequence(_ name: String, partials: [String], final: String? = nil,
                               expected: String?) {
    var buffer = StableTranscriptBuffer()
    for partial in partials {
        buffer.updatePartial(partial)
    }
    check(buffer.finish(final: final) == expected, "\(name): wrong complete transcript")
    check(buffer.finish(final: final) == nil, "\(name): duplicate insertion")
    print("PASS: \(name)")
}

verifySequence("Thai trailing tone revisions", partials: ["ก", "ก่", "ก่อน"], expected: "ก่อน")
verifySequence("Thai word merge", partials: ["ไม่ เป", "ไม่เป็นไร"], expected: "ไม่เป็นไร")
verifySequence("English fragment revision", partials: ["au", "auto", "auto fix correction"],
               expected: "auto fix correction")
verifySequence("Thai and English code switching",
               partials: ["อยู่ตรงนี้auครับ", "อยู่ตรงนี้ auto ครับ"],
               final: "อยู่ตรงนี้ auto fix correction ครับ", expected: "อยู่ตรงนี้ auto fix correction ครับ")
verifySequence("user phrase is preserved literally", partials: ["อยู่ตรงนี้auครับ"],
               expected: "อยู่ตรงนี้auครับ")
verifySequence("emoji grapheme revisions", partials: ["👩", "👩‍", "👩‍💻", "👩‍💻 ก่อนไป"],
               expected: "👩‍💻 ก่อนไป")
verifySequence("empty final uses last partial", partials: ["ข้อความล่าสุด"],
               final: "", expected: "ข้อความล่าสุด")
verifySequence("blank final uses last partial", partials: ["ข้อความล่าสุด"],
               final: "\n\t  ", expected: "ข้อความล่าสุด")
verifySequence("normal stop uses last partial", partials: ["first draft", "last complete draft"],
               expected: "last complete draft")
verifySequence("final replaces a longer draft", partials: ["incorrect extra words"],
               final: "correct", expected: "correct")
verifySequence("final is accepted without partials", partials: [],
               final: "สวัสดีครับ", expected: "สวัสดีครับ")
verifySequence("blank partial does not erase text", partials: ["keep this", "", "\n\t  "],
               expected: "keep this")
verifySequence("empty utterance", partials: [], expected: nil)
verifySequence("whitespace-only utterance", partials: ["", "\n\t  ", "\u{00A0}"],
               final: "\n", expected: nil)
verifySequence("partial surrounding whitespace remains", partials: ["  ก่อนไป 👩‍💻\n"],
               expected: "  ก่อนไป 👩‍💻\n")
verifySequence("final surrounding whitespace remains", partials: ["draft"],
               final: "\t  final\n", expected: "\t  final\n")

var buffer = StableTranscriptBuffer()
buffer.updatePartial("first draft")
check(buffer.finish(final: "first final") == "first final", "initial final must emit")
buffer.updatePartial("late partial")
check(buffer.finish(final: "late different final") == nil, "late callbacks must not reopen utterance")
buffer.reset()
check(buffer.finish() == nil, "reset must discard old transcript")
buffer.updatePartial("late after empty finish")
check(buffer.finish(final: "late after empty finish") == nil,
      "empty finish must also consume the utterance")
buffer.reset()
buffer.updatePartial("second utterance")
check(buffer.finish() == "second utterance", "reset must allow new utterance")
buffer.reset()
buffer.updatePartial("abandoned draft")
buffer.reset()
check(buffer.finish(final: "next utterance") == "next utterance", "reset must discard pending draft")

// Swift string equality accepts canonically equivalent spellings. Compare
// UTF-8 too so this specifically catches unintended normalization or trimming.
let exactUnicode = "  e\u{0301} ก่ 👩‍💻\n"
buffer.reset()
buffer.updatePartial(exactUnicode)
let untouchedPartial = buffer.finish()
check(untouchedPartial.map { Array($0.utf8) } == Array(exactUnicode.utf8),
      "partial bytes must remain unchanged")
buffer.reset()
let untouchedFinal = buffer.finish(final: exactUnicode)
check(untouchedFinal.map { Array($0.utf8) } == Array(exactUnicode.utf8),
      "final bytes must remain unchanged")

print("ALL PASS (\(checks) checks)")
