import XCTest
@testable import Ordlyd

final class RepositoryAndExportTests: XCTestCase {
    private func freshSample() -> Meeting {
        let sample = Meeting.sample
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        return Meeting(id: sample.id, title: sample.title, date: now, duration: sample.duration, state: sample.state, transcript: sample.transcript, analysis: sample.analysis)
    }

    func testRepositoryDeletesMeetingsAtFourteenDayRetentionDeadline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableMeetingRetentionClock(now: Date(timeIntervalSince1970: 2_000_000))
        let repository = JSONMeetingRepository(root: root, clock: clock)
        let expired = Meeting(id: UUID(), title: "Utløpt", date: clock.now.addingTimeInterval(-JSONMeetingRepository.retentionInterval), duration: 0, state: .transcriptReady, transcript: Meeting.sample.transcript, analysis: Meeting.sample.analysis)
        let current = Meeting(id: UUID(), title: "Fortsatt innen fristen", date: clock.now.addingTimeInterval(-JSONMeetingRepository.retentionInterval + 1), duration: 0, state: .transcriptReady, transcript: Meeting.sample.transcript, analysis: Meeting.sample.analysis)
        try repository.save(expired)
        try repository.save(current)

        XCTAssertEqual(try repository.loadAll(), [current])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: expired.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.directory(for: current.id).path))
    }

    @MainActor
    func testAppStartupAlsoDeletesExpiredMeetingRecoveryAudio() throws {
        let meetingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recordingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: meetingRoot)
            try? FileManager.default.removeItem(at: recordingRoot)
        }
        var meeting = freshSample()
        meeting = Meeting(id: meeting.id, title: meeting.title, date: .now.addingTimeInterval(-JSONMeetingRepository.retentionInterval), duration: meeting.duration, state: meeting.state, transcript: meeting.transcript, analysis: meeting.analysis)
        let repository = JSONMeetingRepository(root: meetingRoot)
        try repository.save(meeting)
        let artifactDirectory = recordingRoot.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        try Data("expired audio".utf8).write(to: artifactDirectory.appendingPathComponent("segment.wav"))

        let store = AppStore(repository: repository, enableBackgroundRecovery: false, recordingRootDirectory: recordingRoot)

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
    }

    func testRepositoryRoundTripsMeetingWithoutDataLoss() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        let meeting = freshSample()
        try repository.save(meeting)
        XCTAssertEqual(try repository.loadAll(), [meeting])
    }

    func testDeleteMeetingRemovesAllAssociatedArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        let meeting = freshSample()
        try repository.save(meeting)
        try repository.delete(meeting.id)
        XCTAssertTrue(try repository.loadAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: meeting.id).path))
    }

    func testDeleteAllRemovesEveryMeetingAndRepositoryRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        try repository.save(freshSample())
        var second = Meeting.sample
        second = Meeting(id: UUID(), title: "Andre møte", date: second.date, duration: second.duration, state: second.state, transcript: second.transcript, analysis: second.analysis)
        try repository.save(second)
        try repository.deleteAll()
        XCTAssertTrue(try repository.loadAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMeetingSearchMatchesTranscriptAndAnalysisContent() {
        XCTAssertTrue(MeetingSearch.matches(.sample, query: "søkeloggen"))
        XCTAssertTrue(MeetingSearch.matches(.sample, query: "budsjettet"))
        XCTAssertFalse(MeetingSearch.matches(.sample, query: "uvedkommende"))
    }

    @MainActor
    func testAppStoreLoadsPersistedMeetingsInsteadOfSampleData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        let meeting = freshSample()
        try repository.save(meeting)
        let store = AppStore(repository: repository)
        XCTAssertEqual(store.meetings, [meeting])
        XCTAssertEqual(store.selection, meeting.id)
    }

    @MainActor
    func testDeletingSelectedMeetingPersistsAcrossNewStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recordingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        let meeting = freshSample()
        try repository.save(meeting)
        let artifactDirectory = recordingRoot.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: artifactDirectory.appendingPathComponent("segment.wav"))
        let store = AppStore(repository: repository, recordingRootDirectory: recordingRoot)
        store.deleteSelected()
        XCTAssertTrue(AppStore(repository: repository, recordingRootDirectory: recordingRoot).meetings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
    }

    func testMarkdownExportIncludesSummaryActionsAndTimestampedTranscript() {
        let markdown = MarkdownExporter.render(.sample)
        XCTAssertTrue(markdown.contains("## Oppsummering"))
        XCTAssertTrue(markdown.contains("- [ ] Send revidert utkast"))
        XCTAssertTrue(markdown.contains("[00:08] Veileder"))
    }

    func testLowConfidenceActionIsExcludedFromDefaultCopy() {
        XCTAssertFalse(Meeting.sample.defaultActionItemsText.contains("Avklar budsjett"))
        XCTAssertTrue(Meeting.sample.defaultActionItemsText.contains("Send revidert utkast"))
    }


    func testBaseEntryExportIsReadyToPasteAndExcludesUncertainTodos() {
        let text = BaseEntryExporter.render(.sample)
        XCTAssertTrue(text.contains("Dette ble diskutert"))
        XCTAssertTrue(text.contains("Beslutninger"))
        XCTAssertTrue(text.contains("To-Do"))
        XCTAssertTrue(text.contains("Send revidert utkast (Martin – Fredag)"))
        XCTAssertFalse(text.contains("Avklar budsjett"))
    }
}

private final class MutableMeetingRetentionClock: MeetingRetentionClock {
    var now: Date
    init(now: Date) { self.now = now }
}
