import Metal
import XCTest
@testable import HomeVideoCore

final class FilterDesignTests: XCTestCase {
    func testButterworth2AtPointOneMatchesKnownCoefficients() {
        // fc / fs = 0.1 (0.2 of Nyquist): scipy.signal.butter(2, 0.2) gives
        // b = [0.06745527, 0.13491055, 0.06745527], a = [1, -1.14298050, 0.41280160].
        let c = Filters.lowpass2(cutoff: 0.1)
        XCTAssertEqual(c.b0, 0.06745527, accuracy: 1e-7)
        XCTAssertEqual(c.b1, 0.13491055, accuracy: 1e-7)
        XCTAssertEqual(c.b2, 0.06745527, accuracy: 1e-7)
        XCTAssertEqual(c.a1, -1.14298050, accuracy: 1e-7)
        XCTAssertEqual(c.a2, 0.41280160, accuracy: 1e-7)
    }

    func testRCStepReaches63PercentAfterOneOverAlpha() {
        for alpha in [0.01, 0.05, 0.1] {
            let n = Int((1 / alpha).rounded())
            let y = Filters.run([Filters.rc(alpha: alpha)], [Double](repeating: 1, count: n))
            XCTAssertEqual(y[n - 1], 1 - exp(-1), accuracy: 0.03, "alpha \(alpha)")
            XCTAssertLessThan(y[n - 2], y[n - 1])
        }
    }

    func testButterworth3HasUnityDCAndMinus3dBAtCutoff() {
        let f = 0.05
        let s = Filters.butterworth3(cutoff: f)
        XCTAssertEqual(s.reduce(1) { $0 * $1.dcGain }, 1, accuracy: 1e-9)
        // Steady state amplitude of a sine at the cutoff.
        let n = 4000
        let x = (0..<n).map { sin(2 * .pi * f * Double($0)) }
        let y = Filters.run(s, x)
        let peak = y[(n - 200)...].map(abs).max()!
        XCTAssertEqual(peak, 1 / 2.0.squareRoot(), accuracy: 0.01)
    }

    func testPrimedFilterHoldsAConstantLine() {
        let y = Filters.run(Filters.butterworth3(cutoff: 0.02), [Double](repeating: 0.7, count: 50), primed: true)
        for v in y { XCTAssertEqual(v, 0.7, accuracy: 1e-12) }
    }

    func testNotchRemovesItsCenter() {
        let f = 0.08
        let n = 3000
        let y = Filters.run([Filters.notch(center: f, q: 4)], (0..<n).map { sin(2 * .pi * f * Double($0)) })
        XCTAssertLessThan(y[(n - 200)...].map(abs).max()!, 0.01)
    }

    func testYIQInverseIsExact() {
        let f = YIQ.forward, i = YIQ.inverse
        for r in 0..<3 {
            for c in 0..<3 {
                let v = (0..<3).reduce(0.0) { $0 + i[r][$1] * f[$1][c] }
                XCTAssertEqual(v, r == c ? 1 : 0, accuracy: 1e-12)
            }
        }
    }
}

final class VHSLayerTests: XCTestCase {
    // MARK: Chain structure

    @MainActor
    func testLayersAreInSignalOrderAndL1FollowsTheMiddle() {
        let vhs = VHSLayers()
        XCTAssertEqual(vhs.all.map(\.id), ["camera", "output-card", "frame", "composite-link",
                                           "damage-clog", "damage-crease", "damage-snow", "damage-tear",
                                           "luma-bandwidth", "color-under", "tape-noise", "dropouts", "edge-halo",
                                           "head-switch", "time-base", "generation", "osd", "levels", "capture"])
        XCTAssertFalse(vhs.generation.enabled, "the dub is an option")
        XCTAssertFalse(vhs.camera.enabled, "the camera is off by default")
        XCTAssertTrue(vhs.frame.enabled, "the frame is on by default")
        XCTAssertFalse(vhs.osd.enabled, "the VCR on-screen display is off by default")
        XCTAssertFalse(vhs.compositeLink.enabled, "L2 is off by default (S-Video)")
        XCTAssertTrue(vhs.outputCard.enabled && vhs.outputCard.isRequired)
        XCTAssertTrue(vhs.capture.enabled)
        vhs.allOff()
        XCTAssertFalse(vhs.outputCard.enabled)
        XCTAssertFalse(vhs.capture.enabled)
        vhs.headSwitch.enabled = true
        XCTAssertTrue(vhs.outputCard.enabled && vhs.capture.enabled)
    }

    // MARK: The round trip

    /// With every layer off the output is the Framing output, bit for bit.
    @MainActor
    func testAllLayersOffEqualsFramingExactly() throws {
        let g = try GPUHarness()
        let src = try g.source { x, y in (UInt8((x * 7 + y) & 255), UInt8((x ^ y) & 255), UInt8((y * 3) & 255)) }
        let (chain, _) = g.vhsChain()
        let framingOnly = SignalChain(framing: FramingLayer(mode: .fullRaster))
        let a = try g.run(chain, src, frame: 3, raw: true).1
        let b = try g.run(framingOnly, src, frame: 3, raw: true).1
        XCTAssertEqual(a, b)
    }

