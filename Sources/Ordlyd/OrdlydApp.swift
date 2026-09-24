import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SparkPalette {
    static let orange = Color(red: 242/255, green: 140/255, blue: 28/255)
    static let ink = Color(red: 26/255, green: 26/255, blue: 26/255)
    static let paper = Color(red: 250/255, green: 250/255, blue: 248/255)
    static let stone = Color(red: 232/255, green: 230/255, blue: 225/255)
    static let mist = Color(red: 253/255, green: 240/255, blue: 220/255)
}

enum Brand {
    static let productName = "Spark* NTNU - veilederverktøy"
}

@main
struct OrdlydApp: App {
    @StateObject private var store = AppStore(enableMeetingDetection: true)
    var body: some Scene {
        WindowGroup(Brand.productName) { ContentView().environmentObject(store).preferredColorScheme(.light).frame(minWidth: 980, minHeight: 680) }.windowStyle(.hiddenTitleBar)
        MenuBarExtra(Brand.productName, systemImage: store.isRecording ? "waveform.circle.fill" : "waveform.circle") {
            Button(store.isRecording ? "Stopp møte" : "Start møte") { store.toggleRecording() }
            Divider()
            Button("Åpne Ordlyd") { NSApp.activate(ignoringOtherApps: true) }
            Button("Avslutt") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: UUID?
    @Published var search = ""
    @Published var isRecording = false
    @Published var audioMode = AudioMode.microphone
    @Published var elapsed = 0
    @Published var isProcessing = false
    @Published var liveSegments: [TranscriptSegment] = []
    @Published var liveStatus = "Lytter …"
    @Published var statusMessage: String?
    @Published var analyzingMeetingID: UUID?
    @Published var analysisStage: AnalysisStage = .preparing
    @Published var analysisStartedAt: Date?
    @Published var isTestingIDUN = false
    @Published var idunTestMessage: String?
    @Published var idunTestSucceeded = false
    @Published var showOnboarding = false
    @Published var onboardingAPIKey = ""
    @Published var onboardingNetworkConfirmed = false
    @Published var dictationStatus = DictationUserStatus.idle
    @Published var analysisMode = IDUNAnalysisMode.automatic
    @Published var detectedMeeting: DetectedMeeting?
    private var timer: Timer?
    private var liveTimer: Timer?
    private var liveTranscriptionInFlight = false
    private let recorder: any MeetingAudioRecording
    private let digitalRecorder: any MeetingAudioRecording
    private var activeRecorder: (any MeetingAudioRecording)?
    private var recordingBarController: FloatingRecordingBarController?
    private let recordingCatalog: RecoverableRecordingCatalog
    private let speechEngine = NBWhisperEngine.installed
    private let analysisProvider = IDUNAnalysisProvider()
    private let repository: any MeetingRepository
    private let shortcutController: GlobalShortcutController
    private let recordingShortcutController: GlobalShortcutController
    private let dictationCoordinator: DictationCoordinator
    private var recordingHotkeyInterpreter: RecordingHotkeyInterpreter?
    private var recordingStartInFlight = false
    private var cancelRecordingWhenStartCompletes = false
    private var meetingDetectionController: MeetingDetectionController?
    private var meetingPromptController: MeetingPromptController?
    private var activeRecordingTitle = "Nytt lydopptak"
    enum AudioMode: String, CaseIterable, Identifiable { case microphone = "Kun mikrofon", digital = "Mikrofon + systemlyd"; var id: Self { self } }
    init(
        repository: any MeetingRepository = JSONMeetingRepository.applicationDefault,
        enableGlobalDictation: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        enableBackgroundRecovery: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        recordingRootDirectory: URL? = nil,
        recorder suppliedRecorder: (any MeetingAudioRecording)? = nil,
        digitalRecorder suppliedDigitalRecorder: (any MeetingAudioRecording)? = nil,
        enableFloatingRecordingBar: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        enableRecordingHotkey: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        enableMeetingDetection: Bool = false
    ) {
        self.repository = repository
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let resolvedRecordingRoot = recordingRootDirectory ?? (isTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ordlyd-test-recordings-\(UUID().uuidString)", isDirectory: true)
            : RecordingDirectories.recoverableRecordings)
        recorder = suppliedRecorder ?? RecoverableMeetingAudioRecorder(rootDirectory: resolvedRecordingRoot)
        digitalRecorder = suppliedDigitalRecorder ?? ScreenCaptureMeetingAudioRecorder(rootDirectory: resolvedRecordingRoot)
        recordingCatalog = RecoverableRecordingCatalog(rootDirectory: resolvedRecordingRoot)
        let shortcuts = GlobalShortcutController()
        let recordingShortcuts = GlobalShortcutController()
        let dictation = DictationCoordinator()
        shortcutController = shortcuts
        recordingShortcutController = recordingShortcuts
        dictationCoordinator = dictation
        let stored = (try? repository.loadAll()) ?? []
        meetings = stored
        selection = stored.first?.id
        showOnboarding = (try? IDUNKeychain().load()) == nil
        dictation.onStatusChange = { [weak self] status in self?.dictationStatus = status }
        shortcuts.onAction = { [weak dictation] action in Task { @MainActor in await dictation?.handle(action) } }
        recordingHotkeyInterpreter = RecordingHotkeyInterpreter(
            isRecording: { [weak self] in self?.isRecording ?? false },
            onAction: { [weak self] action in
                Task { @MainActor in await self?.handleRecordingHotkey(action) }
            }
        )
        recordingShortcuts.onAction = { [weak self] action in
            guard action == .released else { return }
            Task { @MainActor in self?.recordingHotkeyInterpreter?.optionTapped() }
        }
        if enableGlobalDictation { shortcuts.start() }
        if enableRecordingHotkey { recordingShortcuts.start(configuration: .rightOption) }
        if enableBackgroundRecovery {
            recordingCatalog.enforceRetention()
            Task { await recoverInterruptedRecordings() }
        }
        if enableFloatingRecordingBar { recordingBarController = FloatingRecordingBarController(store: self) }
        if enableMeetingDetection {
            meetingPromptController = MeetingPromptController(store: self)
            let detector = MeetingDetectionController(store: self)
            meetingDetectionController = detector
            detector.start()
        }
    }
    var filtered: [Meeting] { meetings.filter { MeetingSearch.matches($0, query: search) } }
    var selected: Meeting? { meetings.first { $0.id == selection } }
    private var recorderForCurrentMode: any MeetingAudioRecording { audioMode == .digital ? digitalRecorder : recorder }
    func toggleRecording() {
        if isRecording { stopRecording() }
        else {
            activeRecordingTitle = detectedMeeting?.suggestedTitle ?? "Nytt lydopptak"
            dismissDetectedMeeting()
            Task { await startRecording() }
        }
    }
    func startRecording() async {
        guard !isRecording, !isProcessing else { return }
        let selectedRecorder = recorderForCurrentMode
        activeRecorder = selectedRecorder
        recordingStartInFlight = true
        do {
            try await selectedRecorder.start()
            recordingStartInFlight = false
            isRecording = true; elapsed = 0; statusMessage = nil; liveSegments = []; liveStatus = "Lytter …"
            recordingBarController?.recordingStateChanged()
            if cancelRecordingWhenStartCompletes {
                cancelRecordingWhenStartCompletes = false
                cancelRecording()
                return
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.elapsed += 1 } }
            liveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refreshLiveTranscript() } }
        } catch {
            recordingStartInFlight = false
            cancelRecordingWhenStartCompletes = false
            activeRecorder = nil
            statusMessage = error.localizedDescription
        }
    }
    func handleRecordingHotkey(_ action: RecordingHotkeyAction) async {
        switch action {
        case .start:
            cancelRecordingWhenStartCompletes = false
            activeRecordingTitle = detectedMeeting?.suggestedTitle ?? "Nytt lydopptak"
            dismissDetectedMeeting()
            await startRecording()
        case .finish:
            stopRecording()
        case .cancel:
            if isRecording { cancelRecording() }
            else if recordingStartInFlight { cancelRecordingWhenStartCompletes = true }
        }
    }
    func receiveDetectedMeeting(_ meeting: DetectedMeeting) {
        guard !isRecording, !isProcessing else { return }
        detectedMeeting = meeting
        meetingPromptController?.show(meeting)
    }
    func acceptDetectedMeeting() async {
        guard let meeting = detectedMeeting, !isRecording, !isProcessing else { return }
        activeRecordingTitle = meeting.suggestedTitle
        dismissDetectedMeeting()
        await startRecording()
    }
    func dismissDetectedMeeting() {
        detectedMeeting = nil
        meetingPromptController?.hide()
    }
    func stopRecording() {
        guard isRecording else { return }
        let duration = elapsed
        timer?.invalidate(); timer = nil; liveTimer?.invalidate(); liveTimer = nil; isRecording = false; isProcessing = true
        recordingBarController?.recordingStateChanged()
        statusMessage = "Transkriberer lokalt med NB-Whisper …"
        let artifact: MeetingRecordingArtifact
        do {
            let activeRecorder = activeRecorder ?? recorderForCurrentMode
            guard let stopped = try activeRecorder.stop() else {
                self.activeRecorder = nil
                statusMessage = "Opptaket inneholdt ingen lyd."
                isProcessing = false
                return
            }
            self.activeRecorder = nil
            artifact = stopped
        } catch {
            activeRecorder = nil
            statusMessage = "Opptaket er bevart for gjenoppretting: \(error.localizedDescription)"
            isProcessing = false
            return
        }
        Task {
            do {
                while liveTranscriptionInFlight { try await Task.sleep(for: .milliseconds(150)) }
                let segments = try await SegmentedTranscriber(engine: speechEngine).transcribe(artifact)
                let meeting = Meeting(id: artifact.meetingID, title: activeRecordingTitle, date: artifact.createdAt, duration: max(TimeInterval(duration), artifact.duration), state: .transcriptReady, transcript: segments, analysis: nil)
                meetings.insert(meeting, at: 0); selection = meeting.id
                try repository.save(meeting)
                try recordingCatalog.markTranscriptionSucceeded(for: artifact.meetingID)
                liveSegments = []
                statusMessage = "Transkripsjonen er klar. Segmentert lyd kan gjenopprettes og slettes automatisk etter sju dager."
            } catch {
                statusMessage = "Opptaket er bevart for gjenoppretting: \(error.localizedDescription)"
            }
            isProcessing = false
            activeRecordingTitle = "Nytt lydopptak"
        }
    }
    func cancelRecording() {
        guard isRecording else { return }
        timer?.invalidate(); timer = nil
        liveTimer?.invalidate(); liveTimer = nil
        isRecording = false
        isProcessing = false
        liveSegments = []
        recordingBarController?.recordingStateChanged()
        do {
            if let meetingID = try (activeRecorder ?? recorderForCurrentMode).cancel() { try recordingCatalog.deleteArtifacts(for: meetingID) }
            activeRecorder = nil
            statusMessage = "Opptaket ble avbrutt og den lokale lyden ble slettet."
        } catch {
            activeRecorder = nil
            statusMessage = "Opptaket ble stoppet, men oppryddingen feilet: \(error.localizedDescription)"
        }
        activeRecordingTitle = "Nytt lydopptak"
    }
    func refreshLiveTranscript() async {
        guard isRecording, !liveTranscriptionInFlight, elapsed >= 3 else { return }
        do {
            guard let snapshot = try activeRecorder?.snapshot() else { return }
            liveTranscriptionInFlight = true; liveStatus = "Tolker tale …"
            defer { liveTranscriptionInFlight = false; try? FileManager.default.removeItem(at: snapshot.url) }
            let segments = try await speechEngine.transcribe(audioAt: snapshot.url).map {
                TranscriptSegment(id: $0.id, start: $0.start + snapshot.startTime, end: $0.end + snapshot.startTime, speaker: $0.speaker, text: $0.text)
            }
            guard isRecording else { return }
            liveSegments.removeAll { $0.start >= snapshot.startTime }
            liveSegments.append(contentsOf: segments)
            liveSegments = liveSegments.enumerated().map { index, segment in
                TranscriptSegment(id: "live-\(index + 1)", start: segment.start, end: segment.end, speaker: segment.speaker, text: segment.text)
            }
            liveStatus = "Foreløpig tekst"
        } catch NBWhisperError.emptyTranscript {
            liveStatus = "Lytter …"
        } catch {
            liveStatus = "Direktetekst er midlertidig utilgjengelig"
        }
    }
    func copy(_ text: String, message: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); statusMessage = message }
    func testIDUNConnection() {
        guard !isProcessing, !isRecording, !isTestingIDUN else { return }
        isTestingIDUN = true; idunTestMessage = "Kontakter IDUN …"; idunTestSucceeded = false
        Task {
            defer { isTestingIDUN = false }
            do {
                let result = try await IDUNConnectionCheck.run()
                idunTestSucceeded = true
                idunTestMessage = result.message
                if showOnboarding { showOnboarding = false }
            } catch let error as URLError {
                idunTestMessage = "Nettverksfeil mot IDUN: \(error.localizedDescription)"
            } catch {
                idunTestMessage = error.localizedDescription
            }
        }
    }
    func logOutOfIDUN() {
        guard !isProcessing, !isRecording, !isTestingIDUN else {
            statusMessage = "Stopp pågående opptak eller IDUN-forespørsel før du logger ut."
            return
        }
        do {
            try IDUNKeychain().delete()
            onboardingAPIKey = ""
            onboardingNetworkConfirmed = false
            idunTestMessage = nil
            idunTestSucceeded = false
            showOnboarding = true
        } catch {
            statusMessage = error.localizedDescription
        }
    }
    func saveAndTestOnboardingKey() {
        let key = onboardingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, onboardingNetworkConfirmed, !isTestingIDUN else { return }
        do {
            try IDUNKeychain().save(key)
            onboardingAPIKey = ""
            testIDUNConnection()
        } catch {
            idunTestSucceeded = false
            idunTestMessage = error.localizedDescription
        }
    }
    func importTextDocument() {
        guard !isProcessing, !isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "Velg et tekstdokument"
        panel.prompt = "Importer tekst"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "md")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try ImportedTextDocument.read(from: url)
            let meeting = Meeting(id: UUID(), title: url.deletingPathExtension().lastPathComponent, date: .now, duration: 0, state: .transcriptReady, transcript: try ImportedTextDocument.segments(from: text), analysis: nil)
            meetings.insert(meeting, at: 0); selection = meeting.id
            try repository.save(meeting)
            statusMessage = "Teksten er importert og klar for oppsummering."
        } catch { statusMessage = error.localizedDescription }
    }
    func importAudioFile() {
        guard !isProcessing, !isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "Velg en lydfil"
        panel.prompt = "Importer lyd"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isProcessing = true
        statusMessage = "Klargjør og transkriberer lydfilen lokalt …"
        Task {
            var converted: URL?
            defer { if let converted { try? FileManager.default.removeItem(at: converted) }; isProcessing = false }
            do {
                converted = try await ImportedAudioConverter.convertToWhisperWAV(source)
                let segments = try await speechEngine.transcribe(audioAt: converted!)
                let meeting = Meeting(id: UUID(), title: source.deletingPathExtension().lastPathComponent, date: .now, duration: segments.last?.end ?? 0, state: .transcriptReady, transcript: segments, analysis: nil)
                meetings.insert(meeting, at: 0); selection = meeting.id
                try repository.save(meeting)
                statusMessage = "Lydfilen er transkribert lokalt og klar for oppsummering."
            } catch { statusMessage = error.localizedDescription }
        }
    }
    func analyze(_ meeting: Meeting) {
        guard !isProcessing, let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        let meetingID = meeting.id
        let requestMeeting = meeting
        let selectedAnalysisMode = analysisMode
        isProcessing = true; meetings[index].state = .analyzing
        try? repository.save(meetings[index])
        analyzingMeetingID = meetingID; analysisStage = .preparing; analysisStartedAt = .now
        statusMessage = selectedAnalysisMode == .borealisFirst ? "Prøver Borealis via NTNU IDUN …" : "Sender transkripsjonen til NTNU IDUN for oppsummering …"
        Task {
            do {
                analysisStage = .awaitingIDUN
                let outcome = try await analysisProvider.analyzeWithOutcome(meeting: requestMeeting, mode: selectedAnalysisMode) { self.analysisStage = .processingResponse }
                let analysis = outcome.analysis
                guard let currentIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { analyzingMeetingID = nil; analysisStartedAt = nil; isProcessing = false; return }
                meetings[currentIndex].analysis = analysis; meetings[currentIndex].state = .completed
                try repository.save(meetings[currentIndex])
                if selectedAnalysisMode == .borealisFirst, outcome.model != .borealis {
                    statusMessage = "Borealis kunne ikke valideres. Oppsummeringen ble trygt laget med \(outcome.model.displayName)."
                } else {
                    statusMessage = "Oppsummeringen er klar med \(outcome.model.displayName): hva som ble sagt og hva som ble bestemt å gjøre."
                }
            } catch {
                if let currentIndex = meetings.firstIndex(where: { $0.id == meetingID }) {
                    meetings[currentIndex].state = .completedWithoutAnalysis
                    try? repository.save(meetings[currentIndex])
                }
                statusMessage = error.localizedDescription
            }
            analyzingMeetingID = nil; analysisStartedAt = nil
            isProcessing = false
        }
    }
    func renameSpeaker(in meetingID: UUID, segmentID: String, to newName: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              let segment = meetings[index].transcript.first(where: { $0.id == segmentID }) else { return }
        meetings[index].renameSpeaker(from: segment.speaker ?? "Ukjent", to: newName)
        do {
            try repository.save(meetings[index])
            statusMessage = "Talernavnet er oppdatert i hele møtet."
        } catch {
            statusMessage = "Talernavnet kunne ikke lagres: \(error.localizedDescription)"
        }
    }
    func deleteSelected() {
        guard let selection else { return }
        do {
            try repository.delete(selection)
            try recordingCatalog.deleteArtifacts(for: selection)
            meetings.removeAll { $0.id == selection }
            self.selection = meetings.first?.id
        } catch { statusMessage = "Møtet kunne ikke slettes: \(error.localizedDescription)" }
    }
    func deleteAll() {
        do {
            try repository.deleteAll()
            try recordingCatalog.deleteAllArtifacts()
            meetings = []; selection = nil
            statusMessage = "Alle lokale møter er slettet."
        } catch { statusMessage = "Møtene kunne ikke slettes: \(error.localizedDescription)" }
    }

    private func recoverInterruptedRecordings() async {
        let artifacts = recordingCatalog.pendingArtifacts().filter { artifact in
            !meetings.contains(where: { $0.id == artifact.meetingID })
        }
        guard !artifacts.isEmpty, !isRecording else { return }
        isProcessing = true
        statusMessage = artifacts.count == 1
            ? "Gjenoppretter et avbrutt opptak …"
            : "Gjenoppretter \(artifacts.count) avbrutte opptak …"
        var recoveredCount = 0
        for artifact in artifacts {
            do {
                let segments = try await SegmentedTranscriber(engine: speechEngine).transcribe(artifact)
                let meeting = Meeting(
                    id: artifact.meetingID,
                    title: "Gjenopprettet opptak",
                    date: artifact.createdAt,
                    duration: artifact.duration,
                    state: .transcriptReady,
                    transcript: segments,
                    analysis: nil
                )
                try repository.save(meeting)
                try recordingCatalog.markTranscriptionSucceeded(for: artifact.meetingID)
                meetings.insert(meeting, at: 0)
                recoveredCount += 1
            } catch {
                statusMessage = "Et avbrutt opptak er fortsatt trygt lagret: \(error.localizedDescription)"
            }
        }
        if recoveredCount > 0 {
            selection = meetings.first?.id
            statusMessage = recoveredCount == 1
                ? "Et avbrutt opptak ble gjenopprettet."
                : "\(recoveredCount) avbrutte opptak ble gjenopprettet."
        }
        isProcessing = false
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmLogout = false
    private let canvas = SparkPalette.paper
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 7) { Text("Spark*").font(.system(size: 23, weight: .bold, design: .rounded)); Text("NTNU").font(.system(size: 15, weight: .semibold)); Spacer(); Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Lyd behandles lokalt"); Menu { Button("Logg ut av IDUN", systemImage: "rectangle.portrait.and.arrow.right") { confirmLogout = true }.disabled(store.isProcessing || store.isRecording || store.isTestingIDUN) } label: { Image(systemName: "person.crop.circle").font(.system(size: 16)).frame(width: 28, height: 28).contentShape(Rectangle()) }.menuStyle(.borderlessButton).help("Konto og onboarding") }.padding(.horizontal, 20).padding(.top, 19)
                HStack(spacing: 7) { Text("veilederverktøy"); Text("v0.16.0").padding(.horizontal, 7).padding(.vertical, 2).background(SparkPalette.mist, in: Capsule()); Spacer() }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 16)
                recordingPanel.padding(.horizontal, 14).padding(.bottom, 16)
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Søk i møter", text: $store.search).textFieldStyle(.plain) }.padding(.horizontal, 13).frame(height: 38).background(.white, in: Capsule()).overlay(Capsule().stroke(SparkPalette.stone)).padding(.horizontal, 14).padding(.bottom, 10)
                List(store.filtered, selection: $store.selection) { meeting in MeetingRow(meeting: meeting).tag(meeting.id) }.listStyle(.sidebar)
            }.background(SparkPalette.paper).navigationSplitViewColumnWidth(min: 280, ideal: 310, max: 350)
        } detail: {
            ZStack { canvas.ignoresSafeArea(); if let meeting = store.selected { MeetingDetail(meeting: meeting) } else { ContentUnavailableView("Ingen møter ennå", systemImage: "waveform", description: Text("Start et møte for å bygge ditt lokale arkiv.")) } }
        }.foregroundStyle(SparkPalette.ink).tint(SparkPalette.ink)
            .overlay(alignment: .bottomTrailing) { if store.isRecording { LiveTranscriptPanel(segments: store.liveSegments, status: store.liveStatus).padding(22) } }
            .overlay(alignment: .bottom) { if let status = store.statusMessage { Toast(text: status).padding(.bottom, 18) } }
            .overlay { if store.showOnboarding { OnboardingView() .environmentObject(store) } }
            .confirmationDialog("Logg ut av IDUN?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Logg ut og åpne onboarding", role: .destructive) { store.logOutOfIDUN() }
                Button("Avbryt", role: .cancel) { }
            } message: {
                Text("API-nøkkelen fjernes fra macOS Keychain. Møtenotater og opptak blir beholdt.")
            }
    }
    private var recordingPanel: some View {
        VStack(spacing: 12) {
            HStack { Text("Nytt opptak").font(.subheadline.weight(.semibold)); Spacer(); Label("NB-Whisper klar", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.secondary) }
            if let meeting = store.detectedMeeting {
                VStack(alignment: .leading, spacing: 8) {
                    Label(meeting.kind.detectionTitle, systemImage: "video.fill").font(.caption.weight(.semibold)).foregroundStyle(SparkPalette.ink)
                    Text("Velg mikrofon eller mikrofon + systemlyd. macOS kan be om opptakstillatelse første gang.").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button("Ikke nå") { store.dismissDetectedMeeting() }
                        Spacer()
                        Button("Start opptak") { Task { await store.acceptDetectedMeeting() } }.buttonStyle(.borderedProminent).tint(SparkPalette.orange)
                    }
                }
                .padding(11)
                .background(SparkPalette.mist, in: RoundedRectangle(cornerRadius: 13))
            }
            Picker("Lydkilde", selection: $store.audioMode) { ForEach(AppStore.AudioMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented)
            if store.isRecording {
                Label(store.audioMode == .digital ? "Tar opp mikrofon og møtelyd" : "Tar opp mikrofon", systemImage: store.audioMode == .digital ? "macbook.and.iphone" : "mic.fill")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { store.toggleRecording() } label: { HStack(spacing: 10) { Image(systemName: store.isProcessing ? "ellipsis" : (store.isRecording ? "stop.fill" : "waveform")); Text(store.isProcessing ? "Transkriberer …" : (store.isRecording ? "Stopp  \(format(store.elapsed))" : "Start møte")).fontWeight(.semibold); if store.isRecording { MiniWaveform() } }.frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(store.isRecording ? SparkPalette.orange : SparkPalette.ink).disabled(store.isProcessing)
            HStack(spacing: 8) {
                Button("Importer tekst", systemImage: "doc.text") { store.importTextDocument() }
                Button("Importer lydfil", systemImage: "waveform.badge.plus") { store.importAudioFile() }
            }.buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(store.isProcessing || store.isRecording)
            Button { store.testIDUNConnection() } label: {
                HStack {
                    if store.isTestingIDUN { ProgressView().controlSize(.small) }
                    else { Image(systemName: "network") }
                    Text(store.isTestingIDUN ? "Tester IDUN …" : "Test IDUN-tilkobling")
                    Spacer()
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(store.isProcessing || store.isRecording || store.isTestingIDUN)
            VStack(alignment: .leading, spacing: 5) {
                Picker("Analysemodell", selection: $store.analysisMode) {
                    ForEach(IDUNAnalysisMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.menu).disabled(store.isProcessing || store.isRecording)
                Text(store.analysisMode.detail).font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let message = store.idunTestMessage {
                Label(message, systemImage: store.idunTestSucceeded ? "checkmark.circle.fill" : (store.isTestingIDUN ? "clock" : "exclamationmark.triangle.fill"))
                    .font(.caption2).foregroundStyle(store.idunTestSucceeded ? Color.green : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 9) { Text("⌘").font(.caption.weight(.bold)).frame(width: 24, height: 24).background(SparkPalette.mist, in: RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading, spacing: 1) { Text("Hurtigdiktering").font(.caption.weight(.semibold)); Text(store.dictationStatus.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }; Spacer() }
            HStack(spacing: 9) {
                Text("⌥").font(.caption.weight(.bold)).frame(width: 24, height: 24).background(SparkPalette.mist, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Møteopptak").font(.caption.weight(.semibold))
                    Text("Høyre Option: start/fullfør · dobbelttrykk: avbryt").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
        }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(SparkPalette.stone)).shadow(color: .black.opacity(0.04), radius: 14, y: 6)
    }
    private func format(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

private struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @State private var logoVisible = false
    private let keyRequestURL = URL(string: "https://ai.hpc.ntnu.no/request-api-key")!

    var body: some View {
        ZStack {
            SparkPalette.paper.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle().fill(SparkPalette.mist).frame(width: 82, height: 82)
                            Text("✱").font(.system(size: 51, weight: .bold, design: .rounded)).foregroundStyle(SparkPalette.orange)
                        }
                        .scaleEffect(logoVisible ? 1 : 0.55).opacity(logoVisible ? 1 : 0)
                        .animation(.spring(response: 0.7, dampingFraction: 0.62), value: logoVisible)
                        Text("Spark* NTNU").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("La oss gjøre klart for møtereferatene dine.").font(.title3).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Koble til eduroam eller NTNU VPN", systemImage: "wifi")
                            .font(.headline)
                        Text("IDUN er kun tilgjengelig fra NTNU-nettverket. Koble til før du fortsetter.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("Jeg er koblet til eduroam eller VPN", isOn: $store.onboardingNetworkConfirmed)
                            .toggleStyle(.checkbox)
                        Divider()
                        Label("Hent din personlige API-nøkkel", systemImage: "key.horizontal")
                            .font(.headline)
                        Text("Be om en nøkkel hos NTNU, kopier den og lim den inn her. Spark lagrer den kryptert i macOS Keychain.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button { NSWorkspace.shared.open(keyRequestURL) } label: {
                            Label("Hent API-nøkkel fra NTNU", systemImage: "arrow.up.right.square")
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                        }
                        .buttonStyle(.bordered).tint(SparkPalette.ink)
                        SecureField("Lim inn API-nøkkel", text: $store.onboardingAPIKey)
                            .textFieldStyle(.roundedBorder)
                        if let message = store.idunTestMessage {
                            Label(message, systemImage: store.idunTestSucceeded ? "checkmark.circle.fill" : (store.isTestingIDUN ? "clock" : "exclamationmark.triangle.fill"))
                                .font(.callout).foregroundStyle(store.idunTestSucceeded ? Color.green : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            store.saveAndTestOnboardingKey()
                        } label: {
                            HStack {
                                if store.isTestingIDUN { ProgressView().controlSize(.small) }
                                Text(store.isTestingIDUN ? "Tester tilkoblingen …" : "Lagre og koble til")
                            }.frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(SparkPalette.orange)
                        .disabled(!store.onboardingNetworkConfirmed || store.onboardingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isTestingIDUN)
                    }
                    .padding(24).frame(maxWidth: 480, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(SparkPalette.stone))
                    .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
                    Text("Lyd transkriberes lokalt. Bare møtets tekst sendes til IDUN for oppsummering.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 34).padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { logoVisible = true }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(meeting.title).font(.system(size: 14, weight: .medium)).lineLimit(2); HStack { Text(meeting.date, format: .dateTime.day().month(.abbreviated)); Spacer(); Text("\(Int(meeting.duration) / 60) min"); Image(systemName: meeting.state == .completed ? "checkmark.circle.fill" : "clock") }.font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 7) }
}

struct MeetingDetail: View {
    @EnvironmentObject private var store: AppStore
    let meeting: Meeting
    @State private var showTranscript = true
    @State private var confirmIDUN = false
    @State private var confirmDeleteAll = false
    @State private var selectedTab = DetailTab.notes
    @State private var focusedSegmentID: String?
    @State private var proposedSpeakerName = ""
    enum DetailTab: String, CaseIterable, Identifiable { case notes = "Møtenotat", todos = "Gjøremål", base = "Kopier til basen"; var id: Self { self } }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    Picker("Visning", selection: $selectedTab) { ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 520)
                    if let segment = focusedSegment {
                        EvidenceFocusPanel(segment: segment, proposedSpeakerName: $proposedSpeakerName) {
                            store.renameSpeaker(in: meeting.id, segmentID: segment.id, to: proposedSpeakerName)
                        }.id("evidence-focus")
                    }
                    if store.analyzingMeetingID == meeting.id, let startedAt = store.analysisStartedAt { AnalysisProgressPanel(stage: store.analysisStage, startedAt: startedAt, meeting: meeting) }
                    tabContent(proxy: proxy)
                }.padding(.horizontal, 48).padding(.vertical, 38).frame(maxWidth: 900, alignment: .leading)
            }
        }
    }
    private var focusedSegment: TranscriptSegment? {
        guard let focusedSegmentID else { return nil }
        return meeting.transcript.first(where: { $0.id == focusedSegmentID })
    }
    @ViewBuilder private func tabContent(proxy: ScrollViewProxy) -> some View {
        switch selectedTab {
        case .notes:
            if let analysis = meeting.analysis {
                SectionBlock(title: "Oppsummering", icon: "text.alignleft") { Text(analysis.summary).font(.system(size: 17)).lineSpacing(5).textSelection(.enabled) }
                SectionBlock(title: "Dette ble diskutert", icon: "sparkles") { ItemList(items: analysis.keyPoints.map(\.text)) }
                SectionBlock(title: "Beslutninger", icon: "checkmark.seal") { EvidenceList(items: analysis.decisions, transcript: meeting.transcript) { focusEvidence($0, proxy: proxy) } }
                SectionBlock(title: "Åpne spørsmål", icon: "questionmark.bubble") { ItemList(items: analysis.openQuestions.map(\.text)) }
            }
            transcript
        case .todos:
            if let items = meeting.analysis?.actionItems, !items.isEmpty {
                SectionBlock(title: "Gjøremål", icon: "checklist") { ForEach(items) { item in CopyableActionRow(item: item) { focusEvidence(item.evidenceSegmentIDs, proxy: proxy) } } }
            } else { ContentUnavailableView("Ingen gjøremål", systemImage: "checklist", description: Text("Oppsummer møtet for å hente ut avtalte gjøremål.")) }
        case .base:
            SectionBlock(title: "Klar for basen", icon: "doc.on.clipboard") {
                Text(BaseEntryExporter.render(meeting)).lineSpacing(5).textSelection(.enabled)
                Button("Kopier hele teksten", systemImage: "doc.on.doc") { store.copy(BaseEntryExporter.render(meeting), message: "Møtenotatet er kopiert og klart for basen.") }.buttonStyle(.borderedProminent).tint(SparkPalette.orange)
            }
        }
    }
    private func focusEvidence(_ evidenceIDs: [String], proxy: ScrollViewProxy) {
        guard let target = EvidenceNavigator.targetSegmentID(for: evidenceIDs, in: meeting.transcript),
              let segment = meeting.transcript.first(where: { $0.id == target }) else { return }
        focusedSegmentID = target
        proposedSpeakerName = segment.speaker ?? "Ukjent"
        withAnimation { proxy.scrollTo("evidence-focus", anchor: .center) }
    }
    private var transcript: some View { DisclosureGroup(isExpanded: $showTranscript) { ContinuousTranscriptView(segments: meeting.transcript).padding(.top, 14) } label: { Label("Transkripsjon", systemImage: "quote.bubble").font(.title3.weight(.semibold)) } }
    private var header: some View {
        VStack(alignment: .leading, spacing: 17) { HStack(alignment: .top) { VStack(alignment: .leading, spacing: 7) { HStack(alignment: .firstTextBaseline, spacing: 7) { Text(meeting.title).font(.system(size: 30, weight: .bold, design: .rounded)); Text("✱").foregroundStyle(SparkPalette.orange) }; Text(meeting.date, format: .dateTime.weekday(.wide).day().month(.wide).year()).foregroundStyle(.secondary) }; Spacer(); Menu { Button("Slett møte", role: .destructive) { store.deleteSelected() }; Button("Slett alle møter …", role: .destructive) { confirmDeleteAll = true } } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32).background(.white, in: Circle()).overlay(Circle().stroke(SparkPalette.stone)) }.menuStyle(.borderlessButton) }; HStack { if meeting.analysis == nil { Button("Oppsummer møte", systemImage: "sparkles") { confirmIDUN = true }.buttonStyle(.borderedProminent).tint(SparkPalette.orange).disabled(store.isProcessing) }; Button("Kopier oppsummering", systemImage: "doc.on.doc") { store.copy(meeting.analysis?.summary ?? "", message: "Oppsummeringen er kopiert.") }.disabled(meeting.analysis == nil); Button("Kopier gjøremål", systemImage: "checklist") { store.copy(meeting.defaultActionItemsText, message: "Gjøremål med tilstrekkelig sikkerhet er kopiert.") }.disabled(meeting.analysis == nil); Button("Kopier alt", systemImage: "doc.on.clipboard") { store.copy(MarkdownExporter.render(meeting), message: "Hele møtenotatet er kopiert.") } }.buttonStyle(.bordered).buttonBorderShape(.capsule) }
            .confirmationDialog("Oppsummer møte med NTNU IDUN?", isPresented: $confirmIDUN, titleVisibility: .visible) {
                Button("Send og oppsummer") { store.analyze(meeting) }
                Button("Avbryt", role: .cancel) { }
            } message: { Text(store.analysisMode == .borealisFirst ? "Bare transkripsjon og møtemetadata sendes først til Borealis. Hvis svaret ikke kan valideres, brukes den sikre automatiske IDUN-ruten. Rå lyd forlater ikke maskinen." : "Bare transkripsjon og møtemetadata sendes til en automatisk valgt IDUN-modell. Rå lyd forlater ikke maskinen.") }
            .confirmationDialog("Slett alle lokale møter?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Slett alle møter", role: .destructive) { store.deleteAll() }
                Button("Avbryt", role: .cancel) { }
            } message: { Text("Dette fjerner transkripsjoner og oppsummeringer fra denne maskinen.") }
    }
}

struct SectionBlock<Content: View>: View { let title: String; let icon: String; @ViewBuilder let content: Content; var body: some View { VStack(alignment: .leading, spacing: 13) { HStack(spacing: 9) { Image(systemName: icon).foregroundStyle(SparkPalette.orange); Text(title) }.font(.title3.weight(.semibold)); content }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(SparkPalette.stone.opacity(0.85))) } }

struct AnalysisProgressPanel: View {
    let stage: AnalysisStage
    let startedAt: Date
    let meeting: Meeting
    @State private var showRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(SparkPalette.orange)
                Text(stage.title).font(.headline)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedString(at: context.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(stage.detail).font(.subheadline).foregroundStyle(.secondary)
            IndeterminateProgressBar().frame(height: 7)
            Text("Fremdriften er ubestemt – IDUN sender ikke løpende prosent eller deltekst.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Se prompt og tekst som sendes", isExpanded: $showRequest) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Instruksjoner til modellen").font(.caption.weight(.semibold))
                    Text(MeetingPrompt.system).font(.caption).textSelection(.enabled)
                    Text("Møtekontekst og transkripsjon").font(.caption.weight(.semibold))
                    Text(MeetingPrompt.user(meeting: meeting)).font(.caption).textSelection(.enabled)
                }.padding(.top, 12)
            }.font(.caption)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(SparkPalette.mist, in: RoundedRectangle(cornerRadius: 22))
            .accessibilityElement(children: .contain)
    }

    private func elapsedString(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct IndeterminateProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(SparkPalette.stone).overlay(alignment: .leading) {
                Capsule().fill(SparkPalette.orange).frame(width: max(35, geometry.size.width * 0.32))
                    .offset(x: moving ? geometry.size.width : -geometry.size.width * 0.32)
            }.clipShape(Capsule())
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { moving = true }
                }
        }
    }
}
struct ItemList: View { let items: [String]; var body: some View { VStack(alignment: .leading, spacing: 10) { ForEach(items, id: \.self) { Label($0, systemImage: "circle.fill").labelStyle(BulletStyle()) } } } }
struct BulletStyle: LabelStyle { func makeBody(configuration: Configuration) -> some View { HStack(alignment: .firstTextBaseline, spacing: 10) { configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary); configuration.title } } }
struct EvidenceList: View {
    let items: [EvidenceItem]
    let transcript: [TranscriptSegment]
    let onShowEvidence: ([String]) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.text)
                    Button {
                        onShowEvidence(item.evidenceSegmentIDs)
                    } label: {
                        Label(item.evidenceSegmentIDs.compactMap { id in
                            transcript.first(where: { $0.id == id }).map { "\($0.timestamp) \($0.speaker ?? "Ukjent")" }
                        }.joined(separator: ", "), systemImage: "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(SparkPalette.orange)
                }
            }
        }
    }
}
struct ActionRow: View { let item: ActionItem; var body: some View { HStack(alignment: .top, spacing: 12) { Image(systemName: item.confidence == .low ? "questionmark.circle" : "circle").foregroundStyle(item.confidence == .low ? .orange : .secondary); VStack(alignment: .leading, spacing: 5) { Text(item.task).foregroundStyle(item.confidence == .low ? .secondary : .primary); HStack { if let owner = item.owner { Label(owner, systemImage: "person") }; if let deadline = item.deadline { Label(deadline, systemImage: "calendar") }; if item.confidence == .low { Text("Usikkert") } }.font(.caption).foregroundStyle(.secondary) } } } }
struct CopyableActionRow: View {
    @EnvironmentObject private var store: AppStore
    let item: ActionItem
    let onShowEvidence: () -> Void
    var body: some View {
        HStack {
            ActionRow(item: item)
            Spacer()
            Button("Vis utsagn", systemImage: "quote.bubble") { onShowEvidence() }.labelStyle(.iconOnly).help("Vis utsagnet i transkripsjonen")
            Button("Kopier", systemImage: "doc.on.doc") { store.copy(item.task, message: "Gjøremålet er kopiert.") }.labelStyle(.iconOnly).help("Kopier gjøremål")
        }.padding(.vertical, 4)
    }
}
struct EvidenceFocusPanel: View {
    let segment: TranscriptSegment
    @Binding var proposedSpeakerName: String
    let onRename: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Kildeutsagn \(segment.timestamp)", systemImage: "quote.bubble.fill").font(.headline)
                Spacer()
                Text(segment.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(segment.text).font(.system(size: 17)).lineSpacing(4).textSelection(.enabled)
            HStack {
                TextField("Talernavn", text: $proposedSpeakerName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("Oppdater taler") { onRename() }.disabled(proposedSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
        }.padding(18).background(SparkPalette.mist, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(SparkPalette.orange.opacity(0.45)))
    }
}
struct TranscriptRow: View { let segment: TranscriptSegment; var body: some View { HStack(alignment: .top, spacing: 16) { Text(segment.timestamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .leading); VStack(alignment: .leading, spacing: 4) { Text(segment.speaker ?? "Ukjent").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Text(segment.text).textSelection(.enabled) }; Spacer() }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider() } } }
struct ContinuousTranscriptView: View {
    let segments: [TranscriptSegment]
    var body: some View {
        composedText.font(.system(size: 16)).lineSpacing(7).textSelection(.enabled).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(SparkPalette.stone))
    }
    private var composedText: Text {
        segments.enumerated().reduce(Text("")) { result, pair in
            let (index, segment) = pair
            let space = index == 0 ? Text("") : Text("  ")
            let marker = Text("[\(segment.timestamp)] ").font(.caption.monospacedDigit()).foregroundColor(SparkPalette.orange)
            let speaker = segment.speaker.map { Text("\($0): ").bold() } ?? Text("")
            return result + space + marker + speaker + Text(segment.text)
        }
    }
}
struct Toast: View { let text: String; var body: some View { Label(text, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 11).background(SparkPalette.ink, in: Capsule()).shadow(radius: 8, y: 3) } }
struct MiniWaveform: View { var body: some View { HStack(spacing: 2) { ForEach([8, 15, 11, 19, 9, 14], id: \.self) { height in Capsule().frame(width: 2, height: CGFloat(height)) } }.foregroundStyle(.white.opacity(0.9)).accessibilityLabel("Tar opp lyd") } }

struct LiveTranscriptPanel: View {
    let segments: [TranscriptSegment]
    let status: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) { Circle().fill(SparkPalette.orange).frame(width: 8, height: 8); Text("Direkte transkripsjon").font(.headline); Spacer(); Text(status).font(.caption).foregroundStyle(.secondary) }
            ScrollView { Text(segments.isEmpty ? "Begynn å snakke. Teksten vises her etter noen sekunder." : TranscriptFormatter.continuousText(segments)).foregroundStyle(segments.isEmpty ? .secondary : .primary).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 120)
            Text("Foreløpig tekst kan bli rettet når opptaket stoppes.").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(width: 430).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(SparkPalette.stone)).shadow(color: .black.opacity(0.16), radius: 20, y: 8)
    }
}
