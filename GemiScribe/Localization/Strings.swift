import Foundation
import Observation

/// Every user-visible string in the app. Using an enum (rather than raw string keys)
/// means a missing translation is a compile error in `Strings`, and `LocalizationTests`
/// can assert both tables are complete by iterating `allCases`.
enum LocKey: String, CaseIterable, Sendable {
    // Header
    case appTitle
    case uiLanguage
    case settings

    // Control bar
    case startRecording
    case stopRecording
    case sourceSystemAudio
    case sourceMicrophone
    case smartTranscribe
    case smartTranscribeHelp
    case translate
    case translateTo
    case sourceLanguage
    case sourceLanguageAuto
    case sourceLanguageHelp
    case languageJapanese
    case languageEnglish

    // Status
    case statusIdle
    case statusStarting
    case statusConnecting
    case statusListening
    case statusReconnecting
    case statusStopping
    case statusError

    // Transcript
    case listening
    case emptyTitle
    case emptySubtitle
    case waitingTitle
    case waitingSubtitle
    case copyText
    case copyBoth
    case retranslate
    case translating
    case translationFailed

    // Footer
    case blockCountFormat
    case clear
    case clearConfirmTitle
    case clearConfirmMessage
    case cancel
    case delete
    case save
    case saveMarkdown
    case saveJSON

    // Settings
    case settingsTitle
    case apiKeySection
    case apiKey
    case apiKeyPlaceholder
    case apiKeyHelp
    case getApiKey
    case testConnection
    case testing
    case testSuccess
    case testFailedFormat
    case modelsSection
    case transcribeModel
    case translateModel
    case vocabularySection
    case customVocabulary
    case customVocabularyHelp
    case customVocabularyPlaceholder
    case advancedSection
    case silenceDuration
    case silenceDurationHelp
    case silenceThreshold
    case silenceThresholdHelp
    case debugLogging
    case debugLoggingHelp
    case debugLoggingForced
    case resetDefaults
    case close

    // Errors
    case errorNoAPIKey
    case errorTranslationRateLimitedFormat
    case errorNoSource
    case errorScreenPermission
    case errorMicPermission
    case openPrivacySettings
    case dismiss

    // Export document labels
    case exportTitle
    case exportDate
    case exportDuration
    case exportSources
    case exportModel
    case exportTranslation
    case exportDisabled
    case saveFailedFormat
}

