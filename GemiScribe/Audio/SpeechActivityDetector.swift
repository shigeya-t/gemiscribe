import Foundation

struct SpeechSpan: Equatable, Sendable {
    var startSec: Double
    var endSec: Double
}

/// A cheap energy-based VAD run over the outgoing chunks.
///
/// Block timestamps normally come from the server's own segment timing
/// (`voiceActivity`). This local detector is the fallback for when that is missing,
/// feeds the heartbeat's speech statistics, and marks pauses at which a connection
/// swap is cheap. It runs on the audio we send — before the network — so its times
/// line up with the recording rather than with reply latency.
final class SpeechActivityDetector {
    /// Absolute floor: audio quieter than this is silence whatever else is going on.
    /// Real recordings rarely get near it — a podcast's room tone alone sits well above.
    var thresholdDB: Double = -45
    /// How far above the tracked noise floor speech has to be. Continuous material
    /// (a video, music under a voice) never approaches the absolute floor, so a fixed
    /// threshold marks the entire recording as speech and no pause is ever found.
    var noiseFloorMarginDB: Double = 8
    /// How fast the floor is allowed to creep upwards, in dB per chunk (0.5 dB/s).
    /// Slow enough that speech does not drag it along, fast enough to settle inside
    /// the first few seconds of a recording.
    var noiseFloorRiseDBPerChunk: Double = 0.05

    /// Nil until the first chunk: seeding from real audio converges immediately,
    /// where creeping up from a fixed start takes minutes.
    private(set) var noiseFloorDB: Double?

    /// The threshold actually in force, tracking the material's own noise floor.
    var effectiveThresholdDB: Double {
        guard let noiseFloorDB else { return thresholdDB }
        return max(thresholdDB, noiseFloorDB + noiseFloorMarginDB)
    }
    /// How long the level must stay below the threshold before a span is closed.
    var hangoverMs: Int = 700
    /// How much continuous sound is needed to open a span; rejects clicks and coughs.
    var onsetChunks: Int = 2

    var onSpan: ((SpeechSpan) -> Void)?

    private var inSpeech = false
    private var spanStart: Double = 0
    private var lastLoudEnd: Double = 0
    private var quietChunks = 0
    private var loudChunks = 0

    func reset() {
        noiseFloorDB = nil
        inSpeech = false
        quietChunks = 0
        loudChunks = 0
        spanStart = 0
        lastLoudEnd = 0
    }

    /// Returns the chunk's level in dBFS, so callers can report on it without
    /// walking the same samples a second time.
    @discardableResult
    func process(chunk: Data, startSec: Double) -> Double {
        let endSec = startSec + AudioFormatSpec.frameDurationSec
        let level = Self.decibels(ofPCM16: chunk)
        updateNoiseFloor(with: level)
        let isLoud = level > effectiveThresholdDB

        if isLoud {
            quietChunks = 0
            loudChunks += 1
            lastLoudEnd = endSec
            if !inSpeech && loudChunks >= onsetChunks {
                inSpeech = true
                // Back-date the start to the first loud chunk so the onset is not clipped.
                spanStart = startSec - Double(onsetChunks - 1) * AudioFormatSpec.frameDurationSec
            }
        } else {
            loudChunks = 0
            quietChunks += 1
            let quietMs = Double(quietChunks) * AudioFormatSpec.frameDurationSec * 1000
            if inSpeech && quietMs >= Double(hangoverMs) {
                inSpeech = false
                onSpan?(SpeechSpan(startSec: max(0, spanStart), endSec: lastLoudEnd))
            }
        }
        return level
    }

    /// Falls quickly towards a new quiet level and creeps back up, so the floor
    /// follows the quietest recent audio rather than the average.
    private func updateNoiseFloor(with level: Double) {
        guard let floor = noiseFloorDB else {
            noiseFloorDB = min(Self.floorCeilingDB, max(Self.floorBottomDB, level))
            return
        }
        // Drop halfway to any quieter reading at once; climb back only in small steps.
        let updated = level < floor
            ? floor + (level - floor) * 0.5
            : floor + noiseFloorRiseDBPerChunk
        // The ceiling stops a stretch of unbroken sound from dragging the gate up
        // above the speech it is supposed to detect.
        noiseFloorDB = min(Self.floorCeilingDB, max(Self.floorBottomDB, updated))
    }

    private static let floorCeilingDB = -25.0
    private static let floorBottomDB = -75.0

    /// Closes an open span when the recording stops mid-sentence.
    func flush(at endSec: Double) {
        guard inSpeech else { return }
        inSpeech = false
        onSpan?(SpeechSpan(startSec: max(0, spanStart), endSec: max(lastLoudEnd, endSec)))
    }

    /// RMS level of a 16-bit little-endian PCM chunk, in dBFS.
    static func decibels(ofPCM16 data: Data) -> Double {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return -160 }
        var sumOfSquares = 0.0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<sampleCount {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1])
                let value = Double(Int16(bitPattern: low | (high << 8))) / 32768.0
                sumOfSquares += value * value
            }
        }
        let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }
}
