import XCTest
@testable import GemiScribe

final class AudioPipelineTests: XCTestCase {

    // MARK: - PCM conversion

    func testFloatSamplesBecomeLittleEndianPCM16() {
        let data = AudioMixer.pcm16Data(from: [0, 1, -1])
        XCTAssertEqual(data.count, 6)
        XCTAssertEqual([UInt8](data[0..<2]), [0x00, 0x00])
        XCTAssertEqual([UInt8](data[2..<4]), [0xFF, 0x7F])   // +32767
        XCTAssertEqual([UInt8](data[4..<6]), [0x01, 0x80])   // -32767
    }

    func testSamplesBeyondUnityAreClipped() {
        let data = AudioMixer.pcm16Data(from: [4.5, -4.5])
        XCTAssertEqual([UInt8](data[0..<2]), [0xFF, 0x7F])
        XCTAssertEqual([UInt8](data[2..<4]), [0x01, 0x80])
    }

    // MARK: - Ring buffer

    func testRingBufferZeroPadsWhenItRunsDry() {
        var buffer = RingBuffer(capacity: 16)
        buffer.write([0.5, 0.5])
        let read = buffer.read(frames: 4)
        XCTAssertEqual(read, [0.5, 0.5, 0, 0])
        XCTAssertEqual(buffer.count, 0)
    }

    func testRingBufferDropsOldestOnOverflow() {
        var buffer = RingBuffer(capacity: 3)
        buffer.write([1, 2, 3, 4])
        XCTAssertEqual(buffer.read(frames: 3), [2, 3, 4])
    }

    // MARK: - Voice activity detection

    private func chunk(amplitude: Float) -> Data {
        AudioMixer.pcm16Data(from: [Float](repeating: amplitude, count: AudioFormatSpec.framesPerChunk))
    }

