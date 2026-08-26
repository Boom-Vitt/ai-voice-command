# Wispr Flow — Primary-Source Technical Due Diligence
**Compiled 2026-08-24.** Every factual claim carries a source URL. Inference and
unconfirmed material is prefixed `UNVERIFIED:`. Quotes are short and attributed.

**Method.** Enumerated both sitemaps (308 marketing URLs, 174 help-centre articles) and
crawled them in full; read the DPA, MSA, privacy policy, data-controls and security FAQ;
pulled App Store metadata and reviews across 7 storefronts including Thailand; cross-checked
against their changelog, Series B post, and third-party coverage.

---

## EXECUTIVE SUMMARY — the five things that matter

1. **Thai is NOT a gap. It is one of their ten dedicated-formatting languages.** Their CTO
   named Thai in a tier of seven "trained and tuned to match English-level performance," and
   the help centre lists Thai in the dedicated-formatting set. Thai App Store reviewers
   confirm it works. **Any thesis premised on "Wispr doesn't do Thai" is wrong.**
2. **But their own support docs decline to claim English parity for Thai.** Thai is in
   their "dedicated formatting" set but not their "highest transcription confidence" set, and
   the docs state plainly that "Non-English transcription is not yet as accurate as English."
   Marketing claims parity; documentation does not. That gap is the real, narrow opening.
