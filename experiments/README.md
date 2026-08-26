# Experiment harness

Reproduces the measurements in `../research/REPORT.md`. Run from an **interactive terminal**
(macOS will show a TCC permission dialog that a non-interactive session cannot surface).

## 1. Apple Thai locale probe — no permissions needed
```
swiftc -O -parse-as-library thaiLocales.swift -o thaiLocales && ./thaiLocales
```
Expected on macOS 26.5.1: SpeechTranscriber = 30 locales, **no Thai**;
SFSpeechRecognizer = 63 locales, th-TH present with supportsOnDevice = true.

## 2. Thai+English code-switching ASR probe — needs Speech Recognition permission
A bare CLI binary is killed by TCC (SIGABRT) unless it carries an embedded Info.plist with
`NSSpeechRecognitionUsageDescription`. Build it with the plist linked in:
```
swiftc -O -parse-as-library thaiASR.swift -o thaiASR \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
./thaiASR
```
Click **Allow** on the permission dialog. Tests each clip in 4 configs:
th-TH on-device / th-TH cloud / th-TH + contextualStrings glossary / en-US on-device.

The `contextualStrings` run is the important one — it is Apple's keyword-boosting hook, the
same mechanism that took English-term retention from 0/7 to 5/7 on local Whisper.

## 3. IMPORTANT — replace the test audio first
`thaitest/*.wav` is **synthetic** (macOS `say -v Kanya`), so absolute accuracy is unreliable.
Re-record all five lines in your own voice before trusting any number:

  cs1  เดี๋ยว deploy ให้ก่อนนะ
  cs2  meeting ตอนบ่าย 3 โมง
  cs3  ช่วย refactor function นี้หน่อย
  cs4  ช่วย commit แล้ว push ขึ้น branch main ให้หน่อย
  th_only  สวัสดีครับ วันนี้อากาศดีมาก        (control — should be exact)

Format: 16 kHz mono WAV.

## Scoring — plain WER is invalid for code-mixed text
  ETR (English-Term Retention) = English tokens emitted in Latin script / English tokens spoken
  Thai CER on the surrounding Thai, English spans excluded (regression guard)
