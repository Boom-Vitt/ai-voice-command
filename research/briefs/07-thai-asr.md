# Thai + English Code-Switching ASR — Deep Research Brief
**Research date: 2026-08-24.** Status: COMPLETE.

> **Rule applied throughout:** every WER / price / capability claim carries the URL it was read from,
> or is prefixed `UNVERIFIED:`. Nothing recalled from memory.

## Known anchors (from prior pass — not re-verified here)
- Thonburian Whisper (biodatlab) Thai WER, CommonVoice 13 + deepcut tokenizer: large-v3 **6.59%**, medium **7.42%**, large-v2 **7.69%**, small **11.0%** — https://github.com/biodatlab/thonburian-whisper
- Apple SpeechTranscriber (macOS 26) includes `th_TH`; ~34–42 locales; per-language model download; **ONE locale per instance** — https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide
- Deepgram Nova-3 supports Thai, but its `multi` code-switching model covers only EN/ES/FR/DE/HI/RU/PT/JA/IT/NL — **Thai excluded** — https://developers.deepgram.com/docs/models-languages-overview
- Wispr Flow instructs users to select only the language currently being spoken → no true code-switching — https://wisprflow.ai/

---

## EXECUTIVE SUMMARY — the five things that matter

1. **⛔ An anchor is wrong, measured on this machine.** Apple `SpeechTranscriber` on shipping macOS 26.5.1 has
   **30 locales and NO Thai**. Only the legacy `SFSpeechRecognizer` has `th-TH`. The free modern Apple path
   English-only competitors use is closed for Thai. (§0)
2. **★ Whisper's failure is measured, not reported.** At `language=th`, **7 of 7** English terms were pushed
   into Thai script (`deploy→ดิบโล้ย`, `meeting→มีทิ้ง`). At `language=en` the English survives but the **Thai is
   hallucinated**. Autodetect = identical to `th`. (§1.6)
3. **★★ An 8-word `initial_prompt` glossary fixed most of it: English-term retention went 0/7 → 5/7**, on a
   487 MB `small` model. This is the highest-confidence, lowest-cost finding in the brief. (§1.7)
4. **Exactly one commercial vendor puts Thai inside a code-switching capability: Soniox** — and its Thai docs
   carry a real Thai-English example with `to-go` in Latin script. Speechmatics, AssemblyAI, Deepgram, Azure,
   Gladia and Google all exclude Thai from code-switching, or exclude within-sentence switching entirely. (§1)
5. **The gap is structural, not technical.** No Thai-English code-switch corpus exists (CS-FLEURS: 113 pairs,
   no Thai). The 127-paper CS-ASR review never mentions Thai. And Thailand's own leading benchmark scores a
   model **higher for emitting no Latin characters** — the Thai NLP community treats this product's goal as a
   defect. (§2.1, §3, §7)

**Recommendation in one line:** prototype **Soniox** and a **script-constrained Gemini prompt** (test Flash *and*
Pro — the cheap tier has no published Thai number) against
**Pathumma-Whisper + a dynamic English glossary**, scored on *English-Term Retention* (not WER), using 20 real
utterances. Under $1 and about a week. (§5, §6)

## Index
*Sections appear below in research order, not numeric order — use this index to navigate.*

| § | Contents |
|---|---|
| **0** | MEASURED: Apple Thai locale probe — corrects a stated anchor |
| **1** | Vendors: Speechmatics, Soniox, AssemblyAI, Azure, Google, others (§1.8 = summary table) |
| **1.6** | ★ MEASURED: Whisper on mixed Thai+English |
| **1.7** | ★★ MEASURED: `initial_prompt` biasing fixes most of it |
| **2** | Thai-first models + **the 2026 Thai ASR leaderboard** (§2.4); Thai vendor THB pricing (§2.6) |
| **3** | Academic work — and the corpus that does not exist |
| **4(a)** | LLM restoration of transliterated English — two failure modes |
| **4(b)** | Custom vocabulary / keyword boosting — which APIs support it *with Thai* |
| **4(c)** | Two parallel ASR passes — rejected on evidence |
| **4(d)-i / -ii** | ★ Audio-native LLMs — why they differ, open weights, verified pricing, controllability |
| **5** | **RANKED RECOMMENDATION** (with evidence grades) |
| **6** | **WHAT TO PROTOTYPE FIRST** |
| **7** | Strategic picture |

---

## 0. MEASURED ON THIS MACHINE — correction to an anchor

Ran a Swift probe (`thaiLocales.swift`, in this scratchpad) against the live Speech framework on
**macOS 26.5.1 (Build 25F80)**, 2026-08-24. Raw output:

```
=== SpeechTranscriber.supportedLocales count=30
de-AT de-CH de-DE en-AU en-CA en-GB en-IE en-IN en-NZ en-SG en-US en-ZA es-CL es-ES es-MX
es-US fr-BE fr-CA fr-CH fr-FR it-CH it-IT ja-JP ko-KR pt-BR pt-PT yue-CN zh-CN zh-HK zh-TW
=== THAI in supportedLocales: NO
=== SFSpeechRecognizer.supportedLocales count=63
=== THAI in SFSpeechRecognizer: th-TH
=== SFSpeechRecognizer(th-TH): available=true supportsOnDevice=true
=== CONTROL SFSpeechRecognizer(en-US): available=true supportsOnDevice=true
```

### ⛔ The anchor "Apple SpeechTranscriber (macOS 26) includes th_TH" is WRONG on shipping macOS 26.5.1.

- `SpeechTranscriber` (the **new**, fast, macOS-26 API — the one every 2026 dictation app wants) supports
  **30 locales**, covering only German, English, Spanish, French, Italian, Japanese, Korean, Portuguese,
  Cantonese and Chinese. **There is no Thai.** No `th-*` entry of any kind.
- Thai on Apple is only reachable through the **legacy `SFSpeechRecognizer`** (63 locales), which does list
  `th-TH` and reports `supportsOnDeviceRecognition = true`.
- The substack figure of "~34–42 locales incl. th_TH" appears to have been read from a beta locale list or
  from `SFSpeechRecognizer`, not from shipping `SpeechTranscriber`. Measured count is 30, Thai absent.

**Product consequence:** the free, modern, on-device Apple path is *not available for Thai*. A Thai dictation
app on macOS must either use the older `SFSpeechRecognizer` (`UNVERIFIED:` its quality and
utterance-length limits relative to `SpeechTranscriber` were not measured this pass) or ship its own model. This removes the "just use Apple's free API" option that the
English-only competitors enjoy — and is therefore also a moat.


**Apple probe #2 (`thaiASR.swift`) did NOT run:** exit 134 (SIGABRT) — a bare Mach-O executable has no
`Info.plist` with `NSSpeechRecognitionUsageDescription`, so TCC aborts the process at
`SFSpeechRecognizer.requestAuthorization`. Measuring Apple's Thai code-switch quality requires a signed
`.app` bundle plus an interactive permission grant. Flagged as the #1 cheap experiment in §6.

Test corpus staged in `scratchpad/thaitest/` (16 kHz mono float32 WAV, 2.5–5.7 s), generated with the macOS
Thai TTS voice **Kanya (th_TH)**. Sentences: `เดี๋ยว deploy ให้ก่อนนะ`, `meeting ตอนบ่าย 3 โมง`,
`ช่วย refactor function นี้หน่อย`, `ช่วย commit แล้ว push ขึ้น branch main ให้หน่อย`, plus a Thai-only control.
Caveat: synthetic speech, so absolute WER means nothing; **relative** behaviour between decode settings does.

---

## 1. Which engines decode Thai + English in ONE utterance?

### 1.1 Speechmatics — **Thai supported, Thai code-switching NOT supported** ⛔
Source: https://docs.speechmatics.com/introduction/supported-languages

Speechmatics is the only major vendor with an explicitly enumerated *bilingual* (code-switch) product, and
it is a list of **pairs**, not a language set. The complete enumerated list:

| Bilingual pack | Code |
|---|---|
| Arabic & English | `ar_en` |
| Malay & English | `en_ms` |
| Mandarin & English | `cmn_en` |
| Mandarin, Malay, Tamil & English | `cmn_en_ms_ta` |
| Spanish & English | `es` + `domain: "bilingual-en"` |
| Tamil & English | `en_ta` |
| Tagalog (Filipino) & English | `tl` |

Thai (`th`) **is** in the 80+ monolingual transcription list. Thai is **in none of the bilingual packs.**

