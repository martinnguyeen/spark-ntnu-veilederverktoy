import Foundation
import XCTest
@testable import Ordlyd

final class RecoverableRecordingTests: XCTestCase {
    private let meetingID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testRecordingWritesClosedPCMSegmentAndUpdatesManifestAtomically() throws {
        let fixture = try Fixture(meetingID: meetingID)
        var session = try fixture.makeSession()

        try session.begin()
        let segment = try session.closeSegment(samples: [0, 1_000, -1_000, 250])

        let audio = try Data(contentsOf: fixture.directory.appendingPathComponent(segment.filename))
        XCTAssertEqual(String(data: audio[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: audio[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(segment.format, PCMFormat(sampleRate: 16_000, channels: 1, bitsPerSample: 16))
        XCTAssertEqual(segment.byteCount, 52)
        XCTAssertTrue(fixture.fileSystem.atomicDestinations.contains(fixture.manifestURL))

        let manifest = try fixture.decodeManifest()
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.segments, [segment])
        XCTAssertEqual(manifest.state, .recording)
    }

    func testRecoveryUsesLastValidManifestAndRestoresOnlyClosedSegments() throws {
        let fixture = try Fixture(meetingID: meetingID)
        var session = try fixture.makeSession()
        try session.begin()
        let first = try session.closeSegment(samples: [100, 200])
        _ = try session.closeSegment(samples: [300, 400])

        // Simulate termination halfway through the newest manifest replacement.
        try Data("not-json".utf8).write(to: fixture.manifestURL)

        let recovered = try RecoverableRecordingSession.recover(
            meetingID: meetingID,
            rootDirectory: fixture.root,
            fileSystem: fixture.fileSystem,
            diskSpace: fixture.disk,
            clock: fixture.clock
        )

        XCTAssertEqual(recovered.manifest.segments, [first])
        XCTAssertEqual(recovered.manifest.state, .interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(first.filename).path))
    }

    func testLowDiskBeforeRecordingDoesNotCreateRecording() throws {
        let fixture = try Fixture(meetingID: meetingID, capacities: [99])
        var session = try fixture.makeSession(minimumFreeBytes: 100)

        XCTAssertThrowsError(try session.begin()) { error in
            XCTAssertEqual(error as? RecoverableRecordingError, .insufficientDiskSpace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
    }

    func testFirstRecordingCanStartBeforeRootDirectoryExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-recording-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        var session = try RecoverableRecordingSession(
            meetingID: meetingID,
            rootDirectory: root,
            minimumFreeBytes: 1
        )

        XCTAssertNoThrow(try session.begin())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(meetingID.uuidString).path))
    }

    func testLowDiskDuringRecordingStopsSafelyWithoutDeletingClosedSegments() throws {
        let fixture = try Fixture(meetingID: meetingID, capacities: [1_000, 1_000, 50])
        var session = try fixture.makeSession(minimumFreeBytes: 100)
        try session.begin()
        let closed = try session.closeSegment(samples: [100, 200])

        XCTAssertThrowsError(try session.checkDiskSpaceDuringRecording()) { error in
            XCTAssertEqual(error as? RecoverableRecordingError, .insufficientDiskSpace)
        }

        let manifest = try fixture.decodeManifest()
        XCTAssertEqual(manifest.state, .interrupted)
        XCTAssertEqual(manifest.stopReason, .insufficientDiskSpace)
        XCTAssertEqual(manifest.segments, [closed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(closed.filename).path))
    }

    func testSuccessfulTranscriptionSchedulesRawAudioDeletionAfterSevenDays() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let fixture = try Fixture(meetingID: meetingID, now: started)
        var session = try fixture.makeSession()
        try session.begin()
        _ = try session.closeSegment(samples: [100, 200])

        try session.markTranscriptionSucceeded()

        let manifest = try fixture.decodeManifest()
        XCTAssertEqual(manifest.transcriptionSucceededAt, started)
        XCTAssertEqual(manifest.rawAudioDeleteAfter, started.addingTimeInterval(7 * 24 * 60 * 60))
    }

