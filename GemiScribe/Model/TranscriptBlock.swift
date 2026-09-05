import Foundation

enum TranslationState: Equatable, Sendable {
    case notRequested
    case pending
    case done
    case failed(String)
}

/// One timestamped chunk of transcript, split at a pause in the speech.
struct TranscriptBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Seconds from the start of the recording, measured on the audio clock
    /// (samples streamed / 16000) rather than on wall time, so network lag
    /// does not shift the timestamps.
    var startSec: Double
    var endSec: Double
    var text: String
    var languageCode: String?
    var translation: String?
    var translationState: TranslationState

    init(
        id: UUID = UUID(),
        startSec: Double,
        endSec: Double,
        text: String,
        languageCode: String? = nil,
        translation: String? = nil,
        translationState: TranslationState = .notRequested
    ) {
        self.id = id
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.languageCode = languageCode
        self.translation = translation
        self.translationState = translationState
    }

    var timecode: String { TimecodeFormatter.string(from: startSec) }
}

enum TimecodeFormatter {
    /// `HH:MM:SS`, used both on screen and in the exported files.
    static func string(from seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