    /// L1 then L9 with nothing between is the identity within 1/255.
    @MainActor
    func testL1ThenL9IsIdentity() throws {
        let g = try GPUHarness()
        let src = try g.source { x, y in (UInt8((x * 7 + y) & 255), UInt8((x ^ y) & 255), UInt8((y * 3) & 255)) }
        let (chain, vhs) = g.vhsChain()
        vhs.outputCard.enabled = true
        XCTAssertTrue(vhs.capture.enabled)
        let out = try g.run(chain, src)
        let ref = try g.run(SignalChain(framing: FramingLayer(mode: .fullRaster)), src)
        let maxErr = zip(out.data, ref.data).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(maxErr, 1.0 / 255.0)
    }

    // MARK: L2

    /// Fine luma detail near the subcarrier leaks into chroma (cross color) with the link on.
    @MainActor
    func testL2CompositeLinkMakesCrossColorOnFineLuma() throws {
        let g = try GPUHarness()
        let fsc = 3.579545 / 13.5
        let src = try g.source { x, _ in
            let v = UInt8(128 + 80 * cos(2 * .pi * fsc * Double(x)))
            return (v, v, v)
        }
        let (chain, vhs) = g.vhsChain()
        vhs.outputCard.enabled = true
        let off = try g.run(chain, src)
        vhs.compositeLink.enabled = true
        let on = try g.run(chain, src)
        func chromaPeak(_ r: Raster) -> Float {
            (100..<600).map { x in let c = r.yiq(x, 240); return (c.y * c.y + c.z * c.z).squareRoot() }.max()!
        }
        XCTAssertLessThan(chromaPeak(off), 0.01)
        XCTAssertGreaterThan(chromaPeak(on), 0.05)
    }

    /// comb2 combs only the composite's high band: a vertical luma edge (flat along the line)
    /// passes as S-Video does, within 1 percent, while the full band comb1 smears it; a chroma
    /// bar still separates.
    @MainActor
    func testComb2PassesLowFrequencyVerticalLumaAndStillSeparatesChroma() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.outputCard.enabled = true
        func worstLumaError(_ a: Raster, _ b: Raster, rows: ClosedRange<Int>) -> Float {
            var worst: Float = 0
            for y in rows { for x in stride(from: 100, to: 600, by: 10) { worst = max(worst, abs(a.yiq(x, y).x - b.yiq(x, y).x)) } }
            return worst
        }
        let edge = try g.source { _, y in y < 240 ? (64, 64, 64) : (192, 192, 192) }
        let sVideo = try g.run(chain, edge)
        vhs.compositeLink.enabled = true
        vhs.compositeLink.separator = .comb2
        XCTAssertLessThan(worstLumaError(try g.run(chain, edge), sVideo, rows: 230...250), 0.01, "comb2 keeps the edge")
        vhs.compositeLink.separator = .comb1
        XCTAssertGreaterThan(worstLumaError(try g.run(chain, edge), sVideo, rows: 230...250), 0.05,
                             "canary: the full band comb1 smears the same edge")

