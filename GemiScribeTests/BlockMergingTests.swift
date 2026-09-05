import XCTest
@testable import GemiScribe

/// Replays a real recording that the user exported, where the service split several
/// sentences across turns and each half was then translated on its own.
final class BlockMergingTests: XCTestCase {

    /// The nine turns exactly as the Live API finalized them, with their measured times.
    private let turns: [FinalizedTurn] = [
        .init(text: "閉まってっていうような非常に日本っていうのはアメリカにとってもアジア地域の安全保障、ま、特に大中関係を考え、大中抑止ってことを考えた時",
              startSec: 0.30, endSec: 10.20, languageCode: "ja-JP"),
        .init(text: "非常に、もう、あの、欠かせない拠点になっている。一方で、韓国在韓米軍っていうのは、もう陸軍主体で、陸軍。",
              startSec: 10.20, endSec: 18.50, languageCode: "ja-JP"),
        .init(text: "の有志を想定しているだけ。",
              startSec: 20.90, endSec: 23.80, languageCode: "ja-JP"),
        .init(text: "だけの話になるんでとか、なんかじゃあ、あの、まあ、よく大和証券になった時みたいな時に、じゃあ",
              startSec: 27.50, endSec: 33.90, languageCode: "ja-JP"),
        .init(text: "が出てくるのかっていうと、多分、そこの陸軍がどうこうってことじゃないと思うんですよ。",
              startSec: 33.90, endSec: 39.70, languageCode: "ja-JP"),
        .init(text: "まあ、一部は行ったりするんですけど。",
              startSec: 39.70, endSec: 44.00, languageCode: "ja-JP"),
        .init(text: "と、そもそもじゃあ北朝鮮と韓国が戦争する時に、え、な、なんで我々が、あの、韓国のために語らなくちゃいけないんだって",
              startSec: 45.70, endSec: 52.90, languageCode: "ja-JP"),
        .init(text: "じゃあもういいですよとか。",
              startSec: 62.90, endSec: 65.00, languageCode: "ja-JP"),
        .init(text: "そこがやっぱり日本とこちらがその前の伏線から言うと、前、あの、この戦場ドットコムさん出さしていただい",
              startSec: 68.50, endSec: 75.10, languageCode: "ja-JP"),
    ]

    private func assemble() -> [TranscriptBlock] {
        var assembler = BlockAssembler()
        for turn in turns { assembler.ingest(turn) }
        return assembler.blocks
    }

    func testSentencesSplitAcrossTurnsAreRejoined() {
        let blocks = assemble()
        XCTAssertEqual(blocks.count, 7, "nine turns contain two split sentences")

        // Turn 0 ended on 「考えた時」 and turn 1 completes it.
        XCTAssertTrue(blocks[0].text.hasPrefix("閉まってっていうような"))
        XCTAssertTrue(blocks[0].text.hasSuffix("陸軍。"))
        XCTAssertEqual(blocks[0].startSec, 0.30, accuracy: 0.001)
        XCTAssertEqual(blocks[0].endSec, 18.50, accuracy: 0.001)

        // Turn 3 ended on 「じゃあ」 and turn 4 completes it.
        XCTAssertTrue(blocks[2].text.hasPrefix("だけの話になるんで"))
        XCTAssertTrue(blocks[2].text.hasSuffix("思うんですよ。"))
    }

    /// A block may still end mid-sentence, but only where a real pause follows —
    /// never because the service happened to finalize a turn on a breath.
    func testNoBlockEndsMidSentenceUnlessARealPauseFollows() {
        let blocks = assemble()
        for (index, block) in blocks.enumerated().dropLast() {
            guard !BlockAssembler.endsSentence(block.text) else { continue }
            let gap = blocks[index + 1].startSec - block.endSec
            XCTAssertGreaterThanOrEqual(gap, 3.0,
                "block ends mid-sentence after only \(gap)s: \(block.text.suffix(12))")
        }
    }

    /// A pause long enough to be a real break must not be papered over.
    func testALongPauseStillStartsANewBlock() {
        let blocks = assemble()
        let afterTheTenSecondPause = blocks.first { $0.text.hasPrefix("じゃあもういいですよ") }
        XCTAssertNotNil(afterTheTenSecondPause, "the 10 s pause should not have been merged away")
    }

    func testTimestampsStayOrderedAndNonOverlapping() {
        var previousEnd = -1.0
        for block in assemble() {
            XCTAssertGreaterThanOrEqual(block.startSec, previousEnd)
            XCTAssertGreaterThan(block.endSec, block.startSec)
            previousEnd = block.endSec
        }
    }

    // MARK: - Rules in isolation

