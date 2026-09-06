import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print((ok ? "  PASS " : "  FAIL ") + what)
    if !ok { failures += 1 }
}
func offset(of s: String, in d: Data) -> Int? { d.range(of: Data(s.utf8))?.lowerBound }

// A tiny "WAV": RIFF header bytes plus zeros. Content is irrelevant to the body builder.
let wav = Data([0x52, 0x49, 0x46, 0x46] + [UInt8](repeating: 0, count: 60))

// The exact path the CorrectionProvider conformance takes: render, then nil-out when empty.
func body(for keyterms: [String]) -> (data: Data, boundary: String) {
    let prompt = WhisperClient.promptString(from: keyterms)
    return WhisperClient.multipartBody(wav: wav, filename: "audio.wav",
                                       language: WhisperClient.serverLanguage,
                                       prompt: prompt.isEmpty ? nil : prompt)
}

// 1. Non-empty keyterms -> a prompt part is present, last, and carries the sentence.
let terms = ["deploy", "commit", "branch main"]
let with = body(for: terms)
let sentence = WhisperClient.promptString(from: terms)
print("[1] with keyterms: \(with.data.count) bytes, boundary \(with.boundary)")
let pPrompt = offset(of: "name=\"prompt\"", in: with.data)
let pFile = offset(of: "name=\"file\"; filename=\"audio.wav\"", in: with.data)
let pLang = offset(of: "name=\"language\"", in: with.data)
let pFmt = offset(of: "name=\"response_format\"", in: with.data)
check(pPrompt != nil, "body contains name=\"prompt\"")
check(pFile != nil && pLang != nil && pFmt != nil, "file, language, response_format parts present")
if let f = pFile, let l = pLang, let r = pFmt, let p = pPrompt {
    check(f < l && l < r && r < p, "part order: file < language < response_format < prompt")
}
let promptPart = "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n" + sentence
    + "\r\n--" + with.boundary + "--\r\n"
check(with.data.range(of: Data(promptPart.utf8)) != nil, "prompt value is the rendered sentence, CRLF-framed, then closing boundary")
check(with.data.range(of: wav) != nil, "raw WAV bytes present and intact")
check(with.data.suffix(("--" + with.boundary + "--\r\n").utf8.count) == Data(("--" + with.boundary + "--\r\n").utf8), "body ends with the closing boundary")
check(with.data.range(of: Data("\n".utf8)).map { i in with.data[i.lowerBound - 1] == 0x0D } ?? true, "first LF is preceded by CR")
check(!sentence.contains(","), "rendered prompt has no comma")

// 2. Empty keyterms -> NO prompt part anywhere.
let without = body(for: [])
print("[2] without keyterms: \(without.data.count) bytes")
check(offset(of: "name=\"prompt\"", in: without.data) == nil, "body does NOT contain name=\"prompt\"")
check(offset(of: "prompt", in: without.data) == nil, "the word 'prompt' appears nowhere in the body")
check(offset(of: "name=\"response_format\"", in: without.data) != nil, "response_format still present")

// 3. The default-argument path and an explicit "" both omit the part too.
let legacy = WhisperClient.multipartBody(wav: wav, filename: "audio.wav", language: "th")
check(offset(of: "name=\"prompt\"", in: legacy.data) == nil, "multipartBody(wav:filename:language:) has no prompt part")
let emptyPrompt = WhisperClient.multipartBody(wav: wav, filename: "audio.wav", language: "th", prompt: "")
check(offset(of: "name=\"prompt\"", in: emptyPrompt.data) == nil, "prompt: \"\" emits no prompt part")
check(legacy.data.count == emptyPrompt.data.count, "no-prompt and empty-prompt bodies are the same size")

// 4. Conformance surface, no network: names and the privacy flag.
let client = WhisperClient()
let provider: any CorrectionProvider = client
print("[4] displayName=\"\(provider.displayName)\" sendsAudioOffDevice=\(provider.sendsAudioOffDevice)")
check(provider.displayName == "local whisper (large-v3-turbo)", "displayName uses the stored model name")
check(provider.sendsAudioOffDevice == false, "sendsAudioOffDevice is false")
check(WhisperClient(modelName: "large-v3").displayName == "local whisper (large-v3)", "modelName is injectable")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
