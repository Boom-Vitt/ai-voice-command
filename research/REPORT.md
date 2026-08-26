# Building a Thai + English Voice Dictation App
### Deep research report — 2026-08-24

Ten parallel research agents; ~60,000 words of sourced briefs in `research/briefs/`.
Every claim below is tagged: **[MEASURED]** = run on this machine today · **[DOC]** = vendor/primary
documentation · **[3P]** = third-party evaluation · **[MKTG]** = marketing claim ·
**UNVERIFIED** = could not be sourced.

---

## 1. Bottom line

**Build it — but not the product you set out to build, and not for the reason you expected.**

Three of the four premises this project started from turned out to be false. The fourth — the one
that survived — is narrower, sharper, and **measurably tractable**, and it is defended by an
accident of the Thai NLP research community that is unlikely to correct itself soon.

| Premise | Verdict |
|---|---|
| "Nobody serves Thai dictation" | **FALSE.** Wispr Flow specifically optimised Thai; Windows 11, Google, and every Whisper wrapper list it. |
| "US incumbents ignore code-switching" | **FALSE.** Wispr sells *Hinglish as a named language* in India at a 72% discount, and accepts UPI. |
| "Speaking Thai is much faster than typing it" | **UNSUPPORTED.** Thai typing benchmarks use 4 keystrokes/word vs English's 5; Thai is 23% *more* compact per keystroke. |
| **"Thai+English mixed in one sentence is broken"** | **TRUE, MEASURED, AND FIXABLE.** This is the entire business. |

The product is not "faster dictation." It is **"we write your English words in English."**

---

## 2. The measured core

This is the part no one has published. A local Whisper was run against Thai audio containing English
technical terms. All results **[MEASURED]** on macOS 26.5.1.

> **Read §2.3 before acting on §2.1.** The failures below were measured on `ggml-small` (487 MB).
> Re-running on `large-v3` **overturned two conclusions** — the transliteration failure is
> scale-dependent, and the glossary fix is non-monotonic. §2.1 is retained because it is the honest
> record of what a small model does, and because it is what every competitor shipping a small local
> model is doing to their users.

### 2.1 Both obvious settings fail, and the second fails dangerously

| Ground truth | `language=th` | `language=en` |
|---|---|---|
| เดี๋ยว **deploy** ให้ก่อนนะ | เดี๋ยว **ดิบโล้ย** ให้ก่อนนะ | `Wait, deploy, I'll give you a call.` |
| **meeting** ตอนบ่าย 3 โมง | **มีทิ้ง** ตอนบาย 3 โมง | `meeting, Ton Bai Sam Mung.` |
| ช่วย **refactor function** นี้หน่อย | ช่วย **เรฟาเทอร์ฟังชัน** นี้หน่อย | `Refrigerator Function, Ninoi.` |
| ช่วย **commit** แล้ว **push** ขึ้น **branch main** | ช่วย **คือมีค** แล้ว **พุษคืน รันสมีน** | `(speaking in foreign language)` |

- **`language=th`: Thai is correct, and 7 of 7 English terms are destroyed** — forced into Thai script.
- **`language=en`: English survives, but the Thai is *hallucinated*.** "let me deploy it first"
  became *"I'll give you a call."* For a dictation tool, silently fabricated sentences are the worst
  possible failure — the user pastes confident nonsense into a client email.
- **`auto` is not a third option** — byte-identical to `language=th`.

### 2.2 Three distinct failure modes, only one of which is repairable

1. **Systematic transliteration** — `refactor→เรฟาเทอร์`. Phonetic shadow survives; likely recoverable.
2. **Substitution into a real word** — `meeting→มีทิ้ง` is *readable Thai*; `refactor→"Refrigerator"`
   is an ordinary English word. **Nothing downstream can flag this.** Information destroyed.
3. **Merge/loss** — `branch main` (2 tokens) → `รันสมีน` (1). Boundary gone.

