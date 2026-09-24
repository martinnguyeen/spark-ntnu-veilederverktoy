import XCTest
@testable import Ordlyd

final class DomainTests: XCTestCase {
    func testStartingDictationFromIdleEntersListening() throws {
        var machine = DictationStateMachine()
        try machine.send(.shortcutDown)
        XCTAssertEqual(machine.state, .listening)
    }

    func testReleasingShortcutWhileListeningStartsProcessing() throws {
        var machine = DictationStateMachine()
        try machine.send(.shortcutDown)
        try machine.send(.shortcutUp)
        XCTAssertEqual(machine.state, .processing)
    }

    func testEscapeWhileListeningCancelsAndDeletesTemporaryAudio() throws {
        var machine = DictationStateMachine()
        try machine.send(.shortcutDown)
        try machine.send(.cancel)
        XCTAssertEqual(machine.state, .cancelled)
        XCTAssertTrue(machine.shouldDeleteTemporaryAudio)
    }

    func testMeetingCannotStartWhileAnotherMeetingIsRecording() throws {
        var machine = MeetingStateMachine()
        try machine.send(.start)
        XCTAssertThrowsError(try machine.send(.start))
        XCTAssertEqual(machine.state, .recording)
    }

    func testAnalysisFailurePreservesTranscriptReadyState() throws {
        var machine = MeetingStateMachine()
        try machine.send(.start)
        try machine.send(.stop)
        try machine.send(.finalized)
        try machine.send(.transcribed)
        try machine.send(.analyze)
        try machine.send(.analysisFailed)
        XCTAssertEqual(machine.state, .completedWithoutAnalysis)
    }

    func testUnknownEvidenceSegmentRejectsOnlyUnsupportedClaim() {
        let transcript = [TranscriptSegment(id: "s1", start: 0, end: 4, speaker: "Speaker 1", text: "Vi bestemte å sende utkastet.")]
        let analysis = MeetingAnalysis(
            summary: "Kort møte.", keyPoints: [],
            decisions: [
                EvidenceItem(text: "Utkastet sendes.", confidence: .high, evidenceSegmentIDs: ["s1"]),
                EvidenceItem(text: "Budsjettet dobles.", confidence: .high, evidenceSegmentIDs: ["missing"])
            ], actionItems: [], openQuestions: []
        )
        let result = AnalysisValidator.validate(analysis, against: transcript)
        XCTAssertEqual(result.analysis.decisions.map(\.text), ["Utkastet sendes."])
        XCTAssertEqual(result.rejectedClaims.count, 1)
    }

    func testMissingOwnerAndDeadlineRemainNull() throws {
        let json = #"{"schema_version":"1.0","summary":"Kort møte.","key_points":[],"decisions":[],"action_items":[{"task":"Les artikkelen.","owner":null,"deadline":null,"confidence":"medium","evidence_segment_ids":["s1"]}],"open_questions":[]}"#.data(using: .utf8)!
        let analysis = try JSONDecoder.snakeCase.decode(MeetingAnalysis.self, from: json)
        XCTAssertNil(analysis.actionItems[0].owner)
        XCTAssertNil(analysis.actionItems[0].deadline)
    }

    func testSuggestionIsNotMappedToDecision() {
        let transcript = [TranscriptSegment(id: "s1", start: 0, end: 3, speaker: nil, text: "Kanskje vi kan sende utkastet fredag?")]
        let analysis = MeetingAnalysis(summary: "", keyPoints: [], decisions: [EvidenceItem(text: "Utkastet sendes fredag.", confidence: .medium, evidenceSegmentIDs: ["s1"])], actionItems: [], openQuestions: [])
        let result = AnalysisValidator.validate(analysis, against: transcript)
        XCTAssertTrue(result.analysis.decisions.isEmpty)
    }

    func testRenamingSpeakerUpdatesAllMatchingSegmentsWithoutChangingEvidenceIDs() {
        var meeting = Meeting(
            id: UUID(), title: "Test", date: .now, duration: 8, state: .completed,
            transcript: [
                .init(id: "s1", start: 0, end: 3, speaker: "Ukjent", text: "Vi sender utkastet."),
                .init(id: "s2", start: 3, end: 6, speaker: "Martin", text: "Det gjør jeg."),
                .init(id: "s3", start: 6, end: 8, speaker: "Ukjent", text: "Flott.")
            ],
            analysis: .init(
                summary: "", keyPoints: [],
                decisions: [.init(text: "Utkastet sendes.", confidence: .high, evidenceSegmentIDs: ["s1"])],
                actionItems: [], openQuestions: []
            )
        )

        meeting.renameSpeaker(from: "Ukjent", to: "Veileder")

        XCTAssertEqual(meeting.transcript.map(\.speaker), ["Veileder", "Martin", "Veileder"])
        XCTAssertEqual(meeting.transcript.map(\.id), ["s1", "s2", "s3"])
        XCTAssertEqual(meeting.analysis?.decisions.first?.evidenceSegmentIDs, ["s1"])
    }

    func testEvidenceNavigationChoosesFirstExistingTranscriptSegment() {
        let transcript = [
            TranscriptSegment(id: "s1", start: 0, end: 2, speaker: nil, text: "En"),
            TranscriptSegment(id: "s2", start: 2, end: 4, speaker: nil, text: "To")
        ]

        XCTAssertEqual(EvidenceNavigator.targetSegmentID(for: ["missing", "s2", "s1"], in: transcript), "s2")
        XCTAssertNil(EvidenceNavigator.targetSegmentID(for: ["missing"], in: transcript))
    }
}
