import Foundation
import OSLog

/// One WebSocket connection to the Live API. Short-lived by design: the service caps a
/// connection at roughly ten minutes, so `SessionCoordinator` keeps replacing these.
final class LiveTranscriptionClient: NSObject {

    struct Configuration {
        var apiKey: String
        var model: String
        var languageCodes: [String]
        var customVocabulary: [String]
        var smartTranscribe: Bool
        var resumptionHandle: String?
        var debugLogging: Bool
    }

    enum Event {
        /// `setupComplete` received — safe to stream audio.
        case ready
        case interim(String)
        case final(text: String, languageCode: String?)
        /// A resumption token to carry into the next connection.
        case resumptionHandle(String)
        /// The server will hang up shortly.
        case goAway(timeLeftSec: Double?)
        /// The server's VAD opened or closed a segment, at `audioOffsetSec` into the
        /// audio sent on this connection.
        case voiceActivity(started: Bool, audioOffsetSec: Double)
        case closed(Error?)
    }

    /// Delivered on `callbackQueue` (the main queue unless overridden).
    var onEvent: ((Event) -> Void)?

    private let configuration: Configuration
    private let callbackQueue: DispatchQueue
    private let sendQueue = DispatchQueue(label: "jp.namio.GemiScribe.liveSend")
    private let logger = Logger(subsystem: "jp.namio.GemiScribe", category: "live")

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var hasClosed = false
    private let sendCountLock = NSLock()
    private var sendsInFlight = 0

    /// Messages handed to the socket that it has not confirmed sending yet. A number
    /// that keeps climbing in the heartbeat means the network, not the service, is
    /// where the audio is stuck.
    var pendingSendCount: Int {
        sendCountLock.lock(); defer { sendCountLock.unlock() }
        return sendsInFlight
    }

    private(set) var isReady = false
    /// Audio-clock time of the first chunk sent on this connection. The server reports
    /// voice activity as an offset into the audio it received, so this is what turns
    /// those offsets back into recording time.
    private(set) var firstAudioStartSec: Double?
    /// Total audio injected by `injectAudio` — padding that is not part of the
    /// recording. The server counts it like anything else it receives, so its offsets
    /// run this much ahead of the recording clock.
    private(set) var injectedAudioSec: Double = 0
    /// Retained after the socket dies: the service reports quota and argument problems
    /// as a close frame, so this is often the only explanation available.
    private(set) var lastCloseCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var lastCloseReason: String?

    /// Human-readable close description for the UI, or nil if the socket closed cleanly.
    var closeDescription: String? {
        if let reason = lastCloseReason, !reason.isEmpty { return reason }
        guard lastCloseCode != .invalid, lastCloseCode != .normalClosure else { return nil }
        return "WebSocket closed (code \(lastCloseCode.rawValue))"
    }

    init(configuration: Configuration, callbackQueue: DispatchQueue = .main) {
        self.configuration = configuration
        self.callbackQueue = callbackQueue
        super.init()
    }

    // MARK: - Lifecycle

    func connect() {
        guard let url = LiveProtocol.endpoint(apiKey: configuration.apiKey) else {
            emit(.closed(LiveError.badEndpoint))
            return
        }

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: sessionConfiguration)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task