        // A red bar on gray, flat down the frame: chroma and luma both come through comb2.
        let bar = try g.source { x, _ in x >= 200 && x < 500 ? (191, 40, 40) : (128, 128, 128) }
        vhs.compositeLink.enabled = false
        let barSVideo = try g.run(chain, bar)
        vhs.compositeLink.enabled = true
        vhs.compositeLink.separator = .comb2
        let barComb = try g.run(chain, bar)
        func chroma(_ r: Raster) -> Float { let c = r.yiq(350, 240); return (c.y * c.y + c.z * c.z).squareRoot() }
        XCTAssertEqual(chroma(barComb), chroma(barSVideo), accuracy: 0.1 * chroma(barSVideo), "chroma separates")
        XCTAssertEqual(barComb.yiq(350, 240).x, barSVideo.yiq(350, 240).x, accuracy: 0.02, "no chroma left in luma")
    }

    // MARK: Frame

    /// Blanking: by default a 17 px right bar only, the picture moved left by the offset;
    /// with the Camcorder values a 15 px left bar and 5 black top rows as well.
    @MainActor
    func testFrameBlanksTheBarsAndTopRows() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.frame.enabled = true
        let src = try g.source { x, _ in x < 360 ? (128, 128, 128) : (255, 255, 255) }
        var out = try g.run(chain, src)
        var row = out.row(100) { $0.x }
        var lit = row.indices.filter { row[$0] > 0.25 }
        XCTAssertEqual(lit.first, 0)
        XCTAssertEqual(lit.last, 702, "right bar is 17 samples")
        XCTAssertEqual(crossing(row, lo: 128.0 / 255, hi: 1, from: 300), 357.5, accuracy: 0.01, "picture moves left by 2")
        XCTAssertEqual(out.rgb(100, 0).x, 128.0 / 255, accuracy: 1.0 / 255, "no top rows by default")

        vhs.frame.setParameter("left", to: .float(15))
        vhs.frame.setParameter("top", to: .float(5))
        out = try g.run(chain, src)
        row = out.row(100) { $0.x }
        lit = row.indices.filter { row[$0] > 0.25 }
        XCTAssertEqual(lit.first, 15)
        XCTAssertEqual(lit.last, 702)
        XCTAssertEqual(out.rgb(100, 4).x, 0, accuracy: 1.0 / 255, "top rows black")
        XCTAssertEqual(out.rgb(100, 5).x, 128.0 / 255, accuracy: 1.0 / 255)
    }

    // MARK: L3

    /// A vertical edge is blurred horizontally; a horizontal edge stays sharp.
    @MainActor
    func testL3BlursVerticalEdgeAndLeavesHorizontalEdge() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.luma.enabled = true
        vhs.luma.emphasis = false
        let vEdge = try g.run(chain, try g.source { x, _ in x < 360 ? (0, 0, 0) : (255, 255, 255) })
        let w = transitionWidth(vEdge.row(200) { $0.x }, lo: 0, hi: 1, from: 300)
        // 10 to 90 percent rise of a 2.4 MHz 3rd order Butterworth is about 0.35 / 0.178 = 2 samples.
        XCTAssertGreaterThanOrEqual(w, 2, "the edge should spread over several samples")
        XCTAssertGreaterThan(crossing(vEdge.row(200) { $0.x }, lo: 0, hi: 1, from: 300), 360,
                             "a causal filter delays the edge to the right")

        let hEdge = try g.run(chain, try g.source { _, y in y < 240 ? (0, 0, 0) : (255, 255, 255) })
        for x in [10, 360, 700] {
            XCTAssertEqual(hEdge.rgb(x, 239).x, 0, accuracy: 1.0 / 255)
            XCTAssertEqual(hEdge.rgb(x, 240).x, 1, accuracy: 1.0 / 255)
        }
    }

    /// The emphasis clip: a big edge overshoots to its right and its clipped overshoot comes
    /// back as a streak; nothing moves left of the edge; small texture is cored flat by L6.
    @MainActor
    func testL3EmphasisClipStreaksBigEdgesAndL6CoresSmallTexture() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.luma.enabled = true
        vhs.halo.enabled = true
        vhs.halo.ringIntensity = 0
        let lo: Float = 26.0 / 255, hi: Float = 230.0 / 255
        let src = try g.source { x, y in
            if y < 240 { return x < 360 ? (26, 26, 26) : (230, 230, 230) }
            let v: UInt8 = (x / 4) & 1 == 0 ? 125 : 131
            return (v, v, v)
        }
        let clipped = try g.run(chain, src)
        vhs.luma.whiteClipIRE = 300
        vhs.luma.darkClipIRE = -200
        let unclipped = try g.run(chain, src)
        let a = clipped.row(100) { $0.x }, b = unclipped.row(100) { $0.x }

        for x in 300..<358 { XCTAssertEqual(a[x], lo, accuracy: 1.0 / 255, "flat field left of the edge at \(x)") }
        XCTAssertGreaterThan(a[360..<400].max()!, hi + 0.02, "overshoot right of the edge")
        XCTAssertGreaterThan(b[360..<400].max()!, a[360..<400].max()!, "the clip takes the top off it")
        let streak = (362..<460).filter { abs(a[$0] - b[$0]) > 0.004 }
        XCTAssertGreaterThanOrEqual(streak.count, 10, "the clipped overshoot streaks to the right")

        let texture = clipped.row(300) { $0.x }[200..<500]
        XCTAssertLessThan(texture.max()! - texture.min()!, 0.01, "a 2.4 percent texture is cored to under 1 percent")
    }

    // MARK: L4

    /// On a black to red edge the chroma transition is several times the luma transition and
    /// sits to its right.
    @MainActor
    func testL4WidensAndDelaysChromaMoreThanLuma() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.colorUnder.enabled = true
        vhs.colorUnder.phaseNoiseDegrees = 0
        let out = try g.run(chain, try g.source { x, _ in x < 300 ? (0, 0, 0) : (255, 0, 0) })
        let y = out.row(241, { $0.x }, yiq: true)
        let i = out.row(241, { $0.y }, yiq: true)
        let iHi = Float(YIQ.forward[1][0])
        let lw = transitionWidth(y, lo: 0, hi: Float(YIQ.forward[0][0]), from: 250)
        let cw = transitionWidth(i, lo: 0, hi: iHi, from: 250)
        XCTAssertLessThanOrEqual(lw, 1)
        XCTAssertGreaterThanOrEqual(cw, 4 * max(lw, 1))
        // The Y delay line equalizes the chroma filter's group delay: the net lag is the
        // explicit delay (default 1 px), not the 9.5 px the filter alone would give.
        let lag = crossing(i, lo: 0, hi: iHi, from: 250) - crossing(y, lo: 0, hi: Float(YIQ.forward[0][0]), from: 250)
        XCTAssertEqual(lag, 1, accuracy: 0.75)
        XCTAssertEqual(crossing(y, lo: 0, hi: Float(YIQ.forward[0][0]), from: 250), 299.5, accuracy: 0.01,
                       "the picture does not move: sync rides with Y")
        vhs.colorUnder.delay = 6
        let out6 = try g.run(chain, try g.source { x, _ in x < 300 ? (0, 0, 0) : (255, 0, 0) })
        let lag6 = crossing(out6.row(241, { $0.y }, yiq: true), lo: 0, hi: iHi, from: 250)
            - crossing(out6.row(241, { $0.x }, yiq: true), lo: 0, hi: Float(YIQ.forward[0][0]), from: 250)
        XCTAssertEqual(lag6 - lag, 5, accuracy: 0.1)
    }

    /// Color droop: chroma arrives one field line late, so the first colored line of a field
    /// is colorless and the color runs one field line past the bottom of the area.
    @MainActor
    func testL4DroopDelaysChromaOneFieldLine() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.colorUnder.enabled = true
        vhs.colorUnder.phaseNoiseDegrees = 0
        vhs.colorUnder.verticalBlend = false
        let out = try g.run(chain, try g.source { _, y in (200..<300).contains(y) ? (255, 0, 0) : (0, 0, 0) })
        let iHi = Float(YIQ.forward[1][0])
        XCTAssertLessThan(abs(out.yiq(360, 200).y), 0.01, "first red line of field 0 has no color yet")
        XCTAssertLessThan(abs(out.yiq(360, 201).y), 0.01, "first red line of field 1 has no color yet")
        XCTAssertEqual(out.yiq(360, 202).y, iHi, accuracy: 0.01)
        XCTAssertEqual(out.yiq(360, 300).y, iHi, accuracy: 0.01, "color runs past the bottom")
        XCTAssertEqual(out.yiq(360, 300).x, 0, accuracy: 0.01, "luma does not")
        vhs.colorUnder.droopLines = 0
        let flat = try g.run(chain, try g.source { _, y in (200..<300).contains(y) ? (255, 0, 0) : (0, 0, 0) })
        XCTAssertEqual(flat.yiq(360, 200).y, iHi, accuracy: 0.01)
    }

    // MARK: L5

    /// Two frames of a still differ with the noise on and are identical with it off.
    @MainActor
    func testL5NoiseDiffersFrameToFrameOnlyWhenOn() throws {
        let g = try GPUHarness()
        let src = try g.source { _, _ in (128, 128, 128) }
        let (chain, vhs) = g.vhsChain()
        vhs.outputCard.enabled = true
        let off0 = try g.run(chain, src, frame: 0), off1 = try g.run(chain, src, frame: 1)
        XCTAssertEqual(off0.data, off1.data)
        vhs.noise.enabled = true
        let on0 = try g.run(chain, src, frame: 0), on1 = try g.run(chain, src, frame: 1)
        let diffs = zip(on0.data, on1.data).map { Double($0 - $1) }
        let rms = (diffs.reduce(0) { $0 + $1 * $1 } / Double(diffs.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.001)
        let again = try g.run(chain, src, frame: 1)
        XCTAssertEqual(again.data, on1.data, "noise is reproducible per frame")
    }

    // MARK: L6

    /// A rising luma edge overshoots to its right; the flat part before it is untouched.
    @MainActor
    func testL6OvershootsToTheRightOfAnEdge() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.halo.enabled = true
        vhs.halo.peaking = 0.25
        let lo: Float = 51.0 / 255, hi: Float = 204.0 / 255
        let out = try g.run(chain, try g.source { x, _ in x < 360 ? (51, 51, 51) : (204, 204, 204) })
        let row = out.row(100) { $0.x }
        XCTAssertGreaterThan(row[360..<400].max()!, hi + 0.02)
        for x in 300..<355 { XCTAssertEqual(row[x], lo, accuracy: 1.0 / 255) }
    }

    // MARK: L7

    /// The bottom lines are shifted; the middle lines are not.
    @MainActor
    func testL7ShiftsBottomLinesNotTheMiddle() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.headSwitch.enabled = true
        vhs.headSwitch.noise = 0
        vhs.headSwitch.height = 8
        vhs.headSwitch.maxShift = 72
        let out = try g.run(chain, try g.source { x, _ in x < 200 ? (0, 0, 0) : (255, 255, 255) })
        XCTAssertEqual(crossing(out.row(240) { $0.x }, lo: 0, hi: 1), 199.5, accuracy: 0.01)
        XCTAssertGreaterThan(crossing(out.row(479) { $0.x }, lo: 0, hi: 1), 230)
        XCTAssertGreaterThan(crossing(out.row(478) { $0.x }, lo: 0, hi: 1), 230)
        // Above the band: untouched.
        XCTAssertEqual(crossing(out.row(460) { $0.x }, lo: 0, hi: 1), 199.5, accuracy: 0.01)
    }

    // MARK: L8

    /// Lines move, and by no more than the jitter amplitude (flagging off).
    @MainActor
    func testL8MovesLinesByLessThanItsAmplitude() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.timeBase.enabled = true
        vhs.timeBase.amplitude = 1
        vhs.timeBase.flagAmplitude = 0
        vhs.timeBase.fieldOffset = 0
        let out = try g.run(chain, try g.source { x, _ in x < 360 ? (0, 0, 0) : (255, 255, 255) }, frame: 5)
        let moves = (0..<480).map { abs(crossing(out.row($0) { $0.x }, lo: 0, hi: 1, from: 300) - 359.5) }
        XCTAssertLessThanOrEqual(moves.max()!, 1.0 + 0.02)
        XCTAssertGreaterThan(moves.max()!, 0.05)
    }

    // MARK: L9

    /// Bob rebuilds the even lines from the odd field; weave keeps both; temporal weave takes
    /// the even field from the previous frame.
    @MainActor
    func testL9WeaveBobAndTemporalFields() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.outputCard.enabled = true
        let lines = try g.source { _, y in y & 1 == 0 ? (0, 0, 0) : (255, 255, 255) }
        let weave = try g.run(chain, lines)
        XCTAssertEqual(weave.rgb(100, 100).x, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(weave.rgb(100, 101).x, 1, accuracy: 1.0 / 255)
        vhs.capture.deinterlace = .bob
        let bob = try g.run(chain, lines)
        XCTAssertEqual(bob.rgb(100, 100).x, 1, accuracy: 1.0 / 255)
        XCTAssertEqual(bob.rgb(100, 101).x, 1, accuracy: 1.0 / 255)

        vhs.capture.deinterlace = .weave
        vhs.capture.temporalFields = true
        let black = try g.source { _, _ in (0, 0, 0) }, white = try g.source { _, _ in (255, 255, 255) }
        _ = try g.run(chain, black, frame: 10)
        let moved = try g.run(chain, white, frame: 11)
        XCTAssertEqual(moved.rgb(100, 100).x, 0, accuracy: 1.0 / 255, "even field from the previous frame")
        XCTAssertEqual(moved.rgb(100, 101).x, 1, accuracy: 1.0 / 255, "odd field from this frame")
        let redraw = try g.run(chain, white, frame: 11)
        XCTAssertEqual(redraw.rgb(100, 100).x, 0, accuracy: 1.0 / 255, "a redraw of the same frame keeps it")
    }

    // MARK: Chroma noise order and field asymmetry

    /// Correlation of I between each line and the previous line of its field, on a flat gray.
    private func chromaRowPairCorrelation(_ r: Raster) -> Double {
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for y in stride(from: 40, to: 440, by: 1) {
            for x in stride(from: 40, to: 680, by: 3) {
                let a = Double(r.yiq(x, y).y), b = Double(r.yiq(x, y - 2).y)
                sxy += a * b; sxx += a * a; syy += b * b
            }
        }
        return sxy / (sxx * syy).squareRoot()
    }

    /// With the 1H comb after the noise, chroma noise is paired over lines; without the comb
    /// it is not.
    @MainActor
    func testL5ChromaNoiseIsLinePairedByTheCombAfterIt() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.colorUnder.enabled = true
        vhs.colorUnder.phaseNoiseDegrees = 0
        vhs.colorUnder.droopLines = 0
        vhs.noise.enabled = true
        vhs.noise.chromaSNR = 25
        vhs.noise.wobblePercent = 0
        let src = try g.source { _, _ in (128, 128, 128) }
        let paired = chromaRowPairCorrelation(try g.run(chain, src, frame: 4))
        vhs.colorUnder.verticalBlend = false
        let unpaired = chromaRowPairCorrelation(try g.run(chain, src, frame: 4))
        XCTAssertGreaterThan(paired, 0.35, "comb after the noise: neighbors share half their noise")
        XCTAssertLessThan(abs(unpaired), 0.1)
    }

    /// The second field's noise is stronger by the field multiplier.
    @MainActor
    func testL5SecondFieldIsNoisierByTheMultiplier() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.noise.enabled = true
        vhs.noise.lumaSNR = 30
        let out = try g.run(chain, try g.source { _, _ in (128, 128, 128) }, frame: 7)
        func rms(_ field: Int) -> Double {
            var s = 0.0, n = 0.0
            for y in stride(from: field, to: 480, by: 2) {
                for x in 0..<720 { let d = Double(out.yiq(x, y).x) - 128.0 / 255; s += d * d; n += 1 }
            }
            return (s / n).squareRoot()
        }
        XCTAssertEqual(rms(1) / rms(0), 1.1, accuracy: 0.03)
    }

    /// L8: the second field sits right of the first by the field offset.
    @MainActor
    func testL8OffsetsTheSecondField() {
        let tb = TimeBaseLayer()
        tb.amplitude = 0
        tb.flagAmplitude = 0
        let off = tb.lineOffsets(frame: 3)
        XCTAssertEqual(off[100], 0)
        XCTAssertEqual(off[101], 0.25)
    }

    // MARK: Dropouts

    /// At a high rate some rows carry a run copied from the row two above (the DOC); at rate 0
    /// none do.
    @MainActor
    func testDropoutsCopyThePreviousFieldLine() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.dropouts.enabled = true
        vhs.dropouts.fleckChance = 0
        let src = try g.source { x, y in (UInt8(y / 2), UInt8(x / 3), 90) }
        vhs.dropouts.ratePerMinute = 0
        let ref = try g.run(chain, src, frame: 1)
        func copiedRows(_ r: Raster) -> [Int] {
            (2..<480).filter { y in
                let run = (0..<720).filter { x in r.rgb(x, y) != ref.rgb(x, y) && r.rgb(x, y) == ref.rgb(x, y - 2) }
                return run.count >= 30
            }
        }
        XCTAssertEqual(copiedRows(try g.run(chain, src, frame: 1)), [])
        // About one event in ten lines.
        vhs.dropouts.ratePerMinute = 0.1 * 60 * 59.94 * 240
        let rows = copiedRows(try g.run(chain, src, frame: 1))
        XCTAssertGreaterThan(rows.count, 5)
        let ev = vhs.dropouts.events(frame: 1)
        for y in rows { XCTAssertEqual(ev[y * 4 + 2], 1, "row \(y) has a DOC event") }
        for y in rows { XCTAssertGreaterThanOrEqual(ev[y * 4 + 1] - ev[y * 4], 67) }
    }

    // MARK: Levels

    /// Black lifts by the offset, the white clip is soft and blooms into its neighbors.
    @MainActor
    func testLevelsLiftBlackAndClipWithBloom() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.levels.enabled = true
        vhs.levels.driftIRE = 0
        vhs.levels.pumpingPercent = 0
        let src = try g.source { x, _ in (300..<320).contains(x) ? (255, 255, 255) : (0, 0, 0) }
        let identity = try g.run(chain, src)
        XCTAssertEqual(identity.yiq(100, 100).x, 0, accuracy: 1.0 / 255, "identity by default")
        XCTAssertEqual(identity.yiq(310, 100).x, 1, accuracy: 1.0 / 255)

        vhs.levels.blackIRE = 7.5
        vhs.levels.gain = 1.15
        vhs.levels.clip = true
        let out = try g.run(chain, src)
        XCTAssertEqual(out.yiq(100, 100).x, Float(7.5 / 92.5), accuracy: 1.0 / 255, "black lifted 7.5 IRE")
        XCTAssertLessThanOrEqual(out.yiq(310, 100).x, Float(vhs.levels.clipLevel) + 1.0 / 255, "white clipped")
        XCTAssertGreaterThan(out.yiq(310, 100).x, 1, "but above 1: the clip is at code 255")
        XCTAssertGreaterThan(out.yiq(321, 100).x, out.yiq(100, 100).x + 0.01, "bloom spreads past the edge")
    }

    // MARK: Capture blend

    @MainActor
    func testL9FieldBlendMixesTheFields() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.outputCard.enabled = true
        vhs.capture.deinterlace = .blend
        let out = try g.run(chain, try g.source { _, y in y & 1 == 0 ? (0, 0, 0) : (255, 255, 255) })
        XCTAssertEqual(out.rgb(100, 100).x, 0.5, accuracy: 1.0 / 255)
        XCTAssertEqual(out.rgb(100, 101).x, 0.5, accuracy: 1.0 / 255)
    }

    // MARK: Camera

    /// The camera softens an edge both ways, warms the cast under the Camcorder values, and
    /// darkens the corners.
    @MainActor
    func testCameraSoftensCastsAndVignettes() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        let src = try g.source { x, y in x < 360 && y < 240 ? (60, 60, 60) : (150, 150, 150) }
        let off = try g.run(chain, src)
        vhs.camera.enabled = true
        vhs.camera.toe = 0
        vhs.camera.bloom = 0
        let on = try g.run(chain, src)
        let row = on.row(120) { $0.y }
        XCTAssertGreaterThanOrEqual(transitionWidth(row, lo: row[300], hi: row[420], from: 340), 2, "soft horizontally")
        XCTAssertNotEqual(on.rgb(200, 239).y, off.rgb(200, 239).y, "soft vertically")
        XCTAssertLessThan(on.rgb(700, 470).y, on.rgb(500, 300).y - 0.02, "vignette darkens the corner")
        vhs.camera.vignette = 0
        vhs.camera.crCodes = 5
        vhs.camera.cbCodes = -3
        let warm = try g.run(chain, src)
        XCTAssertGreaterThan(warm.rgb(500, 300).x - warm.rgb(500, 300).z, 0.04, "warm: red over blue on a gray")
    }

    // MARK: Options: moire and the second generation

    /// Moire appears where the luma has HF energy and nowhere on a flat field.
    @MainActor
    func testL3MoireOnlyWhereThereIsDetail() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.luma.enabled = true
        let src = try g.source { x, y in
            if y < 240 { return (128, 128, 128) }
            let v: UInt8 = (x / 3) & 1 == 0 ? 60 : 200
            return (v, v, v)
        }
        let off = try g.run(chain, src)
        vhs.luma.moire = 0.05
        let on = try g.run(chain, src)
        let flat = (100..<600).map { abs(on.rgb($0, 100).x - off.rgb($0, 100).x) }.max()!
        let busy = (100..<600).map { abs(on.rgb($0, 300).x - off.rgb($0, 300).x) }.max()!
        XCTAssertLessThan(flat, 1.0 / 255)
        XCTAssertGreaterThan(busy, 0.02)
    }

    /// A dub runs L3 again: an edge is softer after two generations than after one.
    @MainActor
    func testSecondGenerationSoftensAgain() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.luma.enabled = true
        vhs.luma.emphasis = false
        let src = try g.source { x, _ in x < 360 ? (0, 0, 0) : (255, 255, 255) }
        let one = try g.run(chain, src)
        vhs.generation.enabled = true
        let two = try g.run(chain, src)
        XCTAssertGreaterThan(crossing(two.row(200) { $0.x }, lo: 0, hi: 1, from: 300),
                             crossing(one.row(200) { $0.x }, lo: 0, hi: 1, from: 300) + 0.5, "the second lowpass delays it again")
        XCTAssertGreaterThan(transitionWidth(two.row(200) { $0.x }, lo: 0, hi: 1, from: 300),
                             transitionWidth(one.row(200) { $0.x }, lo: 0, hi: 1, from: 300))
    }

    // MARK: Everything on

    /// The default chain runs and produces finite values near range. The raster is deliberately
    /// not clamped to 0...1: smeared chroma on a saturated edge lands outside the RGB gamut, as
    /// on a real capture, and the exporter needs the unclipped floats to recover the true Y'.
    /// The drawable and the 2vuy code clamp do the clipping at the ends.
    @MainActor
    func testDefaultChainRunsClean() throws {
        let g = try GPUHarness()
        let vhs = VHSLayers()
        let chain = SignalChain(framing: FramingLayer(mode: .fullRaster), effects: vhs.all)
        let out = try g.run(chain, try g.source { x, y in (UInt8(x & 255), UInt8(y & 255), 128) }, frame: 2)
        // The emphasis streak after a full height falling edge undershoots black on purpose.
        XCTAssertTrue(out.data.allSatisfy { $0.isFinite && $0 >= -0.75 && $0 <= 1.75 },
                      "range \(out.data.min()!) to \(out.data.max()!)")
    }
}

