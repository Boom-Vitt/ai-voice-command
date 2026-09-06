import Foundation
enum P {
    // MARK: - Glossary prompt

    /// Byte ceiling for the `prompt` form part.
    ///
    /// whisper's prompt window is `n_text_ctx / 2` tokens — 224 for this model
    /// (`n_text_ctx = 448` in the server's model-load log). Past that the
    /// decoder keeps the *last* 224 tokens and drops the front (whisper.cpp
    /// takes `prompt_past.end() - n_take ..< end()`), so an over-long prompt
    /// loses its opening and its first terms, silently. The archived client set
    /// 800 by budgeting ~4 UTF-8 bytes per token for an ASCII comma list. The
    /// sentence format below spends more of its bytes on Thai, which is
    /// unlikely to tokenise as economically as ASCII, so 800 bytes sits nearer
    /// the window here than it did there. Nobody has counted tokens for this
    /// format — the number is inherited, not re-measured. For scale: P2, the
    /// measured 8-term sentence, is 177 bytes; this generator's sentence for
    /// the same eight terms is 178; the app's full 20-term glossary renders
    /// to 452.
    static let maxPromptBytes = 800

    /// Thai connectives that carry the glossary as one sentence, cycled in this
    /// order between consecutive terms. All four occur in the measured prompt
    /// (`P2` in `MicTest/TEST-2026-09-03-turbo-server-5clip.txt`).
    private static let promptConnectives = ["แล้ว", "กับ", "ก่อน", "แล้วค่อย"]

    /// Opens the carrier sentence — "today [I] will …" — so the first term lands
    /// in a verb slot, as `deploy` did in the measured prompt.
    private static let promptOpening = "วันนี้จะ"

    /// Render the glossary as whisper's initial prompt: **a Thai sentence that
    /// happens to contain the terms, not a list of them.**
    ///
    /// # Why a sentence — measured; do not simplify this back to a comma list
    ///
    /// Same server, same `ggml-large-v3-turbo`, five synthetic clips, 2026-09-03
    /// (`MicTest/TEST-2026-09-03-turbo-server-5clip.txt`):
    ///
    /// | prompt                                           | exact | EN kept |
    /// |--------------------------------------------------|-------|---------|
    /// | none                                             | 2/5   | 1/8     |
    /// | P1 `deploy, refactor, function, commit, push, …` | 1/5   | 7/8     |
    /// | P2, the sentence quoted below                    | 4/5   | 7/8     |
    ///
    /// P2 was `วันนี้จะ deploy แล้ว commit กับ push ขึ้น branch main ก่อน meeting
    /// ตอนบ่าย แล้วค่อย refactor function`.
    ///
    /// The comma list rescued the English and wrecked the Thai around it —
    /// `meeting, to an abiding 3 oz.` for "meeting ตอนบ่าย 3 โมง", `ninoi` for
    /// "นี้หน่อย", commas sprayed between words — because whisper treats the
    /// prompt as preceding transcript and continues in its style. The sentence
    /// kept the same English with the Thai intact and no punctuation. The
    /// no-prompt row is also why an empty glossary sends **no** `prompt` part:
    /// no prompt beat a bad prompt, so nothing goes out unless there is
    /// something to say.
    ///
    /// # What this renders
    ///
    /// ``promptOpening``, then the terms joined by ``promptConnectives`` in
    /// rotation:
    ///
    ///     วันนี้จะ deploy แล้ว commit กับ branch ก่อน main แล้วค่อย refactor แล้ว push …
    ///
    /// That is P2's *shape*, not its bytes: P2 was written by hand with
    /// term-specific slots (`push ขึ้น branch main`) no generator can produce for
    /// an arbitrary list. The generated sentence has not itself been scored
    /// against the server. What was measured is that the sentence format beat
    /// the list format on the same eight terms; this keeps the format and
    /// generalises it to any list.
    ///
    /// # Budget
    ///
    /// Terms go through `CloudKeyFile.clampTerms` (trim, drop blanks, clip at 50
    /// characters, de-duplicate, at most 100) — the same clamp the Gemini path
    /// applies, so both providers see one list. Internal whitespace collapses to
    /// a single space so a term can never break the sentence onto a second line.
    /// Each term is then appended with its connective only if the whole piece
    /// fits under ``maxPromptBytes``; a term that does not fit is dropped whole
    /// and the next one is tried, so one oversized entry costs itself and not
    /// everything after it. A term is never cut: a fragment biases the decoder
    /// toward the fragment, and a byte-level cut could also land inside a Thai
    /// cluster (base consonant plus vowel and tone marks), which `String` holds
    /// as one `Character`. Only whole `String`s are appended, so the output ends
    /// on a complete `Character` by construction.
    ///
    /// - Returns: `""` for an empty or all-blank glossary — the caller must then
    ///   omit the `prompt` part rather than send an empty one.
    static func promptString(from keyterms: [String]) -> String {
        var sentence = ""
        var kept = 0
        for term in CloudKeyFile.clampTerms(keyterms) {
            let word = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let joiner = kept == 0
                ? promptOpening
                : promptConnectives[(kept - 1) % promptConnectives.count]
            let piece = (kept == 0 ? "" : " ") + joiner + " " + word
            guard sentence.utf8.count + piece.utf8.count <= maxPromptBytes else { continue }
            sentence += piece
            kept += 1
        }
        return sentence
    }

}
