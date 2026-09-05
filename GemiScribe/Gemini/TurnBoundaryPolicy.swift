import Foundation

/// Decides when to force a turn boundary on a connection whose server-side VAD is not
/// finding one by itself.
///
/// Broadcast material — a podcast, a news panel, a briefing — hardly ever goes quiet,
/// and the service then streams one ever-growing partial without finalizing anything.
/// A boundary has to be forced, but *where* it lands decides whether the transcript
/// reads as sentences or as arbitrary twenty-second slices. So the policy waits for the
/// partial to end on sentence punctuation and cuts there, falling back to a hard
/// ceiling only when no sentence end comes along.
struct TurnBoundaryPolicy {
    /// Never cut a segment shorter than this, even at a sentence end. Short segments
    /// translate worse and cost a request each.
    var minSegmentSec: Double = 8
    /// Cut here whatever the punctuation, so a run-on speaker still gets finalized.
    var maxSegmentSec: Double = 25
    /// Send the boundary a second time if nothing was finalized after this long. The
    /// first one is ignored now and then; an answered one arrives within half a
    /// second, so waiting longer than this only delays the segment.
    var retryAfterSec: Double = 3
    /// After this long with no finalization the connection is treated as wedged.
    var giveUpAfterSec: Double = 15

    enum Decision: Equatable {
        case wait
        case flush
        case retryFlush
        case replaceConnection
    }

    struct Input: Equatable {
        /// Seconds since the first partial of the open turn arrived; nil when no turn
        /// is open (nothing to finalize, so nothing to force).
        var turnOpenFor: Double?
        /// The latest partial ends on sentence punctuation.
        var interimEndsSentence: Bool
        /// Seconds since a boundary was forced and not yet answered; nil when none is pending.
        var sinceForcedFlush: Double?
        /// The pending boundary has already been resent once.
        var flushRetried: Bool
    }

    func decide(_ input: Input) -> Decision {
        if let since = input.sinceForcedFlush {
            if since >= giveUpAfterSec { return .replaceConnection }
            if since >= retryAfterSec, !input.flushRetried { return .retryFlush }
            return .wait
        }
        guard let openFor = input.turnOpenFor else { return .wait }
        if openFor >= maxSegmentSec { return .flush }
        if openFor >= minSegmentSec, input.interimEndsSentence { return .flush }
        return .wait
    }
}

/// Removes text the service repeats at the head of a new segment's partials.
///
/// After a segment is finalized, the next segment's partials often still begin with
/// the previous segment's words — observed after both forced and natural boundaries.
/// The repeat is not an exact copy of anything: it is the last partial plus whatever
/// words were in flight when the boundary landed, and it ends where the new words
/// begin without so much as a space ("…check it out just to eventhe chart"). Shown
/// as-is, the "listening…" row repeats the block above it, and salvaging such a
/// partial as a block duplicates that block outright.
enum InterimCleaner {
    /// The shared prefix must cover this much of a candidate to count as a repeat.
    static let minimumCoverage = 0.8
    /// …and be at least this long, so two segments that merely open with the same
    /// couple of words are not confused for a repeat.
    static let minimumCharacters = 8

