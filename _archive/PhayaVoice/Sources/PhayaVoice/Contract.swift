import Foundation

// Shared contract. Modules are written independently against this file.
// Do not change these declarations without updating every implementor.

/// Where a transcript came from.
enum Engine: String, Codable {
    case localWhisper   // whisper-server on 127.0.0.1, model resident
    case fal            // fal.ai cloud
}

struct TranscriptionRequest {
    let audioURL: URL          // 16 kHz mono WAV on disk
    let language: String?      // "th", "en", nil = auto
    let glossary: [String]     // English terms to bias toward; may be empty
}

struct TranscriptionResult {
    let text: String
    let engine: Engine
    let latencyMS: Int
    let promptApplied: Bool
    let error: String?
    var ok: Bool { error == nil }
}

protocol Transcriber: AnyObject {
    var engine: Engine { get }
    /// Must never throw for runtime failures — return a result with `error` set.
    func transcribe(_ req: TranscriptionRequest) async -> TranscriptionResult
    /// True when this transcriber can serve a request right now.
    func isReady() async -> Bool
}

/// Delivers text into whatever app currently has keyboard focus.
protocol TextInjecting: AnyObject {
    /// Returns nil on success, or a human-readable reason it could not inject.
    @MainActor func inject(_ text: String) -> String?
    /// True if the frontmost app is holding Secure Event Input (password field,
    /// Terminal secure entry, or a Cursor/Electron leak) — injection is unsafe.
    @MainActor func secureInputActive() -> Bool
}

/// Lifecycle of one dictation.
enum DictationState: Equatable {
    case idle
    case recording(startedAt: Date)
    case transcribing
    case injecting
    case failed(String)
}

protocol DictationHUD: AnyObject {
    @MainActor func show(_ state: DictationState)
    @MainActor func setLevel(_ rms: Float)   // 0…1, for the live meter
    @MainActor func hide()
}

/// User-visible settings. Persisted in UserDefaults; no settings window in v1.
struct Settings {
    static let shared = Settings()
    /// Hold this to talk. Right-Option by default: a modifier that nothing else claims.
    var hotkeyKeyCode: UInt16 { UInt16(UserDefaults.standard.integer(forKey: "hotkeyKeyCode")) }
    var language: String { UserDefaults.standard.string(forKey: "language") ?? "th" }
    var engine: Engine { Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .localWhisper }
    var whisperPort: Int { let p = UserDefaults.standard.integer(forKey: "whisperPort"); return p == 0 ? 8177 : p }
    var modelPath: String {
        UserDefaults.standard.string(forKey: "modelPath")
        ?? (NSHomeDirectory() + "/.cache/hyperframes/whisper/models/ggml-large-v3.bin")
    }
}
