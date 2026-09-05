import Foundation
import OSLog

/// Keeps an unbroken transcription running across the Live API's ~10 minute connection cap.
///
/// The strategy is make-before-break: well before the current socket expires a second one
/// is opened and set up, and only once it reports `setupComplete` does the audio switch
/// over — preferably during a pause, so the handover does not cut a sentence in half.
/// The outgoing socket is kept alive for a few seconds to collect its trailing transcript.
@MainActor
final class SessionCoordinator {

    enum State: Equatable {
        case idle
        case connecting
        case listening
        case reconnecting
        case failed(String)
    }

    struct Configuration {
        var apiKey: String
        var model: String
        var languageCodes: [String]
        var customVocabulary: [String]
        var smartTranscribe: Bool
        var debugLogging: Bool
    }

    var onState: ((State) -> Void)?
    /// A partial for the open turn, with any repeat of the previous segment removed.
    var onInterim: ((String) -> Void)?
    var onFinal: ((String, String?) -> Void)?
    /// The server's VAD opened (`true`) or closed (`false`) a segment at this point on
    /// the recording's audio clock.
    var onSpeechActivity: ((Bool, Double) -> Void)?
    /// A connection-level problem worth showing the user while retries continue.
    var onConnectionError: ((String) -> Void)?
    /// Appended to the heartbeat log: what the captured audio actually contained.
    var audioStatsProvider: (() -> String)?
    /// The connection is going away with a turn still open — it wedged, or the server
    /// dropped it — and no final for that turn will ever come. Whatever is showing as
    /// a partial is all that survives, so the app keeps it.
    var onSalvagePartial: (() -> Void)?

    /// Open the replacement socket this long into a connection.
    private let rotateAfterSec: Double = 510      // 8m30s
    /// Hand over even mid-sentence past this point, rather than risk being cut off.
    private let forcePromoteAfterSec: Double = 570 // 9m30s
    /// How long the retired socket stays open to deliver its last finalized turn.
    /// Finals normally follow the flush within half a second; the margin is for a
    /// loaded service.
    private let trailingCollectSec: Double = 6
    /// Roughly 30 s of audio held while reconnecting.
    private let maxBufferedChunks = 300
    /// The last few chunks sent, replayed to a promoted connection before anything
    /// else. The retired socket never finalizes the few hundred milliseconds it got
    /// after its last final, and a fresh session clips the first syllable it hears
    /// while its VAD is still deciding; both lose the same beat, so the new socket
    /// starts from slightly before the handover instead.
    private let preRollChunks = 3
    private var recentChunks: [(chunk: Data, startSec: Double)] = []

    private var configuration: Configuration?
    private var current: LiveTranscriptionClient?
    private var standby: LiveTranscriptionClient?
    private var retiring: [LiveTranscriptionClient] = []

    private var resumptionHandle: String?
    private var connectionStartedAt: Date?
    private var pendingAudio: [(chunk: Data, startSec: Double)] = []
    private var reconnectAttempt = 0
    private var ticker: Timer?
    private var isStopping = false
    /// Retries before giving up and reporting `.failed` instead of retrying forever.
    private let maxReconnectAttempts = 6

    // Counters behind the 10-second heartbeat log. When transcription stops, these say
    // whether audio stopped flowing or the service stopped answering.
    private var chunksSent = 0
    private var chunksBuffered = 0
    private var interimsReceived = 0
    private var finalsReceived = 0
    private var lastServerMessageAt: Date?
    private var tickCount = 0

