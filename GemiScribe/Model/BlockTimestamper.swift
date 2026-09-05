import Foundation

/// Pairs the Live API's finalized turns with measured speech spans.
///
/// The service reports where each segment began and ended as an offset into the audio
/// it received (`voiceActivity`), and that is the preferred source: it is exact and it
/// is the same segmentation the finals follow. When it is missing, the local VAD's spans
/// stand in, and failing both the audio clock does. Whatever the source, the two
/// timelines are kept from sliding permanently out of step.
final class BlockTimestamper {
    /// Beyond this many unclaimed spans the local VAD is clearly splitting more finely
    /// than the server, so the oldest are discarded to resynchronise.
    var maxQueuedSpans = 3

    /// A gap wider than this between blocks is treated as a real pause rather than
    /// continuous speech.
    var continuousSpeechGapSec: Double = 2
    /// Roughly how long the service takes to turn speech into a first partial.
    var partialLatencySec: Double = 0.5

    private var spans: [SpeechSpan] = []
    private var interimStartSec: Double?
    private var lastEndSec: Double?
    /// The server's open segment, on the recording's audio clock.
    private var serverSegmentStartSec: Double?
    private var serverSegmentEndSec: Double?

    func reset() {
        spans.removeAll()
        interimStartSec = nil
        lastEndSec = nil
        serverSegmentStartSec = nil
        serverSegmentEndSec = nil
    }

    func noteSpan(_ span: SpeechSpan) {
        spans.append(span)
        if spans.count > maxQueuedSpans {
            spans.removeFirst(spans.count - maxQueuedSpans)
        }
    }

    /// Records when the first partial of the current turn arrived, as a fallback anchor.
    func noteInterim(atAudioTime time: Double) {
        if interimStartSec == nil { interimStartSec = time }
    }

    /// The server's VAD opened a segment at this point of the recording.
    func noteServerActivityStarted(at time: Double) {
        serverSegmentStartSec = time
        serverSegmentEndSec = nil
    }

    /// The server's VAD closed its segment. Returns true when the segment's turn was
    /// already resolved — the final normally lands a beat *before* this message — in
    /// which case the caller may tighten that block's end to `time`.
    @discardableResult
    func noteServerActivityEnded(at time: Double) -> Bool {
        if serverSegmentStartSec != nil {
            serverSegmentEndSec = time
            return false
        }
        if let lastEndSec, time < lastEndSec, time > 0 {
            self.lastEndSec = time
        }
        return true
    }

    /// Consumes the span belonging to a turn that has just been finalized.
    func resolve(atAudioTime time: Double) -> (start: Double, end: Double) {
        defer { interimStartSec = nil }

        if let start = serverSegmentStartSec {
            let end = max(start, serverSegmentEndSec ?? time)
            serverSegmentStartSec = nil
            serverSegmentEndSec = nil
            // Local spans up to here described this turn or an earlier one; they must
            // not be handed to a later turn that arrives without server timing.
            spans.removeAll { $0.endSec <= end }
            lastEndSec = end
            return (start, end)
        }

        if !spans.isEmpty {
            let span = spans.removeFirst()
            let end = max(span.endSec, span.startSec)
            lastEndSec = end
            return (span.startSec, end)
        }

        // No span means the local VAD never heard a pause — continuous audio, which is
        // the normal case for a video or a busy meeting. The turn then began where the
        // previous one ended, not when its first partial happened to come back over the
        // network. Falling back to the partial's arrival time here would push every
        // timestamp a second or so late, and the error would compound over a recording.
        let anchor = interimStartSec ?? time
        let start: Double
        if let lastEndSec, anchor - lastEndSec < continuousSpeechGapSec {
            start = lastEndSec
        } else if interimStartSec != nil {
            // The correction models the lag between speech and its first partial, so it
            // only applies when a partial actually anchored this turn.
            start = max(lastEndSec ?? 0, anchor - partialLatencySec)
        } else {
            start = max(lastEndSec ?? 0, anchor)
        }

        let end = max(start, time)
        lastEndSec = end
        return (start, end)
    }
}
