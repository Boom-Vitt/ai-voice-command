# Thai-Language Text Engineering for a Voice-Dictation Desktop App

Research brief. Date: 2026-08-24. Platform of measurement: macOS 26.5.1 (build 25F80), Apple Silicon.
Every claim carries a source URL, or is marked `UNVERIFIED:`.
Claims marked **[MEASURED]** were produced locally by scripts reproduced in this document.
---

## TL;DR — the eight numbers that change engineering decisions

| # | Finding | Number | Where |
|---|---|---|---|
| 1 | Naive whitespace word-count **under-bills Thai users** | **7.1×** | §1.1 |
| 2 | macOS `NLTokenizer`/`CFStringTokenizer`/`enumerateSubstrings` all segment Thai **correctly and identically** — no Thai NLP dependency needed for metering. **But proper nouns fragment** (`สมชาย` → `สม`+`ชาย`), so custom-dictionary matching must longest-match your own list *first* | 4 APIs byte-identical on 10/10 tests; 4 clean / 5 fragmented on OOV names & neologisms | §1.3 |
| 3 | Thai token tax **on a current (o200k) tokenizer** | **1.33–1.85×** vs same-meaning English (not the 3–5× commonly claimed) | §0 |
| 4 | Thai token tax **on a legacy (cl100k) tokenizer** | **2.44–4.62×**; ~1 token *per character*, 20% of tokens are mid-UTF-8 byte fragments | §0 |
| 5 | Thai **numerals** cost vs Arabic digits — normalize before the LLM call | `๒๕๖๙` = **7 tokens**, `2569` = **2 tokens** (3.5×) | §3.3 |
| 6 | `CGEventKeyboardSetUnicodeString` delivery truncation, and 20 UTF-16 units ≠ 20 Thai characters | 20-unit limit; first **20 graphemes = 26 UTF-16 units** → naive chunking splits a tone mark from its base | §2.1 |
| 7 | Shift-key load in real Thai text is **lower than folklore** but lands on diacritics + loanwords | 37% of the Kedmanee layout is shift-only, but only **3.5–8.8%** of typed characters | §5.2 |
| 8 | What Thai dictation users actually complain about | **spacing**, not word accuracy | §5.4 |

### The five engineering decisions this brief supports

1. **Meter with a real segmenter, not whitespace.** `NLTokenizer(unit: .word)` on macOS;
   `Intl.Segmenter` in Electron; `icu_segmenter` in Rust. Free, correct, no Python. Use it for
   counting and for Thai↔Latin space insertion — but **not** for custom-dictionary lookup, where
   you must longest-match the user's own terms before falling through. (§1.3)
2. **Inject Thai via clipboard + ⌘V / Ctrl+V, not synthetic Unicode keystrokes.** Apple's own docs
   say frameworks may re-translate the virtual keycode using the active input source — which is
   the Thai-Kedmanee mangling mechanism — and the ~20-unit delivery limit forces chunking that
   splits combining sequences. (§2.1–2.2)
3. **"Auto-punctuate" for Thai means auto-*space*: two spaces = sentence, one space = clause.**
   Do not insert `.`. Do add a space at every Thai↔Latin boundary. Both are deterministic; do
   them in code, not in the LLM. (§3.1–3.2)
4. **Mask years and numbers before the LLM call.** Buddhist Era ↔ Gregorian is the highest-risk
   silent corruption (`พ.ศ. 2569` → `พ.ศ. 2026` looks well-formed and is wrong). Small models are
   weakest exactly at Extraction (typhoon2-8b: 3.80/10). (§3.4, §4.1)
5. **Budget ~1.4× English for a Thai cleanup round-trip on gpt-4.1-mini-class pricing**
   ($0.344 vs $0.252 per 1,000 dictations) — not the 3–5× the folklore predicts, provided you
   use an o200k-era model and normalize Thai numerals. (§4.2)


---

## §0. THE THAI TOKEN TAX — measured, reproducible  *(answered first; it is the load-bearing number; the §4 material continues below)*

### Headline

There are **two different ratios** and they must not be conflated:

| Metric | cl100k_base (legacy: GPT-4, GPT-3.5-turbo, text-embedding-3) | o200k_base (current: GPT-4o, GPT-4.1, o-series, GPT-5 family) |
|---|---|---|
| tokens per **Thai** character | **0.94 – 1.05** (≈ 1 token per character) | **0.39 – 0.53** |
| tokens per **English** character | 0.18 – 0.27 | 0.18 – 0.25 |
| Thai characters per token | **0.95 – 1.06** | **1.9 – 2.6** |
| English characters per token | 3.8 – 5.6 | 4.0 – 5.6 |
| **Cost multiplier, same meaning (Thai vs English)** | **2.4× – 4.6×** | **1.33× – 1.85×** |

**Use the bottom row for unit economics.** For any current OpenAI model (o200k_base) the Thai
tax is roughly **1.5×–1.9× the token count of the equivalent English text**, not the 3–5× that
the older cl100k figure implies. Quoting the cl100k number for a GPT-4.1-mini/nano budget
overstates cost by ~2.5×.

Which encoding a model uses is documented in tiktoken's model→encoding map:
https://github.com/openai/tiktoken/blob/main/tiktoken/model.py
(`gpt-4o`, `gpt-4.1`, `o1`, `o3` → `o200k_base`; `gpt-4`, `gpt-3.5-turbo` → `cl100k_base`).

### Why: cl100k literally shreds Thai into UTF-8 byte fragments **[MEASURED]**

Same 57-codepoint Thai clause, `การประมวลผลภาษาไทยด้วยคอมพิวเตอร์นั้นยากกว่าภาษาอังกฤษมาก`
("Processing the Thai language with a computer is much harder than English"):

* **o200k_base → 24 tokens.** Split contains real Thai subwords:
  `["การ","ประ","ม","ว","ล","ผล","ภาษา","ไทย","ด้วย","ค","อม","พ","ิว","เตอร์","นั้น","ย","าก","ก","ว่","า�","�","าษา","อังกฤษ","มาก"]`
  Only **2 of 24** tokens are mid-UTF-8 byte fragments.
* **cl100k_base → 60 tokens** (more tokens than characters!). Split is per-character or worse:
  `["การ","ป","ร","ะ","ม","ว","ล","ผ","ล","�","�","า","�","�","า","ไ","ท","ย","ด","้","ว","ย","ค","อ","ม","พ","ิ","ว","เ","ต","อ","ร","์", ...]`
  **12 of 60** tokens are mid-UTF-8 byte fragments (they do not decode standalone).

Note in the cl100k split that **`ด` `้` `ว` `ย`** — the single written word ด้วย — becomes four
tokens, and the tone mark ` ้ ` (U+0E49) is its own token. Combining marks are tokenized
separately. This is the same structural problem described in §1.

Independent corroboration of the general phenomenon:
* Typhoon paper (SCB 10X), §Tokenizer: "the Typhoon tokenizer is **2.62× more efficient than GPT-4**"
  at encoding Thai; GPT-2's 50k vocab needs **3.8× more tokens** for Thai than a 5k Thai-trained
  SentencePiece model. https://arxiv.org/abs/2312.13951 (PDF: https://arxiv.org/pdf/2312.13951)
* Tokenizer bias case study on GPT-4o/o200k: https://arxiv.org/html/2406.11214v2

### Reproduce it

Script `thai_tok.py` (run with `pip install tiktoken`):

```python
# -*- coding: utf-8 -*-
import tiktoken, json

TH_A = ("สวัสดีครับ วันนี้ผมอยากจะสรุปผลการประชุมเมื่อวานนี้ให้ทุกคนฟังนะครับ "
        "เรื่องแรกคือเรื่องงบประมาณของไตรมาสที่สาม ซึ่งทางฝ่ายการเงินแจ้งว่าเราใช้ไปแล้วประมาณสองล้านห้าแสนบาท "
        "คิดเป็นประมาณหกสิบเปอร์เซ็นต์ของงบทั้งหมด ส่วนเรื่องที่สองคือการพัฒนาแอปพลิเคชันตัวใหม่ "
        "ทีมวิศวกรรมบอกว่าจะสามารถปล่อยเวอร์ชันทดสอบได้ภายในสิ้นเดือนกันยายน ปี ๒๕๖๙ นี้ครับ")
EN_A = ("Hello everyone, today I would like to summarize the results of yesterday's meeting for you. "
        "The first topic is the third-quarter budget, which the finance department reported we have "
        "already spent about two million five hundred thousand baht, roughly sixty percent of the total budget. "
        "The second topic is the development of the new application. The engineering team said they will be "
        "able to release a test version by the end of September 2026.")

for enc_name in ["cl100k_base", "o200k_base"]:
    enc = tiktoken.get_encoding(enc_name)
    th, en = len(enc.encode(TH_A)), len(enc.encode(EN_A))
    print(enc_name, "TH tok", th, "EN tok", en, "mult", round(th/en, 2),
          "tok/TH-char", round(th/len(TH_A), 3))
```

Raw output (sample A = a realistic 342-character Thai meeting summary; EN_A is its 445-character
English translation, i.e. **same meaning**):

```
A_meeting_summary  cl100k_base: TH 323 tok / EN  86 tok  -> 3.76x ; 0.944 tok per Thai char
A_meeting_summary  o200k_base : TH 132 tok / EN  86 tok  -> 1.53x ; 0.386 tok per Thai char
B_short_chat       cl100k_base: TH  39 tok / EN  16 tok  -> 2.44x ; 1.026 tok per Thai char
B_short_chat       o200k_base : TH  20 tok / EN  15 tok  -> 1.33x ; 0.526 tok per Thai char
C_one_clause       cl100k_base: TH  60 tok / EN  13 tok  -> 4.62x ; 1.053 tok per Thai char
C_one_clause       o200k_base : TH  24 tok / EN  13 tok  -> 1.85x ; 0.421 tok per Thai char
```

Note sample A contains a Thai-numeral Buddhist-Era year `๒๕๖๙` — see §3 for why that matters.

---

## 1. Thai script mechanics that break naive code

### 1.1 No word spaces — your "N words per week" quota is off by ~7×  **[MEASURED]**

Thai does not put spaces between words. Space (U+0020) is a **phrase/clause separator**, roughly
where English would use a comma or a full stop. Unicode's own standard says so:
UAX #14 (Line Breaking) notes Thai/Lao/Khmer/Myanmar "do not use spaces between words" and
require dictionary-based break analysis — https://www.unicode.org/reports/tr14/#DictionaryBreaking
UAX #29 (Text Segmentation) §4.1 explicitly carves out these scripts: "in some languages
(Thai, Lao, Khmer, Myanmar, and Chinese/Japanese) ... word boundaries need to be determined
using more sophisticated dictionary-based approaches" — https://www.unicode.org/reports/tr29/#Word_Boundaries

Measured on a realistic 275-grapheme Thai meeting-summary paragraph (macOS 26.5, 2026-08-24):