    // Turn tracking for the forced-boundary policy. All of it belongs to the current
    // connection and is reset whenever that changes.
    private let boundaryPolicy = TurnBoundaryPolicy()
    /// When the first partial of the open turn arrived; nil while no turn is open.
    private var turnOpenedAt: Date?
    /// The latest partial, cleaned of any repeat of the previous segment, and as the
    /// server sent it — the server repeats its *own* last partial, not the cleaned one.
    private var latestInterim = ""
    private var latestRawInterim = ""
    /// The last partial exactly as the server sent it, and as cleaned, at the moment
    /// the turn was finalized — what the next turn's partials may start with.
    private var rawInterimAtLastFinal = ""
    private var cleanInterimAtLastFinal = ""
    private var lastFinalText = ""
    private var lastFinalAt: Date?
    private var forcedFlushAt: Date?
    private var flushRetried = false
    /// The server's VAD has opened a segment it has not closed yet. Partials lag the
    /// segment start by a second or more, so this is the earlier signal that speech
    /// is in progress — and a retired socket does not reliably finalize a segment
    /// that was cut off this young.
    private var serverSegmentOpen = false
    /// The server closing a segment right after a forced boundary is not a pause.
    private let forcedBoundaryPauseExclusionSec: Double = 3
    /// Audio is held back this long after a forced boundary and then sent in one burst,
    /// so that nothing real arrives while the service is still closing the old segment.
    private let postBoundaryHoldSec: Double = 0.5
    /// Silence sent before the held audio is released. The service ignores the first
    /// stretch of audio after a boundary while its VAD looks for a speech onset — the
    /// gap between its own ACTIVITY_END and ACTIVITY_START never measured below 0.32 s
    /// across several recordings. Whatever occupies that window is lost, so it is given
    /// silence rather than the first words of the next sentence.
    private let postBoundarySilenceSec: Double = 0.4
    /// Already-transcribed audio replayed after that silence. Silence alone halved the
    /// loss but did not end it: about 0.16 s of real speech still went into finding the
    /// onset once the silence stopped, which is a short word at some seams. Replaying
    /// the moment before the boundary gives the onset something to consume that the
    /// previous block already contains. What survives the window is a few hundredths of
    /// a second, far less than a syllable.
    private let postBoundaryReplaySec: Double = 0.2
    private var holdAudioUntil: Date?
    /// A standby connection exists (or is being opened) and is cleared to take over.
    private var rotationArmed = false
    /// Set from `goAway`: swap over by this time even if no pause has come along.
    private var hardRotationDeadline: Date?

    private let logger = Logger(subsystem: "jp.namio.GemiScribe", category: "session")

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    // MARK: - Lifecycle

    func start(configuration: Configuration) {
        stopInternal()
        self.configuration = configuration
        isStopping = false
        resumptionHandle = nil
        reconnectAttempt = 0
        rotationArmed = false
        hardRotationDeadline = nil
        pendingAudio.removeAll()
        recentChunks.removeAll()
        state = .connecting
        chunksSent = 0
        chunksBuffered = 0
        interimsReceived = 0
        finalsReceived = 0
        lastServerMessageAt = nil
        tickCount = 0
        openCurrent()

        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Flushes the tail of the transcript, then tears everything down.
    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        ticker?.invalidate()
        ticker = nil

        current?.flushTurn()
        standby?.close()
        standby = nil

        try? await Task.sleep(nanoseconds: UInt64(trailingCollectSec * 1_000_000_000))
        stopInternal()
        state = .idle
    }

    private func stopInternal() {
        ticker?.invalidate()
        ticker = nil
        current?.close()
        current = nil
        standby?.close()
        standby = nil
        retiring.forEach { $0.close() }
        retiring.removeAll()
        pendingAudio.removeAll()
        connectionStartedAt = nil
    }

    // MARK: - Audio

    /// `startSec` is the chunk's position on the recording's audio clock; it anchors
    /// the server's voice-activity offsets back onto that clock.
    func send(_ chunk: Data, at startSec: Double) {
        guard !isStopping else { return }
        if let holdAudioUntil {
            if Date() < holdAudioUntil {
                pendingAudio.append((chunk, startSec))
                return
            }
            self.holdAudioUntil = nil
            releaseHeldAudio()
        }
        if let current, current.isReady {
            current.send(audio: chunk, at: startSec)
            chunksSent += 1
            recentChunks.append((chunk, startSec))
            if recentChunks.count > preRollChunks { recentChunks.removeFirst() }
        } else {
            pendingAudio.append((chunk, startSec))
            chunksBuffered += 1
            if pendingAudio.count > maxBufferedChunks { pendingAudio.removeFirst() }
        }
    }

    /// Called when the local VAD closes a speech span. A pause is the cheapest moment
    /// to swap connections, so a promotion that is already armed happens here.
    func noteSpeechEnded() {
        promoteIfPossible(force: false)
    }

    // MARK: - Connections

    private func openCurrent() {
        guard let configuration else { return }
        logger.notice("Opening Live connection (model=\(configuration.model, privacy: .public), resuming=\(self.resumptionHandle != nil, privacy: .public))")
        let client = makeClient(configuration: configuration)
        current = client
        connectionStartedAt = Date()
        resetTurnTracking()
        client.connect()
    }