// MARK: - Extended strength ranges

/// Every extended strength range: the layer, the parameter, the end of the earlier range on the
/// strong side, and the end of the current one (for an S/N or a clip floor the strong side is
/// the bottom).
let extendedRanges: [(layer: String, parameter: String, old: Double, new: Double)] = [
    ("luma-bandwidth", "moire", 0.1, 0.5),
    ("luma-bandwidth", "smallBoost", 20, 32),
    ("luma-bandwidth", "largeBoost", 20, 32),
    ("luma-bandwidth", "whiteClip", 110, 60),
    ("color-under", "delay", 16, 48),
    ("color-under", "droop", 4, 12),
    ("color-under", "phase", 10, 45),
    ("color-under", "gain", 2, 4),
    ("tape-noise", "luma", 30, 18),
    ("tape-noise", "chroma", 20, 8),
    ("tape-noise", "fieldGain", 2, 4),
    ("tape-noise", "wobble", 20, 60),
    ("edge-halo", "peaking", 1, 4),
    ("edge-halo", "ringPower", 8, 24),
    ("edge-halo", "ringIntensity", 10, 40),
    ("edge-halo", "coring", 10, 30),
    ("head-switch", "height", 24, 96),
    ("head-switch", "shift", 200, 720),
    ("head-switch", "noise", 0.5, 2),
    ("time-base", "amplitude", 4, 16),
    ("time-base", "flagLines", 30, 90),
    ("time-base", "flag", 20, 80),
    ("time-base", "fieldOffset", 2, 8),
    ("dropouts", "rate", 5000, 20000),
    ("levels", "black", 10, 30),
    ("levels", "bloom", 2, 6),
    ("levels", "drift", 4, 16),
    ("levels", "pumping", 5, 20),
    ("camera", "bloom", 2, 6),
    ("camera", "toe", 0.3, 1),
    ("camera", "cb", 20, 60),
    ("camera", "cr", 20, 60),
    ("camera", "vignette", 0.6, 1),
    ("generation", "generation", 4, 6),
]

