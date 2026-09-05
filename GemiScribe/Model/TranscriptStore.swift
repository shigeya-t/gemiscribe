import Foundation
import Observation

/// The transcript the UI renders: assembled blocks plus the in-flight partial line.
@MainActor
@Observable
final class TranscriptStore {
    private(set) var blocks: [TranscriptBlock] = []
    var interimText: String = ""
    private(set) var recordedAt: Date?
    private(set) var durationSec: Double = 0

    private var assembler = BlockAssembler()

    var isEmpty: Bool { blocks.isEmpty }

    /// How long the last block stays open to absorb the next turn.
    var mergeWindowSec: Double { assembler.mergeWindowSec }

    /// True once no later turn can merge into `block`.
    func isSettled(_ block: TranscriptBlock) -> Bool { assembler.isSettled(block) }

    /// True for a few words still waiting for the turn that completes them.
    func isFragment(_ block: TranscriptBlock) -> Bool { assembler.isFragment(block) }

    func beginRecording(at date: Date = Date()) {
        if recordedAt == nil { recordedAt = date }
    }

    func updateDuration(_ seconds: Double) {
        durationSec = max(durationSec, seconds)
    }

    @discardableResult
    func ingest(_ turn: FinalizedTurn) -> [BlockChange] {
        let changes = assembler.ingest(turn)
        if !changes.isEmpty { blocks = assembler.blocks }
        return changes
    }

    /// Corrects the newest block's end once the server reports where its segment ended.
    func trimLastBlockEnd(to endSec: Double) {
        if assembler.trimLastBlockEnd(to: endSec) != nil { blocks = assembler.blocks }
    }

    func markTranslationPending(_ id: UUID) {
        if assembler.markTranslationPending(id) != nil { blocks = assembler.blocks }
    }

    func applyTranslation(_ result: Result<String, Error>, to id: UUID) {
        if assembler.applyTranslation(result, to: id) != nil { blocks = assembler.blocks }
    }

    func block(with id: UUID) -> TranscriptBlock? {
        blocks.first { $0.id == id }
    }

    func clear() {
        assembler.reset()
        blocks = []
        interimText = ""
        recordedAt = nil
        durationSec = 0
    }
}
