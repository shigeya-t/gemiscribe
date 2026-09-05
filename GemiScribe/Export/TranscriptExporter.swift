import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case json

    var id: String { rawValue }
    var fileExtension: String { self == .markdown ? "md" : "json" }
    var contentType: UTType { self == .markdown ? .init(filenameExtension: "md") ?? .plainText : .json }
    var locKey: LocKey { self == .markdown ? .saveMarkdown : .saveJSON }
}

/// Renders a finished transcript as Markdown or JSON.
enum TranscriptExporter {

    struct Metadata {
        var recordedAt: Date
        var durationSec: Double
        var capturedSystemAudio: Bool
        var capturedMicrophone: Bool
        var transcribeModel: String
        var smartTranscribe: Bool
        var sourceLanguage: SourceLanguage
        var translationEnabled: Bool
        var translationTarget: AppLanguage
        var translateModel: String
    }

    static func data(for format: ExportFormat,
                     blocks: [TranscriptBlock],
                     metadata: Metadata,
                     localizer: Localizer) throws -> Data {
        switch format {
        case .markdown:
            return Data(markdown(blocks: blocks, metadata: metadata, localizer: localizer).utf8)
        case .json:
            return try json(blocks: blocks, metadata: metadata)
        }
    }

    static func suggestedFilename(for format: ExportFormat, recordedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "GemiScribe-\(formatter.string(from: recordedAt)).\(format.fileExtension)"
    }

    // MARK: - Markdown

    static func markdown(blocks: [TranscriptBlock],
                         metadata: Metadata,
                         localizer: Localizer) -> String {
        var lines: [String] = []
        lines.append("# \(localizer[.exportTitle])")
        lines.append("")
        lines.append("- \(localizer[.exportDate]): \(dateString(metadata.recordedAt))")
        lines.append("- \(localizer[.exportDuration]): \(TimecodeFormatter.string(from: metadata.durationSec))")
        lines.append("- \(localizer[.exportSources]): \(sourceNames(metadata, localizer: localizer))")
        let mode = metadata.smartTranscribe ? "SMART" : "VERBATIM"
        lines.append("- \(localizer[.exportModel]): \(metadata.transcribeModel) (\(mode))")
        if metadata.translationEnabled {
            let target = localizer.name(of: metadata.translationTarget)
            lines.append("- \(localizer[.exportTranslation]): \(target) (\(metadata.translateModel))")
        } else {
            lines.append("- \(localizer[.exportTranslation]): \(localizer[.exportDisabled])")
        }
        lines.append("")

        for block in blocks {
            lines.append("## [\(block.timecode)]")
            lines.append("- \(escapeListItem(block.text))")
            if let translation = block.translation, !translation.isEmpty {
                lines.append("- \(escapeListItem(translation))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Keeps multi-line transcript text inside its list item.
    private static func escapeListItem(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\n  ")
    }

    // MARK: - JSON

    static func json(blocks: [TranscriptBlock], metadata: Metadata) throws -> Data {
        let root: [String: Any] = [
            "app": "GemiScribe",
            "version": 1,
            "recordedAt": ISO8601DateFormatter().string(from: metadata.recordedAt),
            "durationSec": rounded(metadata.durationSec),
            "sources": sourceIdentifiers(metadata),
            "transcription": [
                "model": metadata.transcribeModel,
                "mode": metadata.smartTranscribe ? "SMART" : "VERBATIM",
                "languageCodes": metadata.sourceLanguage.languageCodes,
            ],
            "translation": [
                "enabled": metadata.translationEnabled,
                "targetLanguage": metadata.translationTarget.rawValue,
                "model": metadata.translateModel,
            ],
            "blocks": blocks.enumerated().map { index, block -> [String: Any] in
                var entry: [String: Any] = [
                    "index": index,
                    "startSec": rounded(block.startSec),
                    "endSec": rounded(block.endSec),
                    "startTimecode": block.timecode,
                    "text": block.text,
                ]
                if let language = block.languageCode { entry["detectedLanguage"] = language }
                if let translation = block.translation { entry["translation"] = translation }
                return entry
            },
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Helpers

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func sourceIdentifiers(_ metadata: Metadata) -> [String] {
        var sources: [String] = []
        if metadata.capturedSystemAudio { sources.append("system") }
        if metadata.capturedMicrophone { sources.append("microphone") }
        return sources
    }

    private static func sourceNames(_ metadata: Metadata, localizer: Localizer) -> String {
        var names: [String] = []
        if metadata.capturedSystemAudio { names.append(localizer[.sourceSystemAudio]) }
        if metadata.capturedMicrophone { names.append(localizer[.sourceMicrophone]) }
        return names.isEmpty ? "-" : names.joined(separator: ", ")
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss (zzz)"
        return formatter.string(from: date)
    }
}