    func testDetectorEmitsASpanAfterTheHangover() {
        let detector = SpeechActivityDetector()
        detector.thresholdDB = -45
        detector.hangoverMs = 300
        var spans: [SpeechSpan] = []
        detector.onSpan = { spans.append($0) }

        var time = 0.0
        // 1 s of speech, then 400 ms of silence.
        for _ in 0..<10 {
            detector.process(chunk: chunk(amplitude: 0.3), startSec: time)
            time += AudioFormatSpec.frameDurationSec
        }
        for _ in 0..<4 {
            detector.process(chunk: chunk(amplitude: 0), startSec: time)
            time += AudioFormatSpec.frameDurationSec
        }

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].startSec, 0, accuracy: 0.15)
        XCTAssertEqual(spans[0].endSec, 1.0, accuracy: 0.15)
    }

    func testDetectorIgnoresAnIsolatedClick() {
        let detector = SpeechActivityDetector()
        detector.thresholdDB = -45
        var spans: [SpeechSpan] = []
        detector.onSpan = { spans.append($0) }

        detector.process(chunk: chunk(amplitude: 0.4), startSec: 0)
        for index in 1...12 {
            detector.process(chunk: chunk(amplitude: 0),
                             startSec: Double(index) * AudioFormatSpec.frameDurationSec)
        }
        XCTAssertTrue(spans.isEmpty)
    }

    func testDecibelsOfSilenceIsBelowTheDefaultThreshold() {
        XCTAssertLessThan(SpeechActivityDetector.decibels(ofPCM16: chunk(amplitude: 0)),
                          AppSettings.Default.silenceThresholdDB)
        XCTAssertGreaterThan(SpeechActivityDetector.decibels(ofPCM16: chunk(amplitude: 0.2)),
                             AppSettings.Default.silenceThresholdDB)
    }

    // MARK: - Timestamp pairing

    func testTimestamperUsesTheQueuedSpan() {
        let timestamper = BlockTimestamper()
        timestamper.noteSpan(SpeechSpan(startSec: 4.1, endSec: 8.9))
        let range = timestamper.resolve(atAudioTime: 9.6)
        XCTAssertEqual(range.start, 4.1, accuracy: 0.001)
        XCTAssertEqual(range.end, 8.9, accuracy: 0.001)
    }

    func testTimestamperFallsBackToTheFirstInterim() {
        let timestamper = BlockTimestamper()
        timestamper.noteInterim(atAudioTime: 12.0)
        timestamper.noteInterim(atAudioTime: 12.4) // later partials must not move the anchor
        let range = timestamper.resolve(atAudioTime: 13.0)
        // The anchor is backed off by the partial latency: the words were spoken
        // slightly before the service returned its first guess at them.
        XCTAssertEqual(range.start, 11.5, accuracy: 0.001)
        XCTAssertEqual(range.end, 13.0, accuracy: 0.001)
    }

    func testTimestamperResyncsWhenLocalVADOutrunsTheServer() {
        let timestamper = BlockTimestamper()
        timestamper.maxQueuedSpans = 3
        for index in 0..<6 {
            timestamper.noteSpan(SpeechSpan(startSec: Double(index), endSec: Double(index) + 0.5))
        }
        // The three oldest were dropped, so the next turn is timed from span #3.
        XCTAssertEqual(timestamper.resolve(atAudioTime: 10).start, 3, accuracy: 0.001)
    }

    func testTimestamperResetClearsEverything() {
        let timestamper = BlockTimestamper()
        timestamper.noteSpan(SpeechSpan(startSec: 1, endSec: 2))
        timestamper.noteInterim(atAudioTime: 1)
        timestamper.noteServerActivityStarted(at: 0.5)
        timestamper.reset()
        XCTAssertEqual(timestamper.resolve(atAudioTime: 7).start, 7, accuracy: 0.001)
    }

    // MARK: - Server voice activity

    /// The order seen on the wire: ACTIVITY_START, partials, the final, then
    /// ACTIVITY_END a beat later. The final is stamped from the server start and the
    /// audio clock, and the end is tightened once the server reports it.
    func testServerActivityAnchorsTheTurn() {
        let timestamper = BlockTimestamper()
        timestamper.noteServerActivityStarted(at: 4.96)
        timestamper.noteInterim(atAudioTime: 6.0)
        let range = timestamper.resolve(atAudioTime: 25.3)
        XCTAssertEqual(range.start, 4.96, accuracy: 0.001)
        XCTAssertEqual(range.end, 25.3, accuracy: 0.001)
        XCTAssertTrue(timestamper.noteServerActivityEnded(at: 24.9),
                      "an end arriving after the final belongs to the block already made")
    }

    func testServerActivityEndBeforeTheFinalIsUsedDirectly() {
        let timestamper = BlockTimestamper()
        timestamper.noteServerActivityStarted(at: 10)
        XCTAssertFalse(timestamper.noteServerActivityEnded(at: 18))
        let range = timestamper.resolve(atAudioTime: 19)
        XCTAssertEqual(range.start, 10, accuracy: 0.001)
        XCTAssertEqual(range.end, 18, accuracy: 0.001)
    }

    /// Server timing wins over a queued local span, and consumes the spans it covers
    /// so they are not handed to a later turn.
    func testServerActivityOutranksLocalSpans() {
        let timestamper = BlockTimestamper()
        timestamper.noteSpan(SpeechSpan(startSec: 1, endSec: 3))
        timestamper.noteSpan(SpeechSpan(startSec: 5, endSec: 12))
        timestamper.noteServerActivityStarted(at: 4.5)
        let first = timestamper.resolve(atAudioTime: 12.5)
        XCTAssertEqual(first.start, 4.5, accuracy: 0.001)

        // Nothing from the server for the next turn: the fallback must not reach
        // back to the 1–3 s span the server already superseded.
        timestamper.noteInterim(atAudioTime: 13.0)
        let second = timestamper.resolve(atAudioTime: 20)
        XCTAssertEqual(second.start, 12.5, accuracy: 0.001)
    }
}

final class AudioMixerClockTests: XCTestCase {
    /// Stopping and starting again must continue the transcript's timeline, otherwise
    /// a second take stamps its blocks on top of the first one's.
    func testClockResumesFromTheGivenOffset() {
        let mixer = AudioMixer()
        XCTAssertEqual(mixer.elapsedSeconds, 0, accuracy: 0.001)

        mixer.start(timeOffset: 42)
        XCTAssertEqual(mixer.elapsedSeconds, 42, accuracy: 0.001)
        mixer.stop()
    }

