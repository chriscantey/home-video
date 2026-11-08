import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// What an export produced.
public struct ExportResult: Sendable {
    public var framesWritten: Int
    /// True when an audio track was written (copied, or processed).
    public var audioPassedThrough: Bool
    /// The audio preset the written track went through; nil when it was copied untouched
    /// (Off) or there was no audio.
    public var audioProcessed: AudioPreset?
    public var pixelFormat: ExportPixelFormat
    public var sourceRotationDegrees: Int
}

public enum ExportError: Error, CustomStringConvertible {
    case noVideoTrack
    case noMetal(String)
    case reader(String)
    case writer(String)
    case gpu(String)
    case cancelled

    public var description: String {
        switch self {
        case .noVideoTrack: return "the source has no video track"
        case .noMetal(let s): return "Metal: \(s)"
        case .reader(let s): return "reading the source failed: \(s)"
        case .writer(let s): return "writing the movie failed: \(s)"
        case .gpu(let s): return "GPU frame failed: \(s)"
        case .cancelled: return "export cancelled"
        }
    }
}

/// A flag shared with the reader, writer and audio queues.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Carries a non-Sendable AVFoundation or Core Video object across a queue hop. Only one
/// side touches the object at a time (the hop is awaited), so the crossing is safe.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

/// Renders a movie through a `SignalChain` and writes the 720 by 480 result in the codec and
/// container `settings` name: source frame times,
/// pixel aspect 10:11 with a 704 by 480 clean aperture
/// (shown 4:3), tagged SMPTE-C primaries, 709 transfer, 601 matrix. The first audio track
/// runs through the chain's audio (decoded to Float32, AAC 48 kHz stereo out); when the audio
/// preset is Off it is copied through untouched.
///
/// The chain runs on the main actor (layers are main actor types). Sample reads and writer
/// appends hop to a serial queue, audio pumps on its own queue, and the GPU does the pixels,
/// so the main thread only encodes command buffers between awaits.
///
/// The chain's intermediates are shared with the preview: while an export runs, the preview
/// must not draw (`PreviewRenderer.isSuspended`).
@MainActor
public final class Exporter {
    /// The master export's container (ProRes 422 .mov), what `homevideo-render` writes by default.
    public static let fileType: AVFileType = ExportSettings.master.fileType

    public let sourceURL: URL
    public let destinationURL: URL
    public let chain: SignalChain
    public var maxFrames: Int?
    /// The clip's trim: only this range is read and written, and the written movie
    /// starts at time zero. `maxFrames` then counts from the in point.
    public var trim: TrimRange?
    public var pixelFormat: ExportPixelFormat
    /// Codec, quality and container.
    public var settings: ExportSettings
    /// Where each run writes its start, progress, done, cancel and failure lines. Nil logs nothing.
    public var log: ExportLog? = .shared
    /// Called on the main actor with 0...1 after each frame.
    public var onProgress: ((Double) -> Void)?

    private let device: MTLDevice?
    private let cancelFlag = CancelFlag()
    private let ioQueue = DispatchQueue(label: "homevideo.export.io")
    private let audioQueue = DispatchQueue(label: "homevideo.export.audio")

    public init(source: URL, destination: URL, chain: SignalChain, device: MTLDevice? = nil,
                maxFrames: Int? = nil, pixelFormat: ExportPixelFormat = .yuv422,
                settings: ExportSettings = .default) {
        self.sourceURL = source
        self.destinationURL = destination
        self.chain = chain
        self.device = device ?? MTLCreateSystemDefaultDevice()
        self.maxFrames = maxFrames
        self.pixelFormat = pixelFormat
        self.settings = settings.normalized
    }

    /// Stops the export at the next frame; `run()` then throws `.cancelled` and removes the
    /// partial file.
    public func cancel() { cancelFlag.set() }

    public var isCancelled: Bool { cancelFlag.isSet }

    // MARK: Settings

    public static let colorProperties: [String: Any] = ExportSettings.colorProperties

