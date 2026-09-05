import AppKit
import Foundation
import Observation
import OSLog

/// Wires audio capture, the Live API session and the transcript together, and exposes
/// the small amount of state the views actually render.
@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let localizer: Localizer
    let transcript = TranscriptStore()

    var status: SessionCoordinator.State = .idle
    var isRecording = false
    /// Deliberately a separate observable: levels change ten times a second and only
    /// the meters should re-render that often.
    let levels = AudioLevels()
    var elapsedSec: Double = 0
    /// Non-nil shows the error banner; `errorOffersPrivacyShortcut` adds the settings button.
    var errorMessage: String?
    var errorOffersPrivacyShortcut = false
    /// The banner shows a dropped connection; it comes down again once the session
    /// is back to listening, so a two-second blip does not read as a dead recording.
    private var errorIsTransientConnectionLoss = false
    var isSettingsPresented = false

    private let audio = AudioSourceManager()
    private let coordinator = SessionCoordinator()
    private let timestamper = BlockTimestamper()
    private let translations = TranslationCoordinator()
    private let mainThreadMonitor = MainThreadMonitor()
    /// Holds back the newest block while it can still absorb the next turn.
    private var settleTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private let logger = Logger(subsystem: "jp.namio.GemiScribe", category: "app")

    /// Sources as configured, used for the meters and the export metadata.
    var selectedSources: Set<AudioMixer.Source> {
        var sources: Set<AudioMixer.Source> = []
        if settings.captureSystemAudio { sources.insert(.system) }
        if settings.captureMicrophone { sources.insert(.microphone) }
        return sources
    }

    var statusLabel: String {
        switch status {
        case .idle: return localizer[.statusIdle]
        case .connecting: return localizer[.statusConnecting]
        case .listening: return localizer[.statusListening]
        case .reconnecting: return localizer[.statusReconnecting]
        case .failed: return localizer[.statusError]
        }
    }

    init(settings: AppSettings = .shared) {
        self.settings = settings
        self.localizer = Localizer(language: settings.uiLanguage)
        wireAudio()
        wireSession()
        wireTranslation()
        if settings.isDebugLoggingForced {
            logger.notice("Debug logging enabled by --debug")
        }
    }

    private func wireTranslation() {
        translations.configProvider = { [weak self] in
            guard let self, let apiKey = KeychainStore.loadAPIKey() else { return nil }
            return .init(apiKey: apiKey,
                         model: self.settings.translateModel,
                         target: self.settings.translationTarget,
                         debugLogging: self.settings.isDebugLoggingEnabled)
        }
        translations.textProvider = { [weak self] id in
            self?.transcript.block(with: id)?.text
        }
        translations.onPending = { [weak self] id in
            self?.transcript.markTranslationPending(id)
        }
        translations.onResult = { [weak self] id, result in
            self?.transcript.applyTranslation(result, to: id)
        }
        translations.onRateLimited = { [weak self] message, retryAfter in
            guard let self else { return }
            // A per-row badge is easy to miss when every row has one; quota problems
            // belong in the banner, together with the way out.
            self.errorMessage = self.localizer.format(.errorTranslationRateLimitedFormat,
                                                      Int(retryAfter.rounded()),
                                                      message)
            self.errorOffersPrivacyShortcut = false
        }
    }

    // MARK: - Wiring

    private func wireAudio() {
        // These hop to the main queue with `async` rather than `Task`, because unstructured
        // tasks carry no ordering guarantee and audio chunks must stay in sequence.
        audio.onChunk = { [weak self] chunk, startSec in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.coordinator.send(chunk, at: startSec) }
            }
        }
        audio.onSpan = { [weak self] span in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.timestamper.noteSpan(span)
                    // A pause is the cheapest place to swap Live API connections.
                    self.coordinator.noteSpeechEnded()
                }
            }
        }
        audio.onLevels = { [weak self] levels in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.levels.update(levels) }
            }
        }
        audio.onSourceFailure = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.present(error: error)
                await self.stop()
            }
        }
    }

    private func wireSession() {
        coordinator.audioStatsProvider = { [weak self] in
            guard let self else { return "" }
            let worstStall = self.mainThreadMonitor.consumeWorst()
            return self.audio.consumeStats().summary
                + " underruns=\(self.audio.consumeUnderruns())"
                + String(format: " mainStall=%.2fs", worstStall)
        }
        coordinator.onState = { [weak self] state in
            guard let self else { return }
            self.status = state
            switch state {
            case .failed(let message):
                self.errorMessage = message
                self.errorOffersPrivacyShortcut = false
                self.errorIsTransientConnectionLoss = false
            case .listening where self.errorIsTransientConnectionLoss:
                self.errorMessage = nil
                self.errorIsTransientConnectionLoss = false
            default:
                break
            }
        }
        coordinator.onConnectionError = { [weak self] message in
            // Shown while reconnection is still being attempted, so a session that dies
            // from a quota or argument error says so instead of silently stalling.
            self?.errorMessage = message
            self?.errorOffersPrivacyShortcut = false
            self?.errorIsTransientConnectionLoss = true
        }
        coordinator.onSalvagePartial = { [weak self] in
            guard let self else { return }
            // The partial is everything the lost connection ever produced for this
            // stretch of audio; dropping it would lose the speech outright.
            let salvaged = self.transcript.interimText
            guard !salvaged.isEmpty else { return }
            let range = self.timestamper.resolve(atAudioTime: self.audio.elapsedSeconds)
            let changes = self.transcript.ingest(FinalizedTurn(
                text: salvaged,
                startSec: range.start,
                endSec: range.end,
                languageCode: nil
            ))
            self.transcript.interimText = ""
            self.scheduleTranslations(after: changes)
        }
        coordinator.onInterim = { [weak self] text in
            guard let self else { return }
            self.transcript.interimText = text
            self.timestamper.noteInterim(atAudioTime: self.audio.elapsedSeconds)
        }
        coordinator.onSpeechActivity = { [weak self] started, audioTime in
            guard let self else { return }
            if started {
                self.timestamper.noteServerActivityStarted(at: audioTime)
            } else if self.timestamper.noteServerActivityEnded(at: audioTime) {
                // The final for this segment arrived a beat earlier and was stamped
                // with the audio clock; the server's own end is the exact one.
                self.transcript.trimLastBlockEnd(to: audioTime)
            }
        }
        coordinator.onFinal = { [weak self] text, languageCode in
            guard let self else { return }
            let range = self.timestamper.resolve(atAudioTime: self.audio.elapsedSeconds)
            let changes = self.transcript.ingest(FinalizedTurn(
                text: text,
                startSec: range.start,
                endSec: range.end,
                languageCode: languageCode
            ))
            self.transcript.interimText = ""
            self.scheduleTranslations(after: changes)
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        Task { isRecording ? await stop() : await start() }
    }

    func start() async {
        errorMessage = nil
        errorOffersPrivacyShortcut = false
        errorIsTransientConnectionLoss = false

        guard let apiKey = KeychainStore.loadAPIKey() else {
            errorMessage = localizer[.errorNoAPIKey]
            isSettingsPresented = true
            return
        }
        let sources = selectedSources
        guard !sources.isEmpty else {
            errorMessage = localizer[.errorNoSource]
            return
        }

        timestamper.reset()
        transcript.beginRecording()
        transcript.interimText = ""

        coordinator.start(configuration: .init(
            apiKey: apiKey,
            model: settings.transcribeModel,
            languageCodes: settings.sourceLanguage.languageCodes,
            customVocabulary: settings.customVocabulary,
            smartTranscribe: settings.smartTranscribe,
            debugLogging: settings.isDebugLoggingEnabled
        ))

        do {
            try await audio.start(sources: sources,
                                  thresholdDB: settings.silenceThresholdDB,
                                  hangoverMs: settings.silenceDurationMs,
                                  // Resume the timeline so a second take does not
                                  // restart the timestamps on top of the first.
                                  timeOffset: transcript.durationSec)
        } catch {
            await coordinator.stop()
            present(error: error)
            return
        }

        isRecording = true
        startElapsedTimer()
        mainThreadMonitor.start()
    }

    func stop() async {
        guard isRecording || status != .idle else { return }
        isRecording = false
        // Nothing more can merge into the last block now.
        settleTask?.cancel()
        settleTask = nil
        if let last = transcript.blocks.last { translate(last.id) }
        stopElapsedTimer()
        mainThreadMonitor.stop()
        await audio.stop()
        // Give the tail of the audio a moment to come back as text before closing.
        await coordinator.stop()
        transcript.interimText = ""
        transcript.updateDuration(audio.elapsedSeconds)
        levels.reset()
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = self.audio.elapsedSeconds
                // The clock reads in whole seconds, so publishing four times a second
                // would re-render the control bar and footer for nothing. `stop()`
                // records the exact duration afterwards.
                guard Int(elapsed) != Int(self.elapsedSec) else { return }
                self.elapsedSec = elapsed
                self.transcript.updateDuration(elapsed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// Applies a mid-recording change to the source toggles. Turning off the last
    /// remaining source ends the recording rather than streaming silence indefinitely.
    func applySourceChange() {
        guard isRecording else { return }
        let sources = selectedSources
        guard !sources.isEmpty else {
            errorMessage = localizer[.errorNoSource]
            Task { await stop() }
            return
        }
        Task {
            do {
                try await audio.updateSources(sources)
            } catch {
                present(error: error)
                await stop()
            }
        }
    }

    // MARK: - Translation

    /// Queues a block for translation. Requests are batched and paced by
    /// `TranslationCoordinator`; one request per block exhausts the API quota.
    ///
    /// Without `force` a block that already has a translation, has one in flight, or
    /// whose last attempt failed is left alone — this is called for every settled block
    /// on every turn, and retrying failures automatically would hammer a dead quota.
    func translate(_ id: UUID, force: Bool = false) {
        guard settings.translationEnabled else { return }
        guard let block = transcript.block(with: id), !block.text.isEmpty else { return }
        if !force, block.translationState != .notRequested { return }
        translations.enqueue(id)
    }

    /// Only the newest block can still absorb the next turn, so every earlier block is
    /// settled and safe to translate. Translating the newest one straight away would
    /// mean paying for half a sentence and then paying again once it merges.
    private func scheduleTranslations(after changes: [BlockChange]) {
        guard !changes.isEmpty else { return }
        settleTask?.cancel()
        settleTask = nil

        let blocks = transcript.blocks
        for block in blocks.dropLast() { translate(block.id) }

        guard let last = blocks.last else { return }
        if transcript.isSettled(last) {
            translate(last.id)
            return
        }
        // A tail of a few words is translated once it has been completed by the next
        // turn (or at stop); translating "So that's" on its own buys nothing.
        if transcript.isFragment(last) { return }

        let id = last.id
        let delay = transcript.mergeWindowSec
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.translate(id)
        }
    }

    /// Fills in blocks that have no translation yet — used when the toggle is switched on
    /// mid-session.
    func translateMissing() {
        guard settings.translationEnabled else { return }
        for block in transcript.blocks where block.translation == nil {
            translate(block.id, force: true)
        }
    }

    /// Re-runs every block against the new target language, discarding anything queued
    /// or in flight for the old one.
    func retranslateAll() {
        translations.reset()
        guard settings.translationEnabled else { return }
        for block in transcript.blocks {
            translate(block.id, force: true)
        }
    }

    // MARK: - Transcript actions

    func clearTranscript() {
        settleTask?.cancel()
        settleTask = nil
        translations.reset()
        transcript.clear()
        timestamper.reset()
        elapsedSec = 0
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Export

    func save(format: ExportFormat) {
        guard !transcript.blocks.isEmpty else { return }
        let recordedAt = transcript.recordedAt ?? Date()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = TranscriptExporter.suggestedFilename(for: format, recordedAt: recordedAt)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let metadata = TranscriptExporter.Metadata(
            recordedAt: recordedAt,
            durationSec: transcript.durationSec,
            capturedSystemAudio: settings.captureSystemAudio,
            capturedMicrophone: settings.captureMicrophone,
            transcribeModel: settings.transcribeModel,
            smartTranscribe: settings.smartTranscribe,
            sourceLanguage: settings.sourceLanguage,
            translationEnabled: settings.translationEnabled,
            translationTarget: settings.translationTarget,
            translateModel: settings.translateModel
        )

        do {
            let data = try TranscriptExporter.data(for: format,
                                                   blocks: transcript.blocks,
                                                   metadata: metadata,
                                                   localizer: localizer)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = localizer.format(.saveFailedFormat, error.localizedDescription)
            errorOffersPrivacyShortcut = false
        }
    }

    // MARK: - Errors

    private func present(error: Error) {
        errorOffersPrivacyShortcut = false
        switch error {
        case AudioCaptureError.screenRecordingPermissionDenied:
            errorMessage = localizer[.errorScreenPermission]
            errorOffersPrivacyShortcut = true
        case AudioCaptureError.microphonePermissionDenied:
            errorMessage = localizer[.errorMicPermission]
            errorOffersPrivacyShortcut = true
        default:
            errorMessage = error.localizedDescription
            logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openPrivacySettings() {
        let path = errorOffersPrivacyShortcut && errorMessage == localizer[.errorMicPermission]
            ? "Privacy_Microphone"
            : "Privacy_ScreenCapture"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)") else { return }
        NSWorkspace.shared.open(url)
    }
}
