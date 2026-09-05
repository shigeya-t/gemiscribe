import AVFoundation

/// The single format everything downstream of the mixer speaks:
/// what the Gemini Live API requires — raw 16-bit PCM, 16 kHz, mono, little-endian.
enum AudioFormatSpec {
    static let sampleRate: Double = 16_000
    /// The API guidance is to send roughly 100 ms per chunk.
    static let frameDurationSec: Double = 0.1
    static let framesPerChunk = Int(sampleRate * frameDurationSec) // 1600

    static let mono16k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    /// `audio/pcm;rate=16000`
    static let mimeType = "audio/pcm;rate=\(Int(sampleRate))"
}

enum AudioCaptureError: LocalizedError {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case noDisplayAvailable
    case noMicrophoneAvailable
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required to capture system audio."
        case .microphonePermissionDenied:
            return "Microphone access was denied."
        case .noDisplayAvailable:
            return "No display is available to attach the audio capture to."
        case .noMicrophoneAvailable:
            return "No audio input device was found."
        case .streamFailed(let message):
            return message
        }
    }
}
