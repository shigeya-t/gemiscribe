import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Captures everything the Mac is playing, via ScreenCaptureKit.
///
/// SCK has no audio-only mode: a stream must be attached to displayed content. The
/// configuration below asks for a 2×2 pixel frame at 1 fps so the video path costs
/// essentially nothing, and only the `.audio` output is consumed.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSamples: (([Float]) -> Void)?
    var onStreamError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "jp.namio.GemiScribe.systemAudio")
    private let converter = PCMConverter()
    private var stream: SCStream?

    /// Triggers the system prompt the first time; afterwards the user must grant it
    /// in System Settings, so callers surface `errorScreenPermission` when this is false.
    @discardableResult
    static func requestPermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    func start() async throws {
        guard Self.requestPermission() else { throw AudioCaptureError.screenRecordingPermissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            // SCK reports a missing TCC grant as a generic stream error.
            throw AudioCaptureError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplayAvailable }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 6
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            // A screen output is added and ignored: some macOS releases refuse to start
            // a stream that has no video consumer.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw AudioCaptureError.streamFailed(error.localizedDescription)
        }
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let samples = converter.convert(sampleBuffer), !samples.isEmpty else { return }
        onSamples?(samples)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStreamError?(error)
    }
}