    func testEndsSentenceAcceptsJapaneseAndEnglishPunctuation() {
        for text in ["終わり。", "done.", "本当？", "really?", "yes!", "「引用」", "end…"] {
            XCTAssertTrue(BlockAssembler.endsSentence(text), text)
        }
        for text in ["考えた時", "and then", "じゃあ", "", "   "] {
            XCTAssertFalse(BlockAssembler.endsSentence(text), text)
        }
    }

    func testTrailingWhitespaceDoesNotHideTheTerminator() {
        XCTAssertTrue(BlockAssembler.endsSentence("終わり。  \n"))
    }

    /// Forced boundaries produce turns of a few hundred characters each. A sentence
    /// cut by one must still be completed by the next turn, however long both are.
    func testLongTurnsCutMidSentenceAreStillRejoined() {
        var assembler = BlockAssembler()
        let first = String(repeating: "この文はとても長く、", count: 30) + "そして最後に"
        let second = "続きが来て終わります。"
        assembler.ingest(.init(text: first, startSec: 0, endSec: 20, languageCode: nil))
        assembler.ingest(.init(text: second, startSec: 20.3, endSec: 24, languageCode: nil))
        XCTAssertEqual(assembler.blocks.count, 1)
        XCTAssertTrue(assembler.blocks[0].text.hasSuffix("そして最後に続きが来て終わります。"))
    }

    /// A block that has already reached the duration ceiling stops absorbing turns,
    /// so speech without a single full stop cannot grow one block forever.
    func testABlockAtTheDurationCeilingStopsMerging() {
        var assembler = BlockAssembler()
        assembler.maxBlockSec = 10
        assembler.ingest(.init(text: "切れ目のない発話", startSec: 0, endSec: 11, languageCode: nil))
        assembler.ingest(.init(text: "その続き", startSec: 11, endSec: 14, languageCode: nil))
        XCTAssertEqual(assembler.blocks.count, 2)
    }

    /// When a merge pushes the block past the ceiling, it is re-split on a sentence
    /// boundary: the finished sentences settle and the open tail becomes the new block.
    func testAnOverlongMergeIsResplitAtTheSentenceBoundary() {
        var assembler = BlockAssembler()
        assembler.maxBlockSec = 10
        assembler.ingest(.init(text: "一文目の途中で", startSec: 0, endSec: 9, languageCode: nil))
        let original = assembler.blocks[0].id
        let changes = assembler.ingest(.init(text: "続きです。二文目です。", startSec: 9, endSec: 14, languageCode: nil))

        XCTAssertEqual(assembler.blocks.map(\.text), ["一文目の途中で続きです。", "二文目です。"])
        XCTAssertEqual(assembler.blocks[0].id, original, "the reopened block keeps its identity")
        XCTAssertEqual(assembler.blocks[0].startSec, 0, accuracy: 0.001)
        XCTAssertEqual(assembler.blocks[1].endSec, 14, accuracy: 0.001)
        XCTAssertLessThanOrEqual(assembler.blocks[0].endSec, assembler.blocks[1].startSec + 0.001)
        guard changes.count == 2, case .replaced = changes[0], case .appended = changes[1] else {
            return XCTFail("expected a replace followed by an append, got \(changes)")
        }
    }

    /// A boundary forced at a sentence end still brings the words spoken while the
    /// request was in flight. That tail must not keep the finished sentences open.
    func testTheInFlightTailIsDetachedFromTheFinishedSentences() {
        var assembler = BlockAssembler()
        assembler.ingest(.init(text: "But the reality is that there are many competent models. So that's",
                               startSec: 0, endSec: 12, languageCode: nil))
        XCTAssertEqual(assembler.blocks.map(\.text),
                       ["But the reality is that there are many competent models.", "So that's"])
        XCTAssertTrue(assembler.isSettled(assembler.blocks[0]))
        XCTAssertTrue(assembler.isFragment(assembler.blocks[1]))
        XCTAssertEqual(assembler.blocks[0].endSec, assembler.blocks[1].startSec, accuracy: 0.001)
        XCTAssertEqual(assembler.blocks[1].endSec, 12, accuracy: 0.001)

        // The next turn completes the tail, and the sentence boundary is where the
        // block boundary ends up.
        assembler.ingest(.init(text: "the kind of difficult trade-off where you draw the line.",
                               startSec: 12.3, endSec: 18, languageCode: nil))
        XCTAssertEqual(assembler.blocks.count, 2)
        XCTAssertEqual(assembler.blocks[1].text,
                       "So that's the kind of difficult trade-off where you draw the line.")
        XCTAssertEqual(assembler.blocks[1].startSec, assembler.blocks[0].endSec, accuracy: 0.001)
    }

    func testATurnWithNoFinishedSentenceIsNotSplit() {
        var assembler = BlockAssembler()
        assembler.ingest(.init(text: "だけの話になるんでとか、なんかじゃあ", startSec: 0, endSec: 5, languageCode: nil))
        XCTAssertEqual(assembler.blocks.count, 1)
    }