    /// The master export's video settings (ProRes 422), the measurement path's default.
    public static var videoSettings: [String: Any] { ExportSettings.master.videoSettings }

    /// Tags one Film Scan buffer: 709 primaries, transfer and matrix, square pixels.
    public static func tagScan(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              .shouldPropagate)
    }

    /// Tags one output buffer with the export's color and aspect attachments.
    public static func tag(_ pb: CVPixelBuffer, squarePixels: Bool = false) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                              .shouldPropagate)
        let par: [String: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: squarePixels ? 1 : 10,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: squarePixels ? 1 : 11,
        ]
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, par as CFDictionary, .shouldPropagate)
    }

    /// Clockwise rotation in degrees (0, 90, 180, 270) a track's preferred transform applies.
    public nonisolated static func rotationDegrees(of t: CGAffineTransform) -> Int {
        let deg = Int((atan2(Double(t.b), Double(t.a)) * 180 / .pi).rounded())
        return ((deg % 360) + 360) % 360
    }

    /// Picks the audio track to pass through: the first AAC track, else the first audio track
    /// at all. Other audio (an iPhone's spatial `apac` track) and metadata tracks are ignored.
    nonisolated static func pickAudioTrack(_ tracks: [AVAssetTrack]) async -> AVAssetTrack? {
        for t in tracks {
            if let f = try? await t.load(.formatDescriptions).first,
               CMFormatDescriptionGetMediaSubType(f) == kAudioFormatMPEG4AAC {
                return t
            }
        }
        return tracks.first
    }

    // MARK: Run

    public func run() async throws -> ExportResult {
        let started = Date()
        let clip = sourceURL.lastPathComponent
        log?.write("start", [("clip", clip), ("to", destinationURL.path), ("codec", settings.codec.rawValue),
                             ("quality", settings.codec.hasQuality ? settings.quality.rawValue : "none"),
                             ("container", settings.container.rawValue),
                             ("audio", chain.audio.preset.rawValue), ("range", logRange)])
        // Progress in the log every 10 percent, around the caller's own handler.
        let callerProgress = onProgress
        var loggedTenth = 0
        onProgress = { [log] p in
            let tenth = Int(p * 10)
            if tenth > loggedTenth && tenth < 10 {
                loggedTenth = tenth
                log?.write("progress", [("clip", clip), ("percent", "\(tenth * 10)")])
            }
            callerProgress?(p)
        }
        defer { onProgress = callerProgress }
        do {
            let r = try await runUnchecked()
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int) ?? 0
            log?.write("done", [("clip", clip), ("frames", "\(r.framesWritten)"), ("bytes", "\(bytes)"),
                                ("seconds", String(format: "%.1f", Date().timeIntervalSince(started))),
                                ("file", destinationURL.lastPathComponent)])
            return r
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if isCancelled {
                log?.write("cancel", [("clip", clip), ("partial", "removed")])
                throw ExportError.cancelled
            }
            log?.write("fail", [("clip", clip), ("error", "\(error)")])
            throw error
        }
    }

    /// The part of the clip the run covers, for the log: the whole clip, or its first N frames.
    var logRange: String { maxFrames.map { "first \($0) frames" } ?? "all" }

    private func runUnchecked() async throws -> ExportResult {
        guard let device, let queue = device.makeCommandQueue() else {
            throw ExportError.noMetal("no Metal device")
        }
        let (library, _) = try ShaderLibrary.make(device: device)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let textureCache = cache else { throw ExportError.noMetal("no texture cache") }

        // Source.
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let (nominalRate, minFrameDuration, transform, timeScale, naturalSize) = try await videoTrack.load(
            .nominalFrameRate, .minFrameDuration, .preferredTransform, .naturalTimeScale, .naturalSize)
        let duration = try await asset.load(.duration)
        let audioTrack = await Exporter.pickAudioTrack(try await asset.loadTracks(withMediaType: .audio))
        let audioHint = try await audioTrack?.load(.formatDescriptions).first

        // The preview sets framing rotation from the same transform; match it.
        let rotation = Exporter.rotationDegrees(of: transform)
        applyRotation(rotation)

        // The file is what the last stage gives (`SignalChain.Output`): the 720 by 480 raster
        // (the tape, or a Telecine transfer with the tape off), the Display canvas or the
        // camera's frame (square pixels, the raster's tags), or the Film's Scan or the source
        // untouched (square pixels in 709).
        let shown = FramingMath.displaySize(naturalSize, rotation: rotation)
        chain.sourceSize = (Int(shown.width.rounded()), Int(shown.height.rounded()))
        let output = chain.output
        let outSize = chain.outputSize
        let converter = try RasterConverter(device: device, library: library, format: pixelFormat,
                                            matrix: output.isHD ? .bt709 : .bt601,
                                            width: outSize.width, height: outSize.height)

        let reader = try AVAssetReader(asset: asset)
        var frameDuration = minFrameDuration
        if !frameDuration.isValid || frameDuration.seconds <= 0 {
            frameDuration = CMTime(value: 1001, timescale: CMTimeScale(max(1, (nominalRate * 1001).rounded())))
        }
        // The range read: the trim (clamped to the clip), then at most `maxFrames` from its start.
        let range = trim?.clamped(to: duration.seconds)
        let start = range.map { CMTime(seconds: $0.inPoint, preferredTimescale: max(timeScale, 600)) } ?? .zero
        var length = range.map { CMTime(seconds: $0.length, preferredTimescale: max(timeScale, 600)) } ?? duration
        if let maxFrames {
            length = CMTimeMinimum(length, CMTimeMultiply(frameDuration, multiplier: Int32(maxFrames)))
        }
        if range != nil || maxFrames != nil {
            reader.timeRange = CMTimeRange(start: start, duration: length)
        }
        var totalFrames = max(1, Int((length.seconds / max(frameDuration.seconds, 1e-6)).rounded()))
        if let maxFrames { totalFrames = min(totalFrames, maxFrames) }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.reader("cannot add video output") }
        reader.add(videoOutput)

        // Off (or every audio layer off) keeps the untouched copy; otherwise decode and process.
        let audioSpec: AudioChainSpec? = chain.audio.isPassthrough ? nil : chain.audio.spec
        let audioPreset = chain.audio.preset
        // An MPEG-4 file takes no Linear PCM or Apple Lossless track: the writer accepts the copy
        // and writes a silent file. So a passthrough into .mp4 of anything
        // but AAC decodes to PCM and encodes to AAC, untouched otherwise, with no chain in between.
        let sourceIsAAC = audioHint.map { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC } ?? true
        let transcodeCopy = audioSpec == nil && settings.container == .mp4 && !sourceIsAAC
        let copiesUntouched = audioSpec == nil && !transcodeCopy
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack,
                                               outputSettings: copiesUntouched ? nil : AudioExport.decodeSettings)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        // Destination.
        try? FileManager.default.removeItem(at: destinationURL)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: settings.fileType)
        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: settings.videoSettings(
                                                for: output, size: outSize, picked: !(chain.vhs?.output.isAuto ?? true)))
        videoInput.expectsMediaDataInRealTime = false
        // Keep the source's track timescale; the default (600) cannot hold 1001/30000 frame
        // times exactly and the frame durations would wobble.
        if timeScale > 0 {
            videoInput.mediaTimeScale = timeScale
            writer.movieTimeScale = timeScale
        }
        guard writer.canAdd(videoInput) else {
            throw ExportError.writer("cannot add the \(settings.codec.name) video input")
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat.cvFormat,
            kCVPixelBufferWidthKey as String: outSize.width,
            kCVPixelBufferHeightKey as String: outSize.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = copiesUntouched
                ? AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioHint)
                : AVAssetWriterInput(mediaType: .audio, outputSettings: AudioExport.encodeSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioOutput = nil
            }
        }

        guard reader.startReading() else {
            throw ExportError.reader(reader.error?.localizedDescription ?? "startReading failed")
        }
        guard writer.startWriting() else {
            throw ExportError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }

        var audioDone: DispatchGroup?
        var written = 0
        var sessionStarted = false
        // A trimmed export moves every time back by the first frame's, so it starts at zero.
        // Without a trim the source times are written as they are.
        var offset = CMTime.zero
        let rasterSize = CGSize(width: SignalChain.rasterWidth, height: SignalChain.rasterHeight)
        // Frame 0 must not see the preview's last frame (L9 temporal fields).
        chain.reset()
        // The export is the tape playing, whatever the preview's transport says.
        for case let osd as OSDLayer in chain.layers { osd.paused = false }

        // A trimmed read hands back the frame already on screen at the in point, stamped at the
        // in point, so it can last only a sliver before the next real frame (3 ms on one clip
        // trimmed at 5 s). A first frame shorter than half a frame is dropped.
        var queued: [CMSampleBuffer] = []
        if range != nil, let a = await nextSample(videoOutput) {
            queued.append(a)
            if let b = await nextSample(videoOutput) {
                let gap = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(b),
                                         CMSampleBufferGetPresentationTimeStamp(a))
                if gap.isValid, gap.seconds < frameDuration.seconds / 2 { queued.removeAll() }
                queued.append(b)
            }
        }

        while !isCancelled {
            let next = queued.isEmpty ? await nextSample(videoOutput) : queued.removeFirst()
            guard let sample = next else { break }
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            if !sessionStarted {
                if range != nil { offset = pts }
                writer.startSession(atSourceTime: CMTimeSubtract(pts, offset))
                sessionStarted = true
                if let audioOutput, let audioInput {
                    if let audioSpec {
                        audioDone = AudioExport.pump(from: audioOutput, to: audioInput, spec: audioSpec,
                                                     on: audioQueue, cancel: cancelFlag, offset: offset)
                    } else {
                        audioDone = Exporter.pumpAudio(from: audioOutput, to: audioInput, on: audioQueue,
                                                       cancel: cancelFlag, offset: offset)
                    }
                }
            }

            // GPU: source texture, chain, conversion into the converter's buffer.
            var cvTex: CVMetalTexture?
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0,
                                                            &cvTex) == kCVReturnSuccess,
                  let cvTex, let srcTex = CVMetalTextureGetTexture(cvTex),
                  let cb = queue.makeCommandBuffer() else {
                throw ExportError.gpu("could not wrap frame \(written)")
            }
            cb.label = "Home Video export frame \(written)"
            let ctx = FrameContext(frameIndex: UInt64(written), time: pts.seconds,
                                   sourceSize: PreviewRenderer.displaySize(of: pb), rasterSize: rasterSize)
            let raster = try chain.encodeOutput(commandBuffer: cb, source: srcTex, frame: ctx,
                                                device: device, library: library)
            converter.encode(commandBuffer: cb, raster: raster)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                cb.addCompletedHandler { _ in c.resume() }
                cb.commit()
            }
            withExtendedLifetime(cvTex) {}
            if let err = cb.error { throw ExportError.gpu(err.localizedDescription) }

            guard let pool = adaptor.pixelBufferPool else {
                throw ExportError.writer(writer.error?.localizedDescription ?? "no pixel buffer pool")
            }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else { throw ExportError.writer("pool gave no buffer") }
            converter.copy(into: outBuffer)
            if output.isHD { Exporter.tagScan(outBuffer) } else { Exporter.tag(outBuffer, squarePixels: output.isSquare) }

            while !videoInput.isReadyForMoreMediaData {
                if isCancelled || writer.status == .failed { break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            if isCancelled { break }
            let ok = await append(adaptor, outBuffer, at: CMTimeSubtract(pts, offset))
            guard ok else {
                throw ExportError.writer(writer.error?.localizedDescription ?? "append failed at frame \(written)")
            }
            written += 1
            onProgress?(min(1, Double(written) / Double(totalFrames)))
            if let maxFrames, written >= maxFrames { break }
        }

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            throw ExportError.reader(reader.error?.localizedDescription ?? "unknown")
        }
        guard written > 0 else { throw ExportError.reader("no video frames decoded") }

        videoInput.markAsFinished()
        if let audioDone {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                audioDone.notify(queue: .main) { c.resume() }
            }
        } else {
            audioInput?.markAsFinished()
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        onProgress?(1)
        return ExportResult(framesWritten: written, audioPassedThrough: audioDone != nil,
                            audioProcessed: audioDone != nil && audioSpec != nil ? audioPreset : nil,
                            pixelFormat: pixelFormat, sourceRotationDegrees: rotation)
    }

    /// Sets the framing layer's rotation, if the framing layer exposes one as a parameter
    /// named `rotation` (degrees as a float, or a choice holding the degree count).
    private func applyRotation(_ degrees: Int) {
        guard let p = chain.framing.parameters.first(where: { $0.id == "rotation" }) else { return }
        switch p.value {
        case .float: chain.framing.setParameter("rotation", to: .float(Double(degrees)))
        case .choice: chain.framing.setParameter("rotation", to: .choice(String(degrees)))
        case .bool: break
        }
    }

    // MARK: Queue hops

    private func nextSample(_ output: AVAssetReaderTrackOutput) async -> CMSampleBuffer? {
        let box = Unchecked(value: output)
        let result: Unchecked<CMSampleBuffer?> = await withCheckedContinuation { c in
            ioQueue.async { c.resume(returning: Unchecked(value: box.value.copyNextSampleBuffer())) }
        }
        return result.value
    }

    private func append(_ adaptor: AVAssetWriterInputPixelBufferAdaptor, _ pb: CVPixelBuffer,
                        at time: CMTime) async -> Bool {
        let box = Unchecked(value: (adaptor, pb))
        return await withCheckedContinuation { c in
            ioQueue.async { c.resume(returning: box.value.0.append(box.value.1, withPresentationTime: time)) }
        }
    }

    /// Copies audio samples untouched from `output` to `input` on `queue` until the source
    /// ends, an append fails, or the export is cancelled. The group leaves when it stops.
    private nonisolated static func pumpAudio(from output: AVAssetReaderTrackOutput, to input: AVAssetWriterInput,
                                              on queue: DispatchQueue, cancel: CancelFlag,
                                              offset: CMTime = .zero) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        let box = Unchecked(value: (output, input))
        let finished = CancelFlag()
        let offsetBox = Unchecked(value: offset)
        input.requestMediaDataWhenReady(on: queue) {
            let (output, input) = box.value
            guard !finished.isSet else { return }
            while input.isReadyForMoreMediaData {
                if cancel.isSet {
                    finished.set()
                    group.leave()
                    return
                }
                guard let read = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    finished.set()
                    group.leave()
                    return
                }
                guard let s = shifted(read, by: offsetBox.value) else { continue }
                guard input.append(s) else {
                    input.markAsFinished()
                    finished.set()
                    group.leave()
                    return
                }
            }
        }
        return group
    }

    /// `sample` with every time moved earlier by `offset`, so a trimmed export starts at zero.
    /// The sample itself when `offset` is zero, nil when the shifted sample ends at or before
    /// zero. One that straddles zero is kept: the writer edits out the part before the session
    /// start (dropping it whole lost 167 ms of decoded audio on one clip).
    nonisolated static func shifted(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset.isValid, offset != .zero else { return sample }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr, count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing,
                                                     entriesNeededOut: &count) == noErr else { return nil }
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid {
                timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            }
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset)
            }
        }
        let length = CMSampleBufferGetDuration(sample)
        if let first = timing.first, first.presentationTimeStamp.isValid, length.isValid,
           CMTimeAdd(first.presentationTimeStamp, length) <= .zero { return nil }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                    sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                                    sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}
