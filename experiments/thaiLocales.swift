import Foundation
import Speech

@main
struct T {
  static func main() async {
    print("=== OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

    // 1. SpeechTranscriber (new macOS 26 API)
    let sup = await SpeechTranscriber.supportedLocales
    print("=== SpeechTranscriber.supportedLocales count=\(sup.count)")
    let ids = sup.map { $0.identifier(.bcp47) }.sorted()
    print(ids.joined(separator: " "))
    let thai = ids.filter { $0.lowercased().hasPrefix("th") }
    print("=== THAI in supportedLocales: \(thai.isEmpty ? "NO" : thai.joined(separator: ","))")

    let inst = await SpeechTranscriber.installedLocales
    let instIds = inst.map { $0.identifier(.bcp47) }.sorted()
    print("=== SpeechTranscriber.installedLocales count=\(inst.count): \(instIds.joined(separator: " "))")
    print("=== THAI installed: \(instIds.contains(where: {$0.lowercased().hasPrefix("th")}) ? "YES" : "NO")")

    // 2. Legacy SFSpeechRecognizer
    let sf = SFSpeechRecognizer.supportedLocales()
    let sfIds = sf.map { $0.identifier }.sorted()
    print("=== SFSpeechRecognizer.supportedLocales count=\(sf.count)")
    let sfThai = sfIds.filter { $0.lowercased().hasPrefix("th") }
    print("=== THAI in SFSpeechRecognizer: \(sfThai.isEmpty ? "NO" : sfThai.joined(separator: ","))")

    // 3. On-device support for Thai via SFSpeechRecognizer
    for cand in ["th-TH","th_TH"] {
      if let r = SFSpeechRecognizer(locale: Locale(identifier: cand)) {
        print("=== SFSpeechRecognizer(\(cand)): available=\(r.isAvailable) supportsOnDevice=\(r.supportsOnDeviceRecognition)")
      } else {
        print("=== SFSpeechRecognizer(\(cand)): nil (locale unsupported)")
      }
    }
    // control: en-US
    if let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) {
      print("=== CONTROL SFSpeechRecognizer(en-US): available=\(r.isAvailable) supportsOnDevice=\(r.supportsOnDeviceRecognition)")
    }
  }
}
