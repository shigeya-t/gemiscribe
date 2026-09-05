import Foundation
import OSLog

/// Measures how long the main thread takes to answer a ping.
///
/// A stalled main thread looks exactly like a stalled transcription: text arrives from
/// the API and never reaches the screen. This tells the two apart in the log rather
/// than leaving it to guesswork.
final class MainThreadMonitor {
    /// Latency above this is reported; below it the main thread is keeping up fine.
    var stallThresholdSec: Double = 0.5

    var onStall: ((TimeInterval) -> Void)?

    private let queue = DispatchQueue(label: "jp.namio.GemiScribe.mainMonitor")
    private var timer: DispatchSourceTimer?
    private let logger = Logger(subsystem: "jp.namio.GemiScribe", category: "mainthread")
    private var worstSec: Double = 0

    func start() {
        stop()
        worstSec = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Worst latency seen since the last read, for the heartbeat line.
    func consumeWorst() -> Double {
        queue.sync {
            let worst = worstSec
            worstSec = 0
            return worst
        }
    }

    private func ping() {
        let sentAt = DispatchTime.now()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let latency = Double(DispatchTime.now().uptimeNanoseconds - sentAt.uptimeNanoseconds) / 1_000_000_000
            self.queue.async { self.worstSec = max(self.worstSec, latency) }
            guard latency >= self.stallThresholdSec else { return }
            self.logger.error("Main thread stalled for \(latency, format: .fixed(precision: 2))s")
            self.onStall?(latency)
        }
    }
}
