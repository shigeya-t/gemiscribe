import XCTest
@testable import GemiScribe

/// The forced-boundary policy, replayed against what a debug log of a news broadcast
/// showed: the service never finalizes continuous speech on its own, a fixed 20 s cut
/// lands mid-sentence, and the first cut on a fresh connection is sometimes ignored.
final class TurnBoundaryPolicyTests: XCTestCase {

    private let policy = TurnBoundaryPolicy()

    private func input(openFor: Double?, sentenceEnd: Bool = false,
                       sinceFlush: Double? = nil, retried: Bool = false) -> TurnBoundaryPolicy.Input {
        .init(turnOpenFor: openFor, interimEndsSentence: sentenceEnd,
              sinceForcedFlush: sinceFlush, flushRetried: retried)
    }

    /// Silence is not a stuck turn. The old watchdog forced a boundary twenty seconds
    /// into any pause and then replaced the connection when nothing came back.
    func testNothingIsForcedWhileNoTurnIsOpen() {
        XCTAssertEqual(policy.decide(input(openFor: nil)), .wait)
        XCTAssertEqual(policy.decide(input(openFor: nil, sentenceEnd: true)), .wait)
    }

    func testASentenceEndIsTakenOnceTheSegmentIsLongEnough() {
        XCTAssertEqual(policy.decide(input(openFor: 3, sentenceEnd: true)), .wait,
                       "too short to be worth a block and a translation")
        XCTAssertEqual(policy.decide(input(openFor: policy.minSegmentSec, sentenceEnd: true)), .flush)
    }

    func testARunOnSpeakerIsCutAtTheCeiling() {
        XCTAssertEqual(policy.decide(input(openFor: policy.maxSegmentSec - 1)), .wait)
        XCTAssertEqual(policy.decide(input(openFor: policy.maxSegmentSec)), .flush)
    }

    func testAnUnansweredBoundaryIsResentOnceThenGivenUpOn() {
        XCTAssertEqual(policy.decide(input(openFor: 30, sinceFlush: 1)), .wait)
        XCTAssertEqual(policy.decide(input(openFor: 30, sinceFlush: policy.retryAfterSec)), .retryFlush)
        XCTAssertEqual(policy.decide(input(openFor: 30, sinceFlush: policy.retryAfterSec + 1, retried: true)), .wait)
        XCTAssertEqual(policy.decide(input(openFor: 30, sinceFlush: policy.giveUpAfterSec, retried: true)),
                       .replaceConnection)
    }

    /// While a boundary is pending, a sentence end must not send a second one.
    func testNoNewBoundaryWhileOneIsPending() {
        XCTAssertEqual(policy.decide(input(openFor: 40, sentenceEnd: true, sinceFlush: 2)), .wait)
    }
}

/// The service repeats the previous segment at the head of the next segment's
/// partials. These are shapes taken from debug logs.
final class InterimCleanerTests: XCTestCase {

    /// The next partial began with the last partial of the previous turn — exactly,
    /// with no space — not with the finalized (corrected) text.
    func testThePreviousPartialIsStrippedEvenWhenTheFinalDiffers() {
        let lastPartial = "one of the reporters who was on the"
        let final = "one of the reporters uh who was on the"
        let next = "one of the reporters who was on theline of this story. I I was sure"
        XCTAssertEqual(InterimCleaner.strip(next, previous: [lastPartial, final]),
                       "line of this story. I I was sure")
    }

    /// The repeat carried the words that were in flight when the boundary landed:
    /// longer than the last partial, and differing from the final in its last word.
    func testARepeatWithInFlightWordsIsMatchedFuzzily() {
        let lastPartial = "I really encourage you to check it out."
        let final = "I really encourage you to check it out just to even see"
        let next = "I really encourage you to check it out just to eventhe chart how what the difference is."
        XCTAssertEqual(InterimCleaner.strip(next, previous: [lastPartial, final]),
                       "the chart how what the difference is.")
    }

    func testTheFinalizedTextIsStrippedWhenThatIsWhatRepeats() {
        let final = "But I got you something. So Brandon, you're"
        let next = "But I got you something. So Brandon, you're staying, right? Yeah."
        XCTAssertEqual(InterimCleaner.strip(next, previous: [final]), "staying, right? Yeah.")
    }

    func testAPartialThatOnlyRepeatsTheOldSegmentBecomesEmpty() {
        XCTAssertEqual(InterimCleaner.strip("もう終わりました。", previous: ["もう終わりました。"]), "")
    }

    func testAFreshPartialIsLeftAlone() {
        XCTAssertEqual(InterimCleaner.strip("では、よろしくお願いします。", previous: ["前の文はこれです。", ""]),
                       "では、よろしくお願いします。")
    }

    /// Two segments that merely open on the same few words are not a repeat.
    func testASharedOpeningIsNotMistakenForARepeat() {
        let final = "So when we look at the code arena, it looks completely insane."
        let next = "So when we consider the agent score, things look different."
        XCTAssertEqual(InterimCleaner.strip(next, previous: [final]), next)
    }

    func testTheLongestMatchingCandidateWins() {
        let short = "The Journal's reporting"
        let long = "The Journal's reporting is based on interviews."
        let next = "The Journal's reporting is based on interviews. My panel joins me now."
        XCTAssertEqual(InterimCleaner.strip(next, previous: [short, long]), "My panel joins me now.")
    }
}

/// SMART mode drops the opening fragment of a segment that starts mid-sentence. The
/// partial still has it. Cases are from a debug log of a forced-boundary recording.
final class SeamRepairTests: XCTestCase {

