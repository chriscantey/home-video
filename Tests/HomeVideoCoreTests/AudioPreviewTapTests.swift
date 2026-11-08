import AVFoundation
import XCTest
@testable import HomeVideoCore

/// The preview tap's own processing, driven the way the player drives it (prepare with the
/// stream format, then one render call per buffer), with no player in between. Off is the
/// source untouched, EP Linear cuts a 6 kHz tone and keeps a 1 kHz one, and a preset changed
/// through the feed between two render calls is heard on the second.
extension AudioTests {
    /// A tap context registered with `feed` and prepared at 48 kHz stereo Float32, planar or
    /// interleaved, as the player prepares it.
    func preparedTap(_ feed: AudioPreviewFeed, interleaved: Bool = false) -> AudioTapContext {
        let tap = AudioTapContext(feed: feed)
        feed.register(tap)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 2,
                                   interleaved: interleaved)!
        tap.prepare(format.streamDescription.pointee)
        return tap
    }

    /// Runs planar `input` through the tap in 512 frame render calls, returning the output.
    /// `between` runs after the block that starts at frame `at`.
    func renderTap(_ tap: AudioTapContext, _ input: [[Float]], interleaved: Bool = false,
                   at: Int = -1, between: () -> Void = {}) -> [[Float]] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 2,
                                   interleaved: interleaved)!
        let n = input[0].count
        var out: [[Float]] = [[Float](repeating: 0, count: n), [Float](repeating: 0, count: n)]
        var start = 0
        while start < n {
            let count = min(512, n - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = AVAudioFrameCount(count)
            let data = buffer.floatChannelData!
            for c in 0..<2 {
                for i in 0..<count {
                    if interleaved { data[0][i * 2 + c] = input[c][start + i] } else { data[c][i] = input[c][start + i] }
                }
            }
            tap.process(buffer.mutableAudioBufferList, frames: CMItemCount(count))
            for c in 0..<2 {
                for i in 0..<count { out[c][start + i] = interleaved ? data[0][i * 2 + c] : data[c][i] }
            }
            if start == at { between() }
            start += count
        }
        return out
    }

    func noise(seconds: Double) -> [[Float]] {
        var rng = SplitMix64(seed: 0x7A9)
        let n = Int(seconds * Self.rate)
        return (0..<2).map { _ in (0..<n).map { _ in Float(rng.unit() - 0.5) * 0.5 } }
    }

    func testOffTapIsIdentityPlanarAndInterleaved() {
        let input = noise(seconds: 0.5)
        for interleaved in [false, true] {
            let feed = AudioPreviewFeed(spec: AudioChain(preset: .off).spec)
            let tap = preparedTap(feed, interleaved: interleaved)
            XCTAssertEqual(renderTap(tap, input, interleaved: interleaved), input, "interleaved \(interleaved)")
        }
    }

    /// EP Linear: a 6 kHz 4th order lowpass under a -3 dB azimuth shelf, so the whole response
    /// is -3 dB near 4 kHz and about -6 dB at 6 kHz, not 20 dB down there. 20 dB down is reached
    /// near 10 kHz, so 12 kHz carries that check.
    func testEPLinearTapKeeps1kRollsOff6kAndCuts12k() {
        let feed = AudioPreviewFeed(spec: AudioChain(preset: .epLinear).spec)
        let tail = 24_000..<48_000
        func gain(_ hz: Double) -> Double {
            let out = renderTap(preparedTap(feed), sine(hz, amplitude: 0.25, seconds: 1))
            return dB(bandAmplitude(out[0][tail], hz: hz) / 0.25)
        }
        let g1 = gain(1_000), g6 = gain(6_000), g12 = gain(12_000)
        print("EP Linear tap: 1 kHz \(g1) dB, 6 kHz \(g6) dB, 12 kHz \(g12) dB")
        XCTAssertEqual(g1, 0, accuracy: 1, "1 kHz through the EP Linear tap")
        XCTAssertTrue((-9.0 ... -4.0).contains(g6), "6 kHz through the EP Linear tap: \(g6) dB")
        XCTAssertLessThan(g12, -20, "12 kHz through the EP Linear tap")
    }

    /// The sidebar's preset change goes AudioChain.onChange, feed.update, the tap's pending
    /// processor, and is swapped in at the next render call, with no clip reopen.
    func testPresetChangeTakesEffectOnTheNextRenderCall() {
        let tone = sine(12_000, amplitude: 0.25, seconds: 1)
        let feed = AudioPreviewFeed(spec: AudioChain(preset: .off).spec)
        let tap = preparedTap(feed)
        // Off for the first half second, EP Linear from the next call on.
        let switchAt = 23_552
        let out = renderTap(tap, tone, at: switchAt) { feed.update(AudioChain(preset: .epLinear).spec) }
        let before = 0..<(switchAt + 512)
        XCTAssertEqual(Array(out[0][before]), Array(tone[0][before]), "Off before the change")
        XCTAssertNotEqual(out[0][switchAt + 512], tone[0][switchAt + 512], "the call after the change is processed")
        let after = dB(bandAmplitude(out[0][36_000..<48_000], hz: 12_000) / 0.25)
        XCTAssertLessThan(after, -20, "12 kHz after the change to EP Linear")

        // And back: EP Linear to Off is identity from the next call.
        let back = renderTap(tap, tone, at: 0) { feed.update(AudioChain(preset: .off).spec) }
        XCTAssertEqual(Array(back[0][512...]), Array(tone[0][512...]), "Off after the change back")
    }
}
