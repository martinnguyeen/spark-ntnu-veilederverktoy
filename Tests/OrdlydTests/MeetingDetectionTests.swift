import XCTest
@testable import Ordlyd

final class MeetingDetectionTests: XCTestCase {
    func testZoomMeetingWindowIsDetected() {
        let context = ForegroundAppContext(
            bundleIdentifier: "us.zoom.xos",
            applicationName: "zoom.us",
            windowTitle: "Zoom Meeting"
        )

        XCTAssertEqual(MeetingAppClassifier.detect(context), DetectedMeeting(kind: .zoom, suggestedTitle: "Zoom-møte"))
    }

    func testZoomHomeWindowDoesNotProduceFalseMeetingPrompt() {
        let context = ForegroundAppContext(
            bundleIdentifier: "us.zoom.xos",
            applicationName: "Zoom Workplace",
            windowTitle: "Home"
        )

        XCTAssertNil(MeetingAppClassifier.detect(context))
    }

    func testTeamsMeetingWindowIsDetected() {
        let context = ForegroundAppContext(
            bundleIdentifier: "com.microsoft.teams2",
            applicationName: "Microsoft Teams",
            windowTitle: "Prosjektmøte | Microsoft Teams"
        )

        XCTAssertEqual(MeetingAppClassifier.detect(context), DetectedMeeting(kind: .teams, suggestedTitle: "Teams-møte"))
    }

    func testGoogleMeetBrowserTabIsDetected() {
        let context = ForegroundAppContext(
            bundleIdentifier: "company.thebrowser.Browser",
            applicationName: "Arc",
            windowTitle: "abc-defg-hij – Google Meet"
        )

        XCTAssertEqual(MeetingAppClassifier.detect(context), DetectedMeeting(kind: .googleMeet, suggestedTitle: "Google Meet"))
    }

    func testDetectionGatePromptsOnceUntilMeetingContextClears() {
        var gate = MeetingDetectionGate()
        let meeting = DetectedMeeting(kind: .teams, suggestedTitle: "Teams-møte")

        XCTAssertEqual(gate.observe(meeting), meeting)
        XCTAssertNil(gate.observe(meeting))
        XCTAssertNil(gate.observe(nil))
        XCTAssertEqual(gate.observe(meeting), meeting)
    }

    @MainActor
    func testDetectedMeetingRequiresExplicitAcceptanceBeforeRecordingStarts() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-detection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = MeetingDetectionTestRecorder()
        let digitalRecorder = MeetingDetectionTestRecorder()
        let store = AppStore(
            repository: JSONMeetingRepository(root: root.appendingPathComponent("meetings")),
            enableGlobalDictation: false,
            enableBackgroundRecovery: false,
            recordingRootDirectory: root,
            recorder: recorder,
            digitalRecorder: digitalRecorder,
            enableFloatingRecordingBar: false,
            enableRecordingHotkey: false,
            enableMeetingDetection: false
        )
        let meeting = DetectedMeeting(kind: .zoom, suggestedTitle: "Zoom-møte")

        store.receiveDetectedMeeting(meeting)
        XCTAssertEqual(store.detectedMeeting, meeting)
        XCTAssertEqual(recorder.startCount, 0)

        await store.acceptDetectedMeeting()
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(digitalRecorder.startCount, 1)
        XCTAssertEqual(store.audioMode, .digital)
        XCTAssertTrue(store.isRecording)
        XCTAssertNil(store.detectedMeeting)
    }
}

private final class MeetingDetectionTestRecorder: MeetingAudioRecording {
    var startCount = 0
    func start() async throws { startCount += 1 }
    func snapshot() throws -> MeetingAudioSnapshot? { nil }
    func stop() throws -> MeetingRecordingArtifact? { nil }
    func cancel() throws -> UUID? { nil }
}
