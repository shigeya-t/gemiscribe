import Foundation

/// Owns the capture sources, the mixer and the local VAD, and hands the rest of the
/// app a single stream of ready-to-send chunks plus the locally detected speech spans.
final class AudioSourceManager {
    /// One ~100 ms chunk of 16 kHz mono PCM16, with its start time on the audio clock.
    var onChunk: ((Data, Double) -> Void)?
    /// A stretch of speech, closed once the level has stayed low for the hangover period.
    var onSpan: ((SpeechSpan) -> Void)?
    var onLevels: (([AudioMixer.Source: Float]) -> Void)?
    /// Raised when a source dies after a successful start (display disconnected, device unplugged).
    var onSourceFailure: ((Error) -> Void)?

    private let mixer = AudioMixer()
    private let detector = SpeechActivityDetector()
    private let systemAudio = SystemAudioCapture()
    private let microphone = MicrophoneCapture()
    private var running: Set<AudioMixer.Source> = []
    private let statsLock = NSLock()
    private var stats = AudioStats()

    var elapsedSeconds: Double { mixer.elapsedSeconds }

    /// What the microphone and system audio actually contained since the last read.
    /// The mixer emits a chunk every 100 ms whether or not any sound arrived, so a
    /// chunk count alone cannot distinguish "streaming speech" from "streaming silence".
    struct AudioStats {
        var chunks = 0
        var speechChunks = 0
        var peakDB = -160.0
        var spans = 0

        var thresholdDB = -45.0

        var summary: String {
            let percent = chunks > 0 ? speechChunks * 100 / chunks : 0
            return "speech=\(percent)% peak=\(Int(peakDB))dB gate=\(Int(thresholdDB))dB spans=\(spans)"
        }
    }

    /// Ticks where the mixer found less than a full chunk of captured audio buffered.
    func consumeUnderruns() -> Int { mixer.consumeUnderruns() }

    /// Reads and resets the counters.
    func consumeStats() -> AudioStats {
        statsLock.lock(); defer { statsLock.unlock() }
        let current = stats
        stats = AudioStats()
        return current
    }

    init() {
        mixer.onChunk = { [weak self] data, startSec in
            guard let self else { return }
            let level = self.detector.process(chunk: data, startSec: startSec)
            self.statsLock.lock()
            self.stats.chunks += 1
            if level > self.detector.effectiveThresholdDB { self.stats.speechChunks += 1 }
            self.stats.peakDB = max(self.stats.peakDB, level)
            self.stats.thresholdDB = self.detector.effectiveThresholdDB
            self.statsLock.unlock()
            self.onChunk?(data, startSec)
        }
        mixer.onLevels = { [weak self] levels in
            self?.onLevels?(levels)
        }
        detector.onSpan = { [weak self] span in
            guard let self else { return }
            self.statsLock.lock()
            self.stats.spans += 1
            self.statsLock.unlock()
            self.onSpan?(span)
        }
        systemAudio.onSamples = { [weak self] samples in
            self?.mixer.write(samples, from: .system)
        }
        systemAudio.onStreamError = { [weak self] error in
            self?.running.remove(.system)
            self?.onSourceFailure?(error)
        }
        microphone.onSamples = { [weak self] samples in
            self?.mixer.write(samples, from: .microphone)
        }
    }

    /// `timeOffset` continues the clock from a previous run of the same transcript.
    func start(sources: Set<AudioMixer.Source>,
               thresholdDB: Double,
               hangoverMs: Int,
               timeOffset: Double) async throws {
        guard !sources.isEmpty else { throw AudioCaptureError.streamFailed("No audio source selected.") }

        detector.thresholdDB = thresholdDB
        detector.hangoverMs = hangoverMs
        detector.reset()

        do {
            // Start the sources before the mixer so its clock begins with real audio.
            try await updateSources(sources)
        } catch {
            await stop()
            throw error
        }
        mixer.start(timeOffset: timeOffset)
    }

    /// Adds and removes sources without interrupting the recording, so the toggles
    /// stay live mid-session. The mixed stream to Gemini is unaffected either way.
    func updateSources(_ sources: Set<AudioMixer.Source>) async throws {
        for source in running.subtracting(sources) {
            switch source {
            case .system: await systemAudio.stop()
            case .microphone: microphone.stop()
            }
            running.remove(source)
        }
        for source in sources.subtracting(running) {
            switch source {
            case .system: try await systemAudio.start()
            case .microphone: try await microphone.start()
            }
            running.insert(source)
        }
        mixer.setEnabled(running)
    }

    func stop() async {
        mixer.stop()
        detector.flush(at: mixer.elapsedSeconds)
        if running.contains(.system) { await systemAudio.stop() }
        if running.contains(.microphone) { microphone.stop() }
        running.removeAll()
        mixer.setEnabled([])
    }
}
