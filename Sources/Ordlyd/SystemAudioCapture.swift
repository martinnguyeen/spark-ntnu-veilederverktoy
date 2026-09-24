import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum MixedAudioSource: Equatable, Sendable {
    case microphone
    case system
}

struct TimelineAudioMixer {
    private var bufferStart = 0
    private var microphone: [Int16] = []
    private var system: [Int16] = []
    private var hasMicrophone: [Bool] = []
    private var hasSystem: [Bool] = []

    mutating func append(source: MixedAudioSource, samples: [Int16], startSample: Int) {
        guard !samples.isEmpty else { return }
        let trimmedCount = max(0, bufferStart - startSample)
        guard trimmedCount < samples.count else { return }
        let writeStart = max(startSample, bufferStart) - bufferStart
        let incoming = samples.dropFirst(trimmedCount)
        ensureCapacity(writeStart + incoming.count)
        for (offset, sample) in incoming.enumerated() {
            let index = writeStart + offset
            switch source {
            case .microphone:
                microphone[index] = sample
                hasMicrophone[index] = true
            case .system:
                system[index] = sample
                hasSystem[index] = true
            }
        }
    }

    mutating func drain(before absoluteSample: Int) -> [Int16] {
        let count = min(max(0, absoluteSample - bufferStart), microphone.count)
        guard count > 0 else { return [] }
        let result = (0..<count).map(mixedSample)
        microphone.removeFirst(count)
        system.removeFirst(count)
        hasMicrophone.removeFirst(count)
        hasSystem.removeFirst(count)
        bufferStart += count
        return result
    }

    mutating func finish() -> [Int16] {
        drain(before: bufferStart + microphone.count)
    }

    private mutating func ensureCapacity(_ count: Int) {
        guard count > microphone.count else { return }
        let addition = count - microphone.count
        microphone.append(contentsOf: repeatElement(0, count: addition))
        system.append(contentsOf: repeatElement(0, count: addition))
        hasMicrophone.append(contentsOf: repeatElement(false, count: addition))
        hasSystem.append(contentsOf: repeatElement(false, count: addition))
    }

    private func mixedSample(at index: Int) -> Int16 {
        switch (hasMicrophone[index], hasSystem[index]) {
        case (true, true):
            let average = (Int32(microphone[index]) + Int32(system[index])) / 2
            return Int16(clamping: average)
        case (true, false): return microphone[index]
        case (false, true): return system[index]
        case (false, false): return 0
        }
    }
}

enum DigitalMeetingRecordingError: LocalizedError, Equatable {
    case screenRecordingPermissionRequired
    case noDisplayAvailable
    case systemAudioUnavailable

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            "Tillat skjerm- og systemlydopptak for Spark* NTNU - veilederverktøy i Systeminnstillinger → Personvern og sikkerhet → Skjerm- og systemlydopptak."
        case .noDisplayAvailable:
            "Fant ingen skjerm som systemlyden kunne knyttes til."
        case .systemAudioUnavailable:
            "Systemlyden kunne ikke startes. Prøv å åpne møtet på nytt og kontroller skjermopptakstillatelsen."
        }
    }
}

private protocol TimedPCMAudioSource: AnyObject {
    func start(handler: @escaping ([Int16], TimeInterval) -> Void) async throws
    func stop()
}

private final class MicrophonePCMSource: TimedPCMAudioSource {
    private let engine = AVAudioEngine()

    func start(handler: @escaping ([Int16], TimeInterval) -> Void) async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw NBWhisperError.recordingPermissionDenied }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NBWhisperError.recordingFailed }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, time in
            let samples = PCM16kConverter.convert(buffer)
            let timestamp = time.isHostTimeValid
                ? Double(AudioConvertHostTimeToNanos(time.hostTime)) / 1_000_000_000
                : ProcessInfo.processInfo.systemUptime
            if !samples.isEmpty { handler(samples, timestamp) }
        }
        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            throw NBWhisperError.recordingFailed
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

private final class ScreenCapturePCMSource: NSObject, TimedPCMAudioSource, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "no.sparkntnu.ordlyd.system-audio")
    private var stream: SCStream?
    private var handler: (([Int16], TimeInterval) -> Void)?

    func start(handler: @escaping ([Int16], TimeInterval) -> Void) async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw DigitalMeetingRecordingError.screenRecordingPermissionRequired
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw DigitalMeetingRecordingError.screenRecordingPermissionRequired }
        guard let display = content.displays.first else { throw DigitalMeetingRecordingError.noDisplayAvailable }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            self.handler = handler
            try await stream.startCapture()
        } catch {
            self.handler = nil
            throw DigitalMeetingRecordingError.systemAudioUnavailable
        }
        self.stream = stream
    }

    func stop() {
        handler = nil
        guard let stream else { return }
        try? stream.removeStreamOutput(self, type: .audio)
        stream.stopCapture { _ in }
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples))
        else { return }
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<sampleBuffer.numSamples, into: buffer.mutableAudioBufferList)
            buffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
            let samples = PCM16kConverter.convert(buffer)
            let presentationTime = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
            let timestamp = presentationTime.isFinite ? presentationTime : ProcessInfo.processInfo.systemUptime
            if !samples.isEmpty { handler?(samples, timestamp) }
        } catch { }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handler = nil
    }
}

private enum PCM16kConverter {
    static func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        else { return [] }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 8)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData?[0] else { return [] }
        return (0..<Int(output.frameLength)).map { index in
            Int16(max(-1, min(1, channel[index])) * Float(Int16.max))
        }
    }
}

