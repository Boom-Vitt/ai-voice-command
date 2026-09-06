import Foundation
extension GeminiClient: CorrectionProvider {
    var displayName: String { "Gemini" }
    var sendsAudioOffDevice: Bool { true }
    func isAvailable() async -> Bool { isConfigured }
}
extension CorrectionProvider where Self == GeminiClient {
    func transcribe(wav: Data, keyterms: [String]) async throws -> CorrectionResult {
        let r: GeminiClient.Result = try await transcribe(wav: wav, keyterms: keyterms)
        return CorrectionResult(text: r.text, elapsedMS: r.elapsedMS, audioTokens: r.audioTokens)
    }
}
