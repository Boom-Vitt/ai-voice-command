import Foundation

@main
struct ClientTextTest {
    static func main() {
        let cases = [
            ("ให้\nหน่อย", "ให้หน่อย"),
            ("ให้\r\nหน่อย", "ให้หน่อย"),
            ("ให้\rหน่อย", "ให้หน่อย"),
            ("refactor\n function", "refactor function"),
            ("refactor \r\nfunction", "refactor function"),
            ("refactor \n function", "refactor  function"),
            ("  เดี๋ยว deploy\n ให้ก่อนนะ\r\n", "เดี๋ยว deploy ให้ก่อนนะ"),
            ("\r\n\n\r", ""),
            ("คำพูดเดิม refactor function", "คำพูดเดิม refactor function"),
        ]
        for (index, item) in cases.enumerated() {
            guard LocalWhisperTranscriber.joiningSegments(item.0) == item.1 else {
                print("FAIL segment joining case \(index)")
                exit(1)
            }
        }
        print("PASS \(cases.count) segment joining checks")
    }
}