final class RangeTopTests: XCTestCase {
    @MainActor
    private func value(_ chain: SignalChain, _ layer: String, _ parameter: String) -> Double? {
        chain.layers.first { $0.id == layer }?.parameters.first { $0.id == parameter }?.value.doubleValue
    }

    @MainActor
    private func set(_ chain: SignalChain, _ layer: String, _ parameter: String, _ v: Double) {
        chain.layers.first { $0.id == layer }?.setParameter(parameter, to: .float(v))
    }

    /// The new end is the slider's end and the layer keeps it, with no clamp back to the old one.
    @MainActor
    func testEveryExtendedRangeReachesItsNewEnd() {
        let chain = SignalChain.standard()
        for r in extendedRanges {
            let p = chain.layers.first { $0.id == r.layer }?.parameters.first { $0.id == r.parameter }
            let range = p?.range
            XCTAssertTrue(range?.lowerBound == r.new || range?.upperBound == r.new,
                          "\(r.layer).\(r.parameter) range \(String(describing: range))")
            set(chain, r.layer, r.parameter, r.new)
            XCTAssertEqual(value(chain, r.layer, r.parameter), r.new, "\(r.layer).\(r.parameter)")
            // Past the new end still clamps to it.
            set(chain, r.layer, r.parameter, r.new + (r.new - r.old))
            XCTAssertEqual(value(chain, r.layer, r.parameter), r.new, "\(r.layer).\(r.parameter) past the end")
        }
    }

