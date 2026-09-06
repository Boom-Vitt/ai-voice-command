# เริ่มใช้ MicTest

[← กลับ README](../README.md) · [Architecture](ARCHITECTURE.md) · [Privacy](PRIVACY.md)

## สิ่งที่ต้องมี

| รายการ | ข้อกำหนด |
|:--|:--|
| Mac | Apple Silicon (`arm64`) |
| ระบบปฏิบัติการ | macOS 26 ขึ้นไป |
| เครื่องมือ build | Swift 6 และ macOS SDK ที่รองรับ macOS 26 จาก Xcode หรือ Command Line Tools |
| สิทธิ์ | Microphone, Speech Recognition, Accessibility |
| Whisper / Gemini | เป็นส่วนเสริม ไม่จำเป็นสำหรับเริ่มด้วย Apple Speech |

ตรวจเครื่องมือก่อน build:

```bash
uname -m
xcrun swiftc --version
xcrun --show-sdk-path --sdk macosx
```

## Build รุ่นพัฒนา

รันจากราก repository:

```bash
./MicTest/build-dev.sh "$HOME/Applications/MicTest Dev.app"
open "$HOME/Applications/MicTest Dev.app"
```

หากไม่ระบุปลายทาง สคริปต์ใช้ `~/Applications/MicTest Dev.app` เช่นกัน ปิดแอปก่อน rebuild สคริปต์จะตรวจ bundle และ signature ก่อนแทนที่แอปเดิม

รุ่นนี้ใช้ ad-hoc signature และ bundle ID `com.boombignose.mictest.dev` จึงมีการตั้งค่าและสิทธิ์แยกจากรุ่น production การ rebuild อาจทำให้ macOS ขอสิทธิ์อีกครั้ง เปิดจาก `.app` bundle เสมอเพื่อให้ระบบอ่าน metadata สำหรับการขอสิทธิ์

ถ้า `xcrun` เลือก Xcode ที่ยังตั้งค่าไม่เสร็จ ให้เปิด Xcode และทำขั้นตอนเริ่มต้นให้ครบ หรือเลือก Command Line Tools ที่ติดตั้งและมี SDK ตรงข้อกำหนด เช่น:

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  ./MicTest/build-dev.sh "$HOME/Applications/MicTest Dev.app"
```

### สำหรับผู้มี Developer ID

ตั้ง `MICTEST_SIGN_ID` เป็น SHA-1 ของ Developer ID Application certificate ของคุณใน Keychain แล้ว build ไปยังปลายทางของ MicTest โดยเฉพาะ:

```bash
MICTEST_SIGN_ID="YOUR_DEVELOPER_ID_CERTIFICATE_SHA1" \
  ./MicTest/build.sh "$HOME/Applications/MicTest.app"
```

สคริปต์ production ปฏิเสธ ad-hoc signing และแทนที่ `.app` ที่ระบุ จึงควรใช้ปลายทางเฉพาะของโปรเจกต์ สคริปต์นี้ยังไม่มีขั้นตอน notarization หรือสร้าง installer สำหรับเผยแพร่

## เปิดสิทธิ์และพูดครั้งแรก

1. เปิดแอป แล้วให้สิทธิ์ **Microphone** และ **Speech Recognition**
2. เปิด **System Settings → Privacy & Security → Accessibility** และเปิดสิทธิ์ให้ bundle ที่กำลังใช้ เมนูแอปมีทางลัดไปหน้าตั้งค่าสิทธิ์
3. หาก macOS ขอให้ Quit & Reopen ให้เปิด bundle เดิมอีกครั้ง
4. เปิดเอกสารทดลอง วางเคอร์เซอร์ในช่องข้อความ แล้วแตะ **Right Option** หนึ่งครั้ง
5. พูดประโยคสั้น ดูฉบับร่างบน HUD แล้วแตะปุ่มเดิมหรือ **Stop** เพื่อจบ

ค่าเริ่มต้นปิด **Automatic corrections** ข้อความในช่องปลายทางจึงอาจปรากฏเมื่อจบช่วงเสียงหรือหยุดพูด หากแอปตรวจช่องปลายทางไม่ได้ ข้อความจะคงอยู่ให้เลือก **Copy last transcript**

## ตั้งค่า Thai + English: local large-v3

ขั้นตอนนี้เป็นการติดตั้งส่วนเสริมด้วยตนเอง **repository และสคริปต์ build ไม่มีตัวดาวน์โหลด runtime หรือโมเดลอัตโนมัติ** เริ่มใช้ Apple Speech ก่อนได้

แอปตรวจ runtime ที่โครงสร้างนี้:

```text
~/Library/Application Support/MicTest/whisper/
  bin/
    whisper-server
  models/
    ggml-large-v3.bin
    ggml-silero-v6.2.0.bin