    private func makeClient(configuration: Configuration) -> LiveTranscriptionClient {
        let client = LiveTranscriptionClient(configuration: .init(
            apiKey: configuration.apiKey,
            model: configuration.model,
            languageCodes: configuration.languageCodes,
            customVocabulary: configuration.customVocabulary,
            smartTranscribe: configuration.smartTranscribe,
            resumptionHandle: resumptionHandle,
            debugLogging: configuration.debugLogging
        ))
        client.onEvent = { [weak self, weak client] event in
            guard let self, let client else { return }
            self.handle(event, from: client)
        }
        return client
    }

    /// A new connection is a new server session: nothing about the previous turn
    /// carries over, and measuring "time since the last final" across the swap would
    /// force a boundary the moment the socket comes up.
    private func resetTurnTracking() {
        holdAudioUntil = nil
        turnOpenedAt = nil
        latestInterim = ""
        latestRawInterim = ""
        rawInterimAtLastFinal = ""
        cleanInterimAtLastFinal = ""
        lastFinalText = ""
        lastFinalAt = nil
        forcedFlushAt = nil
        flushRetried = false
        serverSegmentOpen = false
    }

    private func isRetiring(_ client: LiveTranscriptionClient) -> Bool {
        retiring.contains { $0 === client }
    }

    private func handle(_ event: LiveTranscriptionClient.Event, from client: LiveTranscriptionClient) {
        switch event {
        case .ready:
            lastServerMessageAt = Date()
            logger.notice("Live connection ready")
            if client === current {
                reconnectAttempt = 0
                state = .listening
                flushPendingAudio()
            } else if client === standby {
                // Armed; the actual switch waits for a pause (or the force deadline).
                // Between segments right now counts as one.
                promoteIfPossible(force: false)
            }

        case .interim(let raw):
            lastServerMessageAt = Date()
            interimsReceived += 1
            // Only the live connection drives the "listening…" line; a retiring socket
            // would otherwise rewind it with stale partials.
            guard client === current else { return }
            latestRawInterim = raw
            let cleaned = InterimCleaner.strip(raw, previous: [
                rawInterimAtLastFinal, cleanInterimAtLastFinal, lastFinalText,
            ])
            // A partial that only repeats the finalized segment carries no new speech.
            guard !cleaned.isEmpty else { return }
            latestInterim = cleaned
            if turnOpenedAt == nil { turnOpenedAt = Date() }
            onInterim?(cleaned)
            // Sentence ends are fleeting — the next partial may already have moved
            // on — so the boundary check runs here, not just on the ticker.
            checkTurnBoundary()

        case .final(let text, let languageCode):
            // A socket that was replaced because it wedged had its partial salvaged
            // already; a final from it now would duplicate that block.
            guard client === current || isRetiring(client) else {
                logger.notice("Ignoring a final from a closed connection")
                return
            }
            lastServerMessageAt = Date()
            finalsReceived += 1
            var text = text
            if client === current {
                let restored = SeamRepair.restoreDroppedHead(final: text,
                                                             interim: latestInterim,
                                                             previousFinal: lastFinalText)
                if restored != text {
                    logger.notice("Restored a dropped segment head from the partial: \(restored.prefix(40), privacy: .public)…")
                }
                let deduplicated = SeamRepair.trimDuplicatedHead(final: restored,
                                                                 previousFinal: lastFinalText)
                if deduplicated != restored {
                    logger.notice("Trimmed a segment head the previous block already had: \(deduplicated.prefix(40), privacy: .public)…")
                }
                text = deduplicated
                lastFinalAt = Date()
                rawInterimAtLastFinal = latestRawInterim
                cleanInterimAtLastFinal = latestInterim
                lastFinalText = text
                latestInterim = ""
                latestRawInterim = ""
                turnOpenedAt = nil
                forcedFlushAt = nil
                flushRetried = false
            }
            onFinal?(text, languageCode)
            // The moment after a final — often a sentence end that was chosen on
            // purpose — is the cleanest point to swap connections.
            if client === current { promoteIfPossible(force: false) }

        case .voiceActivity(let started, let offset):
            lastServerMessageAt = Date()
            // A retiring socket's trailing segment must not restamp the segment the
            // new connection has meanwhile opened; its final falls back to the clock.
            guard client === current, let base = client.firstAudioStartSec else { return }
            serverSegmentOpen = started
            // The server counts injected silence as audio, so its offsets run ahead of
            // the recording by however much has been injected so far.
            onSpeechActivity?(started, base + offset - client.injectedAudioSec)
            guard !started else { return }
            // The server closed its segment; whatever final it had is already out, so
            // a forced boundary still pending here would only escalate for nothing.
            let recentlyForced = forcedFlushAt.map {
                Date().timeIntervalSince($0) < forcedBoundaryPauseExclusionSec
            } ?? false
            turnOpenedAt = nil
            forcedFlushAt = nil
            flushRetried = false
            // A server-detected pause is as good a moment to rotate as a local one.
            if !recentlyForced { promoteIfPossible(force: false) }

        case .resumptionHandle(let handle):
            resumptionHandle = handle

        case .goAway(let timeLeft):
            logger.info("Live API goAway, \(timeLeft ?? -1) s left")
            if client === current {
                armStandby()
                // Leave a couple of seconds of margin before the server hangs up.
                let margin = max(1, (timeLeft ?? 10) - 2)
                hardRotationDeadline = Date().addingTimeInterval(margin)
            }

        case .closed(let error):
            handleClose(of: client, error: error)
        }
    }

