import Foundation
import Speech

func recognize(url: URL, locale: String, onDevice: Bool, ctx: [String]) async -> String {
  guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return "<no recognizer for \(locale)>" }
  let req = SFSpeechURLRecognitionRequest(url: url)
  req.requiresOnDeviceRecognition = onDevice
  req.addsPunctuation = true
  if !ctx.isEmpty { req.contextualStrings = ctx }
  return await withCheckedContinuation { (c: CheckedContinuation<String,Never>) in
    var done = false
    rec.recognitionTask(with: req) { res, err in
      if done { return }
      if let e = err { done = true; c.resume(returning: "<ERR \(e.localizedDescription)>"); return }
      if let r = res, r.isFinal { done = true; c.resume(returning: r.bestTranscription.formattedString) }
    }
  }
}

@main struct M {
  static func main() async {
    let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool,Never>) in
      SFSpeechRecognizer.requestAuthorization { s in c.resume(returning: s == .authorized) }
    }
    print("AUTH: \(ok)")
    guard ok else { print("NOT AUTHORIZED - cannot test"); return }

    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("thaitest")
    let cases: [(String,String)] = [
      ("cs1.wav","เดี๋ยว deploy ให้ก่อนนะ"),
      ("cs2.wav","meeting ตอนบ่าย 3 โมง"),
      ("cs3.wav","ช่วย refactor function นี้หน่อย"),
      ("cs4.wav","ช่วย commit แล้ว push ขึ้น branch main ให้หน่อย"),
      ("th_only.wav","สวัสดีครับ วันนี้อากาศดีมาก"),
    ]
    let tech = ["deploy","refactor","function","commit","push","branch","main","meeting"]

    for (f, truth) in cases {
      let u = dir.appendingPathComponent(f)
      print("\n########## \(f)")
      print("  TRUTH      : \(truth)")
      let a = await recognize(url: u, locale: "th-TH", onDevice: true, ctx: [])
      print("  th-TH ONDEV: \(a)")
      let b = await recognize(url: u, locale: "th-TH", onDevice: false, ctx: [])
      print("  th-TH CLOUD: \(b)")
      let c2 = await recognize(url: u, locale: "th-TH", onDevice: true, ctx: tech)
      print("  th-TH +CTX : \(c2)")
      let d = await recognize(url: u, locale: "en-US", onDevice: true, ctx: [])
      print("  en-US ONDEV: \(d)")
    }
  }
}