    func testClockAdvancesWithEmittedChunks() {
        let mixer = AudioMixer()
        mixer.setEnabled([.system])
        let emitted = expectation(description: "chunk emitted")
        emitted.assertForOverFulfill = false
        var firstStart: Double?
        mixer.onChunk = { _, startSec in
            if firstStart == nil { firstStart = startSec }
            emitted.fulfill()
        }
        mixer.start(timeOffset: 10)
        wait(for: [emitted], timeout: 2)
        mixer.stop()

        XCTAssertEqual(firstStart ?? -1, 10, accuracy: 0.001)
        XCTAssertGreaterThan(mixer.elapsedSeconds, 10)
    }

    /// With every source switched off the mixer still emits silence, so the clock —
    /// and every later timestamp — stays continuous.
    func testClockKeepsRunningWithNoSourceEnabled() {
        let mixer = AudioMixer()
        mixer.setEnabled([])
        let emitted = expectation(description: "silence emitted")
        emitted.assertForOverFulfill = false
        var chunkSize = 0
        mixer.onChunk = { data, _ in
            chunkSize = data.count
            emitted.fulfill()
        }
        mixer.start()
        wait(for: [emitted], timeout: 2)
        mixer.stop()

        XCTAssertEqual(chunkSize, AudioFormatSpec.framesPerChunk * 2)
    }
}

final class AudioStatsTests: XCTestCase {
    /// The mixer emits a chunk every 100 ms whether or not any sound arrived, so a
    /// chunk count alone cannot tell "streaming speech" from "streaming silence".
    /// These counters are what distinguish the two in the heartbeat log.
    private func chunk(amplitude: Float) -> Data {
        AudioMixer.pcm16Data(from: [Float](repeating: amplitude, count: AudioFormatSpec.framesPerChunk))
    }

    func testDetectorReportsTheChunkLevel() {
        let detector = SpeechActivityDetector()
        let silence = detector.process(chunk: chunk(amplitude: 0), startSec: 0)
        let speech = detector.process(chunk: chunk(amplitude: 0.25), startSec: 0.1)
        XCTAssertLessThan(silence, -100)
        XCTAssertGreaterThan(speech, -20)
    }

    func testStatsSummaryReportsSilenceAsZeroPercent() {
        var stats = AudioSourceManager.AudioStats()
        stats.chunks = 100
        stats.speechChunks = 0
        stats.peakDB = -120
        XCTAssertEqual(stats.summary, "speech=0% peak=-120dB gate=-45dB spans=0")
    }

    func testStatsSummaryReportsSpeechShare() {
        var stats = AudioSourceManager.AudioStats()
        stats.chunks = 100
        stats.speechChunks = 42
        stats.peakDB = -12.4
        stats.spans = 3
        XCTAssertEqual(stats.summary, "speech=42% peak=-12dB gate=-45dB spans=3")
    }

    func testConsumeStatsResetsTheCounters() {
        let manager = AudioSourceManager()
        XCTAssertEqual(manager.consumeStats().chunks, 0)
        XCTAssertEqual(manager.consumeStats().speechChunks, 0)
    }
}

@MainActor
final class AudioLevelsTests: XCTestCase {
    /// Levels arrive ten times a second. Publishing every one of them re-renders every
    /// view that reads them, so changes below the eye's resolution are dropped.
    func testTinyChangesDoNotPublish() {
        let levels = AudioLevels()
        levels.update([.system: 0.50, .microphone: 0])
        XCTAssertEqual(levels.system, 0.50, accuracy: 0.001)

        levels.update([.system: 0.51, .microphone: 0])
        XCTAssertEqual(levels.system, 0.50, accuracy: 0.001)

        levels.update([.system: 0.60, .microphone: 0])
        XCTAssertEqual(levels.system, 0.60, accuracy: 0.001)
    }

    func testSubscriptReadsEachSource() {
        let levels = AudioLevels()
        levels.update([.system: 0.4, .microphone: 0.9])
        XCTAssertEqual(levels[.system], 0.4, accuracy: 0.001)
        XCTAssertEqual(levels[.microphone], 0.9, accuracy: 0.001)
    }

    func testResetClearsBothSources() {
        let levels = AudioLevels()
        levels.update([.system: 0.8, .microphone: 0.8])
        levels.reset()
        XCTAssertEqual(levels[.system], 0)
        XCTAssertEqual(levels[.microphone], 0)
    }
}

