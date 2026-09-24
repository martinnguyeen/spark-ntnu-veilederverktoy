import Foundation

enum RecordingHotkeyAction: Equatable, Sendable {
    case start
    case finish
    case cancel
}

@MainActor
final class RecordingHotkeyCancellation {
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

@MainActor
protocol RecordingHotkeyScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> RecordingHotkeyCancellation
}

@MainActor
struct MainQueueRecordingHotkeyScheduler: RecordingHotkeyScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> RecordingHotkeyCancellation {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return RecordingHotkeyCancellation { item.cancel() }
    }
}

@MainActor
final class RecordingHotkeyInterpreter {
    private enum PendingTap { case startCancellationWindow, finish }

    private let isRecording: () -> Bool
    private let scheduler: any RecordingHotkeyScheduling
    private let onAction: (RecordingHotkeyAction) -> Void
    private let doubleTapInterval: TimeInterval
    private var pendingTap: PendingTap?
    private var pendingCancellation: RecordingHotkeyCancellation?

    init(
        isRecording: @escaping () -> Bool,
        scheduler: (any RecordingHotkeyScheduling)? = nil,
        doubleTapInterval: TimeInterval = 0.34,
        onAction: @escaping (RecordingHotkeyAction) -> Void
    ) {
        self.isRecording = isRecording
        self.scheduler = scheduler ?? MainQueueRecordingHotkeyScheduler()
        self.doubleTapInterval = doubleTapInterval
        self.onAction = onAction
    }

    func optionTapped() {
        if pendingTap != nil {
            pendingCancellation?.cancel()
            pendingCancellation = nil
            pendingTap = nil
            onAction(.cancel)
            return
        }

        if isRecording() {
            pendingTap = .finish
            pendingCancellation = scheduler.schedule(after: doubleTapInterval) { [weak self] in
                guard let self, self.pendingTap == .finish else { return }
                self.pendingTap = nil
                self.pendingCancellation = nil
                if self.isRecording() { self.onAction(.finish) }
            }
        } else {
            onAction(.start)
            pendingTap = .startCancellationWindow
            pendingCancellation = scheduler.schedule(after: doubleTapInterval) { [weak self] in
                guard let self, self.pendingTap == .startCancellationWindow else { return }
                self.pendingTap = nil
                self.pendingCancellation = nil
            }
        }
    }
}
