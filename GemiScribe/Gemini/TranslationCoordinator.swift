import Foundation
import OSLog

/// Feeds blocks to `TranslationService` at a rate the API will actually accept.
///
/// The naive design — one request the moment a block is finalized — exhausts the free
/// tier's request quota within minutes of a busy meeting, and a 429 then marks the block
/// permanently failed. So blocks are collected for a moment, sent in batches, spaced out,
/// and retried using the delay the service itself asks for.
@MainActor
final class TranslationCoordinator {

    struct Config {
        var apiKey: String
        var model: String
        var target: AppLanguage
        var debugLogging: Bool
    }

    /// Blocks per request. Larger batches use less quota but delay the first translation.
    var maxBatchSize = 8
    /// Time to collect newly finalized blocks before the first request goes out.
    var debounceSec: Double = 1.2
    /// Floor on the gap between requests, which is what keeps us under the per-minute cap.
    var minRequestIntervalSec: Double = 3
    /// Attempts per batch, including the first.
    var maxAttempts = 3

    var configProvider: (() -> Config?)?
    /// Current text of a block, or nil if it no longer exists.
    var textProvider: ((UUID) -> String?)?
    var onPending: ((UUID) -> Void)?
    var onResult: ((UUID, Result<String, Error>) -> Void)?
    /// Raised when the API asks us to slow down, with the wait it requested. Worth
    /// telling the user about: on an exhausted free tier this is the whole story.
    var onRateLimited: ((String, TimeInterval) -> Void)?

    private var queue: [UUID] = []
    private var pump: Task<Void, Never>?
    private var lastRequestAt: Date?
    /// Set from a 429. The whole queue waits rather than each batch retrying into the
    /// same exhausted quota.
    private var pausedUntil: Date?
    private var attemptsByBlock: [UUID: Int] = [:]
    /// Bumped whenever queued work becomes stale (target language changed, transcript
    /// cleared), so an in-flight batch's results are discarded instead of applied late.
    private var generation = 0

    private let logger = Logger(subsystem: "jp.namio.GemiScribe", category: "translation")

    var queueDepth: Int { queue.count }

    func enqueue(_ id: UUID) {
        queue.removeAll { $0 == id }   // a re-queued block goes to the back, once
        queue.append(id)
        onPending?(id)
        startPump()
    }

    /// Drops everything queued and invalidates results still in flight.
    func reset() {
        generation += 1
        queue.removeAll()
        attemptsByBlock.removeAll()
        pausedUntil = nil
        pump?.cancel()
        pump = nil
    }

    // MARK: - Pump

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pump = nil }

            // Collect a moment's worth of blocks before the first request, so a burst
            // of short turns goes out as one batch instead of four.
            try? await Task.sleep(nanoseconds: UInt64(self.debounceSec * 1_000_000_000))

            while !self.queue.isEmpty, !Task.isCancelled {
                await self.waitWhilePaused()
                await self.waitForRateLimit()
                guard !Task.isCancelled else { return }
                await self.sendNextBatch()
            }
        }
    }

    private func waitWhilePaused() async {
        guard let until = pausedUntil else { return }
        let wait = until.timeIntervalSinceNow
        guard wait > 0 else {
            pausedUntil = nil
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        pausedUntil = nil
    }

    private func waitForRateLimit() async {
        guard let last = lastRequestAt else { return }
        let wait = minRequestIntervalSec - Date().timeIntervalSince(last)
        guard wait > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }

    private func sendNextBatch() async {
        let batch = Array(queue.prefix(maxBatchSize))
        queue.removeFirst(batch.count)
        guard !batch.isEmpty else { return }

        // Blocks can be merged away or cleared while they sit in the queue. Drop those
        // before anything else, so they are never reported as failures.
        var ids: [UUID] = []
        var texts: [String] = []
        for id in batch {
            guard let text = textProvider?(id), !text.isEmpty else { continue }
            ids.append(id)
            texts.append(text)
        }
        guard !ids.isEmpty else { return }

        guard let config = configProvider?() else {
            fail(ids, with: TranslationService.TranslationError.missingAPIKey)
            return
        }

        let startGeneration = generation
        lastRequestAt = Date()

        do {
            let translations = try await TranslationService.translate(.init(
                apiKey: config.apiKey,
                model: config.model,
                texts: texts,
                target: config.target,
                debugLogging: config.debugLogging
            ))
            guard generation == startGeneration else { return }
            for (id, translation) in zip(ids, translations) {
                onResult?(id, .success(translation))
            }
            for id in ids { attemptsByBlock[id] = nil }
        } catch {
            guard generation == startGeneration else { return }
            handleFailure(error, for: ids)
        }
    }

    private func handleFailure(_ error: Error, for ids: [UUID]) {
        guard let translationError = error as? TranslationService.TranslationError else {
            fail(ids, with: error)
            return
        }

        switch translationError {
        case .rateLimited(let retryAfter, let message):
            // Honour the service's own delay: guessing shorter just spends another
            // request against a quota that is already gone.
            let delay = min(300, max(1, retryAfter ?? 10))
            pausedUntil = Date().addingTimeInterval(delay)
            onRateLimited?(message, delay)

            var retryable: [UUID] = []
            var exhausted: [UUID] = []
            for id in ids {
                let attempt = (attemptsByBlock[id] ?? 0) + 1
                attemptsByBlock[id] = attempt
                if attempt >= maxAttempts { exhausted.append(id) } else { retryable.append(id) }
            }
            logger.notice("Rate limited: pausing \(delay, format: .fixed(precision: 0))s, requeueing \(retryable.count), giving up on \(exhausted.count)")
            queue.insert(contentsOf: retryable, at: 0)
            fail(exhausted, with: translationError)

        case .countMismatch where ids.count > 1:
            // Split and retry: a smaller batch is far less likely to misalign,
            // and halving terminates.
            maxBatchSize = max(1, ids.count / 2)
            queue.insert(contentsOf: ids, at: 0)
            logger.notice("Batch misaligned; retrying with batches of \(self.maxBatchSize)")

        default:
            fail(ids, with: translationError)
        }
    }

    private func fail(_ ids: [UUID], with error: Error) {
        for id in ids {
            attemptsByBlock[id] = nil
            onResult?(id, .failure(error))
        }
    }
}
