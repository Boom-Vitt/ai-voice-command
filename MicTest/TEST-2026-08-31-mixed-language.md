# Mixed Thai+English — measured, not assumed (2026-08-31)

Harness: mixtest.swift / biastest.swift. Offline SFSpeechURLRecognitionRequest on
`say -v Kanya` clips. No mic, no app launch, nothing typed into any window.

## Platform facts
- SFSpeechRecognizer: 63 locales, **zero multilingual**. Strictly monolingual.
- th-TH: available, onDevice=true.  en-US: available, onDevice=true.
  => a dual on-device recogniser is possible with no network.

## Control: pure Thai is perfect
  spoken: สวัสดีครับ วันนี้อากาศดีมากเลยนะครับ
  th-TH : สวัสดีครับวันนี้อากาศดีมากเลยนะครับ   ✓ exact

## The failure, by mode
| spoken | th-TH output | mode |
|---|---|---|
| commit     | เครือมี      | wrong Thai words — meaning destroyed |
| production | โปรดักชั่น   | transliterated into Thai script |
| browser    | บราวเซอร์    | transliterated into Thai script |
| deploy     | Diplo        | Latin, but wrong word |
| Google     | Google       | correct (common lexicon entry) |

## contextualStrings biasing: RULED OUT
Passing ["commit","deploy","production","browser","Google","code","push","branch"]
produced **byte-identical** output on all three clips. The th-TH model has no path
to emit these tokens. The cheap fix does not exist.

## en-US on the same audio — partial signal
  mix1 "commit"            -> "To clear Courtney no crap"      MISSED
  mix2 "deploy production" -> "Deploy production"              CAUGHT BOTH
  mix3 "browser Google"    -> "Browser by T Google I know"     CAUGHT BOTH
2 of 3. Useful as a repair signal, not reliable alone.

## CAVEAT, stated plainly
`say -v Kanya` is a THAI TTS engine reading English words. That is not the same as a
human Thai speaker code-switching, and it probably mangles the English harder than a
person would — so the en-US catch rate here is likely a FLOOR, not an estimate.
The th-TH transliteration failure is independent of this: it comes from the
recogniser's language model, and reproduces regardless of who is speaking.

## Second batch (6 more clips) — worse, and a new failure mode

| spoken | th-TH output |
|---|---|
| ช่วย review pull request ให้หน่อย | ช่วย**รไม่รู้ผล**รีเควสต์ให้หน่อย |
| ไฟล์นี้มี bug ต้อง debug ก่อน | ไฟล์นี้มี**บาส**ต้อง**ดี**ก่อน |
| ส่ง email ไปหา team แล้วนะ | ส่งอีเมลไปหาทีมแล้วนะ (loanwords — acceptable) |
| เปิด terminal แล้วรัน command นี้ | เปิดเทอร์มินัลแล้วรัน**คอร์มาร**นี้ |
| ผมใช้ Python กับ JavaScript | **พรชัยพีเทิร์น**กับ**จว่าสคริปต์** |
| save ไฟล์แล้ว restart server | เซฟไฟล์แล้ว**สตาร์ต**เซิร์ฟเวอร์ |

### NEW FAILURE MODE — English corrupts ADJACENT THAI
`ผมใช้ Python` -> `พรชัยพีเทิร์น`. The Thai words ผม+ใช้ ("I use") were consumed into
`พรชัย`, a person's name. The damage is not confined to the English span, so any fix
that assumes "Thai is fine, only patch the English" is wrong.

Meaning inversions seen: `debug` -> `ดี` ("good"); `restart` -> `สตาร์ต` ("start").

### en-US catch rate across all 9 clips: ~3-4/9
Not reliable enough to drive a dual-recogniser merge on its own.

## Where this points
- contextualStrings: ruled out empirically.
- dual on-device merge: en-US too unreliable (3-4/9) to be the primary mechanism.
- => the multilingual model (Gemini) is the only path with a real chance.
  GOOGLE_API_KEY is present in ~/.config/thaidictate/env, so the key exists.

## contextualStrings: now CONCLUSIVELY inert on th-TH on-device
Confound from the first test (Thai TTS pronouncing English) was removed by re-testing
with a native English voice (`say -v Samantha`), and by re-testing on the app's actual
request type. Byte-identical output in every cell:

| condition | spoken | bias off | bias on |
|---|---|---|---|
| EN voice, URL req | commit | เข็ด | เข็ด |
| EN voice, URL req | deploy | ซอย | ซอย |
| EN voice, URL req | debug | ที่บาร์ | ที่บาร์ |
| EN voice, BUFFER req (app's exact 5 settings) | commit | เข็ด | เข็ด |
| EN voice, BUFFER req | deploy | ซอย | ซอย |
| TH voice, BUFFER req | ช่วย commit โค้ดนี้ | ช่วยเครือมี… | ช่วยเครือมี… |

8 terms, all present in the app's real 20-term list (main.swift:121-126).
=> `main.swift:106-120`'s premise — that this list is "the single knob that decides
whether 'commit' comes back as `commit` or as `คอมมิต`" — is FALSE for the Apple path.
The list is applied (LiveRecognizer.swift:759) but the th-TH model ignores it.
It DOES still do real work on the Gemini REST path, where it is prompt text.

## Gemini REST probe with the EXISTING promptHead: 4/4 exact
| spoken | on-device th-TH | gemini-3.5-flash |
|---|---|---|
| ช่วย commit โค้ดนี้ให้หน่อยครับ | ช่วยเครือมีโค้ดนี้ให้หน่อยครับ | ช่วย commit โค้ดนี้ให้หน่อยครับ |
| ผมจะ deploy ขึ้น production พรุ่งนี้เช้า | ผมจะ Diplo ขึ้นโปรดักชั่นพรุ่งนี้เช้า | ผมจะ deploy ขึ้น production พรุ่งนี้เช้า |
| ไฟล์นี้มี bug ต้อง debug ก่อน | ไฟล์นี้มีบาสต้องดีก่อน | ไฟล์นี้มี bug ต้อง debug ก่อน |
| ผมใช้ Python กับ JavaScript ครับ | พรชัยพีเทิร์นกับจว่าสคริปต์ครับ | ผมใช้ Python กับ Javascript ครับ |

The fix already exists in the tree (GeminiClient.promptHead). It is OFF by default.

## Blockers the cloud pass does NOT solve on its own
- `applyCloudResult` refuses spans under 10 graphemes (main.swift:5018) — most short
  mixed utterances never get corrected.
- `replaceRecentText` is whole-span verbatim or nothing (TextInjector.swift:1291); a
  one-word Latin-vs-Thai fix is structurally a full-span rewrite.
- Turning it on changes the app's privacy posture: `requiresOnDeviceRecognition = true`
  (LiveRecognizer.swift:691) was a deliberate choice. That is the user's call, not mine.

## The 20-term coverage count (the decision that killed the mapping table)
Carrier `ผมจะ <TERM> นะครับ`, `say -v Kanya`, th-TH on-device:

| term | th-TH output | verdict |
|---|---|---|
| function | ฟังก์ชัน | safe to map |
| test | เทสต์ | safe to map |
| server | เซิร์ฟเวอร์ | safe to map |
| database | เดทเบส | odd spelling, marginal |
| endpoint | เอ็นโพ | truncated, marginal |
| **debug** | **ดีมาก** | COLLISION — "ดีมาก" = "very good" |
| **push** | **โพสต์** | COLLISION — "โพสต์" = "post" |
| **main** | **มี** | COLLISION — "มี" = "have" |
| **build** | **มี** | COLLISION — same output as `main` |
| **client** | **คลีน** | COLLISION — "คลีน" = "clean" |
| **merge** | **ง** | a single Thai letter |
| commit | เครื่อมี | garbage |
| branch | *(nothing at all)* | garbage |
| deploy | ดีโปร | garbage |
| refactor | Reminder | garbage |
| rebase | เรย์เดส | garbage |
| API | อพี่นะ | garbage |
| variable | ไม่ Revel | garbage |
| pull request | พูดรีเควสต์ | garbage |
| repository | รีดผ้าสีทอรีส์ | garbage |

**3 of 20 safely mappable.** `main` and `build` both produce `มี` — the same string, for two
different terms, and one of the commonest words in Thai. A mapping table would corrupt
correct text more often than it would fix broken text. NOT SHIPPED, by the numbers.

## Rejected: dual on-device recogniser (th-TH + en-US in parallel)
Both locales support on-device, so this needs no network. Killed by its own measurements:
- en-US missed `commit` completely on mix1 ("To clear Courtney no crap").
- en-US confidences are 0.00–0.34 even when CORRECT ("Deploy" 0.09, "production" 0.34),
  so confidence cannot arbitrate between the two engines.
- Segment granularity does not align: th-TH emitted `"Diplo ขึ้นโปรดักชั่น"` as ONE segment
  spanning 0.72–3.42 s against two separate en-US segments.
- Cost: doubles recognition CPU on a live audio path, for ~40% coverage at best.

## Conclusion
On-device only, mixed Thai+English CANNOT be fixed. The transliteration class is a
minority and half of it collides with ordinary Thai; the garbage class (`commit → เครือมี`)
has no local remedy at all. The one measured fix is the cloud pass (4/4 exact), which the
user has declined so that audio never leaves the machine. That is a coherent trade — it is
recorded here so nobody re-derives it from scratch.