This is the sharpest single data point in the whole brief: Speechmatics ran a deliberate **Southeast Asia
bilingual push** — https://www.speechmatics.com/company/articles-and-news/speechmatics-launches-worlds-first-bilingual-voice-ai-models-for-southeast-asia
— and shipped Mandarin-English, Malay-English, Tamil-English and Tagalog for that market. They built exactly
the product this app needs, for the neighbouring countries, **and skipped Thailand.** Speechmatics' own framing
of why generic multilingual models fail here is worth quoting: general models "struggle when speakers blend
them naturally", because a model "tend[s] to predict that English is most commonly followed by English."


### 1.2 Soniox — **the only vendor that documents Thai↔English mid-sentence switching by name** ✅

Soniox is the standout. Unlike every other vendor, its code-switching capability is **not gated to a pair
list** — it is presented as a property of the single multilingual model across all 60+ languages, and Thai is
in that list.

Verbatim from https://soniox.com/docs/speech-to-text/core-concepts/language-hints :
> "handles multilingual speech seamlessly, even when multiple languages are mixed within a single sentence or
> conversation."

Verbatim from https://soniox.com/speech-to-text/thai :
> "Handle mid-sentence language switching in Thai" … "people often blend languages within a sentence or phrase."

**And the page's own worked example is a Thai-English code-switched sentence:**
> `ขออเมริกาโน่เย็น หวานน้อย ใส่แก้ว to-go นะ.`

Note what that example demonstrates: `to-go` is rendered **in Latin script, inline in Thai text** — precisely
the behaviour that Whisper fails at (§1.6). This is the single most on-target piece of vendor evidence found.

| Property | Value | Source |
|---|---|---|
| Thai in language list | **Yes**, `th` | https://soniox.com/docs/stt/concepts/supported-languages |
| Code-switch scope | All 60+ languages (no pair list, no subset published) | https://soniox.com/docs/speech-to-text/core-concepts/language-hints |
| Language config needed | **None** — auto-detected, no language hint required | ibid. |
| Latency | "Sub-200ms real-time latency" | https://soniox.com/speech-to-text/thai |
| Streaming | Yes, "no waiting for sentence boundaries" | ibid. |
| Price | **~$0.12/hr realtime, ~$0.10/hr async** | ibid. (matches `stt-rt-v5` $0.12/hr in 05-providers.md) |

⚠️ **Caveat that must be tested, not assumed:** all of the above is Soniox marketing + docs prose. No published
Thai WER, and **no published code-switched Thai benchmark**. "60+ languages" pages are frequently templated
(the same trap flagged for Willow Voice in `notes-a1-ai-native.md`). The `to-go` example is stronger than a
templated page — it is Thai-specific copy — but it is still an illustration, not a measurement. **Prototype
before believing.** See §6.


### 1.3 AssemblyAI — **Thai excluded from the code-switch model** ⛔
Sources: https://www.assemblyai.com/docs/pre-recorded-audio/code-switching and
https://www.assemblyai.com/docs/streaming/universal-streaming/multilingual-transcription

AssemblyAI has a real, native code-switching feature, and it is the **strongest streaming code-switch claim in
the market** — verbatim: Universal-3.5 Pro Streaming is *"the only streaming model with native (mid-sentence)
code switching"*, and it *"follows speakers as they shift mid-sentence between languages … preserving exactly
what was said without translating everything into a single language."*

But the feature's own enumerated list is 18 languages: Global/AU/GB/US English, Spanish, French, German,
Italian, Portuguese, Arabic, Danish, Dutch, Finnish, Hebrew, Hindi, Japanese, Mandarin, Norwegian, Swedish,
Turkish, Vietnamese. **Thai is not in it.** The streaming multilingual list is the same 18 — **no Thai**.

Thai *is* in the 99-language Universal-2 list, and the docs say anything outside the 18 "automatically falls
back to Universal-2 … without any extra configuration". So a Thai request succeeds — but it silently drops off
the code-switching model onto the older one. **Falling back is not code-switching**; nothing in the docs
promises mid-sentence behaviour on the fallback path.

Also relevant to a Thai product, from the same docs: compressed phone audio "removes frequency ranges crucial
for tonal languages like Thai or Mandarin."

### 1.4 Azure Speech — **explicitly cannot do within-sentence switching** ⛔
Source: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-identification

This is the cleanest disqualification in the brief, in Microsoft's own words:

> "Continuous LID can identify multiple languages during the audio. Use continuous LID if the language in the
> audio could change. **Continuous LID doesn't support changing languages within the same sentence.** For
> example, if you're primarily speaking Spanish and insert some English words, it doesn't detect the language
> change per word."

That failure example *is* the product's use case, verbatim. Also the candidate-language caps:
> "You can include up to **four** languages for at-start LID or up to **10** languages for continuous LID."

And a gotcha worth knowing: LID always returns one of your candidates even if neither was spoken —
"if `fr-FR` and `en-US` are provided as candidates, but German is spoken, the service returns either `fr-FR`
or `en-US`." Azure's N-candidate LID is a *segment router*, not a code-switching decoder. Not usable here.