**And a repair dictionary is impossible:** two runs of the *identical file* produced **ดีโพล้อย** and
**ดิบโล้ย**. There is no stable key. Any repair must be a semantic LLM pass, never a lookup.

### 2.3 The finding the business rests on

**⚠️ REVISED 2026-08-24 after re-running at full model scale. Two earlier conclusions were wrong.**
The headline — *the Latin-script barrier is soft* — survives and is now confirmed twice over. The
*mechanism* changed.

**Correction 1 — transliteration is scale-dependent, not universal.** Everything in §2.1 was measured
on `ggml-small` (487 MB). Re-run on **`large-v3`** (3.1 GB), `language=th`, **with no prompt and no
configuration at all**:

| Ground truth | `small` | **`large-v3`, unprompted** |
|---|---|---|
| เดี๋ยว **deploy** ให้ก่อนนะ | ดิบโล้ย ❌ | **เดี๋ยว deploy ให้ก่อนนะ** ✅ exactly right |
| ช่วย **refactor function** นี้หน่อย | เรฟาเทอร์ฟังชัน ❌ | **ช่วย Refrater Function นี้หน่อย** — Latin script |

**ETR 0/7 → 2/7 clean + 1 partial, for free.** The `<|th|>` token is *not* a hard Latin-script ban —
a large enough model crosses it unaided.

**This strengthens the local recommendation.** Pathumma-Whisper-L3 and Typhoon-Whisper-L3 are both
`large-v3` fine-tunes, so they inherit this behaviour *before* any Thai tuning. (Inference from shared
lineage — not yet measured on those models directly. That is Step 1.)

**Correction 2 — the glossary is not monotonic. It can subtract.** At `large-v3`, the same eight-word
glossary:

- **regressed** `refactor function` from correct Latin back into Thai script — *with both words in the glossary*
- **deleted `meeting` entirely** (`มีทิ้ง ตอนบ่าย 3 โมง` → `ตอนบ่าย 3 โมง`)
- but recovered all four of `commit, push, branch, main`

Replicated **3× in each condition; both reproduce 3/3.** Systematic, not noise.

Both model sizes land at 5/7 with the glossary — **but not on the same five words.** The glossary
changes *which* terms survive, not reliably *how many*.

> **A deleted word is worse than a transliterated one.** Transliteration leaves a phonetic shadow a
> repair pass can work with. Deletion leaves nothing — no repair layer can recover a word that was
> never emitted, and the user cannot see what is missing. **Track deletion rate as a first-class
> metric alongside ETR.**

**Revised conclusion:** the primary lever is **base-model scale**; the glossary is a secondary,
double-edged tool that must be evaluated per-term rather than assumed to help. The problem is still
an integration problem rather than a research frontier — but "just add a glossary" was too simple.

Standing caveats: audio is synthetic (macOS `say -v Kanya`), so the *pattern* is the finding, not the
absolute numbers. `initial_prompt` caps at **224 tokens**, introduces spurious commas, and corrupted
an adjacent Thai word (`ขึ้น`→`คืน`). One bonus finding: `large-v3` was **byte-stable across all 12
runs**, while `small` produced two different spellings of the same file — larger models are more
*repeatable*, not merely more accurate, which matters for a product users must trust.

### 2.4 Why the glossary is a moat and not a feature

A glossary only helps if it contains *the right words for this utterance*. A desktop app knows things
a cloud API cannot: **the frontmost application, the current git branch names, identifiers in the open
buffer, dependency names, and the user's accepted corrections.** That is a per-utterance, context-derived
English glossary — a moat mapped directly onto a measured mechanism, inside a 224-token budget.

---

## 3. Why this gap exists, and why it persists

Not an oversight — a structural blind spot with four independent causes.

