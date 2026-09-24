import XCTest
@testable import Ordlyd

final class ImportTests: XCTestCase {
    func testTextDocumentPreservesParagraphsAsEvidenceSegments() throws {
        let segments = try ImportedTextDocument.segments(from: "  Første avsnitt.\n\nAndre avsnitt.  ")
        XCTAssertEqual(segments.map(\.text), ["Første avsnitt.", "Andre avsnitt."])
        XCTAssertEqual(segments.map(\.id), ["s1", "s2"])
    }

    func testSpeakerLinesBecomeAttributedEvidenceSegments() throws {
        let segments = try ImportedTextDocument.segments(from: "Speaker 1: Første poeng.\nSpeaker 2: Andre poeng.")
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(segments.map(\.text), ["Første poeng.", "Andre poeng."])
    }

    func testRTFDisguisedAsTextIsDecodedBeforeImport() throws {
        let rtf = #"{\rtf1\ansi\ansicpg1252 Speaker 1: Vi skal m\'e5le fremdriften.\par Speaker 2: Ja.}"#
        let text = try ImportedTextDocument.decode(data: Data(rtf.utf8))
        XCTAssertEqual(text, "Speaker 1: Vi skal måle fremdriften.\nSpeaker 2: Ja.")
        XCTAssertFalse(text.contains("\\rtf"))
    }

    func testProvidedTranscriptImportsAsReadableNorwegianWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["IDUN_TEST_FILE"] else {
            throw XCTSkip("Kjør med IDUN_TEST_FILE for å kontrollere den vedlagte filen.")
        }
        let text = try ImportedTextDocument.read(from: URL(fileURLWithPath: path))
        let segments = try ImportedTextDocument.segments(from: text)
        XCTAssertGreaterThan(segments.count, 20)
        XCTAssertTrue(text.contains("å"))
        XCTAssertTrue(text.contains("Speaker 1:"))
        XCTAssertFalse(text.contains("\\rtf"))
        XCTAssertFalse(text.contains("\\'e5"))
    }

    func testEmptyTextDocumentIsRejected() {
        XCTAssertThrowsError(try ImportedTextDocument.segments(from: " \n\t "))
    }

    func testAudioConversionTargetsWhisperCompatibleWAV() {
        let destination = ImportedAudioConverter.destinationURL()
        XCTAssertEqual(destination.pathExtension, "wav")
        XCTAssertTrue(destination.lastPathComponent.hasPrefix("ordlyd-import-"))
    }
}