enum Strings {
    static let ja: [LocKey: String] = [
        .appTitle: "GemiScribe",
        .uiLanguage: "表示言語",
        .settings: "設定",

        .startRecording: "録音開始",
        .stopRecording: "停止",
        .sourceSystemAudio: "システム音声",
        .sourceMicrophone: "マイク",
        .smartTranscribe: "スマート書き起こし",
        .smartTranscribeHelp: "「えー」などのフィラーを取り除き、句読点や箇条書きを整えます。",
        .translate: "翻訳",
        .translateTo: "翻訳先",
        .sourceLanguage: "認識言語",
        .sourceLanguageAuto: "自動判定",
        .sourceLanguageHelp: "話されている言語を固定すると認識が安定します。自動判定は連続した発話で別言語に振れることがあります。録音中は変更できません。",
        .languageJapanese: "日本語",
        .languageEnglish: "英語",

        .statusIdle: "待機中",
        .statusStarting: "開始中…",
        .statusConnecting: "接続中…",
        .statusListening: "認識中",
        .statusReconnecting: "再接続中…",
        .statusStopping: "停止中…",
        .statusError: "エラー",

        .listening: "聞き取り中…",
        .emptyTitle: "まだ文字起こしはありません",
        .emptySubtitle: "音声ソースを選んで「録音開始」を押してください。",
        .waitingTitle: "聞き取り中…",
        .waitingSubtitle: "発話の切れ目でブロックが確定します。スマート書き起こしは部分結果を出さないことがあるため、最初の1ブロックまで時間がかかる場合があります。",
        .copyText: "原文をコピー",
        .copyBoth: "原文と翻訳をコピー",
        .retranslate: "翻訳をやり直す",
        .translating: "翻訳中…",
        .translationFailed: "翻訳に失敗しました",

        .blockCountFormat: "%d ブロック / %@",
        .clear: "クリア",
        .clearConfirmTitle: "文字起こしを消去しますか？",
        .clearConfirmMessage: "この操作は取り消せません。保存していない内容は失われます。",
        .cancel: "キャンセル",
        .delete: "消去",
        .save: "保存",
        .saveMarkdown: "Markdown (.md)",
        .saveJSON: "JSON (.json)",

        .settingsTitle: "設定",
        .apiKeySection: "Gemini API",
        .apiKey: "API キー",
        .apiKeyPlaceholder: "AIza…",
        .apiKeyHelp: "キーは macOS のキーチェーンに保存されます。",
        .getApiKey: "API キーを取得",
        .testConnection: "接続テスト",
        .testing: "テスト中…",
        .testSuccess: "接続に成功しました。",
        .testFailedFormat: "接続に失敗しました: %@",
        .modelsSection: "モデル",
        .transcribeModel: "文字起こし",
        .translateModel: "翻訳",
        .vocabularySection: "カスタム語彙",
        .customVocabulary: "固有名詞・専門用語",
        .customVocabularyHelp: "改行またはカンマ区切りで最大 1000 語。20〜100 語程度が最も効果的です。",
        .customVocabularyPlaceholder: "例: 山田太郎, 田中部長, 第 3 四半期\n新宿オフィス\n定例会議",
        .advancedSection: "詳細",
        .silenceDuration: "無音と判定する長さ",
        .silenceDurationHelp: "ローカルの無音判定に使います。タイムスタンプは通常サーバーの区間情報から取り、これはその予備と、接続切替のタイミングに使われます。",
        .silenceThreshold: "無音と判定するレベル",
        .silenceThresholdHelp: "これより静かな音は無音として扱います。",
        .debugLogging: "デバッグログ",
        .debugLoggingHelp: "送受信した JSON をコンソールに出力します。",
        .debugLoggingForced: "--debug 付きで起動されているため、この実行中は常に有効です。",
        .resetDefaults: "既定値に戻す",
        .close: "閉じる",

        .errorNoAPIKey: "Gemini API キーが設定されていません。設定から入力してください。",
        .errorTranslationRateLimitedFormat: "翻訳が API の利用上限に達しました。%d 秒後に再試行します。無料枠を使い切っている場合は、翻訳トグルを OFF にすれば文字起こしはそのまま続けられます。(%@)",
        .errorNoSource: "音声ソースが選択されていません。システム音声かマイクを ON にしてください。",
        .errorScreenPermission: "システム音声の取得には「画面収録」の許可が必要です。",
        .errorMicPermission: "マイクの使用が許可されていません。",
        .openPrivacySettings: "プライバシー設定を開く",
        .dismiss: "閉じる",

        .exportTitle: "GemiScribe 文字起こし",
        .exportDate: "日時",
        .exportDuration: "長さ",
        .exportSources: "音声ソース",
        .exportModel: "モデル",
        .exportTranslation: "翻訳",
        .exportDisabled: "なし",
        .saveFailedFormat: "保存に失敗しました: %@",
    ]

