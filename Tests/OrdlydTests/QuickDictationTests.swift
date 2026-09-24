import XCTest
@testable import Ordlyd

@MainActor
final class QuickDictationTests: XCTestCase {
    func testShortcutDownStartsExactlyOneCaptureSession() async {
        let audio = FakeDictationAudioCapture()
        let coordinator = makeCoordinator(audio: audio)

        await coordinator.handle(.pressed)
        await coordinator.handle(.pressed)

        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(coordinator.state, .listening)
    }

    func testShortcutUpStopsCaptureAndRequestsLocalTranscription() async {
        let asset = URL(fileURLWithPath: "/tmp/dictation.wav")
        let audio = FakeDictationAudioCapture(completedAsset: asset)
        let speech = FakeQuickSpeechEngine(segments: [segment("Dette er lokalt.")])
        let coordinator = makeCoordinator(audio: audio, speech: speech)

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(speech.receivedURLs, [asset])
    }

    func testSuccessfulTranscriptIsInsertedIntoOriginalFocus() async {
        let focus = DictationFocusTarget(processIdentifier: 42, elementIdentifier: "editor")
        let cursor = FakeCursorInsertion(target: focus, insertionSucceeds: true)
        let coordinator = makeCoordinator(
            speech: FakeQuickSpeechEngine(segments: [segment("Hei fra NB-Whisper.")]),
            cursor: cursor
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        XCTAssertEqual(cursor.insertions, [.init(text: "Hei fra NB-Whisper.", target: focus)])
        XCTAssertEqual(coordinator.state, .completed)
        XCTAssertEqual(coordinator.status, .inserted)
    }

    func testInsertionFailureCopiesLiteralTranscriptToClipboard() async {
        let pasteboard = FakeDictationPasteboard()
        let coordinator = makeCoordinator(
            speech: FakeQuickSpeechEngine(segments: [segment("Bevar denne teksten ordrett.")]),
            cursor: FakeCursorInsertion(insertionSucceeds: false),
            pasteboard: pasteboard
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        XCTAssertEqual(pasteboard.values, ["Bevar denne teksten ordrett."])
        XCTAssertEqual(coordinator.status, .copiedToClipboard)
    }

    func testEscapeWhileListeningCancelsAndDeletesTemporaryAudio() async {
        let audio = FakeDictationAudioCapture()
        let cursor = FakeCursorInsertion()
        let pasteboard = FakeDictationPasteboard()
        let coordinator = makeCoordinator(audio: audio, cursor: cursor, pasteboard: pasteboard)

        await coordinator.handle(.pressed)
        await coordinator.handle(.cancelled)

        XCTAssertEqual(audio.cancelCount, 1)
        XCTAssertEqual(coordinator.state, .cancelled)
        XCTAssertTrue(cursor.insertions.isEmpty)
        XCTAssertTrue(pasteboard.values.isEmpty)
    }

    func testSilentAudioDoesNotInsertText() async {
        let cursor = FakeCursorInsertion()
        let pasteboard = FakeDictationPasteboard()
        let coordinator = makeCoordinator(
            speech: FakeQuickSpeechEngine(segments: []),
            cursor: cursor,
            pasteboard: pasteboard
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        XCTAssertEqual(coordinator.status, .noSpeech)
        XCTAssertTrue(cursor.insertions.isEmpty)
        XCTAssertTrue(pasteboard.values.isEmpty)
    }

    func testCompletedDictationCanStartAnotherCapture() async {
        let audio = FakeDictationAudioCapture()
        let coordinator = makeCoordinator(audio: audio)

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)
        await coordinator.handle(.pressed)

        XCTAssertEqual(audio.startCount, 2)
        XCTAssertEqual(coordinator.state, .listening)
    }

    func testRightCommandMonitorMapsPressReleaseAndEscape() {
        let source = FakeShortcutEventSource()
        let controller = GlobalShortcutController(source: source, conflictChecker: FakeShortcutConflictChecker())
        var actions: [DictationShortcutAction] = []
        controller.onAction = { actions.append($0) }

        controller.start()
        source.send(.modifierChanged(keyCode: 54, commandIsDown: true))
        source.send(.modifierChanged(keyCode: 54, commandIsDown: true))
        source.send(.keyDown(keyCode: 53))
        source.send(.modifierChanged(keyCode: 54, commandIsDown: false))

        XCTAssertEqual(actions, [.pressed, .cancelled])
        XCTAssertEqual(controller.status, .active)
    }

    func testConflictingShortcutIsReportedWithoutInstallingMonitor() {
        let source = FakeShortcutEventSource()
        let conflict = ShortcutConflict(description: "Command + Space brukes vanligvis av Spotlight.")
        let controller = GlobalShortcutController(source: source, conflictChecker: FakeShortcutConflictChecker(conflict: conflict))

        controller.start(configuration: .init(keyCode: 49, requiredModifiers: [.command]))

        XCTAssertEqual(controller.status, .conflict(conflict.description))
        XCTAssertEqual(source.installCount, 0)
    }

    func testMissingGlobalMonitorReportsPermissionRequired() {
        let source = FakeShortcutEventSource(globalMonitorInstalled: false)
        let controller = GlobalShortcutController(source: source, conflictChecker: FakeShortcutConflictChecker())

        controller.start()

        XCTAssertEqual(controller.status, .permissionRequired)
    }
}

@MainActor
private func makeCoordinator(
    audio: FakeDictationAudioCapture = FakeDictationAudioCapture(),
    speech: FakeQuickSpeechEngine = FakeQuickSpeechEngine(segments: [segment("Hei.")]),
    cursor: FakeCursorInsertion = FakeCursorInsertion(insertionSucceeds: true),
    pasteboard: FakeDictationPasteboard = FakeDictationPasteboard()
) -> DictationCoordinator {
    DictationCoordinator(audioCapture: audio, speechEngine: speech, cursorInsertion: cursor, pasteboard: pasteboard)
}

private func segment(_ text: String) -> TranscriptSegment {
    TranscriptSegment(id: "s1", start: 0, end: 1, speaker: nil, text: text)
}

private final class FakeDictationAudioCapture: DictationAudioCapturing {
    var startCount = 0
    var stopCount = 0
    var cancelCount = 0
    var cleanedURLs: [URL] = []
    let completedAsset: URL?

    init(completedAsset: URL? = URL(fileURLWithPath: "/tmp/dictation.wav")) { self.completedAsset = completedAsset }
    func start() async throws { startCount += 1 }
    func stop() -> URL? { stopCount += 1; return completedAsset }
    func cancel() { cancelCount += 1 }
    func removeAsset(at url: URL) { cleanedURLs.append(url) }
}

private final class FakeQuickSpeechEngine: SpeechEngine {
    let segments: [TranscriptSegment]
    var receivedURLs: [URL] = []
    init(segments: [TranscriptSegment]) { self.segments = segments }
    func transcribe(audioAt url: URL) async throws -> [TranscriptSegment] { receivedURLs.append(url); return segments }
}

private final class FakeCursorInsertion: CursorInsertionGateway {
    struct Insertion: Equatable { let text: String; let target: DictationFocusTarget? }
    let target: DictationFocusTarget?
    let insertionSucceeds: Bool
    var insertions: [Insertion] = []
    init(target: DictationFocusTarget? = .init(processIdentifier: 7, elementIdentifier: "field"), insertionSucceeds: Bool = true) {
        self.target = target; self.insertionSucceeds = insertionSucceeds
    }
    func captureFocusedTarget() -> DictationFocusTarget? { target }
    func insert(_ text: String, into target: DictationFocusTarget?) -> Bool {
        insertions.append(.init(text: text, target: target)); return insertionSucceeds
    }
}

private final class FakeDictationPasteboard: DictationPasteboardWriting {
    var values: [String] = []
    func write(_ text: String) { values.append(text) }
}

private final class FakeShortcutEventSource: ShortcutEventSourcing {
    var installCount = 0
    let globalMonitorInstalled: Bool
    private var handler: ((ShortcutHardwareEvent) -> Void)?
    init(globalMonitorInstalled: Bool = true) { self.globalMonitorInstalled = globalMonitorInstalled }
    func install(handler: @escaping (ShortcutHardwareEvent) -> Void) -> ShortcutMonitorInstallation {
        installCount += 1; self.handler = handler
        return ShortcutMonitorInstallation(tokens: [], globalMonitorInstalled: globalMonitorInstalled)
    }
    func remove(_ tokens: [Any]) { handler = nil }
    func send(_ event: ShortcutHardwareEvent) { handler?(event) }
}

private struct FakeShortcutConflictChecker: ShortcutConflictChecking {
    var conflict: ShortcutConflict?
    func conflict(for configuration: DictationShortcutConfiguration) -> ShortcutConflict? { conflict }
}
