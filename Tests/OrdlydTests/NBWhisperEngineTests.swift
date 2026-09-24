import XCTest
@testable import Ordlyd

final class NBWhisperEngineTests: XCTestCase {
    func testWhisperJSONBecomesTimestampedTranscriptSegments() throws {
        let json = #"{"transcription":[{"timestamps":{"from":"00:00:00,000","to":"00:00:04,250"},"offsets":{"from":0,"to":4250},"text":" Dette er en test."},{"timestamps":{"from":"00:00:04,250","to":"00:00:07,000"},"offsets":{"from":4250,"to":7000},"text":" Andre setning."}]}"#.data(using: .utf8)!
        let segments = try WhisperJSONParser.parse(json)
        XCTAssertEqual(segments, [
            TranscriptSegment(id: "s1", start: 0, end: 4.25, speaker: nil, text: "Dette er en test."),
            TranscriptSegment(id: "s2", start: 4.25, end: 7, speaker: nil, text: "Andre setning.")
        ])
    }

    func testQuotedWhisperTextIsCleanedBeforeDisplay() throws {
        let json = #"{"transcription":[{"timestamps":{"from":"00:00:00,000","to":"00:00:02,000"},"offsets":{"from":0,"to":2000},"text":" \"Hei verden.\""}]}"#.data(using: .utf8)!
        XCTAssertEqual(try WhisperJSONParser.parse(json)[0].text, "Hei verden.")
    }

    func testMissingModelReportsActionableError() async {
        let engine = NBWhisperEngine(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"), modelURL: URL(fileURLWithPath: "/definitely/missing/model.bin"))
        do {
            _ = try await engine.transcribe(audioAt: URL(fileURLWithPath: "/tmp/audio.wav"))
            XCTFail("Expected missing model error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "NB-Whisper-modellen mangler. Installer modellen før du transkriberer.")
        }
    }
}
