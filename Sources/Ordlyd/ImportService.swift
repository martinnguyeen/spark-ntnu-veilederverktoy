import Foundation
import AppKit

enum ImportError: LocalizedError {
    case emptyText, unreadableText, audioConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyText: "Tekstdokumentet er tomt."
        case .unreadableText: "Tekstdokumentet kunne ikke leses. Bruk en vanlig TXT- eller Markdown-fil."
        case .audioConversionFailed(let detail): "Lydfilen kunne ikke klargjøres. \(detail)"
        }
    }
}

enum ImportedTextDocument {
    static func read(from url: URL) throws -> String {
        try decode(data: Data(contentsOf: url))
    }

    static func decode(data: Data) throws -> String {
        if data.starts(with: Data("{\\rtf".utf8)) {
            guard let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
                throw ImportError.unreadableText
            }
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ImportError.unreadableText
        }
        return text
    }

    static func segments(from text: String) throws -> [TranscriptSegment] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ImportError.emptyText }
        return clean.components(separatedBy: .newlines).compactMap { line -> (String?, String)? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("Speaker "), let colon = trimmed.firstIndex(of: ":") {
                let speaker = String(trimmed[..<colon])
                let spoken = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty { return (speaker, spoken) }
            }
            return (nil, trimmed)
        }.enumerated().map { offset, content in
            TranscriptSegment(id: "s\(offset + 1)", start: 0, end: 0, speaker: content.0, text: content.1)
        }
    }
}

enum ImportedAudioConverter {
    static func destinationURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ordlyd-import-\(UUID().uuidString).wav")
    }

    static func convertToWhisperWAV(_ source: URL) async throws -> URL {
        let destination = destinationURL()
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let diagnostics = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = [source.path, destination.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
            process.standardOutput = Pipe()
            process.standardError = diagnostics
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ImportError.audioConversionFailed(detail?.isEmpty == false ? detail! : "Formatet støttes ikke av macOS.")
            }
            return destination
        }.value
    }
}
