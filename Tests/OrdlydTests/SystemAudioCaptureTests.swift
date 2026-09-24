import XCTest
@testable import Ordlyd

final class SystemAudioCaptureTests: XCTestCase {
    func testTimelineMixerCombinesOverlappingMicrophoneAndSystemAudio() {
        var mixer = TimelineAudioMixer()
        mixer.append(source: .microphone, samples: [1_000, 1_000], startSample: 0)
        mixer.append(source: .system, samples: [3_000, 3_000], startSample: 0)

        XCTAssertEqual(mixer.drain(before: 2), [2_000, 2_000])
    }

    func testTimelineMixerPreservesSingleSourceAndSilenceGaps() {
        var mixer = TimelineAudioMixer()
        mixer.append(source: .microphone, samples: [1_000, 2_000], startSample: 0)
        mixer.append(source: .system, samples: [3_000], startSample: 3)

        XCTAssertEqual(mixer.finish(), [1_000, 2_000, 0, 3_000])
    }

    func testTimelineMixerClipsCombinedAudioInsteadOfOverflowing() {
        var mixer = TimelineAudioMixer()
        mixer.append(source: .microphone, samples: [32_767], startSample: 0)
        mixer.append(source: .system, samples: [32_767], startSample: 0)

        XCTAssertEqual(mixer.finish(), [32_767])
    }

    @MainActor
    func testDigitalAudioModeStartsSystemAudioRecorderInsteadOfMicrophoneOnlyRecorder() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("digital-recorder-routing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = RoutingRecorder()
        let digital = RoutingRecorder()
        let store = AppStore(
            repository: JSONMeetingRepository(root: root.appendingPathComponent("meetings")),
            enableGlobalDictation: false,
            enableBackgroundRecovery: false,
            recordingRootDirectory: root,
            recorder: microphone,
            digitalRecorder: digital,
            enableFloatingRecordingBar: false,
            enableRecordingHotkey: false,
            enableMeetingDetection: false
        )
        store.audioMode = .digital

        await store.startRecording()

        XCTAssertEqual(microphone.startCount, 0)
        XCTAssertEqual(digital.startCount, 1)
        XCTAssertTrue(store.isRecording)
    }

    func testScreenRecordingPermissionErrorExplainsHowToRecover() {
        XCTAssertEqual(
            DigitalMeetingRecordingError.screenRecordingPermissionRequired.errorDescription,
            "Tillat skjerm- og systemlydopptak for Spark* NTNU - veilederverktøy i Systeminnstillinger → Personvern og sikkerhet → Skjerm- og systemlydopptak."
        )
    }
}

private final class RoutingRecorder: MeetingAudioRecording {
    var startCount = 0
    func start() async throws { startCount += 1 }
    func snapshot() throws -> MeetingAudioSnapshot? { nil }
    func stop() throws -> MeetingRecordingArtifact? { nil }
    func cancel() throws -> UUID? { nil }
}
