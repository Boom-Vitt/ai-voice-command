# Voice Dictation Desktop App — Key Findings (working notes)

Research date: 2026-08-24. Sourcing rule: every load-bearing claim carries a URL,
or is marked UNVERIFIED, or is marked MEASURED (run on this machine).

## THE CENTRAL TENSION (discovered 2026-08-24)

The English-market research converges on a clean recommendation:

> "the honest privacy claim and the zero-COGS path are the same path"
> — i.e. build on Apple `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+) and
> Windows AI Speech Recognition (Win11 24H2+). Free, offline, no vendor contract,
> better English accuracy than Whisper Small.

**That recommendation does not survive contact with Thai.**

MEASURED on this machine (macOS 26.5.1, Build 25F80), via `SpeechTranscriber.supportedLocales`:

```
SpeechTranscriber.supportedLocales count = 30
de-AT de-CH de-DE en-AU en-CA en-GB en-IE en-IN en-NZ en-SG en-US en-ZA
es-CL es-ES es-MX es-US fr-BE fr-CA fr-CH fr-FR it-CH it-IT ja-JP ko-KR
pt-BR pt-PT yue-CN zh-CN zh-HK zh-TW
THAI: **NOT PRESENT**
installedLocales count = 0

SFSpeechRecognizer.supportedLocales count = 63
THAI: th-TH present; available=true; supportsOnDevice=TRUE
CONTROL en-US: available=true supportsOnDevice=true
```

Consequences:
1. Apple's NEW, fast, high-accuracy on-device engine (`SpeechAnalyzer`) **cannot do Thai at all.**
   The free+private+zero-COGS path is English/EU/CJK only.
2. Apple's LEGACY `SFSpeechRecognizer` DOES do Thai on-device. But it is the older engine, and
   Apple's own docs warn: "For some languages, the recognizer might require an Internet connection."
   Quality vs Thonburian Whisper is unmeasured.
3. Therefore a Thai-first product is pushed toward (a) cloud ASR, or (b) self-hosted Thai-tuned
   Whisper — both of which reintroduce COGS and/or the privacy-contract problem.

NOTE this corrects a third-party blog claim (antongubarenko.substack.com) that a subagent had
accepted, which stated SpeechTranscriber includes th_TH across ~34-42 locales. On real hardware
it is 30 locales and Thai is absent.

## MEASURED: audio capture startup cost (macOS 26, Apple Silicon, n=5)
```
AVAudioEngine, fresh object, FIRST mic access in process (cold): TOTAL 2567.6 ms
  (ctor 2361.0 | installTap 17.9 | prepare 24.0 | start() 56.8 | start->firstBuf 107.9)
