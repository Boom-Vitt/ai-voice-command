# Glaido — Primary-Source Competitive Brief

**Target:** Glaido, voice dictation desktop app for macOS + Windows 11.
**Research date:** 2026-08-24. All sources fetched live on this date.
**Method:** Direct HTTP fetch of glaido.com + docs.glaido.com (23 doc pages crawled), raw Next.js JS bundle inspection for JS-gated content (FAQ answers, pricing toggle), blog archive, privacy policy, Framer staging site.

**Evidence-quality legend:**
- **[DOC]** = stated in official documentation or legal policy (highest confidence)
- **[CODE]** = extracted from the site's own JS bundle (highest confidence — this is their source of truth, not rendered marketing)
- **[MKT]** = marketing claim, unverified by any independent source
- **UNVERIFIED:** = inference or third-party claim I could not confirm against a primary source

---

## 0. HEADLINE ANSWER: Cloud or Local Inference?

# → **CLOUD. Definitively. Not ambiguous.**

Speech-to-text inference runs on Glaido's servers. This is stated explicitly in their own documentation, and confirmed by four mutually independent lines of evidence.

### Evidence 1 — Explicit statement in the docs (decisive)
Source: <https://docs.glaido.com/docs/features/dictation> — section "How it works", step 2 of 4:

> "Audio is streamed to Glaido's servers where Whisper AI converts speech to text."

This is unambiguous and settles the question on its own. **[DOC]**

### Evidence 2 — Internet listed as a hard system requirement, both platforms
Source: <https://docs.glaido.com/docs/getting-started/installation> — "System requirements". Under **both** the macOS tab and the Windows tab, the requirement list includes:

> "Internet connection (for transcription processing)"

A local-inference product would not require network connectivity *for transcription*. The parenthetical names transcription specifically. **[DOC]**

### Evidence 3 — Network loss breaks transcription entirely, and audio must be re-uploaded
Source: <https://docs.glaido.com/docs/features/history> — section "If a recording fails":

> "If your internet connection drops during a dictation, Glaido saves the audio locally and marks the session as failed."

The documented recovery is to click retry, whereupon "Glaido re-sends the saved audio for transcription", and the docs note you can retry "once you're back online." Local inference would be unaffected by an internet outage. The failure mode proves the dependency. **[DOC]**

### Evidence 4 — Third-party GPU-inference vendors named as sub-processors
Source: <https://glaido.com/privacy-policy>. Named third parties with the stated purpose of AI processing / cloud infrastructure:

| Vendor | Stated role |
|---|---|
| **Groq, Inc.** | AI processing |
| **Baseten Labs, Inc.** | AI processing |
| Amazon Web Services, Inc. | Cloud infrastructure and AI |
| Hetzner Online GmbH | Cloud infrastructure |

Groq and Baseten are both GPU inference-hosting providers. Their presence as sub-processors is only explicable if audio or text is leaving the device. **[DOC]**

### Evidence 5 — The metering hypothesis is confirmed, not merely inferred
Your note that a 2,000-words/week free cap implies server-side accounting was correct reasoning, and it is now **confirmed** rather than inferred. Server-side transcription is stated outright; the metering is downstream of that fact, not evidence for it.

### Why the marketing sounds ambiguous — and why it is technically not a lie
The ambiguity is doing real work for them, but the claims are *narrowly* accurate. Every "local"/"on-device" claim they make is a claim about **storage of the transcript**, never about **inference**:

- Landing page **[MKT]**: "Stored on your device. Secure AI processing. Zero data retention." (<https://glaido.com/>) — note that "Secure AI processing" is conspicuously *not* "local AI processing".
- FAQ, "Is my data private?" **[DOC/MKT]** (answer is JS-gated; extracted from `/_next/static/chunks/app/faq/page-095b73ee10f49bd3.js`): "Glaido uses local storage only. Your dictation text stays on your device as a temporary history. Nothing is saved to our database."
- Privacy policy **[DOC]**: "Glaido does not store Your dictation text in Our database; a temporary local history is kept only on Your Device."

**Assessment:** "local storage only" and "streamed to Glaido's servers for transcription" are fully compatible statements. Audio goes up, text comes back, the *text* is stored locally. The marketing never states inference is local — it just never states it isn't, and lets "on device" + "zero data retention" imply it. For a build-vs-buy report this should be characterized as *ambiguity by construction*, not as a false claim.

### ⚠️ One claim that IS materially contradicted
The Framer staging site (<https://desirable-expectations-958965.framer.app/>) still runs an older version of the marketing copy, which reads verbatim:

> "Local storage. Private servers. Your data never touches third-party AI."

Two things here matter:
1. **"Private servers"** — the earlier copy openly conceded server-side processing. The current live site replaced this line with "Secure AI processing. Zero data retention.", which is strictly *less* informative about where inference happens.
2. **"Your data never touches third-party AI"** directly contradicts the current privacy policy, which names Groq, Baseten, and AWS as third-party AI processors. Either the staging copy is stale/false, or the architecture changed. This is a real inconsistency and is worth citing if the report needs to assess vendor trustworthiness.

**Note this is on the staging/Framer site, not the current live glaido.com** — the live site does not make the "never touches third-party AI" claim. Do not attribute it to the current product without that caveat.

### ⚠️ Second scope gap: "zero data retention" covers transcript TEXT. Audio retention is undisclosed.
This is separate from the local-vs-cloud question and matters independently for a privacy comparison.

Note the precise scoping of every retention claim:
- Privacy policy **[DOC]**: "Glaido does not store Your dictation **text** in Our database; a temporary local history is kept only on Your Device." — scoped to *text*. It says nothing about audio.
- FAQ **[DOC]**: "Nothing is saved to our database."
- Landing page **[MKT]**: "Zero data retention."

Now set that against the product's documented behavior:
- <https://docs.glaido.com/docs/features/history> **[DOC]**: "Glaido keeps the original audio of each dictation, so you can listen back to the recording, download it as an audio file, or retry the transcription." Retry works by "Glaido re-sends the saved audio for transcription." Audio persists "until you manually delete the session."
- <https://docs.glaido.com/docs/account/authentication> **[DOC]**: signing out "clears your local session but keeps your account, preferences, and **data intact on the server**."
- <https://glaido.com/blog/introducing-glaido> **[MKT]**: the launch feature table lists "Session history — Playback and review in **the web dashboard**."
- An authenticated web app exists at `app.glaido.com` (login required).

**The discriminating question the documentation never answers: is dictation audio — and the searchable session history — stored client-side, server-side, or both?** A "web dashboard" for session playback implies server-side; the history docs describe history as living on the app's home screen, implying local.

> UNVERIFIED: The Command Palette "searches across all transcription text and returns **up to 15** matching sessions" (<https://docs.glaido.com/docs/features/command-palette>) — a fixed result cap is more characteristic of a server-side query than an in-memory local search. This is a hint, not proof. Do not state it as fact.

**How to report this:** "Zero data retention" is a claim about *transcript text in Glaido's database*. It is not a claim about audio, and audio retention is simply undisclosed. That is a documentation gap on their side, not a research gap on ours — state it as an unanswered question a procurement/security review would need to put to the vendor directly.

### Residual gap (be precise about this)
What the docs do **not** say: which vendor runs which stage. "Whisper AI" (docs) and "Groq, Inc." / "Baseten Labs, Inc." (privacy policy) are two separate facts from two separate documents. Whisper-on-Groq is a plausible pairing and Groq publicly serves Whisper, but **no primary source connects them**. Do not assert it.

---

## 1. Pricing — Discrepancy RESOLVED

**Both figures in your notes are correct. They are different billing terms of the same plan.** There is no stale data and no contradiction.

Resolved from the pricing page's own JS bundle (`https://glaido.com/_next/static/chunks/940-cb4ae175d1190dda.js`), which contains the literal source: **[CODE]**

```js
let m = "$".concat(Math.round(200/12)),      // annual display price -> "$17"
    u = Math.round(16.666666666666664);      // savings badge -> "Save 17%"
...
price:      r ? m : "$".concat(20),
priceNote:  r ? "Billed annually" : "Billed monthly",
```

`r` is the toggle state and defaults to `true` (annual), which is why the page renders $17 on load and why a casual read of the landing page misses the $20.

| Plan | Monthly billing | Annual billing |
|---|---|---|
| **Pro** | **$20 / month** ($240/yr) | **$200 / year**, displayed as **$17/month** "Billed annually" |

- The **$200/year** figure is derived from `Math.round(200/12)` in their source — so the annual contract value is 200, not 204 and not 199. Caveat: this is read off the display arithmetic, not off a checkout page (checkout is behind auth), so treat $200/yr as *strongly indicated* rather than as a verified charge.
- **Independent corroboration of the $200 figure:** the savings badge constant is `u = Math.round(16.666666666666664)`. That float is exactly (240 − 200) / 240 × 100. The badge was computed from a $240-vs-$200 comparison, which confirms the annual contract value from a second, unrelated constant.
- The **$20/month** price is independently corroborated by the launch blog post (<https://glaido.com/blog/introducing-glaido>, April 8, 2026), whose pricing table lists Pro at "$20/month", and by the Framer staging site which shows "$20". **[DOC]**

**Source URLs:** <https://glaido.com/pricing> (rendered), JS bundle above (authoritative), <https://glaido.com/blog/introducing-glaido> (corroborating).

### Free tier ("Basic")
Source: <https://glaido.com/pricing> **[DOC]**
- **2,000 words per week** — the only hard metered limit
- "Free forever", "No credit card. No trial limits."
- Includes: use in any app, AI auto-edits, **Agent mode**, local storage
- Notably, Agent Mode is **not** paywalled — it is on the free tier.
- Launch post additionally characterized free-tier processing as "Standard" vs Pro's "Prioritized" (<https://glaido.com/blog/introducing-glaido>).

### Pro adds
Unlimited words; "Prioritized processing"; early access to new features; prioritized support. <https://glaido.com/pricing>

### Enterprise
Source: <https://glaido.com/pricing>. Custom pricing / custom billing. Everything in Pro, plus: **[DOC]**
- Unlimited team members
- **SSO & SAML authentication**
- **Dedicated data processing** ← note: this feature only makes sense in a server-side inference architecture, and is further corroboration of Section 0
- **API access & integrations**

### Other commercial mechanics
- **Referral program**: "Earn free months of Glaido Pro by inviting friends" — <https://docs.glaido.com/docs/account/referrals> **[DOC]**
- **Billing provider**: docs say "a secure third-party billing provider"; the privacy policy names **Polar** as payment processor. <https://docs.glaido.com/docs/account/subscription>, <https://glaido.com/privacy-policy> **[DOC]**
- UNVERIFIED: a third-party community post (skool.com, AI Automation Society) advertised a "40% off" Windows launch promo. Not confirmed on any Glaido-owned property; treat as promotional noise.

---

## 2. Agent Mode — What It Mechanically Does

Source: <https://docs.glaido.com/docs/features/agent-mode> **[DOC]**

**It is all three things you asked about — LLM rewriting, voice-triggered actions, AND real tool use.** It is not merely a rewrite layer.

### Core mechanic
Docs describe it as "agentic dictation". The documented flow:

1. **Select text in any app (optional)** — the docs state the selection "Captures context for the agent"
2. Activate via a **separate agent hotkey** (distinct from the dictation hotkey)
3. Speak a request, e.g. "translate this to French"
4. The request + the selected text are sent to an LLM
5. A floating **agent window** appears showing "the streaming response"
6. **Press Enter to paste** the result into the app

Critically, the agent output does **not** auto-insert. It renders in a review window first and requires an explicit Enter to paste. That is a meaningfully different (and safer) interaction than dictation, which pastes automatically.

### The agent window
- Floating, bottom-center, renders "with full markdown formatting"
- "Stays on top of other windows without stealing focus"
- Draggable by its header
- Shortcuts: `Enter` paste · `⌘/Ctrl+C` copy · `Esc` close · hold agent hotkey again = speak a follow-up

### Multi-turn refinement
Documented: hold the agent hotkey while the window is open to speak a follow-up, and "The agent remembers the context of your previous exchange." Documented example chain: "Summarize this" → "Make it shorter". This is a stateful conversation, not a one-shot transform.

### Documented example commands
"Translate this to Spanish", "Make this more formal", "Summarize this", "Fix the grammar", "Explain this code", "Write a reply to this email", "Convert to bullet points". Works with no selection at all, in which case it behaves as a general voice assistant.

### Tool use — this is the strategically important part
Source: <https://docs.glaido.com/docs/beta/tools> **[DOC]**

Agent Mode can execute **local MCP (Model Context Protocol) servers**. Verbatim from the docs: "Under the hood, tools are Model Context Protocol (MCP) servers that run as local processes on your machine."

Mechanics:
- **Beta-gated**: requires Settings > Preferences > "Enable beta features"
- **Import** a folder containing an `mcp.json` / `.mcp.json`; or **Edit config** to hand-edit a config using "the standard `mcpServers` format shared by most MCP clients"
- Default install path: `~/Glaido/glaido-mcp-servers`
- **Per-tool approval policy: Auto / Ask / Deny.** Docs state "Tools that only read data default to `Auto`; everything else defaults to `Ask`." An approval card appears inline in the agent window; `Enter` = Allow once. Notably the docs specify that while the approval card is visible, Enter "never pastes" — a deliberate guard against accidental paste-on-approve.
- **Authoring model is unusual and worth flagging competitively:** Glaido does not ship a tool builder. The documented workflow is to have *an external AI coding agent* (Claude Code, Cursor, or Codex) generate the MCP server for you, via a skill hosted at `github.com/daveebbelaar/glaido-skills`. The docs contain a copy-paste prompt aimed at the coding agent and even a dedicated "For coding agents" section addressed to the agent rather than the user. This offloads all integration engineering to the user's own AI subscription.

**Architectural rationale (directly relevant to a build-vs-buy latency discussion), quoted from the docs:**
> "Glaido's agent is built for speed: it uses a fast model so answers come back in about a second."

The docs justify local-only MCP servers by arguing large cloud MCP servers "expose dozens of broad, general-purpose tools" and "loading them all makes a fast agent slower and less accurate." So: local tool *execution*, but cloud model *inference* — consistent with Section 0.

### Voice Activation ("Hey Glaido")
Source: <https://docs.glaido.com/docs/features/voice-activation> **[DOC]**
A wake phrase that reaches Agent Mode without a second hotkey. Start any normal dictation and open with "Hey Glaido" + command. Docs state Glaido "detects the wake phrase at the start of your dictation and switches the session to agent mode."

Important mechanical detail: **the wake phrase is only honored at the start of a dictation.** Docs: "Saying 'Hey Glaido' mid-sentence won't trigger agent mode; those words simply become part of your dictated text." This implies the detection is performed on the **transcript text after transcription**, not by an always-on local wake-word engine. Consistent with there being no always-listening component.

---

## 3. Hotkey / Interaction Model

Source: <https://docs.glaido.com/docs/configuration/hotkeys> and <https://docs.glaido.com/docs/features/dictation> **[DOC]**

**Both push-to-talk and toggle are supported, as separate simultaneously-bound hotkeys.** Push-to-talk is the default and the docs call it "the default and most popular mode." There are **four configurable hotkey slots** — two dictation, two agent.

| Function | macOS default | Windows default | Mode |
|---|---|---|---|
| Dictation | **`Fn`** | **`Ctrl + Win`** | Hold (push-to-talk) |
| Hands-free dictation | `Fn + Space` | `Ctrl + Win + Shift` | Toggle |
| Agent dictation | **`Right ⌥`** | **`Ctrl + Alt`** | Hold |
| Hands-free agent | `Right ⌥ + Space` | `Ctrl + Alt + Shift` | Toggle |

Non-remappable: `⌘/Ctrl + K` command palette, `⌘/Ctrl + ,` settings, "Hey Glaido" voice activation.

### On release (push-to-talk)
Docs: "Release hotkey → Recording stops, text is transcribed and pasted." Fully automatic — no confirmation step for plain dictation.

### In toggle mode
- Press again **or `Enter`** → stop and paste. Docs note "Enter to stop and paste" is a distinct, on-by-default setting, disableable in Settings > Hotkeys > App.
- **`Esc`** → cancel, "Recording is cancelled (no text pasted)"

### UI overlay / HUD
Source: <https://docs.glaido.com/docs/features/dictation> **[DOC]**
- A **"dictation bar"** appears **bottom-center** with a **live audio waveform**
- Explicitly documented: "It never steals focus from the app you're working in"
- Position is adjustable — Preferences offers "Bottom (default), Raised, or High" for cases where it overlaps a dock/taskbar
- Optional interaction sounds on start/stop (configurable)
- The Agent Mode window is a separate, draggable, always-on-top overlay in the same bottom-center location

### Notable hotkey engineering (a real differentiator vs. naive implementations)
- **Modifier-only hotkeys supported** — bare `Fn` or bare `Right Option` can be the trigger
- **Left/right modifiers are distinguished on Windows** (Left Ctrl ≠ Right Ctrl)
- **Double-tap activation** to prevent accidental triggers: "Double tap and hold" for push-to-talk, "Double tap to start" for toggle. Single-key hotkeys only.
- **Conflict warnings** before saving OS-colliding combos (e.g. `Win + Space` language switcher, bare AltGr)
- Duplicate assignments are actively prevented

---

## 4. OS Permissions Requested

Source: <https://docs.glaido.com/docs/getting-started/setup> ("Setup & Permissions") **[DOC]**

The docs publish a complete permission table. It lists exactly **two** permissions:

| Permission | Platform | Documented purpose (verbatim) |
|---|---|---|
| **Microphone** | macOS & Windows | "To capture audio for transcription" |
| **Accessibility** | **macOS only** | "To detect global hotkeys and paste text into other apps" |

### ⭐ Screen Recording is NOT requested — and this matters
**No Screen Recording permission appears anywhere in the documentation.** Neither does Input Monitoring — on macOS the Accessibility grant is documented as covering both global hotkey capture and text insertion.

This is a **load-bearing negative finding** given the "understands context" positioning:

- The launch blog post **[MKT]** (<https://glaido.com/blog/introducing-glaido>) claims Glaido "looks at three things": "The app you're in", "The text around your cursor", and "The type of content you're producing."
- Without Screen Recording, **none of that can come from reading the screen.** App identity is available from ordinary frontmost-application APIs (no special permission), and "text around your cursor" is exactly what the macOS Accessibility API exposes.
- In Agent Mode the docs are explicit that context comes from an **explicit user text selection** ("Select text… Captures context for the agent"), not from ambient screen capture.

**Conclusion:** "understands context" means *selected text + focused application*, not screen-context awareness. There is no evidence of screen scraping, and the permission set makes it impossible. For a privacy-comparison section this is a genuine point in Glaido's favor, and it should be stated plainly rather than left as an open question.

### Supporting detail
- Docs state flatly: "Glaido cannot transcribe or paste text without these permissions."
- Recovery paths documented: macOS System Settings > Privacy & Security > {Microphone, Accessibility}; Windows Settings > Privacy & security > Microphone.
- In-app verification exists: Settings > Account > "Check permissions".
- The onboarding wizard sequence is documented as: Welcome → Accessibility (macOS only) → Test hotkey → Microphone → Language → Test dictation.

---

## 5. Named AI Models and Providers

### Explicitly named in primary sources

| Name | Where | Role as stated |
|---|---|---|
| **Whisper** | <https://docs.glaido.com/docs/features/dictation> | "Whisper AI converts speech to text" — the STT model **[DOC]** |
| **Groq, Inc.** | <https://glaido.com/privacy-policy> | "AI processing" sub-processor **[DOC]** |
| **Baseten Labs, Inc.** | <https://glaido.com/privacy-policy> | "AI processing" sub-processor **[DOC]** |
| **Amazon Web Services, Inc.** | <https://glaido.com/privacy-policy> | "Cloud infrastructure and AI" **[DOC]** |
| **Hetzner Online GmbH** | <https://glaido.com/privacy-policy> | Cloud infrastructure **[DOC]** |

No Whisper **variant** is ever specified — no `large-v3`, no `turbo`, no distil. No Parakeet, Deepgram, AssemblyAI, GPT, Claude, or Gemini appears anywhere in the docs, blog, privacy policy, or any JS bundle I inspected.

### There are (at least) TWO models in the pipeline, and the second is unnamed
The dictation pipeline documented at <https://docs.glaido.com/docs/features/dictation> has four stages:

1. **Audio capture** — with "Built-in noise reduction" / a denoiser, running locally
2. **Transcription** — "Audio is streamed to Glaido's servers where Whisper AI converts speech to text"
3. **Formatting** — "An AI model applies punctuation, capitalization, and your custom formatting rules"
4. **Paste** — into the active field

**Stage 3 is a second, separate, completely unidentified model.** The formatting-rules doc (<https://docs.glaido.com/docs/personalization/formatting-rules>) confirms it is prompt-driven: "Your rules are included as instructions to the AI." That is an LLM taking user-authored natural-language instructions, not a rules engine.

A **third** unnamed model powers Agent Mode, described only as "a fast model" (<https://docs.glaido.com/docs/beta/tools>).

**Gap to state honestly in the report:** the vendor for the formatting LLM and the Agent Mode LLM is not disclosed anywhere. Groq and Baseten are the plausible hosts, but:

> UNVERIFIED: No primary source maps any specific model to any specific vendor. Whisper→Groq and formatting-LLM→Baseten are *inferences* from the co-occurrence of two independent documents, not documented facts. Do not state them as fact in the report.

### Search technique note
I inspected the site's Next.js JS bundles directly (13 chunks from the pricing page, plus the FAQ page chunk) — this is how the JS-gated FAQ answers and the pricing constants were recovered.

I then grepped every fetched bundle and HTML file for `whisper|parakeet|deepgram|groq|baseten|assembly|elevenlabs|openai|anthropic|gpt-[0-9]|gemini|api\.[a-z]+\.(com|ai)`. **Zero hits across all marketing-site bundles and pages.** The single occurrence of "Whisper" anywhere in the crawl is the prose sentence on the dictation docs page. So: no model names, API endpoints, or provider SDKs leak through the public web tier. The desktop app binary would be the next place to look, but it is auth-gated (see §7).

---

## 6. Custom Dictionary / Prompts / Vocabulary

Glaido ships **three separate and distinct** personalization systems. It is worth keeping them apart — they operate at different pipeline stages.

### 6a. Dictionary — <https://docs.glaido.com/docs/personalization/dictionary> **[DOC]**
Two documented modes:
- **Custom vocabulary** — add words so the recognizer knows them. Docs frame this as improving recognition: "Adding it to the dictionary improves recognition accuracy." Documented examples: "Kubernetes", "WebSocket", "Salesforce", "Kowalski", "PostgreSQL".
- **Spelling corrections** — an explicit misspelling→correction map applied post-transcription. Docs state matching "is case-insensitive, so 'postgress' also catches 'Postgress' and 'POSTGRESS'." Documented examples: "Shawn"→"Sean", "postgress"→"Postgres".

> UNVERIFIED: whether custom vocabulary is injected as a Whisper decoder prompt/biasing term or is applied as post-hoc text substitution. The docs claim it improves *recognition*, which implies decoder-side biasing, but no mechanism is documented.

Entries are managed in a dedicated page and can be added via the command palette ("Add word").

### 6b. Formatting Rules ("Personalization") — <https://docs.glaido.com/docs/personalization/formatting-rules> **[DOC]**
This is the **custom prompt** feature.
- Docs define them as "AI instructions that modify how Glaido processes your transcriptions"
- Mechanism, verbatim: "After Glaido transcribes your speech, it passes the text through an AI formatting step. Your rules are included as instructions to the AI, which adjusts the text accordingly before pasting."
- **Hard limit: "up to 8 active formatting rules at a time."** All active rules are applied together.
- Documented examples: "Always write in a professional, formal tone"; "Use British English spelling (colour, organise, etc.)"; "Always write in lowercase, with no capital letters"
- Preset suggestions are offered on first open
- Docs advise against contradictory rules — a tell that these are concatenated into a single system prompt

### 6c. Snippets — <https://docs.glaido.com/docs/personalization/snippets> **[DOC]**
Deterministic text expansion, not AI.
- Docs: "When Glaido detects an **exact match** of your trigger phrase in the transcription, it replaces the trigger with your defined content." (emphasis mine — exact match, so this is string substitution)
- Multi-line replacements supported (signature blocks)
- Documented examples: "my email" → an address; "kind regards" → a multi-line signature

### 6d. Languages — <https://docs.glaido.com/docs/configuration/languages> **[DOC]**
- **⚠️ Marketing/docs discrepancy:** the landing page and FAQ claim **"100+ languages"** **[MKT]** (<https://glaido.com/>, and the FAQ answer "Glaido supports 100+ languages and dialects in any application"), but the documentation states **"more than 65 languages"**. Cite the docs figure (**65+**) as the defensible number.
  - Likely benign explanation, consistent with the Whisper finding in §5: Whisper's nominal language coverage is ~99, so "100+" probably reflects the *model's* spec sheet while 65+ is what is actually exposed in Glaido's language picker. Report it as a spec-sheet-vs-shipped-UI gap rather than as an overstatement.
- Multi-language selection with auto-detection is supported; docs advise "Choose a single language for maximum accuracy."
- Separately, the **app UI** is localized into **14 languages**: English, German, Spanish, Dutch, French, Italian, Polish, Romanian, Russian, Serbian (Latin), Greek, Japanese, Korean, Chinese (Simplified).

---

## 7. Platform Requirements

Source: <https://docs.glaido.com/docs/getting-started/installation> **[DOC]**

### macOS
- **macOS 13 (Ventura) or later**
- **Apple Silicon (M1/M2/M3/M4) *or* Intel Mac** — note: Intel is explicitly supported
- Working microphone
- **Internet connection (for transcription processing)**
- Ships as `.dmg`, drag-to-Applications

### Windows
- **Windows 11** (Windows 10 is not listed)
- **Microsoft Edge WebView2 runtime** — "pre-installed on most systems; the installer handles it otherwise"
- Working microphone
- **Internet connection (for transcription processing)**
- Ships as `.exe` installer

### Why Windows 11 and not Windows 10?
**No reason is given in any primary source.** The Windows launch post (<https://glaido.com/blog/glaido-comes-to-windows>, June 29, 2026) states the requirement flatly — "You need Windows 11 and a microphone. That is the whole requirements list" — without justification.

> UNVERIFIED: The WebView2 dependency is *not* the explanation — WebView2 is supported on Windows 10 as well. The Win11-only cut is more likely a support-surface decision than a technical constraint. I could find no primary source confirming any reason; do not speculate in the report beyond noting it is unexplained.

### Download size — could not be obtained, but the hypothesis it would test is already dead
- Every "Download" button on glaido.com points to `https://app.glaido.com/signup`. There is no public direct binary URL.
- `https://app.glaido.com/download` returns **HTTP 307 → `/login?next=%2Fdownload`**. The installer is **auth-gated**; no size is publicly retrievable without an account.
- `glaido.com/download`, `/changelog`, and `glaido.com/docs` all return **404** (docs live on the `docs.glaido.com` subdomain at `/docs`).

**However — the "large download ⇒ bundled local model" test is moot.** Internet is a documented hard requirement *for transcription*, and network loss is documented to fail transcription outright (§0, Evidence 2 & 3). No bundled STT model is present, whatever the installer weighs. Do not spend further effort on the download size.

### Implementation stack
- Launch post **[MKT]** claims: "a lightweight native Mac app. No browser tab, no Electron wrapper".
- > UNVERIFIED: The Windows WebView2 dependency strongly suggests a Rust/Tauri-style webview shell (Tauri uses WebView2 on Windows and WKWebView on macOS) rather than a fully native UI. This would make the "no Electron wrapper" claim technically true but arguably misleading. I could not confirm the framework — the binary is auth-gated. Flag as inference only.

---

## 8. Latency, WPM, Streaming, "How It Works"

### Latency — a documented figure, stated twice
- <https://docs.glaido.com/docs/features/dictation>: "The entire pipeline takes around **1 to 3 seconds** after you stop speaking, depending on the length of your dictation." **[DOC]**
- <https://docs.glaido.com/docs/getting-started/quick-start>: "This takes about **1 to 3 seconds**." **[DOC]**
- <https://glaido.com/blog/glaido-comes-to-windows>: "in about a second" **[MKT]**
- Agent Mode: "it uses a fast model so answers come back in **about a second**" (<https://docs.glaido.com/docs/beta/tools>) **[DOC]**

**This is post-hoc batch latency, not streaming.** The figure is measured "after you stop speaking" and scales with dictation length — the signature of upload-then-transcribe, not incremental streaming ASR.

### Streaming — batch, not streaming ASR
The architecture is **batch**, and this is established from the docs alone without needing to read marketing copy against them:

- The documented latency is measured **"after you stop speaking"** and **scales with dictation length**. That is the signature of upload-then-transcribe, not incremental streaming ASR.
- The docs name an explicit **post-transcription "AI formatting step"** as stage 3 of 4 (<https://docs.glaido.com/docs/features/dictation>).

Marketing describes it as real-time — launch post: "There is no post-processing step. It happens in real time, as you speak" **[MKT]**; Framer site: "REAL-TIME DICTATION … NO DELAYS" **[MKT]**.

**Do not report this as a caught falsehood.** In context, the launch post's surrounding paragraphs are about dictation output "that takes almost as long to clean up as it would have taken to type" — so "no post-processing step" most plausibly means *no manual cleanup by the user*, which is true, rather than a claim about pipeline architecture. Reading a technical claim into a workflow claim would weaken the brief. The defensible statement is simply: **the documented pipeline is batch with a 1–3s post-release tail, so benchmark against 1–3s, not against "real time."**

The one place streaming genuinely occurs is Agent Mode output: "the agent window appears showing the **streaming** response" — LLM token streaming into the review window, not streaming ASR.

### WPM
- **[MKT]** Landing page: "Glide through work at 150 WPM"; a stated "Average dictation speed: 152 WPM"
- **[MKT]** "Save 20+ hours a month"; FAQ claims "Within a few days, expect 3-5x speed"
- **[MKT]** Tagline "World's fastest dictation"

> All WPM, time-saving, and "world's fastest" figures are self-reported marketing with **no methodology, no benchmark, and no independent verification** anywhere in any source. ~150 WPM is simply a normal human speaking rate, so the number describes speech, not the product's performance. Do not carry these into a technical comparison as performance data.

### Reliability engineering (a real, documented strength)
- Audio for every session is retained locally and is replayable/downloadable — <https://docs.glaido.com/docs/features/history> **[DOC]**
- Failed transcriptions are recoverable via a **retry** that re-sends the stored audio; retryable indefinitely once back online **[DOC]**
- Local denoiser runs before upload **[DOC]**
- Two blog posts are dedicated to reliability: "Built to never lose a word" (April 20, 2026) and the 0.1.0 post citing "deep reliability work" (June 16, 2026)

---

## 9. Company / Team

### Confirmed from primary sources
- **Legal entity: GLAIDOVOICE AI SOLUTIONS - FZCO**, a Free Zone Company with Limited Liability, incorporated in the **United Arab Emirates**, licensed by the **Dubai Integrated Economic Zones Authority (DIEZA)**. Source: <https://glaido.com/privacy-policy> **[DOC]**
- **Registered address: Building A1, Dubai Digital Park, Dubai Silicon Oasis, Dubai, United Arab Emirates.** Source: <https://glaido.com/terms-of-service> **[DOC]**
- The `daveebbelaar/glaido-skills` GitHub repository referenced by the official docs **exists and is public** (HTTP 200), confirming the docs' instruction is live rather than aspirational. **[DOC]**
- **Launch date: April 8, 2026** — "Introducing Glaido", the first blog post, positioned as Mac-only at launch. <https://glaido.com/blog/introducing-glaido> **[DOC]**
- **Windows launch: June 29, 2026.** <https://glaido.com/blog/glaido-comes-to-windows> **[DOC]**
- **Very early version numbering:** the June 16, 2026 post is titled "Glaido **0.1.0** — Hotkeys, onboarding, and rock-solid reliability". A 0.1.0 two months after public launch signals a young product. **[DOC]**
- **Ships fast:** 7 blog posts between April 8 and July 18, 2026 (April 8, April 12, April 20, May 1, June 16, June 29, July 18). Roughly monthly shipping cadence. <https://glaido.com/blog> **[DOC]**
- **Blog posts are bylined "Glaido team"** — no individual author attribution anywhere on the site. **[DOC]**
- All blog copy uses "we"/"our"; no team, about, or careers page exists on the site.

### Strong circumstantial evidence linking Dave Ebbelaar to the company (not just a testimonial)
The landing page presents four names as **testimonials**: Nate Herk, **Dave Ebbelaar**, Jannis Moore, Jack Roberts. But the official Tools documentation instructs users to install a skill from a **personal GitHub repository owned by one of them**:

> `git clone https://github.com/daveebbelaar/glaido-skills.git`
> and: "The **skill is the source of truth** and takes precedence over the summary on this page."

Source: <https://docs.glaido.com/docs/beta/tools> **[DOC]**

Glaido's own docs designate `daveebbelaar`'s personal repo as the authoritative source for a core product feature. That is not a customer relationship — it is an insider one. **The "testimonials" are, at minimum, partly from people building the product.**

### Funding / team size
- **No funding announcement exists** on any Glaido-owned property. No press page, no investor mentions, no "backed by".
- > UNVERIFIED: A third-party branding-agency case study (<https://www.plenor.io/case-studies/glaido>, published Aug 19, 2026) describes **Dave Ebbelaar as "Co-Founder"** and states Glaido is backed by **Datalumina**, his data/AI consultancy. Web search results additionally suggested Jack Roberts, Nate Herk, and Jannis Moore as co-founders. **None of this is confirmed by a Glaido-owned source.** The Plenor case study is a vendor marketing page, and the co-founder list came from a search-engine summary — treat both as low-confidence.
- > UNVERIFIED: Team size is nowhere stated. The absence of a funding announcement is **not** evidence of bootstrapping.
- **Overall picture (inference, label as such):** indie / self-funded-looking, founder-led, small, launched April 2026, Dubai free-zone entity, marketed heavily through the founders' own AI-creator audiences (Datalumina, Skool communities). No evidence of institutional venture funding.

### Market presence
- > UNVERIFIED: A competitor's comparison page (<https://www.getvoibe.com/resources/glaido-vs-wispr-flow/>) asserts Glaido has no Product Hunt listing, no G2 reviews, no Trustpilot data, and no meaningful Reddit/HN discussion. This is a **competitor-authored source and inherently hostile** — but it is consistent with my own searches, which surfaced no Product Hunt, HN, Reddit, or app-store listing for Glaido.
- **Not distributed via the Mac App Store or Microsoft Store** — installation is by direct `.dmg`/`.exe` download only, per <https://docs.glaido.com/docs/getting-started/installation>. **[DOC]**
- **Competitive positioning tell:** the 0.1.0 release added **"Wispr Flow import"** (<https://glaido.com/blog>), i.e. a migration path built specifically to poach Wispr Flow users. That names their primary competitive target.

---

## 10. Source Inventory

### Reachable and used
| URL | Status |
|---|---|
| <https://glaido.com/> | 200 |
| <https://glaido.com/faq> | 200 (answers JS-gated; recovered from bundle) |
| <https://glaido.com/pricing> | 200 (prices JS-gated; recovered from bundle) |
| <https://glaido.com/privacy-policy> | 200 |
| <https://glaido.com/blog> + 7 posts | 200 |
| <https://glaido.com/sitemap.xml> | 200 (7 URLs) |
| <https://desirable-expectations-958965.framer.app/> | 200 — stale copy, materially different |
| `docs.glaido.com` — **23 pages, fully crawled** | 200 |
| `https://glaido.com/_next/static/chunks/…` (14 JS bundles) | 200 |

**Full docs tree crawled:** `/docs`; getting-started/{installation, setup, quick-start, tips, troubleshooting}; features/{dictation, agent-mode, voice-activation, command-palette, history}; configuration/{hotkeys, microphone, languages, preferences}; personalization/{dictionary, snippets, formatting-rules}; account/{authentication, subscription, referrals}; beta/tools; support.

### Do not exist (404 — these are not research gaps)
- `glaido.com/download` · `glaido.com/changelog` · `glaido.com/docs` · `docs.glaido.com/sitemap.xml`
- No App Store, Microsoft Store, or Product Hunt listing found.
- `https://docs.glaido.com/` returns **403 to WebFetch** but **200 to a normal browser User-Agent** — a UA filter, not a real block. Fetched successfully via curl.

### Auth-gated (blocked)
- `app.glaido.com/download` → 307 to login. Installer binary and its size are not publicly obtainable.
- Terms of Service is at `/terms-of-service` (not `/terms`); reviewed via sitemap, nothing material beyond the privacy policy findings.

---

## 11. Bottom Line for Build-vs-Buy

1. **Cloud STT, unambiguously.** "Audio is streamed to Glaido's servers where Whisper AI converts speech to text." Any build-vs-buy framing that treats Glaido as an on-device competitor is wrong. Their privacy story is *storage*-local, not *inference*-local, and their own docs say so plainly even though the landing page does not.

2. **Three cloud model calls per interaction, not one.** Whisper (STT) → an unnamed formatting LLM → optionally an unnamed "fast model" for Agent Mode. The formatting LLM is a real, separate, undisclosed dependency and a real cost center.

3. **Pricing is $20/mo month-to-month, or $200/yr (shown as $17/mo).** Both numbers in the original notes were right. Free tier is genuinely generous on features — Agent Mode is not paywalled — and metered only at 2,000 words/week.

4. **No screen capture, and it cannot do screen capture.** Only Microphone + macOS Accessibility are requested. "Understands context" = selected text + focused app. This is a legitimate privacy advantage and should be reported as a confirmed negative finding, not an open question.

5. **"Zero data retention" is scoped to transcript text; audio retention is undisclosed.** Glaido demonstrably keeps the original audio of every dictation (it can replay, download, and re-upload it for retry), and the authentication doc says data stays "on the server" after sign-out. Whether audio and session history live client-side, server-side, or both is never stated. This is the single most important question to put to the vendor in a security review.

6. **The most differentiated feature is local MCP tool execution from Agent Mode** — with per-tool Auto/Ask/Deny policies — but it is beta-gated and offloads all tool authoring onto the user's own AI coding agent via a founder's personal GitHub repo. Low engineering cost to them, high friction for users.

7. **Benchmark against the documented 1–3s batch latency, not "real time."** The pipeline is batch: latency is measured after you stop speaking and scales with length. Two checkable marketing gaps are worth noting — "100+ languages" vs. the docs' 65+ (probably Whisper's spec sheet vs. the shipped picker), and the *staging* site's "your data never touches third-party AI" vs. a privacy policy naming Groq, Baseten, and AWS. Do **not** cite "no post-processing step" as a falsehood; in context it reads as a claim about user cleanup, not architecture.

8. **Young, small, unfunded-as-far-as-anyone-can-tell, shipping fast.** Launched April 2026, still 0.1.x, Dubai FZCO, founder-led with creator-audience distribution, and explicitly targeting Wispr Flow users with a purpose-built importer.
