import AVFoundation
import Foundation

enum RecordingDirectories {
    static var recoverableRecordings: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ordlyd/RecoverableRecordings", isDirectory: true)
    }
}

struct MeetingAudioSnapshot {
    let url: URL
    let startTime: TimeInterval
}

protocol MeetingAudioRecording: AnyObject {
    func start() async throws
    func snapshot() throws -> MeetingAudioSnapshot?
    func stop() throws -> MeetingRecordingArtifact?
    func cancel() throws -> UUID?
}

/// Production meeting recorder. PCM is closed into independently recoverable
/// WAV files while recording instead of being held in memory until Stop.
final class RecoverableMeetingAudioRecorder: MeetingAudioRecording {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "no.sparkntnu.ordlyd.recording-writer")
    private let sampleRate = PCMFormat.whisper.sampleRate
    private let segmentSampleCount: Int
    private let recentSampleLimit: Int
    private let rootDirectory: URL

    private var accumulator: PCMChunkAccumulator
    private var recentSamples: [Int16] = []
    private var totalSampleCount = 0
    private var sourcePosition = 0.0
    private var session: RecoverableRecordingSession?
    private var writerError: Error?

    init(
        rootDirectory: URL = RecordingDirectories.recoverableRecordings,
        segmentDuration: TimeInterval = 30,
        liveWindowDuration: TimeInterval = 30
    ) {
        self.rootDirectory = rootDirectory
        segmentSampleCount = max(1, Int(TimeInterval(sampleRate) * segmentDuration))
        recentSampleLimit = max(1, Int(TimeInterval(sampleRate) * liveWindowDuration))
        accumulator = PCMChunkAccumulator(segmentSampleCount: segmentSampleCount)
    }

    func start() async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw NBWhisperError.recordingPermissionDenied }

        let meetingID = UUID()
        var newSession = try RecoverableRecordingSession(meetingID: meetingID, rootDirectory: rootDirectory)
        try newSession.begin()
        writerQueue.sync { session = newSession; writerError = nil }
        lock.withLock {
            accumulator = PCMChunkAccumulator(segmentSampleCount: segmentSampleCount)
            recentSamples.removeAll(keepingCapacity: true)
            totalSampleCount = 0
            sourcePosition = 0
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NBWhisperError.recordingFailed }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, inputRate: format.sampleRate)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw NBWhisperError.recordingFailed
        }
    }

    func snapshot() throws -> MeetingAudioSnapshot? {
        let state = lock.withLock { (recentSamples, totalSampleCount) }
        guard !state.0.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ordlyd-live-\(UUID().uuidString).wav")
        try WaveEncoder.encode(samples: state.0, sampleRate: sampleRate).write(to: url, options: .atomic)
        let startSample = max(0, state.1 - state.0.count)
        return MeetingAudioSnapshot(
            url: url,
            startTime: TimeInterval(startSample) / TimeInterval(sampleRate)
        )
    }

    func stop() throws -> MeetingRecordingArtifact? {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let tail = lock.withLock { accumulator.finish() }

        return try writerQueue.sync {
            if let tail { try closeSegment(tail) }
            if let writerError { throw writerError }
            guard var session else { return nil }
            guard !session.manifest.segments.isEmpty else {
                try session.finish()
                self.session = session
                return nil
            }
            try session.finish()
            self.session = session
            return session.artifact
        }
    }

    func cancel() throws -> UUID? {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.withLock {
            accumulator = PCMChunkAccumulator(segmentSampleCount: segmentSampleCount)
            recentSamples.removeAll(keepingCapacity: true)
            totalSampleCount = 0
            sourcePosition = 0
        }
        return writerQueue.sync {
            let meetingID = session?.meetingID
            session = nil
            writerError = nil
            return meetingID
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, inputRate: Double) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        let converted: [Int16] = lock.withLock {
            let ratio = inputRate / Double(sampleRate)
            var output: [Int16] = []
            output.reserveCapacity(max(1, Int(Double(frames) / ratio)))
            while sourcePosition < Double(frames) {
                let index = min(Int(sourcePosition), frames - 1)
                var mixed: Float = 0
                for channel in 0..<channelCount { mixed += channels[channel][index] }
                mixed /= Float(channelCount)
                output.append(Int16(max(-1, min(1, mixed)) * Float(Int16.max)))
                sourcePosition += ratio
            }
            sourcePosition -= Double(frames)
            totalSampleCount += output.count
            recentSamples.append(contentsOf: output)
            if recentSamples.count > recentSampleLimit {
                recentSamples.removeFirst(recentSamples.count - recentSampleLimit)
            }
            return output
        }

        let completed = lock.withLock { accumulator.append(converted) }
        guard !completed.isEmpty else { return }
        writerQueue.async { [weak self] in
            guard let self else { return }
            for samples in completed where self.writerError == nil {
                do { try self.closeSegment(samples) }
                catch { self.writerError = error }
            }
        }
    }

    /// Must only be called on writerQueue.
    private func closeSegment(_ samples: [Int16]) throws {
        guard var session else { throw RecoverableRecordingError.invalidState }
        _ = try session.closeSegment(samples: samples)
        self.session = session
    }
}