### 1.5 Google Chirp 2/3, ElevenLabs, Voxtral, OpenAI, Gladia, Sarvam/Krutrim
See §5 summary table. Chirp 3 documents "automatic language detection for multilingual audio … the **dominant**
language spoken in the audio" — dominant-language selection, i.e. the same one-winner behaviour as Whisper,
not within-utterance switching (https://docs.cloud.google.com/speech-to-text/docs/models/chirp-3).

---

## 4(d)-i. AUDIO-NATIVE LLMs — why this category is different, + the open-weight models ★

**Why this category is structurally different, and the single most important idea in this brief:**

Every ASR API above exposes one lever — *which language*. None accepts an instruction about **output form**.
An audio-native LLM does. You can write:

> "Transcribe verbatim. Keep English technical terms in Latin script. Never transliterate English into Thai script."

That sentence is the entire problem statement, and it is only expressible as a prompt. No WER table measures
it, which is exactly why the published benchmarks under-sell this category for this use case.

### Qwen3-ASR (Alibaba) — best measured Thai number found, open weights ★
Source: https://arxiv.org/html/2601.21337v2 (Qwen3-ASR Technical Report)

| Model | Params | Thai WER, FLEURS | License |
|---|---|---|---|
| **Qwen3-ASR-1.7B** | Qwen3-1.7B + 300M AuT encoder | **6.32%** | Apache 2.0 |
| **Qwen3-ASR-0.6B** | Qwen3-0.6B + 180M AuT encoder | **8.34%** | Apache 2.0 |

30 languages + 22 Chinese dialects (52 total); **Thai (`th`) confirmed in the list**.

**The feature that matters most here** — verbatim: the model "learns to utilize the **context tokens inside the
system prompt as background knowledge**, allowing users to obtain customized ASR results." That is
prompt-based contextual biasing built into an open-weight ASR model — i.e. mitigation 4(b), locally, for free,
with no per-request keyword API. Feed it the user's git branch names, framework names and function names.

⚠️ The report gives **no dedicated code-switching evaluation.** Thai WER 6.32% is monolingual FLEURS read
speech. Code-switch behaviour is untested and must be prototyped.

### Qwen3.5-Omni — strongest general audio LLM ASR result
Source: https://arxiv.org/html/2604.15804v1 (Qwen3.5-Omni Technical Report), Table 5, FLEURS(top60) WER:

| Model | FLEURS(top60) WER |
|---|---|
| **Qwen3.5-Omni-Plus** | **6.55** |
| Gemini-3.1 Pro | 7.32 |
| Qwen3.5-Omni-Flash | 10.75 |

`UNVERIFIED:` the widely-repeated figure "GPT-4o-Transcribe 10.4% FLEURS avg" appears in search summaries but
**is not in Table 5** of the report as fetched; treat as unconfirmed. Likewise the claim that Qwen3.5-Omni wins
"by significant margins on Cantonese, Thai and Vietnamese" is search-summary text — **the fetched report
contains no per-language Thai breakdown.** Do not quote a Thai number for Qwen3.5-Omni.


---

## 1.6 WHISPER ON MIXED THAI+ENGLISH — **MEASURED, NOT REPORTED** ★★★

The brief asked for "real reported behavior" from GitHub issues or blogs. Better: this was **run on this
machine**, 2026-08-24, and it reproduces the predicted failure exactly.

Setup: `whisper.cpp` (`whisper-cli`, ggml 0.12.0) + `ggml-small.bin` (487 MB, official
`huggingface.co/ggerganov/whisper.cpp`), 16 kHz mono PCM16, macOS 26.5.1 Metal backend.
Audio = macOS Thai TTS voice **Kanya**. Synthetic, so ignore absolute accuracy; the **pattern** is the finding.

| # | Ground truth | `language=th` | `language=en` | `auto` |
|---|---|---|---|---|
| cs1 | เดี๋ยว **deploy** ให้ก่อนนะ | เดี๋ยว **ดิบโล้ย** ให้ก่อนนะ | `Wait, deploy, I'll give you a call.` | = th |
| cs2 | **meeting** ตอนบ่าย 3 โมง | **มีทิ้ง** ตอนบาย 3 โมง | `meeting, Ton Bai Sam Mung.` | = th |
| cs3 | ช่วย **refactor function** นี้หน่อย | ช่วย **เรฟาเทอร์ฟังชัน** นี้หน่อย | `Refrigerator Function, Ninoi.` | = th |
| cs4 | ช่วย **commit** แล้ว **push** ขึ้น **branch main** ให้หน่อย | ช่วย **คือมีค** แล้ว **พุษคืน รันสมีน** ให้หน่อย | `(speaking in foreign language)` | = th |

### What this proves

**1. `language="th"` — the Thai is right, every English word is destroyed.** The Thai matrix text comes back
essentially correct in all four sentences. Every embedded English token is forced through the Thai script:
`deploy→ดิบโล้ย`, `meeting→มีทิ้ง`, `refactor→เรฟาเทอร์`, `function→ฟังชัน`, `commit→คือมีค`, `push→พุษคืน`.
Mechanism: the `<|th|>` decoder token conditions the whole output; there is no path for a Latin-script token.

**2. `language="en"` — the English survives, the *Thai* is destroyed.** It is not the mirror image, it is worse:
the model **translates and hallucinates** rather than transcribing. `เดี๋ยว…ให้ก่อนนะ` ("let me deploy it first")
became "I'll give you a call" — invented content. cs4 collapsed entirely to
`(speaking in foreign language)`. For a dictation app that silently emits fabricated sentences, this is the
most dangerous of the three settings.

**3. `auto` is not a third option.** Autodetect returned **output identical to `language=th`** on all four.
It picks one language per 30 s window; every clip is one window; Thai is the majority language. Autodetect
cannot code-switch — it can only re-pick between windows.

### The finding that kills mitigation 4(a) as a *general* strategy: two failure modes, not one

- **(i) Systematic transliteration — plausibly recoverable.** `refactor→เรฟาเทอร์`, `function→ฟังชัน`,
  `deploy→ดิบโล้ย`. A phonetic shadow of the English survives; an LLM with context could invert it.
- **(ii) Substitution into a real word — information destroyed.** `meeting→มีทิ้ง` is not nonsense Thai, it is
  a **readable Thai string**. Downstream, nothing marks it as foreign. Worse, at `language=en`,
  `refactor→"Refrigerator"` — a perfectly ordinary English word. No post-processor can know to doubt it.
- **(iii) Merge/loss.** `branch main` (two tokens) → `รันสมีน` (one). The boundary is gone; you cannot restore
  two words from one.

### And the killer for dictionary-based repair: **the transliteration is not stable**
Two runs of the identical file `cs1.wav` at `language=th`, same model, same flags, produced
**`ดีโพล้อย`** and **`ดิบโล้ย`**. Same word, same audio, two different Thai spellings. So you cannot build a
`ดีพลอย→deploy` lookup table — there is no stable key. Any repair layer must be a **semantic** LLM pass
(fuzzy/phonetic), never a dictionary. That is a real architectural constraint, measured rather than assumed.


### 1.7 MEASURED: `initial_prompt` keyword biasing largely FIXES it ★★★ (mitigation 4(b))

Same model, same audio, same `language=th`. Only change: `--prompt "deploy, refactor, function, commit,
push, branch, main, meeting"` — an eight-word English glossary.

| File | `language=th`, no prompt | `language=th` **+ prompt** |
|---|---|---|
| cs1 | เดี๋ยว **ดิบโล้ย** ให้ก่อนนะ | เดี๋ยว **ดีปลโลย** ให้ก่อนนะ ❌ still Thai script |
| cs3 | ช่วย **เรฟาเทอร์ฟังชัน** นี้หน่อย | ช่วย, **refactor function** นี้หน่อย ✅ **exactly right** |
| cs4 | ช่วย **คือมีค** แล้ว **พุษคืน รันสมีน** ให้หน่อย | ช่วย,**คือมีบ**แล้ว, **push**,คืน, **branch**, **main** ให้หน่อย ⚠️ 3 of 4 |
| th_only (control) | สวัสดีครับ วันนี้อากาศดีมาก ✅ (exact match) | — |

**English tokens returned in Latin script: 0 / 7 without the prompt → 5 / 7 with it.**
*(Denominator = the 7 English tokens in cs1/cs3/cs4, the three files re-run with `--prompt`. cs2's `meeting`
was in the glossary but that file was not re-run, so it is excluded from both sides — read as "5 of 7 **tested**".)*
Recovered: `refactor`, `function`, `push`, `branch`, `main`. Still lost: `deploy`, `commit`.

This is the highest-leverage, lowest-cost result in the brief. It is free, local, needs no vendor, and works
on a **487 MB `small`** model — the weakest one tested. Two things follow:

1. **The Latin-script barrier is soft, not hard.** Whisper *can* emit Latin script inside a Thai transcript;
   the prompt raises the prior enough to cross over. So the fix is not "find a different model" — it is
   "supply the vocabulary."
2. **The glossary must be user-specific and dynamic.** A desktop dictation app knows things a generic ASR
   vendor cannot: the frontmost app, the repo's branch names, the identifiers in the open file, the user's
   own correction history. That is a real product moat and it maps onto a measured mechanism.

**The hard limit, from `whisper-cli --help`:** `--prompt PROMPT [] initial prompt (max n_text_ctx/2 tokens)`
— i.e. **224 tokens** for Whisper (`n_text_ctx` = 448). Whisper's BPE tokenizes Thai very inefficiently, so a
mixed Thai+English glossary burns that budget fast. Practical design: **English terms only in the prompt**
(they are 1–2 tokens each; the Thai matrix needs no help), rotate the list by context, and cap at ~100 terms.
`--carry-initial-prompt` re-prepends it to every window, which matters for utterances over 30 s.

**Side effects observed:** spurious comma insertion (the prompt was comma-delimited — use space or newline
delimiters instead), and one adjacent Thai word corrupted in cs4 (`ขึ้น`→`คืน`). Biasing is not free; it
perturbs neighbouring tokens. Measure both directions when tuning.


---

## 2. Thai-first models

### 2.1 ⚠️ TRAP: Typhoon's "Code-Switching" benchmark measures the OPPOSITE of what you want

Secondary sources report that Typhoon2-Audio "achieved perfect performance on Code-Switching tasks." **That is
a misreading, and acting on it would send you the wrong way.** The Typhoon 2 paper defines the metric verbatim
(https://arxiv.org/html/2412.13702v2, §3.1.2):

> "For Code-switching (CS) evaluation, the metric is accuracy, defined as: 1. **The response does not contain
> characters from other languages.** 2. Thai characters constitute the majority of the response content."

Its stated motivation: "English monolingual and English-Chinese bilingual LLMs exhibit a high tendency to
produce code-switching responses when prompted to respond in Thai… to assess the model's propensity to output
non-Thai characters."

So Typhoon's CS score is a **code-switching *suppression*** score. A model that scores 100% is a model that
**never emits `deploy` in Latin script.** Typhoon2-Llama-8B scores 98.8 / 98.6; Llama3.1-8B-Instruct scores
11.20 / 93.00 (Table 4). Optimising for that number is optimising *against* this product.

Generalise the lesson: **the Thai NLP community's benchmarks treat Latin script in Thai output as a defect.**
Every Thai-first model has been tuned, at least partly, toward Thai-script purity. That is the structural
reason Thai-first models are a poor fit for code-switched dictation, and it is not visible from WER tables.

### 2.2 Typhoon ASR Real-time (SCB 10X) — best local Thai streaming model
Sources: https://arxiv.org/abs/2601.13044 · https://huggingface.co/typhoon-ai/typhoon-asr-realtime ·
https://github.com/scb-10x/typhoon-asr

| Property | Value |
|---|---|
| Architecture | NVIDIA FastConformer-Transducer (NeMo) |
| Params | **114M** |
| Training | 10,000 h Thai |
| **CER** | **0.0984** (9.84%) |
| Throughput | **RTFx 4097×**; 6× the next fastest; 15–19× Whisper variants |
| License | **CC-BY-4.0** |
| Local | **Yes — designed for CPU**, "self-hosted deployment without sending data to cloud services" |
| Streaming | Yes, optional timestamps |
| Published | Jan 2026, Sirichotedumrong et al. |

Also in the family (2026): `typhoon-isan-asr-realtime` (Isan dialect), `typhoon-whisper-turbo`,
`typhoon-whisper-large-v3` under the new `typhoon-ai` HF org.

⚠️ **Thai-only, 114M, transducer.** No English in its output vocabulary in any meaningful sense, and a
Transducer has no `initial_prompt` equivalent — so the §1.7 mitigation **does not port to it**. Excellent for
Thai-only dictation; structurally unable to emit `deploy`. Rules it out as the primary engine here.

### 2.3 Typhoon2-Audio — measured Thai ASR WER
From the Typhoon 2 paper Table 29 (backbone selection, ASR = LibriSpeech-other for En, CommonVoice subset-1K
for Th):

| Speech encoder | LLM | En WER | **Th WER** |
|---|---|---|---|
| Whisper-v3-large | Llama-3 | 6.02 | 16.66 |
| Whisper-v3-large | Typhoon-1.5 | 7.76 | 20.01 |
| Whisper-v3-large-Th | Llama-3 | 7.35 | 15.68 |
| **Whisper-v3-large-Th** | **Typhoon-1.5** (shipped) | 9.15 | **13.52** |

Note the tradeoff visible in the table: the configuration they shipped is the **worst on English** (9.15) and
best on Thai (13.52). Again the Thai-first optimisation direction, now measured.
Interesting detail: their speech-*decoder* mixture (Table 33) does include **"Thai-English Mix 21,000"**
examples — so SCB 10X has built Thai-English mixed data, but applied it to TTS, not ASR.


### 2.4 ★ THE 2026 THAI ASR LEADERBOARD (this is the eval the brief was looking for)
Source: **Typhoon ASR Real-time**, arXiv **2601.13044**, Table 6 — https://arxiv.org/html/2601.13044v1
Published Jan 2026. Metric = **CER** (correct choice: Thai has no word boundaries). Lower is better.

| Model | TVSpeech (robustness) | Gigaspeech2-Typhoon (standard) | FLEURS | FLEURS (norm.) |
|---|---|---|---|---|
| **Typhoon Whisper Large-v3** | **6.32%** 🥇 | **4.69%** 🥇 | 9.98% | 5.69% 🥇 |
| Typhoon Whisper Turbo | 6.85% 🥈 | 4.79% 🥈 | 10.52% | 7.08% |
| Typhoon Isan ASR Realtime | 9.34% | 6.93% | 14.55% | 10.15% |
| Typhoon ASR Realtime (114M) | 9.99% | 6.81% | 13.87% | 9.68% |
| **Pathumma-Whisper Large-v3** (NECTEC) | 10.36% | 5.84% 🥉 | **6.29%** 🥇 | 7.88% |
| **Gemini 3 Pro** | 10.95% | 12.50% | 11.35% | 6.91% 🥈 |
| Biodatlab Distill-Whisper Large | 13.82% | 8.24% | **6.77%** 🥈 | 8.63% |
| Biodatlab Whisper Large (Thonburian) | 18.96% | 13.22% | 16.50% | 15.26% |

**Read this table carefully — three things matter more than the ranking:**

1. **TVSpeech is the closest existing proxy for this product's workload.** Verbatim: 570 utterances / 3.75 h
   from public YouTube media, selected for "high lexical density – specifically selecting clips containing
   **domain-specific terminology, proper names, and technical jargon**." Thai tech speech is where English
   loanwords live. On that track Thonburian collapses to **18.96%** — three times Typhoon Whisper Large-v3.
2. **The Thonburian anchor is stale.** The prior pass's 6.59% (CommonVoice 13, deepcut tokenizer) is a
   *clean-read-speech* number on a different dataset and tokenizer. On the 2026 benchmarks Thonburian is
   **last of eight**. Do not architect around it.
3. **Gemini 3 Pro is mid-pack on raw Thai** (10.95 / 12.50 / 11.35) and clearly behind the Thai-first Whisper
   fine-tunes. Its case rests entirely on instruction-following (§4d), not accuracy.

Typhoon ASR Realtime's own summary: comparable accuracy to Pathumma-Whisper Large-v3 "while achieving an
approximate **45× reduction in computational complexity**."

### 2.5 Pathumma-Whisper (NECTEC / ThaiLLM)
https://huggingface.co/nectec/Pathumma-whisper-th-large-v3 — 2B params, base `openai/whisper-large-v3`,
**Apache-2.0**, trained on ThaiSC/NSTDA LANTA. A `-medium` variant and `nectec/Pathumma-llm-audio-1.0.0`
(audio LLM) also exist. **The model card itself publishes no WER** ("Additional information is needed") —
the numbers above come from Typhoon's independent eval. Best FLEURS Thai of the open Thai models (6.29%).

**Because it is a Whisper derivative it inherits `initial_prompt` — so the §1.7 mitigation DOES port to it.**
That combination (best-in-class Thai + Apache-2.0 + promptable) makes it the strongest *local* base.

---

## 3. Academic work on Thai-English code-switching ASR

### 3.1 ⛔ There is NO Thai-English code-switch speech corpus. This is a real gap.

**CS-FLEURS** (Interspeech 2025) is the largest code-switched speech dataset in existence — 4 test sets,
**113 code-switched language pairs across 52 languages**, plus a 128-hour training set over 16 X-English pairs.
Sources: https://arxiv.org/abs/2509.14161 · https://www.isca-archive.org/interspeech_2025/yan25c_interspeech.html
· dataset https://huggingface.co/datasets/byan/cs-fleurs

**Thai does not appear anywhere in the CS-FLEURS paper.** (Verified mechanically: full extracted paper text,
zero occurrences of "Thai".) Even the 45-pair *lower-resourced* X-English test set does not reach it.

Existing code-switch corpora and their pairs — note what is and is not covered:
| Corpus | Pair | Size | Source |
|---|---|---|---|
| SEAME | Mandarin-English (SG/MY) | 192 h | referenced in CS-FLEURS |
| TALCS | Mandarin-English | — | https://arxiv.org/pdf/2206.13135 |
| CS-Dialogue | Mandarin-English | 104 h | https://arxiv.org/html/2502.18913v1 |
| HiKE | Korean-English | — | https://arxiv.org/pdf/2509.24613 |
| HiACC / Hinglish corpus | Hindi-English | — | https://arxiv.org/pdf/1810.00662 |
| Soapies | 5 SA languages | 14 h | referenced in CS-FLEURS |
| CS-FLEURS | 113 pairs / 52 langs | 294 h | https://arxiv.org/abs/2509.14161 |
| **Thai-English** | — | **none found** | — |

**SEAME is the sharpest irony: a "South-East Asia" code-switching corpus that covers Singapore and Malaysia
and skips Thailand.** Combined with Speechmatics shipping Malay/Tamil/Mandarin-English bilingual models for
SEA and skipping Thai (§1.1), and AssemblyAI's 18-language code-switch list including Vietnamese but not Thai
(§1.3), the pattern is consistent: **Thai-English code-switching is systematically unserved.** That is the
market gap — and also why no vendor can show you a number for it.


### 3.2 The literature has not looked at Thai either
**"Code-Switching in End-to-End Automatic Speech Recognition: A Systematic Literature Review"** —
https://arxiv.org/html/2507.07741v1 — surveys **127 papers, 2018–2024**.
**"Thai receives no mention"** anywhere in it.

Techniques the review reports as working (all validated on other pairs — transfer to Thai is untested):

| Technique | Adoption | Reported effect |
|---|---|---|
| **Frame-level LID via multi-task learning** | ~33% use LID | **"outperforms predicting LID token at the beginning of the sequence"** for *intra-sentential* switching |
| TTS-synthesised CS data augmentation | ~30% | up to **5% absolute WER** reduction (with Mixup) |
| LM fusion / rescoring | ~45% | subword LMs on CS data strong; **mT5 rescoring fine-tuned on CS data** beats neural + max-ent baselines |
| Multilingual > per-language models | — | "capture shared acoustic and lexical patterns across languages" |

The frame-level-LID finding explains the measured §1.6 results precisely: Whisper's `<|th|>` **is** a
"LID token at the beginning of the sequence" — the architecture the literature says is the *wrong* one for
within-sentence switching. Whisper cannot be configured out of this; it is structural.

The review's caveat, verbatim: "there is no single methodology shared across all datasets."

**Practical consequence for building:** the two techniques with the best evidence are both available to you —
TTS-synthesised Thai-English CS data (macOS `say -v Kanya` already produced usable clips for this brief in
seconds; a real pipeline would use a Thai TTS with English phoneme support) and **LLM rescoring** (mitigation
4a/4c). Since no Thai-English CS corpus exists (§3.1), **synthesising one is a prerequisite for any fine-tune —
and is itself a defensible asset.**

### 3.3 Related 2026 work worth tracking
- **CS-YODAS: A Mined Dataset of In-the-Wild Code-Switched Speech** — https://arxiv.org/html/2606.11514
- **Adding Robust Code-Switching Capabilities to High Performance Multilingual ASR** — https://arxiv.org/pdf/2606.21990
- **Improving Code-Switching ASR with Code-Mixing Guided Synthetic Speech** — https://arxiv.org/pdf/2606.19381
- **UniCoM: A Universal Code-Switching Speech Generator** — https://aclanthology.org/2025.findings-emnlp.715.pdf
- **Benchmarking Evaluation Metrics for Code-Switching ASR** — https://arxiv.org/pdf/2211.16319 — argues plain
  WER is invalid for code-mixed text: "misspellings and borrowing of words from two different writing systems
  … artificially inflate the WER." **Directly relevant: you will need a custom metric, not WER.**
- **SpeechJBB: … Large Audio Language Models under Code-Switched Speech** — https://arxiv.org/pdf/2606.06037


---

## 4(c). TWO PARALLEL ASR PASSES MERGED — ⛔ evidence says this fails

**Gladia built exactly this and published the number that kills it.**
Source: https://www.gladia.io/blog/building-real-time-multilingual-asr-with-code-switching

Their architecture: streaming Zipformer models, 640 ms chunks, with **routing logic** between per-language
models — structurally identical to mitigation (c) and to the "two Apple `SFSpeechRecognizer` instances" idea.
Evaluated on three tiers:

| Condition | Dataset | Gladia WER |
|---|---|---|
| Monolingual baseline | Google FLEURS | — |
| **Inter**-utterance switching (at sentence boundaries) | synthetic "FLEURS Blend" | **~13%** — "outperforming every other solution" |
| **Intra**-utterance switching (mid-sentence, no pause) | **Bangor-Miami Corpus (real speech)** | **~41%** |

**A 3× degradation, on Spanish-English — the best-resourced code-switch pair on earth, with a real corpus.**
Their own framing: "inter-utterance switches occur at natural speech boundaries, while intra-utterance switches
happen within sentences **without acoustic pauses**."

The product's target utterance — `เดี๋ยว deploy ให้ก่อนนะ` — is intra-utterance with no pause. Language
routing has nothing to segment on. Thai-English, with no corpus and no Thai-English routing tuning, would be
worse than 41%.

**Conclusion: reject mitigation (c) as the primary architecture.** Two parallel passes merged by an LLM is
still worth keeping as a *diagnostic* (it is how you measure the §4a recoverability ratio cheaply — see §6),
but not as the shipping path.

Gladia's language list for code-switching is **eight languages** — English, French, Spanish, German, Russian,
Italian, Portuguese, Dutch. **Thai is not among them.**

### The taxonomy this gives you — use it to read every vendor claim
1. **Language routing / LID segmentation** — Azure continuous LID, Gladia, two-pass merge. Handles switches
   *between* utterances. **Documented to collapse mid-sentence.**
2. **Bilingual pair models** — Speechmatics. Genuinely handles intra-utterance, but only for pairs they built.
   **No Thai pair exists.**
3. **Single multilingual decoder that may emit either script** — Soniox, AssemblyAI U-3.5 Pro, ElevenLabs
   Scribe v2. The only class that can work for Thai without a Thai-specific model — **and only Soniox puts
   Thai in scope.**
4. **Instruction-followable audio LLM** — Gemini, GPT-4o-audio, Qwen3-Omni/ASR, Typhoon-Audio. Output format
   is controllable by prompt. **Unbenchmarked for this, and the only category where you control the failure mode.**


---

## 1.8 Remaining vendors — quick verdicts

| Vendor | Thai in product? | Thai in **code-switch** feature? | Evidence |
|---|---|---|---|
| **Soniox** | Yes (`th`) | ✅ **YES** — only vendor with a Thai-English CS example in its own docs | https://soniox.com/speech-to-text/thai |
| **Speechmatics** | Yes (`th`) | ⛔ No — 7 bilingual packs, none Thai | https://docs.speechmatics.com/introduction/supported-languages |
| **AssemblyAI** | Yes (Universal-2, 99 langs) | ⛔ No — CS list is 18 langs, Thai absent; silently falls back off the CS model | https://www.assemblyai.com/docs/pre-recorded-audio/code-switching |
| **Deepgram** | Yes (Nova-3) | ⛔ No — `multi` excludes Thai (prior pass) | https://developers.deepgram.com/docs/models-languages-overview |
| **Azure Speech** | Yes | ⛔ No — "doesn't support changing languages within the same sentence" | https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-identification |
| **Gladia** | — | ⛔ No — CS = 8 European langs; **~41% WER intra-utterance even on ES-EN** | https://www.gladia.io/blog/building-real-time-multilingual-asr-with-code-switching |
| **Google Chirp 3** | 85+ langs | ⛔ No — picks "the **dominant** language spoken in the audio" | https://docs.cloud.google.com/speech-to-text/docs/models/chirp-3 |
| **ElevenLabs Scribe v2** | ✅ Yes (`tha`), **"Good" tier = >10% to ≤20% WER** | ⚠️ Auto-detects CS when `language_code` omitted, but Thai CS undocumented | https://elevenlabs.io/docs/overview/capabilities/speech-to-text |
| **OpenAI gpt-4o-transcribe** | `UNVERIFIED:` Thai not in the documented language-code examples | ⚠️ Has a **`prompt` vocabulary field** (= mitigation 4b); "cannot guarantee a correct transcript" | https://developers.openai.com/api/docs/guides/speech-to-text |
| **Sarvam / Krutrim** | ⛔ **No** — 23 languages = 22 Indian + English, no Thai | n/a — Indic-only; does not generalise | https://docs.sarvam.ai/api/getting-started/models |
| **Mistral Voxtral** | `UNVERIFIED:` Thai status not confirmed this pass | `UNVERIFIED:` | https://docs.mistral.ai/getting-started/models/models_overview/ |
| **Wispr Flow** | unstated | ⛔ Tells users to pick the current language (prior pass) | https://wisprflow.ai/ |

**Bottom line for §1: exactly one commercial vendor — Soniox — puts Thai inside a code-switching capability.**
Everyone else either excludes Thai from the CS feature, or excludes within-sentence switching entirely.


### 2.6 Thai commercial ASR vendors — pricing in THB

**iApp Technology "SpeechFlow"** — https://iapp.co.th/products/speechflow · https://ai.iapp.co.th/product/speech_to_text_asr
- **iApp ASR Base: 1 IC/min · iApp ASR Pro: 2 IC/min** (IC = internal credit)
- Plans: **฿89** / 60 IC · **฿150** / 120 IC · **฿700** / 600 IC · **฿7,500** / 7,200 IC · **฿18,000** / 21,600 IC
- Effective: ฿1.48/min (Starter) down to **฿0.83/min** (Premium) on Base ≈ **$1.5–2.7/hr** — i.e. **~10–20×
  Soniox's $0.12/hr.** Domestic Thai vendors are dramatically more expensive than global infrastructure.
- Accuracy (their claim, Mozilla Common Voice 17.0): **91.23% Thai word-level**, **94.13% character-level**;
  "3.12% lower WER than Google ASR"; 16.3× faster than Google ASR (Base).
- Supports "Thai and English" with smart punctuation. **Mixed Thai-English handling is not claimed.**
- 60 IC free on registration + 30 IC trial.

**NECTEC "Partii"** — https://www.nectec.or.th/innovation/innovation-service/thai-ai-voice-transcription.html
Thai speech recognition from NECTEC, commercialised via Ai9 as a meeting-transcription system.
`UNVERIFIED:` no public per-minute API price found; appears to be enterprise/solution sales, not self-serve.

**Botnoi** — https://voice.botnoi.ai/ — **text-to-speech, not speech-to-text.** Not a candidate. (Their
100+ voices could matter for §6 test-data synthesis.)

**Gowajee (Chulalongkorn)** — https://github.com/ekapolc/gowajee_corpus — the public artefact is a **corpus**
(Thai smart-home, "Gowajee" hotword), collected as coursework in Ekapol Chuangsuwanich's ASR class,
Spring 2017–2023. It is training data other Thai models use, **not a deployable model or API.**
`UNVERIFIED:` no public WER for a "Gowajee model", no pricing, no API.

**Verdict on the Thai domestic vendors: none is a fit.** They are priced 10–20× above global infrastructure,
none advertises code-switching, none publishes a code-switched benchmark, and the best of them (Pathumma) is
freely available as Apache-2.0 weights anyway.

---

## 4(a). LLM RESTORATION OF ENGLISH FROM THAI TRANSLITERATION — partially works, and is measurable

The §1.6 measurement settles the shape of this. **The question "is ดีพลอย→deploy recoverable?" has three
different answers depending on which failure occurred**, and the *ratio* between them — not the average —
decides whether (a) is a viable product strategy.

| Failure mode | Measured example | Recoverable by an LLM? |
|---|---|---|
| **Systematic transliteration** | `refactor→เรฟาเทอร์`, `function→ฟังชัน`, `deploy→ดิบโล้ย`/`ดีโพล้อย` | **Likely yes.** A phonetic shadow survives; with sentence context + a domain prior the candidate set is small. `ฟังชัน` is a near-standard Thai rendering of *function*. |
| **Substitution into a real word** | `meeting→มีทิ้ง` (real Thai); `refactor→"Refrigerator"` (real English, at `language=en`) | **No.** The output is well-formed text. Nothing downstream flags it as suspect. This is silent corruption — the worst failure class for dictation. |
| **Merge / loss** | `branch main`(2 tokens) → `รันสมีน`(1) | **No.** The token boundary is destroyed; two words cannot be recovered from one. |

**Two measured facts that constrain any (a) implementation:**

1. **You cannot use a lookup table.** The same audio produced `ดีโพล้อย` on one run and `ดิบโล้ย` on the next
   (§1.6). There is no stable key. Repair must be a **semantic/phonetic LLM pass**, not a dictionary.
2. **The repair pass cannot know when to fire.** Because mode (ii) produces valid Thai, an LLM asked to "fix
   transliterations" will also "fix" genuine Thai words into English ones — introducing errors in Thai-only
   dictation. Any (a) implementation needs a confidence signal (ASR token logprobs, or a second opinion) to
   gate it.

**Honest limitation:** the recoverability judgements in the middle column are *my* assessment while knowing the
ground truth, which is contaminated. The genuine experiment is blind and cheap — see §6. It is also the single
number that decides this strategy, so measure it rather than trusting the table above.

**Strategic conclusion: (a) is a repair layer, not an architecture.** Use it to clean the residue after §1.7
biasing has already prevented most of the damage. Do not build the product on it.


---

## 4(d)-ii. AUDIO-NATIVE LLMs — verified pricing + full comparison ★★★

### The pricing surprise: audio LLMs are CHEAPER than dedicated ASR APIs

All prices from https://ai.google.dev/gemini-api/docs/pricing (raw page, read 2026-08-24). Google's own
footnote: **"Audio tokens correspond to 25 tokens per second of audio"** → 90,000 audio tokens per hour.

**⚠️ These are INPUT-ONLY prices.** Output tokens are billed separately ($2.50/1M on Flash-Lite, $3.00/1M
on 3 Flash) and — because Thai tokenizes inefficiently — the **output term is likely LARGER than the input
term** for a full hour of transcript. `UNVERIFIED:` Thai output-token count per audio-hour was not measured.
The conclusion (ASR cost is immaterial at $20/mo) is unaffected; the figures below are a floor, not a total.

| Model | Vendor's audio **input** price | **$/hr input only** | Mode |
|---|---|---|---|
| Gemini 3.5 Flash-Lite | $0.30 / 1M (text/image/video/audio) | **$0.027** | request/response |
| Gemini 3.1 Flash-Lite | $0.50 / 1M (audio) | **$0.045** | request/response |
| **Gemini 3 Flash Preview** | $1.00 / 1M (audio) | **$0.090** | request/response |
| Gemini 2.5 Flash | $1.00 / 1M (audio) | **$0.090** | request/response |
| **Gemini 3.1 Flash Live Preview** | **$3.00 or $0.005/min (audio)** | **$0.30** | **bidirectional streaming** |
| Gemini 3.5 Live Translate | $3.50 or $0.0053/min (audio) | $0.32 | streaming, 70+ langs |
| *(reference)* Soniox `stt-rt-v5` | $0.12/hr realtime, $0.10/hr async | 0.10–0.12 | streaming |

Batch tiers halve most of these. Output tokens are extra but negligible for a transcript.

**Two consequences that reframe the whole decision:**

1. **Non-streaming Gemini Flash at $0.027–$0.09/hr *undercuts every dedicated ASR API in this brief*,
   including Soniox's $0.10/hr async.** The "audio LLMs are the expensive option" intuition is wrong in 2026.
2. **A push-to-talk dictation app does not need bidirectional streaming.** The user holds a key, speaks 2–10 s,
   releases. That is a request/response workload. The expensive Live API ($0.30/hr, 2.5× Soniox) buys
   real-time partials you may not need. Budget the cheap tier and spend the savings on latency engineering.
   *(Latency for a short clip on these models: `UNVERIFIED:` — Google publishes no TTFT figure for short
   audio. Measure it; see §6.)*

### Model-by-model

| Model | Thai accuracy | Evidence grade | $/audio-hr | Streaming | Local? | Prompt-controllable output |
|---|---|---|---|---|---|---|
| **Gemini 3 Pro** | **CER 10.95 TVSpeech / 12.50 GS2 / 11.35 FLEURS** | **third-party eval** (Typhoon, arXiv 2601.13044 Tbl 6) | **Pro tier — not the Flash prices above** | via Live API | No | **Yes** |
| **Gemini 3 Flash / Flash-Lite** | `UNVERIFIED:` — **no Thai accuracy figure exists for any Flash-tier model.** The CER row above is **Pro only** and does not transfer. | — | $0.027–$0.09 input-only | via Live API | No | **Yes** |
| **Qwen3-ASR-1.7B** | **WER 6.32% FLEURS** | vendor paper (arXiv 2601.21337) | free (self-host) | `UNVERIFIED:` | **Yes, Apache 2.0** | **Yes — system-prompt context tokens** |
| Qwen3-ASR-0.6B | WER 8.34% FLEURS | vendor paper | free | `UNVERIFIED:` | **Yes, Apache 2.0** | Yes |
| Qwen3.5-Omni-Plus | 6.55 FLEURS(top60) avg — **no Thai breakdown** | vendor paper (arXiv 2604.15804) | `UNVERIFIED:` | `UNVERIFIED:` | Plus = API | Yes |
| **Typhoon2-Audio 8B** | **WER 13.52%** CommonVoice-th | vendor paper (arXiv 2412.13702 Tbl 29) | free (self-host) | No | **Yes** | Yes — but **tuned to suppress Latin script** (§2.1) |
| GPT-4o-audio / gpt-4o-transcribe | `UNVERIFIED:` Thai not in documented lang-code examples | — | — | Realtime API | No | **Yes — `prompt` vocab field** |

**The decisive fact, and it is not in any of those columns:** Gemini 3 Pro is *mid-pack* on Thai CER — clearly
behind Typhoon Whisper Large-v3 (6.32) and Pathumma (6.29 FLEURS). If you rank on Thai accuracy alone, the
audio LLMs lose. **They win on the axis no benchmark measures: you can tell them what the output should look
like.** "Keep English technical terms in Latin script" is unavailable from every ASR API in §1 except as a
side-effect of model training. That is the entire argument for this category, and it is why §6 step 2 exists.

### Qwen3-ASR is the sleeper pick for the local path
1.7B params, **Apache 2.0**, Thai FLEURS **6.32%** — competitive with the best Thai-first models — and it ships
the biasing mechanism natively: it "learns to utilize the **context tokens inside the system prompt as
background knowledge**, allowing users to obtain customized ASR results" (arXiv 2601.21337). That is §1.7's
measured 5/7 fix, built into the model, on Apache-2.0 weights, at 1.7B — small enough for a laptop.


---

## 4(b). CUSTOM VOCABULARY / KEYWORD BOOSTING — which APIs support it **with Thai**

This is the mitigation with measured evidence behind it (§1.7: 0/7 → 5/7). The question is which engines let
you do it *while decoding Thai*.

| Engine | Mechanism | Works with Thai? | Source |
|---|---|---|---|
| **Whisper / whisper.cpp** (+ Thonburian, Pathumma, any Whisper fine-tune) | `initial_prompt` / `--prompt`, **cap = `n_text_ctx/2` = 224 tokens**; `--carry-initial-prompt` re-prepends per window | ✅ **MEASURED WORKING** — §1.7 | `whisper-cli --help`, measured this machine |
| **Apple `SFSpeechRecognizer`** | `SFSpeechRecognitionRequest.contextualStrings` | ✅ Thai available (`th-TH`, `supportsOnDevice=true`, measured §0). **Effect on Thai code-switch UNTESTED — TCC blocked** | measured `thaiLocales` run |
| **Qwen3-ASR** | context tokens in the **system prompt** | ✅ Thai in the 52-language list | https://arxiv.org/html/2601.21337v2 |
| **OpenAI gpt-4o-transcribe / whisper-1** | `prompt` field — "names, acronyms, formatting, or recording-specific vocabulary"; explicitly "cannot guarantee a correct transcript" | `UNVERIFIED:` Thai not in the documented language-code examples | https://developers.openai.com/api/docs/guides/speech-to-text |
| **Audio LLMs (Gemini / GPT-4o-audio)** | free-form prompt — the **only** mechanism that can also constrain *script*, not just vocabulary | Thai supported | §4(d) |
| **Deepgram** `keyterm` | keyterm prompting | ⚠️ `UNVERIFIED:` whether `keyterm` is available on Thai (it is documented as Nova-3 English-first) | https://developers.deepgram.com/docs/models-languages-overview |
| **AssemblyAI** `word_boost` | word boost list | ⚠️ `UNVERIFIED:` Thai + word_boost combination not confirmed | https://www.assemblyai.com/docs/ |
| **Speechmatics** custom dictionary | additional vocab w/ sounds-like | ⚠️ `UNVERIFIED:` Thai + custom dictionary not confirmed | https://docs.speechmatics.com/ |
| **Typhoon ASR Realtime** (FastConformer-**Transducer**) | ⛔ **none** — a Transducer has no `initial_prompt` analogue | n/a | architecture |

**Design rule that falls out of this:** prefer an **attention/decoder-based** model (Whisper-family, or an
audio LLM) over a Transducer, *specifically because* the biasing hook is what fixes code-switching. That is a
counterintuitive ranking criterion — Typhoon ASR Realtime is faster and more accurate on Thai than the
`small` model that produced the 5/7 result, and is still the wrong choice here.

**Note the asymmetry that matters most:** every row except the audio-LLM row can bias *which words* are
likely. Only the audio LLM can be told **what script to write them in**. For this problem those are different
levers, and the second one is the one that was actually broken.


---

# 5. RANKED RECOMMENDATION

**Evidence grades used below.** The ordering does *not* track evidence strength, so read both columns:
`MEASURED` (run on this machine, 2026-08-24) · `3P-EVAL` (independent third-party benchmark) ·
`VENDOR-PAPER` (vendor's own peer-reviewed/arXiv eval) · `VENDOR-DOCS` (technical documentation) ·
`VENDOR-MKTG` (marketing copy).

### 🥇 BEST OVERALL — **Audio-native LLM (Gemini 3 Flash class) with a script-constraining prompt**, Soniox as the ASR-shaped alternative

| | Evidence grade |
|---|---|
| Gemini 3 **Pro** Thai CER 10.95 / 12.50 / 11.35 | **3P-EVAL** — arXiv 2601.13044 Tbl 6 |
| Gemini **Flash-tier** Thai accuracy | `UNVERIFIED:` — **no Thai figure exists for Flash.** The cheap pricing is Flash; the only benchmark is Pro. These two do not currently meet. |
| $0.027–$0.09/hr **input-only** non-streaming; $0.30/hr Live | **VENDOR-DOCS** — ai.google.dev pricing |
| Prompt can constrain output script | **inferred** — no vendor documents this for Thai |
| Latency on short clips | `UNVERIFIED:` |

**Why first despite mid-pack Thai accuracy:** it is the only option where the failure mode measured in §1.6 is
*addressable by you* rather than baked into someone's decoder. Every ASR API forces a single-language decoder
token; an audio LLM takes "keep English technical terms in Latin script" as an instruction. Cheaper than
dedicated ASR in the non-streaming tier, which suits push-to-talk dictation.
**The gap you must close first:** the cost argument rests on **Flash**; the accuracy evidence rests on **Pro**.
If only Pro is accurate enough for Thai, the price reverts to the $0.30/hr Live tier — still viable, but 2.5×
Soniox rather than cheaper than it. §6 step 1 must test **both tiers**.
**Tradeoff:** cloud-only, worse raw Thai CER than Typhoon/Pathumma, unproven on the specific instruction, and
you inherit a general-purpose model's tendency to "helpfully" rewrite rather than transcribe (Whisper's
`language=en` hallucination in §1.6 is the same failure class — audio LLMs are *more* prone to it, not less).
**Verify the instruction holds before committing.**

**Runner-up in the same slot — Soniox `stt-rt-v5`:** the only commercial ASR vendor with Thai inside a
code-switching capability, sub-200 ms, $0.12/hr, no language config needed, and a **Thai-English code-switched
example in its own Thai docs** (`ขออเมริกาโน่เย็น หวานน้อย ใส่แก้ว to-go นะ` — note `to-go` in Latin script).
Evidence grade: **VENDOR-DOCS/MKTG only — zero published Thai WER, zero code-switch benchmark.** If it works
it is the least engineering effort of anything here. It is also the least *proven* thing in this brief. Test
it on day one; if it delivers, it likely beats the LLM path on latency and simplicity.

### 🥈 BEST LOCAL / PRIVATE — **Pathumma-Whisper Large-v3 (or Typhoon Whisper Large-v3) + a dynamic English glossary via `initial_prompt`**

| | Evidence grade |
|---|---|
| `initial_prompt` raises Latin-script retention **0/7 → 5/7** | **MEASURED** — this machine, `ggml-small` |
| Whisper at `language=th` transliterates 7/7 English terms | **MEASURED** |
| Pathumma FLEURS 6.29 CER / Typhoon-Whisper-L3 TVSpeech 6.32 CER | **3P-EVAL** — arXiv 2601.13044 Tbl 6 |
| Apache-2.0 (Pathumma) | **VENDOR-DOCS** — HF model card |

**This is the highest-confidence recommendation in the brief** — the mechanism was measured working here on the
*weakest* model tested (487 MB `small`). Scaling to Pathumma/Typhoon Whisper Large-v3 should only improve it.
Fully offline, no per-minute cost, Apache-2.0, and the glossary is a product moat: a desktop app knows the
frontmost app, the git branch, the identifiers in the open file, and the user's correction history — context
no ASR vendor can have.
**Tradeoffs:** ~1.5–3 GB model download; needs an Apple-Silicon-class machine; 224-token prompt budget forces
glossary rotation; biasing perturbs neighbouring Thai tokens (measured: `ขึ้น`→`คืน`); and 2/7 terms still
failed. Not a complete fix — a large improvement.

**Strong alternative in this slot — Qwen3-ASR-1.7B:** Thai FLEURS **6.32% WER**, Apache 2.0, 1.7B params, and
prompt-context biasing is a *documented model capability* rather than a decoder trick. Smaller and likely
faster than a 1.5B–2B Whisper. Grade: **VENDOR-PAPER**. Untested for Thai code-switch — but it is the option
I would benchmark second.

**Free wildcard worth 30 minutes — Apple `SFSpeechRecognizer(th-TH)` + `contextualStrings`.** MEASURED on this
machine: Thai exists on the legacy API with `supportsOnDevice = true`, and `contextualStrings` is Apple's
keyword-boosting hook — i.e. the *same* mechanism as §1.7, free, zero download, fully on-device. The probe was
blocked only by TCC (needs an `.app` bundle + a permission click). **Note the correction in §0: the modern
`SpeechTranscriber` API has no Thai at all, so the "just use Apple's free API" path that English-only
competitors enjoy is closed to you** — which is also why this is a moat rather than a commodity.

### 🥉 BEST CHEAP — **Gemini 3.5 Flash-Lite / 3 Flash, non-streaming, at $0.027–$0.09 per audio-hour**

**VENDOR-DOCS, input-only.** At 60 min/week that is **$0.007–$0.023 per user per month in audio input alone**;
output tokens are extra and are probably the larger term for Thai (`UNVERIFIED:` not measured). Even at 5×
that figure, ASR cost is not a variable in this business — it rounds to zero against a $20 subscription. Do not
optimise it. `UNVERIFIED:` Flash-tier Thai accuracy — see §5 🥇. The genuinely free option is the local path above.

### ⛔ DO NOT BUILD
| Approach | Why not | Grade |
|---|---|---|
| **Two parallel ASR passes (th + en) merged by an LLM** | Gladia shipped it: **~13% WER inter-utterance → ~41% intra-utterance** on Spanish-English with a real corpus. Thai-English would be worse. | **3P-EVAL** |
| **Azure continuous LID** | "Continuous LID doesn't support changing languages within the same sentence" | **VENDOR-DOCS** |
| **Whisper at `language=en` for mixed audio** | Recovers English, **hallucinates the Thai** (`เดี๋ยว…ให้ก่อนนะ` → "I'll give you a call"; one clip → `(speaking in foreign language)`). Silent fabrication. | **MEASURED** |
| **Autodetect as a code-switch strategy** | Identical output to `language=th`; one language per 30 s window. | **MEASURED** |
| **Typhoon ASR Realtime as the primary engine** | Excellent Thai (CER 9.84%, RTFx 4097×, CC-BY-4.0) but a **Transducer — no prompt-biasing hook**, Thai-only. Structurally cannot emit `deploy`. | **VENDOR-PAPER** |
| **Optimising for Thai "code-switching" benchmarks** | Typhoon's CS metric scores you *higher* for emitting **no Latin characters** (§2.1). Backwards for this product. | **VENDOR-PAPER** |
| **Thai domestic ASR vendors (iApp etc.)** | ~฿0.83–1.48/min ≈ **$1.5–2.7/hr**, 10–20× Soniox, no code-switch claim. | **VENDOR-DOCS** |
| **A reverse-transliteration dictionary (`ดีพลอย`→`deploy`)** | Same audio → `ดีโพล้อย` **and** `ดิบโล้ย` across two runs. No stable key exists. | **MEASURED** |


---

# 6. WHAT TO PROTOTYPE FIRST TO DE-RISK THIS

**First, define the metric — because WER is invalid here.**
arXiv 2211.16319 establishes that plain WER is meaningless for code-mixed text: "misspellings and borrowing of
words from two different writing systems … artificially inflate the WER." Use a **two-number scorecard**,
already validated by the §1.7 run:

> **ETR — English-Term Retention** = English tokens returned in Latin script ÷ English tokens actually spoken.
> *(Measured: Whisper-small `language=th` → **0/7 = 0%**; + 8-word prompt → **5/7 = 71%**.)*
> **Thai CER** on the Thai matrix text, with the English spans excluded.

ETR is the product metric. Thai CER is the regression guard — §1.7 showed biasing can corrupt adjacent Thai
(`ขึ้น`→`คืน`), so a rise in ETR must not be bought with a rise in Thai CER.

### Step 0 — Record 20 real utterances (½ day). Do this before anything else.
Everything measured in this brief used **macOS TTS voice Kanya** reading Latin text through a Thai G2P. A real
bilingual developer saying "deploy" almost certainly produces **crisper English phonology than Kanya does** —
so the 0/7 baseline is likely a **pessimistic bound**, and the true achievable ETR may be *higher* than 71%.
The bias direction is knowable but its size is not. Twenty real utterances from the target user
(the app's actual vocabulary: deploy, refactor, commit, branch names, framework names) converts the single
strongest evidence in this brief from synthetic to real. Nothing else has this leverage-to-cost ratio.
Keep the staged files in `scratchpad/thaitest/` + `scratchpad/pcm/` as the synthetic control set.

### Step 1 — The three-way bake-off (2 days). One prompt, one audio set, three engines.
Same 20 clips through:
1. **Soniox `stt-rt-v5`**, no language hint (auto). *Closes the one unproven gap on the top recommendation:
   whether Thai is genuinely inside their code-switch capability, or only inside their language list.*
2. **Gemini 3 Flash *and* Gemini 3 Pro** — test **both tiers**: the cheap price is Flash, the only published
   Thai benchmark is Pro (§4(d)-ii) — non-streaming, prompt: *"Transcribe verbatim. Keep English technical terms in Latin
   script. Never transliterate English into Thai script. Do not translate."* **This single test is the crux of
   the whole recommendation** — it is the only claim in §5's top slot that is `inferred` rather than sourced.
3. **Pathumma-Whisper Large-v3 + `initial_prompt`** glossary (replicating §1.7 at full model size).

Score all three on ETR + Thai CER. **Total cost: well under $1 of API credit.** Decision rule: if (2) holds the
script instruction reliably, take it; if (1) matches it at 200 ms and $0.12/hr, take (1); if neither beats (3),
ship local and keep the margin.

### Step 2 — Measure the 4(a) recoverability ratio *blind* (½ day).
Take the `language=th` outputs from step 1, strip the ground truth, and hand them to an LLM cold:
*"Some English technical terms in this Thai text were transliterated into Thai script. Restore them."*
Score three buckets from §4(a): **recovered** / **substituted into a real word** (`meeting→มีทิ้ง` — silent
corruption) / **merged or lost** (`branch main→รันสมีน`).
The **substituted + lost** fraction is the hard ceiling on any LLM-repair strategy, and it is the number that
decides whether repair is a viable layer or a liability. *(The §4(a) table is my own non-blind assessment —
this step is what makes it real.)*

### Step 3 — Unblock the free Apple path (1 day).
Wrap `thaiASR.swift` in a minimal `.app` bundle with `NSSpeechRecognitionUsageDescription` (it currently
aborts with SIGABRT under TCC), grant permission once, and run the same 20 clips through
`SFSpeechRecognizer(th-TH)`, `requiresOnDeviceRecognition = true`, **with and without
`contextualStrings = [english tech terms]`**. If Apple's on-device Thai + contextual boosting reaches a usable
ETR, the best-local-and-private option costs **zero dollars, zero download, and zero model shipping**. Cheapest
possible upside in the whole plan.

### Step 4 — Build the glossary engine (the actual moat, 1 week).
Whichever engine wins, §1.7 proved the *vocabulary* is the lever. Ship a component that assembles a
per-utterance English glossary from: frontmost app, current git branch + recent branch names, identifiers in
the open editor buffer, package.json/requirements.txt dependency names, and the user's own accepted
corrections. Budget **224 tokens** (Whisper's `n_text_ctx/2` cap) — English terms only, since the Thai matrix
needs no help — and rotate by context. No ASR vendor can replicate this; it is the defensible part.

### What would change the recommendation
- **Soniox passes step 1** → take it; least engineering, best latency, ranking simplifies.
- **Gemini holds the script instruction and Soniox does not** → audio-LLM path, and the prompt becomes the spec.
- **Neither holds, but `initial_prompt` scales** → ship local-first (Pathumma or Qwen3-ASR-1.7B). This is also
  the strongest privacy story, and given §0 it is a story no English-focused competitor can copy for Thai.
- **Step 2 shows a high substituted-or-lost fraction** → abandon LLM repair entirely and put all effort into
  prevention (biasing + prompting), because repair would be adding silent errors.

---

# 7. THE STRATEGIC PICTURE

Three independent sources converge on the same conclusion:

- **Speechmatics** built bilingual code-switch models for Southeast Asia — Mandarin-English, Malay-English,
  Tamil-English, Tagalog — and **skipped Thai**.
- **AssemblyAI's** 18-language code-switch list includes Vietnamese, Hindi, Mandarin — and **not Thai**.
- **CS-FLEURS**, 113 code-switched pairs across 52 languages including a 45-pair *low-resource* set, contains
  **no Thai**. The 127-paper systematic review of code-switching ASR (2018–2024) never mentions Thai. SEAME —
  the "South-East Asia" code-switching corpus — covers Singapore and Malaysia and skips Thailand.

**Thai-English code-switching is unserved by vendors, unbenchmarked by academia, and uncorpused.** That is
simultaneously the risk (nobody has solved it, so you can't buy it) and the opportunity (nobody has solved it,
so nobody is competing). The prior pass found the same on the product side: no dictation app publishes Thai
accuracy or a Thai-specific model claim.

**And the measured §1.7 result says the problem is more tractable than the silence implies.** A 487 MB model
and an eight-word glossary took English-term retention from 0% to 71%. The gap is not a modelling frontier —
it is an integration gap that nobody has bothered to close, because the people who could close it do not speak
Thai and the Thai NLP community is optimising a benchmark (§2.1) that scores this behaviour as a *defect*.

---

## Appendix: measured artefacts in this scratchpad
- `thaiLocales.swift` / `thaiLocales` — Apple locale probe (§0). Runs clean.
- `thaiASR.swift` / `thaiASR` — Apple recognition probe. **SIGABRT under TCC**; needs an `.app` bundle (§6 step 3).
- `thaitest/*.wav` — 5 Kanya-TTS clips (float32); `pcm/*.wav` — 16 kHz PCM16 conversions used for whisper.cpp.
- `wmodels/ggml-small.bin` — 487 MB, official whisper.cpp weights, used for §1.6/§1.7.
- Repro: `whisper-cli -m wmodels/ggml-small.bin -f pcm/cs3.wav -l th -nt [--prompt "deploy, refactor, function, commit, push, branch, main, meeting"]`

**Disk note:** this machine's data volume was at 100% (180 MB free) during research; a 1.5 GB model download
failed on `ENOSPC`, not network. Freed to ~2 GB. Relevant to §6 — a full-size local model needs headroom.
