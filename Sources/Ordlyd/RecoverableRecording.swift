import Foundation

/// Internal recording format: little-endian, signed 16-bit PCM, mono, 16 kHz.
struct PCMFormat: Codable, Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int

    static let whisper = PCMFormat(sampleRate: 16_000, channels: 1, bitsPerSample: 16)
}

struct ClosedAudioSegment: Codable, Equatable, Sendable {
    let sequence: Int
    let filename: String
    let byteCount: Int
    let sampleCount: Int
    let format: PCMFormat
    let closedAt: Date
}

/// Collects incoming PCM without retaining the whole meeting in memory.
/// Only the unfinished tail remains buffered after `append` returns.
struct PCMChunkAccumulator {
    let segmentSampleCount: Int
    private var storage: [Int16] = []
    private var readIndex = 0

    init(segmentSampleCount: Int) {
        precondition(segmentSampleCount > 0)
        self.segmentSampleCount = segmentSampleCount
        storage.reserveCapacity(segmentSampleCount)
    }

    var bufferedSampleCount: Int { storage.count - readIndex }

    mutating func append(_ samples: [Int16]) -> [[Int16]] {
        storage.append(contentsOf: samples)
        var completed: [[Int16]] = []
        while bufferedSampleCount >= segmentSampleCount {
            let end = readIndex + segmentSampleCount
            completed.append(Array(storage[readIndex..<end]))
            readIndex = end
        }
        compactIfUseful()
        return completed
    }

    mutating func finish() -> [Int16]? {
        guard bufferedSampleCount > 0 else { return nil }
        let tail = Array(storage[readIndex...])
        storage.removeAll(keepingCapacity: true)
        readIndex = 0
        return tail
    }

    private mutating func compactIfUseful() {
        guard readIndex > 0, readIndex >= segmentSampleCount else { return }
        storage.removeFirst(readIndex)
        readIndex = 0
    }
}

struct RecordingArtifactSegment: Equatable, Sendable {
    let url: URL
    let sampleCount: Int
}

struct MeetingRecordingArtifact: Equatable, Sendable {
    let meetingID: UUID
    let segments: [RecordingArtifactSegment]
    var createdAt: Date = .now

    var duration: TimeInterval {
        TimeInterval(segments.reduce(0) { $0 + $1.sampleCount }) / TimeInterval(PCMFormat.whisper.sampleRate)
    }
}

struct SegmentedTranscriber {
    let engine: SpeechEngine

    func transcribe(_ artifact: MeetingRecordingArtifact) async throws -> [TranscriptSegment] {
        var timeOffset: TimeInterval = 0
        var result: [TranscriptSegment] = []
        for artifactSegment in artifact.segments {
            let local = try await engine.transcribe(audioAt: artifactSegment.url)
            for segment in local {
                result.append(TranscriptSegment(
                    id: "s\(result.count + 1)",
                    start: segment.start + timeOffset,
                    end: segment.end + timeOffset,
                    speaker: segment.speaker,
                    text: segment.text
                ))
            }
            timeOffset += TimeInterval(artifactSegment.sampleCount) / TimeInterval(PCMFormat.whisper.sampleRate)
        }
        return result
    }
}

enum RecoverableRecordingState: String, Codable, Equatable, Sendable {
    case recording
    case completed
    case interrupted
}

enum RecordingStopReason: String, Codable, Equatable, Sendable {
    case user
    case insufficientDiskSpace
    case recoveredAfterInterruption
}

struct RecoverableRecordingManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let meetingID: UUID
    let createdAt: Date
    var updatedAt: Date
    var state: RecoverableRecordingState
    var stopReason: RecordingStopReason?
    var segments: [ClosedAudioSegment]
    var transcriptionSucceededAt: Date?
    var rawAudioDeleteAfter: Date?
    var rawAudioPurgedAt: Date?
}

enum RecoverableRecordingError: Error, Equatable {
    case insufficientDiskSpace
    case invalidState
    case emptySegment
    case noRecoverableManifest
    case unsupportedManifestVersion(Int)
}

protocol RecordingClock: AnyObject {
    var now: Date { get }
}

