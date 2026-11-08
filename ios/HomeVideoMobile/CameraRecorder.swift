import AVFoundation
import CoreMedia
import CoreVideo
import Metal

/// Writes the camera screen's processed picture and processed sound straight into the export's
/// format while recording: an `AVAssetWriter` in real time mode with the export sheet's codec,
/// quality and size (`ExportSettings.videoSettings`, the same settings the `Exporter` writes)
/// and AAC 48 kHz stereo sound (`AudioExport.encodeSettings`). Every writer call runs on one
/// serial queue, so nothing here needs a lock. Frames the writer is not ready for are dropped
/// and counted rather than queued, so a slow encoder never backs up the live picture.
final class CameraRecorder: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "homevideo.camera.writer", qos: .userInitiated)
    private let output: SignalChain.Output
    /// The sound through the chain's audio, nil when the Track is Off (the sound is then
    /// encoded untouched).
    private let processor: AudioChainProcessor?

    // Writer queue only.
    private var started = false
    private var finishing = false
    private var startTime = CMTime.invalid
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var audioFrames: Int64 = 0
    private(set) var videoFramesWritten = 0
    private(set) var videoFramesDropped = 0

    static let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioExport.sampleRate,
                                           channels: AVAudioChannelCount(AudioExport.channels), interleaved: false)!

    init(url: URL, settings: ExportSettings, output: SignalChain.Output, size: (width: Int, height: Int),
         picked: Bool, audio: AudioChainSpec?, withSound: Bool) throws {
        self.url = url
        self.output = output
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: settings.fileType)
        videoInput = AVAssetWriterInput(mediaType: .video,
                                        outputSettings: settings.videoSettings(for: output, size: size, picked: picked))
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ExportError.writer("cannot add the video input") }
        writer.add(videoInput)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: ExportPixelFormat.yuv422.cvFormat,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        if withSound {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioExport.encodeSettings)
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a)
                audioInput = a
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }
        processor = audio.map { AudioChainProcessor(spec: $0, sampleRate: AudioExport.sampleRate,
                                                    channels: AudioExport.channels) }
        guard writer.startWriting() else {
            throw ExportError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
    }

    /// One converted frame: the converter's bytes copied into a writer buffer, tagged as the
    /// export tags them, and appended at `time`. The first frame starts the file's clock.
    /// `done` runs on the writer queue once the bytes are read, so the converter can be reused.
    func appendVideo(bytes: Unchecked<MTLBuffer>, bytesPerRow: Int, rows: Int, at time: CMTime,
                     done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            defer { done() }
            guard !finishing, writer.status == .writing else { return }
            if !started {
                writer.startSession(atSourceTime: time)
                startTime = time
                started = true
            }
            guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
                videoFramesDropped += 1
                return
            }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else {
                videoFramesDropped += 1
                return
            }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let stride = CVPixelBufferGetBytesPerRow(pb)
                let n = min(bytesPerRow, stride)
                let src = bytes.value.contents()
                for y in 0..<min(rows, CVPixelBufferGetHeight(pb)) {
                    memcpy(base + y * stride, src + y * bytesPerRow, n)
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            Self.tag(pb, output: output)
            if adaptor.append(pb, withPresentationTime: time) {
                videoFramesWritten += 1
            } else {
                videoFramesDropped += 1
            }
        }
    }

    /// One buffer of microphone sound: converted to 48 kHz stereo Float32, run through the
    /// chain's audio, and appended. Sound from before the first frame is left out.
    func appendAudio(_ sample: CMSampleBuffer) {
        let box = Unchecked(value: sample)
        queue.async { [self] in
            guard let audioInput, started, !finishing, writer.status == .writing else { return }
            let sample = box.value
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts >= startTime, let out = convert(sample) else { return }
            if let processor {
                let channels = (0..<Int(out.format.channelCount)).compactMap { out.floatChannelData?[$0] }
                processor.process(AudioBlock(channels: channels, frames: Int(out.frameLength)))
            }
            // The first buffer sets the sound's clock, later ones follow by sample count, so the
            // resampler's own timing never leaves a gap or an overlap.
            if audioFrames == 0 { audioFrames = Int64((pts - startTime).seconds * AudioExport.sampleRate) }
            let time = CMTimeAdd(startTime, CMTime(value: audioFrames, timescale: CMTimeScale(AudioExport.sampleRate)))
            audioFrames += Int64(out.frameLength)
            guard audioInput.isReadyForMoreMediaData, let s = Self.sampleBuffer(out, at: time) else { return }
            audioInput.append(s)
        }
    }

    /// Ends the file. Returns the frames written and dropped, or throws the writer's error.
    func finish() async throws -> (written: Int, dropped: Int) {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<(written: Int, dropped: Int), Error>) in
            queue.async { [self] in
                finishing = true
                guard started else {
                    writer.cancelWriting()
                    c.resume(throwing: ExportError.writer("no frames were recorded"))
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                let w = Unchecked(value: writer)
                let counts = (videoFramesWritten, videoFramesDropped)
                writer.finishWriting {
                    if w.value.status == .completed {
                        c.resume(returning: counts)
                    } else {
                        c.resume(throwing: ExportError.writer(w.value.error?.localizedDescription ?? "status \(w.value.status.rawValue)"))
                    }
                }
            }
        }
    }

    /// Stops without a file.
    func cancel() {
        queue.async { [self] in
            finishing = true
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The export's tags (`Exporter.tag` and `Exporter.tagScan`, which are main actor and so
    /// cannot run on the writer queue): 709 throughout for the HD pictures, else SMPTE-C
    /// primaries, 709 transfer, 601 matrix, with 10:11 pixels for the raster.
    static func tag(_ pb: CVPixelBuffer, output: SignalChain.Output) {
        let hd = output.isHD
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                              hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                              hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                              .shouldPropagate)
        guard !hd else { return }
        let square = output.isSquare
        let par: [String: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: square ? 1 : 10,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: square ? 1 : 11,
        ]
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, par as CFDictionary, .shouldPropagate)
    }

    // MARK: Sound

    /// The microphone's buffer at the recorder's rate and layout. A mono microphone is heard on
    /// both channels.
    private func convert(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let inFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }
        if converterInput != inFormat {
            converter = AVAudioConverter(from: inFormat, to: Self.audioFormat)
            if inFormat.channelCount == 1 { converter?.channelMap = [0, 0] }
            converterInput = inFormat
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let converter, frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: input.mutableAudioBufferList) == noErr else { return nil }
        let ratio = Self.audioFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.audioFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return input
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// A Core Media sample buffer over `buffer`'s planar floats, stamped at `time`.
    static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: buffer.format.formatDescription,
                                   sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sample
    }
}