    static let en: [LocKey: String] = [
        .appTitle: "GemiScribe",
        .uiLanguage: "Language",
        .settings: "Settings",

        .startRecording: "Start Recording",
        .stopRecording: "Stop",
        .sourceSystemAudio: "System Audio",
        .sourceMicrophone: "Microphone",
        .smartTranscribe: "Smart Transcribe",
        .smartTranscribeHelp: "Removes filler words and applies punctuation, casing and list formatting.",
        .translate: "Translate",
        .translateTo: "Into",
        .sourceLanguage: "Spoken language",
        .sourceLanguageAuto: "Auto-detect",
        .sourceLanguageHelp: "Pinning the spoken language steadies recognition; auto-detect can flip to another language during continuous speech. Cannot be changed while recording.",
        .languageJapanese: "Japanese",
        .languageEnglish: "English",

        .statusIdle: "Idle",
        .statusStarting: "Starting…",
        .statusConnecting: "Connecting…",
        .statusListening: "Listening",
        .statusReconnecting: "Reconnecting…",
        .statusStopping: "Stopping…",
        .statusError: "Error",

        .listening: "Listening…",
        .emptyTitle: "No transcript yet",
        .emptySubtitle: "Pick an audio source and press Start Recording.",
        .waitingTitle: "Listening…",
        .waitingSubtitle: "Blocks are finalized at pauses in the speech. Smart Transcribe may not emit partial results, so the first block can take a while.",
        .copyText: "Copy transcript",
        .copyBoth: "Copy transcript and translation",
        .retranslate: "Translate again",
        .translating: "Translating…",
        .translationFailed: "Translation failed",

        .blockCountFormat: "%d blocks / %@",
        .clear: "Clear",
        .clearConfirmTitle: "Clear the transcript?",
        .clearConfirmMessage: "This cannot be undone. Anything you have not saved will be lost.",
        .cancel: "Cancel",
        .delete: "Clear",
        .save: "Save",
        .saveMarkdown: "Markdown (.md)",
        .saveJSON: "JSON (.json)",

        .settingsTitle: "Settings",
        .apiKeySection: "Gemini API",
        .apiKey: "API key",
        .apiKeyPlaceholder: "AIza…",
        .apiKeyHelp: "The key is stored in the macOS Keychain.",
        .getApiKey: "Get an API key",
        .testConnection: "Test connection",
        .testing: "Testing…",
        .testSuccess: "Connection succeeded.",
        .testFailedFormat: "Connection failed: %@",
        .modelsSection: "Models",
        .transcribeModel: "Transcription",
        .translateModel: "Translation",
        .vocabularySection: "Custom vocabulary",
        .customVocabulary: "Names and jargon",
        .customVocabularyHelp: "Up to 1000 terms, separated by newlines or commas. Around 20–100 works best.",
        .customVocabularyPlaceholder: "e.g. Siobhan Hughes, Acme Corp, Q3 roadmap\nKanban board\nOnboarding",
        .advancedSection: "Advanced",
        .silenceDuration: "Silence length",
        .silenceDurationHelp: "Used by the local silence detector. Timestamps normally come from the server's segment timing; this is the fallback, and it also picks the moment to swap connections.",
        .silenceThreshold: "Silence level",
        .silenceThresholdHelp: "Audio quieter than this counts as silence.",
        .debugLogging: "Debug logging",
        .debugLoggingHelp: "Print the JSON sent to and received from the Live API.",
        .debugLoggingForced: "Forced on for this run because the app was launched with --debug.",
        .resetDefaults: "Reset to defaults",
        .close: "Close",

        .errorNoAPIKey: "No Gemini API key is set. Add one in Settings.",
        .errorTranslationRateLimitedFormat: "Translation hit the API rate limit; retrying in %d s. If the free tier is exhausted, switch the Translate toggle off and transcription keeps running. (%@)",
        .errorNoSource: "No audio source selected. Turn on System Audio or Microphone.",
        .errorScreenPermission: "Capturing system audio requires Screen Recording permission.",
        .errorMicPermission: "Microphone access was not granted.",
        .openPrivacySettings: "Open Privacy Settings",
        .dismiss: "Dismiss",

        .exportTitle: "GemiScribe Transcript",
        .exportDate: "Recorded",
        .exportDuration: "Duration",
        .exportSources: "Audio sources",
        .exportModel: "Model",
        .exportTranslation: "Translation",
        .exportDisabled: "off",
        .saveFailedFormat: "Could not save: %@",
    ]

    static func table(for language: AppLanguage) -> [LocKey: String] {
        switch language {
        case .ja: return ja
        case .en: return en
        }
    }
}

/// Holds the runtime-selected UI language. SwiftUI's `.strings` lookup follows the
/// system locale and cannot be switched from a picker, so the app resolves strings itself.
@Observable
final class Localizer {
    var language: AppLanguage {
        didSet { AppSettings.shared.uiLanguage = language }
    }

    init(language: AppLanguage) {
        self.language = language
    }

    subscript(key: LocKey) -> String {
        Strings.table(for: language)[key] ?? key.rawValue
    }

    func format(_ key: LocKey, _ arguments: CVarArg...) -> String {
        String(format: self[key], arguments: arguments)
    }

    /// Menu label for a spoken-language choice.
    ///
    /// The names come from `Locale` rather than the string table: hand-writing every
    /// language in both interface languages is a table that goes stale, and Foundation
    /// already knows them.
    func name(of source: SourceLanguage) -> String {
        guard source != .auto else { return self[.sourceLanguageAuto] }
        let locale = Locale(identifier: language.localeIdentifier)
        return source.languageCodes
            .map { code in
                let base = String(code.prefix(while: { $0 != "-" }))
                return locale.localizedString(forLanguageCode: base) ?? code
            }
            .joined(separator: " + ")
    }

    /// Localized label for a translation-target / spoken-language choice.
    func name(of language: AppLanguage) -> String {
        self[language == .ja ? .languageJapanese : .languageEnglish]
    }
}