final class MainThreadMonitorTests: XCTestCase {
    func testReportsAStallWhenTheMainThreadIsBlocked() {
        let monitor = MainThreadMonitor()
        monitor.stallThresholdSec = 0.2

        let stalled = expectation(description: "stall reported")
        stalled.assertForOverFulfill = false
        nonisolated(unsafe) var reported: TimeInterval = 0
        monitor.onStall = { latency in
            reported = latency
            stalled.fulfill()
        }
        monitor.start()

        // Pings go out once a second starting at t=1s. Blocking the main thread from
        // t=0.5s to t=2.5s guarantees the first ping is delivered late.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Thread.sleep(forTimeInterval: 2.0)
        }
        wait(for: [stalled], timeout: 10)
        monitor.stop()

        XCTAssertGreaterThan(reported, 0.2)
    }

    func testWorstLatencyIsResetWhenRead() {
        let monitor = MainThreadMonitor()
        XCTAssertEqual(monitor.consumeWorst(), 0, accuracy: 0.001)
    }
}

final class ContinuousSpeechTimestampTests: XCTestCase {
    /// Real recordings — a video, a busy meeting — often never go quiet enough for the
    /// local VAD to close a span. These cover that path, which is the common one.

    func testContinuousTurnsStartWhereThePreviousOneEnded() {
        let timestamper = BlockTimestamper()

        timestamper.noteInterim(atAudioTime: 1.5)
        let first = timestamper.resolve(atAudioTime: 12.0)
        XCTAssertEqual(first.start, 1.0, accuracy: 0.001)   // 1.5 s minus partial latency
        XCTAssertEqual(first.end, 12.0, accuracy: 0.001)

        // Next turn's first partial arrives 1.2 s later: continuous speech, no pause.
        timestamper.noteInterim(atAudioTime: 13.2)
        let second = timestamper.resolve(atAudioTime: 20.0)
        XCTAssertEqual(second.start, 12.0, accuracy: 0.001)
        XCTAssertEqual(second.end, 20.0, accuracy: 0.001)
    }

    func testARealPauseIsNotSwallowed() {
        let timestamper = BlockTimestamper()
        timestamper.noteInterim(atAudioTime: 1.0)
        _ = timestamper.resolve(atAudioTime: 10.0)

        // Nothing for 20 s, then someone speaks again.
        timestamper.noteInterim(atAudioTime: 30.0)
        let next = timestamper.resolve(atAudioTime: 34.0)
        XCTAssertEqual(next.start, 29.5, accuracy: 0.001)
        XCTAssertEqual(next.end, 34.0, accuracy: 0.001)
    }

    func testTimestampsNeverGoBackwards() {
        let timestamper = BlockTimestamper()
        var previousEnd = 0.0
        for step in 1...20 {
            let now = Double(step) * 7
            timestamper.noteInterim(atAudioTime: now - 5)
            let range = timestamper.resolve(atAudioTime: now)
            XCTAssertGreaterThanOrEqual(range.start, previousEnd - 0.001)
            XCTAssertGreaterThanOrEqual(range.end, range.start)
            previousEnd = range.end
        }
    }

    func testAClosedSpanStillWins() {
        let timestamper = BlockTimestamper()
        timestamper.noteInterim(atAudioTime: 4.0)
        timestamper.noteSpan(SpeechSpan(startSec: 2.0, endSec: 8.0))
        let range = timestamper.resolve(atAudioTime: 9.0)
        XCTAssertEqual(range.start, 2.0, accuracy: 0.001)
        XCTAssertEqual(range.end, 8.0, accuracy: 0.001)
    }

    func testResetForgetsThePreviousEnd() {
        let timestamper = BlockTimestamper()
        timestamper.noteInterim(atAudioTime: 1.0)
        _ = timestamper.resolve(atAudioTime: 50.0)
        timestamper.reset()

        timestamper.noteInterim(atAudioTime: 2.0)
        let range = timestamper.resolve(atAudioTime: 6.0)
        XCTAssertEqual(range.start, 1.5, accuracy: 0.001)
    }
}