```

เตรียม `whisper-server` สำหรับ Apple Silicon ที่รองรับ VAD พร้อม dependencies ที่ binary ต้องใช้ และโมเดลทั้งสองไฟล์ตามชื่อข้างต้น อ่านวิธี build, ดาวน์โหลดโมเดล และ VAD จาก [เอกสาร upstream ของ whisper.cpp](https://github.com/ggml-org/whisper.cpp) ตรวจ checksum กับแหล่งดาวน์โหลดก่อนนำมาใช้

Runtime ที่ใช้เป็นฐานการพัฒนาคือ whisper.cpp 1.9.2; ความเข้ากันได้กับเวอร์ชันอื่นต้องตรวจเพิ่ม อย่าคัดลอกเฉพาะ binary หาก build นั้นยังอ้างอิง dynamic libraries จากตำแหน่งเดิม

เมื่อไฟล์พร้อม ให้เปิด MicTest ใหม่และตรวจเมนู **Thai + English: local large-v3** เส้นทางนี้ต้องมี **full large-v3 + Silero VAD + binary ในตำแหน่งของ MicTest** ครบ การมี turbo หรือ binary จาก Homebrew เพียงอย่างเดียวไม่เปิดโหมดนี้

Apple Speech จะแสดงฉบับร่างใน HUD และ Whisper จะถอดเสียงสุดท้ายก่อนแทรกตามลำดับ แอปจัดการ server บน `127.0.0.1` เอง จึงไม่ต้องเปิด server ด้วยมือ

### เพิ่มคำที่ใช้บ่อย

สร้างหรือแก้ `~/.config/thaidictate/keyterms.txt` โดยใส่หนึ่งคำต่อบรรทัด เช่น:

```text
SwiftUI
refactor
GitHub
```

คำที่เพิ่มเองมีลำดับก่อนคำที่แอปแถมมา และโหลดอีกครั้งเมื่อเริ่มบันทึก Glossary เป็นคำใบ้การสะกด ไม่ใช่กฎบังคับผลลัพธ์ ควรเปรียบเทียบผลก่อนและหลังเพิ่มคำ

## Gemini เป็นทางเลือก

แอปอ่าน `GOOGLE_API_KEY` จากไฟล์ข้อความ `~/.config/thaidictate/env` ตั้งสิทธิ์ไฟล์เป็น `600` และเก็บไฟล์ไว้นอก repository จากนั้นเปิดแอปใหม่และเลือก Gemini correction หรือ Gemini Live จากเมนูด้วยตนเอง

Gemini correction ส่งช่วงเสียงพร้อมคำใบ้ไป Google ส่วน Gemini Live สตรีมเสียงระหว่างบันทึก การมี key อย่างเดียวไม่ได้ยืนยันว่า account ใช้โมเดลที่กำหนดใน source ได้ ดู [Privacy](PRIVACY.md) ก่อนเปิดใช้

## แก้ปัญหาเบื้องต้น

| อาการ | สิ่งที่ตรวจ |
|:--|:--|
| แตะ Right Option แล้วไม่เริ่ม | ดู HUD และสิทธิ์ Accessibility ของ bundle ที่เปิดอยู่ |
| ขอสิทธิ์อีกหลัง rebuild | รุ่น Dev เปลี่ยน signature ได้ ตรวจให้ macOS อนุญาต bundle ปัจจุบัน แล้ว Quit & Reopen ตามที่ระบบแจ้ง |
| เห็นฉบับร่างแต่ยังไม่พิมพ์ | รอ final หรือกดหยุด; ค่าเริ่มต้นใช้ preview ก่อนแทรก |
| เปลี่ยนแอปแล้วข้อความไม่มา | ใช้ **Copy last transcript** และวางเอง เพื่อรักษาช่องปลายทางเดิม |
| Local large-v3 แสดง off | ตรวจ binary, full model, VAD และ dependencies ตามตำแหน่งข้างต้น |
| Apple Speech ไม่พร้อม | ตรวจสิทธิ์ Speech Recognition และสถานะ on-device recognition ของระบบ |
| ถอดเสียงผิด | ใช้ประโยคทดสอบสั้นที่ไม่มีข้อมูลส่วนตัว ระบุโหมดและคำที่ตั้งใจพูดเมื่อแจ้งบั๊ก |

ไฟล์ trace ของแอปอยู่ที่ `/tmp/mictest_trace.txt` ตรวจและลบข้อมูลระบุตัวตนก่อนแชร์ ส่วนไฟล์เสียงสำหรับกู้คืนต้องจัดการเป็นข้อมูลส่วนตัว ดู [Privacy](PRIVACY.md)
