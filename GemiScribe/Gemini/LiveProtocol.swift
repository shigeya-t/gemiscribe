import Foundation

/// Wire types for `BidiGenerateContent` over WebSockets.
/// Decoding is deliberately all-optional: the server adds message kinds over time and
/// an unknown field must never take down a live recording.
enum LiveProtocol {

    // MARK: - Client → server

    struct SetupMessage: Encodable {
        let setup: Setup
    }

    struct Setup: Encodable {
        let model: String
        let generationConfig: GenerationConfig
        let inputAudioTranscription: InputAudioTranscription
        let sessionResumption: SessionResumption?
    }

    struct GenerationConfig: Encodable {
        let responseModalities: [String]
    }

    /// `mode` is what the Smart Transcribe toggle drives:
    /// VERBATIM keeps every "um", SMART cleans and formats the text.
    struct InputAudioTranscription: Encodable {
        let languageCodes: [String]
        let customVocabulary: [String]
        let mode: String

        static let verbatim = "VERBATIM"
        static let smart = "SMART"
    }

    struct SessionResumption: Encodable {
        let handle: String?
    }

    struct RealtimeInputMessage: Encodable {
        let realtimeInput: RealtimeInput
    }

    struct RealtimeInput: Encodable {
        var audio: Blob?
        var audioStreamEnd: Bool?
    }

    struct Blob: Encodable {
        let data: String // base64
        let mimeType: String
    }

    // MARK: - Server → client

    struct ServerMessage: Decodable {
        var setupComplete: SetupComplete?
        var serverContent: ServerContent?
        var goAway: GoAway?
        var sessionResumptionUpdate: SessionResumptionUpdate?
        /// The server's own VAD reporting where in the audio a segment began or ended.
        var voiceActivity: VoiceActivity?
    }

    /// `audioOffset` is measured from the first byte of audio sent on *this* connection,
    /// so it resets to zero every time the socket is replaced.
    struct VoiceActivity: Decodable {
        var type: String?
        var audioOffset: String?

        static let start = "ACTIVITY_START"
        static let end = "ACTIVITY_END"

        var audioOffsetSeconds: Double? { LiveProtocol.seconds(fromDuration: audioOffset) }
    }

    struct SetupComplete: Decodable {}

    struct ServerContent: Decodable {
        /// Finalized transcript for a turn; this is what becomes a block.
        var inputTranscription: Transcription?
        /// Low-latency partial hypothesis while the speaker is still talking.
        var interimInputTranscription: Transcription?
    }

    struct Transcription: Decodable {
        var text: String?
        var languageCode: String?
    }

    struct GoAway: Decodable {
        /// protobuf Duration, serialized as e.g. "12.5s".
        var timeLeft: String?

        var timeLeftSeconds: Double? { LiveProtocol.seconds(fromDuration: timeLeft) }
    }

    /// protobuf Duration JSON form: a decimal number of seconds with an `s` suffix.
    static func seconds(fromDuration text: String?) -> Double? {
        guard let text else { return nil }
        return Double(text.hasSuffix("s") ? String(text.dropLast()) : text)
    }

    struct SessionResumptionUpdate: Decodable {
        var newHandle: String?
    }

    /// Slash escaping is legal JSON but turns `models/x` into `models\/x` in the debug
    /// log, which reads like a bug every time someone looks at it.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    // MARK: - Endpoint

    static func endpoint(apiKey: String) -> URL? {
        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components?.url
    }

    /// The API expects the fully qualified resource name.
    static func qualified(model: String) -> String {
        model.hasPrefix("models/") ? model : "models/\(model)"
    }
}