    func testRetentionDeletesRawAudioOnlyAfterDeadline() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let fixture = try Fixture(meetingID: meetingID, now: started)
        var session = try fixture.makeSession()
        try session.begin()
        let segment = try session.closeSegment(samples: [100, 200])
        try session.markTranscriptionSucceeded()
        let segmentURL = fixture.directory.appendingPathComponent(segment.filename)

        fixture.clock.now = started.addingTimeInterval(7 * 24 * 60 * 60 - 1)
        XCTAssertFalse(try session.enforceRawAudioRetention())
        XCTAssertTrue(FileManager.default.fileExists(atPath: segmentURL.path))

        fixture.clock.now = started.addingTimeInterval(7 * 24 * 60 * 60)
        XCTAssertTrue(try session.enforceRawAudioRetention())
        XCTAssertFalse(FileManager.default.fileExists(atPath: segmentURL.path))
        let manifest = try fixture.decodeManifest()
        XCTAssertTrue(manifest.segments.isEmpty)
        XCTAssertEqual(manifest.rawAudioPurgedAt, fixture.clock.now)
    }

    func testInterruptedRecordingIsNotRemovedByRetention() throws {
        let fixture = try Fixture(meetingID: meetingID, capacities: [1_000, 1_000, 50])
        var session = try fixture.makeSession(minimumFreeBytes: 100)
        try session.begin()
        let segment = try session.closeSegment(samples: [100, 200])
        XCTAssertThrowsError(try session.closeSegment(samples: [300]))
        fixture.clock.now = fixture.clock.now.addingTimeInterval(30 * 24 * 60 * 60)

        XCTAssertFalse(try session.enforceRawAudioRetention())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(segment.filename).path))
    }

    func testPCMChunkAccumulatorClosesFixedSegmentsAndKeepsOnlyTheTailInMemory() {
        var accumulator = PCMChunkAccumulator(segmentSampleCount: 4)

        XCTAssertEqual(accumulator.append([1, 2, 3]), [])
        XCTAssertEqual(accumulator.append([4, 5, 6, 7, 8, 9, 10]), [
            [1, 2, 3, 4],
            [5, 6, 7, 8]
        ])
        XCTAssertEqual(accumulator.bufferedSampleCount, 2)
        XCTAssertLessThan(accumulator.bufferedSampleCount, accumulator.segmentSampleCount)
        XCTAssertEqual(accumulator.finish(), [9, 10])
        XCTAssertEqual(accumulator.bufferedSampleCount, 0)
    }

    func testSegmentedTranscriptionOffsetsTimeAndAssignsStableIDs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("segmented-transcription-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("segment-1.wav")
        let secondURL = root.appendingPathComponent("segment-2.wav")
        try WaveEncoder.encode(samples: [0], sampleRate: 16_000).write(to: firstURL)
        try WaveEncoder.encode(samples: [0], sampleRate: 16_000).write(to: secondURL)
        let artifact = MeetingRecordingArtifact(
            meetingID: meetingID,
            segments: [
                .init(url: firstURL, sampleCount: 32_000),
                .init(url: secondURL, sampleCount: 16_000)
            ]
        )
        let engine = StubSegmentSpeechEngine(responses: [
            firstURL: [.init(id: "local-8", start: 0.25, end: 1.5, speaker: nil, text: "Første del")],
            secondURL: [.init(id: "local-2", start: 0, end: 0.75, speaker: "Martin", text: "Andre del")]
        ])

        let result = try await SegmentedTranscriber(engine: engine).transcribe(artifact)

        XCTAssertEqual(result, [
            .init(id: "s1", start: 0.25, end: 1.5, speaker: nil, text: "Første del"),
            .init(id: "s2", start: 2.0, end: 2.75, speaker: "Martin", text: "Andre del")
        ])
    }

    func testCatalogFindsInterruptedRecordingAndReturnsItsClosedSegments() throws {
        let fixture = try Fixture(meetingID: meetingID)
        var session = try fixture.makeSession()
        try session.begin()
        let closed = try session.closeSegment(samples: [100, 200, 300])

        let artifacts = RecoverableRecordingCatalog(rootDirectory: fixture.root).pendingArtifacts()

        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.meetingID, meetingID)
        XCTAssertEqual(artifacts.first?.segments.map(\.sampleCount), [closed.sampleCount])
        XCTAssertEqual(artifacts.first?.segments.first?.url,
                       fixture.directory.appendingPathComponent(closed.filename))
    }

    func testDeletingArtifactsRemovesOnlyTheSelectedMeeting() throws {
        let otherID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-catalog-delete-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in [meetingID, otherID] {
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: folder.appendingPathComponent("sentinel"))
        }
        let catalog = RecoverableRecordingCatalog(rootDirectory: root)

        try catalog.deleteArtifacts(for: meetingID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(meetingID.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(otherID.uuidString).path))
    }

    func testCatalogEnforcesExpiredRawAudioRetention() throws {
        let fixture = try Fixture(meetingID: meetingID, now: Date(timeIntervalSince1970: 1_000))
        var session = try fixture.makeSession()
        try session.begin()
        let closed = try session.closeSegment(samples: [100, 200])
        try session.finish()
        try session.markTranscriptionSucceeded()
        let segmentURL = fixture.directory.appendingPathComponent(closed.filename)

        let purgedCount = RecoverableRecordingCatalog(rootDirectory: fixture.root).enforceRetention()

        XCTAssertEqual(purgedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: segmentURL.path))
    }
}

