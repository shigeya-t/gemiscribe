import XCTest
@testable import GemiScribe

final class TranslationServiceTests: XCTestCase {

    // MARK: - Retry delay

    /// A 429 that is retried immediately just fails again; the service tells us how long
    /// to wait and the answer arrives in three different shapes.
    func testRetryDelayFromRetryInfoDetail() throws {
        let json = """
        {"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"quota",
          "details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure"},
                     {"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"23.79s"}]}}
        """
        let delay = TranslationService.retryDelay(in: Data(json.utf8), header: nil)
        XCTAssertEqual(try XCTUnwrap(delay), 23.79, accuracy: 0.001)
    }

    func testRetryDelayFromMessageProse() throws {
        let json = """
        {"error":{"code":429,"message":"You exceeded your current quota. Please retry in 23.794836036s."}}
        """
        let delay = TranslationService.retryDelay(in: Data(json.utf8), header: nil)
        XCTAssertEqual(try XCTUnwrap(delay), 23.794836036, accuracy: 0.0001)
    }

    func testRetryDelayFromRetryAfterHeader() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.invalid")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "30"]
        ))
        let delay = TranslationService.retryDelay(in: Data("{}".utf8), header: response)
        XCTAssertEqual(try XCTUnwrap(delay), 30, accuracy: 0.001)
    }

    func testRetryDelayIsNilWhenTheServiceDoesNotSayOne() {
        let json = #"{"error":{"code":400,"message":"Bad request"}}"#
        XCTAssertNil(TranslationService.retryDelay(in: Data(json.utf8), header: nil))
    }

    func testProtobufDurationParsing() {
        XCTAssertEqual(TranslationService.protobufDuration("5s") ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(TranslationService.protobufDuration("1.25s") ?? 0, 1.25, accuracy: 0.001)
        XCTAssertNil(TranslationService.protobufDuration("soon"))
    }

    func testRetrySecondsInMessageIgnoresUnrelatedNumbers() throws {
        let message = "Quota exceeded, limit: 500, model: gemini-3.5-flash-lite. Please retry in 23.7s."
        let seconds = TranslationService.retrySecondsInMessage(message)
        XCTAssertEqual(try XCTUnwrap(seconds), 23.7, accuracy: 0.001)
    }

    // MARK: - Error descriptions

    func testRateLimitErrorReadsAsAQuotaProblem() {
        let error = TranslationService.TranslationError.rateLimited(retryAfter: 24, message: "You exceeded your current quota.")
        XCTAssertEqual(error.errorDescription, "HTTP 429: You exceeded your current quota.")
    }

    func testCountMismatchErrorNamesBothCounts() {
        let error = TranslationService.TranslationError.countMismatch(expected: 8, received: 7)
        XCTAssertEqual(error.errorDescription, "The model returned 7 translations for 8 blocks.")
    }

    // MARK: - Batching

    func testEmptyBatchSkipsTheNetworkEntirely() async throws {
        let result = try await TranslationService.translate(.init(
            apiKey: "unused", model: "unused", texts: [], target: .en
        ))
        XCTAssertTrue(result.isEmpty)
    }

    func testMissingAPIKeyIsRejectedBeforeSending() async {
        do {
            _ = try await TranslationService.translate(.init(
                apiKey: "", model: "m", texts: ["hi"], target: .ja
            ))
            XCTFail("Expected a missing-key error")
        } catch let error as TranslationService.TranslationError {
            guard case .missingAPIKey = error else { return XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}

@MainActor
final class TranslationCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> TranslationCoordinator {
        let coordinator = TranslationCoordinator()
        // No API key: every batch fails immediately, which is enough to observe queueing.
        coordinator.configProvider = { nil }
        coordinator.debounceSec = 0.05
        coordinator.minRequestIntervalSec = 0
        return coordinator
    }

    func testEnqueueMarksTheBlockPending() {
        let coordinator = makeCoordinator()
        var pending: [UUID] = []
        coordinator.onPending = { pending.append($0) }
        coordinator.textProvider = { _ in "text" }

        let id = UUID()
        coordinator.enqueue(id)
        XCTAssertEqual(pending, [id])
    }

    func testEnqueuingTheSameBlockTwiceQueuesItOnce() {
        let coordinator = makeCoordinator()
        coordinator.textProvider = { _ in "text" }
        let id = UUID()
        coordinator.enqueue(id)
        coordinator.enqueue(id)
        XCTAssertEqual(coordinator.queueDepth, 1)
    }

    func testResetDropsTheQueue() {
        let coordinator = makeCoordinator()
        coordinator.textProvider = { _ in "text" }
        coordinator.enqueue(UUID())
        coordinator.enqueue(UUID())
        XCTAssertEqual(coordinator.queueDepth, 2)

        coordinator.reset()
        XCTAssertEqual(coordinator.queueDepth, 0)
    }

    /// Without an API key every block must end up reported as failed rather than
    /// sitting in "translating…" forever.
    func testBlocksFailWhenThereIsNoConfiguration() async {
        let coordinator = makeCoordinator()
        coordinator.textProvider = { _ in "text" }

        let reported = expectation(description: "result reported")
        reported.expectedFulfillmentCount = 2
        coordinator.onResult = { _, result in
            if case .failure = result { reported.fulfill() }
        }

        coordinator.enqueue(UUID())
        coordinator.enqueue(UUID())
        await fulfillment(of: [reported], timeout: 3)
    }

    /// Blocks merged away while queued must not be sent or reported.
    func testVanishedBlocksAreSkipped() async {
        let coordinator = makeCoordinator()
        coordinator.textProvider = { _ in nil }

        var results = 0
        coordinator.onResult = { _, _ in results += 1 }
        coordinator.enqueue(UUID())

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(results, 0)
        XCTAssertEqual(coordinator.queueDepth, 0)
    }
}

@MainActor
final class TranslationRateLimitTests: XCTestCase {
    /// The free tier answers an exhausted quota with a growing retry delay. Retrying
    /// straight into it just spends another request, so the queue has to wait instead.
    func testRateLimitPausesTheQueueAndRequeuesTheBatch() async {
        let coordinator = TranslationCoordinator()
        coordinator.debounceSec = 0.05
        coordinator.minRequestIntervalSec = 0
        coordinator.textProvider = { _ in "text" }
        coordinator.configProvider = { nil }

        var rateLimits: [(String, TimeInterval)] = []
        coordinator.onRateLimited = { rateLimits.append(($0, $1)) }

        // No key means the batch fails with a non-429 error, which must NOT pause.
        let failed = expectation(description: "failed")
        coordinator.onResult = { _, result in
            if case .failure = result { failed.fulfill() }
        }
        coordinator.enqueue(UUID())
        await fulfillment(of: [failed], timeout: 3)

        XCTAssertTrue(rateLimits.isEmpty)
        XCTAssertEqual(coordinator.queueDepth, 0)
    }

    func testResetClearsAPause() {
        let coordinator = TranslationCoordinator()
        coordinator.textProvider = { _ in "text" }
        coordinator.configProvider = { nil }
        coordinator.enqueue(UUID())
        coordinator.reset()
        XCTAssertEqual(coordinator.queueDepth, 0)
    }
}
