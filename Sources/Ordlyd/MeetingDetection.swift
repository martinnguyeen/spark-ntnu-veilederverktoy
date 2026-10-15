import AppKit
import ApplicationServices
import SwiftUI

struct ForegroundAppContext: Equatable, Sendable {
    let bundleIdentifier: String
    let applicationName: String
    let windowTitle: String
}

enum DetectedMeetingKind: String, Equatable, Sendable {
    case teams
    case zoom
    case googleMeet

    var displayName: String {
        switch self {
        case .teams: "Teams"
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        }
    }

    var detectionTitle: String {
        switch self {
        case .teams: "Mulig Teams-møte"
        case .zoom: "Mulig Zoom-møte"
        case .googleMeet: "Mulig Google Meet-møte"
        }
    }
}

struct DetectedMeeting: Equatable, Sendable {
    let kind: DetectedMeetingKind
    let suggestedTitle: String
}

enum MeetingAppClassifier {
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "app.zen-browser.zen"
    ]

    static func detect(_ context: ForegroundAppContext) -> DetectedMeeting? {
        let bundleID = context.bundleIdentifier.lowercased()
        let title = context.windowTitle.lowercased()
        let meetingWords = ["meeting", "møte", "samtale", "call"]

        if bundleID == "us.zoom.xos", meetingWords.contains(where: title.contains) {
            return DetectedMeeting(kind: .zoom, suggestedTitle: "Zoom-møte")
        }

        if ["com.microsoft.teams", "com.microsoft.teams2"].contains(bundleID),
           meetingWords.contains(where: title.contains) {
            return DetectedMeeting(kind: .teams, suggestedTitle: "Teams-møte")
        }

        if browserBundleIdentifiers.contains(context.bundleIdentifier),
           title.contains("google meet") || title.contains("meet.google.com") {
            return DetectedMeeting(kind: .googleMeet, suggestedTitle: "Google Meet")
        }

        return nil
    }
}

struct MeetingDetectionGate {
    private var lastDetectedMeeting: DetectedMeeting?

    mutating func observe(_ meeting: DetectedMeeting?) -> DetectedMeeting? {
        guard let meeting else {
            lastDetectedMeeting = nil
            return nil
        }
        guard meeting != lastDetectedMeeting else { return nil }
        lastDetectedMeeting = meeting
        return meeting
    }
}

protocol ForegroundAppInspecting {
    func currentContext() -> ForegroundAppContext?
}

struct MacForegroundAppInspector: ForegroundAppInspecting {
    func currentContext() -> ForegroundAppContext? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let title = accessibilityWindowTitle(for: application)
            ?? coreGraphicsWindowTitle(for: application.processIdentifier)
            ?? ""
        return ForegroundAppContext(
            bundleIdentifier: application.bundleIdentifier ?? "",
            applicationName: application.localizedName ?? "",
            windowTitle: title
        )
    }

    private func accessibilityWindowTitle(for application: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success else { return nil }
        return titleValue as? String
    }

    private func coreGraphicsWindowTitle(for processIdentifier: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.first { window in
            (window[kCGWindowOwnerPID as String] as? pid_t) == processIdentifier
                && (window[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowName as String] as? String
    }
}

@MainActor
final class MeetingDetectionController {
    private weak var store: AppStore?
    private let inspector: any ForegroundAppInspecting
    private var gate = MeetingDetectionGate()
    private var timer: Timer?

    init(store: AppStore, inspector: any ForegroundAppInspecting = MacForegroundAppInspector()) {
        self.store = store
        self.inspector = inspector
    }

    func start() {
        inspect()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.inspect() }
        }
    }

    private func inspect() {
        guard let store, !store.isRecording, !store.isProcessing else { return }
        let meeting = inspector.currentContext().flatMap(MeetingAppClassifier.detect)
        if let newMeeting = gate.observe(meeting) { store.receiveDetectedMeeting(newMeeting) }
    }
}

@MainActor
final class MeetingPromptController {
    private weak var store: AppStore?
    private var panel: NSPanel?

    init(store: AppStore) { self.store = store }

    func show(_ meeting: DetectedMeeting) {
        guard let store else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: MeetingPromptView(store: store, meeting: meeting))
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 390, height: 164)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setContentSize(size)
        panel.setAccessibilityLabel("Mulig digital møtekontekst")
        return panel
    }

    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visibleFrame.maxX - panel.frame.width - 24, y: visibleFrame.maxY - panel.frame.height - 24))
    }
}

private struct MeetingPromptView: View {
    @ObservedObject var store: AppStore
    let meeting: DetectedMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "video.fill").foregroundStyle(SparkPalette.orange).font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.kind.detectionTitle).font(.headline)
                    Text("Dette vinduet kan være et møte. Spark starter ikke opptak før du velger Start.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Når du velger Start, tas valgt mikrofon og systemlyd opp lokalt. Systemlyd kan også inneholde annen Mac-lyd. macOS kan be om tillatelse første gang.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Ikke nå") { store.dismissDetectedMeeting() }.buttonStyle(.bordered)
                Spacer()
                Button("Start opptak") { Task { await store.acceptDetectedMeeting() } }
                    .buttonStyle(.borderedProminent).tint(SparkPalette.orange)
            }
        }
        .padding(18)
        .frame(width: 390, height: 164)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.5)))
    }
}
