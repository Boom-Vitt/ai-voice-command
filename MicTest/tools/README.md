# MicTest tools

[← README](../../README.md) · [Contributing](../../CONTRIBUTING.md)

เครื่องมือในโฟลเดอร์นี้แยกจาก app bundle สคริปต์ build แอปคอมไพล์เฉพาะ `Sources/MicTest/*.swift`

## ตรวจพื้นฐานด้วยคำสั่งเดียว

รันจากราก repository บน Apple Silicon พร้อม Swift 6 และ macOS 26+ SDK:

```bash
bash MicTest/tools/check.sh
```

สคริปต์รัน typecheck ของแอปทั้งโมดูล แล้วคอมไพล์ component tests ร่วมกับ source ที่แอปใช้จริง สร้าง executable ชั่วคราวและล้างเมื่อจบ ไม่ใช้ไมโครโฟน, Accessibility automation, runtime ของโมเดล หรือ network requests

| ชุดตรวจ | พฤติกรรมที่ครอบคลุม |
|:--|:--|
| Audio pipeline | การแบ่งช่วงเสียง การ flush และการรักษา PCM |
| Transcription queue | ลำดับงาน ขอบเขตรอบบันทึก และการยกเลิก |
| Stable transcript | การส่งข้อความสมบูรณ์ครั้งเดียวและ final/stop fallback |
| Pending transcript | เก็บส่วนที่ส่งไม่สำเร็จ ลองใหม่ตามลำดับ และไม่ส่งส่วนที่สำเร็จแล้วซ้ำ |
| Text target | app/window/field identity, selection ที่อ่านไม่ครบ และการยกเลิก fallback เมื่อมีกิจกรรมผู้ใช้ |
| Tail repair | แผนแก้ท้ายข้อความโดยรักษา grapheme clusters ภาษาไทย |
| Audio gain | การปรับเสียงเบาภายในขอบเขต และการคงเสียงปกติ/silence |
| Segment joining | การรวมข้อความจาก local Whisper โดยไม่เพิ่มช่องว่างกลางคำไทย |

Workflow **Checks** บน GitHub Actions ใช้ runner เดียวกัน การผ่านชุดตรวจนี้ไม่ยืนยันความแม่นยำของ ASR หรือการพิมพ์ผ่าน Accessibility ในแอปจริง

## เครื่องมือเฉพาะจุด

อ่าน README และ header ของเครื่องมือก่อนรัน เพราะบางตัวมีผลกับระบบหรือแอปที่เปิดอยู่

| ตำแหน่ง | ใช้เมื่อ |
|:--|:--|
| `audio-pipeline-local-test/` | ตรวจการแบ่งและ flush เสียงแบบแยกส่วน |
| `local-transcription-queue-test/` | ตรวจคิว local transcription |
| `local-transcription-integration-test/` | ตรวจการเชื่อม pipeline/transcriber; บางโหมดต้องมี runtime |
| `stable-transcript-test/`, `tail-repair-test/` | ตรวจ buffer และการวางแผนแก้ข้อความโดยไม่พิมพ์ลงแอป |
| `pending-transcript-test/`, `text-target-test/` | ตรวจการกู้คืนข้อความและเงื่อนไขปลายทางแบบ pure tests |
| `cap-test/` | ตรวจสูตรจำกัดช่วงแก้ข้อความ |
| `prompt-test/` | ตรวจ glossary และ multipart request |
| `whisper-server-lifecycle/` | ตรวจ server ownership และ lifecycle; แยก fake-server tests จาก real-server tests |
| `segment-timestamp-probe/` | ตรวจ callback/timestamps ของ Apple Speech ผ่าน signed app |
| `s2-overload-repro/` | ตัวอย่างจำลอง Swift overload resolution |
| `make-icon.py` | สร้าง app icon |

**`run-correction-harness.sh` เป็นเครื่องมือเก่าสำหรับทดสอบผ่าน UI จริง:** มันพิมพ์ลง TextEdit และ cleanup ค้นหา whisper-server ทั้งเครื่อง อย่ารันพร้อม server ของโปรเจกต์อื่นหรือ UI automation และอย่าเปลี่ยนโฟกัสระหว่างทำงาน

ผลทดสอบควรระบุให้ชัดว่าเป็น component, synthetic audio, real voice หรือ UI integration พร้อมเงื่อนไขและผลที่ทำซ้ำได้ ไม่ใช้จำนวน checks แทนตัวเลขความแม่นยำการถอดเสียง