1. **Whisper is architecturally biased against it — though not absolutely.** *"Whisper's language and
   task tokens cannot explicitly direct the model to do code-switching ASR, with each language token
   only representing one language."* [arXiv 2412.16507] **[DOC]** whisper.cpp's maintainer: *"Code
   switching is currently an unsolved problem in AI"* [whisper.cpp#749].
   **⚠️ Reconciling this with §2.3:** the architectural claim is about what the language token can be
   *directed* to do, and it stands. But empirically a `large-v3` model **crosses the barrier anyway**,
   unprompted — the bias is strong, not absolute. So the correct statement is that Whisper-based
   competitors inherit a *handicap*, not an impossibility, and **the size of the model they ship
   determines how badly they suffer it.** Superwhisper, MacWhisper, VoiceInk, Better Dictation,
   Spokenly and Handy all inherit that handicap — and several default to small models for speed.
2. **The cloud tier excludes Thai specifically.** Deepgram's `multi` code-switch model: 10 languages,
   **Thai absent**. AssemblyAI's native mid-sentence code-switching: 18 languages, **Thai absent**
   (Vietnamese is in). Speechmatics ran a deliberate Southeast Asia bilingual push — shipped
   Mandarin/Malay/Tamil/Tagalog-English, **skipped Thailand**. Azure: *"doesn't support changing
   languages within the same sentence."* **[DOC]**
3. **Academia has never looked.** CS-FLEURS, the largest code-switch corpus (113 pairs, 52 languages,
   including a 45-pair low-resource set) contains **no Thai**. A 127-paper systematic review of
   code-switching ASR: **"Thai receives no mention."** SEAME — the *South-East Asia* code-switching
   corpus — covers Singapore and Malaysia and **skips Thailand**. **No Thai-English code-switch speech
   corpus exists.**
4. **⚠️ The Thai NLP community scores the desired behaviour as a *defect*.** Typhoon2-Audio's
   "Code-Switching" benchmark defines accuracy as: *"The response does not contain characters from
   other languages."* [arXiv 2412.13702] **[DOC]** A model scoring 100% **never emits `deploy` in
   Latin script.** Thai-first models are being optimised in the opposite direction.

> The people who could fix this don't speak Thai, and the people who speak Thai are optimising a
> benchmark that punishes the fix.

**But the clock is real.** Wispr announced **Canto** alongside its $280M Series B (17 Aug 2026) — its
first proprietary speech model, explicitly targeting *"half the world [that] moves between languages…
often inside a single sentence."* Their current docs still say the opposite. **Window: ~18–24 months.**

---

## 4. Recommended architecture

### 4.1 ASR — run a three-way bake-off before choosing

| Path | Evidence | Why |
|---|---|---|
| **Local Whisper large-v3 class** — Pathumma-Whisper-L3 (Apache-2.0) or Typhoon-Whisper-L3 | **[MEASURED]** 2/7 unprompted at `large-v3`; 5/7 with glossary, but non-monotonic | Highest-confidence option, and the only one that *composes with the privacy moat*. **Choose on base-model scale first**, glossary second. |
| **Audio-native LLM** — Gemini 3 Flash/Pro, non-streaming | **[3P]** Thai CER 10.95 (Pro only) | **The only category where you can constrain *output script* by instruction** rather than hope. $0.027–$0.09/audio-hour. |
| **Soniox `stt-rt-v5`** | **[MKTG]** only | The *only* vendor documenting Thai mid-sentence switching, with a Thai example emitting `to-go` in Latin. Sub-200 ms, $0.12/hr. **Zero published Thai WER — test day one.** |

**Do not build:** two parallel ASR passes merged (Gladia published the number that kills it — **13% →
41% WER** intra-utterance on Spanish-English, the best-resourced pair on earth); Whisper at
`language=en`; Typhoon ASR Realtime as primary (it is a Transducer — **no `initial_prompt` hook**, so
the measured fix does not port).

**Stale anchor corrected:** Thonburian Whisper's widely-cited 6.59% Thai WER was clean read speech.
On the 2026 Thai leaderboard it is **last of eight**, at **18.96% CER on TVSpeech** — the benchmark
built from technical jargon and proper nouns, i.e. the closest proxy for this workload. Do not
architect around it.

### 4.2 ⚠️ The privacy moat and the code-switching moat nearly cancelled each other