    func testTheDroppedHeadIsRestoredFromThePartial() {
        let interim = "describe them correctly. So, you know, you know, we can we can"
        let final = "So, we can improve the transcription quality by setting kind of the language hints."
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim),
                       "describe them correctly. So, we can improve the transcription quality by setting kind of the language hints.")
    }

    func testCapitalisationDifferencesDoNotDefeatTheMatch() {
        let interim = "really nice. Thanks so much for tuning in. Um I hope you try out"
        let final = "Thanks so much for tuning in. I hope you try out Gemini 3.5 Transcribe."
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim),
                       "really nice. Thanks so much for tuning in. I hope you try out Gemini 3.5 Transcribe.")
    }

    func testAFinalThatKeptItsHeadIsLeftAlone() {
        let interim = "for Life transcription on the Life"
        let final = "For live transcription on the Live API, what's really cool here is that the model is an LLM-based transcription model."
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim), final)
    }

    /// Fillers and false starts do not close a sentence; those SMART may keep dropping.
    func testAFalseStartIsNotRestored() {
        let interim = "so so um Thanks so much for tuning in"
        let final = "Thanks so much for tuning in."
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim), final)
    }

    func testJapaneseHeadsAreRestoredToo() {
        let interim = "説明しました。次に、料金体系について"
        let final = "次に、料金体系についてご説明します。"
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim),
                       "説明しました。次に、料金体系についてご説明します。")
    }

    /// The case the user reported: a whole German sentence spoken across a forced
    /// boundary, present in the partial, dropped from the SMART final because the
    /// segment opened mid-sentence. It ends on a comma, not a full stop.
    func testASentenceInAnotherLanguageIsRestored() {
        let interim = "so jetzt zum Beispiel auch, wenn ich auf Deutsch spreche, you can see even though you know I set kind of the language hints"
        let final = "You can see even though I set the language hints or the language codes to be English."
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim),
                       "so jetzt zum Beispiel auch, wenn ich auf Deutsch spreche, You can see even though I set the language hints or the language codes to be English.")
    }

    func testAHeadOfOnlyFillersIsNotRestored() {
        for head in ["So,", "You know,", "and uh", "えー、あの"] {
            let final = "This is the sentence that survived."
            let restored = SeamRepair.restoreDroppedHead(final: final, interim: head + " " + final)
            XCTAssertEqual(restored, final, head)
        }
    }

    func testAHeadCarryingRealWordsIsRestoredEvenAmongFillers() {
        let interim = "And what you can see is uh What's really cool here is that the model is an LLM."
        let final = "What's really cool here is that the model is an LLM."
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim),
                       "And what you can see is uh What's really cool here is that the model is an LLM.")
    }

    /// A partial that still carries the previous block's tail must not put that tail
    /// into this block as well.
    func testAHeadAlreadyInThePreviousBlockIsNotRestored() {
        let previous = "It actually went back over that and realized okay, that was"
        let interim = "that was probably wrong, and so it transcribed that correctly."
        let final = "Probably wrong, and so it transcribed that correctly."
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim, previousFinal: previous),
                       final)
    }

    /// SMART removes a stutter ("we can, we can improve"), so the repeated words are
    /// left at the end of the head. Restoring them would restate the final's opening.
    func testAStutterLeftInTheHeadIsNotRestored() {
        let interim = "you know, we can we can improve the transcription quality"
        let final = "We can improve the transcription quality by setting the language hints."
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: final, interim: interim), final)
    }

    func testAnUnrelatedPartialChangesNothing() {
        XCTAssertEqual(SeamRepair.restoreDroppedHead(final: "Thanks so much for tuning in.", interim: "completely different words here."),
                       "Thanks so much for tuning in.")
    }
}

/// The audio replayed after a boundary exists to be discarded, but the service
/// sometimes transcribes its tail, putting the same word in two blocks.
final class SeamDeduplicationTests: XCTestCase {

    func testAWordRepeatedAcrossTheSeamIsTrimmed() {
        let previous = "This is really exciting for applications that need a bit more accurate transcription, which"
        let final = "Which is really nice. Thanks so much for tuning in."
        XCTAssertEqual(SeamRepair.trimDuplicatedHead(final: final, previousFinal: previous),
                       "is really nice. Thanks so much for tuning in.")
    }

    func testSeveralRepeatedWordsAreTrimmed() {
        let previous = "and so you can see here now if I"
        let final = "if I introduce myself as Thor Chef, it will know how to pronounce my name."
        XCTAssertEqual(SeamRepair.trimDuplicatedHead(final: final, previousFinal: previous),
                       "introduce myself as Thor Chef, it will know how to pronounce my name.")
    }

    /// A block that ends on a full stop was not cut mid-sentence, so a word shared
    /// with the next block is the speaker repeating themselves, not a seam artefact.
    func testNothingIsTrimmedWhenThePreviousBlockEndsASentence() {
        let previous = "Now, another really nifty thing is, for example, phone numbers."
        let final = "Phone numbers are transcribed correctly too."
        XCTAssertEqual(SeamRepair.trimDuplicatedHead(final: final, previousFinal: previous), final)
    }

    func testAnUnrelatedFinalIsLeftAlone() {
        XCTAssertEqual(SeamRepair.trimDuplicatedHead(final: "Thanks for tuning in.", previousFinal: "so it would go and"),
                       "Thanks for tuning in.")
        XCTAssertEqual(SeamRepair.trimDuplicatedHead(final: "Thanks for tuning in.", previousFinal: ""),
                       "Thanks for tuning in.")
    }

    /// Trimming must never empty a block out.
    func testAFinalThatIsEntirelyARepeatIsKept() {
        XCTAssertEqual(SeamRepair.trimDuplicatedHead(final: "which", previousFinal: "transcription, which"),
                       "which")
    }
}
