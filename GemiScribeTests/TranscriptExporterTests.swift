import XCTest
@testable import GemiScribe

final class TranscriptExporterTests: XCTestCase {

    private let recordedAt = Date(timeIntervalSince1970: 1_756_704_730)

    private func metadata(translationEnabled: Bool = true) -> TranscriptExporter.Metadata {
        TranscriptExporter.Metadata(
            recordedAt: recordedAt,
            durationSec: 754.2,
            capturedSystemAudio: true,
            capturedMicrophone: true,
            transcribeModel: "gemini-3.5-transcribe-live",
            smartTranscribe: true,
            sourceLanguage: .auto,
            translationEnabled: translationEnabled,
            translationTarget: .en,
            translateModel: "gemini-3.5-flash-lite"
        )
    }

    private var blocks: [TranscriptBlock] {
        [
            TranscriptBlock(startSec: 4.12, endSec: 8.9,
                            text: "今日はお集まりいただきありがとうございます。",
                            languageCode: "ja-JP",
                            translation: "Thank you all for joining today.",
                            translationState: .done),
            TranscriptBlock(startSec: 11.0, endSec: 15.0,
                            text: "まず前回の議事録を確認しましょう。",
                            languageCode: "ja-JP",
                            translation: nil,
                            translationState: .notRequested),
        ]
    }

    // MARK: - Markdown

    func testMarkdownPutsTranscriptAndTranslationOnSeparateListItems() {
        let markdown = TranscriptExporter.markdown(blocks: blocks,
                                                   metadata: metadata(),
                                                   localizer: Localizer(language: .ja))
        XCTAssertTrue(markdown.contains("## [00:00:04]"))
        XCTAssertTrue(markdown.contains("- 今日はお集まりいただきありがとうございます。"))
        XCTAssertTrue(markdown.contains("- Thank you all for joining today."))
    }

    func testMarkdownOmitsTheTranslationItemWhenThereIsNone() {
        let markdown = TranscriptExporter.markdown(blocks: blocks,
                                                   metadata: metadata(),
                                                   localizer: Localizer(language: .ja))
        let lines = markdown.components(separatedBy: "\n")
        guard let headingIndex = lines.firstIndex(of: "## [00:00:11]") else {
            return XCTFail("Second block heading missing")
        }
        XCTAssertEqual(lines[headingIndex + 1], "- まず前回の議事録を確認しましょう。")
        XCTAssertEqual(lines[headingIndex + 2], "")
    }

    func testMarkdownHeaderRecordsTheTranscriptionMode() {
        let smart = TranscriptExporter.markdown(blocks: blocks,
                                                metadata: metadata(),
                                                localizer: Localizer(language: .en))
        XCTAssertTrue(smart.contains("gemini-3.5-transcribe-live (SMART)"))
        XCTAssertTrue(smart.contains("Duration: 00:12:34"))
    }

    func testMarkdownHeaderMarksTranslationOff() {
        let markdown = TranscriptExporter.markdown(blocks: blocks,
                                                   metadata: metadata(translationEnabled: false),
                                                   localizer: Localizer(language: .en))
        XCTAssertTrue(markdown.contains("Translation: off"))
    }

    func testMarkdownFollowsTheSelectedUILanguage() {
        let japanese = TranscriptExporter.markdown(blocks: blocks,
                                                   metadata: metadata(),
                                                   localizer: Localizer(language: .ja))
        XCTAssertTrue(japanese.contains("# GemiScribe 文字起こし"))
        XCTAssertTrue(japanese.contains("- 音声ソース: システム音声, マイク"))
    }

    // MARK: - JSON

    func testJSONStructure() throws {
        let data = try TranscriptExporter.json(blocks: blocks, metadata: metadata())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["app"] as? String, "GemiScribe")
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["durationSec"] as? Double, 754.2)
        XCTAssertEqual(root["sources"] as? [String], ["system", "microphone"])

        let transcription = try XCTUnwrap(root["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "SMART")
        XCTAssertEqual(transcription["languageCodes"] as? [String], [])

        let translation = try XCTUnwrap(root["translation"] as? [String: Any])
        XCTAssertEqual(translation["enabled"] as? Bool, true)
        XCTAssertEqual(translation["targetLanguage"] as? String, "en")

        let entries = try XCTUnwrap(root["blocks"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["index"] as? Int, 0)
        XCTAssertEqual(entries[0]["startTimecode"] as? String, "00:00:04")
        XCTAssertEqual(entries[0]["startSec"] as? Double, 4.12)
        XCTAssertEqual(entries[0]["detectedLanguage"] as? String, "ja-JP")
        XCTAssertEqual(entries[0]["translation"] as? String, "Thank you all for joining today.")
        // A block with no translation omits the key rather than emitting null.
        XCTAssertNil(entries[1]["translation"])
    }

    func testSuggestedFilenameUsesTheFormatExtension() {
        XCTAssertTrue(TranscriptExporter.suggestedFilename(for: .markdown, recordedAt: recordedAt).hasSuffix(".md"))
        XCTAssertTrue(TranscriptExporter.suggestedFilename(for: .json, recordedAt: recordedAt).hasSuffix(".json"))
    }
}
