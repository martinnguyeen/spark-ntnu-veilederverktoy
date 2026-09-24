import AppKit
import SwiftUI

enum RecordingBarVisibilityPolicy {
    static func shouldShow(isRecording: Bool, isAppActive: Bool) -> Bool {
        isRecording && !isAppActive
    }
}

@MainActor
final class FloatingRecordingBarController {
    private weak var store: AppStore?
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []

    init(store: AppStore) {
        self.store = store
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(isAppActive: false) }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(isAppActive: true) }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func recordingStateChanged() {
        refresh(isAppActive: NSApplication.shared.isActive)
    }

    private func refresh(isAppActive: Bool) {
        guard let store else { return }
        if RecordingBarVisibilityPolicy.shouldShow(isRecording: store.isRecording, isAppActive: isAppActive) {
            show(store: store)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func show(store: AppStore) {
        let panel = panel ?? makePanel(store: store)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel(store: AppStore) -> NSPanel {
        let size = NSSize(width: 330, height: 66)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: FloatingRecordingBarView(store: store))
        panel.setContentSize(size)
        panel.setAccessibilityLabel("Opptak pågår")
        return panel
    }

    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 28
        )
        panel.setFrameOrigin(origin)
    }
}

private struct FloatingRecordingBarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        HStack(spacing: 13) {
            Button { store.cancelRecording() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Avbryt og slett opptaket")
            .accessibilityLabel("Avbryt opptak")

            VStack(alignment: .leading, spacing: 3) {
                Text("Tar opp møte").font(.system(size: 13, weight: .semibold))
                Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.68))
            }

            AnimatedRecordingWaveform()
                .frame(width: 82, height: 26)
                .accessibilityHidden(true)

            Button { store.stopRecording() } label: {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .bold))
                    .foregroundStyle(SparkPalette.ink)
                    .frame(width: 42, height: 42)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Fullfør og transkriber")
            .accessibilityLabel("Fullfør opptak")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(width: 330, height: 66)
        .background(SparkPalette.ink, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
    }

    private var duration: String {
        String(format: "%02d:%02d", store.elapsed / 60, store.elapsed % 60)
    }
}

private struct AnimatedRecordingWaveform: View {
    private let phases: [Double] = [0, 0.7, 1.4, 2.1, 2.8, 3.5, 4.2, 4.9, 5.6, 6.3, 7.0, 7.7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                    Capsule()
                        .frame(width: 3, height: 7 + 15 * abs(sin(time * 4.2 + phase)))
                }
            }
            .foregroundStyle(SparkPalette.orange)
            .frame(maxHeight: .infinity)
        }
    }
}
