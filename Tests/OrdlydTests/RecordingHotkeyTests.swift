import XCTest
@testable import Ordlyd

@MainActor
final class RecordingHotkeyTests: XCTestCase {
    func testRightOptionReleaseStartsRecordingWhenIdle() {
        let scheduler = ManualRecordingHotkeyScheduler()
        var isRecording = false
        var actions: [RecordingHotkeyAction] = []
        let interpreter = RecordingHotkeyInterpreter(
            isRecording: { isRecording },
            scheduler: scheduler,
            onAction: {
                actions.append($0)
                if $0 == .start { isRecording = true }
            }
        )

        interpreter.optionTapped()

        XCTAssertEqual(actions, [.start])
    }

    func testDoubleRightOptionTapImmediatelyAfterStartCancelsRecording() {
        let scheduler = ManualRecordingHotkeyScheduler()
        var isRecording = false
        var actions: [RecordingHotkeyAction] = []
        let interpreter = RecordingHotkeyInterpreter(
            isRecording: { isRecording },
            scheduler: scheduler,
            onAction: {
                actions.append($0)
                if $0 == .start { isRecording = true }
            }
        )

        interpreter.optionTapped()
        interpreter.optionTapped()
        scheduler.runPending()

        XCTAssertEqual(actions, [.start, .cancel])
    }

    func testSingleRightOptionTapFinishesAfterDoubleTapWindow() {
        let scheduler = ManualRecordingHotkeyScheduler()
        var actions: [RecordingHotkeyAction] = []
        let interpreter = RecordingHotkeyInterpreter(
            isRecording: { true },
            scheduler: scheduler,
            onAction: { actions.append($0) }
        )

        interpreter.optionTapped()
        XCTAssertTrue(actions.isEmpty)

        scheduler.runPending()
        XCTAssertEqual(actions, [.finish])
    }

    func testDoubleRightOptionTapCancelsWithoutFinishing() {
        let scheduler = ManualRecordingHotkeyScheduler()
        var actions: [RecordingHotkeyAction] = []
        let interpreter = RecordingHotkeyInterpreter(
            isRecording: { true },
            scheduler: scheduler,
            onAction: { actions.append($0) }
        )

        interpreter.optionTapped()
        interpreter.optionTapped()
        scheduler.runPending()

        XCTAssertEqual(actions, [.cancel])
    }

    func testRightOptionMonitorEmitsOneTapOnRelease() {
        let source = FakeRecordingShortcutEventSource()
        let controller = GlobalShortcutController(source: source, conflictChecker: NoRecordingShortcutConflict())
        var actions: [DictationShortcutAction] = []
        controller.onAction = { actions.append($0) }

        controller.start(configuration: .rightOption)
        source.send(.modifierChanged(keyCode: 61, modifiers: [.option]))
        source.send(.modifierChanged(keyCode: 61, modifiers: []))

        XCTAssertEqual(actions, [.pressed, .released])
    }

    func testAppStoreMapsHotkeyStartAndCancelToMeetingRecorder() async {
        let recorder = RecordingHotkeyTestRecorder()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-hotkey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(
            repository: JSONMeetingRepository(root: root.appendingPathComponent("meetings")),
            enableGlobalDictation: false,
            enableBackgroundRecovery: false,
            recordingRootDirectory: root,
            recorder: recorder,
            enableFloatingRecordingBar: false,
            enableRecordingHotkey: false
        )

        await store.handleRecordingHotkey(.start)
        await store.handleRecordingHotkey(.cancel)

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertFalse(store.isRecording)
    }
}

@MainActor
private final class ManualRecordingHotkeyScheduler: RecordingHotkeyScheduling {
    private var work: (() -> Void)?
    var pendingCount: Int { work == nil ? 0 : 1 }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> RecordingHotkeyCancellation {
        self.work = work
        return RecordingHotkeyCancellation { [weak self] in self?.work = nil }
    }

    func runPending() {
        let pending = work
        work = nil
        pending?()
    }
}

private final class FakeRecordingShortcutEventSource: ShortcutEventSourcing {
    private var handler: ((ShortcutHardwareEvent) -> Void)?
    func install(handler: @escaping (ShortcutHardwareEvent) -> Void) -> ShortcutMonitorInstallation {
        self.handler = handler
        return ShortcutMonitorInstallation(tokens: [], globalMonitorInstalled: true)
    }
    func remove(_ tokens: [Any]) { handler = nil }
    func send(_ event: ShortcutHardwareEvent) { handler?(event) }
}

private struct NoRecordingShortcutConflict: ShortcutConflictChecking {
    func conflict(for configuration: DictationShortcutConfiguration) -> ShortcutConflict? { nil }
}

private final class RecordingHotkeyTestRecorder: MeetingAudioRecording {
    var startCount = 0
    var cancelCount = 0
    func start() async throws { startCount += 1 }
    func snapshot() throws -> MeetingAudioSnapshot? { nil }
    func stop() throws -> MeetingRecordingArtifact? { nil }
    func cancel() throws -> UUID? { cancelCount += 1; return nil }
}
