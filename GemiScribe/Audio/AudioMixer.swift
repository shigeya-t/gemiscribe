import Foundation

/// Sums the enabled capture sources into the single 16 kHz mono stream sent to Gemini,
/// and doubles as the recording's clock.
///
/// Output is pulled on a timer rather than pushed by the capture callbacks, so the two
/// sources (which run on independent hardware clocks) stay on one timeline. The number
/// of chunks emitted per tick adapts to the backlog, which keeps the emitted audio in
/// step with the hardware over long recordings instead of drifting with the timer.
final class AudioMixer {
    enum Source: String, CaseIterable, Sendable {
        case system
        case microphone
    }

    /// Emits one ~100 ms chunk of 16-bit little-endian PCM together with the audio-clock
    /// time (seconds since recording started) at which the chunk begins.
    var onChunk: ((Data, Double) -> Void)?
    /// Peak level in 0...1 per source, for the meters. Called on the mixer queue.
    var onLevels: (([Source: Float]) -> Void)?

    private let queue = DispatchQueue(label: "jp.namio.GemiScribe.mixer")
    private let lock = NSLock()
    private var buffers: [Source: RingBuffer] = [:]
    private var enabled: Set<Source> = []
    private var timer: DispatchSourceTimer?
    /// Consecutive ticks that found less than a full chunk available beyond the cushion.
    private var underrunTicks = 0
    private var underrunsSinceRead = 0
    /// 300 ms of starvation before the mixer starts inserting silence to keep time.
    private static let underrunGraceTicks = 3
    /// Audio held back so that capture jitter does not show up in the output. Capture
    /// callbacks arrive late in bursts when the machine is loaded; without a cushion
    /// the mixer alternates between finding nothing and finding three chunks, and
    /// after three empty ticks it splices silence into the middle of a word. Two
    /// chunks of latency is invisible to the transcript and absorbs that jitter.
    private static let cushionChunks = 2
    private var chunksEmitted = 0
    /// Where this run picks up on the transcript's timeline, so stopping and starting
    /// again continues the timestamps instead of restarting them at zero.
    private var timeOffset: Double = 0

    /// Seconds of audio streamed so far. Immune to network latency, unlike wall time.
    var elapsedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return timeOffset + Double(chunksEmitted) * AudioFormatSpec.frameDurationSec
    }

    init() {
        // 8 seconds of headroom per source is far more than the mixer ever needs;
        // it only matters if the main queue stalls.
        let capacity = Int(AudioFormatSpec.sampleRate * 8)
        for source in Source.allCases {
            buffers[source] = RingBuffer(capacity: capacity)
        }
    }

    func setEnabled(_ sources: Set<Source>) {
        lock.lock()
        enabled = sources
        for source in Source.allCases where !sources.contains(source) {
            buffers[source]?.removeAll()
        }
        lock.unlock()
    }

    /// Called from each capture source's own queue.
    func write(_ samples: [Float], from source: Source) {
        guard !samples.isEmpty else { return }
        lock.lock()
        if enabled.contains(source) {
            buffers[source]?.write(samples)
        }
        lock.unlock()
    }

    /// Number of starved ticks since the last read, for the heartbeat log.
    func consumeUnderruns() -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = underrunsSinceRead
        underrunsSinceRead = 0
        return count
    }

    func start(timeOffset: Double = 0) {
        stop()
        underrunTicks = 0
        lock.lock()
        self.timeOffset = timeOffset
        chunksEmitted = 0
        for source in Source.allCases { buffers[source]?.removeAll() }
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + AudioFormatSpec.frameDurationSec,
                       repeating: AudioFormatSpec.frameDurationSec,
                       leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Mixing

    private func tick() {
        let frames = AudioFormatSpec.framesPerChunk

        lock.lock()
        let active = enabled
        let backlog = active.compactMap { buffers[$0]?.count }.max() ?? 0
        lock.unlock()

        // Emit only whole chunks of real audio beyond the cushion, up to three when we
        // are behind so a hiccup drains instead of accumulating latency. Emitting a
        // short-and-zero-padded chunk instead would splice silence into the middle of
        // a word every time the capture callback lands a moment after the timer —
        // which both corrupts recognition and drifts the audio clock away from the audio.
        let available = backlog - Self.cushionChunks * frames
        var chunks = min(3, max(0, available) / frames)

        if chunks == 0 {
            underrunTicks += 1
            lock.lock(); underrunsSinceRead += 1; lock.unlock()
            // A source that has genuinely gone quiet (or stopped) must not freeze the
            // clock, or every later timestamp collapses. After a short grace period,
            // keep time: first with whatever real audio the cushion still holds, then
            // with silence (`read` zero-pads once the buffer is dry).
            guard underrunTicks >= Self.underrunGraceTicks else { return }
            chunks = 1
        } else {
            underrunTicks = 0
        }

        for _ in 0..<chunks {
            var mixed = [Float](repeating: 0, count: frames)
            var levels: [Source: Float] = [:]

            lock.lock()
            for source in Source.allCases {
                guard active.contains(source) else {
                    levels[source] = 0
                    continue
                }
                let samples = buffers[source]?.read(frames: frames) ?? [Float](repeating: 0, count: frames)
                var peak: Float = 0
                for index in 0..<frames {
                    mixed[index] += samples[index]
                    peak = max(peak, abs(samples[index]))
                }
                levels[source] = min(1, peak)
            }
            let startSec = timeOffset + Double(chunksEmitted) * AudioFormatSpec.frameDurationSec
            chunksEmitted += 1
            lock.unlock()

            onChunk?(Self.pcm16Data(from: mixed), startSec)
            onLevels?(levels)
        }
    }

    /// Float32 [-1, 1] to 16-bit little-endian PCM, hard-clipped.
    static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }
}