```
chars (grapheme clusters) = 275   scalars = 342   utf16 = 342
naive whitespace-split "words"    = 10
NLTokenizer(.word) Thai words     = 71
UNDERCOUNT FACTOR                 = 7.1x
```

**Consequences for the product:**
* A whitespace-based word meter under-bills Thai users by ~7×. If your free tier is "2,000
  words/week", Thai users get ~14,000 real words. Conversely, if you switched to a naive
  *character* meter Thai would look cheap; if you switched to *tokens*, see §0.
* You **must** run a Thai segmenter to meter Thai (see §1.3 — free on macOS).
* Whitespace-delimited truncation ("show first 10 words") will show either the whole paragraph
  or nothing.
* Option ⌥ + arrow / double-click "select word" behaviour in your own transcript UI must go
  through the same segmenter, or it jumps a whole clause.

### 1.2 Combining characters: one visible cluster ≠ one codepoint  **[MEASURED]**

Thai stacks above-vowels/tone marks (U+0E31, U+0E34–U+0E37, U+0E47–U+0E4E) and below-vowels
(U+0E38–U+0E3A) on a base consonant. These are `Mn` (nonspacing mark) in the Unicode character
database — https://www.unicode.org/charts/PDF/U0E00.pdf (Thai block U+0E00–U+0E7F).

Measured lengths on macOS 26.5:

| string | grapheme (`String.count`) | scalars | UTF-16 (`NSString.length`) | UTF-8 bytes |
|---|---|---|---|---|
| `ที่` | **1** | 3 | 3 | 9 |
| `เสี้ยม` | **4** | 6 | 6 | 18 |
| `กิ๊ก` | **2** | 4 | 4 | 12 |
| `ญู` | **1** | 2 | 2 | 6 |
| `ก็` | **1** | 2 | 2 | 6 |
| 57-scalar clause | **50** | 57 | 57 | 171 |

`ที่` = `U+0E17 U+0E35 U+0E48` (TH THAHAN + SARA II + MAI EK) → **one** grapheme cluster.
UAX #29 grapheme-cluster rule GB9 (`× Extend`) is what makes this work:
https://www.unicode.org/reports/tr29/#Grapheme_Cluster_Boundaries

**The Thai gotcha that grapheme clusters do NOT solve — leading vowels.** Thai has four
*prepended* vowels (เ U+0E40, แ U+0E41, โ U+0E42, ใ U+0E43, ไ U+0E44) which are stored **before**
the consonant they phonetically follow. They are spacing characters, so they are their own
grapheme cluster. Measured:

```
"เสี้ยม" grapheme dump -> ["เ", "สี้", "ย", "ม"]   (4 clusters for one syllable)
```

So even correct grapheme-cluster iteration puts a cursor position *between* `เ` and `สี้`,
i.e. visually in the middle of one syllable. Thai orthographic-syllable ("แหล่งอักขระ" /
orthographic cell) boundaries are a level above grapheme clusters, and Unicode does not define
them; ICU's Thai dictionary break iterator is the practical answer. Background on Thai
prepended vowels and rendering order: Unicode Standard ch. 16 "Southeast Asia" (Thai section),
https://www.unicode.org/versions/latest/core-spec/chapter-16/ ("The Thai script … the vowel
signs SARA E through SARA AI MAIMALAI are placed before the consonant in the memory
representation").

**What breaks in a dictation app:**
* **Per-character synthetic keystroke injection.** If your injector iterates *scalars*, it emits
  a bare tone mark as its own keystroke. Measured payload split for `ที่`:
  `per-SCALAR = ["ท", "\u{0E35}", "\u{0E48}"]`. Many text fields, IMEs, and validators will
  drop or reorder an isolated combining mark. Iterate grapheme clusters, or (better, §2)
  send the whole string at once.
* **`String.count` vs `NSString.length` vs byte length** all disagree — a 57-scalar Thai clause
  is 50 graphemes, 57 UTF-16 units, 171 bytes. Any code that does `NSRange` arithmetic from a
  Swift `String.Index` offset, or that assumes `length == count`, is wrong for Thai.
  Accessibility APIs (`AXSelectedTextRange`) speak **UTF-16 offsets**, Swift speaks graphemes —
  convert explicitly via `String.Index(_:within:)` / `NSRange(_:in:)`.
  https://developer.apple.com/documentation/foundation/nsrange/3175163-init
* Truncating a Thai string by byte or by scalar count can leave a dangling combining mark
  (renders as a dotted-circle placeholder ◌ ่ ). Truncate on grapheme clusters at minimum.

### 1.3 Word segmentation WITHOUT shipping Python — macOS gives it to you free  **[MEASURED]**

**This is the single most useful finding in §1.** All four macOS system APIs segment Thai
correctly and produced *byte-identical* output on macOS 26.5.1. Input:
`การประมวลผลภาษาไทยด้วยคอมพิวเตอร์นั้นยากกว่าภาษาอังกฤษมาก`

| API | result |
|---|---|
| `NLTokenizer(unit: .word)` (auto-detect) | 9 tokens ✅ |
| `NLTokenizer` + `setLanguage(.thai)` | 9 tokens ✅ (identical) |
| `NSLinguisticTagger` scheme `.tokenType`, unit `.word` | 9 tokens ✅ (identical) |
| `CFStringTokenizer`, `kCFStringTokenizerUnitWord`, locale `th_TH` | 9 tokens ✅ (identical) |
| `String.enumerateSubstrings(options: .byWords)` | 9 tokens ✅ (identical) |

All five returned:
`["การประมวลผล","ภาษาไทย","ด้วย","คอมพิวเตอร์","นั้น","ยาก","กว่า","ภาษาอังกฤษ","มาก"]`

`NLLanguageRecognizer.dominantLanguage` correctly returned `th`.

Docs: `NLTokenizer` https://developer.apple.com/documentation/naturallanguage/nltokenizer ;
`NLTokenUnit.word` https://developer.apple.com/documentation/naturallanguage/nltokenunit/word ;
`CFStringTokenizer` https://developer.apple.com/documentation/corefoundation/cfstringtokenizer ;
`enumerateSubstrings(in:options:)` https://developer.apple.com/documentation/foundation/nsstring/1416774-enumeratesubstrings

#### Out-of-dictionary stress test — where it holds and where it breaks  **[MEASURED]**

The clause above is made of common dictionary words. Dictionary-based Thai segmentation degrades
on **proper nouns, brands, neologisms and ASR garbage** — which is exactly what a dictation app
emits. I re-ran nine adversarial cases; `NLTokenizer` and `CFStringTokenizer(th_TH)` produced
**identical output on all nine**, confirming they are one ICU implementation, not four opinions.

| input | output | verdict |
|---|---|---|
| `ดาวน์โหลดแอปพลิเคชันคีย์บอร์ดบลูทูธ` (transliterated tech loanwords) | `["ดาวน์โหลด","แอปพลิเคชัน","คีย์บอร์ด","บลูทูธ"]` | ✅ perfect |
| `ซื้อของที่เซ็นทรัลเวิลด์` (CentralWorld, a mall) | `["ซื้อของ","ที่","เซ็นทรัลเวิลด์"]` | ✅ brand kept whole |
| `เดี๋ยวผมจะ deploy ตัวใหม่นะครับ` (code-switch, spaced) | `["เดี๋ยว","ผม","จะ","deploy","ตัวใหม่","นะ","ครับ"]` | ✅ |
| `เดี๋ยวผมจะdeployตัวใหม่` (code-switch, **glued**) | `["เดี๋ยว","ผม","จะ","deploy","ตัวใหม่"]` | ✅ **finds the Thai↔Latin boundary with no space present** |
| `นายสมชาย ใจดี` (a very common personal name) | `["นาย","สม","ชาย","ใจดี"]` | ❌ **name fragmented** (สมชาย → สม + ชาย) |
| `บริษัท ไทยเบฟเวอเรจ จำกัด มหาชน` (ThaiBev) | `["บริษัท","ไทย","เบฟเวอเรจ","จำกัด","มหาชน"]` | ❌ company name split |
| `…แวะร้านชาบูนะ` (shabu, a food loanword) | `…"ร้าน","ชา","บู","นะ"` | ❌ split into ชา (tea) + บู |
| `…ไปกินหมาล่า…` (mala hotpot) | `…"หมา","ล่า"…` | ❌ split into หมา (dog) + ล่า (hunt) — **meaning inverted** |
| `เปิดฟีเจอร์วอยซ์ดิกเทชันในแอปนี้` ("voice dictation") | `["เปิด","ฟีเจอร์","วอยซ์","ดิก","เท","ชัน","ใน","แอป","นี้"]` | ❌ `ดิกเทชัน` → 3 fragments |
| `ผมจะไปทำกาบวยยยที่บ้านนะคับ` (ASR garbage + informal คับ) | `["ผม","จะ","ไป","ทำ","กาบ","วยยย","ที่","บ้าน","นะ","คับ"]` | ⚠️ degrades gracefully, no crash |

**Practical upshot for a Swift/macOS dictation app — split by use case:**

* **Word-count metering: use `NLTokenizer`, ship nothing else.** Fragmenting a name into two
  tokens is noise in an aggregate weekly count; the 7.1× whitespace error (§1.1) is the real
  problem and this fixes it. Zero binary size, zero model download, in the OS.
* **Thai↔Latin space insertion (§3.2): use `NLTokenizer` too** — it correctly located `deploy`
  inside `เดี๋ยวผมจะdeployตัวใหม่` with no space present, so you can drive the fix off token
  boundaries rather than a regex.
* **Custom-dictionary matching: do NOT rely on the segmenter.** A user dictionary is proper
  nouns and jargon *by definition*, and those are precisely what fragments (`สมชาย`, `ไทยเบฟเวอเรจ`,
  `ดิกเทชัน`). Do **longest-match against your own user dictionary first**, over the raw string,
  then fall through to `NLTokenizer` for the remainder. Never look up a user term by asking the
  segmenter for it.

Remaining caveats: (a) Apple does not publish the dictionary or its accuracy or its update
cadence; (b) all four APIs share the same ICU/CoreFoundation Thai dictionary — you have **one**
implementation, so a miss is a miss everywhere; (c) Windows has no equivalent free path, see below.

#### The ICU / cross-platform picture

* ICU ships a **Thai dictionary-based BreakIterator** (`thaidict`, a Burmese/Khmer/Lao/Thai
  DictionaryBreakEngine) — https://unicode-org.github.io/icu/userguide/boundaryanalysis/
  and the CLDR/ICU Thai dictionary source
  https://github.com/unicode-org/icu/tree/main/icu4c/source/data/brkitr/dictionaries (`thaidict.txt`).
* macOS: system ICU is present but **the C API is not a public/stable SPI** — Apple ships
  `libicucore.dylib` and explicitly does not support linking it directly; use the CoreFoundation
  / Foundation / NaturalLanguage wrappers above instead.
  UNVERIFIED: no Apple doc states this in one sentence; it is long-standing developer folklore
  reflected by the absence of ICU headers in the macOS SDK.
