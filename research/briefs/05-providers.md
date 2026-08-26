# Buyer's Guide: Speech-to-Text + Cleanup-LLM Options for a Desktop Dictation App

**Research date: 2026-08-24.** Every price below was captured on this date from the URL cited next to it.

> **Verification rule.** Each number carries the URL it came from. Where a page was unreachable, rendered as an
> empty JS shell, or the vendor simply does not publish the figure, the entry reads `UNVERIFIED:` and states what
> would be needed to close it. Nothing here is filled in from memory. Several pricing pages are Next.js shells that
> return navigation and no prices; those were re-fetched via the vendor's own docs site or `curl` + grep, and where
> that still failed the gap is left open rather than guessed.

---

## 0. Model names that were stale before this research

The brief was commissioned with model names that have all moved. Corrections, each verified:

| Name in the brief | Actual current name (Aug 2026) | Source |
|---|---|---|
| Deepgram "Nova family" | **Flux** is the flagship *streaming* model; **Nova-3** continues for batch and streaming | https://deepgram.com/pricing |
| AssemblyAI "Universal / Universal-Streaming" | **Universal-3.5 Pro** (async) + **Universal-3.5 Pro Realtime** (`u3-rt-pro`); Universal-2 and Universal-Streaming still sold; **SLAM-1 is deprecated** | https://www.assemblyai.com/pricing |
| ElevenLabs "Scribe" | **Scribe v2**, plus **Scribe v2 Realtime** (v1 superseded) | https://elevenlabs.io/pricing/api |
| OpenAI "whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe" | Those persist, plus **gpt-live-transcribe** and **gpt-realtime-whisper** | https://developers.openai.com/api/docs/pricing |
| Mistral "Voxtral" | **voxtral-mini-2602**, **voxtral-mini-realtime-2602**, voxtral-small-2507 | https://docs.mistral.ai/getting-started/models/models_overview/ |
| Groq "whisper-large-v3-turbo and any newer" | Still `whisper-large-v3-turbo` and `whisper-large-v3` — **no newer ASR model**; confirmed, not assumed | https://console.groq.com/docs/speech-to-text |
| NVIDIA "Parakeet TDT 0.6B v2/v3" | **v3 is current** (released 2025-08-14) | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |

---

## 1. Headline recommendation

Three findings drive the build-vs-buy decision, and none of them is about price:

1. **ASR cost is already irrelevant at $20/month.** Even the most expensive credible streaming option leaves
   ~78% gross margin at 60 min/week. The cheapest leaves ~99%. Price is not the discriminator — latency,
   streaming support, and retention terms are.
2. **The cleanup LLM is free in practice.** It costs $0.02–$0.31/user/month, i.e. 1–15% of the ASR line and
   ~0.1–1.5% of a $20 subscription. Do not spend engineering effort optimizing it. Pick on quality and latency.
3. **The privacy claim is the hard part, and most vendors fail it by default.** Deepgram's listed prices are tied to
   a program under which Deepgram *stores your audio to train on*; AssemblyAI's ToS grants an explicit training
   license; OpenAI's zero-retention requires prior approval. See §7 — this is the section that actually decides
   whether an honest privacy claim is possible.

**If the product's differentiator is privacy, the on-device path is not a cost optimization — it is the only
configuration that supports the claim without an enterprise contract.** And as of macOS 26 / Windows 11 24H2,
both platforms ship a free, offline, first-party transcription API (§4, §5). That is the real story here.

---

## 2. Cloud STT — verified pricing

All prices captured 2026-08-24. `$/hr` figures converted from `$/min` where the vendor prices per minute, and
vice-versa; the vendor's own unit is given first.

### 2.1 Streaming / realtime (what live dictation actually needs)

| Provider | Model | Vendor's price | $/hr | Notes | Source |
|---|---|---|---|---|---|
| **Soniox** | `stt-rt-v5` | **$0.12/hr** | 0.12 | cheapest verified streaming | https://soniox.com/pricing/ |
| **AssemblyAI** | Universal-Streaming (EN & multilingual) | **$0.15/hr** | 0.15 | billed on **WebSocket session duration, not audio duration** — idle time bills | https://www.assemblyai.com/pricing |
| **Together AI** | Whisper Large v3 (Streaming) | **$0.0035/min** | 0.21 | | https://www.together.ai/pricing |
| **Speechmatics** | Real-time Standard | **$0.24/hr** | 0.24 | Enhanced $0.43/hr | https://www.speechmatics.com/pricing |
| **Gladia** | Real-time | $0.75/hr Starter → **"as low as $0.25/hr"** Growth (commit) | 0.25–0.75 | | https://www.gladia.io/pricing |
| **Deepgram** | Nova-3 Monolingual (streaming) | **$0.0048/min promotional; $0.0077/min regular** | 0.29 / 0.46 | multilingual $0.0058 promo / $0.0092 regular | https://deepgram.com/pricing |
| **ElevenLabs** | Scribe v2 Realtime | **$0.39/hr** | 0.39 | | https://elevenlabs.io/pricing/api |
| **Deepgram** | **Flux** English | **$0.0065/min promotional; $0.0077/min regular** | 0.39 / 0.46 | Flux Multilingual $0.0078/min | https://deepgram.com/pricing |
| **Speechmatics** | Real-time Enhanced | **$0.43/hr** | 0.43 | | https://www.speechmatics.com/pricing |
| **AssemblyAI** | Universal-3.5 Pro Realtime (`u3-rt-pro`) | **$0.45/hr base** | 0.45 | add-ons stack (Medical Mode +$0.15/hr) | https://www.assemblyai.com/pricing |
| **OpenAI** | `gpt-live-transcribe` / `gpt-realtime-whisper` | **$0.017/min** | 1.02 | ~7× the field; Realtime API audio input separately $32.00/1M audio tokens, cached $0.40/1M | https://developers.openai.com/api/docs/pricing |
| **Azure AI Speech** | Real-time / Fast / Batch | `UNVERIFIED:` | — | page renders literal `$-` placeholders | see §8 |

### 2.2 Batch / pre-recorded