final class MixerUnderrunTests: XCTestCase {
    /// A short-and-zero-padded chunk splices silence into the middle of a word every
    /// time the capture callback lands just after the timer. The mixer must wait for a
    /// whole chunk instead.
    func testEmittedAudioIsTheWrittenAudioNotPadding() {
        let mixer = AudioMixer()
        mixer.setEnabled([.system])

        let loudChunk = expectation(description: "a chunk carrying the written audio")
        loudChunk.assertForOverFulfill = false
        mixer.onChunk = { data, _ in
            if SpeechActivityDetector.decibels(ofPCM16: data) > -20 { loudChunk.fulfill() }
        }

        mixer.start()
        // Half a chunk first: on its own this must not be emitted as padded silence.
        mixer.write([Float](repeating: 0.5, count: AudioFormatSpec.framesPerChunk / 2), from: .system)
        mixer.write([Float](repeating: 0.5, count: AudioFormatSpec.framesPerChunk * 3), from: .system)

        wait(for: [loudChunk], timeout: 3)
        mixer.stop()
    }

    /// A source that stops delivering must not freeze the clock, or every later
    /// timestamp collapses onto the same second.
    func testAStarvedSourceStillKeepsTimeAfterTheGracePeriod() {
        let mixer = AudioMixer()
        mixer.setEnabled([.system])

        let kepttime = expectation(description: "clock keeps running")
        kepttime.assertForOverFulfill = false
        mixer.onChunk = { data, _ in
            if SpeechActivityDetector.decibels(ofPCM16: data) < -100 { kepttime.fulfill() }
        }

        mixer.start()   // nothing is ever written
        wait(for: [kepttime], timeout: 3)
        mixer.stop()

        XCTAssertGreaterThan(mixer.consumeUnderruns(), 0, "starvation should be reported")
        XCTAssertGreaterThan(mixer.elapsedSeconds, 0)
    }

    func testUnderrunCountResetsWhenRead() {
        let mixer = AudioMixer()
        XCTAssertEqual(mixer.consumeUnderruns(), 0)
    }
}

final class AdaptiveSilenceThresholdTests: XCTestCase {
    /// A fixed threshold marks continuous material — a podcast, a video with music —
    /// as 100% speech, so no pause is ever found and every block timestamp falls back
    /// to guesswork. The gate has to follow the material's own noise floor.
    private func chunk(_ amplitude: Float) -> Data {
        AudioMixer.pcm16Data(from: [Float](repeating: amplitude, count: AudioFormatSpec.framesPerChunk))
    }

    func testGateRisesToSitAboveALoudNoiseFloor() {
        let detector = SpeechActivityDetector()
        XCTAssertEqual(detector.effectiveThresholdDB, -45, accuracy: 0.001)

        // Room tone around -30 dBFS, the sort a podcast never drops below.
        for index in 0..<200 {
            detector.process(chunk: chunk(0.03), startSec: Double(index) * 0.1)
        }
        XCTAssertGreaterThan(detector.effectiveThresholdDB, -35,
                             "the gate must climb above the material's floor")
    }

    func testGateStaysAtTheAbsoluteFloorInAQuietRoom() {
        let detector = SpeechActivityDetector()
        for index in 0..<200 {
            detector.process(chunk: chunk(0.0002), startSec: Double(index) * 0.1)
        }
        XCTAssertEqual(detector.effectiveThresholdDB, -45, accuracy: 0.001)
    }

    /// The point of the whole exercise: speech over a loud floor produces spans.
    func testPausesAreFoundInContinuousMaterial() {
        let detector = SpeechActivityDetector()
        detector.hangoverMs = 300

        var spans: [SpeechSpan] = []
        detector.onSpan = { spans.append($0) }

        var time = 0.0
        func feed(_ amplitude: Float, seconds: Double) {
            for _ in 0..<Int(seconds / 0.1) {
                detector.process(chunk: chunk(amplitude), startSec: time)
                time += 0.1
            }
        }

        feed(0.03, seconds: 3)    // room tone establishes the floor
        feed(0.30, seconds: 2)    // speech
        feed(0.03, seconds: 2)    // a pause that never reaches -45 dBFS
        feed(0.30, seconds: 2)    // speech again
        feed(0.03, seconds: 2)

        XCTAssertGreaterThanOrEqual(spans.count, 2,
                                    "a fixed -45 dB gate finds none of these pauses")
    }

    func testResetForgetsTheLearnedFloor() {
        let detector = SpeechActivityDetector()
        for index in 0..<200 {
            detector.process(chunk: chunk(0.05), startSec: Double(index) * 0.1)
        }
        XCTAssertGreaterThan(detector.effectiveThresholdDB, -45)

        detector.reset()
        XCTAssertEqual(detector.effectiveThresholdDB, -45, accuracy: 0.001)
    }
}
