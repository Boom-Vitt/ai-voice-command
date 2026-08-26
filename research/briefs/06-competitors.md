# Desktop Voice-Dictation: Competitive Landscape & Failure Modes
Research brief — compiled 2026-08-24. Every claim carries a source URL; anything unsourced is marked `UNVERIFIED:`.
STATUS: COMPLETE. Parts A, B and C below.
HEADLINE: Wispr Flow's own documentation states **"Rapid language switching within a single sentence is not supported"** and puts non-Latin-script + English in its worst-performing bucket. See section B10 — that is the wedge.

## Verified anchors (carried from prior run)
- Wispr Flow: $280M Series B at $2B valuation, 17 Aug 2026, led by Menlo Ventures; total raised $361M; no ARR disclosed. https://techcrunch.com/2026/08/17/wispr-raises-280m-at-2b-valuation-as-it-looks-beyond-dictation/
- Wispr Flow is CLOUD-ONLY; training on user audio is OPT-OUT by default on standard/trial. https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq
- Wispr Flow tells users to "select only the language you're speaking right now" -> no true code-switching. https://wisprflow.ai/
- Apple SpeechTranscriber (macOS/iOS 26) DOES include th_TH; ~34-42 locales; separate model download per language; one locale per instance. https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide
- Apple SpeechAnalyzer WER 2.12% clean / 4.56% noisy vs Whisper Small 3.74/7.95 (LibriSpeech, English). https://lyonesse.app/blog/apple-speech-api-benchmark.html
- Deepgram Nova-3 supports Thai (th/th-TH) but its `multi` code-switching model covers only EN/ES/FR/DE/HI/RU/PT/JA/IT/NL — Thai excluded. https://developers.deepgram.com/docs/models-languages-overview
- Thonburian Whisper Thai WER (CommonVoice 13, deepcut tokenizer): large-v3 6.59, medium 7.42, large-v2 7.69, small 11.0. https://github.com/biodatlab/thonburian-whisper
- Apple rejects system-wide dictation apps from Mac App Store under guideline 2.4.5 (accessibility API text injection). https://news.ycombinator.com/item?id=48369088

---

# PART A — COMPETITOR MATRIX

## A1. Wispr Flow — the category leader
- Platforms: Mac, Windows, iOS, Android. Notetaker feature is Mac-only (Windows "coming soon"). https://wisprflow.ai/pricing
- Pricing: Free $0 — **2,000 words/week on desktop, 1,000/week on iPhone**; Android unlimited. Pro **$15/user/mo monthly, $12/user/mo annual** (20% off). Enterprise custom. https://wisprflow.ai/pricing
- Inference: **cloud-only.** https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq
- Model: undisclosed proprietary; Pro adds "advanced AI thinking models". https://wisprflow.ai/pricing
- Languages: claims 100+. https://wisprflow.ai/pricing
- Privacy: HIPAA-ready; Enterprise gets SOC 2 Type II + ISO 27001; "opt out of model training, any time" — i.e. **opt-OUT, not opt-in**. https://wisprflow.ai/pricing + https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq
- Funding: $280M Series B @ $2B, Aug 2026, Menlo Ventures; $361M total. https://techcrunch.com/2026/08/17/wispr-raises-280m-at-2b-valuation-as-it-looks-beyond-dictation/
- Logos claimed: Microsoft, Amazon, Notion, Klarna, Groupon, Rivian, Vercel, Mercury. https://wisprflow.ai/pricing

## A2. Superwhisper — the local-first / lifetime-license incumbent
- Platforms: macOS (Intel + Apple Silicon), Windows, iOS. https://superwhisper.com/
- Inference: **hybrid, local-first.** Offline models ship in-app ("works offline"); cloud models optional (GPT-5, Claude Haiku, Llama 4, Grok, Gemini, Ministral for the post-processing LLM). https://superwhisper.com/
- STT models: Whisper Large among the on-device voice models. https://superwhisper.com/
- Pricing: Free tier = 15 minutes of recording with Pro features, then unlimited free-tier features. **Pro $8.49/mo**; yearly = "2 months free"; **Lifetime license offered** (flagged as the "top choice" tier); Enterprise volume pricing; 40% student discount. https://superwhisper.com/
- Languages: 100+ languages & dialects, plus translate-to-English. https://superwhisper.com/
- Standout: **Modes** (Voice / Message / Email / custom), custom vocabulary, meeting assistant, auto-paste into the frontmost app, 30+ named app integrations. https://superwhisper.com/
- Funding: none disclosed — indie/bootstrapped. `UNVERIFIED: no funding round found.`

