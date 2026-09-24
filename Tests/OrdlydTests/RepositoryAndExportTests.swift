import XCTest
@testable import Ordlyd

final class RepositoryAndExportTests: XCTestCase {
    func testRepositoryRoundTripsMeetingWithoutDataLoss() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        let meeting = Meeting.sample
        try repository.save(meeting)
        XCTAssertEqual(try repository.loadAll(), [meeting])
    }

    func testDeleteMeetingRemovesAllAssociatedArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        try repository.save(.sample)
        try repository.delete(Meeting.sample.id)
        XCTAssertTrue(try repository.loadAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: Meeting.sample.id).path))
    }

    func testDeleteAllRemovesEveryMeetingAndRepositoryRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        try repository.save(.sample)
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
        try repository.save(.sample)
        let store = AppStore(repository: repository)
        XCTAssertEqual(store.meetings, [.sample])
        XCTAssertEqual(store.selection, Meeting.sample.id)
    }

    @MainActor
    func testDeletingSelectedMeetingPersistsAcrossNewStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recordingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = JSONMeetingRepository(root: root)
        try repository.save(.sample)
        let artifactDirectory = recordingRoot.appendingPathComponent(Meeting.sample.id.uuidString, isDirectory: true)
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