| Provider | Model | Vendor's price | $/hr | Source |
|---|---|---|---|---|
| **Groq** | `whisper-large-v3-turbo` | **$0.04/hr** (216× realtime speed factor) | 0.04 | https://console.groq.com/docs/speech-to-text |
| **Together AI** | Whisper Large v3 · Parakeet TDT 0.6B v3 · Nemotron 3 ASR Streaming 0.6B | **$0.0015/min** | 0.09 | https://www.together.ai/pricing |
| **Soniox** | `stt-rt-v5` async | **$0.10/hr** | 0.10 | https://soniox.com/pricing/ |
| **Rev.ai** | Reverb Turbo (EN) | **$0.10/hr** | 0.10 | Reverb $0.20/hr; foreign-language $0.30/hr; Whisper Fusion / Whisper Large $0.005/min | https://www.rev.ai/pricing |
| **Groq** | `whisper-large-v3` | **$0.111/hr** (189× speed factor) | 0.111 | https://console.groq.com/docs/speech-to-text |
| **Speechmatics** | Batch **Melia 1** (multilingual, batch-only) | **$0.129/hr** | 0.129 | Batch Standard $0.24/hr, Batch Enhanced $0.40/hr | https://www.speechmatics.com/pricing |
| **AssemblyAI** | Universal-2 | **$0.15/hr** | 0.15 | 99 languages | https://www.assemblyai.com/pricing |
| **AssemblyAI** | Universal-3.5 Pro | **$0.21/hr** | 0.21 | only 18 languages | https://www.assemblyai.com/pricing |
| **ElevenLabs** | Scribe v2 | **$0.22/hr** | 0.22 | +entity detection $0.07/hr, +keyterm prompting $0.05/hr | https://elevenlabs.io/pricing/api |
| **OpenAI** | `gpt-4o-mini-transcribe` | **$0.003/min** | 0.18 | | https://developers.openai.com/api/docs/pricing |
| **OpenAI** | Whisper · `gpt-4o-transcribe` | **$0.006/min** | 0.36 | | https://developers.openai.com/api/docs/pricing |
| **Deepgram** | Nova-3 Monolingual pre-recorded | **$0.0043/min** | 0.26 | multilingual $0.0052/min; Whisper Large $0.0048/min | https://deepgram.com/pricing |
| **Gladia** | Async | $0.61/hr Starter → **"as low as $0.20/hr"** Growth | 0.20–0.61 | https://www.gladia.io/pricing |
| **Google Cloud STT** | **Chirp** (a "Standard" model, V2 API only) | **$0.024/min without data logging; $0.016/min with data logging**; volume tier $0.01/min above 500,000 min/mo; first 60 min/mo free | 0.96 / 1.44 | https://cloud.google.com/speech-to-text/pricing |
| **Google Cloud STT** | Dynamic Batch Recognition (Standard) | **$0.003/min** | 0.18 | same page |
| **Mistral** | `voxtral-mini-2602`, `voxtral-mini-realtime-2602` | `UNVERIFIED:` — pricing page states only "speech models are priced per minute", no figure | — | https://mistral.ai/pricing |
| **Fireworks AI** | — | `UNVERIFIED:` — **no audio pricing on the pricing page at all** | — | https://fireworks.ai/pricing |
| **Baseten** | Whisper Large V3 listed under popular models | `UNVERIFIED:` — no per-audio-minute rate published | — | https://www.baseten.co/pricing/ |

**Note the Google inversion:** Google is the *only* provider that charges you **50% more to not be logged**
($0.024 vs $0.016/min). Every other vendor either logs by default silently or charges the same either way.
Deepgram does the same thing in the opposite direction (§7).

### 2.3 Accuracy, latency, languages, rate limits — what vendors actually publish

This is where the marketing thins out. Verified:

