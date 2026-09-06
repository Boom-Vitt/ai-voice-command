# เสียงและข้อมูลไปที่ไหน

[← กลับ README](../README.md) · [เริ่มใช้งาน](GETTING_STARTED.md)

เอกสารนี้อธิบายพฤติกรรมของ source ปัจจุบัน การเลือก engine และ correction provider มีผลต่อข้อมูลที่ออกจากเครื่อง

## เส้นทางประมวลผล

| เส้นทาง | ข้อมูลที่ใช้ | ปลายทาง |
|:--|:--|:--|
| Apple Speech | เสียงจากไมโครโฟน | On-device recognition; source กำหนด `requiresOnDeviceRecognition = true` |
| Local Whisper | WAV ของช่วงเสียงและ glossary | `whisper-server` บน `127.0.0.1` ของ Mac |
| Gemini correction | ช่วงเสียงและ prompt ซึ่งอาจรวม glossary | Google Gemini API |
| Gemini Live | เสียงที่สตรีมระหว่าง dictation | Google Gemini Live API |

Gemini ต้องมี key และเลือกเปิดจากเมนู ไม่มีการสลับจาก local ไป cloud โดยอัตโนมัติ หากต้องการเส้นทางประมวลผลในเครื่อง ให้ใช้ Apple/local และตรวจว่า correction provider ไม่ใช่ Gemini

การดาวน์โหลด runtime หรือโมเดลเป็นขั้นตอนแยกที่ใช้อินเทอร์เน็ต สคริปต์ build แอปไม่ได้ดาวน์โหลดสิ่งเหล่านี้ให้

## สิ่งที่อาจอยู่บน Mac

| ข้อมูล | ตำแหน่ง/พฤติกรรม |
|:--|:--|
| Runtime และโมเดล | `~/Library/Application Support/MicTest/whisper/` |
| เสียงกู้คืนเมื่อ local transcription ล้มเหลวหรือคิวเต็ม | `~/Library/Application Support/MicTest/Recovery/`; source สร้างโฟลเดอร์ด้วยสิทธิ์ `700` และตั้งไฟล์ WAV เป็น `600` |
| Glossary ส่วนตัว | `~/.config/thaidictate/keyterms.txt` |
| Gemini API key | `~/.config/thaidictate/env` เป็นไฟล์ข้อความธรรมดา; ผู้ใช้ควรตั้งสิทธิ์เป็น `600` |
| การตั้งค่าแอป | macOS `UserDefaults` ของ bundle แต่ละรุ่น |
| Diagnostic trace | `/tmp/mictest_trace.txt`; มีข้อมูลสถานะ และอาจมี local paths หรือรายละเอียดข้อผิดพลาด ต้องตรวจและลบข้อมูลส่วนตัวก่อนแชร์ |
| ข้อความที่แทรก/คัดลอก | ช่องข้อความปลายทางและ clipboard ตามการทำงานของ text injection หรือ **Copy last transcript** |

**ไม่มีระบบล้าง Recovery อัตโนมัติในเส้นทางนี้** หลังใช้กู้คืนเสร็จ ให้เปิดโฟลเดอร์และลบไฟล์เสียงที่ไม่ต้องการด้วยตนเอง การลบแอปไม่ได้หมายความว่าไฟล์ config, runtime และ Recovery ถูกลบไปด้วย

ไฟล์ trace สร้างด้วยโหมด `644` จึงอาจอ่านได้โดยผู้ใช้อื่นบนเครื่องเดียวกัน ไม่ควรถือว่าเป็นพื้นที่เก็บข้อมูลลับ ตรวจเนื้อหาก่อนแชร์เสมอ และอย่าส่ง raw log โดยยังไม่ได้ลบข้อมูลส่วนตัว

การประมวลผลเสียงในเครื่องไม่ควบคุมพฤติกรรมของแอปปลายทาง บริการซิงก์ clipboard หรือ clipboard manager ที่ผู้ใช้ติดตั้งไว้

## สิทธิ์ macOS

- **Microphone:** รับเสียงขณะบันทึก
- **Speech Recognition:** ใช้ Apple Speech สำหรับถอดเสียงและฉบับร่าง
- **Accessibility:** ตรวจช่องข้อความ ส่งข้อความ และรับปุ่มลัดตามเส้นทางที่แอปใช้

เพิกถอนสิทธิ์ได้ใน **System Settings → Privacy & Security** รุ่น Dev กับ production มี bundle ID แยกกัน จึงมีรายการสิทธิ์แยกกัน

## เมื่อต้องแจ้งบั๊ก

ใช้ประโยคทดสอบที่สร้างขึ้นใหม่และไม่มีข้อมูลส่วนตัว ส่งเฉพาะขั้นตอนที่ทำซ้ำได้ พร้อมเวอร์ชัน macOS โหมดที่เลือก และข้อความสถานะที่จำเป็น

ก่อนแนบ log, ภาพหน้าจอ หรือไฟล์ ให้ลบชื่อผู้ใช้ local paths, API keys, ข้อความในเอกสาร และข้อมูลส่วนตัวของบุคคลอื่น **ไม่แนบเสียงจริงหรือ transcript ส่วนตัวใน public issue**

ไฟล์ instruction, project memory, local config, credentials และข้อมูลการทดสอบส่วนตัวไม่ใช่ส่วนหนึ่งของชุดเผยแพร่สาธารณะ
