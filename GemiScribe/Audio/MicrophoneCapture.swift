@preconcurrency import AVFoundation

/// Captures the microphone through `AVCaptureSession`.
///
/// `AVAudioEngine.installTap` is the shorter route but does not reliably fire for
/// Bluetooth inputs on recent macOS releases; the capture-session delegate does.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onSamples: (([Float]) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "jp.namio.GemiScribe.microphone")
    private let sessionQueue = DispatchQueue(label: "jp.namio.GemiScribe.microphone.control")
    private let converter = PCMConverter()
    private var isConfigured = false

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        switch authorizationStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() async throws {
        guard await Self.requestPermission() else { throw AudioCaptureError.microphonePermissionDenied }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AudioCaptureError.noMicrophoneAvailable
        }

        if !isConfigured {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw AudioCaptureError.noMicrophoneAvailable
            }
            session.addInput(input)
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw AudioCaptureError.streamFailed("Could not attach the microphone output.")
            }
            session.addOutput(output)
            session.commitConfiguration()
            isConfigured = true
        }

        // startRunning() blocks until the device is live; keep it off the caller's thread.
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let samples = converter.convert(sampleBuffer), !samples.isEmpty else { return }
        onSamples?(samples)
    }
}
