import Foundation

/// A completed turn from the Live API, already paired with an audio-clock time range.
struct FinalizedTurn: Equatable, Sendable {
    var text: String
    var startSec: Double
    var endSec: Double
    var languageCode: String?
}

enum BlockChange: Equatable, Sendable {
    /// A new block was added to the end of the transcript.
    case appended(TranscriptBlock)
    /// An existing block absorbed this turn; its translation needs redoing.
    case replaced(TranscriptBlock)
}

/// Turns the Live API's VAD-delimited turns into the transcript's display blocks.
///
/// Gemini already splits on pauses, but the raw turns are sometimes too granular
/// (a one-word acknowledgement becomes its own block) and occasionally too coarse
/// (an uninterrupted monologue). This smooths both ends.
struct BlockAssembler {
    /// A turn arriving within this long of the previous block is a candidate for merging.
    var mergeGapSec: Double = 1.5
    /// …but only if the previous block is still this short.
    var mergeMaxCharacters: Int = 20
    /// How long a pause may be while still joining a turn onto a block that ended
    /// mid-sentence.
    var sentenceMergeGapSec: Double = 3
    /// Blocks longer than this are split on sentence boundaries, and a block already
    /// this long stops absorbing turns even mid-sentence, so speech with no full stops
    /// in it cannot run away.
    var maxBlockSec: Double = 60

    private(set) var blocks: [TranscriptBlock] = []

    mutating func reset() {
        blocks = []
    }

    @discardableResult
    mutating func ingest(_ turn: FinalizedTurn) -> [BlockChange] {
        let text = Self.flattenLines(turn.text)
        guard Self.isMeaningful(text) else { return [] }

        // A turn that continues the open block is folded into it, and the result is
        // then re-split on sentence boundaries if it has grown past the duration
        // ceiling. Earlier blocks are never touched; only the newest is ever reopened.
        var combinedText = text
        var startSec = turn.startSec
        var endSec = turn.endSec
        var languageCode = turn.languageCode
        var reopened: TranscriptBlock?
        if let last = blocks.last, shouldMerge(turn, text: text, into: last) {
            combinedText = Self.join(last.text, text)
            startSec = last.startSec
            endSec = max(last.endSec, turn.endSec)
            languageCode = last.languageCode ?? turn.languageCode
            reopened = blocks.removeLast()
        }

        var pieces = Self.split(text: combinedText,
                                startSec: startSec,
                                endSec: endSec,
                                maxBlockSec: maxBlockSec)
        if let last = pieces.popLast() {
            pieces.append(contentsOf: Self.detachTrailingFragment(from: last))
        }
        var changes: [BlockChange] = []
        for (index, piece) in pieces.enumerated() {
            if index == 0, let reopened {
                // Keeps its identity so an in-flight translation can still find it —
                // and be discarded, because the text it was for has changed.
                let block = TranscriptBlock(id: reopened.id,
                                            startSec: piece.startSec,
                                            endSec: piece.endSec,
                                            text: piece.text,
                                            languageCode: languageCode)
                blocks.append(block)
                changes.append(.replaced(block))
            } else {
                let block = TranscriptBlock(startSec: piece.startSec,
                                            endSec: piece.endSec,
                                            text: piece.text,
                                            languageCode: languageCode)
                blocks.append(block)
                changes.append(.appended(block))
            }
        }
        return changes
    }

    /// Pulls the newest block's end back to `endSec`. The server reports where a
    /// segment ended a beat after finalizing it, so the block is first stamped with the
    /// audio clock and then corrected here.
    @discardableResult
    mutating func trimLastBlockEnd(to endSec: Double) -> TranscriptBlock? {
        guard var last = blocks.last, endSec < last.endSec, endSec > last.startSec else { return nil }
        last.endSec = endSec
        blocks[blocks.count - 1] = last
        return last
    }

    /// The service ends a turn whenever the speaker draws breath, which lands
    /// mid-sentence often enough that half-sentences are the norm rather than the
    /// exception. Two halves also translate far worse than one whole, because each half
    /// is translated without the grammar that completes it.
    ///
    /// There is deliberately no character limit: when the service is being forced to
    /// finalize every twenty-odd seconds, each turn is a few hundred characters and a
    /// limit sized for conversational fragments would leave every cut sentence in two.
    /// The duration ceiling and the sentence re-split keep merged blocks in bounds.
    private func shouldMerge(_ turn: FinalizedTurn, text: String, into last: TranscriptBlock) -> Bool {
        let gap = turn.startSec - last.endSec
        guard gap < mergeWindowSec else { return false }
        guard last.endSec - last.startSec <= maxBlockSec else { return false }

        // A stray one-word turn belongs to its neighbour whatever the punctuation says.
        if gap < mergeGapSec, last.text.count < mergeMaxCharacters { return true }

        return gap < sentenceMergeGapSec && !Self.endsSentence(last.text)
    }

    /// How long a block stays open to absorb the next turn.
    var mergeWindowSec: Double { max(mergeGapSec, sentenceMergeGapSec) }

    /// True once no later turn can merge into this block: it ends a sentence *and* is
    /// long enough that the stray-fragment rule cannot fire either. Translating before
    /// that means paying for the block again every time it grows.
    func isSettled(_ block: TranscriptBlock) -> Bool {
        Self.endsSentence(block.text) && block.text.count >= mergeMaxCharacters
    }

