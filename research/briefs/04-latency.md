# Latency Budget for a Push-to-Talk Voice Dictation App

**Research brief — compiled 2026-08-24.**
Goal: engineer for "world's fastest" *perceived* speed. User holds a hotkey, speaks, releases, expects text instantly.

**Sourcing rules applied:** every number carries a source URL. Provider pricing/latency comes from the provider's own docs. Anything not sourced to a primary page is prefixed `UNVERIFIED:`. Figures older than 2025 are flagged.

---

## 0. Executive summary — the four findings that matter

1. **Push-to-talk deletes the single largest latency term in voice UIs.** Conversational voice agents spend 500–800 ms *after* the user stops talking just waiting for a silence timeout to decide speech ended. PTT replaces that speculative wait with a deterministic event (key release). This is worth more than every other optimization combined. (§2)

2. **The perception literature does not say "text in 100 ms."** It says *something* must respond in ~100 ms. Split the budget into two clocks: an **acknowledgment clock** (≤100 ms, hotkey → visible capture indicator) and a **completion clock** (key release → text landed). Only the first is governed by Nielsen/RAIL. (§6)

3. **Stream during the hold, force-finalize on release.** If audio is already in the provider's buffer when the key comes up, the only remaining cost is the finalize turnaround, not a full upload+inference of the whole utterance. (§3)

4. **The LLM cleanup pass is the second-biggest term and the easiest to hide.** It is the only stage where you can choose to pay nothing (skip short utterances), pay it invisibly (inject raw, then patch), or pay it fully (block). Shipping apps differ here. (§4)

---

## 6. Perception: what "instant" actually means

*(Section ordered first among completed sections because it defines the target the rest of the budget is allocated against.)*

### 6.1 The canonical thresholds