    /// Strips the candidate that `interim` repeats most of, choosing the longest match.
    static func strip(_ interim: String, previous: [String]) -> String {
        var bestMatch = 0
        for raw in previous {
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.count >= minimumCharacters else { continue }
            let shared = interim.commonPrefix(with: candidate).count
            guard shared >= minimumCharacters,
                  Double(shared) >= Double(candidate.count) * minimumCoverage else { continue }
            bestMatch = max(bestMatch, shared)
        }
        guard bestMatch > 0 else { return interim }

        // What the candidate had beyond the shared prefix ("see" in the example above)
        // was the final's guess at the in-flight words; the new partial re-hears them.
        // Drop the punctuation and whitespace such a seam leaves behind.
        let remainder = interim.dropFirst(bestMatch).drop { $0.isWhitespace || $0.isPunctuation }
        return String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Puts back the words SMART mode drops from the head of a forced segment.
///
/// A boundary forced mid-speech starts the next segment a word or two into a
/// sentence. The partials for that segment carry those words ("so jetzt zum Beispiel
/// auch, wenn ich auf Deutsch spreche, you can see even though…"), but the
/// smart-formatted final treats an opening that runs mid-sentence as a false start
/// and begins at the next clean sentence ("You can see even though…"). The dropped
/// head is real speech — a whole German sentence, in that recording — so losing it
/// leaves a hole in the transcript.
enum SeamRepair {
    /// The head must be short: a fragment left by one boundary, not a paragraph.
    static let maximumHeadCharacters = 80
    /// How much of the final's opening is looked for inside the partial.
    static let probeCharacters = 8

    /// Words SMART mode is meant to remove. A head made of nothing else really was a
    /// false start, and putting it back would undo the formatting the user asked for.
    private static let fillers: Set<String> = [
        "so", "um", "uh", "er", "ah", "mm", "hmm", "like", "well", "okay", "ok",
        "yeah", "yep", "you", "know", "i", "mean", "actually", "basically", "and",
        "but", "or", "the", "a", "kind", "sort", "of", "right",
        "えー", "えーと", "ええと", "あの", "あのー", "その", "まあ", "ま", "うーん", "んー",
    ]
    /// How many leading words of the final are compared when looking for a repeat.
    private static let maximumOverlapWords = 3

    static func restoreDroppedHead(final: String, interim: String, previousFinal: String = "") -> String {
        let final = final.trimmingCharacters(in: .whitespacesAndNewlines)
        let interim = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard final.count >= probeCharacters, interim.count > probeCharacters else { return final }

        // SMART rewrites fillers and capitalisation ("So, you know, we can" becomes
        // "So, we can"), so only the opening of the final is expected to appear
        // verbatim in the partial: its first few characters, or failing that its
        // first word.
        let firstWord = final.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let probes = [String(final.prefix(probeCharacters)), firstWord].filter { $0.count >= 3 }
        for probe in probes {
            guard let range = interim.range(of: probe, options: [.caseInsensitive]) else { continue }
            let raw = String(interim[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // A stutter the formatter removed ("we can, we can improve") leaves the
            // repeated words at the end of the head; putting them back would restate
            // the opening of the final.
            let head = droppingOverlap(with: final, from: raw)
            guard isRestorable(head, previousFinal: previousFinal) else { continue }
            return BlockAssembler.join(head, final)
        }
        return final
    }

    /// Removes words at the start of a final that the previous block already ends on.
    ///
    /// The audio replayed after a boundary is there to be discarded, but the service
    /// sometimes transcribes the tail of it, so a word lands in both blocks
    /// ("…more accurate transcription, which" / "Which is really nice."). Only a cut
    /// that left the previous block mid-sentence can produce this.
    static func trimDuplicatedHead(final: String, previousFinal: String) -> String {
        let final = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previousFinal.isEmpty, !BlockAssembler.endsSentence(previousFinal) else { return final }
        let previousWords = previousFinal.split(whereSeparator: \.isWhitespace).map(normalizedWord)
        let finalWords = final.split(whereSeparator: \.isWhitespace)
        guard !previousWords.isEmpty, !finalWords.isEmpty else { return final }

        let limit = min(maximumOverlapWords, min(previousWords.count, finalWords.count))
        for count in stride(from: limit, through: 1, by: -1) {
            let opening = finalWords.prefix(count).map(normalizedWord)
            guard opening.allSatisfy({ !$0.isEmpty }),
                  Array(previousWords.suffix(count)) == opening else { continue }
            let remainder = final[finalWords[count - 1].endIndex...]
                .drop { $0.isWhitespace || $0.isPunctuation }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? final : remainder
        }
        return final
    }

    private static func isRestorable(_ head: String, previousFinal: String) -> Bool {
        guard !head.isEmpty,
              head.count <= maximumHeadCharacters,
              BlockAssembler.isMeaningful(head),
              !isAllFiller(head) else { return false }
        // The partial may still carry the tail of the segment before it, which is
        // already sitting in the previous block; restoring it would duplicate it.
        let normalizedHead = normalized(head)
        guard !normalizedHead.isEmpty else { return false }
        return !normalized(previousFinal).hasSuffix(normalizedHead)
    }

    /// Drops the longest run of words at the end of `head` that repeats the opening
    /// of `final`.
    private static func droppingOverlap(with final: String, from head: String) -> String {
        let headWords = head.split(whereSeparator: \.isWhitespace)
        let finalWords = final.split(whereSeparator: \.isWhitespace).map(normalizedWord)
        let limit = min(maximumOverlapWords, min(headWords.count, finalWords.count))
        for count in stride(from: limit, through: 1, by: -1) {
            let tail = headWords.suffix(count).map(normalizedWord)
            guard tail.allSatisfy({ !$0.isEmpty }),
                  Array(finalWords.prefix(count)) == tail else { continue }
            return String(head[..<headWords[headWords.count - count].startIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return head
    }

    private static func isAllFiller(_ head: String) -> Bool {
        let words = head
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { fillers.contains($0) }
    }

    private static func normalizedWord(_ word: Substring) -> String { normalized(String(word)) }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }
}
