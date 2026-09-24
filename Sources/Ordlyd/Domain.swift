import Foundation

enum DomainError: Error { case invalidTransition }

enum DictationState: Equatable { case idle, listening, processing, inserting, completed, cancelled, failed }
enum DictationEvent { case shortcutDown, shortcutUp, cancel, transcriptReady, inserted, reset, fail }

struct DictationStateMachine {
    private(set) var state: DictationState = .idle
    private(set) var shouldDeleteTemporaryAudio = false

    mutating func send(_ event: DictationEvent) throws {
        switch (state, event) {
        case (.idle, .shortcutDown): state = .listening
        case (.listening, .shortcutUp): state = .processing
        case (.listening, .cancel): state = .cancelled; shouldDeleteTemporaryAudio = true
        case (.processing, .transcriptReady): state = .inserting
        case (.inserting, .inserted): state = .completed
        case (.completed, .reset), (.cancelled, .reset), (.failed, .reset): state = .idle; shouldDeleteTemporaryAudio = false
        case (_, .fail): state = .failed
        default: throw DomainError.invalidTransition
        }
    }
}

enum MeetingState: String, Codable, Equatable {
    case idle, recording, finalizing, transcribing, transcriptReady, analyzing, completed, completedWithoutAnalysis
}
enum MeetingEvent { case start, stop, finalized, transcribed, analyze, analysisSucceeded, analysisFailed }

struct MeetingStateMachine {
    private(set) var state: MeetingState = .idle
    mutating func send(_ event: MeetingEvent) throws {
        switch (state, event) {
        case (.idle, .start): state = .recording
        case (.recording, .stop): state = .finalizing
        case (.finalizing, .finalized): state = .transcribing
        case (.transcribing, .transcribed): state = .transcriptReady
        case (.transcriptReady, .analyze): state = .analyzing
        case (.analyzing, .analysisSucceeded): state = .completed
        case (.analyzing, .analysisFailed): state = .completedWithoutAnalysis
        default: throw DomainError.invalidTransition
        }
    }
}

struct TranscriptSegment: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    var speaker: String?
    let text: String
    var timestamp: String { String(format: "%02d:%02d", Int(start) / 60, Int(start) % 60) }
}

enum TranscriptFormatter {
    static func continuousText(_ segments: [TranscriptSegment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum Confidence: String, Codable { case low, medium, high }

struct EvidenceItem: Codable, Equatable, Identifiable {
    var id: String { text }
    let text: String
    let confidence: Confidence?
    let evidenceSegmentIDs: [String]
    enum CodingKeys: String, CodingKey { case text, point, confidence; case evidenceSegmentIDs = "evidence_segment_ids" }
    init(text: String, confidence: Confidence?, evidenceSegmentIDs: [String]) { self.text = text; self.confidence = confidence; self.evidenceSegmentIDs = evidenceSegmentIDs }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? values.decode(String.self, forKey: .point)
        confidence = try values.decodeIfPresent(Confidence.self, forKey: .confidence)
        evidenceSegmentIDs = try values.decode([String].self, forKey: .evidenceSegmentIDs)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text); try values.encodeIfPresent(confidence, forKey: .confidence); try values.encode(evidenceSegmentIDs, forKey: .evidenceSegmentIDs)
    }
}

struct ActionItem: Codable, Equatable, Identifiable {
    var id: String { task }
    let task: String
    let owner: String?
    let deadline: String?
    let confidence: Confidence
    let evidenceSegmentIDs: [String]
    enum CodingKeys: String, CodingKey { case task, owner, deadline, confidence; case evidenceSegmentIDs = "evidence_segment_ids" }
}

struct OpenQuestion: Codable, Equatable, Identifiable {
    var id: String { text }
    let text: String
    let evidenceSegmentIDs: [String]
    enum CodingKeys: String, CodingKey { case text; case evidenceSegmentIDs = "evidence_segment_ids" }
}

struct MeetingAnalysis: Codable, Equatable {
    var schemaVersion = "1.0"
    let summary: String
    let keyPoints: [EvidenceItem]
    var decisions: [EvidenceItem]
    var actionItems: [ActionItem]
    let openQuestions: [OpenQuestion]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version"; case summary; case keyPoints = "key_points"; case decisions; case actionItems = "action_items"; case openQuestions = "open_questions" }
}

struct Meeting: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    let date: Date
    let duration: TimeInterval
    var state: MeetingState
    var transcript: [TranscriptSegment]
    var analysis: MeetingAnalysis?

