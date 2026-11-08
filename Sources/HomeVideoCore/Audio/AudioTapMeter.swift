import AVFoundation
import os

/// Live readings from the preview's tap for a diagnostics panel (the phone's "Audio
/// diagnostics"): the format the tap was prepared with, the frames it has seen, any failure to
/// get the source audio, and the rolling RMS of what it receives and what it hands back.
/// Off unless an `AudioPreviewFeed` is made with one. The render thread holds the lock for a
/// few stores per buffer, never across any work.
public final class AudioTapMeter: @unchecked Sendable {
    public struct Reading: Sendable, Equatable {
        public var prepared = false
        public var sampleRate: Double = 0
        public var channels = 0
        /// Float32 linear PCM, the only format the chain processes. Anything else passes untouched.
        public var float32 = false
        public var interleaved = false
        public var framesSeen = 0
        /// Buffers whose source audio could not be read, and the last status.
        public var sourceErrors = 0
        public var lastError: Int32 = 0
        /// Rolling mean square over about a third of a second, all channels together.
        public var inMeanSquare: Float = 0
        public var outMeanSquare: Float = 0

        public static func dBFS(_ meanSquare: Float) -> Float {
            meanSquare > 1e-12 ? 10 * log10(meanSquare) : -120
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: Reading())

    public init() {}

    public var reading: Reading { state.withLock { $0 } }

    func prepare(sampleRate: Double, channels: Int, float32: Bool, interleaved: Bool) {
        state.withLock {
            $0 = Reading(prepared: true, sampleRate: sampleRate, channels: channels, float32: float32,
                         interleaved: interleaved, sourceErrors: $0.sourceErrors, lastError: $0.lastError)
        }
    }

    func unprepare() {
        state.withLock { $0.prepared = false }
    }

    func sourceError(_ status: OSStatus) {
        state.withLock {
            $0.sourceErrors += 1
            $0.lastError = status
        }
    }

    /// The buffer's mean square, every Float32 sample of every buffer in the list.
    static func meanSquare(_ list: UnsafeMutablePointer<AudioBufferList>) -> (Float, Int) {
        var sum: Float = 0
        var count = 0
        for b in UnsafeMutableAudioBufferListPointer(list) {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(b.mDataByteSize) / 4
            for i in 0..<n { sum += d[i] * d[i] }
            count += n
        }
        return (count > 0 ? sum / Float(count) : 0, count)
    }

    func record(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, output: Bool) {
        let (ms, n) = Self.meanSquare(list)
        guard n > 0 else { return }
        state.withLock {
            // One pole, weighted by the buffer's share of about a third of a second.
            let rate = $0.sampleRate > 0 ? $0.sampleRate : 48_000
            let w = Float(min(1, Double(frames) / (rate / 3)))
            if output {
                $0.outMeanSquare += w * (ms - $0.outMeanSquare)
                $0.framesSeen += frames
            } else {
                $0.inMeanSquare += w * (ms - $0.inMeanSquare)
            }
        }
    }
}