## A3. Aqua Voice — YC W24, developer-leaning
- Platforms: macOS, iOS, Windows, plus a web app. https://aquavoice.com/
- Pricing: Free = **1,000 words** total. **Pro $8/mo** (unlimited words, custom instructions, expanded dictionary). **Max $24/mo** (adds Realtime Mode, "Send it" voice command). **Team $12/user/mo** (2-9). Business custom (SSO/SAML, zero data retention). https://aquavoice.com/
- Model: proprietary **"Avalon"**; claims 97.3% accuracy benchmarked vs Whisper, NVIDIA, ElevenLabs, AssemblyAI. https://aquavoice.com/
- Speed claims: 230 WPM vs 40 WPM keyboard, "5x faster than typing". https://aquavoice.com/
- Languages: **49** — notably fewer than the 100+ claimed by rivals. https://aquavoice.com/
- Standout: **screen-context awareness** (reads what's on screen to disambiguate), real-time refinement, Privacy Mode.
- Backing: **Y Combinator W24**. https://aquavoice.com/

## A4. VoiceInk — open-source, lifetime, local-first
- Platforms: macOS 14.4+ Apple Silicon; iOS app. https://tryvoiceink.com/
- Pricing: **one-time lifetime only, no subscription.** Solo **$29** (1 device), Personal **$49** (2 devices), Extended **$69** (3 devices). Free trial + 14-day money-back. https://tryvoiceink.com/
- Inference: **local on-device by default**; "Cloud Enhancement is entirely optional — only transcribed text (not your voice) is processed". https://tryvoiceink.com/
- Open source: "built in public on GitHub. Every line is out there for you to read, audit, or run yourself". https://tryvoiceink.com/
- Standout: custom dictionary, Smart Replace phrase expansion, per-context formatting.

## A5. Willow Voice
- Platforms: Mac, Windows, iPhone. https://willowvoice.com/
- Inference: cloud by default with an **offline mode** ("powered entirely by your device"). https://willowvoice.com/
- Latency claim: **"text appears in as little as 200ms"**; "4x faster writing". https://willowvoice.com/
- Model: undisclosed. Languages: 100+. https://willowvoice.com/
- Privacy: SOC 2 Type II, HIPAA, **zero data retention**. https://willowvoice.com/
- Traction: "Trusted by 100,000+ professionals", 600+ app-store reviews. https://willowvoice.com/
- Standout: auto-learning dictionary, "Whisper mode" for quiet speech, style-matching.

## A6. VoiceType
- Platforms: cross-app desktop (Notion, Linear, Slack, iMessage, AI copilots named). https://voicetype.com/
- Pricing: yearly plan works out to **$13/mo**; free trial; **no lifetime option**. Exact monthly not published on the landing page. https://voicetype.com/
- Inference: **cloud** — "All data is encrypted through our private cloud servers". https://voicetype.com/
- Claims: 99.7% accuracy, 360 WPM ("9x faster"), 35+ languages, whisper mode. https://voicetype.com/
- Traction: **65,000+ users** claimed. https://voicetype.com/

## A7. Monologue (by Every)
- Platforms: **Apple-only** — Mac, iPhone, iPad, Apple Watch. https://monologue.to/
- Pricing: Free = **1,000 dictation words + 10 recorded notes**. **$15/mo** or **$144/yr ($12/mo)**. Also bundled into the Every subscription. https://monologue.to/
- Inference: hybrid — offline transcription models on Mac; cloud AI providers with zero data retention. https://monologue.to/
- **Claims dictation "adapts to 100+ languages mid-sentence"** — one of the only vendors making an explicit mid-sentence multilingual claim. https://monologue.to/
- Standout: per-app formatting (casual in Slack, formal in Gmail, technical in code editors), bot-free meeting notes, MCP/API/CLI access.
- Maker: **Every** (the media company). https://monologue.to/

## A8. Spokenly
- Platforms: **macOS, iOS, Windows, Linux** — the widest OS coverage in the set. https://spokenly.app/
- Pricing: Free = **unlimited local transcription + BYOK cloud**. **Pro $9.99/mo** covering Mac + iPhone. No annual/lifetime listed. https://spokenly.app/
- Inference: local **Whisper and Parakeet** on Apple Silicon; cloud via OpenAI, Deepgram, Groq, Anthropic, Google (**BYOK**). **"Local Only Mode blocks all network requests"**. https://spokenly.app/
- Standout: **MCP server for AI coding agents (Claude Code, Cursor)**, agentic macOS automation, 100+ languages with auto-detection. https://spokenly.app/

## A9. Talon Voice — the accessibility / voice-coding outlier
- Platforms: macOS, **Linux (X11)**, Windows (incl. portable zip). https://talonvoice.com/
- Pricing: **Patreon patron model** for early access + priority support; base app free. Exact tiers not on the site. https://talonvoice.com/
- Standout: voice control, **noise control** (pops/hisses as clicks), **eye tracking**, full Python scripting. https://talonvoice.com/
- Audience: RSI sufferers and voice coders, not general dictation.

## A10. MacWhisper
- Platforms: macOS. Distributed via Gumroad + a Mac App Store variant ("Whisper Transcription").
- Pricing: **Pro €59 one-time (~$69)** on Gumroad; the Mac App Store variant carries a **$99.99 lifetime IAP** alongside subscriptions. `UNVERIFIED: both figures come from competitor-run SEO blogs (getvoibe.com, spokenly.app/blog — spokenly is a direct rival), not first-party.` https://www.getvoibe.com/resources/macwhisper-pricing/
- Models: all Whisper sizes Tiny→Large V3, WhisperKit, plus **NVIDIA Parakeet** on Apple Silicon (added v13, June 2025, Pro-gated). `UNVERIFIED: same second-hand sourcing.` https://vowen.ai/blog/macwhisper-review/
- Inference: local-first, with optional cloud API models.

## A11. Better Dictation
- Platforms: macOS, M1+; **Windows "coming soon"**. https://betterdictation.com/
- Pricing: **lifetime tiers** — Basic **$39** (1 device), Flex **$49** (3 devices), Studio **$149** (10 devices); optional **Pro add-on $2/mo billed annually**; Enterprise custom; 14-day refund. https://betterdictation.com/
- Inference: **local, "entirely on Apple's Neural Engine", "no cloud round-trips"** for base transcription; Pro features call out to OpenAI. https://betterdictation.com/
- Model: **Whisper-large-v3-turbo** (explicitly disclosed — rare in this market). https://betterdictation.com/
- Languages: 100+; markets accent handling (Scottish, Manchester, Indian, Hindi). https://betterdictation.com/

## A12. Handy — free/open-source baseline
- Platforms: **Mac, Windows, Linux**. https://handy.computer/
- Price: **free and open source** — "Accessibility tooling belongs in everyone's hands, not behind a paywall." https://handy.computer/
- Inference: **fully local** — "Your voice stays on your computer." Model choice includes **Whisper and Parakeet**. https://handy.computer/ + https://news.ycombinator.com/item?id=49100131
- Funded by donations/GitHub Sponsors. Repo: https://github.com/cjpais/Handy
- Community verdict: "Handy is the one that made me stop looking for local open source alternatives to Wispr Flow." https://news.ycombinator.com/item?id=47668925

## A13. Dragon (Nuance → Microsoft) — effectively exited general desktop dictation
- **`nuance.com/dragon/business-solutions/dragon-professional-v16.html` now 301-redirects to `microsoft.com/health-solutions`** (verified 2026-08-24). Microsoft has folded the Dragon brand into healthcare.
- Dragon Home (~$150 tier) discontinued 2023; no v16 Home. Dragon Professional ~**$699.99 one-time, Windows-only**. **Dragon Anywhere (mobile) discontinued effective 1 July 2026.** `UNVERIFIED: sourced to competitor SEO blogs (getvoibe.com, spokenly.app/blog), not a first-party Microsoft notice.` https://www.getvoibe.com/resources/dragon-pricing/
- Microsoft's investment goes to **Dragon Copilot** (ambient clinical documentation, launched Mar 2025), not desktop dictation. https://www.getvoibe.com/resources/dragon-pricing/
- **Read-through: the 30-year incumbent has vacated the general-purpose desktop dictation market.** That vacuum is what the current wave of startups is filling.

---

# PART B — FAILURE MODES

## B1. NON-ENGLISH & CODE-SWITCHING — the deepest, least-defended crack

### B1.1 The mechanism: Whisper emits ONE language token per decode window
This is not a tuning bug, it is architectural, and it is confirmed by the maintainers.
- whisper.cpp maintainer **ggerganov**, on a request to handle speakers switching languages mid-speech: *"switching languages is not trivially supported"*. https://github.com/ggml-org/whisper.cpp/issues/749
- Same thread, another commenter: *"Code switching is currently an unsolved problem in AI"* (links MDPI survey). https://github.com/ggml-org/whisper.cpp/issues/749
- Reported behaviour in that thread: with mixed audio Whisper *"will ignore and sometimes say [Speaking in French]"*, and results flip depending on **whether it hears English first**. https://github.com/ggml-org/whisper.cpp/issues/749
- Worse, a locale lock silently becomes translation. Issue title: *"whisper with language set when other language spoken it return translated"* — five separate users confirm ("Same issue here", "Same issue", French→English and Italian→English) **even with `translate=false`**. https://github.com/ggml-org/whisper.cpp/issues/1843
- Confirmed constraint: Whisper's translation is **to English only** — there is no path to render a mixed utterance faithfully in both scripts. https://github.com/ggml-org/whisper.cpp/issues/2325

**Why this matters commercially:** Superwhisper, MacWhisper, VoiceInk, Better Dictation, Spokenly and Handy all run the Whisper/Parakeet family locally. They therefore **inherit this single-language-token limitation wholesale.** A Thai+English sentence forces the decoder to pick one language and mangle or drop the other.

### B1.2 The cloud tier fails too, for a different reason
- Deepgram Nova-3 supports Thai, but its dedicated **`multi` code-switching model excludes Thai** — it covers only EN/ES/FR/DE/HI/RU/PT/JA/IT/NL. https://developers.deepgram.com/docs/models-languages-overview
- **Wispr Flow instructs users to "select only the language you're speaking right now"** — an explicit admission it cannot handle two languages in one utterance. https://wisprflow.ai/
- Apple's SpeechTranscriber (macOS/iOS 26) does include `th_TH`, but requires a **separate model download per language and handles one locale per instance**. https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide

**Net: both tiers converge on the same constraint — one language per utterance. Nobody in the matrix has solved Thai+English.**

### B1.3 Users are already articulating this gap unprompted
- A Nepali engineer in the US, launching his own tool (Mar 2026): *"Existing tools (Wispr Flow, Dragon, even Whisper) are built assuming you think in English."* He adds they *"don't handle accents well, they don't translate"*. https://news.ycombinator.com/item?id=47254300
- On what actually separates a paid app from a Whisper wrapper, a user lists: *"Automatic dictionary, seamless language switch, no issues with accents"* — naming **seamless language switch as the last-mile feature worth paying for.** https://news.ycombinator.com/item?id=48896955
- Non-native speakers report the problem generally: *"English dictation when you speak English as a second language with an accent is quite annoying."* https://news.ycombinator.com/item?id=48092293
- Long-standing complaint: *"voice-based systems are nearly useless for non-native english speakers"* — a fluent English speaker who still cannot use dictation. https://news.ycombinator.com/item?id=7336905 (2014, dated — but the 2026 comments above show it is unresolved)
- Medical-domain measurement: ASR dictation error rates *"typically 7-11%"* owing to jargon and **accent variability**. https://news.ycombinator.com/item?id=49370554 citing https://pmc.ncbi.nlm.nih.gov/articles/PMC12460601/

### B1.4 The one incumbent making a mid-sentence claim
- **Monologue** claims dictation *"adapts to 100+ languages mid-sentence"* — the only vendor in the matrix asserting true in-utterance multilingual handling. https://monologue.to/
- Its publisher repeats the claim: *"Multilingual by default. Dictate in 100-plus languages and switch between them effortlessly"*, illustrated with users weaving *"English, Spanish, and Urdu—sometimes all in the same paragraph."* https://every.to/on-every/introducing-monologue-effortless-voice-dictation
- **Resolved as a partial threat, three ways:**
  1. Every named example is **Latin-script or Latin-transliterated (Spanish, Urdu)**. **Thai and non-Latin scripts are never mentioned** in the launch post or the site. https://every.to/on-every/introducing-monologue-effortless-voice-dictation
  2. Users may select **up to three dictation languages, or auto-detect** — i.e. the same bounded-pool design as Wispr, not open-ended per-word switching.
  3. **Its offline mode is the weak one**: local transcription runs on Mac, but *"smart formatting and syncing still require a connection"* — so the mid-sentence intelligence likely lives in the cloud path. Consistent with Monologue leaning on Apple's stack (https://monologue.to/), which is **one locale per instance** (https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide).
- `UNVERIFIED: no independent user confirmation, and no Thai test. STILL THE #1 THING TO BENCHMARK.` But the wedge holds for **Thai specifically** and for **local/offline** use, which is where the positioning sits anyway.
- Aqua Voice supports only **49 languages** vs rivals' 100+ claims — a narrower footprint. https://aquavoice.com/

### B1.5 Language-adjacent accuracy failure: hallucination on silence
Affects every Whisper-derived product, and is worse for non-English users who pause more.
- *"That happens in most speech to text systems, even Superwhisper, Monologue and Wispr Flow"* — filler text generated during silence, attributed to YouTube training data. https://news.ycombinator.com/item?id=47990553
- The classic artifact is Whisper inventing *"Thank you for watching!"* or *"please like and subscribe"* in silent regions. https://news.ycombinator.com/item?id=41984066 (2024) and https://news.ycombinator.com/item?id=47146766 (Feb 2026 — still being raised)
- Standard mitigation is a VAD front-end, which vendors must build themselves. https://news.ycombinator.com/item?id=34881026

## B2. "DOESN'T WORK IN <APP>" — three OS mechanisms, not N random bugs

Every product in this category injects text into a foreground app it does not own. Three OS-level defences block that injection. Almost every "doesn't work in X" complaint reduces to one of them.

### MECHANISM 1 — macOS Secure Event Input (the big one)
`EnableSecureEventInput` is a **process-global, reference-counted, system-wide singleton**. While any process holds it, **every CGEventTap on the machine is disabled — not just in the calling app.** https://forum.cursor.com/t/cursor-leaks-secure-event-input-breaks-all-system-wide-input-taps-until-quit-or-screen-lock/167585

**Wispr Flow ships a first-party help article about this** — the market leader documenting its own breakage. It names the culprits:
- *"Password managers (e.g. 1Password)"*, *"Terminal or iTerm2"*, and *"Wispr Flow itself (rare)"*. https://docs.wisprflow.ai/articles/8841649969-fix-flow-shortcuts-blocked-by-macos-secure-keyboard-entry-secure-event-input
- Symptom: *"fn+space or Escape suddenly stop working while hold-to-talk still works"* — because macOS keeps delivering modifier keys but blocks regular keys. Same URL.
- Official workaround is a downgrade: *"Use hold-to-talk as a workaround until the block clears."* Same URL.

**Cursor leaks it — 4-7 times per day.** This is the single most damaging finding for anyone targeting developers:
- Bug title: *"Cursor leaks Secure Event Input — breaks all system-wide input taps until quit or screen lock"*, reported 4-7 occurrences daily across **4-7 Aug 2026**. https://forum.cursor.com/t/cursor-leaks-secure-event-input-breaks-all-system-wide-input-taps-until-quit-or-screen-lock/167585
- Collateral damage named: Raycast hotkeys, Logitech Options+, text expanders, **dictation tools**. Same URL.
- Suspected triggers: masked input fields (password, SSH passphrase, API key, agent secret), **MCP server authorization popups**, background auth prompts. Same URL.
- Cursor team's read: inherited from **Electron/Chromium password-field behaviour**, not Cursor-specific code — so it generalises to the whole Electron ecosystem. Same URL.
- Recovery requires quitting the app or locking/unlocking the screen. Same URL.
- 1Password holds Secure Event Input **even when not frontmost**. https://www.1password.community/1password-at-work-58/secure-input-blocking-other-apps-event-taps-25015
- Terminal's "Secure Keyboard Entry" stays active in the background once toggled. https://discussions.apple.com/thread/8274901

**So the confirmed macOS break-list is: password/secure fields, 1Password, Terminal, iTerm2, Ghostty, KeePassXC, Cursor (and Electron apps generally).** https://github.com/ghostty-org/ghostty/issues/1325 + https://github.com/keepassxreboot/keepassxc/issues/11906

### MECHANISM 2 — Windows UIPI (User Interface Privilege Isolation)
- Apps may inject input **only into apps at equal or lower integrity level**; UIPI blocks messages from a lower to a higher MIC level. https://learn.microsoft.com/en-us/archive/msdn-technet-forums/b68a77e7-cd00-48d0-90a6-d6a4a46a95aa
- A non-elevated dictation app therefore **cannot type into any elevated window** — admin terminals, installers, elevated IDEs.
- Debugging is near-impossible for users: *"neither GetLastError nor the return value will indicate the failure was caused by UIPI"*. https://learn.microsoft.com/en-us/archive/msdn-technet-forums/b68a77e7-cd00-48d0-90a6-d6a4a46a95aa
- The escape hatch (UIAccess) requires the app be signed **and installed in a secure location** (Program Files), which rules out casual distribution. https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/user-account-control-only-elevate-uiaccess-applications-that-are-installed-in-secure-locations
- Corroborated in the wild: *"UIPI blocks UIA enumeration and input injection on elevated (admin) windows"*. https://github.com/NousResearch/hermes-agent/issues/49067

### MECHANISM 3 — custom text stacks that ignore synthetic input (Electron, IDEs, canvas apps)
Apps that render their own text surface often refuse injected keystrokes or clipboard paste.
- **VS Code on Windows**: *"Handy not working inside VS Code editor... Works in NotePad++ but not VSCode"* (21 Aug 2026, still open). https://github.com/cjpais/Handy/issues/1946
- **JetBrains Rider**: *"Text output not working with JetBrains Rider IDE"*. https://github.com/cjpais/Handy/issues/1421
- **Arc browser**: media/state side-effects on paste. https://github.com/Beingpax/VoiceInk/issues/539

### MECHANISM 4 (bonus) — focus/timing races, which look like app incompatibility
- *"Typing fails due to target window not focused at correct time"*. https://github.com/cjpais/Handy/issues/315
- *"Pastes clipboard instead of spoken text"* — clobbers the user's clipboard. https://github.com/cjpais/Handy/issues/502
- *"Pasting where cursor is on push-to-talk: scrambled sentences"*. https://github.com/cjpais/Handy/issues/1693
- Users are asking for the fix explicitly: **pin the paste target to the window focused at record-start** rather than at paste time. https://github.com/Beingpax/VoiceInk/issues/803
- Keyboard-layout assumptions break non-QWERTY users: *"Pasting is not working for DVORAK keyboard layout"* (https://github.com/Beingpax/VoiceInk/issues/597) and *"`Paste Method > Direct` does not use the correct keyboard layout"* (https://github.com/cjpais/Handy/issues/439). **This is a direct hazard for Thai keyboard layouts.**
- Handy's event tap swallows mouse buttons 4/5 system-wide, breaking back/forward navigation. https://github.com/cjpais/Handy/issues/1758

### MECHANISM 5 — Linux/Wayland has no working text-injection story at all
This is why almost nobody ships Linux.
- Wayland has no native global shortcuts; it relies on `xdg-desktop-portal`, and **each compositor must implement its own**. COSMIC's portal doesn't support GlobalShortcuts. https://news.ycombinator.com/item?id=48436160
- Handy carries a standing meta-issue: *"[META] Wayland: text insertion, hotkeys, and Flathub publication"*. https://github.com/cjpais/Handy/issues/1555
- Concrete Wayland failures, all open: auto-paste fails on GNOME 50.1 (ext-data-control unsupported) https://github.com/cjpais/Handy/issues/1742 ; *"keycombo paste selects wtype then fails with no fallback"* https://github.com/cjpais/Handy/issues/1549 ; first character dropped on GNOME/Wayland https://github.com/cjpais/Handy/issues/429 ; post-processing never triggers on KDE Wayland https://github.com/cjpais/Handy/issues/1282 ; global hotkey dead in background on Ubuntu 24.04 https://github.com/cjpais/Handy/issues/1691
- On some distros the app must request **"Remote Desktop / Allow Remote Interaction"** permission just to type — an alarming prompt for users. https://github.com/cjpais/Handy/issues/273
- Audio too: mic only detected as "Default" on Linux https://github.com/cjpais/Handy/issues/521 ; no mic on Pop!_OS PipeWire https://github.com/cjpais/Handy/issues/806
- **Wispr Flow has no Linux build at all**; the community resorted to repackaging it themselves. https://news.ycombinator.com/item?id=48436738 + https://github.com/wispr-flow-linux/wispr-flow-linux

### MECHANISM 6 — the Mac App Store is closed to this whole category
- Apple rejects system-wide dictation apps under **guideline 2.4.5** (accessibility-API text injection). https://news.ycombinator.com/item?id=48369088
- Vendors route around it by shipping direct: *"Wispr Flow distributes directly from their website and doesn't ship through the Mac App Store... The 2.4.5 limitation really only kicks in if you want App Store presence."* https://news.ycombinator.com/item?id=48370721
- Consequence: **no App Store discovery, no App Store reviews, and users must trust a direct download** — which raises the trust bar for every new entrant. (Also why App Store review mining is thin for this category.)

## B3. PRIVACY BACKLASH — the sharpest reputational wound in the category

### B3.1 The Wispr Flow incident (late 2025) — and why it is STILL live
- A user monitoring network traffic found Wispr Flow **transmitting screenshots of active windows** to cloud servers (and to third-party API providers incl. OpenAI) as part of "Context Awareness", without clear prior disclosure. Discovery credited to Ryan Shrott, "Why I Cancelled My Wispr Flow Subscription". https://modelpiper.com/blog/wispr-flow-privacy-incident (`UNVERIFIED: secondary source — the Medium original returns 403 to automated fetch`; Medium URL: https://medium.com/@ryanshrott/why-i-cancelled-my-wispr-flow-subscription-and-what-im-using-instead-d783433f4411)
- **Wispr initially banned the user who raised it**; CTO Sahaj Garg later publicly apologised for the ban. The company did not dispute the findings. https://modelpiper.com/blog/wispr-flow-privacy-incident (`UNVERIFIED: secondary`)
- The unfalsifiability problem, stated well: *"There is no audit path for a user. You cannot inspect Wispr Flow's servers."* https://modelpiper.com/blog/wispr-flow-privacy-incident

### B3.2 *** THE KEY FINDING: the fix did not actually land for individual users ***
Secondary coverage says Wispr changed training to "opt-in, off by default" after the backlash. **Wispr's own current documentation contradicts that.** Verified directly, 2026-08-24:
- *"Privacy Mode off (standard mode): audio and transcription data may be used to evaluate, train, and improve Wispr's models. **This is the default for trial and standard accounts.**"* https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq
- Only *"Enterprise and HIPAA BAA customers run with Privacy Mode on by default."* Same URL.
- And: *"Wispr Flow is multi-tenant SaaS hosted entirely with a major US cloud provider"* — **no on-device processing option at all.** Same URL.
- **Read-through: nearly a year after a privacy scandal and a CTO apology, a $2B-valuation company still trains on the audio of individual paying customers by default, and only enterprise buyers get protection automatically.** This is the single most attackable position of the market leader.
- Further trap for users: Privacy Mode and Cloud Sync are *separate* switches — zero retention requires **both**; Privacy Mode alone still leaves audio and transcripts stored on Wispr servers. https://www.getvoibe.com/resources/is-wispr-flow-safe/ (`UNVERIFIED: secondary, competitor-run`)

### B3.3 "Context awareness" is a category-wide privacy problem, not just Wispr's
- Builder's assessment of the field: *"many of these dictations app opt you into Context awareness, which means your entire page contents get streamed to their server."* https://news.ycombinator.com/item?id=48531184
- Even the **open-source, local-first** apps have shipped this bug class. VoiceInk: *"Screen capture and clipboard context stored in plaintext in database"* — screen content + clipboard persisted permanently into SQLite as part of the AI prompt (filed Mar 2026, since closed). https://github.com/Beingpax/VoiceInk/issues/583
- Users independently reason about cloud dependency: *"Yes, Wispr Flow is a cloud-based application. All of your voice data, dictation, and contextual AI processing happen on remote external servers."* https://news.ycombinator.com/item?id=48204030
- Scepticism about compliance badges as substitutes for architecture: *"Superwhisper got SOC2 around the same month they hired their first employee... It's a b2b checkbox."* https://news.ycombinator.com/item?id=48153270

### B3.4 Privacy is an active churn driver
- *"i didnt want to pay $12/month for wispr flow or have my audio sent to the cloud. so i built my own."* https://news.ycombinator.com/item?id=47514710
- *"Just canceled my WisprFlow subscription a few days ago to switch to a open source, free, local alternative"* (17 Aug 2026 — the same day as the $280M raise). https://news.ycombinator.com/item?id=49334327
- Local-first is the counter-positioning competitors now lead with: Spokenly's *"Local Only Mode blocks all network requests"* (https://spokenly.app/), Better Dictation's *"no cloud round-trips"* (https://betterdictation.com/), VoiceInk's *"only transcribed text (not your voice)"* leaves the device (https://tryvoiceink.com/), Handy's *"Your voice stays on your computer"* (https://handy.computer/).

## B4. PRICING BACKLASH — subscription fatigue is acute and the churn is measurable

The recurring argument is that the core function is a commodity, so a subscription is unjustifiable.
- *"wispr flow's whole product is just a voice-to-text conduit which can be replaced with a 500mb model that would have 95% of functionality for free"* (Aug 2026). https://news.ycombinator.com/item?id=49234652
- *"Built this because I got tired of paying $15/mo for Wispr Flow when all I needed was accurate dictation that runs locally."* https://news.ycombinator.com/item?id=47119223
- *"You do not need SaaS subscription in this day and age for transcription."* https://news.ycombinator.com/item?id=48965544
- *"Software like this make me questioning a lot the defensibility of products such as Wispr Flow"* — followed by a friend who built his own and *"stopped using Wispr Flow"*. https://news.ycombinator.com/item?id=48815776
- *"RIP to a lot of the paid apps that simply wrap Whisper"* — though the same commenter concedes the last mile is what you pay for. https://news.ycombinator.com/item?id=48896955
- Users sort the market explicitly by pricing model: *"VoiceInk (one time payment) and WisprFlow (subscription) are currently my fav dictation apps"* https://news.ycombinator.com/item?id=44952476 ; *"runs locally so no subscription"* https://news.ycombinator.com/item?id=43831802 ; *"doesn't want to pay for subscription (just one time payment)"* https://news.ycombinator.com/item?id=46260246
- **The one-time-purchase segment is real and well-populated:** VoiceInk $29/$49/$69 (https://tryvoiceink.com/), Better Dictation $39/$49/$149 (https://betterdictation.com/), MacWhisper ~€59, Superwhisper lifetime **$249.99** (independently corroborated by a disgruntled App Store reviewer: *"To charge $250 for lifetime buy is straight up delusion"* https://apps.apple.com/us/app/superwhisper-ai-dictation/id6471464415 ) (`UNVERIFIED: $249.99/$84.99yr/$8.49mo corroborated across several competitor-run blogs incl. https://www.getvoibe.com/resources/superwhisper-pricing/ and https://usevoicy.com/blog/superwhisper-pricing ; superwhisper.com/pricing returns 404 to automated fetch`), Handy free/MIT (https://handy.computer/).
- There is a whole tracked catalogue of open-source replacements: https://opensource.builders/alternatives/superwhisper and https://github.com/primaprashant/awesome-voice-typing (https://news.ycombinator.com/item?id=48965544)
- **Structural read: an unusually large share of this market's users are technically capable of replacing the product in a weekend, and many do.** Retention has to come from the last mile (dictionary, formatting, language handling), not the transcription.

## B5. LATENCY — the benchmark is "feels instant", and local now often wins
- The framing that matters is the **whole loop**, not model speed: *"the full loop has to feel instant"* — press shortcut → speak → release → text appears. https://news.ycombinator.com/item?id=48137064
- Local can beat the cloud leader: a user moved from Wispr Flow to **Handy running Whisper Large locally** — *"essentially as good, while also having lower latency."* https://news.ycombinator.com/item?id=48193556
- Users compare against on-device Apple STT as the latency floor: *"my iPhone can do STT with no latency pretty well fully on device, but Wispr Flow requires a cloud model"*. https://news.ycombinator.com/item?id=48193904
- Streaming vs. batch is a real complaint: *"Many software will paste whatever I said after I have stopped recording, but that is not useful."* https://news.ycombinator.com/item?id=48965889
- Vendor latency claims for reference: Willow **"as little as 200ms"** (https://willowvoice.com/); Aqua **230 WPM / "5x faster than typing"** (https://aquavoice.com/); VoiceType **360 WPM / "9x faster"** (https://voicetype.com/). None publish a methodology.
- Local models can also be far too slow on the wrong hardware: *"Streaming Parakeet unified 0.6B (GGUF) runs at 0.18-0.30x real-time on CPU"* — i.e. 3-5x slower than the speech itself. https://github.com/cjpais/Handy/issues/1754
- **Accuracy regressions happen silently in cloud products.** A user re-ran 525 identical dictation clips a month apart: *"Word Error Rate rose from 9.0% to 11.2%"*, worse in 8 of 9 categories, on plain American English. https://news.ycombinator.com/item?id=48548002 — a structural argument for local/pinned models: cloud vendors can regress your accuracy overnight with no changelog.

## B6. BATTERY / CPU / RAM — the tax on local-first
- VoiceInk: *"Performance: high CPU usage in background. Draining battery"* — drains even with **no interaction**, just autostarted in the background (Apr 2026, still open). https://github.com/Beingpax/VoiceInk/issues/672
- Direct comparison against Apple's on-device stack: Handy with Parakeet is *"a monster compared to Apple's"* in system resource usage. https://news.ycombinator.com/item?id=48193904
- Battery is a first-question buying objection: *"Does this have a high impact on battery usage?"* https://news.ycombinator.com/item?id=48973768
- Other resource/stability failures: heap corruption crashes on macOS 15 Apple Silicon (https://github.com/cjpais/Handy/issues/1944); segfault on launch enumerating audio devices on macOS 26 Tahoe (https://github.com/cjpais/Handy/issues/1643); UI beachballs while opening/closing audio devices during recording (https://github.com/cjpais/Handy/issues/1715); soft lock-up after transcription (https://github.com/cjpais/Handy/issues/1655).

## B7. PERMISSION FRICTION — grants break on rebuild/update
- macOS TCC ties Accessibility/Screen Recording grants to the **code signature**, so a changed binary silently loses them. Filed against VoiceInk: *"Local builds with 'make local' reset macOS permissions (Accessibility/Screen Recording) on every rebuild."* https://github.com/Beingpax/VoiceInk/issues/883
- Related update-channel trap: *"Local builds silently auto-update to the release build, then ask for a license."* https://github.com/Beingpax/VoiceInk/issues/829
- OS upgrades break hotkeys wholesale: *"Global Shortcut Key not working on macOS 26"* (https://github.com/Beingpax/VoiceInk/issues/735), *"default transcribe shortcut not working on macOS 26.5.2"* (https://github.com/cjpais/Handy/issues/1578).
- Users want a **reduced-permission mode**: *"Allow transcribing inside VoiceInk only without accessibility permissions."* https://github.com/Beingpax/VoiceInk/issues/776
- Contention with the OS's own accessibility stack: *"Pause macOS Voice Control while VoiceInk is recording."* https://github.com/Beingpax/VoiceInk/issues/887
- Distribution trust: on Linux the app must request **"Remote Desktop / Allow Remote Interaction"** just to type (https://github.com/cjpais/Handy/issues/273); on Windows, *"Windows Defender detected Trojan in installer of 0.9.5"* (https://github.com/cjpais/Handy/issues/1891). Combined with the Mac App Store ban (B2/M6), **every product in this category has a cold-start trust problem.**

## B8. BLUETOOTH / AUDIO-DEVICE SWITCHING — a real, under-served bug class
- *"Bluetooth microphone audio-quality limitation is not explained"* — the HFP/headset-profile downgrade wrecks accuracy and nobody warns the user. https://github.com/cjpais/Handy/issues/1885
- Mechanism: using a Bluetooth headset as a **mic** forces the "headset profile" with *"greatly reduced bandwidth and a simpler codec, hence reducing the quality of sound in both directions."* https://news.ycombinator.com/item?id=41709471
- *"Audio session activation triggers Handoff, stealing AirPods from other devices."* https://github.com/cjpais/Handy/issues/646
- iOS: *"Other apps' audio degrades to phone-call quality while VoiceInk is open (mic/audio session held when not recording)."* https://github.com/Beingpax/VoiceInk-iOS/issues/4
- *"Noticeable delay before Ready beep when non-default output device is selected."* https://github.com/cjpais/Handy/issues/703
- *"'Mute While Recording' doesn't work when using USB Audio Interface."* https://github.com/cjpais/Handy/issues/998
- Requests for device-awareness: auto-detect clamshell mode and disable the built-in mic. https://github.com/Beingpax/VoiceInk/issues/566
- On Linux the mic may only appear as "Default". https://github.com/cjpais/Handy/issues/521
- **Nobody in the matrix advertises Bluetooth-mic handling. It is a cheap, visible differentiator.**

## B9. WHAT MAKES PEOPLE CHURN vs. STAY
**Churn triggers, in observed order of frequency:** (1) subscription cost vs. a free local equivalent (B4); (2) cloud/privacy discomfort (B3); (3) a silent accuracy regression (B5); (4) missing platform — no Linux, late Windows (B2/M5); (5) breakage in the one app they live in (B2).
- *"I switched off Wispr Flow for the same reasons"* — pattern repeated by multiple builders who then shipped their own. https://news.ycombinator.com/item?id=48898466
- People run two products side by side and pick per-day: *"I use aqua and wispr flow depending on which one seems to be returning the best results that day"* — **near-zero switching cost, no lock-in anywhere in this category.** https://news.ycombinator.com/item?id=48427094
- Direct displacement between paid tools: *"I liked Superwhisper but switched to Willow as it was a big difference."* https://news.ycombinator.com/item?id=48896991

**Stickiness comes from the last mile, not the model.** The features users name as worth paying for:
- *"Automatic dictionary, seamless language switch, no issues with accents"* — *"Putting the effort in the last mile makes a world of difference."* https://news.ycombinator.com/item?id=48896955
- Custom dictionary + text-expansion shortcuts (say "linkedin link" → pastes the URL) — cited as what open source lacks. https://news.ycombinator.com/item?id=48531184
- Per-app formatting/context awareness — *"It lacks context awareness and formatting"* was the reason a rival lost. https://news.ycombinator.com/item?id=48896578
- Filler removal / LLM cleanup — *"an 'umm three, no! four!' just results in 'four'"* https://news.ycombinator.com/item?id=47559537 ; *"Wispr flow cuts out ums. I love it"* https://news.ycombinator.com/item?id=48143529
- **Agent integration is the new battleground.** Superwhisper shipped Claude/openCode plugins piping voice straight in as a prompt (https://news.ycombinator.com/item?id=47936170); Spokenly ships an MCP server for Claude Code and Cursor (https://spokenly.app/); Wispr and Monologue both expose MCP (https://wisprflow.ai/pricing, https://monologue.to/); VoiceInk has an open request for it (https://github.com/Beingpax/VoiceInk/issues/704). The dominant reported use case is now **talking to a coding agent**: *"my current workflow is literally just talking to Claude via Wispr Flow"*. https://news.ycombinator.com/item?id=47472445

---

# *** B10. THE SMOKING GUN: WISPR FLOW'S OWN DOCS RULE OUT CODE-SWITCHING ***

Wispr Flow — the $2B category leader — documents the exact failure the wedge targets. All quotes verified 2026-08-24 from https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages

1. **"Rapid language switching within a single sentence is not supported."**
2. **"Detection is per session, not per word: switch languages mid-sentence and Flow transcribes the entire segment in one language."**
3. **"Code-switching has limits: Flow works best when you speak primarily in one language with occasional words from another, rather than alternating sentence by sentence."**
4. **"With Chinese and English together, Flow may transcribe English words in Chinese characters or vice versa."**
5. **"English paired with Spanish, French, or German performs better than English paired with Chinese or Japanese."**
   → **Non-Latin-script + English is explicitly the worst-performing bucket. Thai is non-Latin script.**
6. *"Select only languages you actually use. Fewer languages means more accurate detection."*

And from the troubleshooting page, https://docs.wisprflow.ai/articles/5899191431-flow-is-transcribing-in-the-wrong-language :
7. The primary recommended fix is **"select only the language you're dictating in and remove the rest"** / **"Deselect every language except the one you're dictating in."**
8. Named failure cause: *"Accents or short phrases can push Auto-detect to the wrong language."*
9. Named failure cause: similar-sounding pairs, explicitly including **"Hindi/Hinglish"** — i.e. Wispr already recognises a code-switched variety as a known accuracy problem, and has no fix for it beyond narrowing the pool.

**Freshness check — the limitation is current, not a stale doc.** Wispr's changelog covering **31 Mar 2026 – 21 Aug 2026** contains **no entry claiming code-switching, mid-sentence switching, or auto-detect improvements.** The only language entries move the other way: the 31 Mar 2026 release added a manual language picker to the Flow Bar, with the guidance that *"If you use Flow in more than one language, manually selecting the language you're dictating in yields the best results."* https://wisprflow.ai/whats-new

**Important counter-fact — do not overclaim "no Thai support".** Wispr's own marketing says: *"Recently, Wispr improved transcription quality for German, French, Spanish, Portuguese, Italian, Hindi, and Thai to match the quality of English dictation."* https://wisprflow.ai/comparison/superwhisper-alternative
- So **monolingual Thai is claimed to be at English parity by the market leader.** The wedge is NOT "Thai support" — that box is ticked (or claimed).
- **The wedge is Thai+English inside one utterance**, which Wispr's own documentation says is not supported and which its own guidance places in the worst-performing script pairing.
- The correct competitive statement is: *incumbents can transcribe Thai, and can transcribe English, but must be told which one you are about to speak — and switching mid-sentence produces one-language output.*

---

# PART A (continued) — remaining products & OS built-ins

## A14. Willow Voice — pricing (verified)
- Free: **unlimited but on a weaker model ("Frontier Mini")**, limited personalization, **20 Scribe uses/week**. https://willowvoice.com/pricing
- Pro: **$15/user/mo, $12/mo billed annually** (unlimited "Frontier Pro" model, priority transcription). https://willowvoice.com/pricing
- Business: **$35/user/mo, $28 annual** — and this is the tier that carries **"Enforced privacy mode (zero data retention)"**, SOC 2 Type II, HIPAA. https://willowvoice.com/pricing
- **Pattern worth noting: like Wispr, Willow gates guaranteed privacy behind the business tier.** Individuals pay for convenience; only companies buy the privacy guarantee.
- No lifetime option. https://willowvoice.com/pricing

## A15. Superwhisper's strategic shift — the S1 model family (19 Aug 2026)
Announced two days after Wispr's $280M raise. https://superwhisper.com/blog/s1
- **S1-mini** — 0.6B params, **484 MB, runs locally with zero network requests**, formats transcripts and controls tone across five registers (casual→formal). 94.8% token accuracy, 11.6% text-edit error rate. **Open weights on Hugging Face.** https://superwhisper.com/blog/s1
- **S1-Voice** — **cloud-hosted** speech-to-text. Up to **46x faster than real-time**; most sub-30s dictations complete in **0.32s**; **6.8% WER** across benchmarks, 2.2% on LibriSpeech. https://superwhisper.com/blog/s1
- **S1-Language** — cloud-hosted instruction-following model for cleanup/formatting/summarisation. https://superwhisper.com/blog/s1
- **Two readings that matter:**
  1. The "local-first" incumbent has put its **best STT in the cloud**. Its local-only story is now weaker than its marketing implies.
  2. **The S1 announcement specifies no language support for any of the three models** — no multilingual claim, no language list. Consistent with an English-first build. https://superwhisper.com/blog/s1
- Also confirmed: Superwhisper ships **Claude Code / openCode agent plugins** piping voice straight in as a prompt. https://news.ycombinator.com/item?id=47936170

## A16. OS built-ins

### macOS Dictation (macOS 26)
- Free, bundled, on-device on Apple Silicon; **Thai IS available** as a dictation language (System Settings → Keyboard → Dictation → Add Language). https://support.apple.com/en-jo/guide/mac-help/mh40584/mac
- Underlying stack: SpeechAnalyzer/SpeechTranscriber includes `th_TH`; ~34-42 locales; **separate model download per language and one locale per instance** — so it has the same single-language-at-a-time constraint. https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide
- Quality on English is now genuinely strong: WER 2.12% clean / 4.56% noisy vs Whisper Small 3.74/7.95. https://lyonesse.app/blog/apple-speech-api-benchmark.html
- But users still rate it poorly against the startups: *"Apple's solution feels like it's from the last century in comparison"* (https://news.ycombinator.com/item?id=48193437); *"the one in iOS and MacOS 26 seemed pretty poor in comparison"* (https://news.ycombinator.com/item?id=48902514); *"apple's built in dictation is terrible"* (https://news.ycombinator.com/item?id=47942572).
- Its real advantage is friction and efficiency: *"Apple's uses so few system resources and runs fully on device... It's so efficient"* (https://news.ycombinator.com/item?id=48193904); *"The only advantage I find to Apple's stt is less friction"* (https://news.ycombinator.com/item?id=48195801).
- **Structural threat: Apple shipping better on-device models compresses the low end.** *"RIP to a lot of the paid apps that simply wrap Whisper"* https://news.ycombinator.com/item?id=48896955

### Windows 11 Voice Access (Win+H / voice access)
- Free, built into Windows 11 22H2+; **"uses modern, on-device speech recognition... and works even without the internet."** https://support.microsoft.com/en-us/topic/use-voice-access-to-control-your-pc-author-text-with-your-voice-4dcd23ee-f1b9-4fd1-bacc-862ab611f55d
- **Supported locales (15): English (US/UK/India/NZ/Canada/Australia), Spanish (Spain/Mexico), German, French (France/Canada), Chinese Simplified, Chinese Traditional, Japanese, Italian.** https://support.microsoft.com/en-us/accessibility/windows/voice-access/set-up-voice-access
- **THAI IS NOT SUPPORTED.** Nor is any Southeast Asian language. VERIFIED first-party 2026-08-24 — Microsoft's page states verbatim: *"Voice access is currently available in the following languages and dialects: English-US, English-UK, English-India, English-New Zealand, English-Canada, English-Australia, Spanish-Spain, Spanish-Mexico, German-Germany, French-France, French-Canada, Simplified Chinese-China, Traditional Chinese-Taiwan, Japanese, and Italian."* 15 variants across 9 languages; Thai absent. https://support.microsoft.com/en-us/accessibility/windows/voice-access/set-up-voice-access
- **Implication: on Windows, a Thai speaker has NO free OS-level dictation at all.** That is a much larger gap than on macOS, and it is the strongest single-platform argument for the wedge.

---

# PART C — POSITIONING GAPS, RANKED BY (EVIDENCE OF DEMAND x FEASIBILITY)

## Rank 1 — Bilingual code-switching, Thai+English, as a first-class primitive
**Demand evidence: very strong. Feasibility: moderate-hard (this is the moat).**
- The market leader's own docs say it is **"not supported"** and place non-Latin-script + English in the worst bucket. https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages
- The architecture blocks it for everyone else: Whisper emits one language token per window; *"switching languages is not trivially supported"* (maintainer). https://github.com/ggml-org/whisper.cpp/issues/749
- The cloud alternative excludes Thai from its code-switching model. https://developers.deepgram.com/docs/models-languages-overview
- Windows has no Thai dictation at all. macOS has Thai but one locale per instance.
- Users articulate the gap unprompted: *"built assuming you think in English"* (https://news.ycombinator.com/item?id=47254300); *"seamless language switch"* named as a paid-tier differentiator (https://news.ycombinator.com/item?id=48896955).
- **Caveat: do not sell "Thai support" — Wispr claims Thai/English parity already.** Sell *"speak Thai and English in the same sentence and get both rendered correctly, in the right script, without touching a language picker."* That claim is currently made by **nobody** except Monologue's unverified "adapts to 100+ languages mid-sentence".
- **First action: benchmark Monologue on Thai+English.** It is the only incumbent asserting mid-sentence switching. https://monologue.to/
- Technical path exists: Thonburian Whisper gets Thai WER to 6.59 (large-v3). https://github.com/biodatlab/thonburian-whisper — the missing piece is script-aware mixed decoding, not Thai ASR per se.

## Rank 2 — Developer-focused: terminals, code identifiers, and prompting coding agents
**Demand evidence: very strong. Feasibility: high (mostly engineering, not research).**
- The dominant use case has already shifted: *"my current workflow is literally just talking to Claude via Wispr Flow"*. https://news.ycombinator.com/item?id=47472445
- **Terminals are exactly where dictation breaks** — Terminal/iTerm2 hold Secure Event Input, and Wispr's own fix is to downgrade to hold-to-talk. https://docs.wisprflow.ai/articles/8841649969-fix-flow-shortcuts-blocked-by-macos-secure-keyboard-entry-secure-event-input
- **Cursor leaks Secure Event Input 4-7x/day, killing all dictation system-wide** — an unsolved, actively-painful bug in the single most popular AI IDE, Aug 2026. https://forum.cursor.com/t/cursor-leaks-secure-event-input-breaks-all-system-wide-input-taps-until-quit-or-screen-lock/167585
- VS Code on Windows silently fails. https://github.com/cjpais/Handy/issues/1946
- **A product that detects Secure Event Input and degrades gracefully (or routes text via a CLI/MCP channel instead of synthetic keystrokes) would fix a problem the $2B leader publicly cannot.**
- Everyone is racing here already (Superwhisper agent plugins, Spokenly MCP, Wispr MCP, Monologue MCP) — so speed matters, but the *terminal-reliability* angle is still open.
- Bonus: technical jargon/proper nouns/code identifiers are a known weak spot — *"Qwen3-ASR also accept vocabulary hints, which helps a lot with names and jargon"*. https://news.ycombinator.com/item?id=49100131

## Rank 3 — True local-only privacy, provable
**Demand evidence: strong. Feasibility: high.**
- The leader still **trains on individual users' audio by default** and offers **no on-device option**. https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq
- It has an unresolved reputational wound (screenshots to cloud; banned the reporter). https://modelpiper.com/blog/wispr-flow-privacy-incident
- Willow and Wispr both gate zero-retention behind business tiers. https://willowvoice.com/pricing
- Users churn on exactly this. https://news.ycombinator.com/item?id=49334327 , https://news.ycombinator.com/item?id=47514710
- **The differentiator is verifiability, not a claim** — *"There is no audit path for a user."* Spokenly's *"Local Only Mode blocks all network requests"* is the current best-in-class framing (https://spokenly.app/); open weights + open source (VoiceInk, Handy) is stronger still.
- **Combines well with Rank 1:** local also means no per-minute cloud cost for a long-tail language, and no Thai audio leaving Thailand (relevant to PDPA-conscious buyers).

## Rank 4 — One-time / lifetime pricing
**Demand evidence: strong. Feasibility: very high (a pricing decision).**
- Loud, repeated subscription fatigue (B4), and a proven willingness to pay once: VoiceInk $29-69, Better Dictation $39-149, MacWhisper ~€59, Superwhisper $249.99 lifetime.
- **But this is the least defensible advantage** — it is copyable in an afternoon, and it caps revenue against cloud inference costs. Use it as a **wedge, not a moat**, and only if inference is local (Rank 3) so marginal cost is ~zero.
- Hybrid that fits the evidence: **local model + lifetime licence; cloud/agent features as an optional add-on** (Better Dictation's $2/mo Pro add-on is the existing template). https://betterdictation.com/

## Rank 5 — Per-app formatting
**Demand evidence: moderate-strong. Feasibility: high. But contested.**
- Users name it as the reason a tool wins or loses: *"It lacks context awareness and formatting"*. https://news.ycombinator.com/item?id=48896578
- **Already table stakes**: Monologue (Slack casual / Gmail formal / code editors technical, https://monologue.to/), Superwhisper Modes (https://superwhisper.com/), VoiceType tone matching (https://voicetype.com/), Willow style-matching (https://willowvoice.com/).
- **The unoccupied version is per-app *language* policy** — e.g. Thai in Slack/LINE, English in the terminal and the IDE, mixed in docs. That composes Rank 1 with Rank 2 and nobody offers it.

## Rank 6 — Linux
**Demand evidence: moderate (vocal, small). Feasibility: LOW.**
- Real, visible demand: users repackaged Wispr Flow for Linux themselves. https://github.com/wispr-flow-linux/wispr-flow-linux
- Only Spokenly (https://spokenly.app/), Talon (X11 only, https://talonvoice.com/) and Handy (https://handy.computer/) ship it.
- **But Wayland has no working text-injection or global-shortcut story**, and it fragments per compositor — an open meta-issue and a long tail of open bugs. https://github.com/cjpais/Handy/issues/1555
- **Recommendation: deprioritise.** High engineering cost, low willingness to pay, an audience that prefers free/open-source anyway.

## Cross-cutting: cheap differentiators nobody is claiming
1. **Bluetooth-mic quality warning + auto device handling.** The HFP downgrade silently wrecks accuracy and *"is not explained"* to users. https://github.com/cjpais/Handy/issues/1885
2. **Pin the paste target to the window focused at record-start**, not at paste time — an explicit user request nobody has shipped. https://github.com/Beingpax/VoiceInk/issues/803
3. **Non-QWERTY / Thai keyboard-layout-safe injection.** Direct-paste methods assume US QWERTY and corrupt output. https://github.com/cjpais/Handy/issues/439 , https://github.com/Beingpax/VoiceInk/issues/597
4. **Pinned model versions + a published WER changelog.** Cloud vendors regress silently (9.0%→11.2% in one month). https://news.ycombinator.com/item?id=48548002
5. **Don't hold the mic session when idle** — it degrades other apps' audio and drains battery. https://github.com/Beingpax/VoiceInk-iOS/issues/4 , https://github.com/Beingpax/VoiceInk/issues/672

## Risks to the plan
- **Apple compresses the low end.** macOS 26 on-device STT is already at 2.12% WER on clean English and supports Thai; it is free and frictionless. https://lyonesse.app/blog/apple-speech-api-benchmark.html
- **No Mac App Store distribution** (guideline 2.4.5) — direct download only, so trust and discovery must be earned. https://news.ycombinator.com/item?id=48369088
- **Near-zero switching costs and no lock-in anywhere in this category** — users run two apps at once and pick per-day. https://news.ycombinator.com/item?id=48427094
- **Wispr is now funded to attack exactly this.** $280M at $2B "as it looks beyond dictation", and it has already invested in Thai specifically. https://techcrunch.com/2026/08/17/wispr-raises-280m-at-2b-valuation-as-it-looks-beyond-dictation/ , https://wisprflow.ai/comparison/superwhisper-alternative
- **A crowded commodity tier**: Handy, Hex, Ghost Pepper, OpenWhispr, FluidVoice, Careless Whisper, Whispering, Glimpse, Thinkur, Mellon, Shoute, Voibe, Floatspeak and more, tracked at https://github.com/primaprashant/awesome-voice-typing and https://opensource.builders/alternatives/superwhisper

---

---

# B11. APP STORE EVIDENCE (iOS) — traction numbers and the 1-3 star complaints

**Traction proxies, iTunes Search API, verified 2026-08-24:**
| App | iOS avg rating | # ratings |
|---|---|---|
| Wispr Flow: AI Voice Keyboard (id 6497229487) | **4.83** | **14,159** |
| Superwhisper - AI Dictation (id 6471464415) | 4.38 | 818 |
| Aqua Voice: AI Dictation (id 6759074969) | 4.39 | **75** |
| Monologue: Smart Dictation (id 6755956193) | — | 16 reviews in feed |

Source: `https://itunes.apple.com/search?term=<app>&entity=software`. **Wispr Flow's mobile install base dwarfs the field by ~17x over Superwhisper and ~190x over Aqua Voice** — the funding is buying real distribution, and the ratings are genuinely high. Do not underestimate the incumbent on core English quality.

**Wispr Flow 1-3 star reviews** (https://apps.apple.com/us/app/wispr-flow-ai-voice-keyboard/id6497229487):
- Silent regressions, corroborating the 9.0%→11.2% WER finding: *"Updates messed it up now it's trash"* — a former 5-star user, "in the last three to four weeks".
- *"Not sure what happened with the update... Now it seems about on par with the normal included voice transcriber."*
- No streaming feedback: *"Cannot see dictation in real time which makes process cumbersome."*
- Pricing dark-pattern complaints: *"It says on the website that for personal use is free but it's not. It's a 14 day trial."* and a user reporting the advertised annual discount did not exist at checkout.
- Permission friction: *"App requires complete permission to keyboards."*
- Cross-device inconsistency: *"Works well on my laptop and helpful then, but started not to work on my phone."*
- Data loss: *"Can't even record a single sentence. Just hangs up and I lost 2-3 30 Min of important monologues."*

**Superwhisper 1-3 star reviews** (https://apps.apple.com/us/app/superwhisper-ai-dictation/id6471464415):
- App-specific breakage on mobile: *"the bugs on iOS especially on WhatsApp and other apps makes this really useless."*
- Desktop/mobile quality gap: *"fantastic on the desktop... Unfortunately, the phone app is very hit or miss."*
- **Local inference is the fragile path**: *"New update crashes local inferencing"* — "keeps crashing the app when you run the local whisper model."
- Pricing revolt on both axes: *"Subscribe even for local models? Wth"* and *"To charge $250 for lifetime buy is straight up delusion."*
- Billing/support: *"No way to cancel and support never replies."*
- **The banning pattern repeats across vendors** — a Superwhisper reviewer: *"Any feedback to the developer gets censored, and they ban you."* Compare Wispr banning the user who raised the privacy issue (B3.1). **Two of the leading vendors stand accused of silencing critics; that is a reputational opening for a vendor that handles criticism in public.**

**Monologue reviews** (https://apps.apple.com/us/app/monologue-smart-dictation/id6755956193):
- Reliability: *"So inconsistent in whether it works or not."*
- **A failure mode not covered elsewhere — LLM post-processing flattens voice**: *"everything gets flattened and all tone and personality it stripped away... makes everything sound like a polite old lady."* This is the cost of the AI-cleanup layer every vendor is racing to add, and it cuts against non-native speakers hardest, whose phrasing is most likely to be "corrected" into blandness.
- Corroborates the churn-from-frustration pattern: a user *"nearly considering building my own because of how frustrated they made me"* before finding it.

## Method & confidence notes
- Sources: each product's own site and docs (first-party), Hacker News via the Algolia API (~300 comments screened), GitHub issue trackers for the two open-source leaders (Beingpax/VoiceInk ★6.1k, cjpais/Handy), Microsoft/Apple support docs, and the Cursor community forum.
- **Reddit could not be reached** — reddit.com is blocked to both WebSearch and WebFetch in this environment. r/macapps, r/MacOS, r/productivity and r/LocalLLaMA are therefore NOT covered. Recommend a manual pass.
- **App Store coverage:** guideline 2.4.5 keeps *system-wide macOS* dictation apps out of the Mac App Store, so the **desktop** products are largely unreviewable there. Their **iOS** apps are not, and were mined via the iTunes customer-reviews RSS (see B11). GitHub issue trackers remain the better corpus for desktop-specific breakage.
- **The task's break-list was not fully reproducible.** Confirmed with evidence: Electron apps, terminals (Terminal/iTerm2/Ghostty), VS Code, Cursor, JetBrains Rider, password/secure fields, 1Password, KeePassXC, WhatsApp (iOS), plus elevated Windows windows by UIPI mechanism. **Searched and NOT found:** no Excel, Figma, Office, VM (Parallels/VMware), remote-desktop (RDP/Citrix) or games complaints surfaced in the VoiceInk or Handy trackers or in HN. Those remain plausible by the UIPI/raw-input mechanisms but are `UNVERIFIED:` — treat as untested, not as cleared.
- Pricing marked `UNVERIFIED:` (MacWhisper, Dragon, Superwhisper lifetime) is corroborated across multiple secondary sources but several of those are competitor-operated SEO blogs. Re-confirm at the checkout page before using in any public comparison.
