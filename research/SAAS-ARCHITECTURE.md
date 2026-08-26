# Adding an ASR Desktop App to Phaya
### Architecture & build plan — 2026-08-24

**Context.** You own Phaya, a media-*generation* SaaS: async jobs, a credits ledger with
per-model pricing formulas, charge-on-submission, and an existing account system. You want to add
a Thai+English dictation desktop app as a second product that shares Phaya accounts and billing.

**Assumptions I'm making** (correct me and I'll revise): Phaya has a REST API behind the MCP layer,
a user/account table with API keys, a credits ledger with transactions, and a job queue. I can see
the MCP surface (`generate_*`, `job_status`, `jobs_wait`, `get_balance`, `upload_media`) but not the
stack underneath. Anything below that touches your internals is marked **[VERIFY]**.

---

## 0. The one rule that determines everything else

> **Local mode consumes no credits. Cloud mode is metered.**

Everything in this document follows from that sentence, so it belongs on your pricing page and in
your onboarding.

It is not a compromise — it is the only shape where the research findings survive contact with your
existing business model:

| | Local mode | Cloud mode |
|---|---|---|
| Inference | On-device **`large-v3`-class** model (Pathumma-Whisper-L3) + gated glossary | Server-side ASR / audio-LLM |
| Marginal cost | **$0** | ~$0.0007–0.008 per audio-minute |
| Billing | **Flat subscription** — no credits touched | **Credits**, metered per audio-second |
| Privacy claim | "Your voice never leaves this laptop" — PDPA §28 transfer *does not occur* | Cross-border transfer; consent + sub-processor disclosure required |
| Thai+English | Model scale first (measured: `large-v3` emits Latin unprompted), glossary second | Script-constraining prompt to an audio LLM |
| Best for | Privacy-sensitive users, Thai price point, offline | Weak machines, no model download, highest accuracy |

Two reasons this specific split is load-bearing:

1. **It's the only structure where the privacy moat is real.** The report's #1 defensible position is
   local-only processing under PDPA. A credits-metered cloud-only product cannot make that claim at
   all. And the glossary — the code-switching moat — is *client-side data by nature* (frontmost app,
   git branch names, open-buffer identifiers), so it fits local mode without any server round-trip.
2. **It fixes the free-funnel problem.** The economics table showed premium cloud ASR at **−74% gross
   margin** at ฿199/month once you carry 19 free users per paid one. Putting cloud inference on
   credits means a heavy user funds their own inference instead of your margin funding it.

---

## 0.5 Your users are developers — what that changes

Confirmed after this document's first draft: Phaya's existing users are developers. That is a
material update, and it cuts both ways.

### Why it strengthens the case

**Thai developers are the exact population the measured finding is about.** Re-read the test
sentences that broke Whisper — they were not arbitrary:

```
ช่วย refactor function นี้หน่อย
ช่วย commit แล้ว push ขึ้น branch main ให้หน่อย
เดี๋ยว deploy ให้ก่อนนะ
```

That *is* how Thai developers talk: Thai grammar carrying English technical terms. The words that get
destroyed — `refactor`, `commit`, `push`, `branch`, `deploy` — are precisely the ones a developer
cannot tolerate being wrong. A marketing manager dictating Thai prose barely notices; a developer
dictating a commit message notices every time.

**The glossary engine gets much stronger.** Its whole premise is context a cloud API can't see —
and a developer's machine is *dense* with exactly the right signal: current git branch names,
identifiers in the open buffer, dependency names from `package.json` / `go.mod` / `requirements.txt`,
recent shell history. For a non-technical user the glossary is thin. For a developer it's rich, and
it refreshes every time they switch repos.

**The dominant use case is now dictating to coding agents** — Claude Code, Cursor, Copilot. Prompting
an agent is long-form, conversational, and tedious to type. This is the fastest-growing dictation use
case, and it lands squarely in your users' daily workflow.

**Affordability stops being a problem.** Thai software developers earn ฿30,000–50,000/month against a
฿15,316 national average. ฿199–299/month is 0.4–1% of salary — the price objection that dominates the
Thai consumer market largely evaporates for this segment.

**You have a warm channel.** No cold-start distribution problem for the launch.

### ⚠️ Why it also makes monetisation harder — be honest about this

**Developers are the best fit for the product and the worst fit for subscription revenue.** The
competitor research found this pattern repeatedly:

> *"i didnt want to pay $12/month... so i built my own"*
> *"can be replaced with a 500mb model"*
> *"Just canceled my WisprFlow subscription... to switch to a open source, free, local alternative"*
> — the last posted on the same day as Wispr's $280M raise.

An audience that can rebuild a Whisper wrapper in a weekend is an audience with a permanent
build-vs-buy alternative. Three consequences:

1. **The lifetime tier moves from "nice option" to "central to the model."** Developers resent
   recurring charges for a local tool far more than they resent a one-time price.
2. **The moat must be the part that is genuinely annoying to rebuild.** Nobody rebuilds
   receipt-sequenced clipboard restore, Secure-Event-Input detection, per-app injection quirks, and a
   live git/editor-aware glossary in a weekend. A Whisper wrapper, they absolutely do. **Ship the
   hard parts, not the model call.**
3. **Open-source the thin parts deliberately.** If they'd rebuild the wrapper anyway, publishing it
   buys goodwill and positions the paid product as the integration layer.

### Engineering consequence — the terminal case deserves its own path

For a developer audience, **Secure Event Input moves from priority #2 to priority #1**. It is a
process-global singleton: while any process holds it, *every* event tap on the machine dies. Terminals
opt into it, and **Cursor leaks it 4–7 times daily**, which silently kills dictation, Raycast and text
expanders until quit or screen lock. Wispr ships a help page conceding its own breakage and telling
users to downgrade to hold-to-talk.

That is a competitor's public, structural failure sitting exactly on top of your users' primary
workflow.

**Worth prototyping: bypass the OS event system entirely for terminals and editors.** Instead of
synthesising keystrokes, deliver text through the target's own input channel:

- **Shell** — a `zsh` ZLE widget / `bash bind -x` binding that inserts dictated text straight into the
  readline buffer. No CGEvent, no Accessibility permission, immune to SEI.
- **Editors** — a VS Code / Cursor extension inserting at the cursor via the editor API.
- **Coding agents** — an MCP server or CLI pipe, so dictation reaches the agent as input without ever
  touching the OS input stack.

This sidesteps the single hardest engineering problem in the entire category, for the exact case your
users care most about. No competitor does it, because no competitor's audience is developers-first.

---

## 0.6 Your user base is a data asset that does not exist anywhere in the world

Confirmed: your Phaya developers are **Thai-speaking, working in Thai + English**. That closes the
decisive unknown — the wedge, the audience, and the distribution channel all point at the same people.

But the more valuable consequence is not distribution. It's this:

> **No Thai-English code-switched speech corpus exists.** CS-FLEURS — the largest code-switching
> corpus, 113 language pairs across 52 languages, including a dedicated 45-pair low-resource set —
> contains **no Thai**. SEAME, the *South-East Asia* code-switching corpus, covers Singapore and
> Malaysia and **skips Thailand**. A 127-paper systematic review of code-switching ASR: **"Thai
> receives no mention."**

You have direct, warm access to a population of Thai developers who code-switch constantly — which is
precisely the population no researcher and no vendor has ever collected. **That data is the moat that
compounds**, and it is the one thing Wispr's Canto cannot buy its way to for Thai specifically, because
the corpus doesn't exist for anyone to buy.

### What this unlocks, in order of cost

1. **A real evaluation set (cheap, do it in Phase 0).** Recruit 10–20 Thai devs from Phaya to record
   30 utterances each of genuine work speech. That is ~500 real code-switched utterances — enough to
   replace every synthetic measurement in the research report, and enough to benchmark Wispr,
   Soniox, Gemini and local Whisper against something real. **Nobody else has this.**
2. **A fine-tuning set (later, only if the evaluation justifies it).** Thousands of utterances would
   support fine-tuning a Thai Whisper variant on genuine code-switched speech — attacking the failure
   at the source rather than patching it with a glossary.
3. **A published benchmark (strategic).** Releasing a Thai-English code-switching eval set publicly
   would make you the reference point for a problem nobody has defined, at essentially zero cost. It
   is also excellent Thai developer-community marketing.

### ⚠️ The trap — do not become what you're criticising

Your #1 moat is *"your voice never leaves this laptop."* Wispr's most attackable position is that it
trains on individual paying customers' audio **by default**. If you collect voice data carelessly, you
forfeit the exact advantage you're selling.