| Threshold | Value | What it actually governs | Source |
|---|---|---|---|
| Nielsen limit 1 | **0.1 s (100 ms)** | "the limit for having the user feel that the system is reacting instantaneously" | [NN/g, *Response Times: The 3 Important Limits*](https://www.nngroup.com/articles/response-times-3-important-limits/) — Jakob Nielsen, first published 1993, excerpt from ch. 5 of *Usability Engineering* |
| Nielsen limit 2 | **1.0 s** | "the limit for the user's flow of thought to stay uninterrupted, even though the user will notice the delay" | same |
| Nielsen limit 3 | **10 s** | "the limit for keeping the user's attention focused on the dialogue" | same |
| Doherty threshold | **400 ms** | "Productivity soars when a computer and its users interact at a pace (<400ms) that ensures that neither has to wait on the other." Replaced the prior 2,000 ms industry standard. | [Laws of UX — Doherty Threshold](https://lawsofux.com/doherty-threshold/). Original: Walter J. Doherty (IBM T.J. Watson Research) & Ahrvind J. Thadani (IBM General Products Division), *The Economic Value of Rapid Response Time*, **November 1982** — catalogued at [Computer History Museum 102751398](https://www.computerhistory.org/collections/catalog/102751398); full text mirrored at [jlelliotton.blogspot.com](https://jlelliotton.blogspot.com/p/the-economic-value-of-rapid-response.html). `UNVERIFIED:` venue is cited inconsistently as *IBM Systems Journal* vs an IBM technical report (GE20-0752-0) |
| Google RAIL — Response | **100 ms** to complete a transition initiated by user input; input processing within **50 ms** | Input acknowledgment | [web.dev — RAIL model](https://web.dev/articles/rail), last updated 2020-06-10 |
| Google RAIL — Animation | **16 ms** frame budget (1000/60), practical target **≤10 ms** (browser needs ~6 ms to render) | Frame pacing for the capture indicator | same |
| RAIL — Idle | work in **≤50 ms** chunks | Don't let background work delay input | same |

**Age caveat:** Nielsen's limits are 1993 (restating Robert B. Miller, 1968); Doherty is 1982; RAIL was last updated 2020. They are conventions, not fresh 2026 measurements. Treat them as design heuristics.

### 6.2 The tension: 100 ms is not actually the perceptual floor

Dan Luu's measurement project explicitly **rejects** Nielsen's framing. Measuring real keypress-to-screen latency across machines, he reports that "people can perceive latencies down to 2 ms or less" and dismisses the claim that sub-100 ms feels instantaneous ([danluu.com/input-lag](https://danluu.com/input-lag/)).

His measured figures are a useful calibration for what users are already used to:

| Machine | Keypress-to-screen | Source |
|---|---|---|
| Apple 2e (1983) | **30 ms** | [danluu.com/input-lag](https://danluu.com/input-lag/) |
| iPad Pro 10.5" + Pencil | **30 ms** | same |
| Custom Haswell-E @165 Hz | **50 ms** | same |
| Kindle 4 (browser scroll) | **860 ms** | same |

Luu's conclusion: a modern gaming machine "running at 4,000x the speed of an apple 2" struggles to match 1983 latency. **Implication for us:** the physical typing that dictation replaces has ~30–50 ms feedback. You will never match that on the completion clock — which is exactly why the acknowledgment clock must be fast and the completion must be *predictable*.

### 6.3 The conversational benchmark

Human turn-taking gaps cluster tightly: across a sample of 10 languages, transition distributions are unimodal with "the highest number of transitions occurring between **0 and 200 ms**," with cross-cultural variation within a ~250 ms range of the mean.
Source: Stivers, Enfield, Brown et al., *Universals and cultural variation in turn-taking in conversation*, PNAS 2009 — [pnas.org/doi/10.1073/pnas.0903616106](https://www.pnas.org/doi/10.1073/pnas.0903616106) | [PubMed 19553212](https://pubmed.ncbi.nlm.nih.gov/19553212/).

This is the number quoted as the "feels conversational" target in voice-agent design. **Caveat: it is the wrong benchmark for dictation.** 200 ms is the gap before a *spoken reply* in a live conversation. Dictation is a transaction the user is watching complete, not a conversational turn — the applicable limits are Doherty (400 ms) and Nielsen limit 2 (1 s), not 200 ms.

### 6.4 The two-clock model (the framing recommendation)

The three canonical numbers are **not measured on the same clock**. Stacking them produces a wrong budget.

| Clock | Starts | Ends | Governing research | Target |
|---|---|---|---|---|
| **Acknowledgment** | Hotkey keydown | Visible indicator that capture is live | Nielsen 0.1 s; RAIL 100 ms / 50 ms input | **≤100 ms**, ideally ≤50 ms |
| **Completion** | Key **release** | Text present in the target app | Doherty 400 ms; Nielsen 1.0 s | **≤500 ms** stretch, ≤700 ms competitive, ≤1000 ms acceptable |

The perceptual literature does **not** require text within 100 ms. It requires *acknowledgment* within 100 ms. The acknowledgment clock is cheap to win and is where most of the "feels instant" impression is actually created; the completion clock is where the engineering money goes.

**Sanity check against a shipping product:** Wispr Flow's published target is 700 ms end-to-end from when the user stops speaking (§7) — already 1.75× outside Doherty. So a brief that declares "400 ms end-to-end" as the target would be proposing something no shipping product currently achieves with an LLM pass. 500 ms is the honest stretch goal; sub-400 ms is achievable only by dropping the LLM pass from the critical path.

---

## 5. Text injection cost (macOS, with Windows notes)

### 5.1 The clipboard-paste round trip and its mandatory delays

The dominant approach: write text to `NSPasteboard`, synthesize Cmd+V via `CGEvent`, optionally restore the previous clipboard. There is a **documented race condition**: if you post Cmd+V before the pasteboard write has propagated, the target app pastes stale content.

Two independent, mature implementations converged on nearly identical delay constants:

**Espanso** (cross-platform text expander, Rust):

| Option | Default | Purpose | Source |
|---|---|---|---|
| `pre_paste_delay` | **100 ms** (source constant) / **300 ms** (docs table) — *discrepancy, see note* | Wait after clipboard write before triggering paste. Docs: "if we trigger a 'paste' shortcut before the content is actually copied in the clipboard, the operation will fail." | Constant `DEFAULT_PRE_PASTE_DELAY: usize = 100` in [`espanso-config/src/config/default.rs`](https://github.com/espanso/espanso/blob/dev/espanso-config/src/config/default.rs) (dev branch, read 2026-08-24); docs table states `300` at [espanso.org/docs/configuration/options](https://espanso.org/docs/configuration/options/) |
| `paste_shortcut_event_delay` | **10 ms** | Gap between individual key events in the synthesized shortcut. Docs: "CTRL + (wait 5ms) + V + … needed as sometimes (for example on macOS), without a delay some keystrokes were not registered correctly." | `DEFAULT_SHORTCUT_EVENT_DELAY: usize = 10`, same file |
| `restore_clipboard_delay` | **300 ms** | Wait before restoring prior clipboard: "without this delay, sometimes the target application detects the previous clipboard content instead of the expansion content." | `DEFAULT_RESTORE_CLIPBOARD_DELAY: usize = 300`, same file; docs agree at 300 |
| `key_delay` / `inject_delay` | platform-dependent | Per-keystroke delay for direct injection backend | [options docs](https://espanso.org/docs/configuration/options/) |

> **Discrepancy, reported as such:** the docs table lists `pre_paste_delay` default = 300 ms; the `default.rs` constant on the dev branch is 100 ms. Both are cited above. Do not treat either as settled — measure on your target macOS version. Either way the *order of magnitude* (100–300 ms) is the finding.

**VoiceInk** (open-source macOS dictation app, Swift) — [github.com/Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk), file `VoiceInk/Paste/CursorPaster.swift`:

```swift
private static let prePasteDelay: TimeInterval = 0.10             // 100 ms
private static let pasteShortcutEventDelay: TimeInterval = 0.01   //  10 ms
private static let minimumClipboardRestoreDelay: TimeInterval = 0.25  // 250 ms
```

Its paste sequence posts four `CGEvent`s (Cmd down, V down, V up, Cmd up) to `.cghidEventTap` with a 10 ms wait between each:

```
setClipboard → wait 100 ms → cmdDown → 10 ms → vDown → 10 ms → vUp → 10 ms → cmdUp
```

**Critical-path injection cost ≈ 100 + 3×10 = 130 ms**, plus the target application's own paste handling (not measurable generically).

**Design note worth copying:** VoiceInk schedules the clipboard *restore* asynchronously via `scheduleClipboardRestore(...)` — the 250 ms restore delay is **off the critical path**. It also guards the restore with `pasteboardStillOwnedByPasteSession(...)`, checking that the pasteboard still contains its own text and session UUID before overwriting, so a user copy during the window isn't clobbered.

> Do **not** count VoiceInk's `DispatchQueue.main.asyncAfter(deadline: .now() + 0.15)` (150 ms) into the injection budget — that appears in `LastTranscriptionService.swift`, on the *paste-last-transcription* command path (allowing focus to return after a UI action), not the main dictation path.

### 5.2 Per-character CGEvent typing

`CGEventKeyboardSetUnicodeString` + `CGEventPost` types characters directly, avoiding the clipboard entirely. Trade-off: throughput and reliability.

- Espanso's `inject_delay` / `key_delay` exist precisely because apps drop characters when events are posted too fast; the docs describe the values as platform- and application-dependent ([options docs](https://espanso.org/docs/configuration/options/)). Espanso's test fixture shows `inject_delay: 10`, `key_delay: 20`, `backspace_delay: 30` as illustrative values.
- At a 10–20 ms per-keystroke delay, a 200-character transcript costs **2–4 seconds** — catastrophically worse than a single paste. Per-character typing is a *fallback* for fields that reject paste, not a primary path.
- VoiceInk-derived forks document exactly this: type-out mode "character-by-character typing via CGEvent for fields that block clipboard paste (password fields, some web forms)" — [github.com/bigloudjeff/VoiceInk-tweaks](https://github.com/bigloudjeff/VoiceInk-tweaks).

**Rule: paste for anything over ~a dozen characters; reserve synthetic typing for paste-hostile targets.**

### 5.3 Alternative injection paths

| Method | Latency | Reliability | Notes |
|---|---|---|---|
| Clipboard + Cmd+V (`CGEvent`) | ~130 ms critical path | Good; needs Accessibility permission (`AXIsProcessTrusted()`) | Primary path. VoiceInk uses `CGEventSource(stateID: .privateState)` and posts to `.cghidEventTap` |
| AppleScript `System Events` keystroke | Slower (script compile + IPC) | Fallback | VoiceInk pre-compiles both scripts at load (`makeScript`) to avoid per-use compile cost. Uses `key code 9` instead of `keystroke "v"` on "⌘-QWERTY" layouts, which remap under Command |
| Accessibility API (`AXUIElement` `AXSelectedText`) | Fastest — no clipboard, no synthetic events | Inconsistent | Works in native AppKit fields; unreliable in Electron/Chrome/terminals. Three-tier fallback (AX → CGEvent Cmd+V → AppleScript) is the documented pattern in this app family |
| Windows: `SendInput` / clipboard paste | — | — | `UNVERIFIED:` no first-party measurement obtained |

**Apple docs:** [`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard) — all AppKit objects including `NSPasteboard` should be accessed from the main thread; VoiceInk's implementation is `@MainActor`-annotated throughout, consistent with this.

**Also note (App Store constraint):** synthesizing input via `CGEvent.post` has drawn App Store review rejections under Guideline 2.4.5 — see [Apple Developer Forums thread 820594](https://developer.apple.com/forums/thread/820594). Relevant if you intend to ship on the Mac App Store rather than direct-download/notarized.

### 5.4 Injection budget verdict

**Allocate 130–150 ms.** It is not free and it is not compressible below ~110 ms with the clipboard approach, because the pre-paste settle is a correctness requirement, not a safety margin. The only way materially below this is the AX path, which you cannot rely on universally — so implement AX-first with CGEvent fallback and you'll get ~20 ms in native apps and ~130 ms elsewhere.

---

## 7. Third-party measured comparisons — honest verdict

**Finding: no credible independent stopwatch comparison of dictation-app latency exists.** This is itself the result, not a gap in the search. What exists falls into two categories, and every number below is labeled by who produced it.

### 7.1 Vendor / founder self-reports (first-party, not independent)

| App | Claim | Who said it | Source |
|---|---|---|---|
| **Aqua Voice** | "starts up in under **50ms**, inserts text in about a second (sometimes as fast as **450ms**), and has state-of-the-art accuracy" | Founder, Show HN post | [HN 43634005](https://news.ycombinator.com/item?id=43634005) |
| **Aqua Voice vs Wispr Flow** | "Aqua can go from key-up to paste in as little as **450ms**. Flow was closer to **1000** in our tests." | `the_king` (Aqua founder) — **competitor measuring a competitor** | [HN 43634005](https://news.ycombinator.com/item?id=43634005) |
| **Aqua Voice** | Architecture: "inference runs in a datacenter (for now)"; LLM stage routed to OpenRouter; offline rejected because "we can't run asr and an llm locally at the speed that is required" | Aqua founders | same thread |
| **Wispr Flow** | Target: "full transcription and LLM formatting/interpretation of their speech within **700ms** of when they stop speaking" | Wispr Flow engineering blog | [wisprflow.ai/post/technical-challenges](https://wisprflow.ai/post/technical-challenges) |
| **Wispr Flow** | "Clean transcripts in under **700 milliseconds**, every time" measured as **p99** end-to-end; "We measure latency on a p90 or p99 basis for each user; we don't care at all about p50" | Baseten case study (infra vendor, with Wispr) | [baseten.co/resources/customers/wispr-flow](https://www.baseten.co/resources/customers/wispr-flow/) |
| **MacWhisper / WhisperKit tiny.en** | "Tiny whisperkit model (english only) is way faster than any cloud service on my M1 macbook pro" | HN commenter `jrvarela56` — anecdotal, no instrumentation | [HN 43634005](https://news.ycombinator.com/item?id=43634005) |

### 7.2 Competitor-authored SEO content — treat as marketing, not measurement

A large volume of "Wispr Flow vs Superwhisper 2026" comparison articles rank for these queries. **Every one found is published by a company selling a competing dictation product**, with no described methodology, no instrumentation, and no raw data:

- willowvoice.com (sells Willow) — [Super Whisper vs Wispr Flow](https://willowvoice.com/blog/super-whisper-vs-wispr-flow-comparison-reviews-and-alternatives)
- lumevoice.com (sells LumeVoice) — [multiple](https://lumevoice.com/blog/wispr-flow-vs-superwhisper-vs-lumevoice/) [comparison](https://lumevoice.com/blog/superwhisper-vs-wispr-flow-comparison-2026/) [posts](https://lumevoice.com/blog/top-9-wispr-flow-alternatives/)
- getvoibe.com (sells Voibe) — [Wispr Flow vs Superwhisper](https://www.getvoibe.com/resources/wispr-flow-vs-superwhisper/)
- blazingfasttranscription.com — [Superwhisper vs Wispr Flow](https://www.blazingfasttranscription.com/blog/superwhisper-vs-wispr-flow)
- spokenly.app (sells Spokenly) — [Aqua Voice Review](https://spokenly.app/blog/aqua-voice-review), [Wispr Flow Review](https://spokenly.app/blog/wispr-flow-review)

Typical figures circulated by this content (**`UNVERIFIED:` — no methodology, competitor-authored**): Wispr Flow ≈ 700 ms–2 s depending on connection; Superwhisper ≈ 1–2 s depending on selected Whisper model.

### 7.3 What the absence of data implies

- Wispr Flow's p99 discipline is the most credible published methodology in the space ("we don't care at all about p50"). **Adopt it.** Median latency is a vanity metric for dictation; the user remembers the slow one.
- Wispr Flow maintains a public status page with logged **"Slow Performance / Latency"** incidents ([statuspage.incident.io/wispr-flow](https://statuspage.incident.io/wispr-flow/incidents/t1189cxn)) — direct evidence that a cloud-dependent architecture's tail latency is an ongoing operational liability, not a solved problem.
- **Opportunity:** publishing a reproducible, instrumented benchmark harness (key-up timestamp → text-present-in-target timestamp, p50/p90/p99 across apps) would be a genuine competitive differentiator, because nobody has done it.

---

## Sections pending

§1 (audio capture start), §2 (VAD/endpointing), §3 (STT inference), §4 (LLM cleanup) — awaiting research streams. Partial primary-source evidence already gathered from the VoiceInk source tree is recorded below and will be merged.

### Primary-source evidence already extracted (VoiceInk, read 2026-08-24)

Repo: [github.com/Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) — open-source macOS dictation app.

**§1 — mic warm-up:** `VoiceInk/CoreAudioRecorder.swift` is an **AUHAL-based Core Audio recorder**, not AVAudioEngine (file comment: "Core Audio Recorder (AUHAL-based, does not change system default device)"). It **separates** the expensive `AudioUnitInitialize(unit)` (`initializeAudioUnit()`) from the cheap `AudioOutputUnitStart(unit)` (`startAudioUnit()`), and gates re-preparation on:
```swift
private func isPrepared(for deviceID: AudioDeviceID) -> Bool {
    audioUnit != nil && isAudioUnitInitialized && currentDeviceID == deviceID && isDeviceAvailable(deviceID)
}
```
This is direct shipping evidence for moving device negotiation off the hotkey path. Also uses a pre-allocated render buffer "to avoid malloc in real-time callback", `maxFramesPerRender = 4096`, and a 96-slot lock-free input ring (`inputRingSlotCount = 96`) with atomic read/write indices.

**§3/§4 — model prewarm:** `ModelPrewarmService.swift` runs a dummy transcription of a bundled `sound7.wav` on app launch and on `NSWorkspace.didWakeNotification` (wake from sleep), default `"PrewarmModelOnWake": true`. Cold-start cost is paid before the user ever presses the key.

**§3 — finalize-on-release:** `StreamingTranscriptionService.stopAndFinalize()` implements exactly the stream-then-force-finalize pattern: `drainRemainingChunks()` → arm commit signal → `provider.commit()` → `waitForFinalCommit()` (10 s *safety ceiling*, not expected latency) → return joined committed segments. It logs `"Streaming stop completed elapsed=…s"`, i.e. the tail latency is explicitly instrumented.

**§3 — streaming providers implemented:** AssemblyAI, Cartesia, Deepgram, ElevenLabs, Mistral, Soniox, Speechmatics, xAI, plus local **FluidAudio** (`FluidAudioStreamingProvider`, `FluidAudioNemotronStreamingProvider`, `FluidAudioUnifiedStreamingProvider`).

**§3 — hypothesis stabilization:** `WordAgreementEngine.swift` implements LocalAgreement-style confirmation over a local streaming model:
```swift
var transcribeIntervalSeconds: Double = 1.0
var tokenConfirmationsNeeded: Int = 3
var minWordsToConfirm: Int = 5
var minPassConfidence: Float = 0.15
var minWordConfidence: Float = 0.6
```
Re-transcribes every 1.0 s; a word is *confirmed* once it agrees across 3 consecutive passes; unconfirmed words are shown as hypothesis. Confirmed audio is trimmed via `hypothesisStartTime`. Consequence: by the time the key is released most words are already confirmed, so only the tail requires final work.

**§4 — skip-cleanup-when-short (technique c), shipping with a default:** `TranscriptionPipeline.swift`
```swift
let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
```
LLM enhancement is skipped when `WordCounter.count(in: text) <= 3` words.

**§4 — but it blocks on the LLM.** The pipeline's own doc comment is:
```
transcribe → filter → format → word-replace → AI enhance → deliver → save
```
`AI enhance` precedes `deliver`. VoiceInk does **not** implement inject-raw-then-diff-patch; it pays the full LLM latency and mitigates only by skipping short utterances.

**§4 — custom vocabulary is handled at the ASR layer, not the LLM:** `DeepgramStreamingProvider.connect()` passes `customVocabulary: vocabulary` into the streaming connect call, so dictionary terms cost zero extra latency.

---

## 3A. Speech-to-text — cloud streaming providers

### 3A.0 Model names in the brief were stale — verified against current docs

| Assumed | Actually current (Aug 2026) |
|---|---|
| Deepgram Nova-3 / Nova-4 | **Nova-3 is still current; there is no Nova-4.** New sibling **Flux**, positioned for voice agents only |
| AssemblyAI Universal-Streaming | **Universal-3.5 Pro**; "Universal-Streaming" is now the cheap legacy tier |
| Speechmatics Ursa | **Melia 1** — "Ursa" appears nowhere in current docs |
| OpenAI gpt-4o-transcribe | Still sold, but **`gpt-transcribe`** is the recommended model; **`gpt-live-transcribe`** is the realtime one |
| Groq distil-whisper | **No longer listed** — only whisper-large-v3 / -turbo |
| ElevenLabs Scribe v1 | **`scribe_v2` + `scribe_v2_realtime`** (Scribe v2 Realtime GA 2025-11-11) |
| Mistral Voxtral (batch only?) | **`voxtral-mini-transcribe-realtime-2602` exists and streams** |

### 3A.1 Comparison

**Latency figures are not comparable across rows** — each provider measures a different thing. The definition is stated in each cell.

| Provider | Model | Stream | Batch | Latency + **what it measures** | WER / accuracy | Price/hr |
|---|---|---|---|---|---|---|
| **Deepgram** | `nova-3`; `flux-general-en` | Yes (WS) | Yes | **"300 ms or less"** transcript latency; breakdown transcription 150–300 ms, total 200–500 ms; Flux EOT 100–500 ms — [docs](https://developers.deepgram.com/docs/measuring-streaming-latency) | Streaming median **6.84%** (54.2% better than next-best 14.92%); batch **5.26%** — [Nova-3 launch](https://deepgram.com/learn/introducing-nova-3-speech-to-text-api) | Stream **$0.462** (promo $0.288); batch **$0.258** — [pricing](https://deepgram.com/pricing) |
| **AssemblyAI** | Universal-3.5 Pro | Yes (WS) | Yes | **282 ms TTFS median / 354 ms P95** — *time from speaker stopping to final transcript* — [benchmarks](https://www.assemblyai.com/blog/universal-3-5-pro-independent-stt-benchmarks). Also ~150 ms P50 / ~240 ms P90 *after VAD endpoint* for U-3 Pro — [blog](https://www.assemblyai.com/blog/universal-3-pro-streaming) | Coval **3.4%** (led all 31 models); Pipecat semantic WER **1.22%** | Stream **$0.45**; batch **$0.21**; legacy Universal-Streaming **$0.15** — [pricing](https://www.assemblyai.com/pricing) |
| **Speechmatics** | Melia 1 | Yes (WS) | Yes | **`max_delay` default 4 s, floor 0.7 s** — *configured delay between end of word and final result* — [RT API ref](https://docs.speechmatics.com/rt-api-ref) | `UNVERIFIED:` not published | **$0.129** Pro, billed to the second (currency inferred) — [pricing](https://www.speechmatics.com/pricing) |
| **OpenAI** | `gpt-transcribe`, `gpt-live-transcribe` | Realtime API only | Yes | **No ms published.** Docs: *"exact delay in milliseconds can vary by model configuration, so benchmark with representative audio"* — [docs](https://developers.openai.com/api/docs/guides/realtime-transcription) | `UNVERIFIED:` STT guide carries no accuracy metrics | `gpt-transcribe` **$0.27**; 4o-mini **$0.18**; 4o **$0.36**; `gpt-live-transcribe` **$1.02** — [pricing](https://developers.openai.com/api/docs/pricing) |
| **Groq** | whisper-large-v3-turbo | **No — batch only** | Yes | **216x** realtime (turbo), 189x (v3) — *throughput, not latency* — [docs](https://console.groq.com/docs/speech-to-text) | turbo **12%**, v3 **10.3%** | turbo **$0.04**; v3 **$0.111** |
| **ElevenLabs** | `scribe_v2`, `scribe_v2_realtime` | Yes (WS) | Yes | **"~150 ms"** — *partial* transcriptions, excludes app + network — [docs](https://elevenlabs.io/docs/capabilities/speech-to-text) | **93.5%** accuracy across 30 languages — [launch](https://elevenlabs.io/blog/introducing-scribe-v2-realtime) | Realtime **$0.39**; batch **$0.22** — [pricing](https://elevenlabs.io/pricing/api?price.section=speech_to_text) |
| **Mistral** | `voxtral-mini-transcribe-realtime-2602` | Yes (WS) | Yes | **"sub-200 ms"**, tunable via `target_streaming_delay_ms` — *steady-state delay, not a flush* — [docs](https://docs.mistral.ai/capabilities/audio/) | `UNVERIFIED:` | Realtime **$0.36**; batch **$0.18** — [pricing](https://mistral.ai/pricing/api) |

### 3A.2 The metric that actually matters: TTFS

AssemblyAI is the only provider that publishes a metric defined exactly as the push-to-talk tail: **TTFS = "time to final segment" = how long after a speaker stops talking before the final transcript is delivered.** Their published figures — **282 ms median, 354 ms P95** — are therefore the best available public estimate of what "stream during hold, finalize on release" costs.

**This validates the architecture:** with streaming + force-finalize, the post-release ASR cost is ~300 ms, not the 1–3 s that a batch upload of the whole utterance would cost.

### 3A.3 Force-finalize support (the PTT primitive), ranked

Note the pattern: **every provider with a force-finalize mechanism declines to publish its latency.**

1. **Deepgram — best fit.** `{"type":"Finalize"}` is purpose-built: *"forces the server to immediately process any unprocessed audio data and return the final transcription results,"* echoed with `from_finalize: true` ([Finalize docs](https://developers.deepgram.com/docs/finalize)). `CloseStream` also flushes before terminating ([docs](https://developers.deepgram.com/docs/close-stream)). `endpointing` **defaults to 10 ms** ([docs](https://developers.deepgram.com/docs/endpointing)) — barely any silence wait to begin with.
2. **AssemblyAI — right primitive, wrong billing.** `{"type":"ForceEndpoint"}` and `{"type":"Terminate"}` exist ([API ref](https://www.assemblyai.com/docs/api-reference/streaming-api/streaming-api)). **But streaming bills by WebSocket-open time, not audio duration, and idle time counts** ([pricing](https://www.assemblyai.com/pricing)) — for dictation (short bursts, long think-time) you pay $0.45/hr for silence. Defaults without forcing: `max_turn_silence` **1536 ms**, `min_turn_silence` **400 ms**.
3. **ElevenLabs — correct primitive, explicit warning against this access pattern.** `connection.commit()` returns `committed_transcript`, but docs warn *"Committing manually several times in a short sequence can degrade model performance"* and recommend committing every 20–30 s ([commit strategies](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies)). Push-to-talk commits every few seconds — a direct collision. Test before adopting.
4. **OpenAI — two paths, easily confused.** `stream=true` on `/v1/audio/transcriptions` is **not** live streaming: *"File transcription can stream partial text while the model processes a completed recording"* ([docs](https://developers.openai.com/api/docs/guides/speech-to-text)). Only the **Realtime API** does true PTT: set `turn_detection: null`, then `input_audio_buffer.commit` when the turn ends, final on `conversation.item.input_audio_transcription.completed`. Exact semantic match for hold-to-talk — but $1.02/hr, ~4x Deepgram.
5. **Speechmatics — worst default tail.** `EndOfStream` → `EndOfTranscript` flushes, but `max_delay` defaults to **4 s with a 0.7 s floor**, and docs don't state that `EndOfStream` short-circuits it. A 700 ms floor vs Deepgram's 10 ms endpointing is a real structural difference. Cheapest per hour.
6. **Mistral — streams, no documented flush.** `TranscriptionStreamTextDelta` / `TranscriptionStreamDone`, but no commit/force-finalize message documented. `target_streaming_delay_ms` tunes steady state (240 ms fast / 2400 ms accurate), not release-triggered finalization.
7. **Groq — no streaming at all.** STT docs never mention WebSocket/realtime. For PTT the *entire request* is tail latency: on release you upload the whole clip and wait. At 216x realtime a 10 s utterance is ~46 ms of *inference* — **but that is not observed latency**; upload, queueing and cold start are unpublished. 10 s minimum billing punishes short utterances. Unbeatable at **$0.04/hr** if you can absorb the tail.

### 3A.4 Batch-after-release vs stream-during-hold — quantified

| Strategy | Post-release cost | Notes |
|---|---|---|
| **Batch after release** (Groq, or any file API) | upload(whole clip) + queue + inference + download | For a 10 s utterance at 16 kHz mono PCM16 ≈ 320 KB. Inference ~46 ms at 216x, but network upload dominates and is unpublished. Highly variable on poor connections |
| **Stream during hold + force-finalize** (Deepgram/AssemblyAI) | **~280–354 ms** (AssemblyAI TTFS median/P95) | Audio is already server-side; only the tail (last partial chunk) needs processing. **Roughly connection-independent** because bytes were trickled during the hold |

**This is the single most important cloud-architecture decision.** Streaming during the hold converts a variable, bandwidth-dependent upload into a fixed ~300 ms finalize.

### 3A.5 Explicitly unverified
`UNVERIFIED:` Speechmatics WER, and real-time vs batch price separation (only one $0.129/hr Pro rate found; currency inferred). OpenAI WER and any OpenAI ms latency figure. Mistral WER, and any latency beyond "sub-200 ms". Deepgram Flux *absolute* WER (only a relative "nearly identical to Nova-3" claim). **Post-`Finalize` latency (Deepgram), post-`commit()` latency (ElevenLabs), post-`ForceEndpoint` latency (AssemblyAI) — none published by any provider.**

`UNVERIFIED:` AssemblyAI's model string appears as `universal-3-pro`, `u3-rt-pro`, and `universal-3-5-pro` across different first-party pages; canonical form could not be determined. Verify against the live API before coding.

### 3A.6 Recommendation
**Deepgram Nova-3** is the strongest default: a real `Finalize` flush, 10 ms endpointing default, published sub-300 ms streaming latency, best published WER, $0.462/hr (promo $0.288). **Do not use Flux** — Deepgram positions it explicitly for voice agents, *"built for conversation, not transcription."* If cost dominates and an unmeasured tail is tolerable, **Groq turbo at $0.04/hr is ~10x cheaper** than anything else. Watch AssemblyAI's session-duration billing — the pricing detail most likely to surprise in production.

**§4 — on-device cleanup model, kept warm during the hold (VoiceInk, cont.):** VoiceInk ships its own local refine model, `beingpax/VoiceInk-Refine-V1` on Hugging Face (`VoiceInkRefineService.swift:33`), Qwen-derived (the download manifest includes `LICENSE-QWEN-APACHE-2.0.txt`). Manifest totals **1,079,479,368 bytes ≈ 1.01 GB on disk** (`model.safetensors` alone is 1.059 GB; `tokenizer.json` 20 MB).

It runs in a **separate XPC process** (`VoiceInkRefineXPCClient`) with explicit warm-state management:
```swift
private static let warmGracePeriod: Duration = .seconds(10)
func keepPreparedModelWarmForRecording()
```
and is warmed **at recording start** — i.e. during the hold, off the post-release critical path (`VoiceInkEngine.swift:798`):
```swift
// Preserve an already-warm XPC model immediately, while retaining the
// debounce below before any new model preparation begins.
await aiService.voiceInkRefineService.keepPreparedModelWarmForRecording()
try await Task.sleep(for: .milliseconds(450))   // debounce before preparing a new model
```
After 10 s idle the model is unloaded to reclaim RAM. **This is the on-device analogue of prompt caching: pay model load during the hold, pay only inference after release.**

Cloud cleanup providers offered: Cerebras, Groq, Gemini, Anthropic, OpenAI, Mistral, Ollama (`AIService.swift:6-19`) — note Cerebras and Groq listed first, both selected for speed.

**§1 — hotkey detection: PTT forces CGEventTap, which carries a hard constraint.** `VoiceInk/Shortcuts/ShortcutMonitor.swift` uses `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, ...)` and handles `.keyDown`, `.keyUp`, `.flagsChanged`.

This is not a free choice. Carbon `RegisterEventHotKey` — the cheaper, permission-free path — delivers hotkey *activation* only; it does not report key **release**, so it cannot express hold-to-talk. **Push-to-talk therefore requires an event tap**, which in turn requires Accessibility permission ([AeroSpace issue #1012](https://github.com/nikitabobko/AeroSpace/issues/1012) discusses the trade-off; [quicopy.com analysis](https://www.quicopy.com/blog/macos-shortcut-dispatch-zed) covers Carbon's "only fires when the frontmost app doesn't consume the event" limitation).

**The constraint that matters for latency:** an event tap callback runs *synchronously in the system input path*. If it takes too long, macOS disables the tap with `kCGEventTapDisabledByTimeout` and it stays dead without recovery logic ([ghostty discussion #11819](https://github.com/ghostty-org/ghostty/discussions/11819) documents this exact failure after sleep/wake). VoiceInk guards it by re-enabling inside the callback:
```swift
CGEvent.tapEnable(tap: eventTap, enable: true)   // on tapDisabledByTimeout
```
**Design rule: the hotkey callback must decide suppress/pass and return immediately.** Never start audio, load a model, or touch the network inside it — post to another queue. A slow handler doesn't just add latency, it silently kills your hotkey.

`UNVERIFIED:` no published millisecond figure for macOS global-hotkey detection latency was found on any first-party or measured source. Treat it as small (single-digit ms) but unmeasured.

### 3A.7 Connection setup, keep-alive, and the vendor-benchmark conflict

**Connection is on the critical path unless you pre-connect.** In VoiceInk, `StreamingTranscriptionService.startStreaming()` sets `state = .connecting` and *awaits* `provider.connect(...)` before any audio flows — and it times the operation (`"Streaming connected … elapsed=…s"`). For a cloud provider that means TLS + WebSocket upgrade + auth **inside the hold window**. Acceptable only because the user is still speaking; if the utterance is very short, connection setup can still be the tail.

**Technique:** open the socket on hotkey *keydown* (not on first audio), so handshake overlaps the user's first syllable. Better still, keep a socket warm between utterances — but see the timeout constraint below.

**Deepgram idle-timeout constraint (matters for a dictation app):** the streaming WebSocket closes after ~10 s without audio. Docs advise a `KeepAlive` every **3–5 s** during audio gaps (some guidance says every 8 s while idle), and note that *KeepAlive alone will not prevent closure — at least one audio message must have been sent*. Sources: [Audio Keep Alive](https://developers.deepgram.com/docs/audio-keep-alive), [lower-level websockets](https://developers.deepgram.com/docs/lower-level-websockets), [WS/NET/DATA troubleshooting](https://developers.deepgram.com/docs/stt-troubleshooting-websocket-data-and-net-errors).
**Implication:** you cannot hold one socket open across a user's whole session for free. Either send keep-alives (cheap, but Deepgram bills streaming by connection time — check your plan) or reconnect per utterance and eat handshake latency. **This is a genuine architectural fork; measure both.**

**Vendor benchmarks directly contradict each other — trust neither.**

| Source | Claim | Who benefits |
|---|---|---|
| Deepgram docs | Nova-3 "300 ms or less" transcript latency — [docs](https://developers.deepgram.com/docs/measuring-streaming-latency) | Deepgram |
| AssemblyAI blog, citing Pipecat benchmark | AssemblyAI **262 ms mean / 355 ms p95** time-to-transcript vs Deepgram **568 ms mean / 1319 ms p95** — [AssemblyAI vs Deepgram](https://www.assemblyai.com/blog/assemblyai-vs-deepgram-best-voice-agent-api) | AssemblyAI |
| AssemblyAI blog, citing Hamming.ai across 4M+ production calls | AssemblyAI **41% faster** median word-emission latency (307 ms vs 516 ms) | AssemblyAI |

Deepgram's self-reported ≤300 ms and AssemblyAI's measurement of Deepgram at 568 ms mean / 1319 ms p95 cannot both describe the same thing. Most likely they measure different events (transcript-segment latency vs time-to-final-transcript) under different configs. **Do not pick a provider from these numbers.** Run your own p90/p99 harness against both with *your* audio, *your* region, and `Finalize`/`ForceEndpoint` actually enabled.

`UNVERIFIED:` no first-party TLS-handshake or WebSocket-connect latency figure was published by any provider.

---

## 2A. Endpointing — the architectural core of the whole design

### 2A.1 The thesis, stated precisely

The brief asks whether endpointing is the dominant latency term, and whether push-to-talk makes it unnecessary. The precise, defensible formulation:

> **Push-to-talk does not "eliminate endpointing." It replaces a *speculative silence timeout* with a *deterministic explicit finalize event*.** The residual cost is the provider's finalize turnaround (~300 ms for a cloud streaming ASR), not zero.

That distinction matters, because the naive claim ("PTT means zero endpointing latency") is false and collapses under review — while the precise claim is both true and still a very large win.

### 2A.2 Why the silence timeout dominates in conversational voice UIs

A voice assistant cannot know the user has finished. It must *infer* it by waiting for silence. That wait is pure, unavoidable, added latency — and it is charged **after** the user has already stopped talking, which is exactly when the user starts counting.

Published provider defaults (first-party):

| Provider / setting | Default silence wait | Source |
|---|---|---|
| AssemblyAI `max_turn_silence` | **1536 ms** | [Streaming API ref](https://www.assemblyai.com/docs/api-reference/streaming-api/streaming-api) |
| AssemblyAI `min_turn_silence` | **400 ms** | same |
| Speechmatics `max_delay` | **4 s** default, **0.7 s** floor | [RT API ref](https://docs.speechmatics.com/rt-api-ref) |
| Deepgram `endpointing` | **10 ms** (transcript-segment finalization) | [endpointing docs](https://developers.deepgram.com/docs/endpointing) |
| Deepgram Flux end-of-turn | **100–500 ms** | [measuring streaming latency](https://developers.deepgram.com/docs/measuring-streaming-latency) |

**Nuance that must not be glossed:** Deepgram's `endpointing` default of 10 ms shows the thesis is *not* universally true at every layer. Deepgram finalizes *transcript segments* aggressively; the long waits live at the *turn* layer (`utterance_end_ms`, Flux EOT 100–500 ms, AssemblyAI's 1536 ms). So the honest claim is: **turn-level endpointing, not segment-level transcription, is where the 400–1536 ms goes.** For a dictation app the turn boundary is exactly what the key release supplies for free.

Against a 700 ms competitive budget (§6), a 1536 ms turn-silence default is not merely the dominant term — **it alone exceeds the entire budget by 2x.** Verdict: **thesis confirmed at the turn layer, refuted at the segment layer.**

### 2A.3 What PTT buys, concretely

| | Voice assistant (VAD-endpointed) | Push-to-talk (key release) |
|---|---|---|
| How end-of-speech is known | Inferred from silence | **Known exactly** |
| Wait before finalizing | 400–1536 ms (provider default) | **0 ms** — the event is the trigger |
| False endpoint mid-sentence (user pauses to think) | Common failure; truncates the utterance | **Impossible** |
| Waits too long after user finishes | Common | **Impossible** |
| Residual post-release cost | ASR finalize + everything downstream | ASR finalize + everything downstream |

**Net saving: the full silence timeout, ~400–1536 ms, for free.** No model, no CPU, no accuracy trade-off. This is the largest single latency win available in the entire system, and it is obtained purely from the interaction design.

### 2A.4 The trap: PTT only pays off if you disable the provider's endpointer

If you stream to a cloud ASR and leave its turn detection at defaults, **you pay the silence timeout anyway** — the key release does nothing, and the server still sits waiting for 1536 ms of quiet before emitting a final. The win is only realized by:

1. **Disabling** server-side turn detection (OpenAI Realtime: `turn_detection: null`; AssemblyAI: don't rely on defaults; Deepgram: `endpointing` already near-zero), **and**
2. **Explicitly forcing finalization** on key release (Deepgram `{"type":"Finalize"}`, AssemblyAI `{"type":"ForceEndpoint"}`, OpenAI `input_audio_buffer.commit`, ElevenLabs `commit()`).

Miss step 1 or 2 and the architecture silently degrades to voice-assistant latency. **This is the most likely implementation bug in the whole system, and it is invisible — it just feels slow.**

### 2A.5 Reference implementation (primary source)

VoiceInk's `StreamingTranscriptionService.stopAndFinalize()` is a working example of the correct sequence:

```
key release
  → drainRemainingChunks()        // flush locally buffered audio
  → arm commit signal             // BEFORE commit, to avoid racing the response
  → provider.commit()             // force-finalize (Deepgram Finalize / equivalent)
  → waitForFinalCommit()          // 10 s safety ceiling, NOT the expected latency
  → joined committed segments
```
Note the deliberate ordering comment in the source — *"Set up the commit signal BEFORE sending commit to avoid a race with the response"* — a real bug class: on a fast provider the final transcript can arrive before your listener is attached.

### 2A.6 Does a PTT app need a VAD at all?

**Not on the critical path.** But a VAD is still useful *off* it:

- **Trailing-silence trim.** Users release the key ~200–500 ms after their last word (`UNVERIFIED:` no measured source found for typical human key-release lag — worth measuring in-house). Trimming that trailing silence before the final ASR pass reduces work; more importantly, trimming *leading* silence avoids wasted inference.
- **Empty-utterance rejection.** If the user taps the key accidentally, a VAD lets you abort silently rather than round-tripping to a paid API.
- **UI feedback.** A live level/voice indicator during the hold serves the acknowledgment clock (§6.4).

None of these are latency-critical, which means the VAD choice can be made on CPU cost and license rather than on latency.

*(VAD library comparison — Silero / WebRTC / energy — in §2B.)*