final class SystemRecordingClock: RecordingClock {
    var now: Date { Date() }
}

protocol RecordingDiskSpaceGateway: AnyObject {
    func availableBytes(at url: URL) throws -> Int64
}

final class LocalRecordingDiskSpaceGateway: RecordingDiskSpaceGateway {
    func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

protocol RecordingFileSystem: AnyObject {
    func createDirectory(at url: URL) throws
    func data(at url: URL) throws -> Data
    func exists(at url: URL) -> Bool
    func removeItem(at url: URL) throws
    func write(_ data: Data, to url: URL, atomically: Bool) throws
}

final class LocalRecordingFileSystem: RecordingFileSystem {
    private let manager: FileManager

    init(manager: FileManager = .default) { self.manager = manager }

    func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func data(at url: URL) throws -> Data { try Data(contentsOf: url) }
    func exists(at url: URL) -> Bool { manager.fileExists(atPath: url.path) }
    func removeItem(at url: URL) throws { try manager.removeItem(at: url) }

    func write(_ data: Data, to url: URL, atomically: Bool) throws {
        try data.write(to: url, options: atomically ? .atomic : [])
    }
}

struct RecoverableRecordingSession {
    private static let manifestName = "manifest.json"
    private static let previousManifestName = "manifest.previous.json"
    private static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    let meetingID: UUID
    let rootDirectory: URL
    let fileSystem: RecordingFileSystem
    let diskSpace: RecordingDiskSpaceGateway
    let clock: RecordingClock
    let minimumFreeBytes: Int64
    private(set) var manifest: RecoverableRecordingManifest