    /// A sidecar holding a value at the old end reads back unchanged, and one at the new end
    /// round trips: sidecars store raw values, so old files read the same.
    @MainActor
    func testSidecarKeepsTheOldEndAndRoundTripsTheNewEnd() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-ranges-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for atNew in [false, true] {
            let source = SignalChain.standard()
            for r in extendedRanges { set(source, r.layer, r.parameter, atNew ? r.new : r.old) }
            let url = folder.appendingPathComponent("clip-\(atNew ? "new" : "old").homevideo.json")
            try Sidecar.write(chain: source, name: "ranges", lookID: nil, to: url)
            let back = SignalChain.standard()
            try Sidecar.read(url, into: back)
            for r in extendedRanges {
                XCTAssertEqual(value(back, r.layer, r.parameter), atNew ? r.new : r.old,
                               "\(r.layer).\(r.parameter) at the \(atNew ? "new" : "old") end")
            }
        }
    }

    /// Each extended parameter alone at its new end renders finite.
    @MainActor
    func testEachNewEndAloneRendersFinite() throws {
        let g = try GPUHarness()
        for r in extendedRanges {
            let vhs = VHSLayers()
            let chain = SignalChain(framing: FramingLayer(mode: .fullRaster), effects: vhs.all)
            vhs.camera.enabled = r.layer == "camera"
            vhs.generation.enabled = r.layer == "generation"
            vhs.levels.setParameter("clip", to: .bool(true))
            set(chain, r.layer, r.parameter, r.new)
            let out = try g.run(chain, try g.source { x, y in (UInt8(x & 255), UInt8(y & 255), 128) }, frame: 2)
            let bad = out.data.filter { !$0.isFinite }.count
            XCTAssertEqual(bad, 0, "\(r.layer).\(r.parameter)")
        }
    }

    /// Every extended parameter at its new end at once, with and without five dubs, renders
    /// finite. The dubs compound the gains to about 15700, still under half float's 65504.
    @MainActor
    func testEveryNewEndAtOnceRendersFinite() throws {
        let g = try GPUHarness()
        for (label, only) in [("all but dubs", nil), ("dubs alone", "generation"), ("all with dubs", "")] as [(String, String?)] {
            let vhs = VHSLayers()
            let chain = SignalChain(framing: FramingLayer(mode: .fullRaster), effects: vhs.all)
            vhs.camera.enabled = true
            vhs.generation.enabled = only != nil
            vhs.levels.setParameter("clip", to: .bool(true))
            for r in extendedRanges where only == nil || only == "" || r.layer == only {
                set(chain, r.layer, r.parameter, r.new)
            }
            let out = try g.run(chain, try g.source { x, y in (UInt8(x & 255), UInt8(y & 255), 128) }, frame: 2)
            let bad = out.data.filter { !$0.isFinite }.count
            XCTAssertEqual(bad, 0, "\(label), min \(out.data.min()!) max \(out.data.max()!)")
        }
    }
}
