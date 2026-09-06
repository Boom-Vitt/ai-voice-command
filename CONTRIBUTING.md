# ร่วมพัฒนา MicTest

ขอบคุณที่ช่วยทำให้ dictation ภาษาไทยบน Mac ใช้งานได้ดีขึ้น รายงานบั๊ก ปรับเอกสาร และ PR ขนาดเล็กที่มีเหตุผลชัดเจนช่วยโปรเจกต์ได้มาก

## ก่อนเริ่ม

อ่าน [วิธี build](docs/GETTING_STARTED.md) และ [Architecture](docs/ARCHITECTURE.md) แล้วค้นหา issue ที่เกี่ยวข้อง หากเป็นการเปลี่ยน engine หรือเส้นทางส่งข้อมูล ควรเสนอแนวทางใน issue ก่อนลงมือ

เขียน issue และ PR ได้ทั้งไทยและอังกฤษ ตัวอย่างคำพูดควรเป็นประโยคทดสอบที่ไม่มีข้อมูลส่วนตัว อ่าน [Privacy](docs/PRIVACY.md) ก่อนแนบไฟล์

## Build และทดสอบ

ใช้ Apple Silicon, macOS 26+ และ Swift 6 ตามข้อกำหนดในคู่มือติดตั้ง ปิด MicTest Dev ก่อน build ทับ:

```bash
./MicTest/build-dev.sh "$HOME/Applications/MicTest Dev.app"
```

รัน Swift 6 typecheck และ component tests หกชุดจาก source จริง โดยไม่เปิดไมโครโฟน, UI, local server หรือ inference:

```bash
bash MicTest/tools/check.sh
```

Workflow **Checks** ใช้คำสั่งเดียวกันบน GitHub Actions ดูขอบเขตแต่ละชุดและเครื่องมือเฉพาะจุดที่ [MicTest/tools/README.md](MicTest/tools/README.md)

อ่าน README และ header ของเครื่องมือแต่ละตัวก่อนรัน integration tests บางตัวเปิด local server หรือพิมพ์ลงแอปจริง โดยเฉพาะ `run-correction-harness.sh` มี cleanup แบบเดิมที่ค้นหา whisper-server ทั้งเครื่อง ไม่ควรรันขณะมี server ของงานอื่นหรือ UI automation ทำงานอยู่

เลือก tests ให้ตรงกับการเปลี่ยนแปลง การแก้เอกสารอย่างเดียวไม่จำเป็นต้องเปิดไมโครโฟนหรือรันโมเดล

## หลักในการแก้โค้ด

- รักษาลำดับข้อความและตรวจช่องปลายทางก่อนแทรกหรือแก้
- รักษา grapheme clusters ภาษาไทยเมื่อคำนวณช่วงข้อความ
- ไม่ใส่กฎลบวลีจากคำพูดเพื่อซ่อนความผิดพลาดของ ASR
- ไม่สลับไป cloud อัตโนมัติ และไม่บันทึก key, เสียง หรือ transcript ลง log
- ตรวจ ownership ก่อนหยุด server และไม่ให้ audio callback ทำ file I/O หรืองาน UI
- แยกผล component tests, เสียงสังเคราะห์ และการทดสอบเสียงจริงให้ชัด

## ส่ง Pull Request

1. อธิบายปัญหาและพฤติกรรมหลังแก้ พร้อมตัวอย่างที่ทำซ้ำได้
2. จำกัด diff ให้เกี่ยวข้องกับงานเดียว และปรับเอกสารเมื่อพฤติกรรมเปลี่ยน
3. ระบุคำสั่งตรวจที่รัน ผลลัพธ์ และสิ่งที่ยังไม่ได้ทดสอบ
4. ตรวจ `git diff --check` และตรวจไฟล์ที่จะส่ง ไม่รวม model weights, build outputs, credentials, เสียงส่วนตัว, project memory หรือ instruction ภายในเครื่อง

ใช้ภาษาสุภาพ ให้ข้อเสนอแนะที่ตัวงาน และเคารพความเป็นส่วนตัวของผู้ร่วมพัฒนา