    func testTheLastBlockEndCanBeTightened() {
        var assembler = BlockAssembler()
        assembler.ingest(.init(text: "発話です。", startSec: 0, endSec: 5.4, languageCode: nil))
        XCTAssertNotNil(assembler.trimLastBlockEnd(to: 5.0))
        XCTAssertEqual(assembler.blocks[0].endSec, 5.0, accuracy: 0.001)
        // Never later than it was, never before the block starts.
        XCTAssertNil(assembler.trimLastBlockEnd(to: 5.2))
        XCTAssertNil(assembler.trimLastBlockEnd(to: -1))
        XCTAssertEqual(assembler.blocks[0].endSec, 5.0, accuracy: 0.001)
    }

    /// Merging invalidates the translation the half-sentence already got.
    func testAMergedBlockAsksForItsTranslationAgain() {
        var assembler = BlockAssembler()
        assembler.ingest(.init(text: "文の前半で", startSec: 0, endSec: 4, languageCode: nil))
        let first = try! XCTUnwrap(assembler.blocks.first)
        assembler.applyTranslation(.success("first half"), to: first.id)
        XCTAssertEqual(assembler.blocks[0].translationState, .done)

        let changes = assembler.ingest(.init(text: "後半です。", startSec: 4, endSec: 7, languageCode: nil))
        XCTAssertEqual(changes.count, 1)
        guard case .replaced = changes[0] else { return XCTFail("expected a merge") }
        XCTAssertEqual(assembler.blocks[0].translationState, .notRequested)
        XCTAssertNil(assembler.blocks[0].translation)
    }

    func testAFragmentStillMergesEvenWhenItEndsOnAFullStop() {
        var assembler = BlockAssembler()
        assembler.ingest(.init(text: "うん。", startSec: 0, endSec: 1, languageCode: nil))
        assembler.ingest(.init(text: "そうですね、それで進めましょう。", startSec: 1.2, endSec: 5, languageCode: nil))
        XCTAssertEqual(assembler.blocks.count, 1)
    }
}

/// A block that is still open keeps absorbing turns, and every absorption invalidates
/// the translation it already paid for. A recording of fast dialogue showed the same
/// block translated four times, each answer longer than the last.
final class BlockSettlementTests: XCTestCase {

    private var assembler = BlockAssembler()

    func testABlockEndingMidSentenceIsNotSettled() {
        assembler.ingest(.init(text: "そこそこ外を", startSec: 0, endSec: 3, languageCode: nil))
        XCTAssertFalse(assembler.isSettled(assembler.blocks[0]))
    }

    /// The stray-fragment rule merges short blocks whatever their punctuation, so
    /// ending on a full stop is not on its own enough to call a block finished.
    func testAShortBlockIsNotSettledEvenWithAFullStop() {
        assembler.ingest(.init(text: "なんとなくですね。", startSec: 0, endSec: 2, languageCode: nil))
        XCTAssertFalse(assembler.isSettled(assembler.blocks[0]))
    }

    func testALongBlockEndingOnAFullStopIsSettled() {
        assembler.ingest(.init(text: "骨格は変えないというような雰囲気は少し伝わってきています。",
                               startSec: 0, endSec: 8, languageCode: nil))
        XCTAssertTrue(assembler.isSettled(assembler.blocks[0]))
    }

    /// The exact case from the recording: a short block does go on to absorb the
    /// next turn, so translating it when it appeared would have been wasted.
    func testAnUnsettledBlockReallyDoesAbsorbTheNextTurn() {
        assembler.ingest(.init(text: "なんとなくですね。", startSec: 0, endSec: 2, languageCode: nil))
        XCTAssertFalse(assembler.isSettled(assembler.blocks[0]))

        assembler.ingest(.init(text: "くるくる変えたりとかする。", startSec: 2.5, endSec: 5, languageCode: nil))
        XCTAssertEqual(assembler.blocks.count, 1, "the short block should have absorbed it")
    }

    func testTheMergeWindowCoversBothMergeRules() {
        XCTAssertEqual(assembler.mergeWindowSec,
                       max(assembler.mergeGapSec, assembler.sentenceMergeGapSec),
                       accuracy: 0.001)
    }

    /// Conversational speech chains fragments indefinitely; the duration ceiling is
    /// what stops one block swallowing the whole recording.
    func testChainedFragmentsStopAtTheDurationCeiling() {
        assembler.maxBlockSec = 30
        var time = 0.0
        for _ in 0..<40 {
            assembler.ingest(.init(text: "それでですね、まあそれで",
                                   startSec: time, endSec: time + 2, languageCode: nil))
            time += 2
        }
        for block in assembler.blocks {
            XCTAssertLessThanOrEqual(block.endSec - block.startSec, 32.001)
        }
        XCTAssertGreaterThan(assembler.blocks.count, 1)
    }
}