Worth stating because it almost sank the plan. Every *local* Thai path is a single-language decoder:
Apple `SpeechTranscriber` has **no Thai at all** [MEASURED]; `SFSpeechRecognizer` is one locale per
instance by construction; the Whisper family has one language token. So *"your voice never leaves
your laptop"* and *"we write your English words in English"* looked mutually exclusive.

**§2.3 is what rescues it — and the revised version rescues it harder.** A `large-v3`-class local
model emits Latin-script inserts **unprompted**, before any glossary is applied. **This is the
load-bearing result of the entire report**: it is the only reason both claims can hold for one
product, and it now rests on model choice rather than on a prompting trick. If it fails to replicate
on real recorded speech, the two moats separate again and you must choose one.

### 4.3 Apple's free path is closed for Thai — which is itself a moat

**[MEASURED]** on macOS 26.5.1:

```
SpeechTranscriber.supportedLocales = 30 — de/en/es/fr/it/ja/ko/pt/yue/zh — THAI ABSENT
SFSpeechRecognizer.supportedLocales = 63 — th-TH present, supportsOnDevice = TRUE
```

This **corrects a published blog claim** that `SpeechTranscriber` covers Thai across ~34–42 locales.
English-only competitors get a free, fast, private, zero-COGS OS engine. **For Thai, nobody does.**
Everyone must ship their own model — which raises your cost *and* every competitor's.

Worth 30 minutes regardless: `SFSpeechRecognizer(th-TH)` + **`contextualStrings`** is Apple's
keyword-boosting hook — the same mechanism as §2.3, free, no download. Untested: a bare CLI binary is
killed by TCC without an `.app` bundle carrying `NSSpeechRecognitionUsageDescription` (diagnosed and
reproduced today). Wrap it in a bundle and run it.

### 4.4 Latency: two clocks, and one invisible bug

Do **not** stack Nielsen/Doherty/RAIL into a single budget — they measure different things.

| Clock | Starts | Ends | Target |
|---|---|---|---|
| **Acknowledgment** | hotkey down | visible capture indicator | **≤100 ms** |
| **Completion** | key **release** | text in the target app | ≤500 ms stretch · ≤700 competitive |

