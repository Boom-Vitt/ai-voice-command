import Foundation
import Speech

setvbuf(stdout, nil, _IOLBF, 0)

func name(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .authorized: return "authorized"
    @unknown default: return "unknown(\(s.rawValue))"
    }
}
print("bundleID: \(Bundle.main.bundleIdentifier ?? "nil")")
print("before: \(name(SFSpeechRecognizer.authorizationStatus()))")
let sem = DispatchSemaphore(value: 0)
SFSpeechRecognizer.requestAuthorization { st in
    print("callback: \(name(st))")
    sem.signal()
}
let r0 = sem.wait(timeout: .now() + 25)
print("wait: \(r0 == .success ? "returned" : "TIMED OUT after 25s")")
print("after: \(name(SFSpeechRecognizer.authorizationStatus()))")
let r = SFSpeechRecognizer(locale: Locale(identifier: "th-TH"))
print("recognizer=\(r != nil) available=\(r?.isAvailable ?? false) supportsOnDevice=\(r?.supportsOnDeviceRecognition ?? false)")
