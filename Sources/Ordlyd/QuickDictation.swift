import Foundation
import AppKit
import ApplicationServices

// MARK: - Shortcut boundary

struct DictationModifiers: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let command = DictationModifiers(rawValue: 1 << 0)
    static let option = DictationModifiers(rawValue: 1 << 1)
    static let control = DictationModifiers(rawValue: 1 << 2)
    static let shift = DictationModifiers(rawValue: 1 << 3)
}

struct DictationShortcutConfiguration: Equatable, Sendable {
    let keyCode: Int
    let requiredModifiers: DictationModifiers

    static let rightCommand = DictationShortcutConfiguration(keyCode: 54, requiredModifiers: [.command])
    static let rightOption = DictationShortcutConfiguration(keyCode: 61, requiredModifiers: [.option])
}

struct ShortcutConflict: Equatable, Sendable {
    let description: String
}

enum ShortcutRegistrationStatus: Equatable, Sendable {
    case stopped
    case active
    case permissionRequired
    case conflict(String)
}

enum DictationShortcutAction: Equatable, Sendable {
    case pressed
    case released
    case cancelled
}

struct ShortcutHardwareEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case keyDown, keyUp, modifierChanged }

    let kind: Kind
    let keyCode: Int
    let modifiers: DictationModifiers

    static func keyDown(keyCode: Int, modifiers: DictationModifiers = []) -> Self {
        .init(kind: .keyDown, keyCode: keyCode, modifiers: modifiers)
    }

    static func keyUp(keyCode: Int, modifiers: DictationModifiers = []) -> Self {
        .init(kind: .keyUp, keyCode: keyCode, modifiers: modifiers)
    }

    static func modifierChanged(keyCode: Int, commandIsDown: Bool) -> Self {
        .init(kind: .modifierChanged, keyCode: keyCode, modifiers: commandIsDown ? [.command] : [])
    }

    static func modifierChanged(keyCode: Int, modifiers: DictationModifiers) -> Self {
        .init(kind: .modifierChanged, keyCode: keyCode, modifiers: modifiers)
    }
}

protocol ShortcutEventSourcing: AnyObject {
    func install(handler: @escaping (ShortcutHardwareEvent) -> Void) -> ShortcutMonitorInstallation
    func remove(_ tokens: [Any])
}

struct ShortcutMonitorInstallation {
    let tokens: [Any]
    let globalMonitorInstalled: Bool
}

protocol ShortcutConflictChecking {
    func conflict(for configuration: DictationShortcutConfiguration) -> ShortcutConflict?
}

struct MacShortcutConflictChecker: ShortcutConflictChecking {
    func conflict(for configuration: DictationShortcutConfiguration) -> ShortcutConflict? {
        // Key code 49 is Space. macOS reserves Command + Space for Spotlight by default.
        if configuration.keyCode == 49, configuration.requiredModifiers == [.command] {
            return ShortcutConflict(description: "Command + Space brukes vanligvis av Spotlight. Velg en annen snarvei eller endre Spotlight-snarveien i Systeminnstillinger.")
        }
        return nil
    }
}

