//  CorrectionProvider.swift
//
//  The seam between main.swift's post-utterance correction pass and whichever engine
//  re-transcribes a finished utterance for it.
//
//  ── WHAT THE CORRECTION PASS IS ──────────────────────────────────────────────────────
//
//  Apple's on-device recogniser (`LiveRecognizer`) types Thai as the user speaks. When an
//  utterance finishes, main.swift's `cloudPass` sends that utterance's WAV — one complete
//  16 kHz mono 16-bit file from `AudioPipeline.Chunk.wav`, header included — to a second
//  engine, and `applyCloudResult(text:utteranceID:typedSpan:typedSpanSeq:elapsedMS:
//  audioTokens:generation:)` repairs the already-typed span with what comes back. Which
//  second engine that is — `LocalWhisperProvider` over a `whisper-server` this app owns
//  on loopback, or `GeminiClient` — is main.swift's `CorrectionProviderKind` setting
//  (`local` when a model and the binary exist, `gemini` only by explicit choice, `off`
//  otherwise). `cloudPass` takes `any CorrectionProvider`, so this protocol is what lets
//  the pass be written once against either, and lets the menu say which one it is
//  talking to and whether audio leaves the Mac. There is no fallback from one provider
//  to the other at runtime: a dormant second transcriber that can silently take over is
//  two answers for the same audio with no way to tell which one you are reading.
//
//  ── THE CONTRACT IS AN INTERSECTION ──────────────────────────────────────────────────
//
//  `CorrectionResult` carries exactly what `applyCloudResult` consumes and nothing more:
//  `text`, `elapsedMS`, `audioTokens`. It is the intersection of the two clients' result
//  types, not their union. `GeminiClient.Result.totalTokens` is left out because nothing
//  downstream reads it; `WhisperClient.Result` has no token figure at all, so that
//  provider reports `0`, which the ledger at the top of `applyCloudResult` already treats
//  as "nothing to count" (`if audioTokens > 0`). Widening this struct means widening what
//  the pass consumes — do not add a field here that main.swift will not read.
//
//  ── WHY `keyterms` IS A LIST AND THE PROVIDER OWNS THE PROMPT ────────────────────────
//
//  The app's glossary (`cloudKeyterms`, main.swift) is a list of English technical terms.
//  How it reaches an engine differs per engine, and that difference was measured to be
//  decisive, so no rendered prompt string crosses this boundary — only the words:
//
//  * Gemini has no bias-vocabulary field; `GeminiClient` folds the terms into an English
//    instruction as a comma-separated spelling hint, and there it works (main.swift's
//    glossary comment: `commit`, `deploy`, `production` come back correct).
//  * whisper.cpp takes an initial `prompt` that it treats as preceding transcript. On
//    the same five clips and the same `ggml-large-v3-turbo` server
//    (`MicTest/TEST-2026-09-03-turbo-server-5clip.txt`, 2026-09-03): no prompt scored
//    exact 2/5 with English kept 1/8; the comma list `deploy, refactor, function, …`
//    scored exact 1/5, English 7/8, and wrecked the Thai around the terms (`meeting, to
//    an abiding 3 oz.`, `ninoi`, commas sprayed through the clips); a natural Thai
//    sentence with the terms embedded in it scored exact 4/5, English 7/8, Thai intact,
//    no commas. Same terms, opposite outcome, decided by format alone.
//
//  A contract that passed a prompt string would have to pick one of those formats for
//  every engine, and the one that is right for Gemini is the one that breaks whisper. So
//  the provider renders (`WhisperClient.promptString(from:)`, `GeminiClient.prompt`) and
//  this protocol only hands over the list. "How (and whether)" below is literal: a
//  provider whose engine ignores hints is entitled to drop the list on the floor.

import Foundation

/// A post-utterance transcriber: re-transcribes one finished 16 kHz mono 16-bit WAV chunk
/// and returns a transcript the app may use to repair already-typed text.
protocol CorrectionProvider: Sendable {
    /// For traces and the menu, e.g. "Gemini 3.5 Flash", "local whisper (large-v3-turbo)".
    var displayName: String { get }
    /// True when the audio leaves this Mac. Drives the privacy label and the default choice.
    var sendsAudioOffDevice: Bool { get }
    /// Can this provider serve right now (key present / server reachable)? Cheap; may cache.
    func isAvailable() async -> Bool
    /// `keyterms` is the app's glossary; the provider decides how (and whether) to bias
    /// on it.
    func transcribe(wav: Data, keyterms: [String]) async throws -> CorrectionResult
}

struct CorrectionResult: Sendable {
    /// The transcript, trimmed. Empty means the engine heard no speech — both clients
    /// document that as an ordinary outcome, not a failure, and `applyCloudResult` has a
    /// branch for it.
    let text: String
    /// Monotonic-clock milliseconds, the same basis every other elapsedMS in this app uses
    /// (GeminiClient.swift ~150-152 states this explicitly).
    let elapsedMS: Double
    /// 0 for providers with no token ledger.
    let audioTokens: Int
}
