import Foundation

var checks = 0
var failures = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(message)") }
}

var delivery = PendingTranscript()
var document = ""
delivery.append("สวัสดีครับ")
let failed = delivery.deliver { _ in "temporarily unavailable" }
expect(failed != nil, "a refused write remains visible")
expect(delivery.transcript == "สวัสดีครับ", "recovery retains the complete transcript")
delivery.append("เปิด Terminal")
let recovered = delivery.deliver { text in document += text; return nil }
expect(recovered == nil, "a later successful write recovers")
expect(document == "สวัสดีครับ เปิด Terminal", "retry includes the refused prefix in order")
delivery.deliver { text in document += text; return nil }
expect(document == "สวัสดีครับ เปิด Terminal", "successful output is never delivered twice")
delivery.append("แล้วพิมพ์ต่อ")
delivery.deliver { text in document += text; return nil }
expect(document == "สวัสดีครับ เปิด Terminal แล้วพิมพ์ต่อ", "new chunks append only their new text")

var other = PendingTranscript()
other.append("อีกหน้าต่าง")
var otherDocument = ""
other.deliver { text in otherDocument += text; return nil }
expect(otherDocument == "อีกหน้าต่าง", "a new capture starts an independent transcript")
expect(document == "สวัสดีครับ เปิด Terminal แล้วพิมพ์ต่อ", "another capture cannot change prior output")

var noText = PendingTranscript()
noText.append("")
var writes = 0
noText.deliver { _ in writes += 1; return nil }
expect(writes == 0, "empty transcription performs no write")

var repeatedFailure = PendingTranscript()
repeatedFailure.append("เดี๋ยวแก้ให้")
repeatedFailure.deliver { _ in "field moved" }
repeatedFailure.deliver { _ in "field moved" }
repeatedFailure.append("ครับ")
var recoveredDocument = ""
repeatedFailure.deliver { text in recoveredDocument += text; return nil }
expect(recoveredDocument == "เดี๋ยวแก้ให้ ครับ", "repeated refusals preserve Thai clusters and order")
expect(repeatedFailure.pendingText.isEmpty, "successful delivery clears only the pending text")

var cancelled = PendingTranscript()
cancelled.append("เก็บไว้คัดลอก")
cancelled.cancelDelivery(reason: "screen locked")
cancelled.append("ผลที่มาช้า")
var cancelledWrites = 0
let cancellation = cancelled.deliver { _ in cancelledWrites += 1; return nil }
expect(cancelledWrites == 0, "emergency stop prevents a delayed write")
expect(cancellation == "screen locked", "cancellation retains the explicit stop reason")
expect(cancelled.transcript == "เก็บไว้คัดลอก ผลที่มาช้า", "late results remain copyable after cancellation")
var newCapture = PendingTranscript()
newCapture.append("เริ่มใหม่")
newCapture.deliver { _ in nil }
cancelled.deliver { _ in cancelledWrites += 1; return nil }
expect(cancelledWrites == 0, "another recording cannot reactivate cancelled delivery")

print("Pending transcript: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
