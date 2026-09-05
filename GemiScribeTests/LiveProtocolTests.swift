import XCTest
@testable import GemiScribe

final class LiveProtocolTests: XCTestCase {

    private func encodedSetup(smart: Bool, handle: String? = nil) throws -> [String: Any] {
        let message = LiveProtocol.SetupMessage(setup: .init(
            model: LiveProtocol.qualified(model: "gemini-3.5-transcribe-live"),
            generationConfig: .init(responseModalities: ["TEXT"]),
            inputAudioTranscription: .init(
                languageCodes: ["ja-JP"],
                customVocabulary: ["GemiScribe"],
                mode: smart ? LiveProtocol.InputAudioTranscription.smart
                            : LiveProtocol.InputAudioTranscription.verbatim
            ),
            sessionResumption: .init(handle: handle)
        ))
        let data = try LiveProtocol.encoder.encode(message)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["setup"] as? [String: Any])
    }

    func testSetupCarriesTheTranscriptionMode() throws {
        let verbatim = try encodedSetup(smart: false)
        let transcription = try XCTUnwrap(verbatim["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["ja-JP"])
        XCTAssertEqual(transcription["customVocabulary"] as? [String], ["GemiScribe"])

        let smart = try encodedSetup(smart: true)
        let smartTranscription = try XCTUnwrap(smart["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(smartTranscription["mode"] as? String, "SMART")
    }

    func testSetupRequestsTextResponsesAndAQualifiedModelName() throws {
        let setup = try encodedSetup(smart: false)
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        let generation = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseModalities"] as? [String], ["TEXT"])
    }

    /// Escaped slashes are legal JSON, but they make every debug log line read like a
    /// malformed model name.
    func testEncodedSetupDoesNotEscapeSlashes() throws {
        let message = LiveProtocol.SetupMessage(setup: .init(
            model: LiveProtocol.qualified(model: "gemini-3.5-transcribe-live"),
            generationConfig: .init(responseModalities: ["TEXT"]),
            inputAudioTranscription: .init(languageCodes: [], customVocabulary: [], mode: "SMART"),
            sessionResumption: .init(handle: nil)
        ))
        let json = String(decoding: try LiveProtocol.encoder.encode(message), as: UTF8.self)
        XCTAssertTrue(json.contains("models/gemini-3.5-transcribe-live"))
        XCTAssertFalse(json.contains("\\/"))
    }

    func testQualifiedModelNameIsNotDoubled() {
        XCTAssertEqual(LiveProtocol.qualified(model: "models/foo"), "models/foo")
    }

    func testSetupCarriesTheResumptionHandle() throws {
        let setup = try encodedSetup(smart: false, handle: "abc123")
        let resumption = try XCTUnwrap(setup["sessionResumption"] as? [String: Any])
        XCTAssertEqual(resumption["handle"] as? String, "abc123")
    }

    func testAudioChunkIsBase64WithThePCMMimeType() throws {
        let message = LiveProtocol.RealtimeInputMessage(
            realtimeInput: .init(audio: .init(data: Data([0x01, 0x02]).base64EncodedString(),
                                              mimeType: AudioFormatSpec.mimeType),
                                 audioStreamEnd: nil)
        )
        let data = try LiveProtocol.encoder.encode(message)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let realtime = try XCTUnwrap(root["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtime["audio"] as? [String: Any])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(audio["data"] as? String, "AQI=")
        XCTAssertNil(realtime["audioStreamEnd"])
    }

    func testDecodingAFinalizedTurn() throws {
        let json = """
        {"serverContent":{"inputTranscription":{"text":"こんにちは","languageCode":"ja-JP"},"turnComplete":true}}
        """
        let message = try JSONDecoder().decode(LiveProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.serverContent?.inputTranscription?.text, "こんにちは")
        XCTAssertEqual(message.serverContent?.inputTranscription?.languageCode, "ja-JP")
        XCTAssertNil(message.serverContent?.interimInputTranscription)
    }

    func testDecodingIgnoresUnknownFields() throws {
        // A recording must survive the service adding message kinds we do not know about.
        let json = """
        {"usageMetadata":{"totalTokenCount":42},"somethingNew":{"a":1},
         "serverContent":{"interimInputTranscription":{"text":"こん"},"unexpected":true}}
        """
        let message = try JSONDecoder().decode(LiveProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.serverContent?.interimInputTranscription?.text, "こん")
    }

    func testDecodingGoAwayDuration() throws {
        let json = #"{"goAway":{"timeLeft":"12.5s"}}"#
        let message = try JSONDecoder().decode(LiveProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.goAway?.timeLeftSeconds ?? 0, 12.5, accuracy: 0.001)
    }

    func testDecodingVoiceActivity() throws {
        let json = #"{"serverContent":{},"voiceActivity":{"type":"ACTIVITY_END","audioOffset":"20.900s"}}"#
        let message = try JSONDecoder().decode(LiveProtocol.ServerMessage.self, from: Data(json.utf8))
        let activity = try XCTUnwrap(message.voiceActivity)
        XCTAssertEqual(activity.type, LiveProtocol.VoiceActivity.end)
        XCTAssertEqual(activity.audioOffsetSeconds ?? 0, 20.9, accuracy: 0.001)
    }

    /// The offset of a segment that starts exactly on a whole second has no fraction.
    func testDecodingWholeSecondDurations() {
        XCTAssertEqual(LiveProtocol.seconds(fromDuration: "1s") ?? 0, 1, accuracy: 0.001)
        XCTAssertNil(LiveProtocol.seconds(fromDuration: nil))
    }

    func testDecodingSessionResumptionUpdate() throws {
        let json = #"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#
        let message = try JSONDecoder().decode(LiveProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.sessionResumptionUpdate?.newHandle, "h-1")
    }

    func testEndpointCarriesTheAPIKey() throws {
        let url = try XCTUnwrap(LiveProtocol.endpoint(apiKey: "test-key"))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertTrue(url.absoluteString.contains("BidiGenerateContent"))
        XCTAssertTrue(url.absoluteString.hasSuffix("key=test-key"))
    }
}