Non-negotiable rules if you do this:

- **Explicit opt-in, per recording session. Never a default, never buried in a ToS.** Off by default,
  and visibly off.
- **Separate it entirely from the product.** A deliberate "contribute a recording" flow — not silent
  collection from live dictation. The distinction is what makes the privacy claim survivable.
- **Compensate.** Free lifetime licences for contributors. Devs respond well to an honest trade and
  badly to being harvested.
- **PDPA:** recorded voice contributions are collected for a *stated research purpose* and need
  consent under §23 with the purpose named. Note that the moment you add speaker adaptation or
  voiceprints you cross into **§26 sensitive biometric data** — keep contribution and identification
  strictly separate.
- **Publish what you collect** where you can. It converts a data grab into a community contribution.

Done this way, corpus-building *reinforces* the privacy position instead of undermining it: the
product is local-only, and the corpus is a separate, consented, compensated, published effort.

---

## 1. What you are actually adding to Phaya

```
                        ┌──────────────────────────────────┐
   EXISTING             │  Phaya accounts · credits ledger │   SHARED — reuse as-is
                        │  OAuth server · billing          │
                        └────────────┬─────────────────────┘
                                     │
              ┌──────────────────────┴────────────────────────┐
              │                                               │
   ┌──────────▼───────────┐                       ┌───────────▼──────────────┐
   │  EXISTING            │                       │  NEW                     │
   │  generation job queue│                       │  dictation stream ingress│
   │  submit→poll→wait    │                       │  WebSocket, sub-second   │
   │  (video/image/music) │                       │  (never the job queue)   │
   └──────────────────────┘                       └───────────┬──────────────┘
                                                              │
                                                  ┌───────────▼──────────────┐
                                                  │  NEW  desktop client     │
                                                  │  macOS + Windows         │
                                                  │  local model · glossary  │
                                                  └──────────────────────────┘
```

**Reused unchanged:** accounts, OAuth, credits ledger, billing, invoicing.
**New:** a streaming ingress, an entitlement service, and the desktop client.
**Deliberately not reused:** the async job queue (see §2).

---

## 2. Decision — a second ingress, not a new model kind

**Do not route dictation through `generate_*` → `job_status` → `jobs_wait`.**

That pattern is correct for a 40-second video render. It is wrong for a 2-second utterance. A
submit-then-poll cycle spends your entire latency budget on round-trips.

From the latency research: the competitive completion budget is **≤700 ms from key release to text
on screen**, and push-to-talk only pays off if you stream audio *during* the key-hold and
**force-finalize on release**. A polling queue cannot express "force-finalize now."

**Design:**
- `wss://api.phaya.../v1/dictate` — persistent WebSocket, authenticated by entitlement token.
- Client opens the socket on **key-down**, streams 16 kHz mono frames during the hold.
- On **key-up** the client sends an explicit `{"type":"finalize"}`. Server force-finalizes upstream
  (`Finalize` / `ForceEndpoint` / `input_audio_buffer.commit` depending on provider) — **do not rely
  on the provider's silence timeout**; AssemblyAI's 1536 ms default alone blows the whole budget.
- Server returns partial transcripts during the hold and a final within the budget after release.
- Keep the socket warm across utterances (idle timeout ~60 s) so you don't pay TLS + auth per dictation.

This is a **new path alongside** the job API, sharing auth and the ledger but nothing else.

---

## 3. Decision — billing needs hold/settle, not charge-on-submission

Every current Phaya model prices off input you already have. `phaya-speech-1` bills
`billing_unit: "input_text"` on character count with `charge_timing: "submission"` — you know the
character count before you submit.

**ASR breaks this.** Audio duration is unknown until the user releases the key, and with streaming,
until the stream closes. There is nothing to charge at submission time.

**Recommended: reserve-and-settle.**