AVAudioEngine, fresh object, warm:                              TOTAL 241.2-260.1 ms
AVAudioEngine, stop()/start() reusing engine+node:              TOTAL ~168-178 ms
Raw CoreAudio HAL AudioUnit, full construct -> first callback:  TOTAL 67.8-70.3 ms
```
Implication: the first dictation after launch pays ~2.5 s of mic warm-up unless you pre-warm.
Keeping a HAL AudioUnit warm gets you to ~70 ms; a naive AVAudioEngine per-recording costs ~250 ms.
This is why "prewarm on launch and on system wake" is a required pattern, not an optimization.

## LATENCY: the two-clock model (governs the whole design)

Do NOT stack Nielsen/Doherty/RAIL into one budget; they measure different clocks.

| Clock | Starts | Ends | Target |
|---|---|---|---|
| Acknowledgment | hotkey keydown | visible "capturing" indicator | <=100 ms (ideally <=50) |
| Completion | key RELEASE | text present in target app | <=500 ms stretch / <=700 competitive / <=1000 acceptable |

The perceptual literature requires ACKNOWLEDGMENT within 100 ms, not text within 100 ms.
The acknowledgment clock is cheap to win and creates most of the "feels instant" impression.
Sources: Nielsen response-time limits (nngroup.com/articles/response-times-3-important-limits/),
Doherty threshold 400 ms (lawsofux.com/doherty-threshold/), Google RAIL (web.dev/articles/rail).
Calibration: Wispr Flow's own published target is 700 ms after you stop speaking -- already 1.75x
outside Doherty. Sub-400 ms is only reachable by removing the LLM pass from the critical path.

## LATENCY: push-to-talk is the single biggest architectural win

Precise formulation (the naive version is false and collapses under review):

> PTT does not "eliminate endpointing." It replaces a SPECULATIVE SILENCE TIMEOUT with a
> DETERMINISTIC EXPLICIT FINALIZE EVENT. Residual cost is the provider's finalize turnaround
> (~300 ms cloud streaming), not zero.

Published provider silence defaults you avoid by using PTT:
- AssemblyAI max_turn_silence default 1536 ms (min_turn_silence 400 ms)
- Speechmatics max_delay default 4 s, floor 0.7 s
- Deepgram Flux end-of-turn 100-500 ms
- (Deepgram `endpointing` default 10 ms is SEGMENT-level, not turn-level -- the thesis holds at the
  turn layer, not the segment layer. Do not overstate it.)

A 1536 ms turn-silence default alone exceeds the entire 700 ms competitive budget by 2x.

### THE TRAP (most likely bug in the whole system, and it is invisible)
PTT only pays off if you BOTH:
1. Disable server-side turn detection (OpenAI Realtime `turn_detection: null`; don't rely on
   AssemblyAI defaults), AND
2. Explicitly force-finalize on key release:
   Deepgram `{"type":"Finalize"}` | AssemblyAI `{"type":"ForceEndpoint"}` |
   OpenAI `input_audio_buffer.commit` | ElevenLabs `commit()`
Miss either and the architecture silently degrades to voice-assistant latency. It just "feels slow."

Reference implementation ordering (VoiceInk StreamingTranscriptionService.stopAndFinalize()):
  key release -> drain buffered audio -> ARM the commit signal BEFORE committing (avoids a race
  where the final transcript arrives before your listener attaches) -> commit() -> await final.

### Does a PTT app need a VAD?
Not on the critical path. Useful off it: trailing-silence trim, empty-utterance rejection (don't
round-trip a paid API on an accidental tap), and live level UI for the acknowledgment clock.
So choose a VAD on CPU cost and license, not latency.

## TEXT INJECTION: the decision table (the hard part of the product)

| App class | Primary approach | Why | Fallback |
|---|---|---|---|
| Native macOS text controls (NSTextField/NSTextView, TextEdit, Notes, Mail) | AX: set `kAXSelectedTextAttribute` on focused element | inserts at caret; no clipboard, no keystrokes, no undo spam | clipboard paste |
| macOS Electron/Chromium (VS Code, Slack, Discord, Notion) | clipboard paste (Cmd+V) | AX tree not built until AXManualAccessibility/AXEnhancedUserInterface set, and setting it is itself broken (electron#37465) | slow synthetic Unicode keystrokes |
| macOS terminals (Terminal, iTerm2, Ghostty, Warp) | clipboard paste, but detect Secure Keyboard Entry FIRST | terminals opt into EnableSecureEventInput; event taps die | refuse + tell user |
| Windows standard controls / most apps | SendInput + KEYEVENTF_UNICODE | Microsoft explicitly blesses this for voice recognition | clipboard + Ctrl+V |
| Windows payloads >~200 chars | clipboard + Ctrl+V | SendInput is 2 INPUT events per UTF-16 unit; latency scales | -- |
| Windows ELEVATED windows (admin cmd, Task Manager, regedit) | **nothing works** | UIPI blocks SendInput SILENTLY | detect + tell user |
| Any secure/password field (both OSes) | **refuse** | macOS kills event taps; injecting into a password field is user-hostile | detect + tell user |

Also: `RegisterHotKey` on Windows CANNOT do push-to-talk -- you need WH_KEYBOARD_LL (three landmines)
or Raw Input (Microsoft's own recommendation).

## OSS PATTERNS WORTH COPYING (from VoiceInk GPL-3.0 / Handy MIT source-level dissection)
1. Clipboard-paste, not synthetic typing. Nobody types char-by-char as the default.
2. **Receipt-sequenced clipboard restore** (Handy `paste_tx/`, MIT): restoring the clipboard on a
   TIMER is a race you lose. Publish a lazy pasteboard PROMISE, restore only after the OS reports a
   consumer actually read it. Copy this outright.
3. Secure Event Input kills CGEventTap -> need a Carbon-registered shadow hotkey fallback.
4. **Layout-aware Cmd+V**: `keystroke "v"` breaks on Dvorak/AZERTY/Cyrillic. Resolve the physical
   keycode via UCKeyTranslate (Handy `resolve_command_v_keycode()`, ~70 lines, MIT).
5. **Prewarm the model on launch AND on system wake** with a bundled 1-second WAV.
6. **Pre-decode VAD is dangerous**: VoiceInk #853 -- whisper's built-in VAD silently discarded ~95%
   of a 168 s dictation. Data loss, no error. Run your own streaming VAD with ~450 ms pre-roll,
   fail-open.
7. Hybrid one-key hotkey: tap <0.5 s = toggle, hold >=0.5 s = push-to-talk.
8. LLM cleanup needs prompt-injection armour: tag-wrap the transcript, forbid following instructions
   inside it, forbid answering questions in it, forbid "the transcript is empty" narration, demand
   bare output. VoiceInk and Handy independently converged on all four.
9. Capture at device-native rate, resample to 16 kHz in 30 ms frames; handle mid-recording device
   change with a full stop->uninit->set-device->re-read-format->re-init dance.
10. Don't default to whisper: Handy's catalogue scores canary-180m-flash (218 MB) at 98 speed /
    88 accuracy vs whisper-large-v3's 23 / 89.

LICENSES: VoiceInk GPL-3.0 (architecture only -- do NOT lift code into a closed product).
Handy MIT (copy freely with attribution). Hyprnote MIT except enterprise/.

## UNIT ECONOMICS (English assumptions -- see Thai token tax caveat below)
Model: 60 audio-min/week = 260 min/month = 39,000 words/month.

- **ASR cost is NOT the discriminator.** Every credible option clears 90% gross margin on a paid
  user at $20/mo. Break-even is 43-440 audio-HOURS/month vs the modelled 4.33 -- a user would have to
  dictate 1.5-15 h/day every day to lose money.
- **The cleanup LLM is free in practice**: $0.02-$0.31/user/month, i.e. 0.1%-1.5% of a $20 sub.
  The entire cleanup-model decision spans 1.5% of one subscription. Choose on QUALITY and TTFT,
  never on price.
- **Where provider choice actually bites: the FREE FUNNEL.** A free user at 2,000 words/week costs
  22.2% of a paid user. At 5% conversion you carry 19 free users per paid user:
    local $0.10 | Groq batch $0.84 | Deepgram Flux regular $8.55 (43% of one sub!) |
    Google Chirp logging-off $26.41 -- the free tier alone EXCEEDS the subscription price.

### The privacy premium (the number that changes the arithmetic)
- Google charges $0.016/min WITH data logging vs $0.024/min WITHOUT -- a +50% privacy premium,
  disclosed openly.
- Deepgram's LISTED prices are tied to its Model Improvement Partnership Program, under which
  "Deepgram stores fractional increments of data for the continued improvement of our voice AI
  models." Opt-out is a per-request param (`mip_opt_out=true`) -- the best MECHANISM of any cloud
  vendor -- but UNVERIFIED whether opting out forfeits ~50% discount. If it does, Deepgram moves
  from best-in-class to worse than most of the field. **Highest-value number to confirm in writing.**
- **Budget a 1.5-2x multiplier on any cloud ASR quote if the privacy claim is load-bearing.**
  The headline prices are, for at least two major vendors, the SURVEILLANCE price.

### Can a privacy claim be honest?
YES, architecturally: Apple SpeechAnalyzer (macOS 26+) / Windows AI Speech Recognition (Win11 24H2+)
/ self-hosted open weights. Nothing leaves the device; verifiable by a user with Little Snitch.
CONDITIONALLY: OpenAI with APPROVED ZDR (approval is discretionary -- you cannot ship a claim that
depends on an approval you don't have); ElevenLabs Zero Retention Mode (enterprise-only).
NO, NOT HONESTLY: AssemblyAI on a standard plan -- their ToS grants an explicit licence to
"train AssemblyAI's artificial intelligence and machine learning models" on Customer Data, with
opt-out only "to the extent applicable to Customer's pricing plan."

>>> BUT SEE THE CENTRAL TENSION: for Thai, the architectural privacy path is closed on macOS.

## THAI TOKEN TAX (caveat on all the economics above)
The $0.02-$0.31/user/month cleanup figures assume ~0.75 words per token, which is ENGLISH.
Thai is poorly represented in BPE vocabularies and costs materially more tokens per character.
Multiplier being measured. Until then, treat all cleanup-LLM costs above as a LOWER BOUND for Thai.

# =====================================================================
# PREMISE REFUTATION (added after competitor/market/Wispr briefs landed)
# =====================================================================

## Three assumptions the project started with are FALSE. Report this honestly.

**1. "Nobody serves Thai" — FALSE.**
- Wispr Flow lists Thai and has SPECIFICALLY optimised it. CTO Sahaj Garg research post
  (19 Jan 2026) names Thai in a tier of seven languages "trained and tuned to match
  English-level performance", studies Thai phonology explicitly, markets Thai speed (4x
  faster than tapping characters). https://wisprflow.ai/research/supporting-languages
- Thai App Store reviewer (5*): "I barely type myself anymore now, both Thai and English"
  — and notes the review itself was dictated.
- Windows 11 Voice Typing DOES list Thai (43 languages). The hypothesis that it might be
  absent was wrong. https://support.microsoft.com/en-us/windows/use-voice-typing-...
- Google Voice Typing: Thai supported. Every Whisper wrapper: Thai inherited from Whisper.
- Wispr already has Thai MINDSHARE: Thai TikTok reviews, Future Trends Thailand FB posts.
=> You would be entering BEHIND, not into a vacuum.

**2. "US-centric incumbents structurally ignore code-switching" — FALSE.**
- Wispr runs a dedicated India page: https://wisprflow.ai/india
  - "Hinglish" sold as its OWN NAMED LANGUAGE
  - Rs400/mo, Rs320/mo annual = $4.18 vs US $15 => 72% REGIONAL DISCOUNT
  - Accepts UPI (India's PromptPay equivalent)
- => They have BUILT AND PROVEN the exact localisation playbook a Thai play depends on.
- Tempering: India is their ONLY localised market. /thailand -> 404, /indonesia -> 404,
  main pricing page has NO regional pricing. So the window is plausibly 18-36 months,
  not one quarter.

**3. "$20/mo ~ 700 THB" — STALE.** At 32.67 THB/USD (21 Aug 2026) $20 = 653 THB.
  And Wispr's actual price is $15/mo ($12 annual) = 392-490 THB.

## CANTO — the clock on this opportunity
Announced WITH the Series B (17 Aug 2026): Wispr's first proprietary speech model,
explicitly targeting intra-sentence code-switching — "half the world moves between
languages... often inside a single sentence." Their current docs say the opposite
("Rapid language switching within a single sentence is not supported").
=> The gap is real TODAY and time-boxed to roughly 18-24 months.

## THE SURVIVING WEDGE: OUTPUT SCRIPT, not recognition
When a Thai professional says "ขอ deck ก่อน brief ลูกค้า", does the model emit Latin
`deck` or Thai `เด็ค`?
- Wispr's Thai claim is explicitly about PRONUNCIATION ("English->Thai loanwords are
  pronounced with Thai phonetics and tone") and says NOTHING about output script.
- The ASR field had to invent **T-WER (transliterated WER)** precisely because training
  corpora are inconsistent here: "there were multiple instances of the same English word
  appearing both in the Latin script and the native scripts" https://arxiv.org/pdf/2203.16578
- For pasting into Slack or a client email the script choice IS the product.
  "ขอ deck ก่อน brief ลูกค้า" = correct. "ขอเด็คก่อนบรีฟลูกค้า" = embarrassing.
- This is a TEXT/FORMATTING problem as much as an acoustic one => favours a small team.

## WHY WHISPER WRAPPERS STRUCTURALLY CANNOT CODE-SWITCH (characterises half the market)
"Whisper's language and task tokens cannot explicitly direct the model to do code-switching
ASR, with each language token only representing one language."
https://arxiv.org/html/2412.16507v2
- whisper.cpp maintainer ggerganov: "switching languages is not trivially supported";
  same thread: "Code switching is currently an unsolved problem in AI"
  https://github.com/ggml-org/whisper.cpp/issues/749
- Worse: a locale lock silently becomes TRANSLATION — 5 users confirm French/Italian->English
  even with translate=false. https://github.com/ggml-org/whisper.cpp/issues/1843
- Superwhisper, MacWhisper, VoiceInk, Better Dictation, Spokenly, Handy ALL inherit this.
- Whisper's own paper reports **CER not WER** for Thai (no standard tokenisation) —
  Thai is permanently in the "hard to even measure" bucket. https://jmlr.org/papers/volume25/23-1318/23-1318.pdf
- Deepgram Nova-3 has Thai, but its `multi` code-switch model EXCLUDES Thai.
=> BOTH the local tier and the cloud tier converge on one language per utterance.

## WISPR FLOW — verified specifics
- Pricing: Pro $15/mo ($144/yr), Student $7.50, **Business $30/seat** (help centre only,
  not the pricing page). Checkout: USD/GBP/EUR/JPY/KRW ONLY. No THB. No PPP tier.
- **Sub-processor list is PUBLIC** in DPA Annex 2 (wisprflow.ai/legal/dpa) — 34 vendors,
  EVERY ONE USA-located: Anthropic, OpenAI, Google, Cerebras, OpenPipe (NLP);
  Fireworks/Baseten/Modal/Foundry (serving); WorkOS (SSO); ElevenLabs = **TTS only**.
  NO dedicated ASR vendor appears.
- **Context Awareness is ON BY DEFAULT and transmits "a screenshot" of your screen with
  each dictation**, plus textbox contents and conversation history.
- **SOC 2 Type II is claimed in marketing but their own security FAQ says "not yet issued"**
  — both prior certs self-invalidated March 2026 after their auditor (Delve) had
  "platform integrity concerns."
- Late 2025: caught sending screenshots of active windows to the cloud, and BANNED the user
  who reported it; CTO apologised.
- Current docs: audio/transcription "may be used to evaluate, train, and improve Wispr's
  models. This is the default for trial and standard accounts." Only Enterprise/HIPAA get
  Privacy Mode on by default. NO on-device option at all.
- Traction: iOS 4.83 / 14,159 ratings (vs Superwhisper 4.38/818, Aqua 4.39/75).
  **Thailand = 195 iOS ratings vs India 2,572 vs US 14,159.**
- 60B words written; "almost all of the Fortune 500".
- **They are COMMODITISING dictation** — Free tier now includes 100+ languages AND Notetaker.
  Selling "better dictation" means entering a category the leader gives away.

## DRAGON HAS EXITED THE MARKET
nuance.com/dragon/... now 301-redirects to microsoft.com/health-solutions.
Dragon Anywhere discontinued 1 Jul 2026. That vacuum is what this startup wave is filling.

## THE BEST DEVELOPER WEDGE FOUND (macOS Secure Event Input)
SEI is a process-global singleton; while held, EVERY CGEventTap on the machine dies.
- Wispr ships a first-party help page about its own breakage, naming 1Password, Terminal,
  iTerm2. Official workaround: downgrade to hold-to-talk.
- **Cursor leaks Secure Event Input 4-7 times daily (Aug 2026)**, killing dictation, Raycast
  and text expanders until quit or screen lock. Cursor attributes it to Electron/Chromium
  password-field behaviour, so it GENERALISES.
  https://forum.cursor.com/t/cursor-leaks-secure-event-input-.../167585
=> The dominant use case is now talking to coding agents, and terminals + Cursor are exactly
   where dictation breaks. Detecting SEI and degrading gracefully — or routing text via
   CLI/MCP instead of synthetic keystrokes — fixes what the $2B leader publicly cannot.

## OTHER CONFIRMED FAILURE MODES
- **Silent cloud regressions**: identical 525 clips re-run a month apart — WER rose
  9.0% -> 11.2%, worse in 8 of 9 categories, on plain American English.
- **LLM cleanup flattens voice**: "all tone and personality it stripped away... makes
  everything sound like a polite old lady." Cuts hardest against non-native speakers.
- **Pricing churn is measurable**: "Just canceled my WisprFlow subscription... to switch to
  a open source, free, local alternative" — posted 17 Aug 2026, the SAME DAY as the $280M raise.
  An unusually large share of this market can rebuild the product in a weekend, and many do.
- **Zero lock-in**: "I use aqua and wispr flow depending on which one seems to be returning
  the best results that day."
- macOS TCC drops Accessibility grants when the code signature changes.
- Bluetooth/HFP downgrade wrecks accuracy; nobody addresses it.
- Linux/Wayland has NO working text-injection story.

## THAI COMMERCIAL FACTS
- FX 32.67 THB/USD (21 Aug 2026).
- Thai national average wage 15,316 THB/mo (NSO, Mar 2026); median ~12,000;
  **software developer 30,000-50,000** (JobsDB) — the actual target.
- Thai mainstream subscription band: YouTube Premium Lite 119 / Spotify 149 / Netflix Basic
  169 / **YouTube Premium 199** / Spotify Family 249 / Netflix Standard 349 /
  **Netflix Premium 419 (most expensive mainstream sub in Thailand)**.
- **Wispr Pro costs a Thai buyer 392-490 THB/mo — at or just above Netflix Premium.**
  (Use the RANGE; the 490 monthly figure exceeds Netflix Premium, the 392 annual sits just below.)
- iApp Technology (Thai ASR) sells PREPAID CREDITS not subscriptions: 89 THB/60 credits,
  150/120, 700/600. Entry at 89-150 THB — a Thai AI company selling to Thai buyers chose
  consumption pricing at a sub-200 THB entry point. Strong revealed preference.
- **Credit cards: only 22.61% of Thai adults** (World Bank Findex). PromptPay: 80-90M+
  registrations vs ~71M population = effectively 100% adult coverage.
  **Stripe Thailand supports PromptPay natively** — but requires a Thai entity.
- Recommended price band (judgement, not sourced): 199-299 THB/mo headline;
  1,990-2,490 THB/yr; **plus a 2,900-3,900 THB lifetime tier** — the one structure a
  subscription-native incumbent is least willing to match.
- VAT: 7%; registration threshold 1.8M THB/yr turnover => first ~1.8M THB is VAT-free
  (~750 subscribers at 199 THB). Monthly filing by the 23rd, even in zero months.
- B2B trap: 3% withholding tax on services (threshold 1,000 THB); you CANNOT issue a
  compliant ใบกำกับภาษี without VAT registration, and many Thai companies won't buy without
  one — so you may need to register voluntarily BEFORE the threshold forces you.
  => B2C/prosumer self-serve is dramatically lower-friction for a solo founder.

## PDPA — the actual legal mechanism (this is the #1 moat)
- **Voice for dictation = ORDINARY personal data, NOT s.26 sensitive data.** s.26 covers
  "biometric data used for IDENTIFICATION". Transcribing speech without building a speaker
  model stays out of s.26. **=> KEEP VOICEPRINT / SPEAKER-ID OUT OF v1** — adding it flips
  you into s.26 and requires separate explicit consent.
- s.23 privacy notice must name **who data is disclosed to** => forces you to list your cloud
  ASR/LLM vendors. Thai enterprise buyers read that line.
- **ss.28-29 cross-border: Thailand has published NO adequacy whitelist**, so the adequacy
  route is unusable. You must either run SCCs with every foreign sub-processor, or obtain
  consent AFTER expressly warning the user the destination LACKS adequate protection.
  => a conversion-rate problem as much as a legal one.
- **Local-only processing DELETES the ss.28-29 obligation entirely** (no transfer occurs),
  and shrinks the s.23 disclosure surface to "no one". It does NOT exempt you for accounts/
  telemetry/crash logs.
- Wispr is cloud-only with opt-OUT training and NO on-device option => matching
  "your voice never leaves this laptop" is a ground-up rewrite, not a pricing decision.

## MOAT RE-RANKING (after the India finding)
1. **Local-only processing + PDPA** — HIGH durability. Architectural, not a pricing decision.
2. **Thai<->English output-script correctness** — ONLY IF the experiment below confirms a gap.
3. Thai UI / Thai support on LINE / ใบกำกับภาษี — medium; a US company won't bother.
4. Apple's missing Thai in SpeechTranscriber — medium; raises everyone's cost including yours.
5. Price / payment rails — REAL TODAY but Wispr can neutralise both (they did in India).

=> The pitch is NOT "we're cheaper and take PromptPay." It is
   **"your client's voice never leaves your laptop, and we write your English words in English."**

## THE DECISIVE EXPERIMENT — do this before writing any code (~1 afternoon, ~$15)
1. Buy one month of Wispr Flow Pro.
2. Dictate 30-50 utterances of REAL Thai office speech with English inserts.
3. Score separately: (a) Thai word accuracy; (b) whether English inserts emit in LATIN or
   THAI script; (c) CONSISTENCY of that choice across repetitions of the same word.
4. Repeat on Superwhisper (local Whisper), Monologue (claims mid-sentence switching),
   Windows/Google voice typing as free baselines.
RESULT INTERPRETATION:
- Clean, consistent Latin-script inserts => the ASR wedge is DEAD. This becomes a local
  distribution/privacy business, not a technology startup.
- Transliterates or flip-flops => the wedge is real, sharp, and demonstrable in a 10s video.
Nobody has published this answer. It is worth more than any further desk research.

## HONEST SCALE EXPECTATION
A good 10-50M THB/yr local software business, NOT a venture-scale category bet.
Thailand is 195 iOS ratings vs India's 2,572 — whatever is built for Thai must generalise.
