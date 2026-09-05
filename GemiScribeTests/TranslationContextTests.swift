import XCTest
@testable import GemiScribe

/// Two live recordings showed the translator folding its surrounding context into the
/// answer: first the neighbouring Japanese was translated as well, then — after the
/// context was switched to the model's own English output — that English came back
/// restated in every later block, so the translations grew without bound. Requests now
/// carry nothing but the blocks to translate.
@MainActor
final class TranslationRequestTests: XCTestCase {

    private func request(_ texts: [String]) -> TranslationService.BatchRequest {
        .init(apiKey: "key", model: "m", texts: texts, target: .en)
    }

    func testARequestCarriesOnlyTheBlocksToTranslate() {
        let mirror = Mirror(reflecting: request(["一つ目。", "二つ目。"]))
        let labels = mirror.children.compactMap(\.label)
        XCTAssertFalse(labels.contains("context"),
                       "context leaked back into the request")
        XCTAssertTrue(labels.contains("texts"))
    }

    func testTheStoreNoLongerExposesNeighbouringText() {
        let store = TranscriptStore()
        // `context(before:)` is gone; the store's job is the transcript, not prompts.
        XCTAssertTrue(store.isEmpty)
    }

    func testAnEmptyBatchIsNotSent() async throws {
        let result = try await TranslationService.translate(request([]))
        XCTAssertTrue(result.isEmpty)
    }

    /// Every block still reaches the model, in order, with nothing between them.
    func testCoordinatorSendsEachQueuedBlockOnce() async {
        let coordinator = TranslationCoordinator()
        coordinator.debounceSec = 0.05
        coordinator.minRequestIntervalSec = 0
        coordinator.configProvider = { nil }   // fails fast, which is all we need here

        var asked: [UUID] = []
        coordinator.textProvider = { id in
            asked.append(id)
            return "text"
        }

        let reported = expectation(description: "both reported")
        reported.expectedFulfillmentCount = 2
        coordinator.onResult = { _, _ in reported.fulfill() }

        let first = UUID(), second = UUID()
        coordinator.enqueue(first)
        coordinator.enqueue(second)
        await fulfillment(of: [reported], timeout: 3)

        XCTAssertEqual(Set(asked), [first, second])
    }
}
