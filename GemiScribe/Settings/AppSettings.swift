import Foundation
import Observation

/// User preferences, persisted to `UserDefaults`. The Gemini API key is *not* here —
/// it lives in the Keychain (see `KeychainStore`).
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Default {
        static let transcribeModel = "gemini-3.5-transcribe-live"
        static let translateModel = "gemini-3.5-flash-lite"
        static let silenceDurationMs = 700
        static let silenceThresholdDB = -45.0
    }

    var uiLanguage: AppLanguage {
        didSet {
            store(uiLanguage.rawValue, .uiLanguage)
            applyDefaultTranslationTargetIfNeeded()
        }
    }
    var captureSystemAudio: Bool { didSet { store(captureSystemAudio, .captureSystemAudio) } }
    var captureMicrophone: Bool { didSet { store(captureMicrophone, .captureMicrophone) } }
    var smartTranscribe: Bool { didSet { store(smartTranscribe, .smartTranscribe) } }
    var translationEnabled: Bool { didSet { store(translationEnabled, .translationEnabled) } }
    var translationTarget: AppLanguage {
        didSet {
            store(translationTarget.rawValue, .translationTarget)
            guard !isApplyingDefaultTarget else { return }
            hasChosenTranslationTarget = true
            store(true, .translationTargetChosen)
        }
    }

    /// Until the user picks a translation target themselves, it tracks the UI language:
    /// a Japanese interface translates into Japanese, anything else into English.
    private(set) var hasChosenTranslationTarget: Bool
    private var isApplyingDefaultTarget = false
    var sourceLanguage: SourceLanguage { didSet { store(sourceLanguage.rawValue, .sourceLanguage) } }
    var transcribeModel: String { didSet { store(transcribeModel, .transcribeModel) } }
    var translateModel: String { didSet { store(translateModel, .translateModel) } }
    var customVocabularyText: String { didSet { store(customVocabularyText, .customVocabulary) } }
    var silenceDurationMs: Int { didSet { store(silenceDurationMs, .silenceDurationMs) } }
    var silenceThresholdDB: Double { didSet { store(silenceThresholdDB, .silenceThresholdDB) } }
    var debugLogging: Bool { didSet { store(debugLogging, .debugLogging) } }

    /// `--debug` on the command line turns logging on for this run only. Flipping the
    /// stored preference instead would leave it on for every later launch.
    let isDebugLoggingForced: Bool

    /// What the rest of the app should consult.
    var isDebugLoggingEnabled: Bool { debugLogging || isDebugLoggingForced }

    /// Parsed form of `customVocabularyText`, capped at the API's 1000-term limit.
    var customVocabulary: [String] {
        let terms = customVocabularyText
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(terms.prefix(1000))
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         launchArguments: [String] = CommandLine.arguments) {
        self.defaults = defaults
        isDebugLoggingForced = launchArguments.contains("--debug")
        // Held locally as well: with @Observable the stored properties cannot be read
        // back until every one of them has been initialized.
        let resolvedUILanguage = defaults.string(forKey: Key.uiLanguage.rawValue)
            .flatMap(AppLanguage.init(rawValue:)) ?? AppLanguage.systemDefault
        uiLanguage = resolvedUILanguage
        // Default: system audio only, per the app's primary use case (meetings, videos).
        captureSystemAudio = defaults.object(forKey: Key.captureSystemAudio.rawValue) as? Bool ?? true
        captureMicrophone = defaults.object(forKey: Key.captureMicrophone.rawValue) as? Bool ?? false
        smartTranscribe = defaults.object(forKey: Key.smartTranscribe.rawValue) as? Bool ?? false
        translationEnabled = defaults.object(forKey: Key.translationEnabled.rawValue) as? Bool ?? true
        hasChosenTranslationTarget = defaults.bool(forKey: Key.translationTargetChosen.rawValue)
        translationTarget = (defaults.string(forKey: Key.translationTarget.rawValue).flatMap(AppLanguage.init(rawValue:)))
            ?? resolvedUILanguage
        sourceLanguage = (defaults.string(forKey: Key.sourceLanguage.rawValue).flatMap(SourceLanguage.init(rawValue:)))
            ?? .auto
        transcribeModel = defaults.string(forKey: Key.transcribeModel.rawValue) ?? Default.transcribeModel
        translateModel = defaults.string(forKey: Key.translateModel.rawValue) ?? Default.translateModel
        customVocabularyText = defaults.string(forKey: Key.customVocabulary.rawValue) ?? ""
        silenceDurationMs = defaults.object(forKey: Key.silenceDurationMs.rawValue) as? Int ?? Default.silenceDurationMs
        silenceThresholdDB = defaults.object(forKey: Key.silenceThresholdDB.rawValue) as? Double ?? Default.silenceThresholdDB
        debugLogging = defaults.object(forKey: Key.debugLogging.rawValue) as? Bool ?? false
    }

    /// Keeps the default target in step with the interface language, without ever
    /// overriding a target the user selected.
    private func applyDefaultTranslationTargetIfNeeded() {
        guard !hasChosenTranslationTarget, translationTarget != uiLanguage else { return }
        isApplyingDefaultTarget = true
        translationTarget = uiLanguage
        isApplyingDefaultTarget = false
    }

    func resetAdvancedToDefaults() {
        transcribeModel = Default.transcribeModel
        translateModel = Default.translateModel
        silenceDurationMs = Default.silenceDurationMs
        silenceThresholdDB = Default.silenceThresholdDB
        debugLogging = false
    }

    private enum Key: String {
        case uiLanguage, captureSystemAudio, captureMicrophone, smartTranscribe
        case translationEnabled, translationTarget, translationTargetChosen, sourceLanguage
        case transcribeModel, translateModel, customVocabulary
        case silenceDurationMs, silenceThresholdDB, debugLogging
    }

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