    private var meetingDirectory: URL {
        rootDirectory.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    private var manifestURL: URL { meetingDirectory.appendingPathComponent(Self.manifestName) }
    private var previousManifestURL: URL { meetingDirectory.appendingPathComponent(Self.previousManifestName) }

    var artifact: MeetingRecordingArtifact {
        MeetingRecordingArtifact(
            meetingID: meetingID,
            segments: manifest.segments.map {
                RecordingArtifactSegment(
                    url: meetingDirectory.appendingPathComponent($0.filename),
                    sampleCount: $0.sampleCount
                )
            },
            createdAt: manifest.createdAt
        )
    }

    init(
        meetingID: UUID,
        rootDirectory: URL,
        fileSystem: RecordingFileSystem = LocalRecordingFileSystem(),
        diskSpace: RecordingDiskSpaceGateway = LocalRecordingDiskSpaceGateway(),
        clock: RecordingClock = SystemRecordingClock(),
        minimumFreeBytes: Int64 = 512 * 1_024 * 1_024
    ) throws {
        self.meetingID = meetingID
        self.rootDirectory = rootDirectory
        self.fileSystem = fileSystem
        self.diskSpace = diskSpace
        self.clock = clock
        self.minimumFreeBytes = minimumFreeBytes
        self.manifest = RecoverableRecordingManifest(
            version: RecoverableRecordingManifest.currentVersion,
            meetingID: meetingID,
            createdAt: clock.now,
            updatedAt: clock.now,
            state: .recording,
            stopReason: nil,
            segments: [],
            transcriptionSucceededAt: nil,
            rawAudioDeleteAfter: nil,
            rawAudioPurgedAt: nil
        )
    }

    mutating func begin() throws {
        guard !fileSystem.exists(at: manifestURL) else { throw RecoverableRecordingError.invalidState }
        // Disk capacity APIs require an existing URL. Creating the shared root
        // is harmless; no meeting exists until its manifest is committed.
        try fileSystem.createDirectory(at: rootDirectory)
        try requireDiskSpace()
        try fileSystem.createDirectory(at: meetingDirectory)
        manifest.updatedAt = clock.now
        try persistManifest()
    }

    @discardableResult
    mutating func closeSegment(samples: [Int16]) throws -> ClosedAudioSegment {
        guard manifest.state == .recording else { throw RecoverableRecordingError.invalidState }
        guard !samples.isEmpty else { throw RecoverableRecordingError.emptySegment }

        do {
            try requireDiskSpace()
        } catch RecoverableRecordingError.insufficientDiskSpace {
            manifest.state = .interrupted
            manifest.stopReason = .insufficientDiskSpace
            manifest.updatedAt = clock.now
            try persistManifest()
            throw RecoverableRecordingError.insufficientDiskSpace
        }

        let sequence = manifest.segments.count + 1
        let filename = String(format: "segment-%06d.wav", sequence)
        let segmentURL = meetingDirectory.appendingPathComponent(filename)
        let encoded = WaveEncoder.encode(samples: samples, sampleRate: PCMFormat.whisper.sampleRate)
        try fileSystem.write(encoded, to: segmentURL, atomically: true)

        let segment = ClosedAudioSegment(
            sequence: sequence,
            filename: filename,
            byteCount: encoded.count,
            sampleCount: samples.count,
            format: .whisper,
            closedAt: clock.now
        )
        manifest.segments.append(segment)
        manifest.updatedAt = clock.now
        do {
            try persistManifest()
        } catch {
            // The WAV is harmless but is not closed/recoverable until referenced by a valid manifest.
            try? fileSystem.removeItem(at: segmentURL)
            manifest.segments.removeLast()
            throw error
        }
        return segment
    }

    mutating func finish() throws {
        guard manifest.state == .recording else { throw RecoverableRecordingError.invalidState }
        manifest.state = .completed
        manifest.stopReason = .user
        manifest.updatedAt = clock.now
        try persistManifest()
    }

    mutating func checkDiskSpaceDuringRecording() throws {
        guard manifest.state == .recording else { throw RecoverableRecordingError.invalidState }
        do { try requireDiskSpace() }
        catch RecoverableRecordingError.insufficientDiskSpace {
            manifest.state = .interrupted
            manifest.stopReason = .insufficientDiskSpace
            manifest.updatedAt = clock.now
            try persistManifest()
            throw RecoverableRecordingError.insufficientDiskSpace
        }
    }

    mutating func markTranscriptionSucceeded() throws {
        let completedAt = clock.now
        manifest.transcriptionSucceededAt = completedAt
        manifest.rawAudioDeleteAfter = completedAt.addingTimeInterval(Self.retentionInterval)
        manifest.updatedAt = completedAt
        try persistManifest()
    }

    /// Returns true only when audio was due and was removed.
    @discardableResult
    mutating func enforceRawAudioRetention() throws -> Bool {
        guard manifest.state != .interrupted,
              manifest.transcriptionSucceededAt != nil,
              let deadline = manifest.rawAudioDeleteAfter,
              clock.now >= deadline,
              manifest.rawAudioPurgedAt == nil else { return false }

        for segment in manifest.segments {
            let url = meetingDirectory.appendingPathComponent(segment.filename)
            if fileSystem.exists(at: url) { try fileSystem.removeItem(at: url) }
        }
        manifest.segments.removeAll()
        manifest.rawAudioPurgedAt = clock.now
        manifest.updatedAt = clock.now
        try persistManifest()
        return true
    }

    static func recover(
        meetingID: UUID,
        rootDirectory: URL,
        fileSystem: RecordingFileSystem = LocalRecordingFileSystem(),
        diskSpace: RecordingDiskSpaceGateway = LocalRecordingDiskSpaceGateway(),
        clock: RecordingClock = SystemRecordingClock(),
        minimumFreeBytes: Int64 = 512 * 1_024 * 1_024
    ) throws -> RecoverableRecordingSession {
        let directory = rootDirectory.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        let candidates = [
            directory.appendingPathComponent(Self.manifestName),
            directory.appendingPathComponent(Self.previousManifestName)
        ]
        var recovered: RecoverableRecordingManifest?
        for candidate in candidates where fileSystem.exists(at: candidate) {
            guard let decoded = try? JSONDecoder().decode(
                RecoverableRecordingManifest.self,
                from: fileSystem.data(at: candidate)
            ) else { continue }
            if decoded.version != RecoverableRecordingManifest.currentVersion {
                throw RecoverableRecordingError.unsupportedManifestVersion(decoded.version)
            }
            guard decoded.meetingID == meetingID,
                  manifestReferencesValidClosedSegments(decoded, in: directory, fileSystem: fileSystem) else { continue }
            recovered = decoded
            break
        }
        guard var manifest = recovered else { throw RecoverableRecordingError.noRecoverableManifest }
        if manifest.state == .recording {
            manifest.state = .interrupted
            manifest.stopReason = .recoveredAfterInterruption
            manifest.updatedAt = clock.now
        }

        var session = try RecoverableRecordingSession(
            meetingID: meetingID,
            rootDirectory: rootDirectory,
            fileSystem: fileSystem,
            diskSpace: diskSpace,
            clock: clock,
            minimumFreeBytes: minimumFreeBytes
        )
        session.manifest = manifest
        try session.persistManifest(preserveCurrentAsBackup: false)
        return session
    }

    private func requireDiskSpace() throws {
        guard try diskSpace.availableBytes(at: rootDirectory) >= minimumFreeBytes else {
            throw RecoverableRecordingError.insufficientDiskSpace
        }
    }

    private func persistManifest(preserveCurrentAsBackup: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        if preserveCurrentAsBackup, fileSystem.exists(at: manifestURL) {
            let previous = try fileSystem.data(at: manifestURL)
            try fileSystem.write(previous, to: previousManifestURL, atomically: true)
        }
        try fileSystem.write(data, to: manifestURL, atomically: true)
    }

    private static func manifestReferencesValidClosedSegments(
        _ manifest: RecoverableRecordingManifest,
        in directory: URL,
        fileSystem: RecordingFileSystem
    ) -> Bool {
        for segment in manifest.segments {
            let url = directory.appendingPathComponent(segment.filename)
            guard fileSystem.exists(at: url),
                  let data = try? fileSystem.data(at: url),
                  data.count == segment.byteCount,
                  data.count >= 44,
                  String(data: data[0..<4], encoding: .ascii) == "RIFF",
                  String(data: data[8..<12], encoding: .ascii) == "WAVE",
                  segment.format == .whisper else { return false }
        }
        return true
    }
}

/// Discovers recordings left behind by a crash or forced quit. Invalid folders
/// are ignored so one damaged recording cannot prevent recovery of the others.
struct RecoverableRecordingCatalog {
    let rootDirectory: URL
    private let manager: FileManager

