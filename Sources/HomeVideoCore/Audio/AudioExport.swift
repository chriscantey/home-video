import AVFoundation
import CoreMedia
import Foundation

/// The exporter's audio when the chain is not Off: decode the source track to interleaved
/// Float32 at 48 kHz stereo, run an `AudioChainProcessor` on each buffer in order (state
/// carries across buffers), and hand the writer new buffers with the source's timestamps for
/// AAC encoding.
enum AudioExport {
    static let sampleRate = 48_000.0
    static let channels = 2

    static var stereoLayout: Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// What the reader decodes to.
    static var decodeSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: stereoLayout,
        ]
    }

    /// What the writer encodes.
    static var encodeSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 256_000,
            AVChannelLayoutKey: stereoLayout,
        ]
    }

    /// Runs `processor` over one decoded buffer and returns a new buffer with the same format
    /// and timing. Nil when the buffer is not interleaved Float32 or a Core Media call fails.
    static func process(_ sample: CMSampleBuffer, with processor: AudioChainProcessor,
                        scratch: inout [[Float]], time: Double? = nil) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              asbd.mBitsPerChannel == 32,
              let source = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let ch = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard ch > 0, frames > 0 else { return nil }
        let byteCount = frames * ch * MemoryLayout<Float>.size

        var interleaved = [Float](repeating: 0, count: frames * ch)
        let copied = interleaved.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: byteCount, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        // Deinterleave, process planar, interleave back.
        if scratch.count != ch { scratch = Array(repeating: [], count: ch) }
        for c in 0..<ch {
            if scratch[c].count < frames { scratch[c] = [Float](repeating: 0, count: frames) }
            for i in 0..<frames { scratch[c][i] = interleaved[i * ch + c] }
        }
        AudioBlock.withPlanar(&scratch, range: 0..<frames) {
            var block = $0
            block.time = time
            processor.process(block)
        }
        for c in 0..<ch {
            for i in 0..<frames { interleaved[i * ch + c] = scratch[c][i] }
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let replaced = interleaved.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: byteCount)
        }
        guard replaced == kCMBlockBufferNoErr else { return nil }

        var out: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), packetDescriptions: nil,
            sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    /// Like `Exporter.pumpAudio`, but each buffer runs through the chain first. The processor
    /// is built from `spec` on the audio queue once the first buffer gives the channel count.
    static func pump(from output: AVAssetReaderTrackOutput, to input: AVAssetWriterInput, spec: AudioChainSpec,
                     on queue: DispatchQueue, cancel: CancelFlag, offset: CMTime = .zero) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        let box = Unchecked(value: (output, input))
        let finished = CancelFlag()
        let state = PumpState()
        let offsetBox = Unchecked(value: offset)
        input.requestMediaDataWhenReady(on: queue) {
            let (output, input) = box.value
            guard !finished.isSet else { return }
            func stop() {
                input.markAsFinished()
                finished.set()
                group.leave()
            }
            while input.isReadyForMoreMediaData {
                if cancel.isSet {
                    finished.set()
                    group.leave()
                    return
                }
                guard let read = output.copyNextSampleBuffer() else { return stop() }
                // A trimmed export starts at zero: shift the buffer, and skip one that ends before it.
                guard let s = Exporter.shifted(read, by: offsetBox.value) else { continue }
                if state.processor == nil {
                    let fmt = CMSampleBufferGetFormatDescription(s)
                        .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                    state.processor = AudioChainProcessor(spec: spec, sampleRate: fmt?.mSampleRate ?? sampleRate,
                                                          channels: Int(fmt?.mChannelsPerFrame ?? UInt32(channels)))
                }
                // The clip's own time, before the trim's shift (`AudioBlock.time`).
                let pts = CMSampleBufferGetPresentationTimeStamp(read)
                guard let processed = process(s, with: state.processor!, scratch: &state.scratch,
                                              time: pts.isNumeric ? pts.seconds : nil),
                      input.append(processed) else { return stop() }
            }
        }
        return group
    }

    /// The pump's state, touched only on its serial queue.
    final class PumpState: @unchecked Sendable {
        var processor: AudioChainProcessor?
        var scratch: [[Float]] = []
    }
}
