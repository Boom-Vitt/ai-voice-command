//
//  GeminiLiveRecognizer — realtime Thai speech recognition by streaming the microphone to
//  Google's `gemini-3.5-transcribe-live` over the BidiGenerateContent WebSocket.
//
//  A drop-in alternative to `LiveRecognizer`, not a replacement for it. `LiveRecognizer`
//  (Apple, on-device) remains the default and is the only engine that keeps every sample of
//  the user's voice on this Mac; this one ships the microphone to a datacenter for as long
//  as dictation runs, and is therefore opt-in from the menubar. The two expose the same
//  eight members so `main.swift` can hold either behind one protocol.
//
//  ── THE MEASUREMENTS THAT DICTATE THE SHAPE OF THIS FILE ───────────────────────────────
//
//  Every number below was taken against the live API, not read off a doc page.
//
//  1. WITH THE MODEL'S OWN VAD (the default), the first transcript arrived only after
//     15-25 s of realtime-paced audio — measured twice. That is not a latency figure, it is
//     a different product: useless for typing as you speak. Sending
//     `realtimeInputConfig.automaticActivityDetection.disabled = true` and driving the turns
//     manually is what makes this engine viable at all. That flag is LOAD-BEARING; deleting
//     it does not "simplify the setup message", it reverts the engine to a 20 s dead zone.
//
//  2. WITH MANUAL TURNS, the transcript for a turn arrives 0.30 s after `activityEnd`
//     (mean of 5 turns). That is the whole latency budget of this engine, and it is why the
//     turn boundary policy below is the only interesting thing in the file.
//
//  3. WHERE THE BOUNDARY FALLS DECIDES ACCURACY, and by a lot. On identical 17 s Thai
//     audio (165 characters of ground truth):
//
//       * FIXED 2 s TURNS   → 0.35 s latency, 147/165 characters (89%), with words sliced
//                             at every single boundary. Fast and wrong.
//       * SILENCE-ALIGNED   → 0.30 s latency, 161/165 characters (97.6%), no boundary
//                             damage at all.
//
//     So boundaries MUST fall in silence. That is the entire justification for the energy
//     VAD, the `silenceCloseSeconds` run, and the `minTurnSpeechSeconds` floor below. A
//     future reader tempted to replace all of it with a timer should read those two lines
//     again: the timer was tried, and it ate 11% of the user's words.
//
//  4. `activityEnd` IMMEDIATELY FOLLOWED BY `activityStart` in the same tick produced a
//     server `1011 Internal error`. Turns are therefore sequenced strictly: close, drain
//     that turn's messages, then open the next. That is what the `.closing` state exists
//     for, and it is why nothing here opens a turn from inside the close path.
//
//  5. The NON-LIVE sibling `gemini-3.5-transcribe` returns an empty part for every request
//     shape tried over `generateContent` — see `GeminiClient`'s "measured negative results".
//     It is not an alternative to this file; the live bidi socket is the only Gemini surface
//     measured to transcribe at all.
//
//  ── RECONCILING `GeminiClient`'s NEGATIVE RESULT, WHICH IS NOW STALE ───────────────────
//
//  `GeminiClient`'s type documentation records `gemini-3.5-transcribe-live` as a dead end:
//  "produced its first transcript only after 25 s of realtime-paced audio … which is why
//  Apple's on-device recognizer is retained for the live path". That measurement is real and
//  it is measurement (1) above — taken with the model's OWN VAD enabled. Disabling
//  `automaticActivityDetection` and closing turns manually is what turns 25 s into 0.30 s.
//  This file is the disproof of that note, not a contradiction of it; the note has not been
//  edited because that file is not this change's to touch. If you are reading the two side
//  by side, this one is the later measurement.
//
//  ── THE ISOLATION RULE — INHERITED VERBATIM FROM `LiveRecognizer`, DO NOT WEAKEN IT ────
//
//  `append(_:)` is called directly from AVFAudio's realtime render thread, from inside an
//  `installTap` closure. This app already hard-crashed once with EXC_BREAKPOINT inside
//  `_dispatch_assert_queue_fail`, called from `swift_task_isCurrentExecutor`, because a tap
//  closure silently inherited `@MainActor` isolation and was then invoked off the render
//  thread. The runtime asked "am I on the main executor?", found a render thread, and killed
//  the process. Therefore:
//
//    * This type is NOT `@MainActor` and must never become one.
//    * `@unchecked Sendable` is honest: an `OSAllocatedUnfairLock` provides the mutual
//      exclusion the compiler cannot see. Unfair (not `NSLock`) because unfair locks
//      participate in priority donation — a low-priority drain on the session queue must
//      never leave the high-priority audio thread spinning.
//    * `append` does no file I/O, no `print`, no `trace`, no UI, no `await`, no
//      `MainActor.assumeIsolated`, and NO ALLOCATION — which specifically includes
//      `DispatchQueue.async`, whose block capture allocates. Nothing on that path may
//      schedule work; the drain tick on `queue` polls for what needs doing instead (see
//      `prepareConverterIfNeeded`).
//    * `append` does REAL WORK on that thread, and the claim is bounded rather than absent:
//      one `AVAudioConverter.convert` (48 kHz → 16 kHz, high quality, microseconds on Apple
//      silicon) plus two passes over the ~340 resulting samples — one for RMS, one to
//      quantise to Int16 — all against storage preallocated in `Converter`, ALL OUTSIDE THE
//      LOCK, exactly as `AudioPipeline.append` does it. Only then does it take ONE critical
//      section, for a bounded memcpy into the ring plus four counter updates. That split is
//      the point: the queue side never blocks the render thread for longer than the memcpy.
//    * Every WebSocket operation — connect, send, receive, parse, reconnect — happens on
//      `queue`. None of it is reachable from the audio thread.
//    * The `onPartial` / `onFinal` / `onState` callbacks are `@Sendable` and fire on `queue`.
//      This class deliberately does NOT hop to the main actor — that is the consumer's job,
//      and doing it here would reintroduce the exact crash above.
//
//  ── PRIVACY: THE KEY IS IN THE URL, AND THE URL IS NEVER WRITTEN DOWN ──────────────────
//
//  `GeminiClient` argues at length that the REST key belongs in the `x-goog-api-key` HEADER
//  and never in a `?key=` query parameter, precisely because URLs are the part of a request
//  that gets logged. That argument is not repealed here — it is OUTRANKED by a narrower
//  fact: the query parameter is the form that was VERIFIED to authenticate this WebSocket
//  handshake, and a header was not. Shipping the unverified form would mean shipping an
//  engine that does not connect.
//
//  The cost is real and is paid for explicitly: this file NEVER traces the endpoint URL,
//  never interpolates it into an error, and runs every string that escapes through
//  `redact(_:)`, which replaces the key with a placeholder. If you add an error path, keep
//  it that way. If you later verify a header form against the live service, move it — the
//  header is strictly better and only evidence is missing.
//
//  ── TWO DELIBERATE DIVERGENCES FROM `LiveRecognizer` ───────────────────────────────────
//
//  Both are choices, not drift, and both are the opposite of what that file does:
//
//    * `isSupported` is CACHED, where `LiveRecognizer` recomputes it on every access. There
//      it wraps `SFSpeechRecognizer.isAvailable`, which genuinely flips at runtime; here it
//      answers "was there a `GOOGLE_API_KEY` line in the dotenv file when this object was
//      built", which is not a live property. It is also polled from menu updates, and
//      re-reading a file on every menu validation would be worse than useless.
//    * The reconnect is BOUNDED (`maxReconnectAttempts`), where `LiveRecognizer` retries
//      forever. That file's reasoning — a wedged local daemon may recover on its own, so
//      never give up — does not transfer: a remote service that refuses `maxReconnectAttempts`
//      handshakes in a row is rejecting us (bad key, revoked project, quota), and each
//      further attempt puts the key on the wire again for nothing. The counter resets on
//      every successful setup, so an hour-long capture with occasional hiccups never
//      approaches it. What the bound costs, plainly: after it is spent this engine goes
//      quiet until the user toggles dictation off and on. That is reported as
//      `.unavailable(...)` and traced.
//
//  Relatedly, this file never emits the token `persistent recognition failure`. That string
//  is `LiveRecognizer`'s interface with main.swift's escalation ladder, whose recoveries
//  (bouncing the Speech session, `pkill localspeechrecognition`) are meaningless for a
//  WebSocket and whose arming counters are not ours to move. Reconnection is this engine's
//  own job and it does it itself.
//

import AVFAudio
import Foundation
import os

final class GeminiLiveRecognizer: @unchecked Sendable {

    // MARK: - Public surface

    /// Mirrors `LiveRecognizer.State` case for case. Deliberately a SECOND enum rather than
    /// a shared one: neither engine file imports the other, and main.swift maps this onto
    /// `LiveRecognizer.State` at the single point it crosses into the app (see the
    /// `DictationEngine` conformance there). Adding a fourth case here is a compile error
    /// over there, on purpose.
    enum State: Sendable {
        case idle
        case listening
        /// A human-readable reason: no key, a socket that would not come up, a mid-session
        /// disconnect, or — past `maxReconnectAttempts` — the terminal report. Already run
        /// through `redact(_:)`; never contains the URL or the key.
        case unavailable(String)
    }

    enum RecognizerError: Error, CustomStringConvertible {
        /// No `GOOGLE_API_KEY` assignment in the dotenv file, so there is nothing to
        /// authenticate with. Carries the PATH, never the file's contents.
        case missingKey(String)
        /// The endpoint URL could not be formed. Carries no fragment of the URL.
        case badEndpoint(String)
        /// No `AVAudioConverter` exists from the tap's format to 16 kHz mono.
        case converterUnavailable(String)

        var description: String {
            switch self {
            case .missingKey(let path):
                return "no \(GeminiClient.keyName) in \(path)"
            case .badEndpoint(let detail):
                return "cannot form the Live endpoint URL: \(detail)"
            case .converterUnavailable(let detail):
                return "cannot build converter: \(detail)"
            }
        }
    }