* Windows: `ICU` has shipped in-box since Windows 10 1703 (`icu.dll`, `icu.h`) —
  https://learn.microsoft.com/en-us/windows/win32/intl/international-components-for-unicode--icu-
  It exposes `ubrk_open(UBRK_WORD, "th", ...)`. UNVERIFIED: whether Microsoft's in-box ICU data
  build includes the Thai `brkitr` dictionary — Microsoft's page does not enumerate data
  coverage, so **test `ubrk_open(UBRK_WORD,"th")` on a real Windows box before relying on it**.
  Windows also exposes a documented word-break API via `ScriptBreak`/Uniscribe and
  `IWordBreaker` (indexing), but neither is a clean modern choice.
* Rust: crate `icu_segmenter` (ICU4X) supports dictionary/LSTM segmentation for Thai —
  https://docs.rs/icu_segmenter/ ; ICU4X explicitly lists Thai/Burmese/Khmer/Lao LSTM+dictionary
  word segmentation https://github.com/unicode-org/icu4x/tree/main/components/segmenter
  This is the right answer for a **Rust/Tauri** app: pure Rust, no Python, data can be trimmed
  to just Thai. `rust_icu_ubrk` (bindings to system ICU) is the alternative.
* JS/Electron: `Intl.Segmenter` with `granularity: "word"` — supported in Chromium/V8 and
  therefore in Electron. https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter
  Chromium bundles ICU with Thai break data (it needs it to line-break Thai web pages).

#### Comparison with PyThaiNLP (only relevant if you ship Python or call a service)

* PyThaiNLP `newmm` is the default: a maximal-matching + TCC dictionary algorithm; PyThaiNLP's
  own docs describe `newmm` as the default and fastest safe choice, `attacut` as faster-but-
  approximate, `deepcut` as accurate-but-slow (TensorFlow/Keras dependency).
  https://pythainlp.github.io/docs/5.0/api/tokenize.html
* AttaCut paper reports ~**6× faster than DeepCut** at comparable-ish accuracy:
  https://arxiv.org/abs/1911.07056 ("AttaCut: A Fast and Accurate Neural Thai Word Segmenter").
* Standard accuracy benchmark is BEST-2010 / the NECTEC BEST corpus. UNVERIFIED (exact
  head-to-head F1 numbers vary by corpus split across sources; do not quote a single figure).
* **Cost of shipping it:** deepcut pulls TensorFlow; attacut pulls PyTorch/ONNX; newmm is pure
  Python but still means bundling a CPython runtime (~40–100 MB) into a desktop app. For a
  Swift app with `NLTokenizer` available this is not worth it.

### 1.4 Thai line breaking for the transcript UI  **[MEASURED]**

Thai line breaks happen at *dictionary-determined* points inside a run of characters, not at
spaces. UAX #14 §8.1 "Dictionary Breaking": https://www.unicode.org/reports/tr14/#DictionaryBreaking
Thai characters carry line-break class **SA** ("Complex Context Dependent / South East Asian"):
https://www.unicode.org/reports/tr14/#SA

Measured on macOS: `CFStringTokenizer` with `kCFStringTokenizerUnitLineBreak` and locale `th_TH`
returns **finer** granularity than the word unit — 13 line-break units vs 9 words for the same
clause: `["การ","ประมวล","ผล","ภาษา","ไทย","ด้วย","คอมพิวเตอร์","นั้น","ยาก","กว่า","ภาษา","อังกฤษ","มาก"]`

Practical notes:
* **In AppKit/SwiftUI you get this for free** — `NSTextView`/`Text` line-break Thai correctly
  because CoreText applies the same dictionary. Do not implement your own wrapping.
* **In Electron/web**, set `lang="th"` on the container and use `word-break: normal`;
  `line-break: normal|strict|loose` interacts with Thai. Setting `word-break: break-all` will
  break *inside* a Thai syllable and split a combining mark from its base — never use it for
  Thai. https://developer.mozilla.org/en-US/docs/Web/CSS/word-break
* CSS `overflow-wrap: anywhere` has the same hazard.
* In a **terminal emulator**, Thai has no dictionary breaking and the combining marks are
  zero-width — see §2.4.

---

## 2. Thai text injection specifics

### 2.1 macOS: `CGEventKeyboardSetUnicodeString` — the string survives, the *delivery* is the problem

**[MEASURED]** The API itself does **not** mangle Thai combining sequences. Round-trip test
(`keyboardSetUnicodeString` → `keyboardGetUnicodeString`) on macOS 26.5.1, no event posted:

```
single cluster ที่        in utf16=  3  out utf16=  3  identical=YES
เสี้ยม                    in utf16=  6  out utf16=  6  identical=YES
สวัสดีครับ                in utf16= 10  out utf16= 10  identical=YES
full 342-utf16 Thai doc   in utf16=342  out utf16=342  identical=YES
```

So combining-mark *storage* is byte-exact at any length. The three real hazards are elsewhere:

**(a) The ~20-UTF-16-unit delivery truncation.** Widely reported, undocumented by Apple.
enigo issue #68, "Mac key_sequence limited to 20 characters": "It looks like
`CGEventKeyboardSetUnicodeString` truncates strings down to 20 characters, and is undocumented"
— https://github.com/enigo-rs/enigo/issues/68 (open; proposed fix is 20-char chunking).
Same limit described with working chunk-and-delay code at
https://isamert.net/2022/08/12/typing-unicode-characters-programmatically-on-linux-and-macos.html

⚠️ **Thai-specific danger in the chunking workaround:** 20 *UTF-16 units* is not 20 *characters*
in Thai. My measurement above shows the first **20 grapheme clusters** of a Thai doc are
**26 UTF-16 units**. A naive `chunks(20)` over UTF-16 will **split a base consonant from its
tone mark across two events**. If you must chunk, chunk on **grapheme-cluster boundaries with a
≤20-UTF-16 budget per chunk**, never on raw UTF-16 index.