    var defaultActionItemsText: String {
        analysis?.actionItems.filter { $0.confidence != .low }.map { "• \($0.task)" }.joined(separator: "\n") ?? ""
    }

    mutating func renameSpeaker(from oldName: String, to newName: String) {
        let replacement = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return }
        for index in transcript.indices where (transcript[index].speaker ?? "Ukjent") == oldName {
            transcript[index].speaker = replacement
        }
    }

    static let sample = Meeting(
        id: UUID(uuidString: "D1C4D4D1-8780-4812-94D0-B46CFA709C2C")!, title: "Veiledning – litteraturgjennomgang",
        date: Date(timeIntervalSince1970: 1_788_880_400), duration: 2_754, state: .completed,
        transcript: [
            .init(id: "s1", start: 8, end: 18, speaker: "Veileder", text: "Vi bestemmer at du sender det reviderte utkastet før fredag."),
            .init(id: "s2", start: 42, end: 55, speaker: "Martin", text: "Jeg strammer inn problemstillingen og legger ved søkeloggen."),
            .init(id: "s3", start: 91, end: 104, speaker: "Veileder", text: "Kanskje vi også bør avklare budsjettet senere.")
        ],
        analysis: .init(
            summary: "Problemstillingen skal avgrenses tydeligere, og søkeloggen skal følge neste utkast. Gruppen ble enige om levering før fredag.",
            keyPoints: [.init(text: "Søkeloggen må gjøre utvalget av litteratur etterprøvbart.", confidence: .high, evidenceSegmentIDs: ["s2"])],
            decisions: [.init(text: "Revidert utkast sendes før fredag.", confidence: .high, evidenceSegmentIDs: ["s1"])],
            actionItems: [
                .init(task: "Send revidert utkast", owner: "Martin", deadline: "Fredag", confidence: .high, evidenceSegmentIDs: ["s1", "s2"]),
                .init(task: "Avklar budsjett", owner: nil, deadline: nil, confidence: .low, evidenceSegmentIDs: ["s3"])
            ],
            openQuestions: [.init(text: "Hvordan skal budsjettet avklares?", evidenceSegmentIDs: ["s3"])]
        )
    )
}

enum EvidenceNavigator {
    static func targetSegmentID(for evidenceSegmentIDs: [String], in transcript: [TranscriptSegment]) -> String? {
        let available = Set(transcript.map(\.id))
        return evidenceSegmentIDs.first(where: available.contains)
    }
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder { JSONDecoder() }
}

struct ValidationResult { let analysis: MeetingAnalysis; let rejectedClaims: [String] }

enum AnalysisValidator {
    static func validate(_ input: MeetingAnalysis, against transcript: [TranscriptSegment]) -> ValidationResult {
        let ids = Set(transcript.map(\.id))
        var rejected: [String] = []
        let validDecisions = input.decisions.filter { item in
            guard item.evidenceSegmentIDs.allSatisfy(ids.contains) else { rejected.append(item.text); return false }
            let evidence = transcript.filter { item.evidenceSegmentIDs.contains($0.id) }.map(\.text).joined(separator: " ").lowercased()
            let tentative = ["kanskje", "muligens", "kan vi", "bør vi"].contains { evidence.contains($0) }
            if tentative { rejected.append(item.text); return false }
            return true
        }
        var output = input
        output.decisions = validDecisions
        output.actionItems = input.actionItems.filter { item in
            guard !item.evidenceSegmentIDs.isEmpty, item.evidenceSegmentIDs.allSatisfy(ids.contains) else { rejected.append(item.task); return false }
            return true
        }
        return ValidationResult(analysis: output, rejectedClaims: rejected)
    }
}

protocol SpeechEngine { func transcribe(audioAt url: URL) async throws -> [TranscriptSegment] }
protocol AnalysisProvider { func analyze(transcript: [TranscriptSegment]) async throws -> MeetingAnalysis }
