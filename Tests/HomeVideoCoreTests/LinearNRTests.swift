import XCTest
@testable import HomeVideoCore

/// Linear NR, the linear track with a matched B type noise reduction, the default sound. The
/// program comes out as Linear's, the hiss comes down in the treble, and the floor in
/// `AudioSplitTests.input()`'s silent gap sits between Linear and Hi-Fi. The numbers print as
/// `LINEARNR` lines.
@MainActor
final class LinearNRTests: XCTestCase {
    static let rate = AudioSplitTests.rate

    /// Inside the input's silent gap (0.8 to 1.4 s), after the decoder's 60 ms release has let go
    /// of the tones before it (its control takes about 0.25 s to fall from the tones' treble to
    /// the full cut), and clear of the gap's far edge.
    static let gap = Int(1.1 * rate)..<Int(1.35 * rate)

    static func render(_ preset: AudioPreset, hiss: Bool = true) -> [[Float]] {
        let chain = AudioChain(preset: preset)
        if !hiss { chain.layers.first { $0.kind == .hiss }?.enabled = false }
        return AudioSplitTests.render(chain.spec)
    }

    /// RMS in dBFS over `range` of every channel, after an optional 4th order highpass.
    static func level(_ b: [[Float]], _ range: Range<Int>, above: Double? = nil) -> Double {
        var sum = 0.0, n = 0
        for ch in b {
            let fs = above.map { hz in butterworth4Q.map { AudioBiquad(.highpass(hz: hz, q: $0), sampleRate: rate) } } ?? []
            for (i, v) in ch.enumerated() {
                let y = fs.reduce(v) { $1.process($0) }
                if range.contains(i) { sum += Double(y) * Double(y); n += 1 }
            }
        }
        return 10 * log10(max(sum / Double(max(n, 1)), 1e-20))
    }

    /// Integrated loudness per ITU-R BS.1770-4: the K weighting at 48 kHz (the standard's own
    /// coefficients), 400 ms blocks at 75 percent overlap, the -70 LUFS absolute gate and the
    /// relative gate 10 LU under the gated mean.
    static func lufs(_ b: [[Float]]) -> Double {
        func biquad(_ x: [Double], _ bc: [Double], _ ac: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = bc[0] * x[i] + bc[1] * x1 + bc[2] * x2 - ac[1] * y1 - ac[2] * y2
                (x2, x1, y2, y1) = (x1, x[i], y1, v)
                y[i] = v
            }
            return y
        }
        let weighted = b.map { ch -> [Double] in
            let shelf = biquad(ch.map(Double.init), [1.53512485958697, -2.69169618940638, 1.19839281085285],
                               [1, -1.69065929318241, 0.73248077421585])
            return biquad(shelf, [1, -2, 1], [1, -1.99004745483398, 0.99007225036621])
        }
        let block = Int(0.4 * rate), hop = block / 4
        var powers: [Double] = []
        var start = 0
        while start + block <= weighted[0].count {
            var z = 0.0
            for ch in weighted { z += ch[start..<(start + block)].reduce(0) { $0 + $1 * $1 } / Double(block) }
            powers.append(z)
            start += hop
        }
        func loudness(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-20)) }
        let absolute = powers.filter { loudness($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let relative = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relative }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// A matched pair leaves the program alone: with the hiss off, Linear NR is Linear sample
    /// for sample, so only the hiss differs between them.
    func testTheProgramComesOutAsLinears() {
        XCTAssertEqual(AudioSplitTests.sampleHash(Self.render(.linearNR, hiss: false)),
                       AudioSplitTests.sampleHash(Self.render(.linear, hiss: false)))
        XCTAssertNotEqual(AudioSplitTests.sampleHash(Self.render(.linearNR)),
                          AudioSplitTests.sampleHash(Self.render(.linear)))
    }

    /// The decoder's cut at a low level follows the four published Dolby B figures within a dB: 3 dB at
    /// 600 Hz, 6 at 1.2 kHz, 8 at 2.4 kHz, 10 at 5 kHz.
    func testTheLowLevelCurveMatchesTheFigures() {
        let spec = AudioLayerSpec.defaults(.noiseReduction, preset: .linearNR)
        for (hz, want) in [(600.0, 3.0), (1_200, 6.0), (2_400, 8.0), (5_000, 10.0)] {
            let cut = SlidingHissCut(spec: spec, sampleRate: Self.rate)
            var inSum = 0.0, outSum = 0.0
            for i in 0..<Int(Self.rate) {
                let x = Float(0.01 * sin(2 * .pi * hz * Double(i) / Self.rate))
                let y = cut.process(x, program: 0)
                if i > Int(Self.rate / 2) { inSum += Double(x * x); outSum += Double(y * y) }
            }
            XCTAssertEqual(10 * log10(inSum / outSum), want, accuracy: 1, "\(hz) Hz")
        }
    }

    /// Loud treble in the program slides the cut off: hiss under a -10 dBFS 3 kHz tone passes
    /// within a dB.
    func testLoudTrebleSlidesTheCutOff() {
        let spec = AudioLayerSpec.defaults(.noiseReduction, preset: .linearNR)
        let cut = SlidingHissCut(spec: spec, sampleRate: Self.rate)
        var inSum = 0.0, outSum = 0.0
        for i in 0..<Int(Self.rate) {
            let t = Double(i) / Self.rate
            let hiss = Float(0.001 * sin(2 * .pi * 5_000 * t))
            let y = cut.process(hiss, program: Float(0.316 * sin(2 * .pi * 3_000 * t)))
            if i > Int(Self.rate / 2) { inSum += Double(hiss * hiss); outSum += Double(y * y) }
        }
        XCTAssertLessThan(10 * log10(inSum / outSum), 1)
    }

    /// The floor in the gap and loudness: Linear NR sits between Linear and Hi-Fi.
    func testTheDefaultSitsBetweenLinearAndHiFi() {
        var rows: [String: (floor: Double, above1k: Double, above2k: Double, lufs: Double)] = [:]
        for preset in [AudioPreset.hifi, .linearNR, .linear] {
            let b = Self.render(preset)
            rows[preset.rawValue] = (Self.level(b, Self.gap), Self.level(b, Self.gap, above: 1_000),
                                     Self.level(b, Self.gap, above: 2_000), Self.lufs(b))
            let r = rows[preset.rawValue]!
            print(String(format: "LINEARNR %@ floor %.1f dBFS, above 1 kHz %.1f, above 2 kHz %.1f, loudness %.2f LUFS",
                         preset.rawValue, r.floor, r.above1k, r.above2k, r.lufs))
        }
        print(String(format: "LINEARNR input loudness %.2f LUFS", Self.lufs(AudioSplitTests.input())))
        let hifi = rows["hifi"]!, nr = rows["linearnr"]!, linear = rows["linear"]!
        XCTAssertLessThan(hifi.floor, nr.floor, "Hi-Fi is the quietest")
        // Pink hiss holds most of its power under 1 kHz, where a B type pair does little, so the
        // whole band moves less than the treble.
        XCTAssertLessThan(nr.floor, linear.floor - 1, "Linear NR's floor is lower than Linear's")
        XCTAssertLessThan(nr.above2k, linear.above2k - 7, "and its treble hiss most of all")
        XCTAssertGreaterThan(nr.above2k, linear.above2k - 11, "by no more than the cut")
    }
}
