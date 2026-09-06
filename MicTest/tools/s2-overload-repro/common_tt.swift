import Foundation
protocol CorrectionProvider: Sendable {
    var displayName: String { get }
    var sendsAudioOffDevice: Bool { get }
    func isAvailable() async -> Bool
    func transcribe(wav: Data, keyterms: [String]) async throws -> CorrectionResult
}
struct CorrectionResult: Sendable {
    let text: String
    let elapsedMS: Double
    let audioTokens: Int
}
struct GeminiClient: Sendable {
    struct Result: Sendable {
        let text: String
        let elapsedMS: Double
        let audioTokens: Int
        let totalTokens: Int
    }
    var isConfigured: Bool { true }
    func transcribe(wav: Data, keyterms: [String]) async throws -> Result {
        Result(text: "gemini", elapsedMS: 1, audioTokens: 2, totalTokens: 3)
    }
}
// main.swift's current call site, verbatim in shape:
func callSite(client: GeminiClient) async throws -> String {
    let result = try await client.transcribe(wav: Data(), keyterms: ["a"])
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(text) \(result.elapsedMS) \(result.audioTokens) total=\(result.totalTokens)"
}
func viaExistential(_ p: any CorrectionProvider) async throws -> String {
    let r = try await p.transcribe(wav: Data(), keyterms: [])
    return "\(p.displayName): \(r.text) \(r.audioTokens)"
}
