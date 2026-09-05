import AVFoundation

/// Converts a `CMSampleBuffer` from any capture source into 16 kHz mono Float32.
///
/// ScreenCaptureKit hands us 48 kHz stereo and the microphone whatever the device
/// runs at, so both resampling and down-mixing happen here. One instance per source;
/// it is not thread-safe but each source drives it from its own serial queue.
final class PCMConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        var asbd = asbdPointer.pointee
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        if inputFormat != sourceFormat || converter == nil {
            converter = AVAudioConverter(from: sourceFormat, to: AudioFormatSpec.mono16k)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputFormat = sourceFormat
        }
        guard let converter else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                           frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        input.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: input.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let ratio = AudioFormatSpec.sampleRate / sourceFormat.sampleRate
        // +16 frames of slack: the resampler can emit slightly more than the ratio suggests.
        let outputCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioFormatSpec.mono16k,
                                            frameCapacity: outputCapacity)
        else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, conversionError == nil,
              let channel = output.floatChannelData?[0], output.frameLength > 0
        else { return nil }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