| Step | Action |
|---|---|
| Socket open | **Reserve** a small hold (e.g. 60 audio-seconds' worth) against the balance. Reject if insufficient. |
| Stream | Meter actual audio-seconds received, server-side. |
| Finalize | **Settle** the true amount; release the unused hold. |
| Stream dies mid-utterance | Settle on audio actually *received and transcribed*. If no transcript was returned, **release the hold entirely and charge nothing** — the user got no value. Log it. |

**[VERIFY]** This is a change to your ledger *semantics*, not just a new pricing formula. If your
transactions table assumes single-shot debits at submission, it needs a two-phase state
(`held` → `settled` / `released`). Worth checking before anything else here, since it may be the
longest lead-time item.

**Pricing formula shape**, matching your existing convention:

```
billing_unit: "audio_seconds"
formula: max(0.001, round(audio_seconds * RATE_PER_SECOND, 6))
charge_timing: "settlement"
```

---

## 4. Decision — meter audio-seconds, never words

**This is the single most important billing decision, and the obvious choice is wrong.**

Glaido and Wispr both meter "2,000 words per week." Copying that in a Thai product is a trap:

- Thai has **no spaces between words.** Naive whitespace counting **under-bills Thai users by 7.1×**
  — measured: 10 whitespace-tokens vs 71 real words on one Thai paragraph.
- Counting Thai words correctly requires ICU / `NLTokenizer` segmentation server-side — and it still
  fragments proper nouns (`สมชาย` → `สม` + `ชาย`).
- So word-metering is *both* more work *and* systematically wrong, in a direction that gets worse the
  more Thai the user speaks. Your best-fit customers would be your worst-billed.

**Audio-seconds are unambiguous in every language, and they are what your COGS actually scales with.**
Use them for both the credit meter and any free-tier cap.

If marketing wants a "words" number for the pricing page, derive it for *display only* at ~150
words/minute and label it as approximate.

---

## 5. Decision — desktop auth, and the offline case

The login flow is the easy half. The offline case is the one that bites.

**Login — OAuth 2.0 + PKCE, loopback redirect.** A desktop app cannot hold a client secret. Open the
system browser to Phaya's existing authorize endpoint, redirect to `http://127.0.0.1:<random>/cb`,
exchange the code with a PKCE verifier. Do **not** embed a webview and do not ask for a password in-app.

**Token storage:** macOS Keychain, Windows Credential Manager. Never a plaintext config file.

**Entitlement, not a live check.** Local mode must work on a plane. Issue a short-lived signed JWT
carrying the tier claim:

```
{ "sub": user_id, "tier": "local" | "cloud", "exp": <7 days>, "grace_until": <+14 days> }
```

- Refreshed silently whenever the app is online.
- **Grace window: 14 days offline.** Long enough for travel and expired cards; short enough that a
  cancelled subscription doesn't run indefinitely.
- On grace expiry while still offline: **degrade, don't brick.** Keep dictation working with the
  already-downloaded local model in a reduced state (e.g. no cloud fallback, no sync) and show a
  persistent "reconnect to continue" banner. An app that hard-stops mid-sentence on a plane generates
  refund requests and one-star reviews.

**Cloud mode requires connectivity anyway**, so it can check live — but still gate on the same
entitlement so there's one code path.

---

## 6. Data model — new tables

**[VERIFY]** against your existing schema; names are illustrative.

| Table | Purpose | Key columns |
|---|---|---|
| `dictation_devices` | One row per installed client | `user_id`, `device_id`, `platform`, `app_version`, `model_version`, `last_seen` |
| `dictation_sessions` | One row per utterance | `user_id`, `device_id`, `mode` (`local`/`cloud`), `audio_seconds`, `provider`, `latency_ms`, `created_at` — **no transcript, no audio** |
| `credit_holds` | Two-phase billing | `user_id`, `amount_held`, `state` (`held`/`settled`/`released`), `session_id` |
| `dictation_glossaries` | Optional cloud sync of user terms | `user_id`, `terms[]`, `updated_at` — **user-opt-in only** |
| `dictation_entitlements` | Issued JWTs, for revocation | `user_id`, `jti`, `tier`, `issued_at`, `revoked_at` |

**Store no transcripts and no audio by default.** This is the whole privacy position — don't
undermine it for analytics. `dictation_sessions` holds duration and latency, which is everything you
need for billing and performance monitoring, and nothing you'd be embarrassed to disclose in a
PDPA §23 notice.

> **Keep voiceprint and speaker-ID out of v1.** Transcription without a speaker model is *ordinary*
> personal data under PDPA. Add voice enrolment and you fall under **§26 sensitive biometric data**,
> which requires separate explicit consent. This is a schema decision with direct legal force.

---

## 7. The desktop client

The hard parts are not the ASR. In build order of difficulty:

1. **Text injection.** Clipboard-paste with receipt-sequenced restore — copy Handy's `paste_tx/`
   (MIT). Restoring the clipboard on a timer is a race you lose. **Thai forces the clipboard
   anyway**: synthetic keystrokes re-translate under the Kedmanee layout, and the ~20-UTF-16-unit
   delivery limit splits Thai tone marks from their base consonants.
2. **Global hotkey + Secure Event Input.** Detect SEI and degrade gracefully — it is a process-global
   singleton that kills every event tap on the machine, and Cursor leaks it 4–7× daily. Handling this
   well is a genuine differentiator against Wispr, which ships a help page conceding its own breakage.
3. **Pre-warmed audio.** Cold first-access mic startup measured **2,568 ms**; a kept-warm CoreAudio
   HAL unit is **68 ms**. Pre-warm on launch and on system wake.
4. **Ship a `large-v3`-class model, not a small one — this is now a headline product decision.**
   Re-running the experiment at full scale overturned an earlier conclusion: **`large-v3` emits
   Latin-script English inside Thai unprompted** (`เดี๋ยว deploy ให้ก่อนนะ`, exactly right), where
   `ggml-small` transliterated 7/7. It was also **byte-stable across 12 runs** while `small` gave two
   spellings of the same file — repeatability matters for a tool users must trust.

   The cost is real: ~1.5–3 GB download, more RAM, an Apple-Silicon-class machine, slower inference.
   **Take it anyway.** And note the competitive read: rivals default to *small* models for speed, and
   that speed optimisation is precisely why they mangle Thai. Their latency win is your quality win.

   Product consequences: a first-run model download needs real UX (progress, resumability, disk-space
   check — your own disk hit 100% during this research); consider shipping `small` as an instant-start
   default that upgrades to `large-v3` in the background, **but never silently**, since the two
   produce visibly different quality.

5. **The glossary engine — still the moat, but gate every term.** Per-utterance English glossary from
   frontmost app, git branch names, open-buffer identifiers, dependency names, accepted corrections.
   224-token budget, English terms only. **Never leaves the device in local mode.**

   **⚠️ Prompting is not monotonic.** At `large-v3` the same glossary *regressed* `refactor function`
   back into Thai script — with both words in the glossary — and **deleted `meeting` entirely**
   (replicated 3/3). A deleted word is worse than a transliterated one: it leaves no trace for any
   repair layer, and the user cannot see what is missing.

   So the engine needs a **per-term A/B harness, not a static word list**: measure each candidate term
   with and without inclusion, keep the ones that help, drop the ones that regress or delete. Track
   **deletion rate** as a first-class metric alongside English-Term Retention. This is exactly what
   §10's TTS regression harness is for.
6. **Thai cleanup pass.** Royal Society spacing rules (space at every Thai↔Latin boundary), and
   **mask Buddhist-Era years before any LLM call** — `พ.ศ. 2569` → `พ.ศ. 2026` looks well-formed and
   is wrong.

**Stack:** native Swift/AppKit on macOS is the safest choice given how much of this is TCC,
Accessibility, and CoreAudio work. Tauri + Rust is defensible for cross-platform (Handy does it), but
you will still write platform-specific injection code either way.

---

## 8. Pricing shape

Grounded in the Thai market research — Wispr's un-localised price is ฿392–490/month, at or above
Netflix Premium, but they already discount 72% in India, so price against ฿200–320, not ฿490.

| Tier | Price | What it is |
|---|---|---|
| **Free** | ฿0 | Local mode only, capped at ~30 audio-minutes/week. **Costs you nothing** — that's the point. |
| **Local** | **฿199/mo** or ฿1,990/yr | Unlimited local dictation. No credits. The privacy tier. |
| **Cloud** | Local price **+ credits** | Everything in Local, plus metered cloud ASR from the existing balance. |
| **Lifetime** | **฿2,900–3,900** | Local mode forever. The one structure a subscription-native incumbent won't match — and, for a developer audience, **the tier most likely to convert** (see §0.5). Lead with it rather than burying it. |

A free tier that runs entirely on-device is a structural advantage: your competitors' free tiers cost
them real inference money, yours costs bandwidth for one model download.

**Payments:** ~22.6% of Thai adults hold a credit card; PromptPay is near-universal and **Stripe
Thailand supports it natively**. If Phaya already bills in THB, this is solved. **[VERIFY]**

---

## 9. Two privacy postures in one product — say so in the UI

This is the part most teams get wrong, and Wispr got publicly burned on it.

- **Local mode:** no transfer occurs. PDPA §§28–29 obligations *do not apply*. Sub-processor list for
  dictation reads "none."
- **Cloud mode:** cross-border transfer to US providers. Thailand has published **no adequacy
  whitelist**, so you need either SCCs with each sub-processor, or consent obtained *after expressly
  telling the user the destination lacks adequate protection.**

**Make the mode visible at all times** — a menubar indicator showing local vs cloud, not a buried
setting. Ask for cloud consent once, explicitly, at the moment of first cloud use. Never silently
fall back from local to cloud; if the local model fails, say so and let the user choose.

---

## 10. Free CI harness — use Phaya's own TTS

`phaya-speech-1` supports Thai across 21 voices at fractions of a credit. That is a **regression
harness for the glossary engine**: generate the same Thai+English sentences across many voices, run
them through the pipeline nightly, and track ETR (English-Term Retention) and Thai CER.

This does **not** replace recording your own voice — a real bilingual speaker's English phonology is
precisely what's being tested, and all measurements so far used synthetic audio. But it catches
"did my glossary change break Thai accuracy" for almost nothing, across far more voices than you'd
record by hand.

---

## 11. Build phases

**Phase 0 — validate before building (1 week).** Run Steps 0–2 from the research report: record real
utterances, three-way ASR bake-off **scored both with and without the glossary**, benchmark Wispr on
identical clips. **If Wispr already emits
clean consistent Latin-script inserts, stop and rethink the positioning** — you'd be building a
distribution play, not a technology one, and this architecture would change.

**Phase 1 — ledger and auth (2 weeks).** Two-phase credit holds. Entitlement JWT issuance and
revocation. OAuth PKCE loopback flow. All server-side, all testable without a desktop app.

**Phase 2 — desktop client, local-only (4–6 weeks).** Hotkey, pre-warmed audio, local model download
and management, clipboard injection with receipt restore, **SEI detection (priority #1 for a dev
audience)**, Thai cleanup pass. **Ship this as the whole product if you must** — it needs no streaming
ingress at all.

**Phase 2.5 — the developer injection path (1–2 weeks). Promoted, given §0.5.** Shell ZLE widget and
a VS Code/Cursor extension that insert text through the target's own input channel rather than
synthetic keystrokes. Small, high-leverage, and it makes the product work in exactly the place every
competitor breaks. Consider doing this *before* Phase 3.

**Phase 3 — cloud mode (2–3 weeks).** WebSocket ingress, force-finalize, hold/settle wired to real
metering, consent flow, mode indicator.

**Phase 4 — the glossary engine (2–3 weeks).** The moat. Deliberately last: it needs the client to
exist, and it's where the differentiation lives. Budget the extra week for the **per-term A/B harness**
— prompting was measured to regress and even delete terms, so a static word list is not enough.

Note that **Phase 2 alone is a shippable product**, and it is the one carrying the privacy claim.
Cloud mode is an upsell, not a prerequisite.

---

## 12. Open questions for you

1. **[VERIFY]** Does your credits ledger support two-phase holds today, or are transactions
   single-shot debits? This is likely the longest lead-time change.
2. **[VERIFY]** Do you already have an OAuth authorization server, or do accounts use API keys only?
   PKCE needs a real authorize endpoint.
3. **[VERIFY]** Do you bill in THB with PromptPay today, or USD cards only?
4. What's Phaya's backend stack? It changes the Phase 1 estimate materially.
5. ~~Do Phaya's existing users overlap with this audience?~~ **Answered: they're developers.** See
   §0.5 — this is a real distribution advantage and a sharper product fit, but it raises the
   build-vs-buy risk and pushes weight onto the lifetime tier.
6. ~~Are your Phaya developers Thai-speaking or international?~~ **Answered: Thai-speaking,
   Thai-focused, working in Thai + English.** The research thesis applies directly, and the
   distribution channel points at the exact target population. See §0.6.
7. Roughly how many active Phaya users are there? At ฿199–299/month with a dev audience, the launch
   list size determines whether this is worth 3 months of your time.
8. **Would your users opt into contributing voice samples?** See §0.6 — this is the highest-value
   question left, and it's a trust question, not a technical one.
