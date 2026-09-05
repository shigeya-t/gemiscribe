import XCTest
@testable import GemiScribe

final class BlockAssemblerTests: XCTestCase {

    private func turn(_ text: String, _ start: Double, _ end: Double) -> FinalizedTurn {
        FinalizedTurn(text: text, startSec: start, endSec: end, languageCode: "ja-JP")
    }

    func testEachTurnBecomesItsOwnBlock() {
        var assembler = BlockAssembler()
        assembler.ingest(turn("おはようございます。会議を始めます。", 0, 4))
        assembler.ingest(turn("まず議題の確認からお願いします。", 8, 12))

        XCTAssertEqual(assembler.blocks.count, 2)
        XCTAssertEqual(assembler.blocks[0].startSec, 0)
        XCTAssertEqual(assembler.blocks[1].startSec, 8)
    }

    func testShortAdjacentTurnMergesIntoPrevious() {
        var assembler = BlockAssembler()
        assembler.ingest(turn("はい。", 0, 1))
        let changes = assembler.ingest(turn("そうですね、その通りだと思います。", 1.5, 5))

        XCTAssertEqual(assembler.blocks.count, 1)
        XCTAssertEqual(assembler.blocks[0].text, "はい。そうですね、その通りだと思います。")
        XCTAssertEqual(assembler.blocks[0].endSec, 5)
        guard case .replaced = changes.first else {
            return XCTFail("Expected a merge, got \(String(describing: changes.first))")
        }
    }

    func testLongPausePreventsMerge() {
        var assembler = BlockAssembler()
        assembler.ingest(turn("はい。", 0, 1))
        assembler.ingest(turn("では次に進みます。", 5, 8))
        XCTAssertEqual(assembler.blocks.count, 2)
    }

    func testLongPreviousBlockPreventsMerge() {
        var assembler = BlockAssembler()
        assembler.ingest(turn("これは二十文字を超える十分に長い発話です。", 0, 4))
        assembler.ingest(turn("はい。", 4.5, 5))
        XCTAssertEqual(assembler.blocks.count, 2)
    }

    func testMergeResetsTranslationSoItIsRedone() {
        var assembler = BlockAssembler()
        assembler.ingest(turn("はい。", 0, 1))
        assembler.applyTranslation(.success("Yes."), to: assembler.blocks[0].id)
        XCTAssertEqual(assembler.blocks[0].translationState, .done)

        assembler.ingest(turn("続けてください。", 1.2, 3))
        XCTAssertNil(assembler.blocks[0].translation)
        XCTAssertEqual(assembler.blocks[0].translationState, .notRequested)
    }

    func testPunctuationOnlyTurnIsDropped() {
        var assembler = BlockAssembler()
        XCTAssertTrue(assembler.ingest(turn("...", 0, 1)).isEmpty)
        XCTAssertTrue(assembler.ingest(turn("  ", 2, 3)).isEmpty)
        XCTAssertTrue(assembler.blocks.isEmpty)
    }

    /// Smart transcription inserts paragraph breaks mid-segment; a block must stay
    /// a single paragraph, joined the way merged turns are.
    func testParagraphBreaksInsideATurnAreFlattened() {
        var assembler = BlockAssembler()
        assembler.ingest(turn("生き延びました。\n\n先生はまだ病気でした。", 0, 20))
        XCTAssertEqual(assembler.blocks[0].text, "生き延びました。先生はまだ病気でした。")
        XCTAssertEqual(BlockAssembler.flattenLines("First line.\nSecond line."), "First line. Second line.")
        XCTAssertEqual(BlockAssembler.flattenLines("  \n  only \n\n"), "only")
    }

    func testEnglishFragmentsJoinWithASpace() {
        XCTAssertEqual(BlockAssembler.join("Yes", "absolutely."), "Yes absolutely.")
    }

    func testJapaneseFragmentsJoinWithoutASpace() {
        XCTAssertEqual(BlockAssembler.join("はい。", "そうです。"), "はい。そうです。")
    }

    func testOverlongTurnIsSplitOnSentenceBoundaries() {
        var assembler = BlockAssembler()
        assembler.maxBlockSec = 10
        let text = String(repeating: "これは長い独白の一文です。", count: 8)
        let changes = assembler.ingest(turn(text, 0, 40))

        XCTAssertGreaterThan(assembler.blocks.count, 1)
        XCTAssertEqual(assembler.blocks.count, changes.count)
        XCTAssertEqual(assembler.blocks.first?.startSec, 0)
        XCTAssertEqual(assembler.blocks.last?.endSec, 40)
        // Splitting must not lose or duplicate any text.
        XCTAssertEqual(assembler.blocks.map(\.text).joined(), text)
        // Timestamps stay in order.
        for (earlier, later) in zip(assembler.blocks, assembler.blocks.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.startSec, later.startSec)
        }
    }

    func testShortTurnIsNeverSplit() {
        let pieces = BlockAssembler.split(text: "一文目。二文目。", startSec: 0, endSec: 5, maxBlockSec: 60)
        XCTAssertEqual(pieces.count, 1)
    }

    func testTranslationFailureIsRecorded() {
        var assembler = BlockAssembler()
        assembler.ingest(turn("テスト発話です。", 0, 2))
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        assembler.applyTranslation(.failure(Boom()), to: assembler.blocks[0].id)
        XCTAssertEqual(assembler.blocks[0].translationState, .failed("boom"))
    }

    func testTranslationForAVanishedBlockIsIgnored() {
        var assembler = BlockAssembler()
        XCTAssertNil(assembler.applyTranslation(.success("hi"), to: UUID()))
    }

    func testTimecodeFormatting() {
        XCTAssertEqual(TimecodeFormatter.string(from: 0), "00:00:00")
        XCTAssertEqual(TimecodeFormatter.string(from: 4.9), "00:00:04")
        XCTAssertEqual(TimecodeFormatter.string(from: 3725), "01:02:05")
    }
}