    /// Punctuation that closes a sentence in either Japanese or English.
    static let sentenceTerminators: Set<Character> = [
        "。", "．", ".", "!", "?", "！", "？", "…",
        "」", "』", "）", ")", "\"", "”",
    ]

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return sentenceTerminators.contains(last)
    }

    /// Applies a translation result to a block, ignoring it if the block was
    /// merged away or the transcript was cleared while the request was in flight.
    @discardableResult
    mutating func applyTranslation(_ result: Result<String, Error>, to id: UUID) -> TranscriptBlock? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        switch result {
        case .success(let text):
            blocks[index].translation = text
            blocks[index].translationState = .done
        case .failure(let error):
            blocks[index].translation = nil
            blocks[index].translationState = .failed(error.localizedDescription)
        }
        return blocks[index]
    }

    @discardableResult
    mutating func markTranslationPending(_ id: UUID) -> TranscriptBlock? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        blocks[index].translationState = .pending
        return blocks[index]
    }

    // MARK: - Text helpers

    /// Rejects turns that carry no words — the API occasionally finalizes a turn
    /// with nothing but punctuation after a cough or a door slam.
    static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.value > 0x2FFF
        }
    }

    /// SMART mode puts paragraph breaks inside a segment ("生き延びました。\n\n先生は…").
    /// A block is one paragraph on screen and one list item in the Markdown export,
    /// so line breaks fold into the same seam rule as merged turns.
    static func flattenLines(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .reduce("") { $0.isEmpty ? $1 : join($0, $1) }
    }

    /// Joins two fragments, inserting a space only where Latin text needs one.
    static func join(_ lhs: String, _ rhs: String) -> String {
        guard let left = lhs.unicodeScalars.last, let right = rhs.unicodeScalars.first else {
            return lhs + rhs
        }
        let needsSpace = left.isASCII && right.isASCII
            && !CharacterSet.whitespaces.contains(left)
            && !CharacterSet.whitespaces.contains(right)
        return needsSpace ? "\(lhs) \(rhs)" : lhs + rhs
    }

    struct Piece: Equatable {
        var text: String
        var startSec: Double
        var endSec: Double
    }

    /// Splits an over-long turn on sentence boundaries, apportioning the time range
    /// by character count. The Live API gives no word timings, so this is an
    /// approximation — but it only ever runs on monologues past `maxBlockSec`.
    static func split(text: String, startSec: Double, endSec: Double, maxBlockSec: Double) -> [Piece] {
        let duration = max(0, endSec - startSec)
        guard duration > maxBlockSec, maxBlockSec > 0 else {
            return [Piece(text: text, startSec: startSec, endSec: endSec)]
        }

        let sentences = sentences(in: text)
        guard sentences.count > 1 else {
            return [Piece(text: text, startSec: startSec, endSec: endSec)]
        }

        let totalCharacters = Double(max(1, text.count))
        let targetGroups = max(2, Int((duration / maxBlockSec).rounded(.up)))
        let charactersPerGroup = totalCharacters / Double(targetGroups)

        var pieces: [Piece] = []
        var current = ""
        var consumedBefore = 0.0

        func flush() {
            guard !current.isEmpty else { return }
            let from = startSec + duration * (consumedBefore / totalCharacters)
            consumedBefore += Double(current.count)
            let to = startSec + duration * (consumedBefore / totalCharacters)
            pieces.append(Piece(text: current, startSec: from, endSec: to))
            current = ""
        }

        for sentence in sentences {
            // Close the group *before* the sentence that would overflow it, so every
            // cut lands on a sentence end and a trailing fragment stays on its own.
            if !current.isEmpty, Double(current.count + sentence.count) > charactersPerGroup {
                flush()
            }
            current += sentence
        }
        flush()
        if var last = pieces.last {
            last.endSec = endSec
            pieces[pieces.count - 1] = last
        }
        return pieces
    }

    /// Separates the unfinished sentence at the end of a piece from the finished ones
    /// before it, apportioning the time range by character count.
    ///
    /// A boundary forced at a sentence end still arrives with the few words spoken
    /// while the request was in flight ("…then you don't need it. So that's"). Left
    /// attached, that tail keeps the block open, the next turn merges into it, and the
    /// block boundary lands mid-sentence again. Detached, the finished sentences settle
    /// and the tail becomes the open block the next turn completes.
    static func detachTrailingFragment(from piece: Piece) -> [Piece] {
        let sentences = sentences(in: piece.text)
        guard sentences.count > 1, let tail = sentences.last, !endsSentence(tail) else {
            return [piece]
        }
        let head = sentences.dropLast().joined()
        let duration = max(0, piece.endSec - piece.startSec)
        let total = Double(max(1, piece.text.count))
        let cut = piece.startSec + duration * (Double(head.count) / total)
        return [
            Piece(text: head, startSec: piece.startSec, endSec: cut),
            Piece(text: tail.trimmingCharacters(in: .whitespaces), startSec: cut, endSec: piece.endSec),
        ]
    }

    /// A block that neither ends a sentence nor has grown past the stray-fragment size:
    /// a few words waiting for the turn that completes them.
    func isFragment(_ block: TranscriptBlock) -> Bool {
        !Self.endsSentence(block.text) && block.text.count < mergeMaxCharacters
    }

    /// Splits after sentence-ending punctuation, keeping the punctuation attached.
    static func sentences(in text: String) -> [String] {
        let terminators: Set<Character> = ["。", "．", ".", "!", "?", "！", "？", "\n"]
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if terminators.contains(character) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