The literature requires *acknowledgment* in 100 ms, not text. The acknowledgment clock is cheap and
creates most of the "instant" impression. (Wispr's own published target is 700 ms.)

**Push-to-talk is the largest single win available, and it is free** — it replaces a *speculative
silence timeout* with a *deterministic finalize event*. AssemblyAI's default `max_turn_silence` is
**1536 ms**, which alone exceeds a 700 ms budget by 2×.

> **⚠️ The trap.** PTT only pays off if you *both* disable server-side turn detection *and* explicitly
> force-finalize on release (`Finalize` / `ForceEndpoint` / `input_audio_buffer.commit`). Miss either
> and it silently degrades to voice-assistant latency. It doesn't error — it just feels slow.

**[MEASURED]** mic warm-up, macOS 26 / Apple Silicon: **2,568 ms cold** on first access ·
~250 ms warm AVAudioEngine · **68 ms** for a kept-warm CoreAudio HAL unit. Pre-warming on launch and
on system wake is mandatory, not an optimisation.

### 4.5 Text injection — inject via clipboard, and for Thai this is not optional

| Target | Approach |
|---|---|
| Native macOS text controls | AX `kAXSelectedTextAttribute` — inserts at caret, no clipboard, no undo spam |
| **Electron/Chromium** (VS Code, Slack, Discord, Notion) | **Clipboard paste** — the AX tree isn't built, and the flag to build it is itself broken (electron#37465) |
| Terminals | Clipboard paste, **but detect Secure Keyboard Entry first** |
| Windows | `SendInput`+`KEYEVENTF_UNICODE`; clipboard above ~200 chars |
| Elevated Windows / password fields | **Nothing works. Detect and tell the user.** |

**Thai forces the clipboard.** **[MEASURED]** with the Thai Kedmanee layout active, synthetic keystroke
injection re-translates virtual keycodes — Apple's own docs concede frameworks "may ignore the Unicode
string… and do their own translation based on the virtual keycode." Add an undocumented ~20-UTF-16-unit
delivery limit: **the first 20 Thai graphemes are 26 UTF-16 units**, so naive chunking splits tone
marks from their base consonants and produces visible mojibake.

**Copy Handy's `paste_tx/` outright (MIT)** — restoring the clipboard on a *timer* is a race you lose;
it publishes a lazy pasteboard promise and restores only after the OS confirms a consumer read it.
Also copy its `resolve_command_v_keycode()` — `keystroke "v"` breaks on Dvorak/AZERTY/Cyrillic.
(VoiceInk is **GPL-3.0** — architecture only, don't lift code.)

### 4.6 Thai text engineering — where the second, quieter win is

- **"Auto-punctuate" in Thai means auto-*space*.** Thai has no sentence period. The Royal Society
  publishes 22 numbered spacing rules; a space is required at every Thai↔Latin boundary. **[DOC]**
  And Thai dictation users on Pantip report the words come out roughly right and **the spacing comes
  out wrong** — a cheap LLM pass fixes exactly that. This may be a bigger perceived-quality win than
  code-switching itself.
- **Buddhist Era dates are the highest silent-corruption risk.** `พ.ศ. 2569` → `พ.ศ. 2026` looks
  well-formed and is wrong. **Mask years before the LLM call.**
- **Word segmentation is free on macOS.** `NLTokenizer` / `NSLinguisticTagger` / `CFStringTokenizer`
  all produce byte-identical correct Thai segmentation — no Python, no PyThaiNLP. **[MEASURED]**
  This matters commercially: naive whitespace counting **under-bills Thai users by 7.1×** (10 vs 71
  words on one paragraph). But proper nouns fragment (`สมชาย`→`สม`+`ชาย`), so it is fine for metering
  and **not** for dictionary matching — longest-match your own terms first.
- **The token tax is real but ~2.5× smaller than folklore.** **[MEASURED]** with `tiktoken`: on
  **o200k** (GPT-4o/4.1) Thai costs only **1.33–1.85×** English, not the 4× commonly claimed — o200k
  has real Thai subwords. On **cl100k** it is 2.4–4.6×, ~1 token per character, 20% mid-UTF-8 byte
  fragments. **Use an o200k-era model.** Free lever: Thai numerals `๒๕๖๙` = **7 tokens** vs `2569` =
  **2** — normalise before the call.

---

## 5. Economics — and why the Thai price changes the answer

At **$20/month** the research concluded ASR cost is irrelevant: every credible provider clears 90%
gross margin. **At a Thai price point that conclusion inverts.**

Recomputed at ฿199 / ฿299 (FX 32.67, 21 Aug 2026), including the 19 free users each paid user must
carry at 5% conversion:

| Provider | Paid user | +19 free | Total | **GM @ ฿199** | **GM @ ฿299** | GM @ $20 |
|---|---|---|---|---|---|---|
| **Local** (own model) | $0.023 | $0.099 | $0.122 | **98.0%** | **98.7%** | 99.4% |
| **Groq whisper-turbo** (batch) | $0.198 | $0.835 | $1.032 | **83.1%** | **88.7%** | 94.8% |
| AssemblyAI Universal-Streaming | $0.673 | $2.844 | $3.518 | 42.2% | 61.6% | 82.4% |
| Deepgram Flux | $2.025 | $8.555 | $10.580 | **−73.7%** | −15.6% | 47.1% |
| OpenAI gpt-live-transcribe | $4.443 | $18.768 | $23.212 | −281% | −154% | −16.1% |
| Google Chirp (logging off) | $6.263 | $26.456 | $32.719 | −437% | −258% | −63.6% |

**The free tier, not the paid user, is what kills you.** Premium streaming providers that are
comfortably profitable at $20 go *deeply negative* at ฿199. At Thai pricing your viable set is
**local inference or cheap batch inference — nothing else.**

This is a second, independent argument for the local path, arriving from a completely different
direction than privacy.

**Also note the privacy premium:** Google charges **+50% to turn data logging off**; Deepgram's listed
prices are tied to a programme under which it *stores your audio to train on*. Budget **1.5–2×** on
any cloud quote where the privacy claim is load-bearing. The headline prices are, for at least two
major vendors, the *surveillance* price.

---

## 6. Competitive and legal reality

**Wispr Flow is the real competitor, not Glaido** — $280M Series B at $2B (17 Aug 2026), $361M total,
60B words written, "almost all of the Fortune 500", iOS 4.83 across 14,159 ratings.

**Their exposed flank is privacy, and it is unusually wide:**
- **Context Awareness is ON BY DEFAULT and transmits a screenshot of your screen with each dictation** **[DOC]**
- Audio and transcripts *"may be used to evaluate, train, and improve Wispr's models. This is the
  default for trial and standard accounts."* Only Enterprise/HIPAA get Privacy Mode by default. **[DOC]**
- **No on-device option exists at all.** Their DPA lists **34 sub-processors, every one US-located.**
- SOC 2 Type II is claimed in marketing while their own security FAQ says it is *"not yet issued"* —
  both prior certificates were self-invalidated in March 2026.
- In late 2025 they were caught sending screenshots of active windows to the cloud, **and banned the
  user who reported it.**

**Thailand's PDPA turns that flank into a legal argument.** Thailand has published **no adequacy
whitelist**, so the §28 adequacy route is unusable in practice. Sending Thai voice to US servers
requires either SCCs with every foreign sub-processor, or consent obtained *after expressly warning
the user the destination lacks adequate protection*. **Local-only processing deletes the §§28–29
obligation entirely** — no transfer occurs — and shrinks the §23 "who we disclose to" line to *"no one."*

> **Product-design consequence with direct legal force: keep voiceprint / speaker-ID out of v1.**
> Transcription without a speaker model is *ordinary* personal data. Add voice enrolment and you fall
> under §26 sensitive biometric data, requiring separate explicit consent.

**Pricing.** Wispr Pro costs a Thai buyer **฿392–490/month** — at or just above Netflix Premium
(฿419), Thailand's most expensive mainstream subscription, and 2–2.5× YouTube Premium (฿199), for a
typing accessory used by one person. But **do not treat that as structural**: Wispr already charges
**₹400 (~฿137, a 72% discount) in India and accepts UPI**. An income-tiered Thai price would plausibly
be **฿200–320**. Price against *that*, not against ฿490.

Recommended: **฿199–299/month, ฿1,990–2,490/year, plus a ฿2,900–3,900 lifetime tier** — a one-time
purchase is the one structure a subscription-native incumbent is least willing to match. Note that
only **22.6% of Thai adults hold a credit card** while PromptPay has ~100% adult coverage, and
**Stripe Thailand supports PromptPay natively** (requires a Thai entity).

**Tax traps for a solo founder:** VAT registration threshold is ฿1.8M/yr turnover (~750 subscribers at
฿199) — but you **cannot issue a compliant ใบกำกับภาษี without registering**, and many Thai companies
won't buy without one. B2B also carries 3% withholding tax. **B2C self-serve is dramatically
lower-friction; don't chase Thai enterprise logos early.**

---

## 7. The build sequence

**Step 0 — Record 20 real utterances of your own voice. Half a day. Before anything else.**
Everything measured so far used synthetic TTS. You are the target user. This is the highest
leverage-to-cost step available, and it validates or kills §2.3.

**Step 1 — Three-way bake-off (2 days, under $1 of credit).** Same 20 clips through Soniox, Gemini
3 Flash *and* Pro (prompt: *"Transcribe verbatim. Keep English technical terms in Latin script. Never
transliterate English into Thai script. Do not translate."*), and Pathumma-Whisper + `initial_prompt`.

**Score every engine BOTH with and without the glossary** — prompting was measured to *subtract* at
`large-v3`, so a single-condition test will mislead you. **Plain WER is invalid for code-mixed text**
[arXiv 2211.16319]; use three numbers:
> **ETR (English-Term Retention)** = English tokens emitted in Latin script ÷ English tokens spoken.
> **Deletion rate** = English tokens emitted *nowhere, in any script*. Worse than transliteration —
> nothing downstream can recover them. New, and non-optional.
> **Thai CER** on the surrounding Thai, English spans excluded — the regression guard, since biasing
> demonstrably corrupted an adjacent Thai word.

**Step 2 — Benchmark the incumbents on the same 20 clips (½ day, ~$15).** Wispr Flow, Monologue
(the one competitor claiming mid-sentence switching), Superwhisper. Score identically. **This decides
the pitch:** if they emit clean, consistent Latin-script inserts, the technology wedge is dead and
this becomes a local distribution business. If they flip-flop, you have a 10-second demo video.

**Step 3 — Measure repair recoverability *blind* (½ day).** Strip ground truth, hand `language=th`
outputs to an LLM cold, score recovered / substituted-into-a-real-word / merged-or-lost. The
substituted+lost fraction is the hard ceiling on any repair strategy.

**Step 4 — Unblock the free Apple path (1 day).** Wrap the probe in an `.app` bundle with
`NSSpeechRecognitionUsageDescription`; test `SFSpeechRecognizer(th-TH)` with and without
`contextualStrings`. Zero cost, zero download if it works.

**Step 5 — Build the glossary engine (1 week). Still the moat — but gate every term.** Per-utterance English glossary
assembled from frontmost app, git branch names, open-buffer identifiers, dependency names, and
accepted corrections. 224-token budget, English terms only, rotated by context. **Because prompting
can regress or delete terms, the engine needs a per-term A/B harness, not a static word list.**

**Then** the app shell: PTT hotkey with force-finalize, pre-warmed CoreAudio, clipboard injection with
receipt-sequenced restore, Thai spacing/BE-date cleanup pass.

---

## 8. Honest risks

- **Wispr's Canto is aimed directly at this.** ~18–24 month window.
- **You would be entering behind on Thai**, not into a vacuum — Wispr already has Thai TikTok reviews
  and Thai Facebook coverage.
- **The dominant Thai code-mixing pattern is lexical insertion** (English nouns in Thai syntax) — which
  is the case Wispr's docs claim it *does* handle. The surviving gap is output *script*, not
  capability. **Step 2 is what confirms or kills this.**
- **The market is thin.** Thai average wage ฿15,316/mo; Thailand is 195 iOS ratings vs India's 2,572.
  Realistic scale is a **฿10–50M/yr local software business**, not a venture outcome. Whatever is built
  for Thai should generalise to Hinglish/Taglish/Manglish — but note those advantages don't transfer:
  PromptPay, PDPA, and Thai invoicing are jurisdiction-specific by construction.
- **The leader is commoditising the category** — Wispr's free tier now includes 100+ languages and a
  notetaker. Selling "better dictation" means competing with free.

---

## 9. What I could not verify

- **Real-voice replication of the scale and glossary results.** All audio was synthetic. *Step 0.*
- **Whether Pathumma / Typhoon Whisper inherit `large-v3`'s unprompted Latin-script behaviour.**
  Inferred from shared lineage; not measured on those models. *Step 1.*
- **Soniox's Thai quality.** Vendor marketing only; zero published Thai WER.
- **Gemini's Thai accuracy at the Flash tier.** The cheap pricing is Flash; the only Thai benchmark is
  **Pro**. These do not currently meet.
- **Whether an audio LLM actually obeys a script-constraining instruction for Thai.** No vendor
  documents it. This is the crux of the top recommendation and is currently *inferred*.
- **Deepgram's opt-out discount** — whether declining data-training forfeits ~50%. Ask in writing.
- **Windows AI Speech Recognition's language list** — Microsoft publishes none. If Thai is absent, the
  Windows story mirrors macOS.
- **Reddit** was unreachable from the research environment; r/macapps and r/LocalLLaMA were not covered.