    private func handleClose(of client: LiveTranscriptionClient, error: Error?) {
        retiring.removeAll { $0 === client }

        if client === standby {
            standby = nil
            return
        }
        guard client === current, !isStopping else { return }

        current = nil
        let reason = client.closeDescription ?? error?.localizedDescription
        if let reason {
            logger.error("Current Live connection lost: \(reason, privacy: .public)")
            onConnectionError?(reason)
        }
        // A "connection reset by peer" lands mid-sentence as often as not; the partial
        // is the only record of that sentence.
        if !latestInterim.isEmpty {
            logger.notice("Keeping the open turn's partial from the lost connection")
            onSalvagePartial?()
        }

        if standby != nil {
            state = .reconnecting
            // Promotes now if the standby is already set up; otherwise its own
            // `.ready` event does it, with the audio buffered until then.
            promoteIfPossible(force: true)
            return
        }

        reconnectAttempt += 1
        guard reconnectAttempt <= maxReconnectAttempts else {
            // Retrying forever behind a "reconnecting" label hides the real cause.
            logger.error("Giving up after \(self.reconnectAttempt) reconnect attempts")
            state = .failed(reason ?? "The connection to the Live API was lost.")
            ticker?.invalidate()
            ticker = nil
            return
        }

        // A handle the service has rejected once would wedge every later attempt.
        if reconnectAttempt >= 2 { resumptionHandle = nil }

        state = .reconnecting
        let delay = min(8, pow(2, Double(reconnectAttempt - 1)) * 0.5)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.isStopping, self.current == nil else { return }
            self.openCurrent()
        }
    }

    private func armStandby() {
        guard standby == nil, !isStopping, let configuration else { return }
        logger.notice("Opening standby Live connection (resuming=\(self.resumptionHandle != nil, privacy: .public))")
        rotationArmed = true
        let client = makeClient(configuration: configuration)
        standby = client
        client.connect()
    }

    /// Swaps in the standby connection. Without `force` it only happens while no turn
    /// is open on the current connection, so the handover does not cut a sentence in
    /// half; `force` ignores that (the connection is about to die anyway).
    private func promoteIfPossible(force: Bool) {
        guard let standby, standby.isReady, !isStopping else { return }
        guard force || (rotationArmed && turnOpenedAt == nil && !serverSegmentOpen) else { return }

        let outgoing = current
        logger.notice("Promoting standby Live connection (forced=\(force, privacy: .public))")
        current = standby
        self.standby = nil
        rotationArmed = false
        hardRotationDeadline = nil
        connectionStartedAt = Date()
        resetTurnTracking()
        state = .listening
        if outgoing != nil {
            pendingAudio.insert(contentsOf: recentChunks, at: 0)
            recentChunks.removeAll()
        }
        flushPendingAudio()

        if let outgoing {
            outgoing.flushTurn()
            retiring.append(outgoing)
            let delay = trailingCollectSec
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                outgoing.close()
                self?.retiring.removeAll { $0 === outgoing }
            }
        }
    }

    private func checkTurnBoundary() {
        guard let current, current.isReady, !isStopping else { return }
        let now = Date()
        let input = TurnBoundaryPolicy.Input(
            turnOpenFor: turnOpenedAt.map { now.timeIntervalSince($0) },
            interimEndsSentence: BlockAssembler.endsSentence(latestInterim),
            sinceForcedFlush: forcedFlushAt.map { now.timeIntervalSince($0) },
            flushRetried: flushRetried
        )
        switch boundaryPolicy.decide(input) {
        case .wait:
            break
        case .flush:
            let openFor = Int(input.turnOpenFor ?? 0)
            logger.notice("Forcing a turn boundary after \(openFor, privacy: .public)s (sentenceEnd=\(input.interimEndsSentence, privacy: .public))")
            current.flushTurn()
            holdAudioUntil = now.addingTimeInterval(postBoundaryHoldSec)
            forcedFlushAt = now
            flushRetried = false
        case .retryFlush:
            logger.notice("Forced boundary unanswered; sending it again")
            current.flushTurn()
            holdAudioUntil = now.addingTimeInterval(postBoundaryHoldSec)
            flushRetried = true
        case .replaceConnection:
            logger.error("Turn never finalized after a forced boundary; replacing the connection")
            forcedFlushAt = nil
            flushRetried = false
            onSalvagePartial?()
            replaceCurrentConnection()
        }
    }

    /// Tears down a wedged connection and starts a fresh one immediately.
    private func replaceCurrentConnection() {
        current?.close()
        current = nil
        standby?.close()
        standby = nil
        hardRotationDeadline = nil
        resumptionHandle = nil   // the handle belongs to the session that wedged
        state = .connecting
        openCurrent()
    }

    /// Ten-second vital signs. `chunksSent` still climbing with `sinceServerMsg` growing
    /// means the socket went deaf; `chunksSent` frozen means capture stopped.
    private func logHeartbeat(connectionAge: TimeInterval) {
        let silence = lastServerMessageAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        let mode = configuration?.smartTranscribe == true ? "SMART" : "VERBATIM"
        let turnOpen = turnOpenedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        let sendBacklog = current?.pendingSendCount ?? 0
        logger.notice("heartbeat mode=\(mode, privacy: .public) age=\(Int(connectionAge), privacy: .public)s state=\(String(describing: self.state), privacy: .public) chunksSent=\(self.chunksSent, privacy: .public) buffered=\(self.chunksBuffered, privacy: .public) sendBacklog=\(sendBacklog, privacy: .public) interims=\(self.interimsReceived, privacy: .public) finals=\(self.finalsReceived, privacy: .public) sinceServerMsg=\(silence, privacy: .public)s turnOpen=\(turnOpen, privacy: .public)s \(self.audioStatsProvider?() ?? "", privacy: .public)")
    }

    /// Pads the stream, then releases everything held back since the boundary.
    private func releaseHeldAudio() {
        guard let current, current.isReady else { return }
        let silence = Data(count: AudioFormatSpec.framesPerChunk * 2)
        let padding = [Data](repeating: silence, count: Self.chunks(in: postBoundarySilenceSec))
            + recentChunks.suffix(Self.chunks(in: postBoundaryReplaySec)).map(\.chunk)
        current.injectAudio(padding)
        flushPendingAudio()
    }

    private static func chunks(in seconds: Double) -> Int {
        max(1, Int((seconds / AudioFormatSpec.frameDurationSec).rounded()))
    }

    private func flushPendingAudio() {
        guard let current, current.isReady, !pendingAudio.isEmpty else { return }
        let queued = pendingAudio
        pendingAudio.removeAll()
        for item in queued { current.send(audio: item.chunk, at: item.startSec) }
    }

    private func tick() {
        guard !isStopping, let startedAt = connectionStartedAt else { return }

        tickCount += 1
        if tickCount % 10 == 0 { logHeartbeat(connectionAge: Date().timeIntervalSince(startedAt)) }
        checkTurnBoundary()
        // A replacement above starts a fresh connection; do not judge its age by the old one.
        guard let startedAt = connectionStartedAt else { return }

        let age = Date().timeIntervalSince(startedAt)
        if age >= rotateAfterSec { armStandby() }

        let deadlinePassed = hardRotationDeadline.map { Date() >= $0 } ?? false
        if age >= forcePromoteAfterSec || deadlinePassed {
            promoteIfPossible(force: true)
        }
    }
}
