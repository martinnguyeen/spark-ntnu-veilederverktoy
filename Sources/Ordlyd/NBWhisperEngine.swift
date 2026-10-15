import Foundation
import AVFoundation

enum NBWhisperError: LocalizedError {
    case modelMissing, runtimeMissing, recordingPermissionDenied, recordingFailed, transcriptionFailed(String), emptyTranscript
    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Den lokale NB-Whisper-modellen mangler. Last ned Spark-installasjonen på nytt, eller kontakt brukerstøtte."
        case .runtimeMissing: return "Den lokale transkripsjonsmotoren mangler. Installer Spark på nytt, eller kontakt brukerstøtte."
        case .recordingPermissionDenied: return "Ordlyd trenger mikrofontilgang for å ta opp lyd."
        case .recordingFailed: return "Opptaket kunne ikke startes. Kontroller valgt mikrofon."
        case .transcriptionFailed(let detail): return "Lokal transkripsjon mislyktes. \(detail)"
        case .emptyTranscript: return "Ingen tale ble gjenkjent i opptaket."
        }
    }
}

enum WhisperJSONParser {
    private struct Document: Decodable { let transcription: [Entry] }
    private struct Entry: Decodable { let offsets: Offsets; let text: String }
    private struct Offsets: Decodable { let from: Int; let to: Int }

    static func parse(_ data: Data) throws -> [TranscriptSegment] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        return document.transcription.enumerated().compactMap { index, entry in
            let text = clean(entry.text)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(id: "s\(index + 1)", start: Double(entry.offsets.from) / 1000, end: Double(entry.offsets.to) / 1000, speaker: nil, text: text)
        }
    }

    private static func clean(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.first == "\"", text.last == "\"" { text.removeFirst(); text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NBWhisperEngine: SpeechEngine {
    let executableURL: URL
    let modelURL: URL

    static var installed: NBWhisperEngine {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ordlyd/Models/nb-whisper-small-beta/ggml-model.bin")
        let bundledModel = Bundle.main.resourceURL?.appendingPathComponent("ggml-model.bin")
        let model = bundledModel.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? support
        return NBWhisperEngine(executableURL: Self.whisperExecutableURL, modelURL: model)
    }

    static var whisperExecutableURL: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/whisper-cli")
        let candidates = [bundled.path,
            "/opt/homebrew/bin/whisper-cli", // Apple Silicon Homebrew
            "/usr/local/bin/whisper-cli"     // Intel Homebrew
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("whisper-cli").path }

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: candidates[0])
    }

    func transcribe(audioAt url: URL) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw NBWhisperError.modelMissing }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw NBWhisperError.runtimeMissing }
        return try await Task.detached(priority: .userInitiated) {
            let outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ordlyd-\(UUID().uuidString)")
            let process = Process()
            let diagnostics = Pipe()
            process.executableURL = executableURL
            process.arguments = ["-m", modelURL.path, "-f", url.path, "-l", "no", "-oj", "-of", outputRoot.path, "-np"]
            let bundledBackends = executableURL.deletingLastPathComponent().appendingPathComponent("ggml-backends", isDirectory: true)
            if let backend = (try? FileManager.default.contentsOfDirectory(at: bundledBackends, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasPrefix("libggml-cpu") && $0.pathExtension == "so" }) {
                var environment = ProcessInfo.processInfo.environment
                environment["GGML_BACKEND_PATH"] = backend.path
                process.environment = environment
            }
            process.standardOutput = Pipe(); process.standardError = diagnostics
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
                throw NBWhisperError.transcriptionFailed(String(data: data, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? "Ukjent feil.")
            }
            let jsonURL = outputRoot.appendingPathExtension("json")
            defer { try? FileManager.default.removeItem(at: jsonURL) }
            let segments = try WhisperJSONParser.parse(Data(contentsOf: jsonURL))
            guard !segments.isEmpty else { throw NBWhisperError.emptyTranscript }
            return segments
        }.value
    }
}

struct LiveTranscriptBuffer {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var isProvisional = true
    var text: String { segments.map(\.text).joined(separator: " ") }
    mutating func update(_ segments: [TranscriptSegment]) { self.segments = segments; isProvisional = true }
    mutating func finalize() { isProvisional = false }
}

enum WaveEncoder {
    static func encode(samples: [Int16], sampleRate: Int) -> Data {
        let payloadSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36) + payloadSize, to: &data)
        data.append("WAVEfmt ".data(using: .ascii)!)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append("data".data(using: .ascii)!)
        append(payloadSize, to: &data)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

final class LocalAudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var sourcePosition = 0.0
    private let sampleRate = 16_000
    private var recordingURL: URL?

    func start() async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw NBWhisperError.recordingPermissionDenied }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ordlyd/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recordingURL = folder.appendingPathComponent("recording-\(UUID().uuidString).wav")
        lock.withLock { samples.removeAll(keepingCapacity: true); sourcePosition = 0 }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NBWhisperError.recordingFailed }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.consume(buffer, inputRate: format.sampleRate) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw NBWhisperError.recordingFailed }
    }

    func snapshot() throws -> URL? {
        let copy = lock.withLock { samples }
        guard !copy.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ordlyd-live-\(UUID().uuidString).wav")
        try WaveEncoder.encode(samples: copy, sampleRate: sampleRate).write(to: url, options: .atomic)
        return url
    }

    func stop() -> URL? {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        let copy = lock.withLock { samples }
        guard let recordingURL, !copy.isEmpty else { return nil }
        try? WaveEncoder.encode(samples: copy, sampleRate: sampleRate).write(to: recordingURL, options: .atomic)
        return recordingURL
    }

    private func consume(_ buffer: AVAudioPCMBuffer, inputRate: Double) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let ratio = inputRate / Double(sampleRate)
        lock.withLock {
            while sourcePosition < Double(frames) {
                let index = min(Int(sourcePosition), frames - 1)
                var mixed: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) { mixed += channels[channel][index] }
                mixed /= Float(buffer.format.channelCount)
                let clamped = max(-1, min(1, mixed))
                samples.append(Int16(clamped * Float(Int16.max)))
                sourcePosition += ratio
            }
            sourcePosition -= Double(frames)
        }
    }
}
