import Foundation

protocol MeetingRetentionClock {
    var now: Date { get }
}

struct SystemMeetingRetentionClock: MeetingRetentionClock {
    var now: Date { .now }
}

protocol MeetingRepository {
    func loadAll() throws -> [Meeting]
    func purgeExpired() throws -> [UUID]
    func save(_ meeting: Meeting) throws
    func delete(_ id: UUID) throws
    func deleteAll() throws
}

struct JSONMeetingRepository: MeetingRepository {
    static let retentionInterval: TimeInterval = 14 * 24 * 60 * 60
    let root: URL
    private let clock: any MeetingRetentionClock
    static var applicationDefault: JSONMeetingRepository {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONMeetingRepository(root: support.appendingPathComponent("Ordlyd/Meetings", isDirectory: true))
    }
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }()
    private let decoder: JSONDecoder = { let value = JSONDecoder.snakeCase; value.dateDecodingStrategy = .iso8601; return value }()

    init(root: URL, clock: any MeetingRetentionClock = SystemMeetingRetentionClock()) {
        self.root = root
        self.clock = clock
    }
    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func loadAll() throws -> [Meeting] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        _ = try? purgeExpired()
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var meetings: [Meeting] = []
        let now = clock.now
        for folder in folders {
            let meetingURL = folder.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: meetingURL),
                  let meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            guard now.timeIntervalSince(meeting.date) < Self.retentionInterval else {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            meetings.append(meeting)
        }
        return meetings.sorted { $0.date > $1.date }
    }

    @discardableResult
    func purgeExpired() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var deleted: [UUID] = []
        let now = clock.now
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")),
                  let meeting = try? decoder.decode(Meeting.self, from: data),
                  now.timeIntervalSince(meeting.date) >= Self.retentionInterval else { continue }
            do {
                try FileManager.default.removeItem(at: folder)
                deleted.append(id)
            } catch {
                continue
            }
        }
        return deleted
    }

    func save(_ meeting: Meeting) throws {
        let folder = directory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(meeting).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
    }

    func delete(_ id: UUID) throws {
        let folder = directory(for: id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

enum MeetingSearch {
    static func matches(_ meeting: Meeting, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        var values = [meeting.title]
        values += meeting.transcript.flatMap { [$0.speaker ?? "", $0.text] }
        if let analysis = meeting.analysis {
            values.append(analysis.summary)
            values += analysis.keyPoints.map(\.text)
            values += analysis.decisions.map(\.text)
            values += analysis.actionItems.flatMap { [$0.task, $0.owner ?? "", $0.deadline ?? ""] }
            values += analysis.openQuestions.map(\.text)
        }
        return values.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

enum MarkdownExporter {
    static func render(_ meeting: Meeting) -> String {
        var lines = ["# \(meeting.title)", "", "## Oppsummering", "", meeting.analysis?.summary ?? "Ingen oppsummering.", ""]
        if let analysis = meeting.analysis {
            lines += ["## Beslutninger", ""] + analysis.decisions.map { "- \($0.text)" } + [""]
            lines += ["## Gjøremål", ""] + analysis.actionItems.map { item in
                let details = [item.owner, item.deadline].compactMap { $0 }.joined(separator: " – ")
                return "- [ ] \(item.task)\(details.isEmpty ? "" : " (\(details))")"
            } + [""]
        }
        lines += ["## Transkripsjon", ""] + meeting.transcript.map { "[\($0.timestamp)] \($0.speaker ?? "Ukjent"): \($0.text)" }
        return lines.joined(separator: "\n")
    }
}

enum BaseEntryExporter {
    static func render(_ meeting: Meeting) -> String {
        guard let analysis = meeting.analysis else { return meeting.title }
        let date = meeting.date.formatted(.dateTime.day().month(.abbreviated).year())
        var lines = [meeting.title, date, "", analysis.summary, ""]
        if !analysis.keyPoints.isEmpty {
            lines += ["Dette ble diskutert", ""] + analysis.keyPoints.map { "• \($0.text)" } + [""]
        }
        if !analysis.decisions.isEmpty {
            lines += ["Beslutninger", ""] + analysis.decisions.map { "• \($0.text)" } + [""]
        }
        let confirmed = analysis.actionItems.filter { $0.confidence != .low }
        if !confirmed.isEmpty {
            lines += ["To-Do", ""] + confirmed.map { item in
                let metadata = [item.owner, item.deadline].compactMap { $0 }.joined(separator: " – ")
                return "• \(item.task)\(metadata.isEmpty ? "" : " (\(metadata))")"
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