    init(rootDirectory: URL, manager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.manager = manager
    }

    func pendingArtifacts() -> [MeetingRecordingArtifact] {
        guard let children = try? manager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { directory in
            guard let meetingID = UUID(uuidString: directory.lastPathComponent),
                  let session = try? RecoverableRecordingSession.recover(
                    meetingID: meetingID,
                    rootDirectory: rootDirectory,
                    minimumFreeBytes: 1
                  ),
                  session.manifest.transcriptionSucceededAt == nil,
                  !session.manifest.segments.isEmpty else { return nil }
            return session.artifact
        }
        .sorted { $0.meetingID.uuidString < $1.meetingID.uuidString }
    }

    func deleteArtifacts(for meetingID: UUID) throws {
        let directory = rootDirectory.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
    }

    func markTranscriptionSucceeded(for meetingID: UUID) throws {
        var session = try RecoverableRecordingSession.recover(
            meetingID: meetingID,
            rootDirectory: rootDirectory,
            minimumFreeBytes: 1
        )
        try session.markTranscriptionSucceeded()
    }

    func deleteAllArtifacts() throws {
        guard manager.fileExists(atPath: rootDirectory.path) else { return }
        try manager.removeItem(at: rootDirectory)
    }

    /// Applies the manifest retention deadline. A damaged folder is left in
    /// place for manual inspection instead of being deleted speculatively.
    @discardableResult
    func enforceRetention() -> Int {
        guard let children = try? manager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var purged = 0
        for directory in children {
            guard let meetingID = UUID(uuidString: directory.lastPathComponent),
                  var session = try? RecoverableRecordingSession.recover(
                    meetingID: meetingID,
                    rootDirectory: rootDirectory,
                    minimumFreeBytes: 1
                  ) else { continue }
            if (try? session.enforceRawAudioRetention()) == true { purged += 1 }
        }
        return purged
    }
}