private struct StubSegmentSpeechEngine: SpeechEngine {
    let responses: [URL: [TranscriptSegment]]
    func transcribe(audioAt url: URL) async throws -> [TranscriptSegment] { responses[url] ?? [] }
}

private final class MutableClock: RecordingClock {
    var now: Date
    init(now: Date) { self.now = now }
}

private final class CapacitySequence: RecordingDiskSpaceGateway {
    private var values: [Int64]
    init(_ values: [Int64]) { self.values = values }
    func availableBytes(at url: URL) throws -> Int64 {
        if values.count > 1 { return values.removeFirst() }
        return values.first ?? .max
    }
}

private final class TrackingFileSystem: RecordingFileSystem {
    private let base = LocalRecordingFileSystem()
    private(set) var atomicDestinations: [URL] = []
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func data(at url: URL) throws -> Data { try base.data(at: url) }
    func exists(at url: URL) -> Bool { base.exists(at: url) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func write(_ data: Data, to url: URL, atomically: Bool) throws {
        if atomically { atomicDestinations.append(url) }
        try base.write(data, to: url, atomically: atomically)
    }
}

private final class Fixture {
    let root: URL
    let meetingID: UUID
    let clock: MutableClock
    let disk: CapacitySequence
    let fileSystem = TrackingFileSystem()
    var directory: URL { root.appendingPathComponent(meetingID.uuidString, isDirectory: true) }
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    init(meetingID: UUID, capacities: [Int64] = [.max], now: Date = Date(timeIntervalSince1970: 1_000)) throws {
        self.meetingID = meetingID
        self.clock = MutableClock(now: now)
        self.disk = CapacitySequence(capacities)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recoverable-recording-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeSession(minimumFreeBytes: Int64 = 1) throws -> RecoverableRecordingSession {
        try RecoverableRecordingSession(
            meetingID: meetingID,
            rootDirectory: root,
            fileSystem: fileSystem,
            diskSpace: disk,
            clock: clock,
            minimumFreeBytes: minimumFreeBytes
        )
    }

    func decodeManifest() throws -> RecoverableRecordingManifest {
        try JSONDecoder().decode(RecoverableRecordingManifest.self, from: Data(contentsOf: manifestURL))
    }
}