    /// Never invoked. Declared because `main.swift`'s `DictationEngine` conformance wires all
    /// three callbacks uniformly, and a property that silently does not exist would be worse
    /// than one that documents its own emptiness.
    ///
    /// WHY THERE ARE NO PARTIALS. A turn's `inputTranscription` messages could be
    /// concatenated and emitted as a growing string, which is what a partial is. They are
    /// not, because measurement (2) says the whole transcript lands 0.30 s AFTER
    /// `activityEnd` — the fragments arrive within milliseconds of each other, at the end,
    /// so a "partial" here would beat its own final by nothing worth having. Emitting them
    /// anyway would put revisable text through the consumer's re-anchoring path (the most
    /// delicate machinery in main.swift) in exchange for zero perceived latency. One turn,
    /// one final: see `finishTurn`.
    var onPartial: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onPartial }
        set { lock.lock(); defer { lock.unlock() }; _onPartial = newValue }
    }

    /// One complete turn's transcript. Fires once per closed turn, on `queue`.
    var onFinal: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFinal }
        set { lock.lock(); defer { lock.unlock() }; _onFinal = newValue }
    }

    /// State changes and errors, for UI.
    var onState: (@Sendable (State) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onState }
        set { lock.lock(); defer { lock.unlock() }; _onState = newValue }
    }

    // MARK: - Wire constants (measured, not guessed)

    /// The model id, WITH the `models/` prefix the setup message requires.
    static let model = "models/gemini-3.5-transcribe-live"

    /// The bidi endpoint, without its query string. The key is appended in `endpointURL()`
    /// and the assembled URL never leaves `queue` — see the privacy note in the file header.
    private static let endpointBase =
        "wss://generativelanguage.googleapis.com/ws/"
        + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// The first message on every connection. Three things in it are load-bearing:
    /// `model` (prefixed), `inputAudioTranscription` (which is what makes the server return
    /// `serverContent.inputTranscription` at all — the transcript of what WE sent, as opposed
    /// to `modelTurn`, which is what the model would SAY back), and
    /// `automaticActivityDetection.disabled`, which is measurement (1).
    ///
    /// Built from ``model`` rather than written out whole, so the two cannot drift.
    private static var setupMessage: String {
        let head = #"{"setup":{"model":""#
        let tail = #"","inputAudioTranscription":{},"realtimeInputConfig":"#
            + #"{"automaticActivityDetection":{"disabled":true}}}}"#
        return head + model + tail
    }

    private static let activityStartMessage = #"{"realtimeInput":{"activityStart":{}}}"#
    private static let activityEndMessage = #"{"realtimeInput":{"activityEnd":{}}}"#

    /// The audio frame envelope, split so the base64 payload can be concatenated in without
    /// building a dictionary and serialising it once per 100 ms.
    ///
    /// Hand-rolled JSON is safe HERE and only here: the sole interpolated value is base64,
    /// whose alphabet (`A-Za-z0-9+/=`) contains no character JSON would need to escape. Do
    /// not extend this trick to a field that could ever carry text.
    private static let audioMessageHead =
        #"{"realtimeInput":{"mediaChunks":[{"mimeType":"audio/pcm;rate=16000","data":""#
    private static let audioMessageTail = #""}]}}"#

    // MARK: - Format constants (non-negotiable)

    /// The API accepts 16 kHz mono signed 16-bit little-endian PCM, and the `mimeType` above
    /// declares exactly that. The tap delivers 48 kHz Float32 non-interleaved, so every
    /// buffer is resampled; see `Converter`.
    static let outputSampleRate: Double = 16_000
    private static let outputChannelCount: AVAudioChannelCount = 1

    // MARK: - The adaptive speech gate

    //  ── WHY THIS IS A MEASURED FLOOR AND NOT A FIXED THRESHOLD ────────────────────────
    //
    //  This gate used to be the literal `rms >= 0.0025`, copied from `AudioPipeline` together
    //  with its calibration note. THE CALIBRATION WAS RIGHT AND THE SHAPE WAS THE BUG —
    //  the same finding `main.swift`'s `noiseFloor` records against the identical literal on
    //  the watchdog side. This file inherited the defect by inheriting the constant.
    //
    //  The evidence is not general audio folklore; it is this codebase's own field notes
    //  about THIS user's room and THIS machine's microphone:
    //
    //    * `main.swift`'s `FlushRequestBox` exists only because "in a room whose ambient
    //      noise sits above the silence threshold, that gate never opens at all", and without
    //      the escape hatch "every utterance would end the session as finalChunks=0". That is
    //      the fixed 0.0025 gate, in this room, never once classifying anything as silence.
    //    * `AudioPipeline` puts a MacBook built-in mic's noise floor at 0.001–0.004 — a band
    //      that STRADDLES 0.0025. By its own documentation the constant lands on the wrong
    //      side of this room's ambient a good part of the time.
    //    * `main.swift`'s recogniser watchdog needed a measured floor for the same reason:
    //      ambient alone armed every tier of its escalation ladder off an EMPTY room and it
    //      fired `pkill` on a macOS system service twice (16:09–16:15 on 2026-08-26).
    //
    //  WHAT A DEAF GATE COSTS THIS ENGINE, which is worse than the latency it looks like. If
    //  ambient sits above the threshold then every buffer is speech, `trailingSilence` never
    //  leaves zero, and three things fail at once:
    //
    //    1. NO TURN CAN EVER CLOSE ON SILENCE. Every boundary falls at `maxTurnSeconds`,
    //       wherever the speaker happens to be — measurement (3)'s 89% regime, the single
    //       outcome this file's whole turn policy is shaped to avoid.
    //    2. `minTurnSpeechSeconds` STOPS GATING ANYTHING, because ambient increments
    //       `speechSamples` just as speech does.
    //    3. THE IDLE-MIC GUARD INVERTS. `drainTick`'s `.idle` branch discards an all-silence
    //       backlog by testing `trailing >= pending`; with `trailing` pinned at zero that
    //       reads `0 >= pending` and is always false, so the pre-roll discard never runs and
    //       a turn opens every `maxTurnSeconds` WHETHER OR NOT ANYONE IS SPEAKING.
    //       `preRollSeconds`' claim that this "stops an idle microphone from sending room
    //       tone to Google by the minute" is then simply untrue, and the cost is not latency:
    //       it is an open microphone streamed to a datacenter, and billed, for as long as
    //       dictation is toggled on.
    //
    //  So the gate is now a RATIO OVER A MEASURED FLOOR — the self-calibrating shape
    //  `main.swift` already proved on the watchdog, reused rather than reinvented. Steady
    //  noise (fan, aircon, hum) is tracked BY the floor, so its own ratio converges towards
    //  1.0 and it can never read as speech, in this room or any other; speech sits 10–30 dB
    //  above the floor and always does. Two things below are deliberate divergences from that
    //  file, and both are argued where they are made: the time constants are expressed in
    //  SECONDS (`noiseFloorFallSeconds`) and the rise learns ONLY from non-speech buffers
    //  (`updateFloor`, with `floorStallSeconds` as the escape hatch that costs).

    /// Floor under the measured floor — and the ORIGINAL fixed threshold, retained on purpose
    /// rather than deleted along with the shape that was wrong.
    ///
    /// THE MEASUREMENT ATTACHED TO 0.0025 IS STILL TRUE, and is why the value is this and not
    /// the textbook 0.01: on this machine's microphone, real speech that the on-device
    /// recognizer transcribes perfectly sits BELOW 0.01, so 0.01 classified whole sentences as
    /// silence. Those numbers stand; only the SHAPE changed. In a near-silent room the
    /// measured floor approaches zero and `floor * speechOverFloorRatio` would be a
    /// hair-trigger that any tiny transient clears, so the threshold is clamped up to this
    /// value — which keeps the old, known-workable sensitivity as the minimum.
    ///
    /// Still computed on the CONVERTED 16 kHz mono samples, which is the signal 0.0025 was
    /// calibrated against — moving the RMS above the converter would silently recalibrate it.
    ///
    /// THE THIN CASE, WRITTEN DOWN SO IT IS DIAGNOSABLE RATHER THAN SURPRISING. This value is
    /// also the seeding bound in `updateFloor`, so a room quieter than it never seeds and the
    /// threshold rides 0.0025 flat for the whole capture. That is safe with a wide margin at
    /// the bottom of `AudioPipeline`'s 0.001–0.004 band, and it is exactly what this constant
    /// is for. But the band STRADDLES this value, and just under it is the narrowest state in
    /// the design: an ambient of 0.0024 does not seed, so the gate compares it against 0.0025
    /// and clears by 4%. An ambient of 0.0026 does seed, and the ratio immediately gives it
    /// 3x of room. So the awkward case is the one that fails to seed by a hair, and its
    /// signature in the trace is specific and easy to read: `floor=(never measured)` sitting
    /// next to a high `speech=` in the LEVEL line. Do not pre-emptively add a mechanism for
    /// it — get that line out of a real session first.
    private static let absoluteQuietFloor: Float = 0.0025

    /// How far above the measured floor a buffer must sit to count as speech: 3.0, about
    /// +9.5 dB. Steady noise converges to a ratio of 1.0 by construction (the floor tracks
    /// it) while speech measures 10–30 dB up, so there is a wide gap either side of 3.0. The
    /// same ratio `main.swift` settled on, kept identical so the two gates in this app cannot
    /// disagree about what "speech" means.
    private static let speechOverFloorRatio: Float = 3.0

    /// Noise-floor tracking time constants — fast down, slow up, and stated in SECONDS.
    ///
    /// DELIBERATELY TIME, WHERE `main.swift` USES BARE PER-TICK COEFFICIENTS. There the
    /// tracker runs on a fixed 1 Hz `tickStatus`, so `0.1 per tick` IS a 10 s time constant.
    /// Here it runs where the RMS already is — once per tap buffer, on the audio thread — and
    /// that cadence is not this file's to fix: main.swift installs the tap with a 1024-frame
    /// hint (~21 ms, so ~47 Hz), AVFAudio is free to hand over another size, and a device
    /// change mid-capture can change it again. Copying 0.1/0.005 literally would mean a 0.21 s
    /// fall and a 4.3 s rise at the CURRENT buffer size and something else entirely at any
    /// other — a tuning that silently re-tunes itself when the hardware changes. The
    /// per-buffer coefficient is derived from the buffer's own sample count instead (see
    /// `updateFloor`), which costs one divide and makes the behaviour a property of the room
    /// rather than of the driver.
    ///
    /// FALL = 2 s, against that file's 10 s, because the two gates act on different horizons.
    /// The watchdog arms over 3–6 one-second ticks, so a floor that is right within ten
    /// seconds is soon enough. This gate decides a turn boundary off a 0.3 s silence run and
    /// the FIRST utterance of a capture already needs a correct floor, so it has to settle
    /// within a second or two of the microphone opening. Still slow enough that one anomalous
    /// quiet buffer moves it by about 1%.
    private static let noiseFloorFallSeconds: Double = 2.0

    /// RISE = 30 s, against that file's 200 s, because this tracker learns the rise from a
    /// far narrower class of sample — see `updateFloor`. There the rise had to survive
    /// full-loudness speech being folded in, which is what forced 200 s and what still leaves
    /// that gate going deaf at tick 75 of unbroken speech. Here nothing above the speech
    /// threshold ever contributes, so the excursion the rise must resist is bounded by the
    /// ratio itself and 30 s is ample. Its only job is to follow genuine ambient drift upward;
    /// the fall outruns it 15:1, so the floor rides close to the minimum envelope rather than
    /// the mean, which is what a noise floor is.
    private static let noiseFloorRiseSeconds: Double = 30.0

    /// The escape hatch for the one case a rise-from-silence-only tracker cannot see by
    /// itself: a STEP in ambient larger than `speechOverFloorRatio` — an aircon or a fan
    /// coming on and landing more than 3x above the settled floor. Every buffer then reads as
    /// speech, no buffer is eligible to teach the floor, and the gate wedges in exactly the
    /// state this whole section exists to prevent. `main.swift` needs no such hatch because it
    /// learns from every sample; this is the price of not deafening under speech, paid here.
    ///
    /// After this long with NOT ONE buffer below the threshold, the classification is not
    /// credible and the floor is RE-SEEDED from the current sample. 15 s sits above
    /// `maxTurnSeconds`, which this file already treats as the pathological pause-free case,
    /// so nothing the turn machine considers normal can reach it.
    ///
    /// THE RESCUE AND `noiseFloorRiseSeconds` COVER DISJOINT BANDS, and that handoff is why
    /// both exist rather than either alone. A step SMALLER than `speechOverFloorRatio` leaves
    /// the new ambient below the threshold, so it is not speech, so the ordinary slow rise
    /// simply follows it up and this hatch never arms. A step LARGER than the ratio puts
    /// every buffer above the threshold, the rise is starved by construction, and only the
    /// rescue can move the floor. Between roughly 3x and 3.5x the classification flickers
    /// buffer to buffer, which resets `stallSamples` and keeps the rescue from ever
    /// accumulating — correctly, because the sub-threshold buffers in that flicker are
    /// exactly what the rise needs. Simulated at a clean 5x step: one rescue fires, the floor
    /// lands on the new ambient exactly, and the room reads as silent again.
    ///
    /// PROVISIONAL, AND SAID SO OUT LOUD. The claim underneath it — that ordinary Thai
    /// dictation always puts at least one sub-threshold ~21 ms buffer inside any 15 s window
    /// (stop consonants, breaths between clauses) — is inference about this speaker, not a
    /// measurement, and `main.swift`'s own doctrine on exactly this kind of compensating gate
    /// is "do not add one on a hunch — get the numbers out of the trace first". So every
    /// rescue emits its own line (`noise floor re-seeded`) and is counted into the LEVEL line;
    /// re-litigate this constant from those after the first real session. The cost if it fires
    /// wrongly is bounded and cheap: the floor jumps to a speech level once, the threshold
    /// with it, and the 2 s fall reclaims it during the next dip between words.
    private static let floorStallSeconds: Double = 15.0

    // MARK: - Turn segmentation constants

    /// A continuous silence run at least this long closes the open turn. This is the
    /// mechanism measurement (3) is about: 0.3 s is long enough to survive the gap between
    /// words and the stop-gap of a plosive, short enough that the 0.30 s transcript latency
    /// is not swamped by waiting for the boundary.
    private static let silenceCloseSeconds: Double = 0.3

    /// Minimum speech in a turn before the ORDINARY `silenceCloseSeconds` boundary may close
    /// it. Below this a "turn" is a door slam or a keyboard click, and closing on it costs a
    /// round trip and invites a hallucinated fragment.
    ///
    /// NO LONGER THE LAST WORD — see `shortUtteranceCloseSeconds` directly below, which is
    /// what stops this floor from stranding a genuinely short word until `maxTurnSeconds`.
    private static let minTurnSpeechSeconds: Double = 0.4

    /// Trailing silence that closes a turn whose speech never reached
    /// `minTurnSpeechSeconds`. The remedy for a real defect in the constant above.
    ///
    /// THE BUG. A single short Thai word — "ครับ", "ใช่", "ไม่" — is 0.25–0.35 s of speech.
    /// It can never satisfy `minTurnSpeechSamples`, so the silence boundary refuses it
    /// forever, and the turn survives until the `maxTurnSeconds` backstop. Three separate
    /// costs, none of them acceptable: the user waits ~9 s for one word; ~8.7 s of silence is
    /// streamed to Google and billed for nothing; and the turn is then traced as a forced
    /// close, "no pause found — this boundary can clip a word", when a pause was found
    /// immediately and no word was clipped anywhere. That last one is the worst of the three,
    /// because it poisons the very trace the forced-close constant was left unbounded to
    /// collect.
    ///
    /// WHY THIS SURFACES NOW AND NOT BEFORE. It is the second half of the noise-floor fix
    /// above, not an independent finding. While the gate was the fixed 0.0025 literal,
    /// ambient incremented `speechSamples` too, so `minTurnSpeechSamples` was satisfied within
    /// 0.4 s of ANY audio and gated nothing at all. The moment the gate starts measuring
    /// actual speech, a 0.3 s word measures 0.3 s and hits this floor for the first time in
    /// the file's life. Fixing the gate is what makes this constant bite.
    ///
    /// THE CHOICE: CLOSE THE TURN, DO NOT DISCARD IT. `AudioPipeline` faces the identical
    /// below-minimum remnant and CLEARS it, and is right to — there the audio is still local
    /// and unsent, and dropping it costs a click. Here it is neither: the turn is already
    /// open and its audio has already gone over the socket, so discarding buys back no
    /// privacy and no billing, and throws away a transcript that may legitimately be one
    /// short word. So the turn closes and whatever the server heard is delivered. The
    /// door-slam protection is not lost, only deferred: a click still has to sit through a
    /// full second of silence before it earns a round trip, and `finishTurn` already declines
    /// to emit an empty transcript, which is what a door slam produces.
    ///
    /// 1.0 s, AND `shortUtteranceCloseSeconds > silenceCloseSeconds` IS A LOAD-BEARING
    /// INVARIANT, not an accident of these two numbers. The ordinary path must always get
    /// first refusal; if this constant were ever lowered to or below 0.3 s it would fire
    /// first, `minTurnSpeechSamples` would stop existing, and the door-slam guard would be
    /// gone with no compile error and no trace line to show for it. 1.0 s is comfortably past
    /// any intra-utterance pause (which is what the 0.3 s constant is sized for), so a click
    /// followed by real speech inside a second still accumulates into a normal turn and
    /// closes through the normal path. It caps the short-word wait at ~1 s instead of ~9 s,
    /// and the silence streamed to Google with it.
    private static let shortUtteranceCloseSeconds: Double = 1.0

    /// Forced close for genuinely pause-free speech.
    ///
    /// THE ONE REMAINING PATH THAT CAN CLIP A WORD, stated plainly rather than hidden: a
    /// speaker who does not pause for nine seconds gets a boundary wherever they happen to
    /// be, which is measurement (3)'s failure mode in miniature. It cannot be removed —
    /// without it a monologue would grow one unbounded turn, overrun the ring, and produce
    /// no text at all until it ended. Every forced close is traced (`turn: forced close`)
    /// specifically so its real-world frequency is measurable rather than assumed; if the
    /// traces show it firing often, the answer is a smarter boundary, not a bigger number.
    private static let maxTurnSeconds: Double = 9.0

    /// Silence retained ahead of speech. Speakers begin the first phoneme before the RMS of
    /// a whole buffer crosses the threshold, so a hard cut at the threshold clips onsets.
    /// While no turn is open, unsent audio older than this is discarded, which is what stops
    /// an idle microphone from sending room tone to Google by the minute.
    private static let preRollSeconds: Double = 0.25

    // MARK: - Pacing and timeout constants

    /// How often `queue` wakes to send audio and evaluate the turn boundary. 100 ms is the
    /// frame size the API was measured with (3200 bytes at 16 kHz mono s16le).
    private static let drainIntervalSeconds: Double = 0.1

    /// Ceiling on the audio sent in one tick. Only reached when the drain is catching up
    /// after a reconnect; it keeps one message from carrying the whole ring.
    private static let maxSendSeconds: Double = 2.0

    /// Ring capacity. Must comfortably exceed `maxTurnSeconds` plus a close-and-drain cycle,
    /// because audio spoken while a turn is `.closing` waits here for the next turn. 12 s of
    /// 16 kHz Int16 is 384 KB, allocated once.
    private static let ringSeconds: Double = 12.0

    /// How long to wait after `activityEnd` for `turnComplete`/`generationComplete` before
    /// giving up on that turn. Measured mean is 0.30 s, so this is 10x headroom — it is a
    /// net against a silent server, not a latency budget. NEVER unbounded: a turn that waits
    /// forever wedges the engine with the microphone still hot, which is the exact failure
    /// `LiveRecognizer`'s flush timeout exists to prevent on its side.
    private static let turnCompletionTimeoutSeconds: Double = 3.0

    /// How long a fresh socket has to answer the setup message with `setupComplete`.
    private static let setupTimeoutSeconds: Double = 10.0

    /// How long `stop()` waits for the last turn's transcript before closing the socket. The
    /// same bargain `LiveRecognizer.finalFlushTimeoutSeconds` strikes: the tail of what the
    /// user said is worth a short wait, and nothing is worth a leaked live socket.
    private static let finalFlushTimeoutSeconds: Double = 2.0

    /// Reconnect backoff. Exponential from the base, capped at the max.
    private static let reconnectBaseDelaySeconds: Double = 0.5
    private static let reconnectMaxDelaySeconds: Double = 8.0
    /// See the divergence note in the file header for why this is bounded at all.
    private static let maxReconnectAttempts = 5

    /// Drain ticks between `gemini-live LEVEL:` lines. `drainIntervalSeconds` is 0.1, so 50
    /// ticks is ~5 s — the same cadence `main.swift`'s LEVEL line runs at, and for the reason
    /// stated there: a measurement that prints only once something has already gone wrong
    /// cannot describe how it got there.
    private static let levelLineTicks = 50

    // MARK: - Derived sample counts

    private let ringCapacity: Int
    private let silenceCloseSamples: Int
    private let shortUtteranceCloseSamples: Int
    private let minTurnSpeechSamples: UInt64
    private let maxTurnSamples: UInt64
    private let preRollSamples: UInt64
    private let maxSendSamples: Int

    // MARK: - Conversion

    /// Everything the realtime path needs to turn one tap buffer into 16 kHz mono s16le,
    /// preallocated. Built on `queue` (it allocates ~600 KB), then published under the lock
    /// and used ONLY from the audio thread.
    ///
    /// Publication is by reference swap and never by mutation: `start()` drops the reference
    /// and the next `prepareConverterIfNeeded` builds a fresh object, so a tap still draining
    /// from a previous capture keeps using the old one rather than racing a half-reconfigured
    /// converter. This inherits `AudioPipeline`'s assumption that AVFAudio delivers one
    /// engine's tap on one render thread — two concurrent callers of `process` would trample
    /// the shared scratch.
    private final class Converter: @unchecked Sendable {

        /// The converter pulls input through a block. The block is built once and captures
        /// this box — never `self` — so there is no retain cycle and no per-buffer closure
        /// allocation.
        private final class InputSource: @unchecked Sendable {
            var buffer: AVAudioPCMBuffer?
            var supplied = false
        }

        private let converter: AVAudioConverter
        private let converted: AVAudioPCMBuffer
        private let source = InputSource()
        private let inputBlock: AVAudioConverterInputBlock

        /// 16 kHz Float32, the intermediate the RMS is computed on. 2 s.
        private var scratch: [Float]
        /// 16 kHz signed 16-bit, the bytes that go on the wire. Same length as `scratch`.
        private(set) var pcm: [Int16]

        // ── THE SPEECH GATE'S WORKING STATE ───────────────────────────────────────────
        //
        // Three scalars, and they live HERE rather than beside the ring for two reasons.
        //
        // FIRST, LOCKING: this object is documented above as built on `queue` and then "used
        // ONLY from the audio thread", published by reference swap and never by mutation. So
        // state kept inside it needs no lock at all — the tracker runs in the same pass that
        // already computes the RMS, outside every critical section, and `append`'s lock is
        // untouched by it.
        //
        // SECOND, LIFECYCLE, and this is the part worth not undoing: `start()` drops the
        // converter reference and `prepareConverterIfNeeded` builds a fresh one per capture,
        // so the floor is cleared per capture FOR FREE. `main.swift` has to clear its own
        // `noiseFloor` explicitly in `beginCapture`, and says why — a floor measured in
        // another session, possibly another room hours ago, must never gate this one. Here
        // that guarantee is structural instead of remembered.

        /// The room's measured noise floor, in the same RMS units `process` computes. Zero
        /// until seeded; see `updateFloor` for why the seed has a lower bound.
        private var noiseFloor: Float = 0
        private var noiseFloorSeeded = false
        /// Samples accumulated since the last buffer that was NOT classified as speech. The
        /// stall detector; see `floorStallSeconds`.
        private var stallSamples = 0
        /// `floorStallSeconds` in samples, precomputed so the hot path compares two `Int`s.
        private let stallSampleLimit: Int

        /// The live gate: a buffer at or above this is speech. ONE definition, used by the
        /// classification and published verbatim to the trace, so a LEVEL line can never
        /// print a threshold the gate did not actually use — the same single-definition rule
        /// `main.swift`'s `speechThreshold` states, for the same reason.
        private var speechThreshold: Float {
            max(GeminiLiveRecognizer.absoluteQuietFloor,
                noiseFloor * GeminiLiveRecognizer.speechOverFloorRatio)
        }

        /// What one buffer measured and what the gate made of it. A struct rather than a
        /// tuple because `append` publishes most of it for the trace, and a six-field tuple
        /// at that call site would be write-only.
        struct Measurement {
            let samples: Int
            let rms: Float
            /// The floor and threshold the classification below ACTUALLY used — snapshotted
            /// before `updateFloor` runs, so the pair always satisfies the gate's own formula.
            let floor: Float
            let floorSeeded: Bool
            let threshold: Float
            let isSpeech: Bool
            /// True on the buffer where `floorStallSeconds` expired and the floor was
            /// re-seeded. Counted and traced on `queue`; see that constant.
            let reseeded: Bool
        }

        init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RecognizerError.converterUnavailable(
                    "sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")
            }
            guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                let rate = Int(inputFormat.sampleRate)
                throw RecognizerError.converterUnavailable(
                    "\(rate) Hz ×\(inputFormat.channelCount) → 16 kHz mono")
            }
            // Rate conversion is not decimation: 48 k → 16 k needs a proper anti-alias filter
            // or everything above 8 kHz folds back onto the speech band as hiss. High quality
            // costs microseconds on Apple silicon — and this engine's whole value is accuracy.
            conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue

            let capacity = AVAudioFrameCount(16_384)
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            else {
                throw RecognizerError.converterUnavailable("cannot allocate conversion buffer")
            }

            self.converter = conv
            self.converted = out
            let staging = Int(GeminiLiveRecognizer.outputSampleRate * 2)
            self.scratch = [Float](repeating: 0, count: staging)
            self.pcm = [Int16](repeating: 0, count: staging)
            self.stallSampleLimit = Int(GeminiLiveRecognizer.outputSampleRate
                * GeminiLiveRecognizer.floorStallSeconds)

            let src = self.source
            self.inputBlock = { _, outStatus in
                // Exactly one buffer per `process`. Once handed over, report that input ran
                // dry so the converter flushes what it has instead of waiting for more.
                guard !src.supplied, let buffer = src.buffer else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                src.supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
        }

        /// Called on the REALTIME AUDIO THREAD. Converts, measures, CLASSIFIES and quantises
        /// in one pass over preallocated storage; allocates nothing.
        ///
        /// Classification lives here, next to the RMS, and not up in `append`, because that
        /// is the only place the noise floor can be tracked without either taking a lock or
        /// recomputing the level. Measuring was already this method's job — the gate is the
        /// second half of the same measurement.
        func process(_ buffer: AVAudioPCMBuffer) -> Measurement {
            let produced = convertIntoScratch(buffer)
            guard produced > 0 else {
                // NOTHING WAS MEASURED, so nothing is published. `samples == 0` is `append`'s
                // signal to leave the trace fields alone: publishing a zero floor and a zero
                // threshold from here would put `thr=0.00000` into the LEVEL line, a threshold
                // the gate never used, which is precisely the class of lie the
                // `floor=(never measured)` treatment exists to prevent.
                return Measurement(samples: 0, rms: 0, floor: noiseFloor,
                                   floorSeeded: noiseFloorSeeded, threshold: speechThreshold,
                                   isSpeech: false, reseeded: false)
            }

            // RMS of the whole buffer decides speech vs. silence for the whole buffer.
            // Per-buffer rather than per-sample granularity is deliberate: a tap buffer is
            // already shorter than any phoneme, and sample-level gating would chatter on
            // zero crossings.
            var sumSquares: Float = 0
            scratch.withUnsafeBufferPointer { src in
                for i in 0..<produced {
                    let s = src[i]
                    sumSquares += s * s
                }
            }
            // Clamped HERE rather than at the return, so the gate classifies, the tracker
            // learns from, and the trace prints one single value. A gate comparing an
            // unclamped level against a floor built from clamped ones would be comparing two
            // different quantities.
            let rms = min((sumSquares / Float(produced)).squareRoot(), 1)

            // Snapshot the pair the classification is about to use, THEN update the tracker.
            // `threshold` is derived from `floor` here and nowhere else, so the two numbers
            // that reach the trace always satisfy the gate's own formula and always describe
            // the compare that actually happened. The published floor is therefore one buffer
            // (~21 ms) behind the tracker; at a 5 s trace cadence that is not a distinction.
            let floor = noiseFloor
            let floorSeeded = noiseFloorSeeded
            let threshold = speechThreshold
            let isSpeech = rms >= threshold
            let reseeded = updateFloor(rms: rms, isSpeech: isSpeech, samples: produced)

            // Clamp BEFORE scaling. An un-clamped 1.2 would scale past Int16.max and wrap to
            // a large negative value — a full-amplitude sign flip, which sounds like a
            // gunshot and wrecks recognition on exactly the loudest (clearest) syllables.
            scratch.withUnsafeBufferPointer { src in
                pcm.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<produced {
                        let clamped = min(max(src[i], -1), 1)
                        dst[i] = Int16(clamped * 32767)
                    }
                }
            }
            return Measurement(samples: produced, rms: rms, floor: floor,
                               floorSeeded: floorSeeded, threshold: threshold,
                               isSpeech: isSpeech, reseeded: reseeded)
        }

        /// Fold one buffer into the room's noise floor. REALTIME AUDIO THREAD, no lock, no
        /// allocation, no tracing: a handful of compares, two multiplies and one divide, in
        /// the pass that had already touched this data.
        ///
        /// - Returns: true if the stall rescue fired on this buffer.
        private func updateFloor(rms: Float, isSpeech: Bool, samples: Int) -> Bool {
            // NON-FINITE IS REJECTED BEFORE IT REACHES THE FLOOR, and this guard is the whole
            // of the non-finite handling this file needs. `process` clamps with `min(rms, 1)`
            // and `min(.infinity, 1)` is 1, so `+inf` can never arrive here — it is folded
            // into full scale upstream. Only NaN can, and it must not be admitted: one fall
            // step yields a NaN floor, `rms < noiseFloor` is then false for every finite
            // sample so the else-branch folds NaN into NaN forever, and
            // `max(0.0025, nan * 3.0)` returns 0.0025 because `y >= x` is false for NaN. The
            // gate would revert to the exact fixed constant this tracker replaces, silently,
            // for the life of the converter. The source would be a virtual or aggregate input
            // device handing the tap garbage; a 0/0 of our own making is impossible here,
            // `process` has already guarded `produced > 0`.
            guard rms.isFinite else { return false }

            if !noiseFloorSeeded {
                // The bound is `absoluteQuietFloor`, not `> 0`, for `main.swift`'s measured
                // reason: any positive value admits a ~3e-4 route-switch artifact (Bluetooth,
                // AirPods, an aggregate device coming up) as the seed, which pins the
                // threshold to the old fixed constant until the slow rise climbs out. A room
                // whose ambient never reaches 0.0025 therefore never seeds, the floor stays
                // 0, and the threshold rides `absoluteQuietFloor` for the whole capture —
                // that is the DESIGNED resting state and exactly what that constant is for,
                // not a missed seed to be fixed by lowering this bound.
                //
                // THE SEED'S SAFETY DIRECTION IS THE OPPOSITE OF `main.swift`'s, and that
                // file's sentence about it must NOT be carried over here. There an
                // over-estimate makes the WATCHDOG HARDER TO ARM, which is the safe way to be
                // wrong. Here an over-estimate makes the ENGINE DEAF: seeding from a speech
                // buffer at 0.05 puts the threshold at 0.15, every subsequent buffer reads as
                // silence, `drainTick`'s `.idle` branch discards it all as pre-roll, and
                // nothing is transcribed at all.
                //
                // IT IS BOUNDED RATHER THAN ABSENT, and the bound is arithmetic: from a 0.05
                // seed against this room's ~0.003 ambient the 2 s fall needs
                // ln(0.05 / 0.003) x 2 ≈ 6 s to heal, after which classification is correct
                // for the rest of the capture. Simulated at 0.04 against 0.003 with the seed
                // forced onto the first buffer — the worst case available — the capture
                // classified 45% of buffers as speech where the constructed signal held 56%,
                // i.e. the whole error was those first seconds and nothing after them.
                //
                // WHAT ACTUALLY MAKES IT UNLIKELY IS STRUCTURAL, not an assumption about how
                // fast the user talks. `append` cannot classify anything until the drain tick
                // has built the converter, which is one `drainIntervalSeconds` later — the
                // ~100 ms the `capturedTapFormat` note already accounts for as never sent. So
                // the first buffer this gate ever sees is already ~100 ms into the capture,
                // and the hotkey press precedes speech by more than that. Stated as the
                // reason it is rare, NOT as a reason it cannot happen: the seed is the one
                // step in this tracker with no field measurement behind it, and the LEVEL
                // line is what will show it — a first window with a high `floor=` that falls
                // steeply across the next two is this failing and healing.
                if rms >= GeminiLiveRecognizer.absoluteQuietFloor {
                    noiseFloor = rms
                    noiseFloorSeeded = true
                }
                return false
            }

            // The per-buffer coefficient, derived from this buffer's OWN duration so the time
            // constants stay in seconds whatever size the tap hands over — see
            // `noiseFloorFallSeconds`. Clamped at 1 so a pathologically long buffer snaps the
            // floor onto the sample instead of overshooting past it.
            let seconds = Float(samples) / Float(GeminiLiveRecognizer.outputSampleRate)

            if rms < noiseFloor {
                // Fast down, from any buffer below the floor. The floor therefore rides the
                // MINIMUM envelope of the room rather than its mean, which is what a noise
                // floor is and what makes the ratio above meaningful.
                stallSamples = 0
                let alpha = min(1, seconds / Float(GeminiLiveRecognizer.noiseFloorFallSeconds))
                noiseFloor += alpha * (rms - noiseFloor)
                return false
            }

            if !isSpeech {
                // Slow up, and ONLY from a buffer the gate did not call speech. THIS IS THE
                // DELIBERATE DIVERGENCE FROM `main.swift`, which folds every sample in and
                // documents what that costs: "the gate does go deaf at tick 75 of speech with
                // NO gap at all". That file survives its own blind spot only because its
                // ladder arms at three ticks and acts at six, so 75 is out of reach. THIS
                // gate has no such bound — it runs continuously for the whole capture, and a
                // floor that climbed under a long monologue would lift the threshold above
                // the speaker, close every turn mid-word, and deliver measurement (3)'s 89%
                // regime by the back door. Excluding speech removes that mode by
                // construction instead of out-running it.
                stallSamples = 0
                let alpha = min(1, seconds / Float(GeminiLiveRecognizer.noiseFloorRiseSeconds))
                noiseFloor += alpha * (rms - noiseFloor)
                return false
            }

            // Speech — or a step in ambient wearing its clothes. Teach the floor nothing, but
            // COUNT: one buffer cannot tell the two apart and only their duration can. See
            // `floorStallSeconds` for why the rescue is bounded, cheap when wrong, and
            // explicitly provisional.
            stallSamples += samples
            guard stallSamples >= stallSampleLimit else { return false }
            noiseFloor = rms
            stallSamples = 0
            return true
        }

        /// Drain `buffer` through the converter into `scratch`. Audio-thread only.
        private func convertIntoScratch(_ buffer: AVAudioPCMBuffer) -> Int {
            guard buffer.frameLength > 0 else { return 0 }

            source.buffer = buffer
            source.supplied = false
            defer { source.buffer = nil }

            var total = 0
            var error: NSError?

            while total < scratch.count {
                // `convert` writes frameLength on the output buffer; reset it so a short
                // final pass cannot be misread as the previous pass's length.
                converted.frameLength = 0
                let status = converter.convert(to: converted,
                                               error: &error,
                                               withInputFrom: inputBlock)
                let produced = Int(converted.frameLength)
                if produced > 0, let channels = converted.floatChannelData {
                    // Guarded rather than force-unwrapped: a nil here would silently yield
                    // zero samples, which looks exactly like a dead microphone.
                    let n = min(produced, scratch.count - total)
                    let src = channels[0]
                    scratch.withUnsafeMutableBufferPointer { dst in
                        if let base = dst.baseAddress {
                            base.advanced(by: total).update(from: src, count: n)
                        }
                    }
                    total += n
                }
                // Break on every status other than `.haveData` — including `.error` and
                // `.endOfStream`. Looping only on the status we expect would spin forever the
                // first time the converter reports a problem.
                if status != .haveData { break }
                if produced == 0 { break }
            }
            return total
        }
    }

    // MARK: - Turn state machine

    /// Strictly sequenced, because measurement (4) says an `activityEnd` chased immediately
    /// by an `activityStart` earns a server-side `1011 Internal error`. Nothing opens a turn
    /// from inside the close path; only a drain tick that finds `.idle` does.
    private enum TurnState: Equatable {
        /// No activity declared. Audio accumulates; while it is all silence, everything
        /// older than the pre-roll is discarded unsent.
        case idle
        /// `activityStart` sent. Audio is streaming; the boundary tests run every tick.
        case open
        /// `activityEnd` sent. NO audio is sent — it accumulates in the ring for the next
        /// turn — while this turn's transcript messages drain in.
        case closing
    }

    // MARK: - Shared state (audio thread ⇄ queue)

    /// Guards every stored property below. Held for pointer reads, counter updates and one
    /// bounded memcpy — never across a network call, and never across a user callback.
    private let lock = OSAllocatedUnfairLock()

    private var _onPartial: (@Sendable (String) -> Void)?
    private var _onFinal: (@Sendable (String) -> Void)?
    private var _onState: (@Sendable (State) -> Void)?

    /// Bumped by `start()` and by the end of `stop()`. Every block scheduled on `queue`
    /// carries the generation it was scheduled under and returns immediately if it no longer
    /// matches — which is what makes `stop()` immediately followed by `start()` safe.
    private var generation = 0
    /// False from the instant `stop()` is called. `append` stops writing to the ring here;
    /// the drain loop exits on the next tick.
    private var isStarted = false
    /// Stored, and — honestly — NOT APPLIED. See `setContextualStrings`.
    private var contextualStrings: [String] = []

    /// The tap's format, captured from the first buffer `append` ever sees.
    ///
    /// Same bootstrap `LiveRecognizer` uses for its replay ring, for the same reason and with
    /// one extra constraint. The converter must be built for the exact format the tap
    /// produces and must be built OFF the audio thread — but `append` may not schedule that
    /// work either, because `DispatchQueue.async` allocates to capture its block. So `append`
    /// only records `buffer.format` (a property read inside a critical section it was taking
    /// anyway), and the drain tick on `queue`, which is already running at 10 Hz, notices and
    /// builds it. The honest cost: the first ~100 ms of a capture is not converted and is
    /// therefore never sent. Irrelevant — the hotkey press precedes speech by far more.
    private var capturedTapFormat: AVAudioFormat?
    /// Published by `prepareConverterIfNeeded`, consumed by `append`.
    private var converter: Converter?
    /// Set once a converter build has failed, so the drain tick does not retry it ten times a
    /// second forever. A failure here is fatal to the capture and is reported once.
    private var converterFailed = false

    /// ── THE RING ──────────────────────────────────────────────────────────────────────
    /// Preallocated 16 kHz mono Int16, written on the audio thread, read on `queue`. Never
    /// resized after `init`.
    private var ring: [Int16]
    /// Next write position (wraps).
    private var ringWrite = 0
    /// Monotonic count of samples ever written in this capture. The ONLY honest clock in
    /// this file: everything the queue side reasons about — what has been sent, how long the
    /// turn is, what the ring has evicted — is a difference of two values of this counter.
    /// Reset by `start()`, along with the three below.
    private var totalSamples: UInt64 = 0
    /// Monotonic count of samples classified as speech. A turn's speech is the difference
    /// between this and its value when the turn opened.
    private var speechSamples: UInt64 = 0
    /// Consecutive silent samples at the very end of the stream. Reset to zero by any speech
    /// buffer. This is the quantity the silence boundary is decided on.
    private var trailingSilence = 0

    /// ── WHAT THE GATE MEASURED, PUBLISHED FOR THE TRACE ──────────────────────────────
    /// Written by `append` inside the critical section it was taking anyway; read and reset
    /// by `traceLevelIfDue` on `queue`. DIAGNOSTICS ONLY — nothing in this file branches on
    /// any of them, and the gate's own working state stays inside `Converter`, where it needs
    /// no lock at all. They exist because the numbers that decide every turn boundary are
    /// computed on a thread that may not trace, and a gate nobody can see the measurements of
    /// is how a fixed 0.0025 threshold survived in this file unchallenged.
    private var gateLastRMS: Float = 0
    private var gateLastFloor: Float = 0
    private var gateLastFloorSeeded = false
    private var gateLastThreshold: Float = 0
    /// Buffers, speech buffers and stall rescues SINCE THE LAST LEVEL LINE — a window, not a
    /// running total, so each line describes its own five seconds and two consecutive lines
    /// can be compared without subtracting.
    private var gateBuffers: UInt32 = 0
    private var gateSpeechBuffers: UInt32 = 0
    private var gateReseeds: UInt32 = 0

    // MARK: - Queue-only state

    // Everything below is touched ONLY from blocks running on `queue`, which is serial, so
    // the queue itself is the mutual exclusion. It is deliberately NOT under `lock`: the
    // audio thread has no business reading a socket or a turn, and widening the lock's remit
    // to cover them would put network bookkeeping in the realtime path's way.

    private var socket: URLSessionWebSocketTask?
    /// Monotonic socket id. Compared instead of holding a reference, so the `@Sendable`
    /// completion handlers capture nothing but `Int`s and `self` — `URLSessionWebSocketTask`
    /// is not something to smuggle across a concurrency boundary.
    private var socketID = 0
    /// True between `setupComplete` and teardown. No audio is sent before it.
    private var isReady = false
    private var reconnectAttempts = 0
    /// Set by `stop()`'s flush so a disconnect during the flush does not reconnect.
    private var isStopping = false
    /// Guards `finishStop` against the flush timeout and the real final both firing it.
    private var stopFinished = false

    private var turnState: TurnState = .idle
    /// Monotonic turn id, so a turn's own timeout cannot fire on its successor.
    private var turnID = 0
    /// The transcript fragments of the CURRENT turn, concatenated. A turn may emit several
    /// `inputTranscription` messages; this is where they are joined. Never traced.
    private var turnText = ""
    /// Value of `totalSamples` at the read cursor — everything below this has been sent or
    /// deliberately discarded as pre-roll silence.
    private var sentSamples: UInt64 = 0
    /// `sentSamples` when the open turn declared itself. The turn's length is measured in
    /// SENT audio, not wall clock and not written audio, so a drain that is catching up after
    /// a reconnect cannot force-close a turn whose audio it has not finished sending.
    private var turnStartSample: UInt64 = 0
    /// `speechSamples` when the open turn declared itself. Under-counts the turn's speech by
    /// at most one drain tick (the backlog present at open, whose pre-roll is silence by
    /// construction), which only ever makes `minTurnSpeechSeconds` slightly conservative.
    private var turnSpeechStart: UInt64 = 0
    private var turnClosedAt: DispatchTime?
    /// Fragments that arrived while no turn was open — a late tail after a timed-out turn.
    /// Counted, never kept: joining them to the NEXT turn would type one turn's words inside
    /// another's. Reported as a count at teardown; the text itself is discarded unread.
    private var orphanFragments = 0
    /// Samples the ring evicted before the drain could send them, this capture.
    private var droppedSamples: UInt64 = 0
    /// Drain ticks since the last LEVEL line. See `levelLineTicks`.
    private var levelTickCount = 0
    /// Preallocated staging for one send. Queue-only, so it needs no lock.
    private var outbound: [Int16]

    /// All connection, send, receive and turn work happens here — never on the audio thread.
    /// Serial, which is what makes the queue-only state above safe without a second lock.
    private let queue = DispatchQueue(label: "GeminiLiveRecognizer.session", qos: .userInitiated)

    /// One ephemeral session for the life of this object. Ephemeral so no part of a
    /// handshake carrying the key is ever written to a disk cache, cookie jar, or credential
    /// store — the same reasoning as `GeminiClient`'s, and load-bearing here because the key
    /// is in the URL.
    private let urlSession: URLSession

    /// The API key, or nil when the dotenv file has no `GOOGLE_API_KEY` line. Never logged,
    /// never interpolated into an error, and actively scrubbed by `redact(_:)`.
    private let apiKey: String?
    /// Where the key was looked for. Safe to report — it is a path, not a secret.
    private let keyPath: String

    /// 16 kHz mono Float32, the converter's destination. Built once here rather than per
    /// converter, and never `static`: `AVAudioFormat` is not `Sendable`.
    private let outputFormat: AVAudioFormat?

    // MARK: - Init

    /// Does not throw, by design: main.swift constructs this unconditionally at app init,
    /// alongside the Apple engine, and construction must be inert. An absent key makes
    /// `isSupported` false — it is not a construction failure, and `start()` is where it
    /// becomes an error.
    init() {
        let url = GeminiClient.defaultKeyFileURL()
        self.keyPath = url.path
        // `name:` is required by `CloudKeyFile.loadKey`, which is the point: this call site
        // and `GeminiClient.init` used to carry matching paragraph-long warnings that
        // omitting the label would silently read the *other* provider's secret out of the
        // very same file and put it in a URL bound for Google. That hazard is now a compile
        // error rather than a comment — see CloudKeyFile.swift.
        self.apiKey = try? CloudKeyFile.loadKey(from: url, name: GeminiClient.keyName)

        self.outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Self.outputSampleRate,
                                          channels: Self.outputChannelCount,
                                          interleaved: false)

        let rate = Self.outputSampleRate
        self.ringCapacity = Int(rate * Self.ringSeconds)
        self.silenceCloseSamples = Int(rate * Self.silenceCloseSeconds)
        self.shortUtteranceCloseSamples = Int(rate * Self.shortUtteranceCloseSeconds)
        self.minTurnSpeechSamples = UInt64(rate * Self.minTurnSpeechSeconds)
        self.maxTurnSamples = UInt64(rate * Self.maxTurnSeconds)
        self.preRollSamples = UInt64(rate * Self.preRollSeconds)
        self.maxSendSamples = Int(rate * Self.maxSendSeconds)
        self.ring = [Int16](repeating: 0, count: Int(rate * Self.ringSeconds))
        self.outbound = [Int16](repeating: 0, count: Int(rate * Self.maxSendSeconds))

        let cfg = URLSessionConfiguration.ephemeral
        // Idle timeout, not handshake timeout: a WebSocket that hears nothing from the server
        // for this long is treated as dead. Generous, because a genuinely silent room
        // produces no turns and therefore no server messages for minutes at a time — a 60 s
        // default would tear down a perfectly healthy connection during a long pause.
        cfg.timeoutIntervalForRequest = 300
        cfg.waitsForConnectivity = false     // fail and report, never queue silently
        cfg.httpMaximumConnectionsPerHost = 2
        self.urlSession = URLSession(configuration: cfg)
    }

    // MARK: - Capability

    /// True when a `GOOGLE_API_KEY` was found at construction.
    ///
    /// Cached, unlike `LiveRecognizer.isSupported` — see the divergence note in the file
    /// header. The consequence, stated so nobody is surprised: adding the key to the dotenv
    /// file while MicTest is running does not light this up until the app is relaunched.
    var isSupported: Bool {
        guard let apiKey else { return false }
        return !apiKey.isEmpty
    }

    // MARK: - Lifecycle

    /// Begin a session: open the socket, run the setup handshake, start the drain loop.
    /// A no-op if one is already running.
    ///
    /// The already-started check comes FIRST, before validation, so a second `start()` on a
    /// running session is a cheap no-op rather than a re-litigation that could throw and tear
    /// down a session that is working fine. Same ordering as `LiveRecognizer.start()`.
    func start() throws {
        lock.lock()
        if isStarted {
            lock.unlock()
            return
        }
        lock.unlock()

        guard isSupported else {
            let error = RecognizerError.missingKey(keyPath)
            // Surface it to the UI as well as throwing, so a consumer that only wired up
            // `onState` still learns why nothing is happening.
            emitState(.unavailable(String(describing: error)))
            throw error
        }

        lock.lock()
        isStarted = true
        generation &+= 1
        let gen = generation
        // Re-captured per capture: the input DEVICE can change between holds of the key, and
        // a converter built for the old device's format would produce silence or garbage.
        capturedTapFormat = nil
        converter = nil
        converterFailed = false
        ringWrite = 0
        totalSamples = 0
        speechSamples = 0
        trailingSilence = 0
        // The gate's TELEMETRY, cleared so the first LEVEL line of a capture describes this
        // capture. The gate's own floor needs no clearing here and deliberately is not
        // cleared here: it lives inside `Converter`, which the two lines above have just
        // dropped, so a fresh capture measures a fresh room by construction. See the working
        // state comment in `Converter`.
        gateLastRMS = 0
        gateLastFloor = 0
        gateLastFloorSeeded = false
        gateLastThreshold = 0
        gateBuffers = 0
        gateSpeechBuffers = 0
        gateReseeds = 0
        lock.unlock()

        queue.async { [weak self] in self?.beginConnection(generation: gen) }
    }

    /// End the session: close the open turn, wait briefly for its transcript, then drop the
    /// socket and go idle.
    ///
    /// `activityEnd` rather than a bare disconnect, for the same reason `LiveRecognizer.stop`
    /// sends `endAudio()` rather than `cancel()`: the tail of what the user just said is
    /// still wanted, and closing the socket on top of an open turn throws it away. Bounded by
    /// `finalFlushTimeoutSeconds` so a silent server can never leave a live socket behind.
    ///
    /// Note this does NOT bump the generation — the drain loop exits on `isStarted` alone,
    /// while the receive loop must stay alive to deliver the flushed transcript. The
    /// generation moves in `finishStop`, once there is nothing left to hear.
    func stop() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            emitState(.idle)
            return
        }
        isStarted = false
        let gen = generation
        lock.unlock()

        queue.async { [weak self] in self?.beginStopFlush(generation: gen) }
    }

    // MARK: - Realtime audio thread

    /// Called on the REALTIME AUDIO THREAD.
    ///
    /// Format capture first, converter second — that order is load-bearing. Bailing out on a
    /// nil converter before recording `buffer.format` would mean the format is never
    /// captured, so the converter is never built, so the engine is permanently deaf with no
    /// error anywhere.
    ///
    /// The expensive part (resample, RMS, quantise) happens OUTSIDE the lock, against
    /// storage owned by `Converter`; the critical section is one bounded memcpy into the ring
    /// plus four counter updates. Nothing here allocates, traces, or schedules — see the
    /// isolation rule in the file header, and in particular why `append` may not call
    /// `queue.async`.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let needsFormatCapture = (capturedTapFormat == nil)
        let started = isStarted
        let box = converter
        lock.unlock()

        if needsFormatCapture {
            // A property read, no allocation, exactly once per capture. The drain tick on
            // `queue` picks it up from here.
            let format = buffer.format
            lock.lock()
            if capturedTapFormat == nil { capturedTapFormat = format }
            lock.unlock()
        }

        guard started, let box else { return }

        // Convert, measure AND classify in one pass, outside the lock, against storage and
        // floor state owned by `box`. The speech decision is no longer a compare against a
        // constant — see "The adaptive speech gate" — but it is still made here, on this
        // thread, at no additional cost: the tracker rides the RMS the converter was already
        // computing.
        let measured = box.process(buffer)
        let produced = measured.samples
        guard produced > 0 else { return }

        let capacity = ringCapacity
        lock.lock()
        // Copy into the ring, wrapping at most once. Oldest samples are overwritten without
        // ceremony; the drain detects the eviction from the monotonic counters and reports it
        // (see `advancePastEvicted`), which is the honest place for that accounting because
        // it is the side that knows what it had not yet sent.
        var written = 0
        while written < produced {
            let room = capacity - ringWrite
            let n = min(room, produced - written)
            ring[ringWrite ..< (ringWrite + n)] = box.pcm[written ..< (written + n)]
            ringWrite = (ringWrite + n) % capacity
            written += n
        }
        totalSamples &+= UInt64(produced)
        if measured.isSpeech {
            speechSamples &+= UInt64(produced)
            trailingSilence = 0
        } else {
            trailingSilence += produced
        }
        // Publish what the gate measured, for the periodic LEVEL line on `queue`. Seven
        // scalar stores and two compares, inside a critical section that was already doing a
        // ~680-byte memcpy plus four counter updates — it does not meaningfully lengthen it,
        // and it is the only way a number computed on this thread can ever be seen. Nothing
        // here allocates, traces or schedules: the sampling, the formatting and the file I/O
        // all happen on `queue`, and the isolation rule in the file header is intact.
        gateLastRMS = measured.rms
        gateLastFloor = measured.floor
        gateLastFloorSeeded = measured.floorSeeded
        gateLastThreshold = measured.threshold
        gateBuffers &+= 1
        if measured.isSpeech { gateSpeechBuffers &+= 1 }
        if measured.reseeded { gateReseeds &+= 1 }
        lock.unlock()
    }

    // MARK: - Contextual biasing

    /// Stored and — say it plainly — NOT APPLIED.
    ///
    /// The Live API's `setup` message has no bias-vocabulary field. `GeminiClient` solves the
    /// same problem for the REST path by folding the terms into its prompt, but that option
    /// does not exist here: this session's whole configuration is `inputAudioTranscription`,
    /// and the one place a prompt could go — `systemInstruction` — was never verified against
    /// this model, while its non-live sibling rejects developer instructions outright
    /// ("Developer instruction is not enabled for this model", recorded in `GeminiClient`).
    /// Shipping an unverified field on the setup message risks failing the handshake for
    /// every user in exchange for a spelling hint.
    ///
    /// So the terms are kept — the storage is cheap and a future verified mechanism should
    /// find them already here — and this engine transcribes without them. They are NOT lost
    /// from the app: the cloud accuracy pass (`GeminiClient.transcribe(wav:keyterms:)`) still
    /// receives the same list and still applies it. A silent drop would be the unacceptable
    /// version of this; a documented one is merely a limitation.
    func setContextualStrings(_ terms: [String]) {
        lock.lock()
        contextualStrings = terms
        lock.unlock()
    }

    // MARK: - Connection

    /// Runs on `queue`. Resets the queue-only half of the world and opens the socket.
    ///
    /// The drain loop starts HERE, not on `setupComplete`, and that is deliberate: it is also
    /// the poller that builds the converter (`prepareConverterIfNeeded`), and the converter
    /// must be ready by the time the handshake finishes, not after it.
    private func beginConnection(generation: Int) {
        guard isLive(generation) else { return }
        // Sweep any socket the PREVIOUS capture left behind. `stop()` normally cancels it in
        // `finishStop`, but a `stop()` chased immediately by a `start()` retires that
        // generation before its teardown runs, and an orphaned `URLSessionWebSocketTask`
        // stays connected — a live microphone stream to Google that nothing owns. The queue
        // is serial, so by the time this runs every block of the old generation has given up.
        if let stale = socket {
            stale.cancel(with: .goingAway, reason: nil)
            socket = nil
            socketID &+= 1
            Self.trace("gemini-live: cancelled a socket orphaned by a stop/start race")
        }
        sentSamples = 0
        reconnectAttempts = 0
        isStopping = false
        stopFinished = false
        turnState = .idle
        turnText = ""
        turnClosedAt = nil
        orphanFragments = 0
        droppedSamples = 0
        levelTickCount = 0
        Self.trace("gemini-live: capture starting (generation \(generation))")
        connect(generation: generation)
        scheduleDrain(generation: generation)
    }

    /// Runs on `queue`. Builds the URL, opens the WebSocket, sends `setup`, arms the receive
    /// loop and the setup timeout.
    private func connect(generation: Int) {
        guard isLive(generation) else { return }
        guard let url = endpointURL() else {
            let error = RecognizerError.badEndpoint("the key could not be percent-encoded")
            emitState(.unavailable(String(describing: error)))
            return
        }

        socketID &+= 1
        let id = socketID
        isReady = false
        turnState = .idle
        turnText = ""

        let task = urlSession.webSocketTask(with: url)
        socket = task
        task.resume()
        Self.trace("gemini-live: socket \(id) opening (attempt \(reconnectAttempts + 1))")

        send(Self.setupMessage, generation: generation, socketID: id, label: "setup")
        receiveNext(on: task, generation: generation, socketID: id)

        // The net: a socket that resumes but never completes setup would otherwise sit there
        // with the microphone hot and nothing being transcribed.
        queue.asyncAfter(deadline: .now() + Self.setupTimeoutSeconds) { [weak self] in
            guard let self, self.isLive(generation), self.socketID == id, !self.isReady else {
                return
            }
            let seconds = String(format: "%.0f", Self.setupTimeoutSeconds)
            self.handleDisconnect(generation: generation,
                                  socketID: id,
                                  reason: "setup did not complete within \(seconds) s")
        }
    }

    /// The endpoint with the key in the query string. The ONLY place the two are joined, and
    /// the result is never traced, never stored, and never interpolated into an error — see
    /// the privacy note in the file header.
    private func endpointURL() -> URL? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?"))
        guard let escaped = apiKey.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: Self.endpointBase + "?key=" + escaped)
    }

    /// Re-arms itself on every message. `URLSessionWebSocketTask.receive` is ONE-SHOT: miss
    /// this recursion and the engine delivers exactly one transcript per connection and then
    /// goes silent with no error at all — indistinguishable from a wedge, and far harder to
    /// diagnose than a crash.
    ///
    /// The completion handler runs on URLSession's own queue, so it does the minimum possible
    /// there — flatten the result into two `String?`s, both `Sendable` — and hops to `queue`
    /// for everything else. The socket itself is deliberately NOT captured; `socketID` is
    /// what identifies it.
    private func receiveNext(on task: URLSessionWebSocketTask, generation: Int, socketID: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            var text: String?
            var failure: String?
            switch result {
            case .success(.string(let s)):
                text = s
            case .success(.data(let d)):
                text = String(decoding: d, as: UTF8.self)
            case .success:
                break                       // a future Message case; ignored, not fatal
            case .failure(let error):
                failure = Self.describeError(error)
            }
            // Rebound as immutable `let`s before the hop. Capturing the `var`s directly is a
            // Sendable-closure diagnostic and, worse than the warning, would let this frame's
            // locals be read after it returns. Two `String?`s are all that crosses.
            let received = text
            let receiveFailure = failure
            self.queue.async {
                guard self.isLive(generation), self.socketID == socketID else { return }
                if let receiveFailure {
                    self.handleDisconnect(generation: generation,
                                          socketID: socketID,
                                          reason: "receive failed: " + receiveFailure)
                    return
                }
                if let received {
                    self.handle(message: received, generation: generation, socketID: socketID)
                }
                guard let live = self.socket, self.socketID == socketID else { return }
                self.receiveNext(on: live, generation: generation, socketID: socketID)
            }
        }
    }

    /// Runs on `queue`. Send one frame, reporting a failure as a disconnect.
    private func send(_ json: String, generation: Int, socketID: Int, label: String) {
        guard let socket, self.socketID == socketID else { return }
        socket.send(.string(json)) { [weak self] error in
            guard let self, let error else { return }
            let described = Self.describeError(error)
            self.queue.async {
                guard self.isLive(generation), self.socketID == socketID else { return }
                let reason = "send failed (\(label)): " + described
                self.handleDisconnect(generation: generation, socketID: socketID, reason: reason)
            }
        }
    }

    /// Runs on `queue`. One disconnect per socket: the `socketID` test is what stops a failed
    /// send, a failed receive and the setup net from each starting their own reconnect for
    /// the same dead connection.
    private func handleDisconnect(generation: Int, socketID: Int, reason: String) {
        guard isLive(generation), self.socketID == socketID else { return }

        let closeCode = socket?.closeCode.rawValue ?? 0
        socket?.cancel()
        socket = nil
        isReady = false
        turnState = .idle
        turnText = ""
        // Bump so nothing still holding the old id can act on this connection again.
        self.socketID &+= 1

        // Server code 1011 ("Internal error") is the one this file has actually provoked, by
        // reopening a turn in the same tick it closed one. The sequencing above prevents it;
        // reporting the code keeps that verifiable rather than assumed.
        let codeNote = closeCode == 0 ? "" : " (close code \(closeCode))"
        Self.trace("gemini-live: disconnected — " + redact(reason) + codeNote)

        if isStopping {
            // A disconnect during the stop flush is not worth reconnecting for — there is
            // nothing left to transcribe. Finish the stop instead.
            finishStop(generation: generation, reason: "socket closed during the stop flush")
            return
        }

        reconnectAttempts += 1
        guard reconnectAttempts <= Self.maxReconnectAttempts else {
            let head = "Gemini Live gave up after \(Self.maxReconnectAttempts) reconnect "
            let tail = "attempts — stop and start dictation to try again: "
            emitState(.unavailable(head + tail + redact(reason)))
            Self.trace("gemini-live: reconnect bound spent; engine is quiet until restarted")
            return
        }

        let exponent = Double(reconnectAttempts - 1)
        let delay = min(Self.reconnectBaseDelaySeconds * pow(2, exponent),
                        Self.reconnectMaxDelaySeconds)
        let attemptNote = "reconnecting \(reconnectAttempts)/\(Self.maxReconnectAttempts) "
        let delayNote = "in \(String(format: "%.1f", delay)) s: "
        emitState(.unavailable(attemptNote + delayNote + redact(reason)))

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isLive(generation) else { return }
            self.connect(generation: generation)
        }
    }

    // MARK: - Incoming messages

    /// Runs on `queue`. Parses one server frame.
    ///
    /// `JSONSerialization` rather than `Codable`: the payload is a small, sparsely populated
    /// envelope where every level is optional, and the discriminator this needs is "is this
    /// key present", not "does this decode". Everything is read out synchronously here — the
    /// `[String: Any]` never crosses a closure boundary, because `Any` is not `Sendable`.
    private func handle(message: String, generation: Int, socketID: Int) {
        guard let data = message.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // Byte count only. The body of a server frame can carry transcript text.
            Self.trace("gemini-live: unparsable frame (\(message.utf8.count) bytes); ignored")
            return
        }

        if root["setupComplete"] != nil {
            handleSetupComplete(generation: generation)
            return
        }

        if let error = root["error"] as? [String: Any] {
            // Google's error envelope. `status` and `code` are safe to report; `message` can
            // echo request material, so it is deliberately not carried into the reason.
            let code = (error["code"] as? Int).map(String.init) ?? "?"
            let status = (error["status"] as? String) ?? "unknown"
            handleDisconnect(generation: generation,
                             socketID: socketID,
                             reason: "server error \(code)/\(status)")
            return
        }

        if root["goAway"] != nil {
            // The server announcing it is about to close. Nothing to do but note it — the
            // receive loop's failure will drive the reconnect a moment later.
            Self.trace("gemini-live: server sent goAway; a disconnect is expected")
            return
        }

        guard let content = root["serverContent"] as? [String: Any] else { return }

        if let transcription = content["inputTranscription"] as? [String: Any],
           let fragment = transcription["text"] as? String, !fragment.isEmpty {
            switch turnState {
            case .open, .closing:
                // A turn may emit several of these; they are concatenated verbatim, with no
                // separator inserted. Thai has no inter-word space and the server's
                // fragmentation is its own — adding anything here would corrupt the text.
                turnText += fragment
            case .idle:
                // A tail that arrived after this turn's own timeout already finished it.
                // Counted and dropped: attaching it to the NEXT turn would type one turn's
                // words inside another's, which is worse than losing a fragment.
                orphanFragments += 1
            }
        }

        let turnComplete = (content["turnComplete"] as? Bool) ?? false
        let generationComplete = (content["generationComplete"] as? Bool) ?? false
        if turnComplete || generationComplete {
            let signal = turnComplete ? "turnComplete" : "generationComplete"
            finishTurn(generation: generation, reason: signal)
        }
    }

    /// Runs on `queue`. The handshake landed: the socket is usable, the backoff resets, and
    /// the consumer is told it is listening.
    private func handleSetupComplete(generation: Int) {
        guard !isReady else { return }
        isReady = true
        reconnectAttempts = 0
        turnState = .idle
        turnText = ""
        Self.trace("gemini-live: setup complete on socket \(socketID); streaming")
        emitState(.listening)
    }

    // MARK: - Turns

    /// Runs on `queue`. The drain tick: build the converter if it is still owed, send what is
    /// buffered, and decide the turn boundary. Reschedules itself until `stop()`.
    private func scheduleDrain(generation: Int) {
        queue.asyncAfter(deadline: .now() + Self.drainIntervalSeconds) { [weak self] in
            self?.drainTick(generation: generation)
        }
    }

    private func drainTick(generation: Int) {
        guard isLive(generation) else { return }
        // Armed before every early return below, so a tick that finds nothing to do does not
        // silently end the loop. Only the liveness guard above stops it.
        defer { scheduleDrain(generation: generation) }

        prepareConverterIfNeeded()
        // BEFORE the socket guard, on purpose: the gate runs whenever audio does, so its
        // measurements must keep printing through a reconnect or a stalled handshake. Those
        // are exactly the stretches where knowing whether the microphone was being classified
        // as speech is worth having.
        traceLevelIfDue()

        guard socket != nil, isReady else { return }

        switch turnState {
        case .closing:
            // Measurement (4): nothing is sent and nothing is opened while a turn is closing.
            // The audio accumulates in the ring and becomes the head of the next turn.
            return

        case .idle:
            let snapshot = snapshotSkippingEvicted()
            reportDropped(snapshot.dropped)
            guard snapshot.pending > 0 else { return }
            if UInt64(max(0, snapshot.trailing)) >= snapshot.pending {
                // Everything unsent is silence. Discard all but the pre-roll rather than
                // stream room tone to Google for the length of a pause. Writing `sentSamples`
                // from a snapshot's `total` is safe even though the counter has moved since:
                // it only ever leaves MORE pre-roll than intended, never less, and the copy
                // that follows re-derives its window from scratch under the lock.
                if snapshot.pending > preRollSamples {
                    lock.lock()
                    sentSamples = snapshot.total - preRollSamples
                    lock.unlock()
                }
                return
            }
            openTurn(generation: generation, speech: snapshot.speech)
            sendPending(generation: generation)

        case .open:
            // Send FIRST, then judge the boundary against what is left. `pending` is read
            // out of the same critical section that did the copy, so it cannot disagree with
            // the send that just happened.
            let pending = sendPending(generation: generation)
            let counters = readCounters()
            let trailing = counters.trailing
            let turnSpeech = counters.speech &- turnSpeechStart
            let turnLength = sentSamples &- turnStartSample

            // THE SILENCE BOUNDARY — measurement (3), the reason this engine reaches 97.6%
            // where a 2 s timer reached 89%. `pending == 0` is part of it: closing while
            // audio is still queued would cut the turn at an arbitrary point rather than at
            // the silence the VAD found.
            if pending == 0,
               trailing >= silenceCloseSamples,
               turnSpeech >= minTurnSpeechSamples {
                closeTurn(generation: generation, reason: "silence", forced: false)
                return
            }

            // THE SHORT-UTTERANCE BOUNDARY — the same silence boundary, for a turn whose
            // speech never reached `minTurnSpeechSamples`. Without it a single short Thai
            // word can satisfy neither gate and rides to the backstop below, waiting ~9 s and
            // streaming ~8.7 s of silence to Google to do it. See
            // `shortUtteranceCloseSeconds` for why this closes the turn rather than
            // discarding it, and why its constant must stay ABOVE `silenceCloseSeconds`.
            //
            // `forced: false`, and that is not a formality: this IS a silence-aligned
            // boundary — a pause was found and no word was clipped — so counting it as a
            // forced close would inflate the one statistic `maxTurnSeconds` was left
            // deliberately measurable to collect. It gets its own reason string instead, so
            // `closed on silence`, `closed on short-utterance silence` and `forced close`
            // stay three countable populations in the trace.
            if pending == 0, trailing >= shortUtteranceCloseSamples {
                closeTurn(generation: generation,
                          reason: "short-utterance silence",
                          forced: false)
                return
            }

            // THE FORCED CLOSE — the one path that can clip a word. Traced every time, on
            // purpose: this constant was chosen without field data, and the traces are how
            // its real-world frequency becomes measurable instead of assumed.
            if turnLength >= maxTurnSamples {
                closeTurn(generation: generation, reason: "max-length", forced: true)
            }
        }
    }

    /// Runs on `queue`. One `gemini-live LEVEL:` line per ~5 s of capture, carrying the three
    /// numbers the gate actually used, plus what it made of them.
    ///
    /// UNCONDITIONAL AND PERIODIC, never event-driven, for the reason `main.swift` spells out
    /// beside its own LEVEL line: traces that fire only on an EVENT say nothing between
    /// events, and the failure this whole gate was rebuilt to fix — a threshold below the
    /// room, so the engine never hears silence — is precisely a failure that produces no
    /// events. A silence close that never happens cannot log its own absence. Before this
    /// line existed, the only way to learn what the gate had measured was to infer it from
    /// the ratio of `forced close` to `closed on silence`, after the fact.
    ///
    /// SAMPLED, NEVER PER BUFFER. At ~47 buffers a second a per-buffer line would be a 47 Hz
    /// flood into a file three other writers share, and `trace` does synchronous file I/O.
    /// `append` contributes seven scalar stores to this and nothing else; every string here
    /// is built on `queue`.
    ///
    /// `speech=` IS THE FIGURE TO READ FIRST after the first real session. It is the fraction
    /// of buffers in the window the gate called speech, and it is the one number that answers
    /// "is the gate measuring the room or drowning in it".
    ///
    /// THE BASELINES TO COMPARE IT AGAINST — SIMULATED, NOT FIELD-MEASURED, and labelled that
    /// way because this engine had never been run when they were produced. The gate's
    /// arithmetic was replayed against constructed signals at this room's documented 0.003
    /// ambient:
    ///
    ///   *   0%  — 60 s of ambient with nobody talking. The floor settles on 0.003 and the
    ///             threshold on 0.009. This is what an idle microphone must look like, and it
    ///             is the reading that keeps the `.idle` pre-roll discard working at all.
    ///   *  ~45% — continuous dictation, 0.5 s words separated by 0.4 s gaps. The floor stays
    ///             at ambient (0.00302 after 36 s), i.e. speech does NOT ratchet it upward —
    ///             the property `updateFloor`'s divergence from `main.swift` exists to get.
    ///   * 100% — the DEFECT. A fixed 0.0025 threshold against 0.003 ambient, every buffer
    ///             classified as speech, `trailingSilence` pinned at zero forever. If a real
    ///             session ever prints this, the gate is back to where it started and all
    ///             three failures listed under "The adaptive speech gate" are live again.
    ///
    /// So: a window near 100% with `trailingSilence=0.00 s` is the regression signature; a
    /// window near 0% while the user is speaking is the over-seeded-floor case (check whether
    /// `floor=` is high and falling). Healthy dictation swings widely between windows and
    /// falls well short of 100% in any window containing a pause. Replace these numbers with
    /// field measurements once there are some.
    private func traceLevelIfDue() {
        levelTickCount += 1
        guard levelTickCount >= Self.levelLineTicks else { return }
        levelTickCount = 0

        // One critical section, so the seven values agree with each other; formatted after
        // the unlock, because `trace` writes to a file and must never do so under this lock.
        lock.lock()
        let rms = gateLastRMS
        let floor = gateLastFloor
        let seeded = gateLastFloorSeeded
        let threshold = gateLastThreshold
        let buffers = gateBuffers
        let speechBuffers = gateSpeechBuffers
        let reseeds = gateReseeds
        let trailing = trailingSilence
        gateBuffers = 0
        gateSpeechBuffers = 0
        gateReseeds = 0
        lock.unlock()

        let window = String(format: "%.0f",
                            Self.drainIntervalSeconds * Double(Self.levelLineTicks))

        guard buffers > 0 else {
            // Not a formatting edge case but a real and otherwise invisible failure: the gate
            // runs on the tap, so an empty window means no audio reached this engine at all
            // — a dead or unrouted input, which from the socket's point of view is
            // indistinguishable from a very quiet room.
            Self.trace("gemini-live LEVEL: no audio buffers reached the gate in \(window) s "
                + "— the tap is not delivering to this engine")
            return
        }

        // `floor=(never measured)` rather than `0.00000`, because those are different facts
        // and only one of them is a measurement — a capture too short to seed used to render
        // the second as the first. `thr` stays numeric in that state on purpose: whatever the
        // floor's provenance, `absoluteQuietFloor` is genuinely the threshold the gate used.
        let floorPart = seeded
            ? String(format: "floor=%.5f", Double(floor))
            : "floor=(never measured)"
        let speechPercent = Int((Double(speechBuffers) / Double(buffers) * 100).rounded())
        Self.trace("gemini-live LEVEL: "
            + String(format: "rms=%.5f ", Double(rms))
            + floorPart
            + String(format: " thr=%.5f", Double(threshold))
            + " speech=\(speechPercent)% (\(speechBuffers)/\(buffers) buffers) "
            + String(format: "trailingSilence=%.2f s ",
                     Double(trailing) / Self.outputSampleRate)
            + "turn=\(turnState)")

        if reseeds > 0 {
            // Its own line, and greppable, because `floorStallSeconds` is explicitly
            // provisional and these are the only evidence that will ever settle it.
            let stall = String(format: "%.0f", Self.floorStallSeconds)
            Self.trace("gemini-live: noise floor re-seeded \(reseeds)x — \(stall) s passed "
                + "with every single buffer above the speech threshold, which is not "
                + "credible as speech. See `floorStallSeconds`; that constant is provisional "
                + "and these lines are what it should be re-litigated from.")
        }
    }

    /// Runs on `queue`. Declare a turn and start streaming into it.
    private func openTurn(generation: Int, speech: UInt64) {
        turnID &+= 1
        turnState = .open
        turnText = ""
        turnStartSample = sentSamples
        turnSpeechStart = speech
        turnClosedAt = nil
        send(Self.activityStartMessage,
             generation: generation,
             socketID: socketID,
             label: "activityStart")
    }

    /// Runs on `queue`. Send `activityEnd` and wait, bounded, for the transcript.
    private func closeTurn(generation: Int, reason: String, forced: Bool) {
        let seconds = Double(sentSamples &- turnStartSample) / Self.outputSampleRate
        turnState = .closing
        turnClosedAt = DispatchTime.now()
        let id = turnID
        send(Self.activityEndMessage,
             generation: generation,
             socketID: socketID,
             label: "activityEnd")

        let length = String(format: "%.1f", seconds)
        if forced {
            let head = "gemini-live: turn \(id) forced close at \(length) s "
            Self.trace(head + "(no pause found — this boundary can clip a word)")
        } else {
            Self.trace("gemini-live: turn \(id) closed on \(reason) after \(length) s")
        }

        // The net. A turn that waits forever wedges the engine with the microphone hot.
        queue.asyncAfter(deadline: .now() + Self.turnCompletionTimeoutSeconds) { [weak self] in
            guard let self, self.isLive(generation) else { return }
            guard self.turnID == id, self.turnState == .closing else { return }
            let waited = String(format: "%.1f", Self.turnCompletionTimeoutSeconds)
            Self.trace("gemini-live: turn \(id) got no end signal within \(waited) s")
            self.finishTurn(generation: generation, reason: "timeout")
        }
    }

    /// Runs on `queue`. Deliver the turn and return to `.idle`.
    ///
    /// ── THE ORDERING main.swift DEPENDS ON ────────────────────────────────────────────
    /// `onFinal` STRICTLY BEFORE `.listening`, never the other way round. The consumer types
    /// a final via `deliver(isFinal: true)` and resets its typed high-water mark on
    /// `.listening`; reversed, every turn's text would be reset away the instant before it
    /// was typed. Both go through the same FIFO event box, so this order is the order the
    /// consumer sees. This is `LiveRecognizer`'s contract, satisfied here by construction
    /// because a turn produces exactly one final and exactly one boundary.
    private func finishTurn(generation: Int, reason: String) {
        guard turnState != .idle else { return }
        let text = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
        let latency = turnClosedAt.map {
            Double(DispatchTime.now().uptimeNanoseconds &- $0.uptimeNanoseconds) / 1_000_000
        }
        let id = turnID
        turnState = .idle
        turnText = ""
        turnClosedAt = nil

        // Counts and latency only — never the transcript. The `chars` figure is grapheme
        // clusters, which for Thai is a long way from a byte or UTF-16 count; it answers
        // "did this turn produce text", never "how much audio".
        let latencyNote = latency.map { String(format: "%.0f", $0) + " ms" } ?? "n/a"
        Self.trace("gemini-live: turn \(id) \(reason) — \(text.count) chars in \(latencyNote)")

        if !text.isEmpty { emitFinal(text) }

        if isStopping {
            // The stop flush was waiting for exactly this. No `.listening` — the session is
            // over, and `finishStop` emits `.idle` instead.
            finishStop(generation: generation, reason: "flushed final delivered")
            return
        }
        emitState(.listening)
    }

    // MARK: - Sending audio

    /// What one critical section can tell the queue side about the ring.
    private struct RingSnapshot {
        let total: UInt64
        let speech: UInt64
        let trailing: Int
        /// Unsent samples, already adjusted for anything the ring evicted.
        let pending: UInt64
        /// Samples the eviction skip just gave up on, for `reportDropped`.
        let dropped: UInt64
    }

    /// Runs on `queue`. Read the counters and skip the read cursor past anything the ring
    /// overwrote, in ONE critical section so the returned values agree with each other.
    private func snapshotSkippingEvicted() -> RingSnapshot {
        let capacity = UInt64(ringCapacity)
        lock.lock()
        let total = totalSamples
        let oldest = total > capacity ? total - capacity : 0
        var dropped: UInt64 = 0
        if sentSamples < oldest {
            dropped = oldest - sentSamples
            sentSamples = oldest
        }
        let snapshot = RingSnapshot(total: total,
                                    speech: speechSamples,
                                    trailing: trailingSilence,
                                    pending: total - sentSamples,
                                    dropped: dropped)
        lock.unlock()
        return snapshot
    }

    /// Runs on `queue`. The two VAD counters, nothing else.
    private func readCounters() -> (speech: UInt64, trailing: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (speechSamples, trailingSilence)
    }

    /// Runs on `queue`. Say out loud that the drain fell behind — a silent skip reads
    /// downstream as a turn that simply had less to say. Traces (file I/O), so it is
    /// deliberately outside every critical section.
    private func reportDropped(_ lost: UInt64) {
        guard lost > 0 else { return }
        droppedSamples &+= lost
        let seconds = String(format: "%.1f", Double(lost) / Self.outputSampleRate)
        let capSeconds = String(format: "%.0f", Self.ringSeconds)
        Self.trace("gemini-live: drain fell \(seconds) s behind the \(capSeconds) s ring; "
            + "that audio was never sent")
    }

    /// Runs on `queue`. Copy up to one send's worth of pending audio out of the ring and put
    /// it on the wire. Returns how much audio is still unsent afterwards.
    ///
    /// ── ONE CRITICAL SECTION, DELIBERATELY WIDER THAN THE MEMCPY ─────────────────────
    /// The eviction check, the window arithmetic and the copy all happen under the SAME lock
    /// take. Splitting them — deriving `start` and `n` from a snapshot and copying after —
    /// is a torn read, and a subtle one: between the two, `append` can advance `ringWrite`
    /// past the window's start and overwrite samples this is about to read, splicing fresh
    /// audio into the middle of stale audio. That is not noise in a script without word
    /// boundaries, it is a corrupted syllable inside an otherwise clean transcript, i.e.
    /// exactly the kind of damage this engine's whole turn policy exists to avoid.
    /// `AudioPipeline.takeChunk` takes the same shape for the same reason: decide and copy
    /// together, encode after the unlock.
    ///
    /// `sentSamples` is queue-only state (this serial queue is its only writer), but it is
    /// read and advanced INSIDE the lock here so it can never describe a window the ring no
    /// longer holds.
    @discardableResult
    private func sendPending(generation: Int) -> UInt64 {
        let capacity = ringCapacity
        var dropped: UInt64 = 0
        var n = 0
        var remaining: UInt64 = 0

        lock.lock()
        let total = totalSamples
        let oldest = total > UInt64(capacity) ? total - UInt64(capacity) : 0
        if sentSamples < oldest {
            dropped = oldest - sentSamples
            sentSamples = oldest
        }
        n = Int(min(total - sentSamples, UInt64(maxSendSamples)))
        if n > 0 {
            let start = Int(sentSamples % UInt64(capacity))
            let first = min(n, capacity - start)
            outbound[0 ..< first] = ring[start ..< (start + first)]
            if first < n {
                outbound[first ..< n] = ring[0 ..< (n - first)]
            }
            sentSamples &+= UInt64(n)
        }
        remaining = total - sentSamples
        lock.unlock()

        reportDropped(dropped)
        guard n > 0 else { return remaining }

        // Int16 in memory is little-endian on arm64, which is exactly the `s16le` the
        // `audio/pcm;rate=16000` mime type declares, so this is a straight copy and not a
        // byte-order conversion. Base64 and the send happen after the unlock, so the realtime
        // `append` path never waits on encoding.
        let bytes = outbound.withUnsafeBytes { raw -> Data in
            Data(UnsafeRawBufferPointer(rebasing: raw[0 ..< (n * 2)]))
        }
        let payload = bytes.base64EncodedString()
        let frame = Self.audioMessageHead + payload + Self.audioMessageTail
        send(frame, generation: generation, socketID: socketID, label: "audio")
        return remaining
    }

    // MARK: - Converter preparation

    /// Runs on `queue`, from the drain tick. Builds the converter the first time a tap format
    /// has been captured. Idempotent, and gives up permanently after one failure rather than
    /// retrying ten times a second forever.
    private func prepareConverterIfNeeded() {
        lock.lock()
        let format = capturedTapFormat
        let alreadyBuilt = (converter != nil)
        let failed = converterFailed
        lock.unlock()

        guard let format, !alreadyBuilt, !failed else { return }
        guard let outputFormat else {
            lock.lock(); converterFailed = true; lock.unlock()
            let error = RecognizerError.converterUnavailable("cannot describe 16 kHz mono Float32")
            emitState(.unavailable(String(describing: error)))
            return
        }

        do {
            let built = try Converter(inputFormat: format, outputFormat: outputFormat)
            lock.lock()
            if converter == nil { converter = built }
            lock.unlock()
            let rate = Int(format.sampleRate)
            Self.trace("gemini-live: converter ready — \(rate) Hz ×\(format.channelCount) → 16 kHz mono")
        } catch {
            lock.lock(); converterFailed = true; lock.unlock()
            // Fatal to this capture and deliberately not silent: without a converter no audio
            // can ever be sent, and a trace of "0 turns" would otherwise read like a quiet room.
            Self.trace("gemini-live: converter UNAVAILABLE — \(String(describing: error))")
            emitState(.unavailable("cannot convert microphone audio: \(String(describing: error))"))
        }
    }

    // MARK: - Stop flush

    /// Runs on `queue`. Close whatever turn is open so its transcript can still land, then
    /// hand over to `finishStop` — either when the final arrives, or when the net fires.
    private func beginStopFlush(generation: Int) {
        guard isLive(generation) else { return }
        isStopping = true

        // `.closing` waits, it does not get discarded. A turn closed by silence one tick
        // before the user tapped off is 0.30 s away from its transcript, and the early return
        // below would throw away the last thing they said for the sake of tidiness. Only a
        // genuinely idle engine — or one with no usable socket — has nothing to wait for.
        guard socket != nil, isReady, turnState != .idle else {
            finishStop(generation: generation, reason: "nothing to flush")
            return
        }

        if turnState == .open {
            // The tail the user just spoke is still unsent; send it before declaring the end,
            // or the flush finalises audio the server never heard.
            sendPending(generation: generation)
            closeTurn(generation: generation, reason: "stop", forced: false)
        }

        queue.asyncAfter(deadline: .now() + Self.finalFlushTimeoutSeconds) { [weak self] in
            guard let self, self.isLive(generation) else { return }
            let waited = String(format: "%.1f", Self.finalFlushTimeoutSeconds)
            self.finishStop(generation: generation,
                            reason: "flushed final never arrived within \(waited) s")
        }
    }

    /// Runs on `queue`. Idempotent teardown: drop the socket, retire the generation (which
    /// ends the drain loop and disarms every scheduled block), and report `.idle`.
    private func finishStop(generation: Int, reason: String) {
        guard isLive(generation), !stopFinished else { return }
        stopFinished = true

        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketID &+= 1
        isReady = false
        isStopping = false
        turnState = .idle
        turnText = ""

        let dropped = Double(droppedSamples) / Self.outputSampleRate
        let droppedNote = String(format: "%.1f", dropped)
        Self.trace("gemini-live: capture ended (\(reason)); "
            + "\(droppedNote) s never sent, \(orphanFragments) orphan fragments")

        lock.lock()
        self.generation &+= 1
        lock.unlock()

        emitState(.idle)
    }

    // MARK: - Liveness

    /// True while the generation a block was scheduled under is still the live one. Every
    /// block on `queue` starts with this; it is what makes `stop()` immediately followed by
    /// `start()` safe, and it is the reason none of the queue-only state needs a lock.
    private func isLive(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }

    // MARK: - Callback dispatch

    // Each of these reads the closure under the lock and invokes it OUTSIDE the lock. Calling
    // consumer code while holding a lock is how you get a deadlock the first time a consumer
    // calls back into `setContextualStrings` from `onFinal`. Copied idiom, deliberately
    // identical to `LiveRecognizer`'s.

    private func emitFinal(_ text: String) {
        lock.lock(); let callback = _onFinal; lock.unlock()
        callback?(text)
    }

    private func emitState(_ state: State) {
        lock.lock(); let callback = _onState; lock.unlock()
        callback?(state)
    }

    // MARK: - Redaction and tracing

    /// The last line of defence for the key, not the first. The first is that the URL is
    /// never handed to anything that formats it — `describeError` deliberately uses
    /// `NSError.localizedDescription` rather than `String(describing:)`, because a `URLError`
    /// carries `failingURL` in its userInfo and `String(describing:)` will print it. This
    /// runs over every reason that reaches `onState` or the trace, so a vendor string that
    /// echoes the query back still cannot leak the secret.
    private func redact(_ text: String) -> String {
        guard let apiKey, !apiKey.isEmpty else { return text }
        return text.replacingOccurrences(of: apiKey, with: "<key redacted>")
    }

    /// One-line identity of a networking error. Domain and code first, because the
    /// interesting distinctions live there: a `NSURLErrorDomain -1009` (offline) and a
    /// `-1200` (TLS) read identically in prose and demand different responses. Contains no
    /// transcript text and — see `redact(_:)` — no URL.
    private static func describeError(_ error: any Error) -> String {
        let ns = error as NSError
        return "[domain=\(ns.domain) code=\(ns.code)] \(ns.localizedDescription)"
    }

    /// Append one line to the same /tmp/mictest_trace.txt the rest of the app traces into, in
    /// the same format. Deliberately duplicated rather than calling main.swift's helper, so
    /// this file keeps type-checking standalone and stays decoupled from files edited
    /// independently. Rules inherited verbatim from `LiveRecognizer.trace`:
    ///
    ///   * NEVER call this from `append(_:)` — it does synchronous file I/O on the realtime
    ///     render thread, and it allocates.
    ///   * NEVER pass transcript text, the endpoint URL, or the key. Counts, latencies, turn
    ///     reasons and error domain/code pairs only. Every call site here obeys that, and the
    ///     one place a reason could carry vendor prose runs through `redact(_:)` first.
    ///
    /// Current call sites are lifecycle events — connect, setup, one line per turn, one per
    /// disconnect — a handful of lines per minute of dictation, all on `queue`.
    private static func trace(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        // O_APPEND is load-bearing and is not a simplification target: this file has multiple
        // concurrent writers (this queue, Speech's callback thread in `LiveRecognizer`, the
        // main actor in main.swift) with no shared state between them. `seekToEndOfFile()`
        // followed by `write()` is two syscalls, and two writers that both resolve
        // end-of-file to offset N both write AT N — one line silently overwriting the other,
        // most likely during an error storm, which is exactly when the trace matters most.
        // O_APPEND makes seek-to-end-and-write one atomic operation for a regular file.
        let fd = open("/tmp/mictest_trace.txt", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.write(data)
    }
}