        task.resume()
        receiveNext()
        sendSetup()
    }

    func close() {
        guard !hasClosed else { return }
        hasClosed = true
        isReady = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Sending

    func send(audio: Data, at startSec: Double) {
        guard isReady else { return }
        if firstAudioStartSec == nil { firstAudioStartSec = startSec }
        let message = LiveProtocol.RealtimeInputMessage(
            realtimeInput: .init(audio: .init(data: audio.base64EncodedString(),
                                              mimeType: AudioFormatSpec.mimeType),
                                 audioStreamEnd: nil)
        )
        transmit(message)
    }

    /// Sends padding the recording's clock does not account for: silence, and audio
    /// the previous segment already covered. The service ignores the audio that
    /// arrives immediately after a turn boundary while its VAD looks for a speech
    /// onset, so whatever occupies that window is lost — this is what gives it
    /// something harmless to lose. Padding advances the server's offsets, which
    /// `injectedAudioSec` takes back out.
    func injectAudio(_ chunks: [Data]) {
        guard isReady, !chunks.isEmpty else { return }
        for chunk in chunks {
            transmit(LiveProtocol.RealtimeInputMessage(
                realtimeInput: .init(audio: .init(data: chunk.base64EncodedString(),
                                                  mimeType: AudioFormatSpec.mimeType),
                                     audioStreamEnd: nil)
            ))
        }
        injectedAudioSec += Double(chunks.count) * AudioFormatSpec.frameDurationSec
    }

    /// Ends the current turn without ending the session — the documented "hybrid VAD"
    /// signal. The server finalizes whatever it is holding; audio sent afterwards
    /// simply starts the next turn. Also used as the last message before a socket is
    /// retired, so its trailing transcript gets flushed.
    func flushTurn() {
        guard isReady else { return }
        transmit(LiveProtocol.RealtimeInputMessage(
            realtimeInput: .init(audio: nil, audioStreamEnd: true)
        ))
    }

    private func sendSetup() {
        let transcription = LiveProtocol.InputAudioTranscription(
            languageCodes: configuration.languageCodes,
            customVocabulary: configuration.customVocabulary,
            mode: configuration.smartTranscribe
                ? LiveProtocol.InputAudioTranscription.smart
                : LiveProtocol.InputAudioTranscription.verbatim
        )
        let setup = LiveProtocol.SetupMessage(setup: .init(
            model: LiveProtocol.qualified(model: configuration.model),
            generationConfig: .init(responseModalities: ["TEXT"]),
            inputAudioTranscription: transcription,
            // Passing an empty config (rather than nil) opts the session in to
            // resumption so the server starts issuing handles.
            sessionResumption: .init(handle: configuration.resumptionHandle)
        ))
        transmit(setup, logBody: true)
    }

    private func transmit<T: Encodable>(_ message: T, logBody: Bool = false) {
        guard let data = try? LiveProtocol.encoder.encode(message) else { return }
        if configuration.debugLogging && logBody {
            // .notice rather than .debug: debug-level entries are memory-only and are
            // usually gone by the time anyone runs `log show`.
            logger.notice("→ \(String(decoding: data, as: UTF8.self), privacy: .public)")
        }
        sendCountLock.lock(); sendsInFlight += 1; sendCountLock.unlock()
        sendQueue.async { [weak self] in
            guard let self, let task = self.task else {
                self?.noteSendFinished()
                return
            }
            task.send(.data(data)) { error in
                self.noteSendFinished()
                guard let error else { return }
                self.handleFailure(error)
            }
        }
    }

    private func noteSendFinished() {
        sendCountLock.lock(); sendsInFlight -= 1; sendCountLock.unlock()
    }

    // MARK: - Receiving

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleFailure(error)
            case .success(let message):
                switch message {
                case .data(let data): self.handle(data)
                case .string(let text): self.handle(Data(text.utf8))
                @unknown default: break
                }
                self.receiveNext()
            }
        }
    }

    private func handle(_ data: Data) {
        if configuration.debugLogging {
            logger.notice("← \(String(decoding: data, as: UTF8.self), privacy: .public)")
        }
        guard let message = try? JSONDecoder().decode(LiveProtocol.ServerMessage.self, from: data) else {
            // Not JSON we understand — most often an error payload from the service.
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                logger.error("Unparsed Live API frame: \(text, privacy: .public)")
            }
            return
        }

        if message.setupComplete != nil {
            isReady = true
            emit(.ready)
        }

        if let content = message.serverContent {
            if let interim = content.interimInputTranscription?.text, !interim.isEmpty {
                emit(.interim(interim))
            }
            if let final = content.inputTranscription?.text, !final.isEmpty {
                emit(.final(text: final, languageCode: content.inputTranscription?.languageCode))
            }
        }

        if let handle = message.sessionResumptionUpdate?.newHandle, !handle.isEmpty {
            emit(.resumptionHandle(handle))
        }

        if let goAway = message.goAway {
            emit(.goAway(timeLeftSec: goAway.timeLeftSeconds))
        }

        if let activity = message.voiceActivity, let offset = activity.audioOffsetSeconds {
            switch activity.type {
            case LiveProtocol.VoiceActivity.start: emit(.voiceActivity(started: true, audioOffsetSec: offset))
            case LiveProtocol.VoiceActivity.end: emit(.voiceActivity(started: false, audioOffsetSec: offset))
            default: break
            }
        }
    }

    private func handleFailure(_ error: Error) {
        guard !hasClosed else { return }
        hasClosed = true
        isReady = false
        lastCloseCode = task?.closeCode ?? .invalid
        lastCloseReason = task?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        logger.error("Live socket closed: code=\(self.lastCloseCode.rawValue, privacy: .public) reason=\(self.lastCloseReason ?? "-", privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        emit(.closed(error))
    }

    private func emit(_ event: Event) {
        callbackQueue.async { [weak self] in self?.onEvent?(event) }
    }

    enum LiveError: LocalizedError {
        case badEndpoint

        var errorDescription: String? {
            switch self {
            case .badEndpoint: return "Could not build the Live API URL. Check the API key."
            }
        }
    }
}