private final class RecoverableMixedAudioSink {
    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "no.sparkntnu.ordlyd.mixed-recording-writer")
    private let sampleRate = PCMFormat.whisper.sampleRate
    private let segmentSampleCount: Int
    private let recentSampleLimit: Int
    private let rootDirectory: URL
    private var accumulator: PCMChunkAccumulator
    private var recentSamples: [Int16] = []
    private var totalSampleCount = 0
    private var session: RecoverableRecordingSession?
    private var writerError: Error?

    init(rootDirectory: URL, segmentDuration: TimeInterval = 30, liveWindowDuration: TimeInterval = 30) {
        self.rootDirectory = rootDirectory
        segmentSampleCount = max(1, Int(TimeInterval(sampleRate) * segmentDuration))
        recentSampleLimit = max(1, Int(TimeInterval(sampleRate) * liveWindowDuration))
        accumulator = PCMChunkAccumulator(segmentSampleCount: segmentSampleCount)
    }

    func start() throws {
        let meetingID = UUID()
        var newSession = try RecoverableRecordingSession(meetingID: meetingID, rootDirectory: rootDirectory)
        try newSession.begin()
        writerQueue.sync { session = newSession; writerError = nil }
        lock.withLock {
            accumulator = PCMChunkAccumulator(segmentSampleCount: segmentSampleCount)
            recentSamples.removeAll(keepingCapacity: true)
            totalSampleCount = 0
        }
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let completed = lock.withLock { () -> [[Int16]] in
            totalSampleCount += samples.count
            recentSamples.append(contentsOf: samples)
            if recentSamples.count > recentSampleLimit { recentSamples.removeFirst(recentSamples.count - recentSampleLimit) }
            return accumulator.append(samples)
        }
        guard !completed.isEmpty else { return }
        writerQueue.async { [weak self] in
            guard let self else { return }
            for samples in completed where self.writerError == nil {
                do { try self.closeSegment(samples) }
                catch { self.writerError = error }
            }
        }
    }

    func snapshot() throws -> MeetingAudioSnapshot? {
        let state = lock.withLock { (recentSamples, totalSampleCount) }
        guard !state.0.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ordlyd-digital-live-\(UUID().uuidString).wav")
        try WaveEncoder.encode(samples: state.0, sampleRate: sampleRate).write(to: url, options: .atomic)
        return MeetingAudioSnapshot(url: url, startTime: TimeInterval(max(0, state.1 - state.0.count)) / TimeInterval(sampleRate))
    }

    func stop() throws -> MeetingRecordingArtifact? {
        let tail = lock.withLock { accumulator.finish() }
        return try writerQueue.sync {
            if let tail { try closeSegment(tail) }
            if let writerError { throw writerError }
            guard var session else { return nil }
            guard !session.manifest.segments.isEmpty else { try session.finish(); self.session = session; return nil }
            try session.finish(); self.session = session; return session.artifact
        }
    }

    func cancel() -> UUID? {
        lock.withLock {
            accumulator = PCMChunkAccumulator(segmentSampleCount: segmentSampleCount)
            recentSamples.removeAll(keepingCapacity: true)
            totalSampleCount = 0
        }
        return writerQueue.sync { let id = session?.meetingID; session = nil; writerError = nil; return id }
    }

    private func closeSegment(_ samples: [Int16]) throws {
        guard var session else { throw RecoverableRecordingError.invalidState }
        _ = try session.closeSegment(samples: samples)
        self.session = session
    }
}

final class ScreenCaptureMeetingAudioRecorder: MeetingAudioRecording {
    private let microphone: any TimedPCMAudioSource
    private let system: any TimedPCMAudioSource
    private let sink: RecoverableMixedAudioSink
    private let lock = NSLock()
    private let sampleRate = PCMFormat.whisper.sampleRate
    private let latencySamples: Int
    private var mixer = TimelineAudioMixer()
    private var recordingStartedAt: TimeInterval = 0

    init(rootDirectory: URL = RecordingDirectories.recoverableRecordings, latency: TimeInterval = 1.5) {
        microphone = MicrophonePCMSource()
        system = ScreenCapturePCMSource()
        sink = RecoverableMixedAudioSink(rootDirectory: rootDirectory)
        latencySamples = Int(TimeInterval(sampleRate) * latency)
    }

    func start() async throws {
        try sink.start()
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        mixer = TimelineAudioMixer()
        do {
            try await microphone.start { [weak self] samples, time in self?.consume(.microphone, samples: samples, at: time) }
            try await system.start { [weak self] samples, time in self?.consume(.system, samples: samples, at: time) }
        } catch {
            microphone.stop()
            system.stop()
            _ = sink.cancel()
            throw error
        }
    }

    func snapshot() throws -> MeetingAudioSnapshot? { try sink.snapshot() }

    func stop() throws -> MeetingRecordingArtifact? {
        microphone.stop()
        system.stop()
        let tail = lock.withLock { mixer.finish() }
        sink.append(tail)
        return try sink.stop()
    }

    func cancel() throws -> UUID? {
        microphone.stop()
        system.stop()
        lock.withLock { mixer = TimelineAudioMixer() }
        return sink.cancel()
    }

    private func consume(_ source: MixedAudioSource, samples: [Int16], at time: TimeInterval) {
        let endSample = max(0, Int((time - recordingStartedAt) * TimeInterval(sampleRate)))
        let startSample = max(0, endSample - samples.count)
        let drained = lock.withLock { () -> [Int16] in
            mixer.append(source: source, samples: samples, startSample: startSample)
            return mixer.drain(before: max(0, endSample - latencySamples))
        }
        sink.append(drained)
    }
}
