import AVFoundation
import XCTest
@testable import HomeVideoCore

/// The audio chain against published VHS audio figures: the Linear SP band edge, the Hi-Fi
/// compander round trip, the hiss level, and Off as a passthrough. Plain CPU, no AVFoundation.
@MainActor
final class AudioTests: XCTestCase {
    static let rate = 48_000.0

    func sine(_ hz: Double, amplitude: Double, seconds: Double, channels: Int = 2) -> [[Float]] {
        let n = Int(seconds * Self.rate)
        let mono = (0..<n).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / Self.rate)) }
        return Array(repeating: mono, count: channels)
    }

    /// Runs planar buffers through a processor in 512 frame blocks, the way a tap would.
    func run(_ processor: AudioChainProcessor, _ input: [[Float]]) -> [[Float]] {
        var buffers = input
        let n = input[0].count
        var start = 0
        while start < n {
            let count = min(512, n - start)
            AudioBlock.withPlanar(&buffers, range: start..<(start + count)) { processor.process($0) }
            start += count
        }
        return buffers
    }

    /// Amplitude of the energy within `halfWidth` Hz of `hz` (Hann window, summed bins), so a
    /// tone smeared by wow and flutter still counts in full.
    func bandAmplitude(_ x: ArraySlice<Float>, hz: Double, halfWidth: Double = 120) -> Double {
        let n = x.count
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n - 1)) }
        let windowSum = window.reduce(0, +)
        let binHz = Self.rate / Double(n)
        var power = 0.0
        var f = hz - halfWidth
        while f <= hz + halfWidth {
            // Rotate a unit phasor instead of calling cos and sin per sample.
            let w = 2 * Double.pi * f / Self.rate
            let (cw, sw) = (cos(w), -sin(w))
            var (pr, pi) = (1.0, 0.0)
            var re = 0.0, im = 0.0
            for (i, v) in x.enumerated() {
                let s = Double(v) * window[i]
                re += s * pr
                im += s * pi
                (pr, pi) = (pr * cw - pi * sw, pr * sw + pi * cw)
            }
            let a = 2 * (re * re + im * im).squareRoot() / windowSum
            power += a * a
            f += binHz
        }
        // A Hann window spreads one tone's power over bins with a total gain of 1.5.
        return (power / 1.5).squareRoot()
    }

    func dB(_ ratio: Double) -> Double { 20 * log10(ratio) }

    func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    // MARK: Linear SP

    func testLinearSPSweepIsFlatAt1kAndMoreThan20dBDownAt15k() {
        // Stepped sine sweep through the whole Linear SP chain at its defaults (hiss, whine and
        // wow included), measured on the left channel after the filters settle.
        let amp = 0.1
        var gains: [Double: Double] = [:]
        for hz in [1_000.0, 5_000, 15_000] {
            let chain = AudioChain(preset: .linear)
            let processor = chain.makeProcessor(sampleRate: Self.rate, channels: 2)
            let out = run(processor, sine(hz, amplitude: amp, seconds: 0.75))
            // 0.25 s, 4 Hz bins; +-60 Hz holds the 0.2% wobble (+-30 Hz at 15 kHz).
            let tail = out[0][(out[0].count - 12_000)...]
            gains[hz] = dB(bandAmplitude(tail, hz: hz, halfWidth: 60) / amp)
        }
        print("Linear SP gains (dB):", gains.sorted { $0.key < $1.key }.map { "\(Int($0.key)) Hz \($0.value)" })
        XCTAssertLessThan(abs(gains[1_000]!), 1, "1 kHz gain \(gains[1_000]!) dB")
        XCTAssertLessThan(gains[15_000]!, -20, "15 kHz gain \(gains[15_000]!) dB")
        XCTAssertLessThan(gains[15_000]!, gains[5_000]!, "monotone rolloff")
    }

    func testLinearIsMonoOnBothChannels() {
        let chain = AudioChain(preset: .linear)
        let processor = chain.makeProcessor(sampleRate: Self.rate, channels: 2)
        var input = sine(440, amplitude: 0.2, seconds: 0.2)
        input[1] = input[1].map { _ in 0 }
        let out = run(processor, input)
        XCTAssertEqual(out[0], out[1])
        XCTAssertGreaterThan(rms(out[0][...]), 0.05)
    }

    // MARK: Hi-Fi

    func testCompressorThenExpanderReturnsAStepWithinHalfADecibel() {
        // -40 dBFS for 0.5 s, then -10 dBFS for 0.5 s, 1 kHz. The pair alone, tracking error 0.
        let compressor = Compander(mode: .compress, sampleRate: Self.rate, attackMs: 5, releaseMs: 100)
        let expander = Compander(mode: .expand, sampleRate: Self.rate, attackMs: 5, releaseMs: 100)
        let quiet = sine(1_000, amplitude: 0.01, seconds: 0.5, channels: 1)[0]
        let loud = sine(1_000, amplitude: 0.316, seconds: 0.5, channels: 1)[0]
        let input = quiet + loud
        var squeezed = [Float](repeating: 0, count: input.count)
        var output = [Float](repeating: 0, count: input.count)
        for i in input.indices {
            squeezed[i] = compressor.process(input[i])
            output[i] = expander.process(squeezed[i])
        }
        // The compressor really compressed: the 30 dB step is about 15 dB in the middle.
        let midStep = dB(rms(squeezed[30_000..<48_000]) / rms(squeezed[6_000..<24_000]))
        XCTAssertEqual(midStep, 15, accuracy: 1.5)
        // After settling (the last 0.3 s of each level) the step comes back.
        for (range, label) in [(6_000..<24_000, "quiet"), (30_000..<48_000, "loud")] {
            let err = dB(rms(output[range]) / rms(input[range]))
            XCTAssertLessThan(abs(err), 0.5, "\(label) error \(err) dB")
        }
    }

    func testHiFiChainKeepsStereoAndLevel() {
        let chain = AudioChain(preset: .hifi)
        let processor = chain.makeProcessor(sampleRate: Self.rate, channels: 2)
        var input = sine(1_000, amplitude: 0.3, seconds: 0.6)
        input[1] = input[1].map { -$0 * 0.5 }
        let out = run(processor, input)
        let l = rms(out[0][14_400...]), r = rms(out[1][14_400...])
        XCTAssertEqual(dB(l / rms(input[0][14_400...])), 0, accuracy: 1.5)
        XCTAssertEqual(dB(r / rms(input[1][14_400...])), 0, accuracy: 1.5)
    }

    // MARK: Noise

    func testHissRMSMatchesItsSetting() {
        for (color, level) in [(NoiseColor.pink, -42.0), (.white, -48.0), (.pink, -20.0)] {
            let source = NoiseSource(color: color, levelDB: level, seed: 7)
            var sum = 0.0
            let n = 96_000
            for _ in 0..<n { let v = Double(source.next()); sum += v * v }
            let measured = 10 * log10(sum / Double(n))
            XCTAssertEqual(measured, level, accuracy: 0.5, "\(color) at \(level)")
        }
    }

    func testHissLayerAddsItsLevelToSilence() {
        let chain = AudioChain(preset: .linear)
        for layer in chain.layers where layer.id != "audio-hiss" { layer.enabled = false }
        let processor = chain.makeProcessor(sampleRate: Self.rate, channels: 2)
        let out = run(processor, [[Float](repeating: 0, count: 96_000), [Float](repeating: 0, count: 96_000)])
        XCTAssertEqual(dB(rms(out[0][...])), -42, accuracy: 0.5)
    }

    func testHissIsBandLimitedByTheLinearLowpassAndKeepsItsLevel() {
        let chain = AudioChain(preset: .linear)
        for layer in chain.layers { layer.enabled = ["audio-band", "audio-hiss"].contains(layer.id) }
        let processor = chain.makeProcessor(sampleRate: Self.rate, channels: 1)
        let out = run(processor, [[Float](repeating: 0, count: 96_000)])[0]
        XCTAssertEqual(dB(rms(out[4_800...])), -42, accuracy: 0.5)
        // Above 12 kHz the hiss is far below its full band level.
        let hp = butterworth4Q.map { AudioBiquad(.highpass(hz: 12_000, q: $0), sampleRate: Self.rate) }
        let high = out.map { x in hp.reduce(x) { $1.process($0) } }
        XCTAssertLessThan(dB(rms(high[4_800...])), -62)
    }

    // MARK: Off and the chain's shape

    func testOffIsPassthrough() {
        let chain = AudioChain(preset: .off)
        // Off keeps only the camcorder mic layer, off (the mic can play with no track).
        XCTAssertEqual(chain.layers.map(\.id), ["audio-camcorder"])
        XCTAssertFalse(chain.layers[0].enabled)
        XCTAssertTrue(chain.isPassthrough)
        let processor = chain.makeProcessor(sampleRate: Self.rate, channels: 2)
        var input = sine(1_234, amplitude: 0.5, seconds: 0.1)
        input[1] = input[1].map { $0 * -0.25 }
        XCTAssertEqual(run(processor, input), input)
    }

    func testAllLayersOffIsPassthroughToo() {
        let chain = AudioChain(preset: .linear)
        for layer in chain.layers { layer.enabled = false }
        let input = sine(500, amplitude: 0.5, seconds: 0.1)
        XCTAssertEqual(run(chain.makeProcessor(sampleRate: Self.rate, channels: 2), input), input)
    }

    func testPresetsHoldTheirOrderedLists() {
        // The camcorder mic first, then each track's own list. Hi-Fi ends with a mono sum the
        // preset leaves off, for the Audio wear slider.
        XCTAssertEqual(AudioChain(preset: .linear).layers.map(\.id),
                       ["audio-camcorder", "audio-mono", "audio-saturation", "audio-band", "audio-bump", "audio-wow",
                        "audio-hiss", "audio-whine", "audio-dolby"])
        XCTAssertEqual(AudioChain(preset: .hifi).layers.map(\.id),
                       ["audio-camcorder", "audio-compressor", "audio-fm-noise", "audio-click", "audio-expander",
                        "audio-band", "audio-dropout", "audio-mono"])
        XCTAssertFalse(AudioChain(preset: .hifi).layers.last!.enabled, "Hi-Fi's mono sum defaults off")
        // Fresh SP and a new chain play Linear NR, the linear track with its noise reduction.
        XCTAssertEqual(AudioChain().preset, .linearNR, "Linear NR is the default")
        XCTAssertEqual(AudioChain.defaultPreset, .linearNR)
        XCTAssertFalse(AudioChain(preset: .linear).layers.last!.enabled, "Dolby B mismatch defaults off")
        // Linear NR is Linear's list with the noise reduction after the hiss.
        XCTAssertEqual(AudioChain(preset: .linearNR).layers.map(\.id),
                       ["audio-camcorder", "audio-mono", "audio-saturation", "audio-band", "audio-bump", "audio-wow",
                        "audio-hiss", "audio-nr", "audio-whine", "audio-dolby"])
        XCTAssertFalse(AudioChain(preset: .linearNR).layers.last!.enabled, "Dolby B mismatch defaults off")
    }

    func testSetParameterClampsAndReadsBack() {
        let chain = AudioChain(preset: .linear)
        let hiss = chain.layers.first { $0.id == "audio-hiss" }!
        hiss.setParameter("level", to: .float(-30))
        XCTAssertEqual(hiss.parameters.first { $0.id == "level" }?.value, .float(-30))
        hiss.setParameter("level", to: .float(999))
        XCTAssertEqual(hiss.parameters.first { $0.id == "level" }?.value.doubleValue,
                       hiss.parameters.first { $0.id == "level" }?.range.upperBound)
    }

    func testBiquadLowpassDesign() {
        // A 1 kHz Butterworth lowpass is -3 dB at its corner and about unity far below.
        let f = AudioBiquad(.lowpass(hz: 1_000, q: 1 / 2.0.squareRoot()), sampleRate: Self.rate)
        XCTAssertEqual(dB(f.magnitude(at: 1_000, sampleRate: Self.rate)), -3.01, accuracy: 0.05)
        XCTAssertEqual(dB(f.magnitude(at: 50, sampleRate: Self.rate)), 0, accuracy: 0.05)
        let shelf = AudioBiquad(.highShelf(hz: 3_000, gainDB: 6), sampleRate: Self.rate)
        XCTAssertEqual(dB(shelf.magnitude(at: 20_000, sampleRate: Self.rate)), 6, accuracy: 0.3)
        let peak = AudioBiquad(.peaking(hz: 80, q: 1, gainDB: 2), sampleRate: Self.rate)
        XCTAssertEqual(dB(peak.magnitude(at: 80, sampleRate: Self.rate)), 2, accuracy: 0.01)
    }

    // MARK: Preview tap

    /// The preview tap's own processing, driven directly with no reader and no clock: the
    /// context the tap's callbacks call is prepared with the stream format an audio mix hands
    /// it (Float32, 48 kHz, stereo, interleaved and not) and fed a 15 kHz tone in 512 frame
    /// buffers, as the render thread does. Through Linear the tone comes out at -27.1 dB (the
    /// level the clock-bound read measured, -27.097 dB) and the same on both channels, with the
    /// Linear hiss under it. Off hands it back untouched. Every read gives the same level.
    func testPreviewTapProcessesTheChain() throws {
        let tone = sine(15_000, amplitude: 0.25, seconds: 1)
        let input = [tone[0], tone[1].map { $0 * 0.5 }]
        func tap(_ preset: AudioPreset, interleaved: Bool) -> [[Float]] {
            let feed = AudioPreviewFeed(spec: AudioChain(preset: preset).spec)
            let context = AudioTapContext(feed: feed)
            let asbd = AudioStreamBasicDescription(
                mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                    | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
                mBytesPerPacket: interleaved ? 8 : 4, mFramesPerPacket: 1, mBytesPerFrame: interleaved ? 8 : 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            context.prepare(asbd)
            var out: [[Float]] = [[], []]
            let block = 512
            for start in stride(from: 0, to: input[0].count, by: block) {
                let n = min(block, input[0].count - start)
                if interleaved {
                    var data = [Float](repeating: 0, count: n * 2)
                    for i in 0..<n { data[i * 2] = input[0][start + i]; data[i * 2 + 1] = input[1][start + i] }
                    data.withUnsafeMutableBytes { raw in
                        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: raw.baseAddress))
                        context.process(&list, frames: CMItemCount(n))
                    }
                    for i in 0..<n { out[0].append(data[i * 2]); out[1].append(data[i * 2 + 1]) }
                } else {
                    var left = Array(input[0][start..<(start + n)]), right = Array(input[1][start..<(start + n)])
                    left.withUnsafeMutableBytes { l in
                        right.withUnsafeMutableBytes { r in
                            let list = AudioBufferList.allocate(maximumBuffers: 2)
                            defer { free(list.unsafeMutablePointer) }
                            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: l.baseAddress)
                            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: r.baseAddress)
                            context.process(list.unsafeMutablePointer, frames: CMItemCount(n))
                        }
                    }
                    out[0] += left
                    out[1] += right
                }
            }
            context.unprepare()
            return out
        }
        let tail = 24_000..<36_000
        var levels: [Double] = []
        for interleaved in [true, false] {
            for _ in 0..<3 {
                let linear = tap(.linear, interleaved: interleaved)
                XCTAssertEqual(linear[0].count, input[0].count)
                XCTAssertGreaterThan(rms(linear[0][...]), 0.003, "the Linear tap carries its sound")
                let gain = dB(bandAmplitude(linear[0][tail], hz: 15_000, halfWidth: 60) / 0.25)
                XCTAssertEqual(gain, -27.1, accuracy: 1, "15 kHz through the Linear tap (interleaved \(interleaved))")
                XCTAssertTrue(linear[0][tail] == linear[1][tail], "Linear is mono")
                levels.append(gain)
            }
            let off = tap(.off, interleaved: interleaved)
            XCTAssertTrue(off[0] == input[0] && off[1] == input[1], "Off hands the tone back untouched")
        }
        XCTAssertEqual(Set(levels).count, 1, "every read gives the same level: \(levels)")
        print("Preview tap (direct): 15 kHz through Linear \(levels[0]) dB, \(levels.count) reads, all equal")
    }

    /// The phone's diagnostics meter reads the tap's format and the level in and out: a 1 kHz
    /// sine at 0.25 is -15.1 dBFS RMS (0.25 / sqrt 2, both channels), and Off hands back the
    /// same level. A feed made without a meter has none, which is the Mac's case.
    func testTapMeterReadsFormatAndLevels() throws {
        XCTAssertNil(AudioPreviewFeed(spec: AudioChain(preset: .off).spec).meter)
        let meter = AudioTapMeter()
        let feed = AudioPreviewFeed(spec: AudioChain(preset: .off).spec, meter: meter)
        let context = AudioTapContext(feed: feed)
        let asbd = AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        context.prepare(asbd)
        // Two seconds, six of the meter's time constants, so its one pole has settled.
        let tone = sine(1_000, amplitude: 0.25, seconds: 2)
        let block = 512
        for start in stride(from: 0, to: tone[0].count, by: block) {
            let n = min(block, tone[0].count - start)
            var data = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { data[i * 2] = tone[0][start + i]; data[i * 2 + 1] = tone[1][start + i] }
            data.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: raw.baseAddress))
                context.process(&list, frames: CMItemCount(n))
            }
        }
        let r = meter.reading
        XCTAssertTrue(r.prepared && r.float32 && r.interleaved)
        XCTAssertEqual(r.sampleRate, Self.rate)
        XCTAssertEqual(r.channels, 2)
        XCTAssertEqual(r.framesSeen, tone[0].count)
        XCTAssertEqual(Double(AudioTapMeter.Reading.dBFS(r.inMeanSquare)), -15.05, accuracy: 0.2)
        XCTAssertEqual(Double(AudioTapMeter.Reading.dBFS(r.outMeanSquare)), -15.05, accuracy: 0.2)
        context.unprepare()
        XCTAssertFalse(meter.reading.prepared)
    }

    /// The same tap end to end, through an asset reader that applies the audio mix as the player
    /// item does. The reader runs the tap against the clock: a buffer whose processing overruns
    /// its own length gets the tap unprepared and the rest of the read comes back as silence.
    /// A debug build runs the Linear chain at about 94% of real time, so on a busy Mac it fails
    /// for timing alone. It runs only in a release build, at about 12% of real
    /// time. The chain itself is checked with no clock in `testPreviewTapProcessesTheChain`.
    func testPreviewTapRunsTheChain() async throws {
        #if DEBUG
        throw XCTSkip("Clock-bound: a debug build runs the Linear tap near real time, so the reader can drop it. Run it in release.")
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-tap-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let n = AVAudioFrameCount(Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buffer.frameLength = n
        let tone = sine(15_000, amplitude: 0.25, seconds: 1)
        for c in 0..<2 { for i in 0..<Int(n) { buffer.floatChannelData![c][i] = tone[c][i] * (c == 0 ? 1 : 0.5) } }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        func render(_ preset: AudioPreset) async throws -> [[Float]] {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .audio).first!
            let feed = AudioPreviewFeed(spec: AudioChain(preset: preset).spec)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
            ])
            output.audioMix = try XCTUnwrap(feed.makeAudioMix(for: track))
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var planar: [[Float]] = [[], []]
            while let s = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(s) {
                let count = CMBlockBufferGetDataLength(block) / 4
                var data = [Float](repeating: 0, count: count)
                _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4,
                                                                              destination: $0.baseAddress!) }
                for i in stride(from: 0, to: count - 1, by: 2) { planar[0].append(data[i]); planar[1].append(data[i + 1]) }
            }
            return planar
        }

        let linear = try await render(.linear)
        let off = try await render(.off)
        // A tap that stalls renders silence, which would pass the rolloff check hollow: the
        // Linear output must carry its hiss and the tone's remainder.
        XCTAssertGreaterThan(rms(linear[0][...]), 0.003, "the Linear tap rendered silence")
        XCTAssertGreaterThan(linear[0].count, 40_000)
        let tail = 24_000..<36_000
        let gain = dB(bandAmplitude(linear[0][tail], hz: 15_000, halfWidth: 60) / 0.25)
        XCTAssertLessThan(gain, -20, "15 kHz through the Linear tap: \(gain) dB")
        XCTAssertEqual(linear[0][tail], linear[1][tail], "Linear is mono")
        XCTAssertEqual(dB(bandAmplitude(off[0][tail], hz: 15_000, halfWidth: 60) / 0.25), 0, accuracy: 0.5)
        print("Preview tap (reader): 15 kHz through Linear \(gain) dB")
    }

    // MARK: Arguments

    func testPresetArgumentTakesAudio() throws {
        XCTAssertEqual(try PresetSelection.parse("audio=linear").audio, .linear)
        XCTAssertEqual(try PresetSelection.parse("audio=linearnr").audio, .linearNR)
        XCTAssertEqual(try PresetSelection.parse("tape=ep,audio=off").audio, .off)
        XCTAssertEqual(try PresetSelection.parse("audio=Hi-Fi").audio, .hifi)
        XCTAssertThrowsError(try PresetSelection.parse("audio=dolby"))
    }

    func testApplySetsAudioPresetAndAudioParameters() throws {
        let chain = SignalChain.standard()
        // The default is Linear NR, and the chain starts on Hi-Fi to see the preset move.
        XCTAssertEqual(chain.audio.preset, .linearNR)
        chain.audio.preset = .hifi
        let args = try RenderArguments.parse(["in.mov", "out.mov", "--preset", "audio=linear",
                                              "--set", "audio-hiss.level=-36", "--set", "audio-dolby.enabled=on"])
        try args.apply(to: chain)
        XCTAssertEqual(chain.audio.preset, .linear)
        XCTAssertEqual(chain.audio.layers.first { $0.id == "audio-hiss" }?.parameters.first?.value, .float(-36))
        XCTAssertTrue(chain.audio.layers.first { $0.id == "audio-dolby" }!.enabled)
        let bad = try RenderArguments.parse(["in.mov", "out.mov", "--set", "audio-hiss.level=-36"])
        let hifi = SignalChain.standard()
        hifi.audio.preset = .hifi
        XCTAssertThrowsError(try bad.apply(to: hifi), "Hi-Fi has no hiss layer")
    }

    // MARK: Camcorder mic

    /// The four tracks' specs as they stood before the camcorder mic.
    static let tracksBeforeTheMic: [AudioPreset: [String]] = [
        .hifi: ["audio-compressor", "audio-fm-noise", "audio-click", "audio-expander", "audio-band", "audio-dropout"],
        .linear: ["audio-mono", "audio-saturation", "audio-band", "audio-bump", "audio-wow", "audio-hiss", "audio-whine"],
        .wornLinear: ["audio-mono", "audio-saturation", "audio-band", "audio-bump", "audio-wow", "audio-hiss",
                      "audio-whine", "audio-mute"],
        .epLinear: ["audio-mono", "audio-saturation", "audio-band", "audio-azimuth", "audio-bump", "audio-wow",
                    "audio-hiss", "audio-whine"],
    ]

    func testCamcorderMicIsFirstAndOffInEveryTrack() {
        for preset in [AudioPreset.hifi, .linear, .wornLinear, .epLinear] {
            let chain = AudioChain(preset: preset)
            XCTAssertEqual(chain.layers.first?.id, "audio-camcorder", "\(preset)")
            XCTAssertEqual(chain.layers.first?.name, "Camcorder mic")
            XCTAssertEqual(chain.layers.first?.enabled, false, "\(preset)")
        }
        // Off holds only the mic, off, so the camcorder mic can play with no track.
        XCTAssertEqual(AudioChain(preset: .off).layers.map(\.id), ["audio-camcorder"])
        XCTAssertEqual(AudioChain(preset: .off).layers.first?.enabled, false)
    }

    func testCamcorderMicOffLeavesEveryPresetSpec() {
        for (preset, ids) in Self.tracksBeforeTheMic {
            let spec = AudioChain(preset: preset).spec
            XCTAssertEqual(spec.layers.map { $0.kind.id }, ids, "\(preset)")
            XCTAssertEqual(spec, AudioChainSpec.defaults(preset), "\(preset)")
            // Every value as the kind's defaults with the preset's overrides, as before the mic.
            for l in spec.layers {
                XCTAssertEqual(l, AudioLayerSpec.defaults(l.kind, preset: preset), "\(preset) \(l.kind)")
            }
        }
    }

    /// The mic alone on silence, one channel pair.
    func micOnly(_ values: [String: Double] = [:], seconds: Double, input: [[Float]]? = nil) -> [[Float]] {
        var s = AudioLayerSpec.defaults(.camcorderMic)
        for (k, v) in values { s.values[k] = .float(v) }
        let p = AudioChainProcessor(spec: AudioChainSpec(layers: [s]), sampleRate: Self.rate, channels: 2)
        return run(p, input ?? sine(1_000, amplitude: 0, seconds: seconds))
    }

    func testCamcorderMicOnSilenceReadsItsLevelWithALineAtTheWhine() {
        let out = micOnly(seconds: 6)
        let tail = out[0][(2 * Int(Self.rate))...]
        XCTAssertEqual(dB(rms(tail)), CamcorderMic.defaultLevel, accuracy: 1, "the bed reads Motor level in silence")
        XCTAssertEqual(out[0], out[1], "one mic: both channels alike")
        // A line at the whine: its band holds far more than a band of the same width beside it.
        let slice = tail.prefix(Int(Self.rate))
        let line = bandAmplitude(slice, hz: CamcorderMic.defaultWhine, halfWidth: 20)
        let beside = bandAmplitude(slice, hz: CamcorderMic.defaultWhine * 1.3, halfWidth: 20)
        XCTAssertGreaterThan(dB(line / beside), 20)
        // Another whine moves the line.
        let moved = micOnly(["whine": 2_400], seconds: 3)[0][Int(Self.rate)...].prefix(Int(Self.rate))
        XCTAssertGreaterThan(dB(bandAmplitude(moved, hz: 2_400, halfWidth: 20) / bandAmplitude(moved, hz: CamcorderMic.defaultWhine, halfWidth: 20)), 20)
    }

    func testCamcorderMicIsTheSameTakeForOneSeedAndAnotherForAnother() {
        let a = micOnly(["seed": 7], seconds: 4)
        let b = micOnly(["seed": 7], seconds: 4)
        let c = micOnly(["seed": 8], seconds: 4)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCamcorderMicAGCLiftsTheBedInTheGaps() {
        // A loud tone for 3 s, then 6 s of silence: the whine's line reads lift dB louder in the
        // silence, once the AGC has climbed back.
        let n = Int(9 * Self.rate)
        let tone = (0..<n).map { i -> Float in i < Int(3 * Self.rate) ? Float(0.25 * sin(2 * .pi * 1_000 * Double(i) / Self.rate)) : 0 }
        let out = micOnly(seconds: 9, input: [tone, tone])
        let loud = out[0][Int(1 * Self.rate)..<Int(3 * Self.rate)]
        let quiet = out[0][Int(6 * Self.rate)..<Int(8 * Self.rate)]
        let lift = dB(bandAmplitude(quiet, hz: CamcorderMic.defaultWhine, halfWidth: 20)
                      / bandAmplitude(loud, hz: CamcorderMic.defaultWhine, halfWidth: 20))
        XCTAssertEqual(lift, 12, accuracy: 1.5, "the AGC lift between the loud and the silent stretch")
        // The loud tone passes at unity: the AGC only lifts.
        XCTAssertEqual(dB(bandAmplitude(loud, hz: 1_000, halfWidth: 20) / 0.25), 0, accuracy: 0.5)
    }

    /// The mic has no zoom parameter, and a sidecar or a preset saved while it had one still
    /// names `zoom`, `zoomLevel`, `zoomRate` and `zoomLength` loads without error, the rest of
    /// it kept.
    func testTheZoomSoundIsGoneAndOldFilesThatNameItStillLoad() throws {
        let ids = AudioLayerKind.camcorderMic.defaultParameters.map(\.id)
        XCTAssertEqual(ids, ["level", "whine", "lift", "seed"])
        for preset in AudioPreset.allCases {
            XCTAssertFalse(AudioChain(preset: preset).micLayer.parameters.contains { $0.id.hasPrefix("zoom") }, preset.rawValue)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zoomgone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A camcorder sidecar from when the mic had a zoom: the golden one (with zoomRate and
        // zoomLength) with the Zoom sound and Zoom level added, and a Whine of its own.
        let old = try XCTUnwrap(AudioSplitGoldens.sidecars["camcorder"])
        let first = try XCTUnwrap(old.range(of: #""parameters": ["#))
        var text = old
        text.insert(contentsOf: #"{ "id": "zoom", "value": "random" }, { "id": "zoomLevel", "value": 9 },"#,
                    at: first.upperBound)
        text = text.replacingOccurrences(of: #""value": 1600"#, with: #""value": 2000"#)
        XCTAssertTrue(text.contains(#""zoomRate""#) && text.contains(#""zoomLength""#))
        let url = dir.appendingPathComponent("old.homevideo.json")
        try Data(text.utf8).write(to: url)
        let chain = SignalChain.standard()
        XCTAssertNoThrow(try Sidecar.read(url, into: chain))
        XCTAssertEqual(chain.audio.preset, .camcorder)
        XCTAssertTrue(chain.audio.micLayer.enabled)
        XCTAssertEqual(chain.audio.micLayer.value("whine"), .float(2_000), "the rest of the file is read")
        XCTAssertEqual(chain.audio.micLayer.parameters.map(\.id), ids)

        // The same through a saved preset whose file names the old parameters.
        let presets = UserPresets(folder: dir)
        let saved = try presets.save(name: "Old zoom", chain: chain)
        var preset = try String(contentsOf: saved.url, encoding: .utf8)
        let whine = try XCTUnwrap(preset.range(of: #""id" : "whine""#) ?? preset.range(of: #""id": "whine""#),
                                  "the preset file names the whine: \(preset.prefix(400))")
        let open = try XCTUnwrap(preset.range(of: "{", options: .backwards, range: preset.startIndex..<whine.lowerBound))
        preset.insert(contentsOf: #"{ "id": "zoom", "value": "follow" }, { "id": "zoomRate", "value": 20 }, "#,
                      at: open.lowerBound)
        try Data(preset.utf8).write(to: saved.url)
        let fromPreset = SignalChain.standard()
        XCTAssertNoThrow(try presets.load(saved.url, into: fromPreset))
        XCTAssertEqual(fromPreset.audio.micLayer.value("whine"), .float(2_000))
        XCTAssertEqual(fromPreset.audio.micLayer.parameters.map(\.id), ids)
    }

    // MARK: Audio wear

    func values(_ chain: AudioChain) -> [String: Double] {
        var out: [String: Double] = [:]
        for l in chain.layers { for p in l.parameters { if let v = p.value.doubleValue { out["\(l.id).\(p.id)"] = v } } }
        return out
    }

    func testWearZeroIsThePresetAndHundredIsEveryWornEnd() {
        for preset in AudioPreset.allCases where preset != .off {
            let fresh = AudioChain(preset: preset)
            let chain = AudioChain(preset: preset)
            chain.setWear(0)
            XCTAssertEqual(values(chain), values(fresh), "\(preset) at 0")
            chain.setWear(100)
            var moved = 0
            for l in chain.layers {
                for (id, worn) in AudioWear.wornEnd(l.kind) {
                    XCTAssertEqual(l.value(id)?.doubleValue ?? .nan, worn, accuracy: 1e-9, "\(preset) \(l.id).\(id)")
                    moved += 1
                }
            }
            XCTAssertGreaterThan(moved, 4, "\(preset)")
            chain.setWear(50)
            for l in chain.layers {
                let base = l.kind.parameters(for: preset)
                for (id, worn) in AudioWear.wornEnd(l.kind) {
                    let b = base.first { $0.id == id }!.value.doubleValue!
                    XCTAssertEqual(l.value(id)!.doubleValue!, (b + worn) / 2, accuracy: 1e-9, "\(preset) \(l.id).\(id) at 50")
                }
            }
            chain.setWear(0)
            XCTAssertEqual(values(chain), values(fresh), "\(preset) back at 0")
        }
    }

    func testWearTurnsHiFiMonoPastTheMidpointAndKeepsAcrossPresets() {
        let chain = AudioChain(preset: .hifi)
        let mono = { chain.layers.first { $0.id == "audio-mono" }!.enabled }
        chain.setWear(50)
        XCTAssertFalse(mono())
        chain.setWear(51)
        XCTAssertTrue(mono())
        chain.setWear(20)
        XCTAssertFalse(mono())
        chain.setWear(80)
        chain.preset = .linear
        XCTAssertEqual(chain.wear, 80)
        XCTAssertEqual(chain.layers.first { $0.id == "audio-band" }!.value("lowpass")!.doubleValue!,
                       AudioWear.value(base: 10_000, worn: 2_500, wear: 80), accuracy: 1e-9)
    }

    func testWearHundredOnLinearMeasuresItsLowpassAndHiss() {
        let chain = AudioChain(preset: .linear)
        chain.setWear(100)
        // Silence: the hiss reads its worn end, -28 dBFS, within 1 dB.
        let quiet = run(chain.makeProcessor(sampleRate: Self.rate, channels: 2), sine(1_000, amplitude: 0, seconds: 2))
        XCTAssertEqual(dB(rms(quiet[0][Int(Self.rate)...])), -28, accuracy: 1)
        // Tones: 2.5 kHz sits near -3 dB against 500 Hz, the worn band's edge.
        func gain(_ hz: Double) -> Double {
            let out = run(chain.makeProcessor(sampleRate: Self.rate, channels: 2), sine(hz, amplitude: 0.05, seconds: 1.5))
            return bandAmplitude(out[0][Int(0.5 * Self.rate)...], hz: hz) / 0.05
        }
        XCTAssertEqual(dB(gain(2_500) / gain(500)), -3, accuracy: 1.5, "the lowpass near 2.5 kHz")
        XCTAssertLessThan(dB(gain(5_000) / gain(500)), -18, "well down an octave above")
    }
}