| Provider | Languages | Published WER | Published latency | Rate limits |
|---|---|---|---|---|
| Deepgram Flux | 10 (`flux-general-multi`: EN, ES, FR, DE, HI, RU, PT, JA, IT, NL); `flux-general-en` English-only | **None.** Docs claim "Nova-3 level accuracy" with no number | **None** in docs; only "ultra-low latency optimized for voice agent pipelines". `UNVERIFIED:` a widely-repeated "sub-300ms" figure appears in search summaries but I could not find it on a Deepgram-owned page | `UNVERIFIED:` |
| Deepgram Nova-3 | 10 primary + 60+ variants | Only **relative**: "54.2% reduction in WER for streaming and 47.4% for batch processing compared to competitors" — no absolute WER | None published | `UNVERIFIED:` |
| AssemblyAI Universal-3.5 Pro | **18** | `UNVERIFIED:` | `UNVERIFIED:` | new-session rate limit **5 for free accounts**, scales with usage; >100 new streams/min needs enterprise contract |
| AssemblyAI Universal-2 | **99** | `UNVERIFIED:` | `UNVERIFIED:` | as above |
| Speechmatics | **55+** | `UNVERIFIED:` | `UNVERIFIED:` | `UNVERIFIED:` |
| Gladia | **100+** | `UNVERIFIED:` | `UNVERIFIED:` | `UNVERIFIED:` |
| Groq Whisper | multilingual (Whisper's ~99) | `UNVERIFIED:` | **216× realtime** (turbo), **189×** (v3) — throughput, not latency | `UNVERIFIED:` |
| Soniox `stt-rt-v5` | `UNVERIFIED:` | `UNVERIFIED:` | `UNVERIFIED:` | `UNVERIFIED:` |

**Assessment:** no major cloud STT vendor publishes an absolute WER on its own docs. Deepgram publishes only
percentage reductions against unnamed competitors. Any WER comparison in a board deck sourced from vendor
marketing is not defensible. The only absolute, reproducible WER numbers found in this research are from the
**open models** (§3) — which is itself an argument for benchmarking in-house on your own audio.

---

## 3. Local / on-device STT

### 3.1 whisper.cpp (ggml)

Verified from the repo on disk at `repos/whispercpp`, git rev `233fe1fc9b48a09e361d3594520838ca266537fe`
(2026-08-22) — primary source, `models/README.md` and `README.md`:

| Model | Disk | RAM | Quantized (q5_0) disk |
|---|---|---|---|
| tiny / tiny.en | 75 MiB | ~273 MB | — |
| base / base.en | 142 MiB | ~388 MB | — |
| small / small.en | 466 MiB | ~852 MB | — |
| medium / medium.en | 1.5 GiB | ~2.1 GB | — |
| large-v1 / v2 / v3 | 2.9 GiB | ~3.9 GB | **1.1 GiB** (large-v2-q5_0, large-v3-q5_0) |
| **large-v3-turbo** | **1.5 GiB** | — | **547 MiB** (large-v3-turbo-q5_0) |

- **Quantization:** integer quantization supported via `./build/bin/quantize ... q5_0`.
- **Metal:** "On Apple Silicon, the inference runs fully on the GPU via Metal."
- **Core ML / ANE:** encoder can run on the Apple Neural Engine via Core ML — **"more than x3 faster compared
  with CPU-only execution."** Caveat from the README: *"The first run on a device is slow, since the ANE service
  compiles the Core ML model to some device-specific format."* — a real first-launch UX problem to design around.
- `UNVERIFIED:` **measured RTF on M1/M2/M3/M4.** The README does not contain a per-chip RTF table. To close this
  I would run `./build/bin/whisper-bench` on the target Macs, or pull the repo's community benchmark issue.
  I am not going to quote an RTF I did not measure.

### 3.2 faster-whisper / CTranslate2

From https://github.com/SYSTRAN/faster-whisper (13 minutes of audio, beam size 5):

| Config | Implementation | Time | Memory |
|---|---|---|---|
| large-v2, GPU fp16 | openai/whisper | 2m23s | 4708 MB |
| large-v2, GPU fp16 | whisper.cpp (Flash Attention) | 1m05s | 4127 MB |
| large-v2, GPU fp16 | **faster-whisper** | **1m03s** | 4525 MB |
| large-v2, GPU **int8** | faster-whisper | **59s** | **2926 MB** |
| large-v2, GPU fp16, batch_size=8 | faster-whisper | **17s** | 6090 MB |
| small, CPU fp32 | openai/whisper | 6m58s | 2335 MB |
| small, CPU fp32 | **whisper.cpp** | **2m05s** | **1049 MB** |
| small, CPU fp32 | faster-whisper | 2m37s | 2257 MB |

Claim: "up to 4 times faster than openai/whisper for the same accuracy while using less memory."
Quantizations: `int8`, `float16`, `int8_float16`.
**Note for a Mac-first product:** on *CPU*, whisper.cpp beats faster-whisper (2m05s / 1049 MB vs 2m37s / 2257 MB).
faster-whisper's advantage is CUDA. For Apple Silicon, whisper.cpp or MLX is the right lane.

### 3.3 NVIDIA Parakeet TDT 0.6B v3

From https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (released 2025-08-14; v3 is current):

- **600M parameters**, license **CC-BY-4.0** — permissive, commercial use allowed with attribution.
- **25 European languages** (BG, HR, CS, DA, NL, EN, ET, FI, FR, DE, EL, HU, IT, LV, LT, MT, PL, PT, RO, SK, SL, ES, SV, RU, UK).
- **RTFx 3,332.74** on the Open ASR Leaderboard.
- **WER: 6.34% average**; LibriSpeech test-clean **1.93%**, test-other **3.59%**, GigaSpeech 9.59%, Earnings-22 11.42%, AMI 11.31%.

**Apple Silicon ports:**
- **FluidAudio** (https://github.com/FluidInference/FluidAudio) — Apache 2.0, runs Parakeet TDT v3 on the **ANE via
  CoreML**, explicitly avoiding GPU/MPS to keep power low for always-on use. Published: **"~190x on M4 Pro
  (processes 1 hour of audio in ~19 seconds)."** Ships v3 (multilingual, 25 languages) and v2 (English-only, higher recall).
- **parakeet-mlx** (https://github.com/senstella/parakeet-mlx) — Apache 2.0, MLX implementation, default model
  `mlx-community/parakeet-tdt-0.6b-v3`; supports streaming, word timestamps. `UNVERIFIED:` no RTF published in README.
- **WhisperKit** (https://github.com/argmaxinc/WhisperKit) — MIT, CoreML, recommends **large-v3-turbo compressed
  (626 MB)** across iOS and macOS; auto-downloads the right model per device. `UNVERIFIED:` per-chip benchmarks
  live in a separate `BENCHMARKS.md` not fetched. **No Parakeet support found in the README.**

**This is the strongest local option for a Mac dictation app**: 190× realtime on an M4 Pro means a 30-second
dictation transcribes in ~0.16s, with a 1.93% LibriSpeech WER that beats every WER any cloud vendor is willing to publish.

### 3.4 Moonshine · Kyutai STT · distil-whisper

| Model | Verified facts | Source |
|---|---|---|
| **Moonshine** | MIT license. Repo claims models "from higher accuracy than Whisper Large V3 down to tiny 1MB models". `UNVERIFIED:` parameter counts, WER vs Whisper tiny/base, speed multiplier, full language list — README defers to moonshine-voice.readthedocs.io | https://github.com/usefulsensors/moonshine |
| **Kyutai STT** | `kyutai/stt-1b-en_fr` — ~1B params, **0.5s delay**, EN+FR, semantic VAD. `kyutai/stt-2.6b-en` — ~2.6B params, **2.5s delay**, EN only. Word-level timestamps, streaming. **Weights CC-BY-4.0**, code MIT/Apache. H100 processes 400 streams realtime; L40S serves 64 connections at RTF 3×. **MLX build available for on-device Apple.** | https://github.com/kyutai-labs/delayed-streams-modeling |
| **distil-large-v3.5** | **756M params**, ~**1.46 RTFx relative to whisper-large-v3-turbo** (~1.5× faster). WER: short-form OOD **7.08**, long-form OOD **11.39**. **English only.** MIT (inherited from Whisper). Newest in the family. | https://huggingface.co/distil-whisper/distil-large-v3.5 |

Kyutai's **0.5s delay** on the 1B model is the number to note — it is the only *published latency* figure from any
STT source in this entire brief, cloud or local.

---

## 4. Apple on-device — `SpeechAnalyzer` / `SpeechTranscriber` (the zero-marginal-cost path)

**Verified directly from Apple's documentation JSON API** (`developer.apple.com/tutorials/data/documentation/speech/...`),
because the HTML docs are JS-rendered and return an empty body to a plain fetch.

**Availability — exact, from Apple's own platform metadata:**

```
SpeechAnalyzer   introducedAt 26.0 — iOS, iPadOS, Mac Catalyst, macOS, tvOS, visionOS   (beta: false)
SpeechTranscriber introducedAt 26.0 — iOS, iPadOS, Mac Catalyst, macOS, tvOS, visionOS  (beta: false)
```

So: **macOS 26.0+ / iOS 26.0+, shipping (not beta).**

- **What it is:** "Analyzes spoken audio content in various ways and manages the analysis session." `SpeechTranscriber`
  is "A speech-to-text transcription module that's appropriate for normal conversation and general purposes."
  Results arrive via `AsyncSequence`; input is supplied as an `AsyncSequence` you populate — i.e. **native streaming**.
- **Cost: $0.** It is an OS framework. There is no metering, no API key, no account.
- **On-device / offline:** models are ML assets "downloaded from Apple's servers and managed by the system…
  the system retains and updates it automatically, and shares it with other apps" (`AssetInventory`). So the
  *models* download once, then transcription is local. **Design consequence:** you must handle the
  not-yet-installed case — assets are installed against a per-app "asset reservation" budget, and your app
  "does not work with assets directly", it configures modules and the system resolves the assets.
- **Device support gate:** `SpeechTranscriber.isAvailable` / `supportedLocales` must be checked; docs say
  `supportedLocales` "is empty if the device does not support the transcriber", and to "consider disabling the
  feature" if unsupported. So it is **not** universally available even on macOS 26.
- **Languages:** `UNVERIFIED:` Apple publishes `supportedLocales` and `installedLocales` as **runtime properties,
  not a documented list** — there is no language count on Apple's docs. Third-party benchmark write-ups put it at
  "roughly 30 locales" vs Whisper's 100+, but that is not an Apple source. **To close this:** run
  `SpeechTranscriber.supportedLocales` on a macOS 26 machine and count. This matters — it is the single biggest
  functional gap vs Whisper.
- **Accuracy:** `UNVERIFIED: — third-party only.` Independent 2026 benchmarks report SpeechAnalyzer at
  **2.12% WER on LibriSpeech test-clean and 4.56% on test-other**, versus Whisper Small's 3.74% / 7.95%, at roughly
  1/3 of Whisper Small's compute per second of audio. Apple publishes no WER of its own. Treat the numbers as
  directional. (Reported by e.g. https://www.metatalks.ai/apples-new-on-device-speech-engine-tops-whisper-on-english-accuracy-benchmark-finds/
  and https://gigazine.net/gsc_news/en/20260714-apple-speech-analyzer-benchmark/ — **not primary sources**.)

**`SFSpeechRecognizer` (the old API)** — verified from Apple docs JSON: introduced iOS 10.0 / macOS 10.15,
**not marked deprecated**. Critical limitation in Apple's own words: *"Each speech recognizer supports only one
language, which you specify at creation time… **For some languages, the recognizer might require an Internet
connection.**"* That last clause is why `SFSpeechRecognizer` cannot underpin a privacy claim, and why
`SpeechAnalyzer` matters: it is the first Apple API that is unambiguously local.

**Verdict:** on macOS 26+, this is a genuine $0-marginal-cost, offline, streaming ASR path with (per third-party
benchmarks) better English accuracy than Whisper Small. It is the strongest argument in the whole brief. The two
open risks are the **language count** and the **device-support gate** — both cheap to resolve with a test machine.

---

## 5. Windows on-device — and why "Windows 11 only" is a real constraint

**Verified from https://learn.microsoft.com/en-us/windows/ai/apis/speech-recognition (page dated 2026-07-07).**

Yes — **Windows 11 exposes a first-party on-device transcription API.** Microsoft's own description:
*"Speech Recognition is an AI-powered on-device speech-to-text technology that transcribes spoken audio into text
in real-time or from pre-recorded files. By running entirely on-device, it provides low-latency transcription
without requiring a network connection or sending audio data to the cloud."*

**Prerequisites — exact, and this is the answer to the "Windows 11 only" question:**
- **Windows 11, version 24H2 (build 26100) or later**
- **WinAppSDK 1.7.1 or later**
- Hardware: **Copilot+ PC with an NPU, *or* any Windows PC meeting recommended CPU specs**
- App must be **packaged as MSIX** with the **`systemAIModels` capability** in `Package.appxmanifest`, and
  `MaxVersionTested` set to `10.0.26226.0` or later (older values cause "Not declared by app" errors)

**So the "Windows 11 only" requirement is explained precisely by build 26100 (24H2) — not by Copilot+.** A Copilot+
PC is *not* required, which is commercially important: it is not a Copilot+-only feature.

| Hardware | Status | Detail |
|---|---|---|
| NPU (Copilot+) | Available | Best performance; **model preinstalled** |
| CPU | Available | **Model NOT preinstalled** — downloaded on demand via Windows Update on first `EnsureReadyAsync` |
| GPU | **Not supported** | — |

Recommended CPU spec (Microsoft's, "recommendations, not hard minimums"): **4+ physical cores, 3 GHz+ base
clock, 32 MB+ L3 cache.** Hardware selection is automatic — no developer or user opt-in to pick CPU on a Copilot+ device.

Modes: **BatchRecognition** (whole file) and **StreamingRecognition** (continuous, from a mic device, via a
`Recognized` event). Cost: **$0**, it is an OS API.

**Product consequences worth planning for:**
- On CPU-only machines the user must **consent to a background model download**, and can later **remove the model**
  at Settings → System → AI Components — at which point `GetReadyState` returns `NotReady` and you must re-run the
  consent flow. Your app has to handle a model disappearing at runtime.
- `NotSupportedOnCurrentSystem` requires a fallback path (older Windows SDK speech recognition, or cloud).
- **MSIX packaging is mandatory.** If the desktop app currently ships as a plain unpackaged .exe, this is a
  real build-system change, not a flag.
- `UNVERIFIED:` supported languages and any WER/latency figure — the Learn page publishes none. Also `UNVERIFIED:`
  which model backs it (Microsoft deliberately tells developers to call it "the speech recognition model" rather
  than a brand name).

---

## 6. Cleanup LLMs

Prices per 1M tokens, captured 2026-08-24.

| Provider | Model | Input $/Mtok | Output $/Mtok | Speed | Source |
|---|---|---|---|---|---|
| **Groq** | `openai/gpt-oss-20b` | **$0.075** | **$0.30** | **~1000 tok/s**, 131,072 ctx | https://console.groq.com/docs/models |
| **Groq** | `openai/gpt-oss-120b` | $0.15 | $0.60 | ~500 tok/s, 131,072 ctx | same |
| **OpenAI** | `gpt-5-nano` | **$0.05** | **$0.40** | — | https://developers.openai.com/api/docs/pricing |
| **OpenAI** | `gpt-4.1-nano` | $0.10 | $0.40 | — | same |
| **OpenAI** | `gpt-5-mini` | $0.25 | $2.00 | — | same |
| **OpenAI** | `gpt-4.1-mini` | $0.40 | $1.60 | — | same |
| **Google** | `gemini-2.5-flash-lite` | **$0.10** (text) | **$0.40** | — | https://ai.google.dev/gemini-api/docs/pricing |
| **Google** | `gemini-3.5-flash-lite` | $0.30 | $2.50 | — | same |
| **Google** | `gemini-3.7-flash` / `3.6-flash` | $0.75 (through 2026-12-31) | $3.75 | — | same |
| **Anthropic** | **Claude Haiku 4.5** | **$1.00** | **$5.00** | — | https://platform.claude.com/docs/en/about-claude/pricing |
| **Cerebras** | — | `UNVERIFIED:` | `UNVERIFIED:` | only an unquantified "20x faster than OpenAI and Anthropic" marketing claim; free trial $5 credit, Developer tier "starts at $10" | https://www.cerebras.ai/pricing |

**Batch discounts (irrelevant here — dictation cleanup is interactive — but recorded):** OpenAI **50%**,
Google **50%**, Anthropic **50%**. Anthropic prompt caching: cache hits **0.1×** base input.

**Latency:** `UNVERIFIED:` — **no vendor in this table publishes a TTFT figure.** Groq publishes throughput
(tok/s), which is not TTFT. This matters more than price for a dictation UX: the user is staring at a spinner
after they stop talking. **Recommendation: measure TTFT yourself against your real prompt** — it is the only
number that decides this choice, and nobody publishes it.

**One Anthropic-specific gotcha, from Anthropic's own pricing page:** *"Claude 4.7 and later models and Claude
Mythos Preview use a newer tokenizer… This tokenizer produces approximately 30% more tokens for the same text."*
Haiku 4.5 uses the older tokenizer, so it is unaffected — but any future migration to a 4.7+ model carries a
hidden ~30% cost increase on identical text. Budget for it.

**Local cleanup LLM on Apple Silicon:** `UNVERIFIED:` — https://github.com/ml-explore/mlx-lm confirms 4-bit
quantization (default example `mlx-community/Llama-3.2-3B-Instruct-4bit`) and warns "Models which are large
relative to the total RAM available on the machine can be slow", but **publishes no tok/s or TTFT table** in the
README (a `/benchmarks` folder exists but was not fetched). Third-party benchmarks (**not primary**) report
Qwen3-14B 4-bit on an M4 Max/64 GB at **~38 tok/s median with TTFT 308–315 ms**. A 3–4B model would be
materially faster and fit in ~2–3 GB. **To close:** run `mlx_lm.benchmark` on target hardware. Given that the
cloud cleanup costs ~$0.02/user/month, local cleanup is justified by *privacy*, not by cost.

---

## 7. Unit economics

### 7.1 Assumptions and arithmetic

```
Audio:   60 min/week × 52 weeks ÷ 12 months = 3,120 ÷ 12   = 260 audio-min/month  (4.333 hr/month)
Words:   9,000 words/week × 52 ÷ 12         = 468,000 ÷ 12  = 39,000 words/month
Speaking rate check: 9,000 words ÷ 60 min   = 150 words/min  (a realistic dictation rate — assumptions are consistent)
Tokens:  39,000 words ÷ 0.75 words-per-token = 52,000 input tokens/month
Cleanup rewrite emits ~the same length       = 52,000 output tokens/month
```

**Monthly ASR COGS** = 260 × (price per audio-minute)
**Monthly cleanup COGS** = 0.052 × (input $/Mtok) + 0.052 × (output $/Mtok)

Worked example, **Groq `whisper-large-v3-turbo` + `gpt-5-nano`**:
```
ASR:      $0.04/hr × 4.333 hr                        = $0.1733
Cleanup:  0.052 × $0.05  = $0.0026  (input)
          0.052 × $0.40  = $0.0208  (output)         = $0.0234
Total COGS/user/month                                = $0.1967
Gross margin at $20                                  = (20 − 0.1967) / 20 = 99.0%
```

### 7.2 Cleanup-LLM cost alone (this is the load-bearing result)

| Model | $/user/month | % of a $20 subscription |
|---|---|---|
| Groq `gpt-oss-20b` | **$0.0195** | 0.10% |
| OpenAI `gpt-5-nano` | **$0.0234** | 0.12% |
| Gemini 2.5 Flash-Lite / `gpt-4.1-nano` | $0.0260 | 0.13% |
| Groq `gpt-oss-120b` | $0.0390 | 0.20% |
| `gpt-4.1-mini` | $0.1040 | 0.52% |
| `gpt-5-mini` | $0.1170 | 0.59% |
| Gemini 3.5 Flash-Lite | $0.1456 | 0.73% |
| Gemini 3.7 Flash | $0.2340 | 1.17% |
| **Claude Haiku 4.5** | **$0.3120** | 1.56% |

**The entire cleanup-LLM decision spans 1.5% of one subscription.** Even the most expensive option here
(Haiku 4.5, 16× the cheapest) is noise against ASR. **Choose it on output quality and TTFT, never on price.**

### 7.3 Full COGS table — ASR + cleanup (`gpt-5-nano`), 260 min/month

Sorted by total. "BE hr/mo" = break-even audio-hours per user before a $20 subscription goes underwater.

| Provider / model | Mode | $/audio-min | ASR $/mo | **Total $/mo** | **GM% @ $20** | Break-even min/mo | BE hr/mo | Free-tier $/mo |
|---|---|---|---|---|---|---|---|---|
| **Local** (Apple SpeechAnalyzer / Windows AI / whisper.cpp / Parakeet) | local | 0.00000 | **0.000** | **0.023** | **99.9%** | ∞ | ∞ | 0.005 |
| Groq `whisper-large-v3-turbo` | batch | 0.00067 | 0.173 | **0.197** | **99.0%** | 26,432 | 440 | 0.044 |
| Together Whisper v3 / Parakeet TDT v3 | batch | 0.00150 | 0.390 | 0.413 | 97.9% | 12,579 | 210 | 0.092 |
| Soniox `stt-rt-v5` async | batch | 0.00167 | 0.433 | 0.457 | 97.7% | 11,385 | 190 | 0.102 |
| Rev.ai Reverb Turbo | batch | 0.00167 | 0.433 | 0.457 | 97.7% | 11,385 | 190 | 0.102 |
| Groq `whisper-large-v3` | batch | 0.00185 | 0.481 | 0.504 | 97.5% | 10,309 | 172 | 0.112 |
| Speechmatics Melia 1 | batch | 0.00215 | 0.559 | 0.582 | 97.1% | 8,929 | 149 | 0.129 |
| **Soniox `stt-rt-v5` realtime** | **stream** | 0.00200 | 0.520 | **0.543** | **97.3%** | 9,569 | 159 | 0.121 |
| **AssemblyAI Universal-Streaming** | **stream** | 0.00250 | 0.650 | **0.673** | **96.6%** | 7,722 | 129 | 0.150 |
| AssemblyAI Universal-2 | batch | 0.00250 | 0.650 | 0.673 | 96.6% | 7,722 | 129 | 0.150 |
| OpenAI `gpt-4o-mini-transcribe` | batch | 0.00300 | 0.780 | 0.803 | 96.0% | 6,472 | 108 | 0.179 |
| Together Whisper v3 Streaming | stream | 0.00350 | 0.910 | 0.933 | 95.3% | 5,571 | 93 | 0.208 |
| AssemblyAI Universal-3.5 Pro | batch | 0.00350 | 0.910 | 0.933 | 95.3% | 5,571 | 93 | 0.208 |
| Gladia async (Growth commit) | batch | 0.00333 | 0.867 | 0.890 | 95.5% | 5,842 | 97 | 0.198 |
| Rev.ai Reverb | batch | 0.00333 | 0.867 | 0.890 | 95.5% | 5,842 | 97 | 0.198 |
| ElevenLabs Scribe v2 | batch | 0.00367 | 0.953 | 0.977 | 95.1% | 5,324 | 89 | 0.217 |
| Speechmatics RT Standard | stream | 0.00400 | 1.040 | 1.063 | 94.7% | 4,890 | 82 | 0.236 |
| Gladia RT (Growth commit) | stream | 0.00417 | 1.083 | 1.107 | 94.5% | 4,699 | 78 | 0.246 |
| Deepgram Nova-3 stream (promo) | stream | 0.00480 | 1.248 | 1.271 | 93.6% | 4,090 | 68 | 0.283 |
| Deepgram Nova-3 pre-recorded | batch | 0.00430 | 1.118 | 1.141 | 94.3% | 4,556 | 76 | 0.254 |
| **Deepgram Flux EN (promo)** | **stream** | 0.00650 | 1.690 | **1.713** | **91.4%** | 3,035 | 51 | 0.381 |
| ElevenLabs Scribe v2 Realtime | stream | 0.00650 | 1.690 | 1.713 | 91.4% | 3,035 | 51 | 0.381 |
| Speechmatics RT Enhanced | stream | 0.00717 | 1.863 | 1.887 | 90.6% | 2,756 | 46 | 0.419 |
| AssemblyAI U-3.5 Pro Realtime | stream | 0.00750 | 1.950 | 1.973 | 90.1% | 2,635 | 44 | 0.439 |
| **Deepgram Flux / Nova-3 (regular, post-promo)** | stream | 0.00770 | 2.002 | **2.025** | **89.9%** | 2,567 | 43 | 0.450 |
| OpenAI whisper / `gpt-4o-transcribe` | batch | 0.00600 | 1.560 | 1.583 | 92.1% | 3,284 | 55 | 0.352 |
| Gladia async (Starter PAYG) | batch | 0.01017 | 2.643 | 2.667 | 86.7% | 1,950 | 33 | 0.593 |
| **OpenAI `gpt-live-transcribe`** | **stream** | 0.01700 | 4.420 | **4.443** | **77.8%** | 1,170 | 20 | 0.988 |
| Google Chirp (data logging ON) | batch | 0.01600 | 4.160 | 4.183 | 79.1% | 1,243 | 21 | 0.930 |
| **Google Chirp (logging OFF)** | batch | 0.02400 | 6.240 | **6.263** | **68.7%** | 830 | 14 | 1.392 |

### 7.4 Free tier: 2,000 words/week

```
2,000 words/week ÷ 150 words/min = 13.33 audio-min/week
13.33 × 52 ÷ 12                  = 57.8 audio-min/month
57.8 ÷ 260                       = 22.2% of a paid user's usage
```
So **a free user costs 22.2% of a paid user** — the rightmost column above. Even on the most expensive option
(Google Chirp, logging off) a free user costs **$1.39/month**; on Groq batch, **$0.044**; on local, **$0.005**.

**Free-tier viability:** at a 5% free→paid conversion rate you need 19 free users per paid user. Cost of those
19 free users:
- Local: 19 × $0.005 = **$0.10** — irrelevant.
- Groq batch: 19 × $0.044 = **$0.84** — 4% of one subscription. Fine.
- Deepgram Flux regular: 19 × $0.450 = **$8.55** — that is **43% of a $20 subscription** consumed by free users.
- Google Chirp logging-off: 19 × $1.39 = **$26.41** — **the free tier alone exceeds the subscription price.** Not viable.

**This is where provider choice actually bites.** Not on the paid user — on the free funnel.

### 7.5 Gross-margin implication

- **Every credible option clears 90% gross margin on the paid user at 60 min/week.** ASR is not a margin risk at
  this usage level. A $20/month product is not constrained by STT COGS.
- **Break-even is 43–440 audio-hours/month** for the sensible choices — **10× to 100× the modelled 4.33 hr/month.**
  A user would have to dictate 1.5–15 hours *per day, every day* to lose money. Power-user abuse is a
  non-risk except on OpenAI Realtime (20 hr/mo) and Google Chirp (14 hr/mo).
- **The margin question is therefore not "which STT" but "how big is the free funnel"** (§7.4) and **"what does
  the privacy claim cost"** (§7.6).

### 7.6 The hidden cost: the price of not being trained on

This is the finding that changes the arithmetic, and it applies to the two vendors most likely to be shortlisted:

- **Deepgram.** Deepgram's own docs state the Model Improvement Partnership Program offers *"Discounted pricing for
  program participants"*, and that when enrolled *"Deepgram stores fractional increments of data for the continued
  improvement of our voice AI models."* Opting out (`mip_opt_out=true`) means *"Data from opted-out requests is
  retained only for the duration necessary to process the request."*
  **`UNVERIFIED:` the discount percentage.** Deepgram's own page does not state it. Third-party sources (a
  competitor's blog and a GitHub discussion) claim listed rates assume opt-in and that opting out forfeits **50%**.
  **If that 50% is right, Deepgram's privacy-preserving price is ~$0.0154/min, total COGS ~$4.03/mo, GM 79.8%, and
  break-even drops to ~21 hr/mo** — moving Deepgram from best-in-class to worse than most of the field.
  **This is the single highest-value number to confirm before signing.** Ask Deepgram directly, in writing.
- **Google.** Charges **$0.024/min without data logging vs $0.016/min with** — a **+50% privacy premium**, stated
  openly on the pricing page. Same shape, disclosed.

**Budget a 1.5–2× multiplier on any cloud ASR quote if the privacy claim is load-bearing.** The headline prices in
§2 are, for at least two major vendors, the *surveillance* price.

---

## 8. Retention, training, and whether an honest privacy claim is possible

A binary "zero retention: yes/no" column would be misleading. The honest split is three-way:
**(a)** is training-on-your-data off by default? **(b)** is there zero storage, or short retention for abuse
monitoring? **(c)** is (b) gated behind an enterprise agreement or approval?

| Provider | (a) Training off by default? | (b) Retention | (c) Enterprise-gated? | Verified language |
|---|---|---|---|---|
| **Apple SpeechAnalyzer** | **N/A — no data leaves the device** | **None** | **No** | On-device OS framework; models managed locally by `AssetInventory`. Nothing transmitted. |
| **Windows AI Speech Recognition** | **N/A — no data leaves the device** | **None** | **No** | *"By running entirely on-device, it provides low-latency transcription without requiring a network connection or sending audio data to the cloud."* |
| **Local OSS** (whisper.cpp, Parakeet/FluidAudio, faster-whisper, Kyutai, Moonshine) | **N/A** | **None** | **No** | You run the weights. MIT / Apache-2.0 / CC-BY-4.0. |
| **OpenAI** | **Yes** — *"data sent to the OpenAI API is not used to train or improve OpenAI models (unless you explicitly opt in)"* | **30 days** abuse-monitoring logs | **YES for ZDR** | *"currently, these controls are subject to prior approval by OpenAI and acceptance of additional requirements."* ZDR covers `/v1/audio/transcriptions`, `/v1/audio/translations`, `/v1/realtime`. |
| **ElevenLabs** | **Yes for third-party LLMs** — *"agreements… which expressly prohibit such providers from training their models on customer content, whether or not Zero Retention Mode is enabled"* | Default: *"ElevenLabs retains data… to enhance services, troubleshoot issues, and ensure the security"* | **YES** — *"Enterprise customers can use Zero Retention Mode"*, *"available to select enterprise customers"* | ZRM covers *"All endpoints starting with `/v1/speech-to-text/`"*, audio in and text out. `enable_logging=false` triggers it. HIPAA requires ZRM + BAA. |
| **AssemblyAI** | **NO — training is licensed by default** | Not stated | **Opt-out is plan-dependent** | ToS §4.3 grants AssemblyAI licence to *"use, modify reproduce, distribute, display and otherwise exploit the Customer Data"* including to *"train AssemblyAI's artificial intelligence and machine learning models"*. Opt-out exists *"to the extent applicable to Customer's pricing plan"*. No retention window published. |
| **Deepgram** | **NO — listed pricing is tied to the training program** | Enrolled: *"stores fractional increments of data for the continued improvement of our voice AI models"*. Opted out: *"retained only for the duration necessary to process the request"* | Opt-out is a **request parameter** (`mip_opt_out=true`), not a contract — **good** — but see §7.6 on price | Privacy policy only says *"retained, stored, and deleted according to our agreement with our business customer"* — no default window. |
| **Google Cloud STT** | `UNVERIFIED:` | Data logging is a **priced, explicit choice**: $0.016/min with, $0.024/min without | No — it is a per-request/SKU choice | Pricing page distinguishes *"Speech Recognition (with data logging)"* as a separate SKU. |
| **Speechmatics / Soniox / Gladia / Rev.ai / Together / Fireworks / Baseten / Mistral / Azure** | `UNVERIFIED:` | `UNVERIFIED:` | `UNVERIFIED:` | Not researched to DPA depth — see §9. Gladia's pricing page claims *"GDPR, HIPAA, and SOC 2 Type 2 compliance, plus data sovereignty controls"* on all paid plans, which is promising but is a compliance claim, not a retention term. |

### Can we honestly claim privacy?

**Yes — but only on three configurations:**

1. **Apple `SpeechAnalyzer` on macOS 26+** — strongest claim available. Nothing leaves the device. No contract needed,
   no vendor to trust, no marginal cost. Claim is verifiable by a user with Little Snitch.
2. **Windows AI Speech Recognition on Windows 11 24H2+** — same claim, same strength, in Microsoft's own words.
3. **Self-hosted open weights** (whisper.cpp, Parakeet TDT v3 via FluidAudio, Kyutai) — same claim; you control the binary.

**Conditionally, with caveats you must disclose:**
4. **OpenAI with approved ZDR** — genuinely strong *once approved*, but approval is discretionary and
   pre-conditioned. You cannot ship a privacy claim that depends on an approval you have not yet received.
5. **ElevenLabs with Zero Retention Mode** — strong, but **enterprise-only**. At an early stage you will not have it,
   and the default is that ElevenLabs retains data.
6. **Deepgram with `mip_opt_out=true`** — the *mechanism* is the best of any cloud vendor (a per-request parameter,
   not a contract negotiation), and the opted-out retention language is genuinely tight. The catch is price (§7.6).

**No, not honestly:**
7. **AssemblyAI on a standard plan.** Their ToS grants an explicit model-training licence over Customer Data, with
   opt-out only *"to the extent applicable to Customer's pricing plan"*. Shipping a privacy claim on top of
   default-plan AssemblyAI would be misleading to users.

**Bottom line for positioning:** a privacy claim built on a cloud vendor is a claim about a *contract you may not
have*. A privacy claim built on Apple/Windows on-device APIs is a claim about *architecture*, and it is free.
Given that both platforms shipped this capability in their current OS versions, **the honest privacy claim and the
zero-COGS path are the same path.** That is an unusually clean strategic alignment and it should probably decide
the build.

---

## 9. Open gaps — what I could not verify and how to close it

Ranked by decision impact.

| # | Gap | Why it matters | How to close |
|---|---|---|---|
| 1 | **Deepgram MIP discount %** — Deepgram's own docs confirm discounted pricing for participants but **never state the percentage** | If it is 50%, Deepgram's privacy price is 2× the headline and it drops out of contention (§7.6) | Ask Deepgram in writing; get it in the order form |
| 2 | **Apple `SpeechTranscriber` language count** — Apple exposes `supportedLocales` only at **runtime**, publishes no list | Determines whether the free path serves non-English users; the "~30 locales" figure is third-party only | Run `SpeechTranscriber.supportedLocales` on a macOS 26 Mac and count |
| 3 | **TTFT for every cleanup LLM** — **no vendor publishes it** | It is the only metric that matters for the post-dictation spinner; price is already noise | Benchmark your real prompt against Groq / gpt-5-nano / Gemini Flash-Lite / Haiku 4.5 |
| 4 | **Azure AI Speech pricing** — the pricing page renders literal `$-` placeholders; *"prices are estimates only"* | Azure is uncosted in this brief. Free tier F0 = 5 audio-hr/month; commitment tiers at 2,000 / 10,000 / 50,000 hr/month exist | Azure pricing calculator (requires sign-in) or Azure sales |
| 5 | **Absolute WER for every cloud vendor** — none publish one | All cloud accuracy comparisons here are vendor-relative and not defensible | Benchmark in-house on your own dictation audio |
| 6 | **whisper.cpp measured RTF on M1–M4** | Sizing the local Mac path | `./build/bin/whisper-bench` on target hardware |
| 7 | **MLX local-LLM tok/s and TTFT** | Sizing a fully-local cleanup pass | `mlx_lm.benchmark`; repo has a `/benchmarks` folder |
| 8 | **Mistral Voxtral per-minute price** — pricing page says only *"speech models are priced per minute"* | Voxtral uncosted | Mistral Studio dashboard or API pricing docs |
| 9 | **Fireworks / Baseten audio pricing** — neither publishes a per-audio-minute rate | Both uncosted; Together does publish, and is cheap | Vendor sales |
| 10 | **Retention/DPA terms** for Speechmatics, Soniox, Gladia, Rev.ai, Together, Azure, Mistral | Any of these could move into or out of the "safe to claim privacy" bucket | Request each vendor's DPA |
| 11 | **Deepgram Flux latency** — the frequently-repeated "sub-300ms" figure does not appear on any Deepgram-owned page I fetched | Flux is sold on latency; the number should be contractual | Deepgram docs/sales |
| 12 | **ElevenLabs plan-tier vs per-unit price discrepancy** | Per-unit page says $0.22/hr, but plan tiers imply $0.66–$1.33/hr ($22 Creator → 27 hr; $99 Pro → 100 hr; $299 Scale → 450 hr). Non-monotonic — the bundled hours likely assume credits spent solely on STT | Clarify with ElevenLabs which rate applies to API-only usage |
| 13 | **Moonshine specs** — README gives license (MIT) and a marketing claim, no parameter counts or WER | Cannot size it | moonshine-voice.readthedocs.io |
| 14 | **Windows AI Speech languages / WER / backing model** | Sizing the free Windows path | Microsoft; Learn page publishes none |

---

## 10. Recommendation

1. **Build the on-device path first, on both platforms.** Apple `SpeechAnalyzer` (macOS 26+) and Windows AI Speech
   Recognition (Win 11 24H2+) are free, offline, streaming, first-party, and make the privacy claim true by
   construction rather than by contract. This is the product's moat and its margin at the same time.
2. **Carry one cloud fallback for older OSes and unsupported locales.** On current evidence: **Groq
   `whisper-large-v3-turbo` for batch** ($0.04/hr, 99.0% GM, 440 hr/mo break-even) and **Soniox `stt-rt-v5`
   or AssemblyAI Universal-Streaming for streaming** ($0.12–$0.15/hr) — *pending* their DPA terms (gap #10).
   Avoid AssemblyAI as the default-plan fallback if the privacy claim is public (§8).
3. **Do not optimize the cleanup LLM for cost.** Pick on TTFT and output quality; the whole decision is worth
   1.5% of one subscription. Benchmark TTFT yourself — nobody publishes it.
4. **Before signing any cloud contract, resolve gap #1** (Deepgram MIP discount) **and #10** (DPA terms). Those two
   determine whether the cloud fallback is cheap or whether privacy costs 2×.
5. **Model the free tier on the free funnel, not the paid user.** At 5% conversion, a Google-Chirp-class provider
   makes the free tier cost more than the subscription; a local or Groq-class provider makes it free.