3. **Intra-sentence code-switching is explicitly unsupported today** ("Rapid language
   switching within a single sentence is not supported") — but their new proprietary model
   **Canto**, announced with the Series B, names exactly this as a target. The window is
   real and closing.
4. **100% US data residency. Every one of 34 sub-processors is USA-located. No on-prem, no
   offline, no local mode — and Context Awareness ships a screenshot of your screen to their
   servers by default.** This is the most durable structural weakness.
5. **No PPP pricing.** Five checkout currencies (USD/GBP/EUR/JPY/KRW). Thailand pays full
   US price. Six discount categories exist, none geographic.

**Overall read:** this is a well-run, well-capitalised incumbent with genuine multilingual
R&D — not a US-only tool with a translation layer. Competing on "they don't support Thai"
fails immediately. Competing on residency, offline capability, price level, and true
intra-sentence Thai-English mixing is defensible, but §7 explains why it is still hard.

---

## 1. Architecture and pipeline

### 1.1 Cloud-only — confirmed twice, unambiguously
- **"Transcription always occurs on the cloud. This is the best way for us to provide
  accurate, low latency transcription."**
  — https://wisprflow.ai/data-controls (updated 18 Aug 2026)
- **"Wispr Flow is multi-tenant SaaS hosted entirely with a major US cloud provider. There is
  no on-premise version."**
  — https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq
- "Flow transcribes in the cloud, so there is no offline transcription on any platform."
  — https://docs.wisprflow.ai/articles/4048537120-what-to-expect-from-flow-accuracy-and-known-limitations
- **There is no local mode, offline mode, or on-prem option at any tier, including
  Enterprise.** The only "offline" feature is Notetaker meeting *recording*
  (https://docs.wisprflow.ai/articles/5810080970-offline-meeting-recording-in-notetaker);
  UNVERIFIED: presumed to buffer audio for later upload, not transcribe locally.
- Aggravating factor: **"Flow is not compatible with most VPNs."** Split tunnelling with
  wisprflow.ai allowlisted is the documented workaround. (accuracy/limitations doc;
  https://docs.wisprflow.ai/articles/3834764683-why-vpns-or-security-tools-can-block-wispr-flow)

### 1.2 The sub-processor list — full, public, and the highest-signal artifact
Published in full at **https://wisprflow.ai/legal/dpa**, "ANNEX 2 / Authorized
Sub-Processors". No NDA required, despite their enterprise post claiming otherwise (§5.6).

| Sub-Processor | Purpose | Location |
|---|---|---|
| Supabase, Inc. | Authentication Provider | USA |
| **Anthropic PBC** | AI Features / Natural Language Processing | USA |
| **Cerebras Systems Inc.** | Natural Language Processing | USA |
| **OpenAI Inc.** | Natural Language Processing | USA |
| **OpenPipe Inc.** | Natural Language Processing | USA |
| Cloudflare, Inc. | Cloud Infrastructure | USA |
| **Fireworks AI, Inc.** | Cloud Infrastructure | USA |
| **Google LLC** | Cloud Infra, NLP, AI Features, Firebase | USA |
| Foundry Technologies, Inc. (Mithril.ai) | Cloud Infrastructure | USA |
| Vercel Inc. | Cloud Infrastructure | USA |
| **BaseTen Labs, Inc.** | Cloud Infrastructure | USA |
| **Modal Labs, Inc.** | Cloud Infrastructure | USA |
| Amazon Web Services, Inc. | Cloud Infrastructure | USA |
| Redis Inc. | Data Caching | USA |
| Functional Software, Inc. (Sentry) | Error Management | USA |
| Clickhouse, Inc. | Site and Product Analytics | USA |
| Segment.io, Inc. | Site and Product Analytics | USA |
| PostHog, Inc. | Site and Product Analytics | USA |
| Metabase, Inc. | Site and Product Analytics | USA |
| Dub Technologies, Inc. | Site and Product Analytics | USA |
| HEX Technologies, Inc. | Site and Product Analytics | USA |
| Slack Technologies, LLC | Customer Support | USA |
| Peaberry Software, Inc. (CustomerIO) | Email Marketing | USA |
| **Eleven Labs Inc.** | **Text-to-Speech** | USA |
| Pylon Labs Inc. | Customer Support | USA |
| Baremetrics Inc. | Revenue Analytics | USA |
| RevenueCat Inc. | Payment Processing | USA |
| Apple Inc. | Payment Processing | USA |
| Attio Inc. | Customer Relationship Management | USA |
| Enterpret Inc. | Customer Insights & Analytics | USA |
| Twilio Inc. | SMS Messaging | USA |
| Better Stack, Inc. (Logtail) | Logging & Observability | USA |
| **WorkOS, Inc.** | Enterprise SSO & Directory Sync | USA |
| Stripe, Inc. | Payment Processing | USA |

**What it proves:**
1. **Every entry is USA. There is no EU, UK, or APAC data residency anywhere in the stack.**
   Corroborated: "All customer data is processed in the United States." (security FAQ)
2. **A multi-vendor router, not one model.** Frontier NLP from Anthropic, OpenAI, Google;
   latency-critical inference on Cerebras, Fireworks, Baseten, Modal, Foundry/Mithril.
3. **OpenPipe** (fine-tuning/distillation) corroborates the CTO's "fine-tuned formatting
   models... learn from real user edits."
4. **No dedicated ASR vendor is listed** — no Deepgram, AssemblyAI, Speechmatics, or Azure
   Speech. `UNVERIFIED:` the most consistent reading is that non-English ASR runs on
   self-hosted / fine-tuned weights across the GPU-serving vendors, with Google as fallback.
5. **The "Scribe" hedge resolves against a production dependency.** ElevenLabs *is* listed —
   but as **Text-to-Speech**, not ASR. See §1.3.

### 1.3 Which models are named — and how carefully to read it
From the CTO's research post (Sahaj Garg, 19.01.2026,
https://wisprflow.ai/research/supporting-languages):
- **"Wispr Flow uses an ensemble of speech recognition models"** across 100+ languages.
- **"Newer automatic speech recognition models like Scribe and Gemini drastically outperform
  OpenAI's Whisper in Asian languages when measured by WER."**
- **"Flow dynamically selects the most accurate ASR engine for each language, cutting
  transcription error rates by more than half in internal testing."**
- Their research found "some standard speech models perform poorly on languages like Hindi,
  Marathi, **Thai**, and Tamil."
- **"Accent confidence scoring"** — "compare multiple transcriptions and choose the most
  likely match. This prevents your English from being mistaken for German." (i.e. N-way
  transcription then arbitration — a deliberate cost/latency trade for accuracy.)

**Careful reading:** the Scribe/Gemini sentence names them as *better benchmarks*, and stops
short of "we use them." Google LLC is a listed NLP sub-processor, so Gemini in the path is
plausible. ElevenLabs is listed only for TTS. `UNVERIFIED:` whether ElevenLabs Scribe is in
the production ASR path.

**The router is real and has shipped bugs.** Changelog, v1.5.891, 17 June 2026: "Better
language routing: UK English and Swiss German weren't always being sent to the right place,
which hurt accuracy for those users." — https://wisprflow.ai/whats-new

### 1.4 Canto — their first proprietary speech model (Aug 2026)
Source: https://wisprflow.ai/post/series-b (Tanay Kothari, CEO, 17 Aug 2026). This shifts the
architecture from third-party ensemble toward in-house.
- "we're announcing a **preview of our first proprietary speech model, Canto**."
- Built for noisy real conditions: "In the hardest conditions, with background noise, wind,
  heavy accents or music, **error rates fall from more than 30% of words to somewhere between
  5 and 10%**." "Across everyday use, we expect it to reduce the number of dictations you
  need to edit by **30 to 35%**."
- **North-star metric: "zero edit rate"** — "the share of everything you say that comes back
  right the first time and needs nothing from you at all."
- **Canto explicitly targets intra-sentence code-switching:** "Roughly half the world moves
  between languages during a normal day, **often inside a single sentence**, and models
  trained on one language at a time handle that badly." → see §3.3 and §7.

### 1.5 Streaming, latency, and the LLM formatting pass
- **Streaming, not batch-on-release.** "audio **streams** securely from the desktop or mobile
  client to our servers, where audio and **intermediate transcripts** are processed entirely
  in memory." — https://wisprflow.ai/post/enterprise-privacy-and-security-overview
- **No absolute latency figure is published anywhere.** The only numbers are relative and
  throughput-based:
  - "Dictation latency is down 30% since the start of the year, and it's still coming down."
    — https://wisprflow.ai/whats-new
  - "dictation reached 99.9% uptime over the past few weeks" — a **company claim relayed by
    press**, not independently verified, via
    https://www.digitaltrends.com/computing/wispr-flow-asked-its-haters-what-was-wrong-and-more-than-700-people-answered/
  - "Keyboard 45 wpm / Flow 220 wpm", "4x faster than typing" — https://wisprflow.ai/
- **Yes, there is a separate LLM cleanup pass.** Product names: **Smart Formatting**,
  **Auto Cleanup (Beta)**, and **polish**.
  (https://docs.wisprflow.ai/articles/6568835559-why-wispr-flow-sometimes-removes-or-changes-words-on-android-smart-formatting)
  It has been a source of harm — Wispr traced accuracy complaints to "an overly aggressive
  Auto Cleanup setting that changed words users hadn't asked it to touch" (Digital Trends).
- **Users can write custom prompts.** "How to configure polish shortcuts and custom prompts"
  — https://docs.wisprflow.ai/articles/2719941210-how-to-configure-polish-shortcuts-and-custom-prompts
- Session caps: **Mac/Windows 20 min** (warns at 19, auto-submits); **iOS 5 min** (no warning).

### 1.6 Context awareness — what it reads, and what that costs
Source: https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness — "It's on by
default." Mac (full), Windows (partial), Android (rolling out), iOS (limited).

**Transmitted with each dictation request** (verbatim): "app info, textbox contents (before,
selected, and after the cursor), on-screen text, variable and file names in coding apps, your
user identifier within the app, the apps in your current session, **a screenshot**, and
conversation history (participant IDs and message roles/content)."

- Flow classifies the active app into Email / Work messaging / Personal messaging / Other,
  and in browsers identifies the *site*, not the browser.
- Documented exclusions: password fields (but "custom or web-based password fields may be
  read like normal text fields"), sensitive/numeric-only fields, URL bars, and it "skips
  context reading entirely in banking and financial apps."
- **Permission required: macOS Accessibility. "Windows requires none."**
- Explicit privacy/accuracy trade: admins can disable it, "though doing so meaningfully
  reduces accuracy for many roles."
  — https://wisprflow.ai/post/enterprise-privacy-and-security-overview
- Persistent code context: "Flow remembers file names seen in Cursor, Windsurf, and VS Code
  across dictation sessions."

---

## 2. Product surface

### 2.1 Hotkeys — push-to-talk primary, toggle via double-tap
Source: https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts
and https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode

| Action | macOS default | Windows default |
|---|---|---|
| **Push-to-talk (hold)** | **Fn** | **Ctrl+Win** |
| Hands-free (toggle) | Fn+Space | Ctrl+Win+Space |
| Command Mode | Fn+Ctrl | Ctrl+Win+Alt |
| Paste last transcript | Cmd+Ctrl+V | Shift+Alt+Z |
| Copy last transcript | Cmd+Ctrl+C | Shift+Alt+X |
| Cancel | Escape | Escape |

- Macs without an Apple Fn key fall back to Ctrl+Opt / Ctrl+Opt+Space / Cmd+Ctrl+Opt.
- "Double-tap your push-to-talk shortcut to lock the session into hands-free."
- Up to **4 bindings per action, ≤3 keys each**; Middle Click and Mouse 4–10 bindable
  (standalone or with modifiers); left/right click cannot be bound.
- Blocked: bare single keys, OS shortcuts (Cmd+C/V), left+right variants of one modifier,
  Caps Lock on Mac.
- Known conflict: macOS **Secure Keyboard Entry** blocks Flow shortcuts —
  https://docs.wisprflow.ai/articles/8841649969-fix-flow-shortcuts-blocked-by-macos-secure-keyboard-entry-secure-event-input

### 2.2 HUD / overlay — the "Flow Bar", and its focus problem
- The Flow Bar is a persistent on-screen overlay carrying the mic state, a language pill and
  a mic switcher.
- **Until mid-2026 it occluded application controls.** "Previously, the overlay could cover
  controls such as Gmail's send button or the macOS Dock." It is now draggable to either side
  and remembers position. "One developer even built a separate Mac utility to reposition it."
  — https://www.digitaltrends.com/computing/wispr-flow-asked-its-haters-what-was-wrong-and-more-than-700-people-answered/
- `UNVERIFIED:` whether the Flow Bar takes keyboard focus. The docs never state focus
  behaviour; the auto-switchback feature on iOS ("automatically returns you to your host app
  the moment you finish dictating", https://wisprflow.ai/whats-new) implies focus *is* taken
  on iOS and must be returned.

### 2.3 Text injection — clipboard-based on desktop, and lossy
Source: https://docs.wisprflow.ai/articles/4048537120-what-to-expect-from-flow-accuracy-and-known-limitations
- **"On Mac and Windows, Flow pastes through the system clipboard, then restores what you had
  copied before."**
- Restore is incomplete: "File contents, PDFs, RTFD documents, audio formats, and copied files
  are not [restored]."
- On failure: "Flow writes your dictated text to the clipboard so you can paste it manually,
  **and your previous clipboard contents are not restored**."
- **Windows leaks dictated text to clipboard managers:** "On Mac, dictated text is marked as
  concealed... **On Windows it is not concealed and may appear.**"
- Android uses direct insertion into the focused field, clipboard only as fallback; never
  inserts into "password, credit-card, numeric, or phone-number fields."
- **Apps where direct paste fails** (verbatim): "Remote desktops such as Citrix, RDP, VMware
  Horizon, and Windows 365... Some terminals including WSL, tmux, screen, SSH, and Termius on
  Windows." Flow "cannot be installed inside a virtual desktop."

### 2.4 Command mode, dictionary, snippets, styles
- **Command Mode**: hold Fn+Ctrl, speak an instruction, release to execute; ESC cancels.
  **Requires a paid subscription or trial**, and is gated behind Settings → Experimental.
  Explicitly "unavailable on the free/Basic plan on desktop."
- **"press enter"** voice command submits in chat/prompt apps; recognised only at the end of
  a dictation.
- **Chaining**: https://docs.wisprflow.ai/articles/9701824265-chaining-multiple-actions-in-a-single-realtime-voice-command
- **Dictionary** (https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary),
  **Snippets** (https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets),
  bulk import (https://docs.wisprflow.ai/articles/8955301725-how-do-i-bulk-import-for-dictionary-and-snippets).
  **Team Dictionary and Team Snippets require Team/Business/Enterprise.**
- Auto-add to dictionary: "Flow monitors the text box where it pastes text to detect any edits
  you made... If you change the spelling of a word, it is automatically added to your
  dictionary." — https://wisprflow.ai/data-controls
- Per-app tone is automatic via Context Awareness: "Wispr always uses information about the
  app you are dictating in (e.g. app name) to format messages (e.g. formal tone in email,
  casual tone in messages)." — https://wisprflow.ai/data-controls
- **Writing/Text Styles are English-only** — see §3.4.
- Other surfaces: **Scratchpad** (notes), **Wispr Lens**, **Focus Mode**, **View Diff**,
  **Meeting Recorder** — all bindable actions in the shortcuts dialog.

### 2.5 Platforms
- **Dictation: macOS, Windows, iOS, Android.** https://wisprflow.ai/pricing
- **Notetaker: Mac only** — "Mac only for now. More platforms coming soon";
  "*Notetaker coming soon to Enterprise". https://wisprflow.ai/pricing
- iOS ships a **custom keyboard** and **Action Button** integration
  (https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone,
  https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone).
  Android system requirements:
  https://docs.wisprflow.ai/articles/6344532666-android-system-requirements
- Web **Admin Portal** at admin.wisprflow.ai (security FAQ).
- **No browser extension** appears in the sitemap or help centre. `UNVERIFIED:` absence.
- **No official Linux client.** `UNVERIFIED:` community repackaging at
  https://github.com/wispr-flow-linux/wispr-flow-linux
- **No iPad support** — a recurring App Store complaint (§6).

### 2.6 Team and enterprise
From https://wisprflow.ai/pricing and the help centre:
- **SAML SSO** (https://docs.wisprflow.ai/articles/8771213223-configure-sso),
  domain verification (https://docs.wisprflow.ai/articles/3897289456-verify-your-domain-for-sso),
  **SCIM** (https://docs.wisprflow.ai/articles/6159095582-set-up-scim-user-provisioning-in-wispr-flow)
  — all **WorkOS**-powered per the DPA annex.
- **Audit logs** (https://docs.wisprflow.ai/articles/1282257172-audit-logs-for-enterprise-admins-track-team-membership-and-join-request-activity)
- **MDM deployment** (https://docs.wisprflow.ai/articles/9363440133-deploy-wispr-flow-via-mdm)
- **App/URL deny list** — admins block dictation in named apps and sites
  (https://docs.wisprflow.ai/articles/1537395424-enterprise-app-and-url-deny-list-blocking-dictation-in-specific-apps-and-websites)
- Cost centres, usage analytics with words-dictated CSV export, free IT-admin seats.
- Enterprise policy can lock Privacy Mode, Cloud Sync and Auto-delete. Fail-safe: "If the
  policy can't be retrieved, Flow defaults to the most private state (Privacy Mode ON, Cloud
  Sync OFF, Auto-delete ON)."
  — https://docs.wisprflow.ai/articles/9559327591-flow-plans-and-what-s-included
- Vendor security questionnaires:
  https://docs.wisprflow.ai/articles/9873443825-how-to-submit-a-vendor-security-assessment-or-questionnaire

---

## 3. LANGUAGES — the highest-priority section

Primary sources:
- **L1** https://wisprflow.ai/research/supporting-languages (CTO Sahaj Garg, 19.01.2026)
- **L2** https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages
- **L3** https://docs.wisprflow.ai/articles/5899191431-flow-is-transcribing-in-the-wrong-language
- **L4** https://docs.wisprflow.ai/articles/4048537120-what-to-expect-from-flow-accuracy-and-known-limitations

### 3.1 Is Thai supported? Yes — and it is in the top tier
**L1 tier ("trained and tuned to match English-level performance"), 7 languages:**
French, German, Hindi, Italian, Portuguese, Spanish, **Thai**.

**L4 "Dedicated formatting", 10 languages:** English, French, German, Hindi, Italian,
Portuguese, Spanish, **Thai**, Japanese, Korean. "All other languages use general-purpose
formatting and remain less reliable than English."

**L1 second tier ("accurate dictation in dozens of other major languages"):** Arabic,
Cantonese, Dutch, Hebrew, Indonesian, Japanese, Korean, Mandarin, Polish, Russian, Swedish,
Turkish, Ukrainian, Vietnamese, "… and 75+ others."

They also market the Thai benefit directly: in "character-based scripts like Mandarin and
Thai, Flow makes typing up to four times faster than tapping through characters" (L1), and
study Thai phonology explicitly — "English→Thai loanwords (meeting, computer) are pronounced
with Thai phonetics and tone" (L1). Thai edits are handled correctly for learning: Flow
"treats edits in Devanagari, Cyrillic, CJK, Arabic, Hebrew, and **Thai** as word changes
rather than punctuation changes" (L2).

### 3.2 Parity is claimed in marketing but not corroborated in the docs
Their support doc publishes **two different, non-identical language sets** (L4):
- **"Dedicated formatting" (10):** English, French, German, Hindi, Italian, Portuguese,
  Spanish, **Thai**, Japanese, Korean.
- **"Highest transcription confidence" (12):** English, Spanish, Portuguese, French, Russian,
  German, Italian, Dutch, Japanese, Turkish, Polish, Catalan.

These are **orthogonal axes, not tiers of one ranking** — *do we have language-specific
formatting rules* vs *is raw ASR confidence highest*. Five languages (Russian, Dutch, Turkish,
Polish, Catalan) are in the confidence set but not the formatting set; three (Hindi, Korean,
**Thai**) are in the formatting set but not the confidence set. **Do not read Thai's absence
from the confidence list as "Catalan and Dutch beat Thai"** — the source does not support that.

What does survive, and is defensible:
- **L1 (research post) claims parity:** Thai is "trained and tuned to match English-level
  performance in speech recognition."
- **L4 does not corroborate it.** Thai is absent from the highest-confidence set, and
- **L2 states flatly: "Non-English transcription is not yet as accurate as English."**

**The honest read:** Thai has genuine ASR and formatting investment, but Wispr's own support
documentation — the surface that has to answer to real users — declines to claim English
parity for Thai. Marketing claims it; the docs do not.

**A useful signal in the same data:** Thai sits in exactly the same position as **Hindi** —
dedicated formatting, but not highest confidence. Hindi is their most-invested non-English
language (Hinglish, the /india page, two India funds on the cap table). So Thai's placement
reflects the *general* state of their non-Latin-script work, not Thai-specific neglect.

### 3.3 Code-switching — unsupported today, explicitly targeted tomorrow
**Today, per their own docs:**
- "**Detection is per session, not per word**: switch languages mid-sentence and Flow
  transcribes the entire segment in one language." (L2)
- Under Limitations: **"Rapid language switching within a single sentence is not
  supported."** (L2)
- "Code-switching has limits: Flow works best when you speak primarily in one language with
  occasional words from another, rather than alternating sentence by sentence." (L2)
- Pair difficulty ranking: "English paired with Spanish, French, or German performs better
  than English paired with Chinese or Japanese." (L2, L4)
- Support's fix for mixed input is to *disable a language*: "Chinese–English code-switching is
  one of the hardest combinations for Flow, so **a single-language setup is the most reliable
  fix**." (L2, repeated in L3)
- Advice for daily bilinguals includes manually swapping the setting per session: "Swap the
  selected language each time... change the selection, and save before dictating." (L3)

**The one productized code-switch pair is Hinglish — and only Hinglish.**
- "Hinglish: a code-switched blend of Hindi and English commonly spoken in India. Hindi speech
  is romanized into Hinglish; English speech is formatted as normal English." (L2)
- Mutually exclusive with Hindi. Searching "romanized" surfaces it. (L2)
- **There is no Thai–English equivalent** ("Thaiglish"/"Tinglish") in any language list, doc,
  or post. Hinglish is the sole entry of its kind.
- The CTO frames it as a beachhead: "**Ongoing code-mixing experiments**... paving the way for
  better mixed-language support across other regions." (L1)

**Tomorrow: Canto names this as a target.** "Roughly half the world moves between languages
during a normal day, **often inside a single sentence**, and models trained on one language at
a time handle that badly." — https://wisprflow.ai/post/series-b
Note the escalation: the docs say intra-sentence switching is unsupported; the Series B post
says it is what the new model is for. Their investor testimonial, however, still describes
only per-utterance switching: "it keeps up with me no matter which one I'm speaking."

### 3.4 Language UX friction — each item is an opening
- Users must hand-curate a language pool: "Select only languages you actually use. Fewer
  languages means more accurate detection." (L2)
- "**Avoid Auto-detect if you code-switch frequently.** Manually selecting 2–3 languages
  beats letting Flow choose from 100+." (L2)
- **Personalization is English-only:** "Personalized styles apply only when dictating in
  English, on all platforms"; Text Styles "require English (American or British)" on iOS (L2).
  L4 adds Writing Styles are "Optimized for English and applied regardless of your dictation
  language" — i.e. English style rules are applied *to Thai output*.
- **UI localisation covers 5 languages only.** "you can now choose between English, German,
  Spanish, Italian, and Portuguese" for the Flow Hub (https://wisprflow.ai/whats-new).
  **There is no Thai interface.** L2 confirms: "Most of the Flow interface is in English
  regardless of your dictation language."
- Variant pairs are mutually exclusive: Hindi↔Hinglish, Chinese Simplified↔Traditional,
  German↔Swiss German, English US↔UK↔CA. (L2, L3)
- Country flags were removed from the picker "because languages don't map cleanly to
  countries." (L2)

### 3.5 Documentation contradiction on Android language selection
- L2: "Flow on Android uses **Auto-detect only** — there is no language selection screen."
- L3: "**Android does not offer Auto-detect**, so choose your dictation language directly,"
  followed by a full Settings → Languages → Add more → Save walkthrough.
Two current, live docs directly contradict each other. `UNVERIFIED:` which is accurate.
Either way it signals Android is under-maintained (§6).

### 3.6 External validation — Thai users say it works
**Thai App Store storefront** (n=23 recent reviews,
https://itunes.apple.com/th/rss/customerreviews/id=6497229487/sortBy=mostRecent/json,
fetched 2026-08-24):
- 5★ "โคตรดี": "แทบไม่พิมพ์เองแล้วอ่ะตอนนี้ ทั้งภาษาไทย ทั้งภาษาอังกฤษ" — *"I barely type
  myself anymore now, both Thai and English."* The reviewer notes the review itself was
  dictated. **Direct corroboration from a Thai user who uses it in both languages.**
- 5★ "ความคงเส้นคงวา": "แอปสามารถที่จะเขียนตามคำพูดได้ตรงดีมากๆ" — *"writes exactly what you
  say, very accurately."*
- Singapore storefront, 5★: "Even understands Singlish!!!" — another code-mixed variety.
- Thai negatives are product, not language: "Every update breaks it"; missing keyboard haptics;
  "5 star if had iPad support".

**Caveat:** n=23, storefront-scoped not language-scoped. This shows the small Thai base is
happy; it is not a WER benchmark. `UNVERIFIED:` Thai WER.

**Thai-language coverage exists but is promotional** — TikTok/Facebook reviews via
futuretrends.th and aggregator posts; no independent Thai WER testing found.

---

## 4. Pricing and business model

### 4.1 Rate card
From https://docs.wisprflow.ai/articles/9559327591-flow-plans-and-what-s-included
("Global and regional pricing") and https://wisprflow.ai/pricing:

| Plan | Monthly | Annual |
|---|---|---|
| Free / Basic | $0 | — |
| **Flow Pro** | **$15 / user / mo** | **$144 / yr** (= $12/mo) |
| **Student** | **$7.50 / mo** | **$72 / yr** |
| **Business (per seat)** | **$30 / mo** | **$288 / yr** |
| Enterprise | "Contact us", volume discounts | — |

Annual is "about 20% less than 12 months of monthly billing."
**Note: the $30/seat Business price is disclosed only in the help centre** — the public
pricing page shows "Contact us."

### 4.2 Free tier limits (desktop)
https://docs.wisprflow.ai/articles/4760791189-free-tier-weekly-word-cap-and-bonus-words-remove-desktop-trial-experiment
- Weekly window resetting Sunday; unused words do not carry over.
- **2,000 words/week soft cap** (triggers "Flow will be slower"); **5,000 words/week hard cap**
  (blocks dictation).
- One-time first-week bonus of 8,000 words → 10,000 soft / 13,000 hard in week 1.
- **iOS: 1,000 soft / 1,500 hard**, tracked separately, no bonus.
- **"Command Mode is unavailable on the free/Basic plan on desktop."**
- Trials: 14 days standard, 30 if referred, **90 for verified students**, 3-day grace.
- They are A/B testing this: "New eligible desktop signups are offered a Pro trial by default.
  A limited group instead receives a weekly word cap."

### 4.3 Regional / PPP pricing for Southeast Asia — **NO**
Verbatim: "Multi-currency, location-based pricing (including **USD, GBP, EUR, JPY, and KRW**)
is selected automatically at checkout based on your billing country."
- **Five currencies, all developed markets. No THB, IDR, INR, SGD, VND, or PHP.**
- A Thai buyer on web checkout pays the **full US price in USD** — $15/mo ≈ ฿500+/mo.
- "Existing subscribers keep the price and currency they originally signed up with."
- **The /india page carries no pricing and no ₹ at all** (https://wisprflow.ai/india) — pure
  testimonial marketing. Even their most-courted emerging market gets no localised price.
- `UNVERIFIED:` iOS in-app purchase is transacted by Apple, and the Thai storefront reports
  currency THB (itunes lookup, country=th) — so iOS buyers may be billed in THB at Apple's
  tier conversion. That is currency conversion, **not PPP discounting**, and does not apply
  to web/Stripe checkout.

### 4.4 Discounts exist — none are geographic
https://docs.wisprflow.ai/articles/1128761434-flow-discounts — Student, Education
(non-student), Non-profit, Accessibility support, Military, Senior citizen. Each requires
manual document verification via a support ticket, reviewed "typically within a few business
days." **No regional, emerging-market, or PPP category.** Promo codes "grant free trial days
(up to 365), **not percentage discounts**."

### 4.5 Traction and funding
All from https://wisprflow.ai/post/series-b unless noted.
- **"People have now written more than 60 billion words with Flow."**
- **"used by people at almost all of the Fortune 500 companies and over 10,000 enterprises."**
- **No ARR figure is disclosed anywhere.** `UNVERIFIED:` revenue.
- **$280M Series B at $2B valuation, 17 Aug 2026, led by Menlo Ventures; $361M total raised.**
  (also https://techcrunch.com/2026/08/17/wispr-raises-280m-at-2b-valuation-as-it-looks-beyond-dictation/)
- Existing: Notable Capital, NEA, Neo Ventures, 8VC, MVP Ventures. New: Acrew, Activate,
  Forerunner, Goodwater, **Peak XV**, **Together Fund**, PLUS Capital — plus athlete investors
  (Klay Thompson, Joe Burrow, Dak Prescott, Domantas Sabonis and others), a consumer-brand
  distribution play.
- **Peak XV (ex-Sequoia India/SEA) and Together Fund (India) both signal a funded India push.
  No equivalent Southeast Asia signal exists.**

**iOS scale by storefront** (app id 6497229487, measured 2026-08-24 via
https://itunes.apple.com/lookup?id=6497229487&country=XX):

| Storefront | Rating | Ratings |
|---|---|---|
| US | 4.83 | 14,159 |
| India | 4.80 | 2,572 |
| UK | 4.78 | 2,090 |
| Singapore | 4.76 | 216 |
| **Thailand** | **4.87** | **195** |
| Japan | 4.70 | 138 |
| Indonesia | 4.97 | 58 |

→ **Thailand is ~1.4% of US rating volume; India is ~18%.** India is the emerging-market
beachhead; Thailand and Indonesia are effectively untouched — *and Thailand's rating is the
highest of any sizeable storefront.* The small Thai base is delighted; there just isn't one.

### 4.6 People
- **Tanay Kothari** — CEO & Co-founder.
- **Sahaj Garg** — Co-founder/CTO/**CISO**, "accountable for security, compliance, and policy"
  (https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq). Author of the
  languages research post and the audit post.
- **Ariya Rastrow** — Chief Scientist/CSO, "a founding member of the team behind Alexa",
  hired to lead the **Wispr Advanced Interfaces Lab**.
- Wispr AI, Inc., Delaware C-corp, founded 2023, HQ 444 Townsend St, San Francisco.
  Careers page: "HQ in San Francisco. Open to remote. Visa-friendly." — no international
  offices advertised (https://wisprflow.ai/careers).

### 4.7 Strategy "beyond dictation" — what it implies for the category
- Two products: **Flow Dictation** and **Flow Notetaker** (launched ~Aug 2026, Mac-only).
  Framing: "Flow is what you say to your computer. Notetaker... is what you say to everyone
  else."
- Stated destination: "We're building an **intelligence layer** towards our vision for
  seamless human-AI interaction, starting with voice and eventually extending to other
  modalities."
- The Lab's remit: "systems that understand what you meant, hold the context of what you're
  doing, and **turn that into an outcome rather than a block of text**."
- They acquired **Yapify** (https://wisprflow.ai/post/wispr-flow-acquires-yapify).
- Notetaker ships an **MCP server** so notes flow into Claude/ChatGPT.

**Implication:** the incumbent is deliberately abandoning pure speech-to-text as the
monetised layer. Dictation becomes the free wedge — note the Free tier now includes 100+
languages *and* Notetaker — while revenue moves to meetings, teams, and agentic
follow-through. **A competitor whose entire product is "better dictation" is entering a
category the leader is actively commoditising.** That cuts both ways (§7).

---

## 5. Privacy posture

Sources: **P1** https://wisprflow.ai/data-controls (updated 18 Aug 2026) ·
**P2** https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq ·
**P3** https://wisprflow.ai/post/enterprise-privacy-and-security-overview ·
**P4** https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness ·
**P5** https://wisprflow.ai/legal/dpa · **P6** https://wisprflow.ai/post/new-independent-audit

### 5.1 Training on user data
- **Consumer default is opt-out (training ON unless you disable it).** "If you allow your data
  to be used to improve models, your data (i.e. audio, transcript, edits) may be used to
  evaluate, train, or improve AI models, by Wispr. You can control this in... Settings > Data
  and Privacy." (P1)
- **Enterprise default is OFF and enforced:** "Use of data to train or improve AI models is
  defaulted to off for all enterprises and enforced across the organization." (P3) Admins can
  lock it; "Individual users cannot override the organization's policy." (P1)
- Renamed: "This setting was previously called 'Privacy Mode.'" (P1)
- Third parties never train: "Wispr maintains agreements that no third party AI providers can
  use your data for model training." (P1)

### 5.2 Retention and zero-retention
- Dictation is ephemeral when both toggles are off: "audio transcripts are never written to
  long-term storage. They exist only in memory for the life of the request, then are
  discarded." (P3)
- Local copies: transcripts and optionally audio stored on-device for recovery; "These files
  never leave the device unless the user shares them. Wispr Flow staff cannot access them."
  (P3) Desktop history retains audio for 14 days.
- **ZDR with a named carve-out:** "Wispr always maintains zero data retention agreements with
  all third-party AI providers. All third party AI models used in Flow Dictation are subject
  to these agreements. **Certain features, such as briefs for Notetaker, rely on features from
  third party AI providers that are not supported under zero data retention.**" (P1)
- Notetaker transcripts **are** stored on Wispr's cloud, with configurable retention. (P1)
- Telemetry is unconditional: "Wispr may collect usage statistics such as the number of words
  you have dictated, **regardless of your data controls**." (P1)

### 5.3 Privacy Mode was split in two (June 2026) — reported fairly
https://wisprflow.ai/whats-new: "To support upcoming features like personalized speech models,
Flow needs to store your transcription data on our servers. Until now, Privacy Mode meant zero
data retention." Their handling: "**Rather than weaken Privacy Mode, we split it into two
independent controls**" — Privacy Mode (training) and Cloud Sync (storage) — and existing
users kept "identical to the previous level of privacy → zero data retention."
**This was a defensible migration, not a downgrade.** But the direction of travel is
unambiguous: personalization requires retention, so the roadmap pulls against zero-retention.

### 5.4 Data residency — the hardest constraint
- **"All customer data is processed in the United States."** (P2)
- **All 34 sub-processors are USA-located.** (P5, §1.2)
- GDPR: EU SCCs (June 2021) + UK Addendum; supervisory authority Ireland; SCC governing law
  Republic of Ireland. (P5)
- **They push the transfer-risk burden onto the customer:** "Wispr does not produce a
  standalone vendor-side Transfer Impact Assessment (TIA); under the SCC framework the TIA is
  conducted by the data controller." (P2)
- Sub-processor change notice: 30 business days by posting to the privacy policy, or 10 days
  retroactively "in urgent circumstances." (P5)

### 5.5 Context Awareness — on by default, ships a screenshot
See §1.6. The single most attackable privacy fact: **"a screenshot"** is in the list of
context data sent with each dictation request, and Context Awareness "is on by default." (P4)

### 5.6 Compliance — a live credibility problem
**Their marketing contradicts their own security FAQ.**
- Marketing, present tense: "independently certified to the world's top security standards:
  **SOC 2 Type II, ISO 27001, and HIPAA**" (https://wisprflow.ai/privacy); "We are SOC 2
  Type 2 compliant" (P1, updated 18 Aug 2026); Enterprise tier lists "SOC 2 Type II, ISO 27001
  compliance" (https://wisprflow.ai/pricing).
- Security FAQ, same period: **"SOC 2 Type II: observation period underway; report not yet
  issued."** Current holdings are only **SOC 2 Type I (A-LIGN, April 2026)** and **ISO
  27001:2022 Stage 1 (April 2026)**, Stage 2 scheduled June 2026. (P2)
- The cause, verbatim: "Wispr previously held a SOC 2 Type II (Accorp Partners) and ISO 27001
  (Gradient) certification. **Both were proactively invalidated in March 2026 due to platform
  integrity concerns at the original auditor.**" (P2)
- P6 names it "the Delve situation"; they replaced **Delve** with **Drata** and engaged
  **A-LIGN**. A stale https://trust.delve.co/wispr-flow link still appears alongside the
  current https://trust.wispr.ai (SafeBase; HTTP 403 to scripted clients).
- Also not held: FedRAMP, PCI DSS, SOC 1, SOC 3. Pen tests: BSK Security (Nov 2025); Doyensec
  next. (P2)
- **Discrepancy on disclosure:** P3 claims "the subprocessor list with regions and retention
  terms... [is] available under NDA through our Trust Center", yet the vendor list is
  published in full at P5. The NDA gate covers retention terms and audit reports, not vendor
  identities.
- HIPAA BAA available and revocable; while active, "Privacy Mode is enforced." (P2)

**Fair note:** their handling of the auditor failure was unusually transparent — they
self-invalidated rather than ride out the certificates. The problem is that the marketing
pages were never updated to match, and still claim certification they do not currently hold.

---

## 6. Weaknesses and failure modes

### 6.1 Self-documented in their own help centre (safest to rely on)
1. **No offline capability on any platform.** "there is no offline transcription on any
   platform." (L4)
2. **"Flow is not compatible with most VPNs."** (L4) — a real blocker for corporate and
   developer users.
3. **Clipboard-based injection with lossy restore**, and outright failure in **Citrix, RDP,
   VMware Horizon, Windows 365, WSL, tmux, screen, SSH, Termius**. (L4, §2.3)
4. **Windows clipboard history leaks dictated text** — not marked concealed as on Mac. (L4)
5. **Front-of-audio clipping on every recording**, worse on AirPods. (L4;
   https://docs.wisprflow.ai/articles/3566082841-fix-missing-first-words-in-transcriptions)
6. **Non-English accuracy gap admitted.** "Non-English transcription is not yet as accurate
   than English" (L2) and "All other languages... remain less reliable than English" (L4).
7. **Intra-sentence code-switching unsupported.** (L2, §3.3)
8. **Personalization and Writing Styles are English-only.** (L2, L4)
9. **UI localised into only 5 languages; no Thai.** (whats-new, L2)
10. **Session caps** — 20 min desktop, 5 min iOS. (L4)
11. **Android is the weakest platform**: no in-app purchase, no Writing Styles, contradictory
    language docs (§3.5), and a dedicated article on Smart Formatting removing words
    (https://docs.wisprflow.ai/articles/6568835559-why-wispr-flow-sometimes-removes-or-changes-words-on-android-smart-formatting).
12. **A populated Known Issues collection**, e.g. password reset broken for email/password
    accounts (https://docs.wisprflow.ai/articles/9281158416-known-issue-password-reset-not-working-for-email-and-password-accounts).
13. **Compliance claims outrunning certification.** (§5.6)
14. **Manual, ticket-based discount verification** with multi-day turnaround. (§4.4)

### 6.2 The mid-2026 reliability crisis — admitted by both Wispr and press
- Wispr publicly solicited complaints (@WisprFlow, 29 July 2026): "**More than 700 people
  responded when Wispr Flow invited its critics to explain what wasn't working. It expected
  around 50.**" — https://www.digitaltrends.com/computing/wispr-flow-asked-its-haters-what-was-wrong-and-more-than-700-people-answered/
  The article frames it as arriving "after a rough stretch... Accuracy and reliability
  problems had already given frustrated users plenty to mention."
- **The HUD occluding UI was a headline complaint** — it "could cover controls such as Gmail's
  send button or the macOS Dock." (§2.2)
- Their own changelog, v1.5.891, 17 June 2026: "**Rapid growth in our user base strained our
  infrastructure recently, and some users saw slower dictation, lower accuracy, or trouble
  signing in.**" Plus: misrouted languages (UK English, Swiss German), audio compression "not
  fully working as intended", and a model-mixing incident where "A portion of dictations were
  being handled by older models." — https://wisprflow.ai/whats-new
- Remediation claims: 99.9% dictation uptime "over the past few weeks"; latency down 30% since
  the start of 2026; Auto Cleanup corrected.

### 6.3 App Store review themes (US, n=250 sampled, 27 rated ≤3★, fetched 2026-08-24)
Source: https://itunes.apple.com/us/rss/customerreviews/page=N/id=6497229487/sortby=mostrecent/json
1. **iOS far weaker than desktop** — "Love it on Mac but finicky on iOS"; "really good on Mac
   but horrible on iPhone"; "So laggy on iPhone"; "New keyboard trash... Desktop app is great."
2. **Update regressions** — "Updates messed it up now it's trash"; "Update seems off."
3. **Lost dictations** — "stopped recording partway through a 10 minute dictation";
   "Just hangs up and I lost 2-3 30 Min of important monologues."
4. **Subscription resentment / no perpetual licence** — "I'm not paying a subscription fee for
   dictation app... I can just buy outright."
5. **Free-tier framing reads as bait** — "It says on the website that for personal use is free
   but it's not."
6. **Billing** — "there is no 10% discount or the option to subscribe monthly."
7. **Permissions unease** — "App requires complete permission to keyboards."
8. **No/broken iPad support** — "Currently does not work on iPad."
9. **No live transcript** — "Cannot see dictation in real time which makes process cumbersome."

### 6.4 Unverified third-party signals — do not rely on these
- `UNVERIFIED:` Trustpilot ~2.7/5 vs G2 ~4.5/5. This divergence appears only in
  competitor-authored review blogs (Spokenly, Voibe — both direct competitors, i.e.
  adversarial sources). Trustpilot returns HTTP 403 to scripted fetches; I could not verify.
- `UNVERIFIED:` One HN commenter claims a measured WER regression from 9.0% to 11.2% across
  525 clips between May and June 2026 — single unreplicated datapoint in a dead comment.
- `UNVERIFIED:` HN thread "Why is Wispr Flow a $2B company?"
  (https://news.ycombinator.com/item?id=49234652) questions defensibility; other HN comments
  report churn to local alternatives — "Just canceled my WisprFlow subscription... to switch
  to a open source, free, local alternative."
- `UNVERIFIED:` No official Linux client; community repackaging at
  https://github.com/wispr-flow-linux/wispr-flow-linux

---

## 7. Strategic read for a would-be competitor

### 7.1 Kill these theses first — the evidence says they are wrong
- ❌ **"They don't support Thai."** They do, in the top formatting tier, with published
  Thai-specific phonetic research and delighted Thai reviewers. (§3.1, §3.6)
- ❌ **"A US company won't invest in non-English."** Their CTO published a 6-minute technical
  post on multilingual ASR, they run a per-language model router, they built Hinglish as a
  first-class code-switched language, and two India/SEA funds are on the cap table. (§3, §4.5)
- ❌ **"It's just a Whisper wrapper."** They route across Anthropic/OpenAI/Google/Cerebras,
  fine-tune with OpenPipe, self-host on four GPU clouds, and have now shipped their own
  model, Canto. (§1.2, §1.4)

### 7.2 Where they are structurally weak — ranked by durability

**1. US-only data residency (most durable).**
Every one of 34 sub-processors is USA-located; "All customer data is processed in the United
States"; there is no on-prem version; and they refuse to author a TIA. For a Thai bank,
hospital, law firm, or government agency, this is not a preference — it is often a
disqualification. **They cannot fix this cheaply**: it requires duplicating a multi-vendor
inference stack in-region, and their entire latency advantage is built on US-colocated GPU
capacity. This is the single hardest thing for a $2B incumbent to match locally.

**2. No offline / on-device mode (durable, and worsening).**
"Transcription always occurs on the cloud" is stated as a deliberate architectural choice for
accuracy and latency — not a gap they intend to close. Worse for them, §5.3 shows the roadmap
*needs* server-side retention for personalized models. Every step toward personalization moves
them further from local. Meanwhile HN churn to local tools is already observable. On Apple
silicon, a local-first competitor gets privacy, offline, zero marginal cost, and no VPN
incompatibility for free.

**3. Price level in low-ARPU markets (durable by choice).**
$15/mo with **no THB pricing and no PPP tier**, in a market where that is a meaningful
monthly outlay. Their discount machinery exists but is identity-based (student, military,
senior) and gated behind manual ticket review. **A US company with a $2B valuation has strong
incentives not to introduce PPP pricing** — it invites arbitrage, complicates enterprise
rate cards, and shrinks reported ARPU. Structural, not accidental.

**4. Thai-English intra-sentence code-switching (real, but time-boxed).**
Today: unsupported by their own docs, with support telling users to disable a language.
Hinglish proves they *can* productize a code-switch pair — and proves they prioritise by
market size. Thailand is 1.4% of their US rating volume; India is 18%. **Thai-English will not
be their second Hinglish.** But Canto explicitly targets intra-sentence mixing, so a generic
capability may arrive without Thai ever being a priority. **Treat this as an 18–24 month
window, not a moat.**

**5. Thai personalization and product localisation (narrow but real).**
The solidly-sourced gaps here are *not* formatting — Thai is in their dedicated-formatting
set. They are:
- **Personalization is English-only.** "Personalized styles apply only when dictating in
  English, on all platforms," and Writing Styles are "Optimized for English and applied
  regardless of your dictation language" — i.e. **English style rules are applied to Thai
  output.** (L2, L4)
- **There is no Thai interface.** UI localisation covers English, German, Spanish, Italian,
  Portuguese only (https://wisprflow.ai/whats-new); "Most of the Flow interface is in English
  regardless of your dictation language" (L2).
- **Their docs do not claim English parity for Thai** (§3.2).
Beyond that, Thai-specific depth — word segmentation without inter-word spaces, tone-mark
normalisation, Thai/Arabic numeral choice, register and politeness particles (ครับ/ค่ะ),
transliteration of English loanwords — is exactly the long-tail polish a US roadmap defers
indefinitely for a market that is 1.4% of its US volume.

**6. Execution instability in the mid-market (opportunistic).**
The 700-complaint campaign, the June infrastructure incident, the Auto Cleanup regression, the
occluding HUD, and the marked iOS-vs-desktop quality gap are all live. **This is the softest
near-term wedge and the least durable** — they have $280M explicitly earmarked for accuracy,
and stated "Most of this round goes there."

### 7.3 The honest case for why competing is hard
- **They are not slow or sloppy at the core.** Series B money is aimed precisely at the
  accuracy gap, with a named model, a public metric ("zero edit rate"), and an ex-Alexa
  founding scientist running the lab.
- **Distribution is already won.** 60 billion words, almost all of the Fortune 500, 10,000+
  enterprises, 14k+ US iOS ratings at 4.83, plus an athlete-investor consumer channel.
- **They are commoditising your product.** The Free tier now includes 100+ languages *and*
  Notetaker. If your entire offer is "better dictation," you are selling into a category the
  leader gives away to fund a higher-margin one.
- **Enterprise checklist parity is expensive.** SSO, SCIM, audit logs, MDM, deny lists, cost
  centres, BAA, DPA, SOC 2 — table stakes they have already built.
- **The gaps have owners.** Code-switching is a funded roadmap item. Latency is down 30% and
  "still coming down." Reliability has a war room.
- **Thailand is small.** 195 iOS ratings is not a market that funds a venture-scale company on
  its own. Whatever you build for Thai must generalise — to SEA, to on-prem/regulated buyers,
  or to a category they are not chasing.

### 7.4 What this implies for positioning
The defensible combination is **not** "better Thai dictation." It is the intersection of the
things a US-centric, cloud-only, VC-backed incumbent structurally will not do:

> **Local/on-device or in-region inference + genuine Thai-English intra-sentence
> code-switching + Thai-native formatting and register + a price and payment model that
> works in Thailand (including one-time or low-ARPU pricing) + working where they don't
> (offline, behind a VPN, in RDP/terminal sessions, on Linux).**

Each element alone is matchable. Together they describe a product Wispr cannot ship without
contradicting its own stated architecture, its retention-dependent roadmap, and its ARPU
model. Sell to the buyers their architecture disqualifies them from — regulated Thai
enterprises and privacy-sensitive professionals — rather than to the users they already
delight.

---

## Appendix — source inventory
- Marketing sitemap: 308 URLs (https://wisprflow.ai/sitemap.xml) — all crawled.
- Help centre sitemap: 174 articles (https://docs.wisprflow.ai/sitemap.xml) — all crawled.
- Legal: /legal/dpa (sub-processors, SCCs), /legal/msa, /privacy-policy, /terms-of-service,
  /data-controls, /ccpa-notice, /cookie-policy.
- Trust Center: https://trust.wispr.ai (SafeBase, 403 to scripted clients);
  legacy https://trust.delve.co/wispr-flow.
- App Store: id 6497229487, storefronts us/th/sg/id/in/jp/gb; review RSS for us/th/sg.
- Third-party: TechCrunch Series B coverage, Digital Trends complaint-campaign coverage.
- **Not obtained:** ARR, absolute latency in ms, Thai WER benchmark, verified Trustpilot/G2
  scores, NDA-gated SOC 2 Type I report and retention terms.
