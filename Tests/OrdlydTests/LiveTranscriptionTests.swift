import XCTest
@testable import Ordlyd

final class LiveTranscriptionTests: XCTestCase {
    func testProductNameMatchesRequestedSparkVeilederverktøyName() {
        XCTAssertEqual(Brand.productName, "Spark* NTNU - veilederverktøy")
    }

    func testNewLivePassReplacesEarlierProvisionalTranscript() {
        var buffer = LiveTranscriptBuffer()
        buffer.update([TranscriptSegment(id: "s1", start: 0, end: 2, speaker: nil, text: "Dette er")])
        buffer.update([TranscriptSegment(id: "s1", start: 0, end: 4, speaker: nil, text: "Dette er en test.")])
        XCTAssertEqual(buffer.text, "Dette er en test.")
        XCTAssertTrue(buffer.isProvisional)
    }

    func testFinalizingLiveTranscriptMarksTextAsStable() {
        var buffer = LiveTranscriptBuffer()
        buffer.update([TranscriptSegment(id: "s1", start: 0, end: 4, speaker: nil, text: "Dette er en test.")])
        buffer.finalize()
        XCTAssertFalse(buffer.isProvisional)
    }

    func testWaveSnapshotHasValidPCMHeaderAndPayloadSize() throws {
        let samples: [Int16] = [0, 1000, -1000, 250]
        let data = WaveEncoder.encode(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 52)
    }

    func testTranscriptSegmentsReadAsOneContinuousText() {
        let segments = [
            TranscriptSegment(id: "s1", start: 0, end: 2, speaker: "Martin", text: "Dette er første setning."),
            TranscriptSegment(id: "s2", start: 2, end: 5, speaker: "Martin", text: "Dette er neste setning.")
        ]
        XCTAssertEqual(TranscriptFormatter.continuousText(segments), "Dette er første setning. Dette er neste setning.")
    }

    func testRecordingBarIsVisibleWhenRecordingContinuesOutsideTheApp() {
        XCTAssertTrue(RecordingBarVisibilityPolicy.shouldShow(isRecording: true, isAppActive: false))
    }

    func testRecordingBarDoesNotDuplicateTheInAppRecordingUI() {
        XCTAssertFalse(RecordingBarVisibilityPolicy.shouldShow(isRecording: true, isAppActive: true))
        XCTAssertFalse(RecordingBarVisibilityPolicy.shouldShow(isRecording: false, isAppActive: false))
    }

    @MainActor
    func testCancellingFromRecordingBarStopsRecordingAndDeletesPartialAudio() throws {
        let meetingID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-bar-cancel-\(UUID().uuidString)")
        let artifactDirectory = root.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        try Data("partial-audio".utf8).write(to: artifactDirectory.appendingPathComponent("segment.wav"))
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RecordingBarTestRecorder(cancelledMeetingID: meetingID)
        let repository = JSONMeetingRepository(root: root.appendingPathComponent("meetings"))
        let store = AppStore(
            repository: repository,
            enableGlobalDictation: false,
            enableBackgroundRecovery: false,
            recordingRootDirectory: root,
            recorder: recorder,
            enableFloatingRecordingBar: false
        )
        store.isRecording = true

        store.cancelRecording()

        XCTAssertFalse(store.isRecording)
        XCTAssertFalse(store.isProcessing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
    }
}

private final class RecordingBarTestRecorder: MeetingAudioRecording {
    let cancelledMeetingID: UUID
    init(cancelledMeetingID: UUID) { self.cancelledMeetingID = cancelledMeetingID }
    func start() async throws { }
    func snapshot() throws -> MeetingAudioSnapshot? { nil }
    func stop() throws -> MeetingRecordingArtifact? { nil }
    func cancel() throws -> UUID? { cancelledMeetingID }
}
