import Foundation

/// The two languages GemiScribe supports for its own UI and as a translation target.
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case ja
    case en

    var id: String { rawValue }

    /// Always rendered in the language itself, so the picker is readable whichever one is active.
    var displayName: String {
        switch self {
        case .ja: return "日本語"
        case .en: return "English"
        }
    }

    var englishName: String {
        switch self {
        case .ja: return "Japanese"
        case .en: return "English"
        }
    }

    /// Used to render language names in whichever language the interface is in.
    var localeIdentifier: String {
        switch self {
        case .ja: return "ja_JP"
        case .en: return "en_US"
        }
    }

    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true ? .ja : .en
    }
}

/// Language hint sent to the transcription model.
///
/// `auto` leaves `languageCodes` empty, which enables Gemini's own detection across
/// 85+ languages. That is the right default for mixed content, but detection flaps on
/// continuous speech — an English podcast comes back as Spanish for several seconds at
/// a time — so pinning the language is worth doing whenever it is known.
///
/// The API takes an array, which is how bilingual meetings are handled: naming two
/// languages biases towards both instead of forcing a choice between them.
enum SourceLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    // Raw values for these two predate the wider list; keep them so a stored
    // preference survives the change.
    case japanese = "ja"
    case english = "en"
    case japaneseAndEnglish = "ja+en"
    case korean = "ko"
    case chinese = "zh"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case italian = "it"
    case russian = "ru"
    case hindi = "hi"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"

    var id: String { rawValue }

    /// Value for `inputAudioTranscription.languageCodes`; empty means auto-detect.
    var languageCodes: [String] {
        switch self {
        case .auto: return []
        case .japanese: return ["ja-JP"]
        case .english: return ["en-US"]
        case .japaneseAndEnglish: return ["ja-JP", "en-US"]
        case .korean: return ["ko-KR"]
        case .chinese: return ["zh-CN"]
        case .spanish: return ["es-ES"]
        case .french: return ["fr-FR"]
        case .german: return ["de-DE"]
        case .portuguese: return ["pt-BR"]
        case .italian: return ["it-IT"]
        case .russian: return ["ru-RU"]
        case .hindi: return ["hi-IN"]
        case .thai: return ["th-TH"]
        case .vietnamese: return ["vi-VN"]
        case .indonesian: return ["id-ID"]
        }
    }
}