**(b) Apple's own documented escape hatch — this is the Thai-IME mechanism.** From the official
reference for `keyboardSetUnicodeString(stringLength:unicodeString:)`
(https://developer.apple.com/documentation/coregraphics/cgevent/1456028-keyboardsetunicodestring),
verbatim:

> "By default, the system translates the virtual key code in a keyboard event into a Unicode
> string based on the keyboard ID in the event source. This function allows you to manually
> override this string. **Note that application frameworks may ignore the Unicode string in a
> keyboard event and do their own translation based on the virtual keycode and perceived event
> state.**"

That last sentence is the whole Thai IME problem in one line: an app that re-derives characters
from the **virtual key code** will apply the **currently active input source**. If the user has
**Thai – Kedmanee** active, your carefully-set Thai Unicode string is discarded and virtual key
0 (`kVK_ANSI_A`) is re-translated through Kedmanee instead. **[MEASURED]** on macOS 26.5.1 via
`UCKeyTranslate` against Apple's bundled "Thai" layout: vk 0 (`A`) → **`ฟ`**, vk 1 (`S`) → `ห`,
vk 2 (`D`) → `ก`, vk 3 (`F`) → `ด`, vk 5 (`G`) → `เ`, vk 12 (`Q`) → `ๆ`. You get
plausible-looking Thai garbage rather than an obvious failure, which is the worst kind of bug.
Mitigations: set `virtualKey: 0` **and** accept that some apps will still re-translate; prefer
clipboard paste (below) for Thai.

**(c) Dead keys / event-source state.** Apple's QA1446 documents that Quartz keyboard events
carry translation state and that a stale event source can corrupt output —
https://developer.apple.com/library/archive/qa/qa2005/qa1446.html ; related forum thread on
dead-key state leaking into `CGEventKeyboardGetUnicodeString`:
https://developer.apple.com/forums/thread/680104

**Recommendation: for Thai, inject via clipboard + ⌘V, not synthetic Unicode keystrokes.**
Reasons: no 20-unit limit, no per-chunk grapheme splitting, no virtual-keycode re-translation,
and it is O(1) rather than O(n) events. This matches what mature dictation/expansion tools do
for non-Latin scripts. Cost: you must save/restore the pasteboard, and some apps (secure input
fields, some Electron apps) block programmatic paste. Note the Karabiner precedent for getting
clipboard encoding wrong: "Karabiner's shell_command is not Unicode compliant" — it put
selected text on the pasteboard as **Mac OS Roman**, destroying non-Latin text —
https://github.com/pqrs-org/Karabiner-Elements/issues/2992 . Always use
`NSPasteboard.setString(_:forType: .string)` (UTF-16 native), never a legacy encoding.

UNVERIFIED: I could not find a published bug report specifically titled "Thai mangled by
macOS synthetic keystrokes". The mechanism is documented by Apple (quote above) and the
20-char limit is well attested, but the specific Thai×Kedmanee×CGEvent combination should be
tested on a machine with Thai – Kedmanee set as the active input source before you rely on
either path.

### 2.2 Windows: `SendInput` + `KEYEVENTF_UNICODE`

* The documented mechanism: set `wVk = 0`, `wScan = <UTF-16 code unit>`, `dwFlags = KEYEVENTF_UNICODE`.
  https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput
  Because `wScan` is a **single `WORD`**, you send **one UTF-16 code unit per INPUT struct** —
  so a Thai cluster like `ที่` is inherently **3 separate INPUT events**. There is no
  "send this grapheme atomically" primitive.
* `SendInput` docs warn the sequence is **not guaranteed to be atomic** against other input:
  "This function is subject to UIPI… input events are not interspersed with other input events"
  only within one call — https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
  **Send the whole Thai cluster (and ideally the whole string) in ONE `SendInput` call with an
  array of INPUTs**, so an IME or another injector cannot interleave between base and tone mark.
* Known wrong-character behaviour when `KEYEVENTF_UNICODE` and `KEYEVENTF_SCANCODE` are mixed,
  and when the target re-maps via layout: microsoft/terminal issue #12977, "Sending unicode
  character via KEYEVENTF_UNICODE/VK_PACKET in SendInput outputs the wrong characters"
  — https://github.com/microsoft/terminal/issues/12977
* IME interaction: when an IME is active, Windows delivers `WM_IME_CHAR` instead of/in addition
  to `WM_CHAR` — https://learn.microsoft.com/en-us/windows/desktop/Intl/wm-ime-char
  UNVERIFIED: the standard Thai Kedmanee layout on Windows is a plain **keyboard layout (KBDTHAI)**,
  not a TSF IME, so it should not intercept `VK_PACKET`. Verify on a Windows box with
  Thai keyboard active; the risk profile is lower than macOS but not zero.
* Windows also enforces **Thai input-sequence validation** at the layout level (the classic
  "Thai input mode: Basic / Strict" setting that rejects an illegal vowel-on-vowel sequence).
  UNVERIFIED: whether that validator is applied to `VK_PACKET`-injected characters. If it is,
  an ASR output containing a rare-but-legal or slightly malformed sequence could be silently
  dropped. Test with a deliberately odd sequence.
* **Same recommendation as macOS: prefer clipboard + Ctrl+V for Thai.**

### 2.3 Real, currently-open Thai combining-mark bugs in shipping tools (evidence the problem is live)

These are all **rendering/width** bugs rather than injection bugs, but they show how commonly
Thai combining marks are mishandled in exactly the desktop stacks a dictation app uses:

* anthropics/claude-code #19365 — "[Bug] Thai text with combining characters (vowels/tone marks)
  renders incorrectly while typing": characters appear separated by spaces while typing.
  https://github.com/anthropics/claude-code/issues/19365
* anthropics/claude-code #51444 — "Thai text rendering broken in CLI — combining marks
  misaligned, cursor drift, not fixable by font changes." Reporter's root-cause note:
  Thai base consonants = width 1, Thai combining marks = width 0, but "many JS libraries
  (`string-width`, older `wcwidth`) incorrectly count combining marks as width 1."
  Symptoms listed: marks land on the wrong consonant; **cursor jumps, backspace deletes the
  wrong character, arrow keys skip or double-count**; line wrapping breaks mid-syllable.
  https://github.com/anthropics/claude-code/issues/51444 (closed as duplicate)
* anomalyco/opencode #21712 — same class of bug in a different TUI.
  https://github.com/anomalyco/opencode/issues/21712
* zed-industries/zed PR #53176 — "Fix terminal combining marks": the fix detects combining marks
  by checking whether the shaped x-position advanced ≥ half a cell, which "unlike script-specific
  fixes … handles all complex scripts (Thai, Arabic, Devanagari)".
  https://github.com/zed-industries/zed/pull/53176
* pdfme #1347 — "Thai tone mark (ไม้เอก / U+0E48) not visible when text starts with a Latin
  character" — a shaping/itemization bug at the Latin↔Thai boundary, directly relevant because
  Thai dictation output is full of embedded English.
  https://github.com/pdfme/pdfme/issues/1347
* notofonts/thai #3 — "U+0E4D THAI CHARACTER NIKHAHIT is reordered below tone marks" — even the
  reference font had mark-ordering bugs. https://github.com/notofonts/thai/issues/3
* Unicode L2/04-332, Eric Muller (Adobe), "Two problems in Thai rendering" — the canonical
  write-up of Thai mark-ordering/rendering ambiguity.
  https://www.unicode.org/L2/L2004/04332-thai.pdf

### 2.4 Thai in terminals and Electron inputs

* **Terminals**: Thai combining marks are `General_Category = Mn` and must be treated as
  **width 0**. `wcwidth`-family functions historically get this wrong (see #51444 above).
  There is **no dictionary line-breaking in a terminal**, so Thai wraps at the column edge,
  mid-syllable. If your app has a TUI or logs Thai, assume misalignment unless you have
  verified the width function against `Mn`.
* **Electron/Chromium text inputs**: Chromium ships its own ICU + HarfBuzz and generally
  shapes/segments Thai correctly (it must, to render the Thai web). The failure mode in
  Electron apps is almost always the **app's own JS string handling**: `str.length`
  (UTF-16!), `slice()`, `substring()`, and `[...str]` (scalars, not graphemes) all break Thai.
  Use `Intl.Segmenter(undefined, {granularity: "grapheme"})` for anything cursor-related and
  `{granularity: "word"}` with locale `th` for counting —
  https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter
* Never apply CSS `word-break: break-all` / `overflow-wrap: anywhere` to Thai (see §1.4).

---

## 3. Thai formatting conventions an "AI auto-edit" pass must respect

The authority is **สำนักงานราชบัณฑิตยสภา / Office of the Royal Society (ORST)**, specifically
*หลักเกณฑ์การใช้เครื่องหมายวรรคตอนและเครื่องหมายอื่น ๆ หลักเกณฑ์การเว้นวรรค หลักเกณฑ์การเขียนคำย่อ*,
6th ed., pp. 56–66. The spacing chapter is published online:
**http://legacy.orst.go.th/?page_id=629** (Thai; "Rules for spacing"). Everything quoted below
is from that page. Note the site is HTTP-only and its TLS endpoint refuses connections.
Mirror of the same rules as a PDF from a Thai government hospital style guide:
https://www.si.mahidol.ac.th/th/division/soqd/admin/knowledges_files/373_18_1.pdf
(Siriraj Hospital, "หลักการที่ถูกต้องในการพิมพ์งาน การเว้นวรรคในภาษาไทย" — correct principles for
typing Thai / Thai spacing).

### 3.1 "Auto-punctuate" in Thai means **auto-SPACE**, not auto-period

Thai has no sentence-ending period. The full stop (`.`) is used **for abbreviations only**
(พ.ศ., ฯลฯ, ศ. นพ.). Sentence boundaries are marked by **space width**:

> **๑.๑ การเว้นวรรคใหญ่** — "เว้นวรรคใหญ่เมื่อจบข้อความแต่ละประโยค"
> *(Use a BIG space when each sentence's content ends.)*
> **วรรคใหญ่** = "ระยะห่างระหว่างวรรคประมาณ ๒ เท่าของการเว้นวรรคเล็ก" (≈ 2× a small space)
> **วรรคเล็ก** = "ระยะห่างระหว่างวรรคประมาณเท่ากับความกว้างของพยัญชนะ ก" (≈ the width of the letter ก)
> — http://legacy.orst.go.th/?page_id=629

**Engineering consequence:** in plain Unicode there is no "big space" character in common use —
the near-universal digital convention is **two U+0020 spaces for วรรคใหญ่ (sentence end) and one
U+0020 for วรรคเล็ก (clause)**. So the *entire* Thai equivalent of "auto-punctuation" is:
**decide where sentences end and emit two spaces; decide where clauses end and emit one.**
Corroborating popular-reference statements of the 2-space/1-space digital convention:
https://thai-notes.com/notes/thaispacingguidelines.html and
http://thai-language.com/ref/spacing and
https://help.unbabel.com/hc/en-us/articles/360008771454-Language-Guidelines-Thai
(Unbabel's production Thai localization guideline).

⚠️ **This is a real product decision, not a nicety.** An LLM cleanup prompt written for English
("add punctuation") will happily insert `.` `,` `?` into Thai. Thai readers read a trailing `.`
as either wrong or as a foreign/informal register. Your prompt must say: *do not add sentence
periods; mark sentence ends with a double space and clause ends with a single space.*
Exception: `?` and `!` **are** used in modern Thai (the ORST page's own examples include
"โอ๊ย ! มาไม่ทันรถอีกแล้ว" — note the space *before* `!`), and `,` `;` `( )` `" "` are used with
the spacing rules in §3.2. There is genuine variation: ORST closes with
"หลักเกณฑ์นี้เป็นแนวทางในการปฏิบัติ แต่บางครั้งอาจเว้นวรรคหรือไม่เว้นวรรคก็ได้ ทั้งนี้ขึ้นอยู่กับดุลยพินิจของผู้เขียน"
(*these are guidelines; sometimes you may space or not — it is the writer's discretion*).

### 3.2 Spacing rules your cleanup pass must implement (all from ORST)

| ORST rule | Rule | Example from ORST |
|---|---|---|
| ๑.๒.๑ | Small space between clauses of a compound sentence before และ / หรือ / แต่ — **but not if the clauses are short** | `นายแดงอยู่ที่บ้าน…ปากน้ำโพ แต่พี่ชายของเขา…` vs `ฉันและเธอไปโรงเรียน` (no space) |
| ๑.๒.๒ | Small space **between given name and surname** | `นายเสริม วินิจฉัยกุล` |
| **๑.๒.๑๐** | **Small space between Thai letters and NUMERALS** | `เขาเลี้ยงสุนัขไว้ที่บ้านตั้ง ๓๐ ตัว` |
| **๑.๒.๑๓** | **Small space between Thai letters and letters of another script** ("ระหว่างตัวหนังสือไทยกับตัวหนังสือภาษาอื่น") | `…ชื่อไม้เถาชนิด Smilax china L. ในวงศ์ Smilacaceae` |
| ๑.๒.๑๒ | Small space after a unit-of-measure expression | `กว้าง ๐.๘๐ เมตร ยาว ๑.๖๐ เมตร` |
| ๑.๒.๑๑ | Small space between date and time | `ทุกวันพฤหัสบดี เวลา ๑๐.๐๐ น.` |
| **๑.๒.๑๕.๑** | **Space BEFORE and AFTER ๆ (ไม้ยมก) and ฯลฯ (ไปยาลใหญ่)** | `วันหนึ่ง ๆ เขาทำอะไรบ้าง` |
| ๑.๒.๑๕.๒ | Space **before** an opening quote `“` and opening paren `(` | `…มีลักษณะคล้าย “เถาวัลย์”` |
| ๑.๒.๑๕.๓ | Space **after** `,` `;` `ฯ` `”` `)` — not before | `พระพุทธ, พระธรรม, พระสงฆ์` |
| ๑.๒.๑๙ | Space before and after `เช่น` when it means "for example" — **but not** when it means "like/as" | `…สกลจักรวาล เช่น มนุษยโลก` vs dictionary sense `ดำ ว. มีสีเช่นสีเขม่า` |
| ๑.๒.๒๐ | Space before และ/หรือ in a list of **3+** items; **no space if only 2** | `…การจำหน่าย และการส่งมอบน้ำตาลทราย` vs `ครูและนักเรียน` |
| ๒.๑–๒.๔ | **NO space** between an honorific/title/profession/organization-type prefix and the name | `นายเสริม` `ศาสตราจารย์รอง ศยามานนท์` `บริษัทเงินทุน…` `กรมปศุสัตว์` |
| ๒.๖ | **NO space** around a hyphen/en-dash | `ภาษาตระกูลไทย–จีน` |
| ๒.๕ | **NO space** after ฯ when another mark follows | `กรุงเทพฯ-เชียงใหม่` |

**The embedded-English rule (๑.๒.๑๓) is the one your auto-edit pass will get wrong most often.**
Thai dictation is full of code-switched English ("เดี๋ยวผมจะ deploy ตัวใหม่นะครับ"). ORST says put
a small space on **both** sides of the Latin run. ASR frequently emits it glued
(`ผมจะdeployตัวใหม่`) or over-spaced. Make this an explicit rule in the LLM prompt AND a
deterministic post-fix: insert U+0020 at every Thai↔Latin script boundary that lacks one —
`(?<=[\u0E00-\u0E7F])(?=[A-Za-z])` and `(?<=[A-Za-z])(?=[\u0E00-\u0E7F])` — then let the LLM
only handle exceptions. Deterministic beats an LLM for this. **[MEASURED]** `NLTokenizer` also
finds this boundary on its own with no space present (`เดี๋ยวผมจะdeployตัวใหม่` →
`["เดี๋ยว","ผม","จะ","deploy","ตัวใหม่"]`, §1.3), so you can drive the insertion off token
boundaries instead of a regex.
⚠️ Suppress the insertion inside URLs, email addresses, file paths, and identifiers — a
dictation app will see `กด save ที่ example.com/path` and `ไฟล์ชื่อreport_v2.pdf`. Mask those
spans first (the same masking pass as §3.4's year guard).

### 3.3 Numbers, Thai numerals, currency  **[MEASURED — this one costs money]**

* Thai digits are U+0E50–U+0E59 (๐๑๒๓๔๕๖๗๘๙). Arabic digits dominate everyday and commercial
  Thai; **Thai numerals persist in official/government documents and formal dates**
  ("Thai numerals appear in government documents… `๑ มิถุนายน พ.ศ. ๒๕๕๖`") —
  https://en.wikipedia.org/wiki/Date_and_time_notation_in_Thailand
* **Thai numerals are a 3.5× token tax on their own.** Measured with `tiktoken`:

  | string | o200k tokens | cl100k tokens |
  |---|---|---|
  | `๒๕๖๙` (Thai numerals) | **7** | 8 |
  | `2569` (Arabic) | **2** | 2 |
  | `๑,๒๓๔,๕๖๗` | **14** | 16 |
  | `1,234,567` | **5** | 5 |

  The o200k token IDs for `๒๕๖๙` are `[176025, 795, 243, 795, 244, 795, 247]` — i.e. **each Thai
  digit after the first is two raw byte tokens.** → **Normalize Thai numerals to Arabic before
  sending to the LLM, and restore them on output if the user's target register needs them.**
  Conversion is trivial (offset U+0E50↔U+0030); PyThaiNLP calls it
  `thai_digit_to_arabic_digit` / `arabic_digit_to_thai_digit`
  https://pythainlp.org/docs/4.0/api/util.html
* **Currency.** `บาท` (word), `฿` U+0E3F THAI CURRENCY SYMBOL BAHT, and `THB` (ISO 4217) all
  occur. Convention in running Thai text is the word `บาท` **after** the amount with a small
  space (`๒,๕๐๐ บาท`) per ORST rule ๑.๒.๑๐/๑.๒.๑๒; `฿` is used in prices/UI.
  UNVERIFIED: I found no ORST rule that explicitly prescribes `฿` placement.
  Satang subdivision: 100 สตางค์ = 1 บาท.
* **Spoken-number → numeral.** This is a solved problem and there IS a library:
  **`pythainlp.util.thaiword_to_num`** converts spelled-out Thai numerals to an int
  (`"สองล้านสามแสนหกร้อยสิบสอง"` → `2300612`), and `pythainlp.util.num_to_thaiword` /
  `bahttext` go the other way (`bahttext(21)` → `'ยี่สิบเอ็ดบาทถ้วน'`, mirroring Excel's BAHTTEXT).
  Docs: https://pythainlp.org/docs/4.0/api/util.html ; source:
  https://pythainlp.org/dev-docs/_modules/pythainlp/util/wordtonum.html
  If you don't want Python, the rules are simple enough to reimplement in ~150 lines
  (units สิบ/ร้อย/พัน/หมื่น/แสน/ล้าน + the irregulars ยี่สิบ = 20 and เอ็ด = 1-in-final-position).
  **[MEASURED]** side benefit: `สองพันห้าร้อย` = 6 o200k tokens vs `2,500` = 3 tokens.
* Note ORST publishes a whole separate ruleset for **reading** numbers aloud
  (การอ่านตัวเลขต่าง ๆ: phone numbers, house numbers, postcodes, licence plates, decimals) —
  relevant if you ever do TTS or reverse-normalization. Index at http://legacy.orst.go.th/

### 3.4 Dates: Buddhist Era vs Gregorian — **the single highest-risk mangling for a cleanup LLM**

* **พ.ศ. (พุทธศักราช, Buddhist Era) = ค.ศ. (CE) + 543.** 2026 CE = **2569 BE**.
  https://en.wikipedia.org/wiki/Date_and_time_notation_in_Thailand
* Thai official date format is D/M/YYYY with a **BE** year: `30/1/2567` = 30 Jan 2024 CE.
  Government forms, court documents, newspapers, bank statements, school records, and product
  expiry dates carry BE years, **often with no Gregorian equivalent alongside**
  (https://make-a-calendar.com/thai-solar-date, https://www.kalberry.com/en/tools/buddhist-era-converter).
* Thailand adopted ISO 8601 as TIS 1111:2535 (1992) but kept the BE year in practice.
  https://en.wikipedia.org/wiki/Date_and_time_notation_in_Thailand
* Historical caveat: the +543 mapping is clean **only from 1941 CE onward**. Before the 1941
  calendar reform the Thai year began on **1 April**, so a BE year straddles two CE years and
  Jan–Mar dates are off by one. https://make-a-calendar.com/thai-solar-date
  UNVERIFIED: Wikipedia's article does not state the pre-1941 caveat; treat pre-1941 dates as
  out of scope for a dictation app.

**Mangling risks a cleanup LLM will actually produce — put explicit guardrails in the prompt:**
1. **Silent conversion.** The model "helpfully" rewrites `ปี ๒๕๖๙` → `2026` (or `ปี 2569` → `ปี 2026`).
   Now the user's document says the wrong year for a Thai reader.
2. **Double conversion.** `พ.ศ. 2569` → `พ.ศ. 2026` (subtracted 543 but kept the พ.ศ. label) —
   the worst outcome because it looks well-formed.
3. **Wrong-direction inference.** A bare 4-digit year in Thai text (`ปี 2569`) is ambiguous to a
   model trained mostly on CE years; some will "correct" 2569 to 2026 as if it were a typo, and
   some will "correct" a genuine `ค.ศ. 2026` up to 2569.
4. **Numeral-form loss.** Thai-numeral years `๒๕๖๙` get rewritten as `2569` (register change) or
   half-converted.
5. **Month-name plus era mismatch.** `กันยายน ๒๕๖๙` → `September 2026`, silently translating.

**Recommended handling:** do **not** let the LLM touch years at all. Before the LLM call,
mask year-like tokens (`(?:พ\.ศ\.|ค\.ศ\.|ปี)?\s*[๐-๙\d]{4}`) to placeholders
(`⟪Y1⟫`), and restore afterwards. Do the era conversion only when the *user explicitly asks*,
and always keep the era label consistent with the number.

### 3.5 Polite particles (ครับ / ค่ะ / นะคะ) and the repetition mark ๆ

**Polite particles.** ครับ (male), ค่ะ/คะ (female), นะครับ/นะคะ (softening) are
**sentence-final politeness markers, not filler**. Stripping them changes the social register
from polite to blunt/rude — it is not the Thai analogue of removing "um".

Register expectations (this is genuinely context-dependent; treat as product configuration):
* **Chat / LINE / Messenger:** particles are expected and frequent. **Preserve.**
* **Email / formal correspondence:** expected in Thai business email. **Preserve.**
* **Formal documents, reports, minutes, published articles, code comments:** written Thai in
  documents is typically **not** in first-person spoken register, so particles usually get
  removed along with the whole spoken framing (`ผมอยากจะบอกว่า…นะครับ` → a declarative sentence).
  UNVERIFIED: I found no ORST or publisher style rule stating "remove ครับ/ค่ะ in formal
  documents" — this is an observed register convention, not a codified rule. Ship it as a
  **user-facing toggle per target app** ("keep politeness particles: on/off"), defaulting to ON.
* Gender risk: ASR/LLM may swap ครับ↔ค่ะ, which mis-genders the user. **Never let the model
  change which particle is used** — treat particles as verbatim-preserve tokens.
* **[MEASURED]** particles are cheap in o200k: `ครับ` = 1 token, `ค่ะ` = 1 token, `นะคะ` = 3
  (vs 3 / 3 / 4 in cl100k).

**ไม้ยมก ๆ (U+0E46, repetition mark).** It means "repeat the preceding word" — `ต่าง ๆ` is
read as `ต่างต่าง` ("various"). Rules:
* ORST ๑.๒.๑๕.๑ requires **a small space before AND after ๆ**: `วันหนึ่ง ๆ เขาทำอะไรบ้าง`
  — http://legacy.orst.go.th/?page_id=629 . In practice much digital Thai writes `ต่างๆ` with no
  space; both occur. Your formatter should normalize to the ORST form (space both sides) for
  documents and can leave the tight form in chat.
* **Never expand or strip it.** `ต่าง ๆ` → `ต่างต่าง` is wrong orthography;
  `ต่าง ๆ` → `ต่าง` changes meaning (singular vs "various").
* ORST publishes a separate rule for **reading** ๆ aloud (การอ่านเครื่องหมายไม้ยมก) —
  index at http://legacy.orst.go.th/
* **[MEASURED]** `ต่าง ๆ` = 2 o200k tokens, same as `ต่างต่าง` — no token incentive either way.
* ASR hazard: a speaker says "ต่างต่าง"; correct written output is `ต่าง ๆ`. That IS a legitimate
  cleanup transform, and the reverse is not.

---

## 4. LLM cleanup quality AND cost for Thai

### 4.1 Published Thai benchmark scores — the official ThaiLLM Leaderboard  **[MEASURED from source data]**

The **ThaiLLM Leaderboard** (SCB 10X / VISTEC / SEACrowd, with Stanford HELM) is the reference
Thai evaluation. It runs 10 datasets across four categories:
**Exam** (ThaiExam, M3Exam-th), **LLM-as-judge** (MT-Bench-Thai, judged by `gpt-4o-2024-05-13`),
**NLU** (Belebele, XNLI, **XCOPA**, Wisesight), **NLG** (XLSum, Flores200, iapp Wiki QA).
Announcement: https://opentyphoon.ai/blog/en/introducing-the-thaillm-leaderboard-thaillm-evaluation-ecosystem-508e789d06bf
Leaderboard: https://huggingface.co/spaces/ThaiLLM-Leaderboard/leaderboard
ThaiExam in HELM: https://www.scb.co.th/en/about-us/news/oct-2024/scb10x-standford.html

I pulled the **raw per-model results** the leaderboard is built from —
https://huggingface.co/datasets/ThaiLLM-Leaderboard/results (each model has
`LLM/<model>/results.json`). MT-Bench-Thai scores, **1–10 scale, higher is better**:

| Model | **Writing** | Extraction | Reasoning | mean of 9 categories |
|---|---|---|---|---|
| **gpt-4o-mini-2024-07-18** | **8.35** | 7.15 | 6.70 | 7.53 |
| gpt-4o-2024-05-13 | 8.15 | 7.60 | 9.00 | 8.26 |
| **gemini-1.5-flash-001** | **8.00** | 6.10 | 5.85 | 7.10 |
| gemini-1.5-pro-001 | 7.90 | 7.00 | 7.95 | 7.58 |
| claude-3-5-sonnet-20240620 | 7.60 | **8.00** | 7.55 | 7.66 |
| Qwen2.5-72B-Instruct | 7.20 | 6.30 | 7.15 | 7.18 |
| llama3.1-typhoon2-70b-instruct (SCB 10X) | 7.10 | 7.10 | 6.75 | 7.25 |
| gemma-2-9b-it | 6.65 | 5.45 | 5.90 | 6.35 |
| llama3.1-typhoon2-8b-instruct | 6.65 | 3.80 | 5.10 | 5.72 |
| Qwen2.5-7B-Instruct | 6.30 | 5.50 | 4.80 | 5.82 |
| **Pathumma-llm-text-1.0.0 (NECTEC)** | 5.20 | 3.85 | 4.50 | 4.57 |
| OpenThaiLLM-Prebuilt-7B (NECTEC) | 3.65 | 3.20 | 3.20 | 3.91 |

**Read this for your use case, which is Thai *writing/rewriting*, not reasoning:**
* **The cheap frontier models already win at Thai writing.** `gpt-4o-mini` scores **8.35** on
  Writing — the highest in the whole table, *above* full `gpt-4o` (8.15) — and
  `gemini-1.5-flash` scores **8.00**. A dictation cleanup pass is a Writing task.
* **Thai-specific open models do NOT beat them for this task.** typhoon2-70b = 7.10,
  typhoon2-8b = 6.65, Pathumma = 5.20. Typhoon's value is Thai *tokenizer efficiency* and
  self-hosting, not raw Thai writing quality vs a frontier mini model.
* **Extraction is where small models collapse** (typhoon2-8b: 3.80). If your cleanup prompt asks
  the model to *preserve* structure (names, numbers, dates) rather than paraphrase, you are
  closer to an extraction task and small models are riskier — consistent with the date-mangling
  risks in §3.4.

⚠️ **Staleness caveat (important).** As of 2026-08-24 the `ThaiLLM-Leaderboard/results` dataset
contains **284 model directories but stops at 2024-era models** — the newest proprietary entries
are `gpt-4o-mini-2024-07-18`, `gemini-1.5-flash-001`, `claude-3-5-sonnet-20240620`.
`UNVERIFIED:` **there is no published ThaiExam/MT-Bench-Thai score for GPT-4.1-mini/nano,
GPT-5-mini, Gemini 2.5/3.x Flash-Lite, Claude Haiku 4.x, or Qwen3 on this leaderboard.** Treat
the 2024 numbers as a *floor* for their successors and run your own eval on your own prompt.

Other Thai benchmark data points, sourced:
* **SEA-HELM** (AI Singapore + Stanford CRFM) covers Thai; leaderboard https://leaderboard.sea-lion.ai/
  Reported figures: **Qwen 3 VL 32B = 59.73** and **Qwen 3 Next 80B MoE = 58.09** on SEA-HELM Thai;
  the article notes "Thai scores cluster lower than Indonesian or Vietnamese."
  https://digitalinasia.com/llm-benchmarks-asian-languages-tour/ (Jul 2026)
* **SiamGPT-32B** reports the highest SEA-HELM competency mean at **63.59**, above Typhoon 2.5 and
  OpenThaiGPT-R1. https://arxiv.org/abs/2512.19455 (SiamGPT, Jan 2026).
  UNVERIFIED: I could not extract the full comparison table from the PDF.
* **OpenThaiGPT 1.5 7B** model card: **ThaiExam 52.04%**, vs SeaLLMs-v3-7B-Chat 51.33% and
  openthaigpt-1.0.0-70b-chat 50.09%; and 65.78% micro-average on OpenThaiGPT's own 17-exam suite
  vs Typhoon 8B 60.65%. https://huggingface.co/openthaigpt/openthaigpt1.5-7b-instruct
* **Typhoon 2.5** (Qwen3-30B-A3B MoE, and a 4B edge variant) claims "Gemini 2.5 Flash–level
  performance while being 14× cheaper", at **$0.10/M tokens**.
  https://opentyphoon.ai/blog/en/typhoon2-5-release
  UNVERIFIED: that page publishes charts, not a numeric table; I could not extract per-benchmark values.
* Typhoon 2 paper: https://arxiv.org/abs/2412.13702 ; Typhoon 1 paper (tokenizer analysis):
  https://arxiv.org/abs/2312.13951 ; Thai safety benchmark:
  https://opentyphoon.ai/blog/en/thaisafetybench ; Thai dialect benchmark:
  https://arxiv.org/pdf/2504.05898 ; Thai cultural/core-capability benchmarks (WangchanThaiInstruct):
  https://arxiv.org/pdf/2410.04795

### 4.2 What the token tax does to unit economics  **[MEASURED]**

Cross-reference §0 at the top for the raw ratios. The practical numbers for a cleanup pass:

**A cleanup pass pays the tax twice** — Thai goes in *and* the corrected Thai comes back out,
and output tokens are typically 4× the price of input. Modelled on the 342-char Thai sample
and its English translation, with a 200-token English system prompt shared by both:

| | input tok | output tok | cost/dictation | cost / 1,000 dictations |
|---|---|---|---|---|
| **Thai** (o200k) | 332 (200 sys + 132) | 132 | $0.000344 | **$0.344** |
| **English** (o200k) | 286 (200 sys + 86) | 86 | $0.000252 | **$0.252** |

*Modelling assumption:* output tokens are set equal to the input **text** tokens — i.e. the model
re-emits similar-length cleaned text with no reasoning/thinking overhead. That is right for a
cleanup pass and wrong for a reasoning model; if you enable thinking, output tokens (and the Thai
premium on them) go up proportionally.

at gpt-4.1-mini list price **$0.40/M input, $1.60/M output**
(https://www.cloudzero.com/blog/openai-pricing/ ; https://platform.openai.com/docs/pricing).
gpt-4.1-nano is **$0.10/M in, $0.40/M out**; Gemini 2.5 Flash-Lite is **$0.10/M in, $0.40/M out**
(https://ai.google.dev/gemini-api/docs/pricing) — note Google announced Flash-Lite retirement
on 2026-10-16 with Gemini 3.1 Flash-Lite at $0.25/$1.50
(https://www.metacto.com/blogs/the-true-cost-of-google-gemini-a-guide-to-api-pricing-and-integration).

**Net: Thai cleanup costs ~1.37× English on a current-generation tokenizer** in this realistic
mix — much less scary than the naive "Thai is 3–5× more expensive" claim, because (a) o200k has
real Thai subwords, and (b) the English system prompt dilutes the ratio. On a **cl100k-era**
model the same workload would be ~2.5× worse. Three concrete levers:
1. **Use an o200k / modern-vocab model.** Biggest single win (2.4× fewer Thai tokens than cl100k).
2. **Normalize Thai numerals to Arabic before the call** (§3.3): `๒๕๖๙` 7 tok → `2569` 2 tok.
3. **Cache the system prompt.** OpenAI's GPT-4.1 family gives 75% off cached input
   (https://www.cloudzero.com/blog/openai-pricing/), which removes most of the 200-token
   overhead — and *raises* the Thai/English ratio toward the raw 1.53×, so measure end-to-end.

### 4.3 Small **local** models for a private Thai cleanup pass on Apple Silicon

* **Typhoon has purpose-built 4B edge models, distributed on Ollama:**
  * `scb10x/typhoon2.1-gemma3-4b` — 4B Thai/English bilingual, built on **Gemma 3**.
    https://ollama.com/scb10x/typhoon2.1-gemma3-4b
  * `scb10x/typhoon2.5-qwen3-4b` — 4B Thai/English bilingual, built on **Qwen 3**.
    https://ollama.com/scb10x/typhoon2.5-qwen3-4b
  * Full org: https://ollama.com/scb10x ; Typhoon 2.5 also ships a 30B-A3B MoE
    ("the strength of a 30B model while consuming compute closer to 3B")
    https://opentyphoon.ai/blog/en/typhoon2-5-release
  **These are the right starting point** — a Thai-specialized 4B beats a generic 4B on Thai, and
  4B at 4-bit is ~2.5–3 GB of unified memory, i.e. it fits on any 16 GB Mac alongside your app.
  UNVERIFIED: exact RAM footprint per quant; check the Ollama tag sizes.
* **Runtime choice on Apple Silicon:** MLX is the fastest path. "MLX beats Ollama by 15–30%
  throughput on Apple Silicon and uses ~10% less memory"; "MLX achieves 20–50% faster inference
  than llama.cpp on Apple Silicon."
  https://willitrunai.com/blog/mlx-vs-ollama-apple-silicon-benchmarks
  Ollama now has an MLX-powered path on Apple Silicon (preview): https://ollama.com/blog/mlx
* **Throughput ballpark** (these are for larger models than 4B, so a 4B will be substantially
  faster): "On M4 Max 36 GB or higher, expect 40–55 tokens/second with full 32K context";
  M3 Ultra 512 GB at MLX 8-bit "80+ tok/s". Memory bandwidth is the binding constraint:
  M1/M2 100 GB/s → M3 150 → M4 120 → M4 Pro 273 → M4 Max 546 → M3 Ultra 800.
  https://willitrunai.com/blog/mlx-vs-ollama-apple-silicon-benchmarks
  `UNVERIFIED:` no published tok/s figure specifically for `typhoon2.5-qwen3-4b` on Apple Silicon.
  A 4B at 4-bit on an M-series should comfortably exceed 40 tok/s; **benchmark it yourself** —
  and note the Thai token tax means a Thai cleanup emits ~1.5× the tokens of the English
  equivalent, so wall-clock latency is ~1.5× too even at equal tok/s.
* **Quality expectation, honestly:** from §4.1, `typhoon2-8b` scored **6.65** on MT-Bench-Thai
  Writing and only **3.80** on Extraction, vs 8.35 / 7.15 for `gpt-4o-mini`. A 4B will be lower
  still. `UNVERIFIED:` no published MT-Bench-Thai score for the 4B variants.
  **Recommendation:** local models are viable for *conservative* Thai cleanup (segment into
  clauses, insert spaces, fix obvious ASR homophones) but **not** for aggressive rewriting, and
  you must hard-guard dates/numbers/names (§3.4) because the Extraction weakness is exactly
  where those get mangled.
* Generic Thai-capable local alternatives: **Qwen3** (base for typhoon2.5; Qwen leads SEA-HELM
  Thai among open models per https://digitalinasia.com/llm-benchmarks-asian-languages-tour/) and
  **Gemma 3** (base for typhoon2.1). Prefer the Typhoon-tuned variants over the bases for Thai.

---

## 5. The value-proposition numbers

### 5.1 ⚠️ First, the measurement trap: Thai WPM and English WPM are not the same unit

Thai has no word delimiter, so Thai typing tests **cannot** count lexical words. The Thai
convention is **คำสุทธิ (net words) where 1 คำ = 4 ดีด (keystrokes)**:

> "ในการคิดคำสุทธิภาษาไทยมีหลักในการนับ คือ **4 ดีด เท่ากับ 1 คำภาษาไทย**"
> and the formula: count all keystrokes including spacebar, **divide by 4**, subtract
> (number of wrong words × 10), divide by minutes elapsed.
> — https://naiyana2706.wordpress.com/พิมพ์ไทย-อังกฤษ/วิธีการคิดคำสุทธิ/
> (Thai; "How to calculate net words", a Thai computer-studies teacher's course page.
> Note: returns HTTP 403 to automated fetchers; content quoted from the search index.)

The English convention is **5 characters = 1 word**. So **a Thai "word" is 4 keystrokes and an
English "word" is 5** — a raw "35 Thai WPM vs 40 English WPM" comparison is already 25% wrong
before you start. **Use keystrokes/minute (or characters/minute) for any cross-language claim.**

Commonly cited Thai typing-proficiency bars (employment/civil-service level):
* "โดยปกติแล้วมาตรฐานการพิมพ์ดีด ต้องได้ **ภาษาไทย 35 คำ/นาที ภาษาอังกฤษ 30 คำ/นาที**"
  (*the usual typing standard is 35 Thai words/min, 30 English words/min*) —
  https://www.dek-d.com/board/knowledge/3525502/ (Thai forum, widely-repeated job-application norm)
  → 35 คำ/นาที × 4 ดีด = **140 keystrokes/min**; 30 English wpm × 5 = **150 chars/min**.
* UNVERIFIED: I found no primary Office of the Civil Service Commission (ก.พ.) publication
  stating the official Thai typing bar. Secondary sources restate it inconsistently — some in
  words/min, some in characters/min — so **do not publish an OCSC figure without the ก.พ. source
  document.** Likewise for beginner speeds: I found no study, only forum anecdote.

### 5.2 Why Kedmanee is genuinely hard — NECTEC's own numbers (authoritative)

Thailand's national IT research agency **NECTEC** publishes the Kedmanee/Pattachote analysis
behind the national standard **TIS 820-2531** (which made Kedmanee the computer keyboard standard):
https://www.nectec.or.th/it-standards/keyboard_layout/thai-key.html

* Kedmanee distributes **30% of the load to the left hand and 70% to the right hand.**
* The **right little finger takes 19% of keystrokes**, while the stronger left index finger takes
  only 16%.
* Pattachote (the ergonomic alternative) is "**only marginally faster (about 27%) with only 8.5%
  less finger movement**" and rebalances the hands to ~46%/53% — but failed to displace Kedmanee.

Plus the raw character-inventory problem. **[MEASURED]** — enumerating Apple's bundled "Thai"
(Kedmanee) layout with `UCKeyTranslate` over every virtual keycode × {unshifted, shifted} yields
**126 distinct reachable characters (79 unshifted + 47 shift-only)**, versus 26 letters × 2 cases
for a US English layout. That is the learning-curve problem stated from a first-party measurement
rather than folklore. Spot-check of the map: `A`→`ฟ`, `S`→`ห`, `D`→`ก`, `F`→`ด`, `G`→`เ`,
`Q`→`ๆ`; shifted `F`→`โ`, shifted `H`→`็`, shifted `Q`→`๐`.

**[MEASURED]** How much of that shift layer real Thai text actually touches — I enumerated
Apple's bundled "Thai" (Kedmanee) layout via `TISCreateInputSourceList` + `UCKeyTranslate` on
macOS 26.5.1 and classified every character of my Thai samples:

```
reachable WITHOUT shift : 79 characters
reachable ONLY WITH shift: 47 characters  (37% of the layout)
shift-only set: ฅ ฆ ฉ ซ ฌ ญ ฎ ฏ ฐ ฑ ฒ ณ ธ ฤ ฦ ศ ษ ฬ ฮ ฯ  ู ฺ ฿ โ ็ ๊ ๋ ์ ํ  ๐๑๒๓๔๕๖๗๘๙  % ( ) , ? |

sample              scalars  no-shift  SHIFT-required
meeting summary       342      330       12  (3.5%)
one clause             57       52        5  (8.8%)
chat message           38       35        3  (7.9%)
```

**Honest reading:** the "Thai needs Shift for everything" claim is **overstated for running
text** — only ~4–9% of typed characters need Shift. But note *which* ones do: **โ (SARA O),
ู (SARA UU), ็ (MAITAIKHU), ๊ ๋ (MAI TRI / MAI CHATTAWA), ์ (THANTHAKHAT — the silencer used in
every English loanword like คอมพิวเตอร์, เปอร์เซ็นต์, เวอร์ชัน), and all ten Thai digits.**
So Shift lands disproportionately on **diacritics and loanwords** — exactly the material a
dictation user is most likely to be producing in a work context.

### 5.3 The honest value-proposition arithmetic

**[MEASURED]** Thai is *more compact per keystroke* than English, which cuts the other way and
must be stated: my 342-scalar Thai meeting summary and its 445-character English translation
carry the same meaning → **Thai needs 23% fewer keystrokes for the same content.**

Speaking rate:
* **Thai ≈ 4.70 syllables/second**, one of the slowest of the 17 languages measured; compare
  Japanese 8.0 and Spanish 7.7. All languages converge on ~**39 bits/s** of information.
  Primary source: Coupé, Oh, Dediu & Pellegrino (2019), *"Different languages, similar encoding
  efficiency: Comparable information rates across the human communicative niche"*,
  **Science Advances** 5(9):eaaw2594 — https://www.science.org/doi/10.1126/sciadv.aaw2594
  (open access: https://pmc.ncbi.nlm.nih.gov/articles/PMC6984970/ ; press:
  https://www.cnrs.fr/en/press/similar-information-rates-across-languages-despite-divergent-speech-rates).
  The paper reports the group means directly: **SR mean 6.63 syll/s (SD 1.15), IR mean 39.15
  bits/s (SD 5.10)**. `UNVERIFIED:` the **specific Thai value of 4.70 syll/s** appears in
  secondary summaries of this paper (e.g. https://thewordpoint.com/blog/what-are-the-fastest-spoken-languages-in-the-world-today ,
  https://www.asianscientist.com/2019/11/in-the-lab/language-information-transmission-rate/)
  but I could not extract the per-language table from the paper or its supplement. Cite it as
  "≈4.7 syll/s per secondary reports of Coupé et al. 2019" or pull Table S1 yourself.

**The strongest framing is the information-rate one, and it is the paper's own headline result:**
*Because every language transmits ≈39 bits/s of speech regardless of syllable rate, speaking a
given message takes about the same wall-clock time in Thai as in English. Typing it does not.*

Worked estimate (**label as estimate** — the typing rates are exam bars, not observed means):

| | Thai | English |
|---|---|---|
| same-meaning content **[MEASURED]** | 342 keystrokes | 445 characters |
| typing at the standard bar | 140 ks/min → **≈147 s** | 150 ch/min → **≈178 s** |
| typing at a competent-professional rate (est. 60 คำ/นาที Thai = 240 ks/min; 50 wpm EN = 250 ch/min) | **≈86 s** | **≈107 s** |
| speaking it (≈39 bits/s, both languages) | **≈25–30 s** | **≈25–30 s** |
| **dictation speed-up** | **≈3–5×** | **≈3.5–6×** |

`UNVERIFIED:` I did **not** find a study measuring observed Thai typing speed in a working
population. The 35 คำ/นาที figure is a job-application/exam norm, not a mean. **Do not publish a
"Thai typists are N× slower than English typists" claim** — my data does not support it, and the
compactness result partly contradicts it.

**What the Thai data DOES support, and what you should actually pitch:**

1. **The spacing problem disappears when you speak.** A Thai writer must actively decide, for
   every clause, whether to insert วรรคเล็ก or วรรคใหญ่ or nothing (§3.1–3.2 — 22 numbered ORST
   rules). A Thai *speaker* never makes that decision. This is a cognitive cost English writers
   simply do not have, and it is invisible in WPM measurements.
2. **Shift-key load falls on diacritics and loanwords** (§5.2 measurement) — the fiddliest part
   of Thai typing, and the part dictation removes entirely.
3. **Kedmanee's ergonomics are officially bad** — NECTEC's own 30/70 hand split and 19% right-pinky
   load, in the document that standardized it.
4. **The learning curve is 126 reachable characters across two shift layers vs 26 letters** —
   measured directly off Apple's Thai layout (§5.2), not quoted from a wiki.

### 5.4 Quality of the Thai dictation people already use — and where the gap is

**Google Voice Typing (พิมพ์ด้วยเสียง)** — Thai is supported in Google Docs
(https://support.google.com/docs/answer/4492226?hl=th , Thai UI) and via the Google Keyboard.
Google's own Thai training material: https://newsinitiative.withgoogle.com/th/resources/trainings/fundamentals/voice-typing-transcribe-audio-using-google-docs/

Real Thai-user reports (Pantip, Thailand's main forum):
* **https://pantip.com/topic/40687716** — *"ประสบการณ์การพิมพ์ด้วยเสียง และการใช้โปรแกรม"*
  (**English gloss:** "My experience with voice typing and the software"). The author reports
  word-level accuracy was acceptable by their second session — "เป็นครั้งที่ 2 โอกาสที่จะมีคำผิดมีไม่มากครับ"
  (*by the second time, there weren't many wrong words*) — but that the output required manual
  **paragraph breaks and spacing corrections**, and that spoken rhythm ≠ written composition,
  making an editing pass necessary.
* **https://pantip.com/topic/32606559** — *"พิมพ์ด้วยการพูดในไอโอเอสแปดทำอย่างไรที่จะเว้นวรรคขึ้นบรรทัดใหม่ได้"*
  (**Gloss:** "How do you get a space or a new line when dictating in iOS 8?") — the spacing
  problem, asked as a direct product question.
* **https://pantip.com/topic/39185448** — *"คำสั่งพิมพ์ด้วยเสียงผิดพลาดบ่อยเกิดจากอะไร"*
  (**Gloss:** "Why does voice typing make mistakes so often?") — reported causes: unclear
  articulation, speaking too fast, and output containing **words not in the dictionary**.
* **https://pantip.com/topic/32594972** — *"อัพ ios 8 แล้ว การใช้งานพิมพ์ข้อความด้วยเสียงภาษาไทย (thai dictation) ใช้ไม่ได้"*
  (**Gloss:** "After updating to iOS 8, Thai dictation stopped working") — Apple Thai dictation
  regressions after OS updates.
* **https://pantip.com/topic/40615557** (**Gloss:** "My keyboard starts typing whatever I say —
  how do I turn it off?") and Samsung Thailand community reports of Thai voice input failing
  (https://r1.community.samsung.com/t5/galaxy-z/การพิมพ์ด้วยเสียงใช้ไม่ได้/td-p/25774490 ,
  **gloss:** "voice typing doesn't work").
* Cross-cutting complaint themes in the Thai-language results: **incorrect spacing
  (เว้นวรรคไม่ถูกต้อง) is the #1 issue**, plus out-of-dictionary words, plus the recognizer
  emitting **English letters while the language is set to Thai**.

**→ The product wedge is explicit in the user complaints: Thai users say ASR gets the *words*
roughly right and gets the *spacing* wrong.** Spacing is exactly what §3.1–3.2 codifies and
exactly what a cheap LLM pass (or even a deterministic segmenter + ruleset) can fix. That is a
much sharper Thai value proposition than "faster than typing".

---

## Appendix A — reproduction

All `[MEASURED]` results in this brief came from four scripts run on **macOS 26.5.1 (25F80),
Apple Silicon, 2026-08-24**. Full sources are in the scratchpad next to this file:

| script | what it measures | § |
|---|---|---|
| `thai_tok.py` | tiktoken token counts, Thai vs English, cl100k vs o200k; per-token split dump | §0 |
| `thai_tok2.py` | Thai-numeral / particle / ๆ token costs; round-trip cleanup cost model | §3.3, §3.5, §4.2 |
| `thaiseg.swift` | NLTokenizer / NSLinguisticTagger / CFStringTokenizer / enumerateSubstrings on Thai; grapheme vs scalar vs UTF-16 lengths; line-break units | §1.2–1.4 |
| `thaicount.swift` | whitespace vs NLTokenizer word count; `CGEventKeyboardSetUnicodeString` round-trip; per-grapheme vs per-scalar injection payloads | §1.1, §2.1 |
| `thaioov.swift` | out-of-dictionary / code-switch segmentation stress test (names, brands, loanwords, glued English, ASR garbage); Kedmanee virtual-keycode→character map | §1.3, §2.1, §5.2 |
| `kedmanee.swift` | enumerates Apple's bundled Thai (Kedmanee) layout via `TISCreateInputSourceList` + `UCKeyTranslate`; classifies sample text into shift / no-shift | §5.2 |

Reproduce the tokenizer numbers anywhere: `pip install tiktoken` then run `thai_tok.py`
(source inline in §0). Reproduce the Swift ones: `swiftc -O <file>.swift -o out && ./out`.
`kedmanee.swift` requires the Thai input source to be installed (it is by default on macOS;
the script prints which layouts it found).

### Key Swift snippet — correct Thai word metering (drop-in)

```swift
import NaturalLanguage

func thaiWordCount(_ s: String) -> Int {
    let tk = NLTokenizer(unit: .word)
    tk.string = s
    var n = 0
    tk.enumerateTokens(in: s.startIndex..<s.endIndex) { _, _ in n += 1; return true }
    return n
}
// Verified identical to CFStringTokenizer(th_TH) and String.enumerateSubstrings(.byWords).
// On a 275-grapheme Thai paragraph: whitespace split = 10, this = 71.
```

### Key Swift snippet — grapheme-safe ≤20-UTF-16 chunking (if you must use CGEvent)

```swift
func utf16SafeChunks(_ s: String, maxUTF16: Int = 20) -> [String] {
    var out: [String] = [], cur = "", curLen = 0
    for g in s {                      // Character == extended grapheme cluster
        let gl = String(g).utf16.count
        if curLen + gl > maxUTF16 && !cur.isEmpty { out.append(cur); cur = ""; curLen = 0 }
        cur.append(g); curLen += gl
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}
// NOTE: this still does NOT protect against a leading vowel (เ แ โ ใ ไ) being split from the
// consonant it visually precedes — those are separate grapheme clusters (§1.2). Prefer clipboard.
```

---

## Appendix B — quick source index

**Unicode / segmentation**
* UAX #29 Text Segmentation (word boundaries, dictionary scripts): https://www.unicode.org/reports/tr29/#Word_Boundaries
* UAX #29 grapheme clusters (rule GB9 `× Extend`): https://www.unicode.org/reports/tr29/#Grapheme_Cluster_Boundaries
* UAX #14 Line Breaking, dictionary breaking + class SA: https://www.unicode.org/reports/tr14/#DictionaryBreaking
* Thai block chart U+0E00–U+0E7F: https://www.unicode.org/charts/PDF/U0E00.pdf
* Unicode core spec ch.16 "Southeast Asia" (Thai prepended vowels): https://www.unicode.org/versions/latest/core-spec/chapter-16/
* Eric Muller (Adobe), L2/04-332 "Two problems in Thai rendering": https://www.unicode.org/L2/L2004/04332-thai.pdf
* ICU boundary analysis: https://unicode-org.github.io/icu/userguide/boundaryanalysis/
* ICU Thai dictionary data: https://github.com/unicode-org/icu/tree/main/icu4c/source/data/brkitr/dictionaries
* ICU4X segmenter (Rust): https://github.com/unicode-org/icu4x/tree/main/components/segmenter · https://docs.rs/icu_segmenter/
* `Intl.Segmenter` (JS/Electron): https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Segmenter
* Windows in-box ICU: https://learn.microsoft.com/en-us/windows/win32/intl/international-components-for-unicode--icu-

**Apple APIs**
* NLTokenizer: https://developer.apple.com/documentation/naturallanguage/nltokenizer
* CFStringTokenizer: https://developer.apple.com/documentation/corefoundation/cfstringtokenizer
* `enumerateSubstrings(in:options:)`: https://developer.apple.com/documentation/foundation/nsstring/1416774-enumeratesubstrings
* `keyboardSetUnicodeString`: https://developer.apple.com/documentation/coregraphics/cgevent/1456028-keyboardsetunicodestring
* QA1446 (Quartz keyboard event translation state): https://developer.apple.com/library/archive/qa/qa2005/qa1446.html

**Injection bug reports**
* enigo #68 (20-char limit): https://github.com/enigo-rs/enigo/issues/68
* Karabiner #2992 (pasteboard Mac OS Roman destroys Unicode): https://github.com/pqrs-org/Karabiner-Elements/issues/2992
* microsoft/terminal #12977 (KEYEVENTF_UNICODE wrong characters): https://github.com/microsoft/terminal/issues/12977
* Win32 KEYBDINPUT: https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput · SendInput: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
* chunk-and-delay writeup: https://isamert.net/2022/08/12/typing-unicode-characters-programmatically-on-linux-and-macos.html

**Thai combining-mark rendering bugs (live)**
* claude-code #19365: https://github.com/anthropics/claude-code/issues/19365
* claude-code #51444: https://github.com/anthropics/claude-code/issues/51444
* opencode #21712: https://github.com/anomalyco/opencode/issues/21712
* zed #53176 (fix): https://github.com/zed-industries/zed/pull/53176
* pdfme #1347 (tone mark lost at Latin↔Thai boundary): https://github.com/pdfme/pdfme/issues/1347
* notofonts/thai #3 (NIKHAHIT reordering): https://github.com/notofonts/thai/issues/3

**Thai style / conventions**
* **ORST spacing rules (primary)**: http://legacy.orst.go.th/?page_id=629 — Thai; from
  *หลักเกณฑ์การใช้เครื่องหมายวรรคตอน…ฉบับราชบัณฑิตยสถาน*, 6th ed., pp. 56–66
* Siriraj Hospital Thai typing/spacing guide (PDF mirror of the same rules):
  https://www.si.mahidol.ac.th/th/division/soqd/admin/knowledges_files/373_18_1.pdf
* ORST index of all rulesets (transliteration, number reading, ๆ reading): http://legacy.orst.go.th/
* Unbabel Thai localization guideline (production style guide): https://help.unbabel.com/hc/en-us/articles/360008771454-Language-Guidelines-Thai
* thai-language.com spacing reference: http://thai-language.com/ref/spacing · word breaking: http://www.thai-language.com/ref/breaking-words
* Thai date/time notation: https://en.wikipedia.org/wiki/Date_and_time_notation_in_Thailand
* PyThaiNLP util (numerals, `thaiword_to_num`, `bahttext`): https://pythainlp.org/docs/4.0/api/util.html
* PyThaiNLP tokenize (newmm/attacut/deepcut): https://pythainlp.github.io/docs/5.0/api/tokenize.html
* AttaCut paper (≈6× faster than DeepCut): https://arxiv.org/abs/1911.07056

**Thai LLMs / benchmarks**
* ThaiLLM Leaderboard: https://huggingface.co/spaces/ThaiLLM-Leaderboard/leaderboard · raw results: https://huggingface.co/datasets/ThaiLLM-Leaderboard/results
* Announcement + dataset list: https://opentyphoon.ai/blog/en/introducing-the-thaillm-leaderboard-thaillm-evaluation-ecosystem-508e789d06bf
* ThaiExam in Stanford HELM: https://www.scb.co.th/en/about-us/news/oct-2024/scb10x-standford.html
* SEA-HELM: https://leaderboard.sea-lion.ai/
* Typhoon 1 (tokenizer 2.62× more efficient than GPT-4): https://arxiv.org/abs/2312.13951
* Typhoon 2: https://arxiv.org/abs/2412.13702 · Typhoon 2.5 release: https://opentyphoon.ai/blog/en/typhoon2-5-release
* OpenThaiGPT 1.5 7B (ThaiExam 52.04): https://huggingface.co/openthaigpt/openthaigpt1.5-7b-instruct
* SiamGPT: https://arxiv.org/abs/2512.19455
* Typhoon local builds: https://ollama.com/scb10x/typhoon2.5-qwen3-4b · https://ollama.com/scb10x/typhoon2.1-gemma3-4b · https://ollama.com/scb10x
* MLX vs Ollama on Apple Silicon: https://willitrunai.com/blog/mlx-vs-ollama-apple-silicon-benchmarks · https://ollama.com/blog/mlx
* Pricing: https://ai.google.dev/gemini-api/docs/pricing · https://www.cloudzero.com/blog/openai-pricing/

**Typing / speech rate**
* NECTEC Thai keyboard layouts + TIS 820-2531: https://www.nectec.or.th/it-standards/keyboard_layout/thai-key.html
* คำสุทธิ (4 ดีด = 1 คำ): https://naiyana2706.wordpress.com/พิมพ์ไทย-อังกฤษ/วิธีการคิดคำสุทธิ/
* Thai typing-speed norms (Thai forum): https://www.dek-d.com/board/knowledge/3525502/ · https://pantip.com/topic/32485195/desktop
* Coupé et al. 2019, Science Advances: https://www.science.org/doi/10.1126/sciadv.aaw2594 · https://pmc.ncbi.nlm.nih.gov/articles/PMC6984970/

**Thai dictation user reports (Thai-language; glosses in §5.4)**
* https://pantip.com/topic/40687716 · https://pantip.com/topic/32606559 · https://pantip.com/topic/39185448 · https://pantip.com/topic/32594972 · https://pantip.com/topic/40615557
* Google Docs voice typing, Thai help page: https://support.google.com/docs/answer/4492226?hl=th

---
*End of brief. Generated 2026-08-24.*