final class MacShortcutEventSource: ShortcutEventSourcing {
    func install(handler: @escaping (ShortcutHardwareEvent) -> Void) -> ShortcutMonitorInstallation {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        var tokens: [Any] = []
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            handler(Self.hardwareEvent(from: event))
        })
        if let global { tokens.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(Self.hardwareEvent(from: event))
            return event
        }
        if let local { tokens.append(local) }
        return ShortcutMonitorInstallation(tokens: tokens, globalMonitorInstalled: global != nil)
    }

    func remove(_ tokens: [Any]) {
        tokens.forEach(NSEvent.removeMonitor)
    }

    private static func hardwareEvent(from event: NSEvent) -> ShortcutHardwareEvent {
        let modifiers = modifiers(from: event.modifierFlags)
        switch event.type {
        case .keyDown: return .keyDown(keyCode: Int(event.keyCode), modifiers: modifiers)
        case .keyUp: return .keyUp(keyCode: Int(event.keyCode), modifiers: modifiers)
        default: return .init(kind: .modifierChanged, keyCode: Int(event.keyCode), modifiers: modifiers)
        }
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> DictationModifiers {
        var result: DictationModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

final class GlobalShortcutController {
    private let source: ShortcutEventSourcing
    private let conflictChecker: ShortcutConflictChecking
    private var tokens: [Any] = []
    private var configuration = DictationShortcutConfiguration.rightCommand
    private var isHeld = false

    private(set) var status: ShortcutRegistrationStatus = .stopped
    var onAction: ((DictationShortcutAction) -> Void)?

    init(source: ShortcutEventSourcing = MacShortcutEventSource(), conflictChecker: ShortcutConflictChecking = MacShortcutConflictChecker()) {
        self.source = source
        self.conflictChecker = conflictChecker
    }

    deinit { source.remove(tokens) }

    func start(configuration: DictationShortcutConfiguration = .rightCommand) {
        stop()
        if let conflict = conflictChecker.conflict(for: configuration) {
            status = .conflict(conflict.description)
            return
        }
        self.configuration = configuration
        let installation = source.install { [weak self] event in self?.receive(event) }
        tokens = installation.tokens
        status = installation.globalMonitorInstalled ? .active : .permissionRequired
    }

    func stop() {
        source.remove(tokens)
        tokens = []
        isHeld = false
        status = .stopped
    }

    private func receive(_ event: ShortcutHardwareEvent) {
        if event.kind == .keyDown, event.keyCode == 53, isHeld {
            isHeld = false
            onAction?(.cancelled)
            return
        }

        let isModifierShortcut = [54, 55, 58, 61].contains(configuration.keyCode)
        let eventMatches = event.keyCode == configuration.keyCode
        let requiredModifiersPresent = event.modifiers.isSuperset(of: configuration.requiredModifiers)
        let down = isModifierShortcut ? requiredModifiersPresent : event.kind == .keyDown && requiredModifiersPresent
        let up = isModifierShortcut ? !requiredModifiersPresent : event.kind == .keyUp

        if eventMatches, down, !isHeld {
            isHeld = true
            onAction?(.pressed)
        } else if eventMatches, up, isHeld {
            isHeld = false
            onAction?(.released)
        }
    }
}

// MARK: - Dictation boundaries

protocol DictationAudioCapturing: AnyObject {
    func start() async throws
    func stop() -> URL?
    func cancel()
    func removeAsset(at url: URL)
}

final class LocalDictationAudioCapture: DictationAudioCapturing {
    private let recorder: LocalAudioRecorder

    init(recorder: LocalAudioRecorder = LocalAudioRecorder()) { self.recorder = recorder }
    func start() async throws { try await recorder.start() }
    func stop() -> URL? { recorder.stop() }
    func cancel() {
        if let url = recorder.stop() { removeAsset(at: url) }
    }
    func removeAsset(at url: URL) { try? FileManager.default.removeItem(at: url) }
}

struct DictationFocusTarget: Equatable, Hashable, Sendable {
    let processIdentifier: pid_t
    let elementIdentifier: String
}

protocol CursorInsertionGateway: AnyObject {
    func captureFocusedTarget() -> DictationFocusTarget?
    func insert(_ text: String, into target: DictationFocusTarget?) -> Bool
}

protocol DictationPasteboardWriting: AnyObject {
    func write(_ text: String)
}

final class AccessibilityCursorInsertionService: CursorInsertionGateway {
    private var elements: [String: AXUIElement] = [:]

    func captureFocusedTarget() -> DictationFocusTarget? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let identifier = UUID().uuidString
        elements[identifier] = (focused as! AXUIElement)
        return DictationFocusTarget(processIdentifier: app.processIdentifier, elementIdentifier: identifier)
    }

    func insert(_ text: String, into target: DictationFocusTarget?) -> Bool {
        guard AXIsProcessTrusted(), let target, let element = elements.removeValue(forKey: target.elementIdentifier) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }
}

final class SystemDictationPasteboard: DictationPasteboardWriting {
    func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum DictationUserStatus: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case inserted
    case copiedToClipboard
    case noSpeech
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .idle: return "Hold høyre Command for å diktere."
        case .listening: return "Lytter …"
        case .transcribing: return "Transkriberer lokalt …"
        case .inserted: return "Teksten ble satt inn ved markøren."
        case .copiedToClipboard: return "Kunne ikke sette inn ved markøren. Teksten er kopiert."
        case .noSpeech: return "Ingen tale ble gjenkjent."
        case .cancelled: return "Dikteringen ble avbrutt."
        case .failed(let message): return message
        }
    }
}

@MainActor
final class DictationCoordinator {
    private let audioCapture: DictationAudioCapturing
    private let speechEngine: SpeechEngine
    private let cursorInsertion: CursorInsertionGateway
    private let pasteboard: DictationPasteboardWriting
    private var originalFocus: DictationFocusTarget?

    private(set) var state: DictationState = .idle
    private(set) var status: DictationUserStatus = .idle {
        didSet { onStatusChange?(status) }
    }
    var onStatusChange: ((DictationUserStatus) -> Void)?

    init(
        audioCapture: DictationAudioCapturing = LocalDictationAudioCapture(),
        speechEngine: SpeechEngine = NBWhisperEngine.installed,
        cursorInsertion: CursorInsertionGateway = AccessibilityCursorInsertionService(),
        pasteboard: DictationPasteboardWriting = SystemDictationPasteboard()
    ) {
        self.audioCapture = audioCapture
        self.speechEngine = speechEngine
        self.cursorInsertion = cursorInsertion
        self.pasteboard = pasteboard
    }

    func handle(_ action: DictationShortcutAction) async {
        switch action {
        case .pressed: await beginIfPossible()
        case .released: await finishIfListening()
        case .cancelled: cancelIfListening()
        }
    }

    private func beginIfPossible() async {
        if [.completed, .cancelled, .failed].contains(state) {
            state = .idle
            status = .idle
        }
        guard state == .idle else { return }
        originalFocus = cursorInsertion.captureFocusedTarget()
        do {
            try await audioCapture.start()
            state = .listening
            status = .listening
        } catch {
            originalFocus = nil
            state = .failed
            status = .failed(error.localizedDescription)
        }
    }

    private func finishIfListening() async {
        guard state == .listening else { return }
        state = .processing
        status = .transcribing
        guard let asset = audioCapture.stop() else {
            originalFocus = nil
            state = .completed
            status = .noSpeech
            return
        }
        defer { audioCapture.removeAsset(at: asset) }

        do {
            let segments = try await speechEngine.transcribe(audioAt: asset)
            let text = TranscriptFormatter.continuousText(segments).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                originalFocus = nil
                state = .completed
                status = .noSpeech
                return
            }
            state = .inserting
            if cursorInsertion.insert(text, into: originalFocus) {
                state = .completed
                status = .inserted
            } else {
                pasteboard.write(text)
                state = .completed
                status = .copiedToClipboard
            }
            originalFocus = nil
        } catch NBWhisperError.emptyTranscript {
            originalFocus = nil
            state = .completed
            status = .noSpeech
        } catch {
            originalFocus = nil
            state = .failed
            status = .failed(error.localizedDescription)
        }
    }

    private func cancelIfListening() {
        guard state == .listening else { return }
        audioCapture.cancel()
        originalFocus = nil
        state = .cancelled
        status = .cancelled
    }
}
