import Foundation
import Metal
import Observation

// The VHS chain, L1 to L9 of docs/SIGNAL-CHAIN.md, in signal path order. Between L1 and L9
// the working textures hold YIQ (Y in r, I in g, Q in b). Kernels live in Shaders/VHS.metal.

/// Seed for every hashed noise source; one constant so preview and export agree.
let vhsSeed: UInt32 = 0x5241_4400

/// VHS tape speed and the bandwidth figures it sets (ntsc-rs's tuned values, see the spec).
public enum TapeSpeed: String, CaseIterable, Sendable {
    case sp, lp, ep

    public var label: String { rawValue.uppercased() }
    public var lumaCutMHz: Double { [2.4, 1.9, 1.4][index] }
    public var chromaCutKHz: Double { [320, 300, 280][index] }

    private var index: Int { TapeSpeed.allCases.firstIndex(of: self)! }

    static var options: [LayerParameter.Option] { allCases.map { .init(value: $0.rawValue, label: $0.label) } }
}

// MARK: - Helpers

func makePipeline(_ name: String, device: MTLDevice, library: MTLLibrary) throws -> MTLComputePipelineState {
    guard let fn = library.makeFunction(name: name) else {
        throw ShaderLibrary.LoadError.noLibrary("kernel '\(name)'")
    }
    return try device.makeComputePipelineState(function: fn)
}

/// A raster sized RGBA16Float texture a layer owns for its own intermediate passes.
func makeRasterTexture(device: MTLDevice, label: String) throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                     width: SignalChain.rasterWidth,
                                                     height: SignalChain.rasterHeight,
                                                     mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = .private
    guard let t = device.makeTexture(descriptor: d) else {
        throw ShaderLibrary.LoadError.noLibrary("could not allocate \(label)")
    }
    t.label = label
    return t
}

/// Dispatches a per line kernel: one thread per line, each walking its line left to right.
/// Small threadgroups spread the 480 lines across the compute units.
func dispatchLines(_ enc: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, lines: Int) {
    let tg = min(32, pipeline.maxTotalThreadsPerThreadgroup)
    enc.dispatchThreadgroups(MTLSize(width: (lines + tg - 1) / tg, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
}

func setFloats(_ enc: MTLComputeCommandEncoder, _ values: [Float], index: Int) {
    values.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: max($0.count, 4), index: index) }
}

func clamped(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }

extension FrameContext {
    var frame32: UInt32 { UInt32(truncatingIfNeeded: frameIndex) }
}

// MARK: - L1 Output card

/// L1: the output card's RGB to YIQ conversion, the domain change into the VHS stage.
/// Forced on (and its toggle locked) whenever any layer between L1 and L9 is on; on its own
/// it only exists to prove the L1 then L9 round trip.
@MainActor
@Observable
public final class OutputCardLayer: Layer {
    public let id = "output-card"
    public let name = "L1 Output card (RGB to YIQ)"
    public var userEnabled = false
    @ObservationIgnored var isNeeded: @MainActor () -> Bool = { false }
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var enabled: Bool {
        get { userEnabled || isNeeded() }
        set { userEnabled = newValue }
    }
    public var isRequired: Bool { isNeeded() }
    public var parameters: [LayerParameter] { [] }
    public func setParameter(_ id: String, to value: ParameterValue) {}

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("yiq_encode", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "L1 RGB to YIQ"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        setFloats(enc, YIQ.floats(YIQ.forward), index: 0)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

// MARK: - L2 Composite link

public enum Separator: String, CaseIterable, Sendable {
    case notch, comb1, comb2
    public var label: String { ["Notch", "1-line comb", "2-line comb"][index] }
    var index: Int { Separator.allCases.firstIndex(of: self)! }
    static var options: [LayerParameter.Option] { allCases.map { .init(value: $0.rawValue, label: $0.label) } }
}

/// L2: a composite cable instead of S-Video. Chroma is modulated on the 3.58 MHz subcarrier
/// (running phase at 13.5 MHz sampling, inverting line to line and frame to frame), summed
/// with luma, then separated by a notch or a comb and demodulated. Off by default. The
/// capture card's own separator in L9 reuses this pass.
@MainActor
@Observable
public final class CompositeLinkLayer: Layer {
    public let id = "composite-link"
    public let name = "L2 Composite link"
    public var enabled = false
    public var separator: Separator = .notch
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    /// Subcarrier in cycles per sample.
    static let fsc = 3.579545 / Filters.sampleRateMHz
    /// The decoder's chroma bandwidth after demodulation (I's 1.3 MHz, used for both).
    static let chromaDemodMHz = 1.3
    /// comb2 keeps only the comb's band above this split as chroma (INFERRED, the band-split
    /// comb of better TVs and decks). Chroma sits at 3.58 MHz plus or minus 1.3. The split is
    /// two 3rd order Butterworths in series, which at 2.2 MHz leak 5 percent of the chroma
    /// back into luma at 3.58 MHz. comb1 stays full band as the cheaper design.
    static let combSplitMHz = 2.2

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "separator", name: "Separator", value: .choice(separator.rawValue),
                        options: Separator.options)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        if id == "separator", case .choice(let raw) = value, let s = Separator(rawValue: raw) { separator = s }
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("composite_link", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        encodePass(commandBuffer: commandBuffer, in: input, out: output, frame: frame, separator: separator)
    }

    func encodePass(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                    frame: FrameContext, separator: Separator) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "Composite link"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        var p: [UInt32] = [Float(CompositeLinkLayer.fsc).bitPattern, UInt32(separator.index), frame.frame32]
        enc.setBytes(&p, length: p.count * 4, index: 0)
        let sections = [Filters.notch(center: CompositeLinkLayer.fsc, q: 1),
                        Filters.lowpass2(cutoff: Filters.normalized(mhz: CompositeLinkLayer.chromaDemodMHz))]
            + Filters.butterworth3(cutoff: Filters.normalized(mhz: CompositeLinkLayer.combSplitMHz))
            + Filters.butterworth3(cutoff: Filters.normalized(mhz: CompositeLinkLayer.combSplitMHz))
        setFloats(enc, Filters.floats(sections), index: 1)
        dispatchLines(enc, pipeline: pipeline, lines: output.height)
        enc.endEncoding()
    }
}

// MARK: - L3 Luma bandwidth

/// L3: the luma FM record path. With emphasis on (the default): a nonlinear pre-emphasis,
/// the FM deviation's white and dark clip, the tape's lowpass, and the playback de-emphasis.
/// Without it, the lowpass alone: a causal 3rd order Butterworth on Y per line at the luma cut.
///
/// Emphasis figures (US patent 4,597,021): small signals get up to 13 dB of HF boost, large
/// ones less (the nonlinear emphasis), and the boosted signal is clipped where the FM carrier
/// would leave its deviation range: white clip 5.3 MHz and dark clip 2.9 MHz against sync tip
/// 3.4 and white 4.4 MHz, at 140 IRE per MHz, so 226 IRE and -110 IRE. The shelf corner
/// (0.5 MHz) and the large signal boost (8 dB) are INFERRED, and the de-emphasis time constant
/// that falls out of them is about 1.3 us, the VHS figure. A big edge's clipped overshoot
/// comes back through the de-emphasis as a streak to its right (dark after a rise into white,
/// light after a fall into black). Small detail is untouched.
@MainActor
@Observable
public final class LumaBandwidthLayer: Layer {
    public let id = "luma-bandwidth"
    public let name = "L3 Luma record (emphasis, clip, bandwidth)"
    public var enabled = true
    public var speed: TapeSpeed = .sp
    public var cutMHz = TapeSpeed.sp.lumaCutMHz
    public var emphasis = true
    public var smallBoostDB = 13.0
    public var largeBoostDB = 8.0
    public var whiteClipIRE = 226.0
    public var darkClipIRE = -110.0
    /// FM moire: the folded lower sideband's beat on high frequency luma, an option, default
    /// off (amplitude INFERRED).
    public var moire = 0.0
    /// To 0.5: a beat of half the Y range on fine detail, a badly misaligned deck whose lower
    /// sideband folds deep into the luma band.
    static let moireRange = 0.0...0.5
    /// To 5.5 MHz so the slider reaches S-VHS (5.0 MHz, docs/LOOKS.md). The Butterworth runs at
    /// 13.5 MHz sampling, so 5.5 MHz is still 0.41 of the sample rate, under Nyquist.
    static let cutRange = 1.0...5.5
    /// To 32 dB, an HF gain of 40x, so every edge runs into the deviation clip and streaks.
    static let boostRange = 0.0...32.0
    /// Down to 60 IRE: a deviation so narrow that midtones clip,
    /// so the streak after an edge starts well below white.
    static let whiteClipRange = 60.0...300.0
    static let darkClipRange = -200.0...0.0
    /// Shelf corner of the emphasis, MHz.
    static let emphasisCornerMHz = 0.5
    /// Envelope level (Y, of the HF part) where the boost is halfway from small to large.
    static let emphasisKnee = 0.06
    /// Width of the soft knee under each clip, Y units.
    static let clipSoftness = 0.3
    @ObservationIgnored private var lowpass: MTLComputePipelineState?
    @ObservationIgnored private var record: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "speed", name: "Tape speed", value: .choice(speed.rawValue), options: TapeSpeed.options),
            LayerParameter(id: "cut", name: "Luma cut (MHz)", value: .float(cutMHz), range: Self.cutRange),
            LayerParameter(id: "emphasis", name: "Emphasis and clip", value: .bool(emphasis)),
            LayerParameter(id: "smallBoost", name: "Small signal boost (dB)", value: .float(smallBoostDB),
                           range: Self.boostRange, isActive: emphasis),
            LayerParameter(id: "largeBoost", name: "Large signal boost (dB)", value: .float(largeBoostDB),
                           range: Self.boostRange, isActive: emphasis),
            LayerParameter(id: "whiteClip", name: "White clip (IRE)", value: .float(whiteClipIRE),
                           range: Self.whiteClipRange, isActive: emphasis),
            LayerParameter(id: "darkClip", name: "Dark clip (IRE)", value: .float(darkClipIRE),
                           range: Self.darkClipRange, isActive: emphasis),
            LayerParameter(id: "moire", name: "FM moire", value: .float(moire), range: Self.moireRange,
                           isActive: emphasis),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("speed", .choice(let raw)):
            if let s = TapeSpeed(rawValue: raw) { speed = s; cutMHz = s.lumaCutMHz }
        case ("cut", .float(let v)): cutMHz = clamped(v, Self.cutRange)
        case ("emphasis", .bool(let b)): emphasis = b
        case ("smallBoost", .float(let v)): smallBoostDB = clamped(v, Self.boostRange)
        case ("largeBoost", .float(let v)): largeBoostDB = clamped(v, Self.boostRange)
        case ("whiteClip", .float(let v)): whiteClipIRE = clamped(v, Self.whiteClipRange)
        case ("darkClip", .float(let v)): darkClipIRE = clamped(v, Self.darkClipRange)
        case ("moire", .float(let v)): moire = clamped(v, Self.moireRange)
        default: break
        }
    }

    var sections: [Biquad] { Filters.butterworth3(cutoff: Filters.normalized(mhz: cutMHz)) }

    /// The emphasis uniforms, in EmphasisParams order.
    var emphasisFloats: [Float] {
        let c = 1 - exp(-2 * Double.pi * Filters.normalized(mhz: Self.emphasisCornerMHz))
        func boost(_ db: Double) -> Double { pow(10, db / 20) - 1 }
        func y(_ ire: Double) -> Double { (ire - 7.5) * yPerIRE }
        return [c, boost(smallBoostDB), boost(largeBoostDB), Self.emphasisKnee, 0.5, 0.12,
                y(whiteClipIRE), y(darkClipIRE), Self.clipSoftness, moire].map(Float.init)
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        lowpass = try makePipeline("luma_lowpass", device: device, library: library)
        record = try makePipeline("luma_record", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline = emphasis ? record : lowpass, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = emphasis ? "L3 luma record" : "L3 luma lowpass"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        setFloats(enc, Filters.floats(sections), index: 0)
        if emphasis { setFloats(enc, emphasisFloats + [Float(bitPattern: frame.frame32)], index: 1) }
        dispatchLines(enc, pipeline: pipeline, lines: output.height)
        enc.endEncoding()
    }
}

// MARK: - L4 Color-under chroma

/// L4: color-under. Causal 2nd order Butterworth on I and Q at the chroma cut, a horizontal
/// chroma delay, a vertical delay (color droop), the playback 1H comb's vertical blend with
/// the previous line of the same field, a slow per line hue error from the color-under PLL,
/// and a chroma gain.
///
/// Y/C timing: the chroma filter's own group delay (about 9.5 px at 320 kHz) would put chroma
/// far behind luma. Real decks equalize it with a Y delay line and regenerate sync with Y, so
/// the picture does not move. Here chroma is read ahead by that group delay instead (a
/// per pixel gather on the filtered line), and the net lag is the explicit delay, default 1
/// px (Worn 2): captures of four home tapes measure 0.3 to 1.2 px. The comb runs in L5 after
/// the noise when L5 is on,
/// so the noise comes out line paired as it does from a real deck. Chroma gain 0.8 is the
/// Aged deck (two faded tapes measure 0.70 of our saturation).
@MainActor
@Observable
public final class ColorUnderLayer: Layer {
    public let id = "color-under"
    public let name = "L4 Color-under chroma"
    public var enabled = true
    public var speed: TapeSpeed = .sp
    public var cutKHz = TapeSpeed.sp.chromaCutKHz
    public var delay = 1.0
    public var droopLines = 1.0
    public var verticalBlend = true
    public var phaseNoiseDegrees = 1.0
    public var gain = 1.0
    static let cutRange = 100.0...1000.0
    /// The strength tops. Delay to 48 px (3.6 us, a deck whose Y delay line is badly out),
    /// droop to 12 field lines, phase noise to 45 degrees (a PLL that barely holds lock, hue
    /// swinging from red toward green), gain to 4 (a chroma AGC stuck at full gain).
    static let delayRange = 0.0...48.0
    static let droopRange = 0.0...12.0
    static let phaseRange = 0.0...45.0
    static let gainRange = 0.0...4.0
    /// True when L5 runs the comb after its noise (set by `VHSLayers`).
    @ObservationIgnored var combInPlayback: @MainActor () -> Bool = { false }
    @ObservationIgnored private var lowpass: MTLComputePipelineState?
    @ObservationIgnored private var gather: MTLComputePipelineState?
    @ObservationIgnored private var scratch: MTLTexture?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "speed", name: "Tape speed", value: .choice(speed.rawValue), options: TapeSpeed.options),
            LayerParameter(id: "cut", name: "Chroma cut (kHz)", value: .float(cutKHz), range: Self.cutRange),
            LayerParameter(id: "delay", name: "Chroma delay (px)", value: .float(delay), range: Self.delayRange),
            LayerParameter(id: "droop", name: "Color droop (lines)", value: .float(droopLines), range: Self.droopRange),
            LayerParameter(id: "blend", name: "Vertical blend (1H comb)", value: .bool(verticalBlend)),
            LayerParameter(id: "phase", name: "Phase noise (deg)", value: .float(phaseNoiseDegrees), range: Self.phaseRange),
            LayerParameter(id: "gain", name: "Chroma gain", value: .float(gain), range: Self.gainRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("speed", .choice(let raw)):
            if let s = TapeSpeed(rawValue: raw) { speed = s; cutKHz = s.chromaCutKHz }
        case ("cut", .float(let v)): cutKHz = clamped(v, Self.cutRange)
        case ("delay", .float(let v)): delay = clamped(v, Self.delayRange)
        case ("droop", .float(let v)): droopLines = clamped(v, Self.droopRange).rounded()
        case ("blend", .bool(let b)): verticalBlend = b
        case ("phase", .float(let v)): phaseNoiseDegrees = clamped(v, Self.phaseRange)
        case ("gain", .float(let v)): gain = clamped(v, Self.gainRange)
        default: break
        }
    }

    var sections: [Biquad] { [Filters.lowpass2(cutoff: Filters.normalized(mhz: cutKHz / 1000))] }

    /// Group delay at DC of `sections`, in samples: sum k b_k / sum b_k - sum k a_k / sum a_k.
    static func groupDelay(_ sections: [Biquad]) -> Double {
        sections.reduce(0) { d, c in
            d + (c.b1 + 2 * c.b2) / (c.b0 + c.b1 + c.b2) - (c.a1 + 2 * c.a2) / (1 + c.a1 + c.a2)
        }
    }

    /// Where a unit step crosses one half after `sections`, in samples: the delay an edge
    /// center actually sees, which is what the Y/C equalization must cancel. For a second
    /// order Butterworth this is about 1.17 / omega_c, 17 percent under the DC group delay
    /// (sqrt 2 / omega_c). Equalizing on the group delay leaves chroma 0.66 px left of luma
    /// on color bars. On the step center the net lag is the explicit delay.
    static func stepCenter(_ sections: [Biquad], samples: Int = 256) -> Double {
        var x = [Double](repeating: 1, count: samples)
        var y = [Double](repeating: 0, count: samples)
        for c in sections {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<samples {
                let out = c.b0 * x[i] + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                x2 = x1; x1 = x[i]; y2 = y1; y1 = out; y[i] = out
            }
            x = y
        }
        for i in 1..<samples where y[i] >= 0.5 {
            let f = (0.5 - y[i - 1]) / (y[i] - y[i - 1])
            return Double(i - 1) + f
        }
        return groupDelay(sections)
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        lowpass = try makePipeline("chroma_lowpass", device: device, library: library)
        gather = try makePipeline("chroma_delay_blend", device: device, library: library)
        scratch = try makeRasterTexture(device: device, label: "L4 scratch")
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let lowpass, let gather, let scratch, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "L4 color-under"
        enc.setComputePipelineState(lowpass)
        enc.setTexture(input, index: 0)
        enc.setTexture(scratch, index: 1)
        setFloats(enc, Filters.floats(sections), index: 0)
        dispatchLines(enc, pipeline: lowpass, lines: output.height)

        enc.setComputePipelineState(gather)
        enc.setTexture(input, index: 0)
        enc.setTexture(scratch, index: 1)
        enc.setTexture(output, index: 2)
        let blendHere = verticalBlend && !combInPlayback()
        var p: [UInt32] = [Float(delay).bitPattern, blendHere ? 1 : 0,
                           Float(phaseNoiseDegrees * .pi / 180).bitPattern, vhsSeed, frame.frame32,
                           Float(Self.stepCenter(sections)).bitPattern, UInt32(droopLines), Float(gain).bitPattern]
        enc.setBytes(&p, length: p.count * 4, index: 0)
        dispatch2D(enc, pipeline: gather, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

// MARK: - L5 Tape noise

/// L5: tape and head noise. Luma: white noise, first differenced (FM noise rises with
/// frequency), then the L3 lowpass. Chroma: white noise through the L4 chroma lowpass, so it
/// is coarse and streaky. Fresh per frame and per field.
///
/// Unit mapping: S/N is the in band RMS of the shaped noise against the 0 to 1 Y range (the
/// way a deck's video S/N is measured, after its filters), so the white amplitude sent to
/// the shader is divided by the shaping filter's noise gain. Measured before shaping, 45 dB
/// would leave the grain far under one 8 bit step.
///
/// Chroma S/N defaults to 45 dB (Worn 38), the second head's
/// field is noisier by `fieldGain` (1.1, INFERRED: "one field with a much different SNR"),
/// and L4's 1H comb runs here after the noise, so chroma noise comes out paired over lines
/// and vertically streaky (the "mist"), with a per line saturation wobble. The comb halves
/// the noise power it averages, so the chroma amplitude is raised by sqrt 2 when it runs,
/// keeping the S/N figure what a deck's output measures.
@MainActor
@Observable
public final class TapeNoiseLayer: Layer {
    public let id = "tape-noise"
    public let name = "L5 Tape noise"
    public var enabled = true
    public var lumaSNR = 45.0
    public var chromaSNR = 45.0
    public var fieldGain = 1.1
    public var wobblePercent = 3.0
    /// S/N is noisier as it falls, so the strength end is the bottom: luma down to 18 dB and
    /// chroma down to 8 dB. 18 dB luma is about 16x the noise power of a worn EP tape (30 dB).
    static let lumaRange = 18.0...60.0
    static let chromaRange = 8.0...60.0
    /// To 4: one head four times noisier than the other, a clogged head.
    static let fieldGainRange = 1.0...4.0
    /// To 60 percent: the saturation swings by more than half from line to line.
    static let wobbleRange = 0.0...60.0
    /// The shaping filters follow L3's and L4's cuts.
    @ObservationIgnored var lumaCutMHz: @MainActor () -> Double = { TapeSpeed.sp.lumaCutMHz }
    @ObservationIgnored var chromaCutKHz: @MainActor () -> Double = { TapeSpeed.sp.chromaCutKHz }
    /// L4's comb, when L4 is on with its vertical blend (set by `VHSLayers`).
    @ObservationIgnored var comb: @MainActor () -> Bool = { false }
    @ObservationIgnored private var pipeline: MTLComputePipelineState?
    @ObservationIgnored private var combPipeline: MTLComputePipelineState?
    @ObservationIgnored private var scratch: MTLTexture?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "luma", name: "Luma S/N (dB)", value: .float(lumaSNR), range: Self.lumaRange),
            LayerParameter(id: "chroma", name: "Chroma S/N (dB)", value: .float(chromaSNR), range: Self.chromaRange),
            LayerParameter(id: "fieldGain", name: "Second field noise (x)", value: .float(fieldGain),
                           range: Self.fieldGainRange),
            LayerParameter(id: "wobble", name: "Saturation wobble (%)", value: .float(wobblePercent),
                           range: Self.wobbleRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("luma", .float(let v)): lumaSNR = clamped(v, Self.lumaRange)
        case ("chroma", .float(let v)): chromaSNR = clamped(v, Self.chromaRange)
        case ("fieldGain", .float(let v)): fieldGain = clamped(v, Self.fieldGainRange)
        case ("wobble", .float(let v)): wobblePercent = clamped(v, Self.wobbleRange)
        default: break
        }
    }

    /// White amplitude for a uniform -1...1 source (std 1/sqrt 3) to give `snr` dB after `sections`.
    static func amplitude(snr: Double, sections: [Biquad], difference: Bool) -> Double {
        let gain = Filters.noiseGain(sections, difference: difference)
        return pow(10, -snr / 20) * 3.0.squareRoot() / max(gain, 1e-9)
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("tape_noise", device: device, library: library)
        combPipeline = try makePipeline("chroma_comb", device: device, library: library)
        scratch = try makeRasterTexture(device: device, label: "L5 before the comb")
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let combPipeline, let scratch,
              let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let combs = comb()
        let second = combs || wobblePercent > 0
        let luma = Filters.butterworth3(cutoff: Filters.normalized(mhz: lumaCutMHz()))
        let chroma = [Filters.lowpass2(cutoff: Filters.normalized(mhz: chromaCutKHz() / 1000))]
        let ya = Self.amplitude(snr: lumaSNR, sections: luma, difference: true)
        let ca = Self.amplitude(snr: chromaSNR, sections: chroma, difference: false) * (combs ? 2.0.squareRoot() : 1)
        enc.label = "L5 tape noise"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(second ? scratch : output, index: 1)
        var p: [UInt32] = [Float(ya).bitPattern, Float(ca).bitPattern, vhsSeed, frame.frame32,
                           Float(fieldGain).bitPattern]
        enc.setBytes(&p, length: p.count * 4, index: 0)
        setFloats(enc, Filters.floats(luma + chroma), index: 1)
        dispatchLines(enc, pipeline: pipeline, lines: output.height)
        if second {
            enc.setComputePipelineState(combPipeline)
            enc.setTexture(scratch, index: 0)
            enc.setTexture(output, index: 1)
            var c: [UInt32] = [combs ? 1 : 0, Float(wobblePercent / 100).bitPattern, vhsSeed, frame.frame32]
            enc.setBytes(&c, length: c.count * 4, index: 0)
            dispatch2D(enc, pipeline: combPipeline, width: output.width, height: output.height)
        }
        enc.endEncoding()
    }
}

// MARK: - L6 Edge halo

/// L6: de-emphasis overshoot and the deck's detail enhancer, then ringing, then the noise
/// canceller's coring. Per line, causal.
///
/// Unit mapping for the ringing (ntsc-rs's frequency 0.45, power 4, intensity 4, whose units
/// are its own): ring frequency is a fraction of the luma cut, so 0.45 puts the notch at
/// 1.08 MHz in SP; power is the notch's Q (4: a ring that decays by 1/e in about 16 px);
/// intensity scales the mix toward the notched signal by 0.05 per unit, so 4 is a 0.2 mix,
/// an echo of a few percent of the edge height.
@MainActor
@Observable
public final class EdgeHaloLayer: Layer {
    public let id = "edge-halo"
    public let name = "L6 Edge halo"
    public var enabled = true
    /// Default 0 since the L3 emphasis clip carries the halo; Worn keeps some sharpness.
    public var peaking = 0.0
    public var ringFrequency = 0.45
    public var ringPower = 4.0
    public var ringIntensity = 4.0
    public var coringPercent = 2.0
    /// The canceller cores detail above this fraction of the luma cut. At 1.0 it meets only
    /// the noise L3 has not already removed. At 0.5 (1.2 MHz in SP) it also flattens small
    /// texture into mush, while big edges keep their excess (INFERRED).
    public var coringSplit = 0.5
    static let splitRange = 0.25...1.0
    /// The strength tops: peaking to 4 (a sharpness knob turned past its end, every edge
    /// outlined), ring Q to 24 (a ring lasting about 50 px), ring intensity to 40 (a mix of 2
    /// past the notched signal, an echo as tall as the edge), canceller coring to 30 percent
    /// of Y (all fine texture flattened into wax).
    static let peakingRange = 0.0...4.0
    static let frequencyRange = 0.2...1.0
    static let powerRange = 0.5...24.0
    static let intensityRange = 0.0...40.0
    static let coringRange = 0.0...30.0
    static let intensityToMix = 0.05
    @ObservationIgnored var lumaCutMHz: @MainActor () -> Double = { TapeSpeed.sp.lumaCutMHz }
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "peaking", name: "Peaking", value: .float(peaking), range: Self.peakingRange),
            LayerParameter(id: "ringFrequency", name: "Ring frequency (x luma cut)", value: .float(ringFrequency),
                           range: Self.frequencyRange),
            LayerParameter(id: "ringPower", name: "Ring power (Q)", value: .float(ringPower), range: Self.powerRange),
            LayerParameter(id: "ringIntensity", name: "Ring intensity", value: .float(ringIntensity),
                           range: Self.intensityRange),
            LayerParameter(id: "coring", name: "Noise canceller (% of Y)", value: .float(coringPercent),
                           range: Self.coringRange),
            LayerParameter(id: "coringSplit", name: "Canceller band (x luma cut)", value: .float(coringSplit),
                           range: Self.splitRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        guard case .float(let v) = value else { return }
        switch id {
        case "peaking": peaking = clamped(v, Self.peakingRange)
        case "ringFrequency": ringFrequency = clamped(v, Self.frequencyRange)
        case "ringPower": ringPower = clamped(v, Self.powerRange)
        case "ringIntensity": ringIntensity = clamped(v, Self.intensityRange)
        case "coring": coringPercent = clamped(v, Self.coringRange)
        case "coringSplit": coringSplit = clamped(v, Self.splitRange)
        default: break
        }
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("edge_halo", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let cut = Filters.normalized(mhz: lumaCutMHz())
        let lp = Filters.butterworth3(cutoff: cut)
        let split = Filters.butterworth3(cutoff: cut * coringSplit)
        let sections = lp + [Filters.notch(center: cut * ringFrequency, q: ringPower)] + split
        enc.label = "L6 edge halo"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        setFloats(enc, [Float(peaking), Float(ringIntensity * Self.intensityToMix), Float(coringPercent / 100)],
                  index: 0)
        setFloats(enc, Filters.floats(sections), index: 1)
        dispatchLines(enc, pipeline: pipeline, lines: output.height)
        enc.endEncoding()
    }
}

// MARK: - L7 Head switch

/// L7: the head switch, 6.5 lines before vertical sync, in each field's bottom lines. The
/// band's lines are shifted right by shift_max * ((i + offset) / height)^1.5 plus jitter, the
/// first visible band line only from its mid-line start, with a decaying transient at the
/// start of each shifted span and a noise burst. Per field: heights count field lines, so
/// 3 visible field lines are 6 raster lines of the woven frame.
///
/// Defaults: captures of four home tapes show 0, 12, 18 and 0 rows of band, so 3 visible
/// lines per field (height 6, 3 hidden) with a 24 px shift. Worn keeps a big band, 12
/// visible lines and 120 px. The noise burst is the "Tracking noise" switch, 0 (off) by
/// default.
@MainActor
@Observable
public final class HeadSwitchLayer: Layer {
    public let id = "head-switch"
    public let name = "L7 Head switch"
    public var enabled = true
    public var height = 6.0
    public var offset = 3.0
    public var maxShift = 24.0
    public var midLineStart = 0.95
    public var noise = 0.0
    /// The strength tops: height to 96 field lines (the band climbing to 40 percent of the
    /// picture, a deck badly out of tracking), shift to 720 px (a full line, the band torn off
    /// the right edge), noise burst to 2 (a band of solid snow).
    static let heightRange = 1.0...96.0
    static let offsetRange = 0.0...8.0
    static let shiftRange = 0.0...720.0
    static let midRange = 0.5...1.0
    static let noiseRange = 0.0...2.0
    /// Per line jitter on the shift (px) and on the mid-line start (fraction of the width).
    static let shiftJitter = 2.0
    static let startJitter = 0.03
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "height", name: "Height (field lines)", value: .float(height), range: Self.heightRange),
            LayerParameter(id: "offset", name: "Hidden lines", value: .float(offset), range: Self.offsetRange),
            LayerParameter(id: "shift", name: "Max shift (px)", value: .float(maxShift), range: Self.shiftRange),
            LayerParameter(id: "mid", name: "Mid-line start", value: .float(midLineStart), range: Self.midRange),
            LayerParameter(id: "noise", name: "Noise burst", value: .float(noise), range: Self.noiseRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        guard case .float(let v) = value else { return }
        switch id {
        case "height": height = clamped(v, Self.heightRange).rounded()
        case "offset": offset = clamped(v, Self.offsetRange).rounded()
        case "shift": maxShift = clamped(v, Self.shiftRange)
        case "mid": midLineStart = clamped(v, Self.midRange)
        case "noise": noise = clamped(v, Self.noiseRange)
        default: break
        }
    }

    /// Per raster line shift (px, 0 outside the band) and start (px), for one frame.
    func lineShifts(frame: UInt32, width: Int = SignalChain.rasterWidth,
                    lines: Int = SignalChain.rasterHeight) -> (shift: [Float], start: [Float]) {
        var shift = [Float](repeating: 0, count: lines)
        var start = [Float](repeating: 0, count: lines)
        let h = Int(height), off = Int(offset)
        let visible = max(0, h - off)
        let fieldLines = lines / 2
        for field in 0..<2 {
            for i in 0..<min(visible, fieldLines) {
                let y = (fieldLines - visible + i) * 2 + field
                let t = Double(i + off) / Double(max(h, 1))
                let jitter = Self.shiftJitter * Hash.signed(vhsSeed, 71, frame, UInt32(field), UInt32(i))
                shift[y] = Float(max(maxShift * pow(t, 1.5) + jitter, 0.001))
                if i == 0 {
                    let s = midLineStart + Self.startJitter * Hash.signed(vhsSeed, 72, frame, UInt32(field))
                    start[y] = Float(min(max(s, 0), 1) * Double(width))
                }
            }
        }
        return (shift, start)
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("head_switch", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let (shift, start) = lineShifts(frame: frame.frame32, width: output.width, lines: output.height)
        enc.label = "L7 head switch"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        // Transient: half the line's shift again at the start of the span, decaying over 32 px.
        var p: [UInt32] = [Float(noise).bitPattern, Float(0.5).bitPattern, Float(32).bitPattern,
                           vhsSeed, frame.frame32]
        enc.setBytes(&p, length: p.count * 4, index: 0)
        setFloats(enc, shift, index: 1)
        setFloats(enc, start, index: 2)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

// MARK: - L8 Time base

/// L8: no TBC. Each line's start wanders by a smooth 2D value noise over (field line, field
/// time), two octaves, plus a flagging lean over each field's first lines.
@MainActor
@Observable
public final class TimeBaseLayer: Layer {
    public let id = "time-base"
    public let name = "L8 Time base"
    public var enabled = true
    public var amplitude = 0.5
    public var flagLines = 8.0
    public var flagAmplitude = 2.0
    /// The second head's lines sit this far right of the first's (INFERRED, 0.25 px), a
    /// faint static combing in weave.
    public var fieldOffset = 0.25
    /// The strength tops: jitter to 16 px (a stretched tape on a deck with no TBC, verticals
    /// visibly wavy), flagging over 90 field lines (the top third of the picture), flagging
    /// lean to 80 px (a tape played on a VCR with the wrong back tension), second field offset
    /// to 8 px (a heavy static comb on every vertical).
    static let amplitudeRange = 0.0...16.0
    static let flagLinesRange = 0.0...90.0
    static let flagRange = 0.0...80.0
    static let fieldOffsetRange = 0.0...8.0
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "amplitude", name: "Jitter (px)", value: .float(amplitude), range: Self.amplitudeRange),
            LayerParameter(id: "flagLines", name: "Flagging lines", value: .float(flagLines), range: Self.flagLinesRange),
            LayerParameter(id: "flag", name: "Flagging (px)", value: .float(flagAmplitude), range: Self.flagRange),
            LayerParameter(id: "fieldOffset", name: "Second field offset (px)", value: .float(fieldOffset),
                           range: Self.fieldOffsetRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        guard case .float(let v) = value else { return }
        switch id {
        case "amplitude": amplitude = clamped(v, Self.amplitudeRange)
        case "flagLines": flagLines = clamped(v, Self.flagLinesRange).rounded()
        case "flag": flagAmplitude = clamped(v, Self.flagRange)
        case "fieldOffset": fieldOffset = clamped(v, Self.fieldOffsetRange)
        default: break
        }
    }

    /// Per raster line offset in px for one frame.
    /// |offset| <= amplitude + flagAmplitude + fieldOffset.
    func lineOffsets(frame: UInt64, lines: Int = SignalChain.rasterHeight) -> [Float] {
        (0..<lines).map { y in
            let field = y & 1, fl = Double(y >> 1)
            let t = Double(frame) * 2 + Double(field)
            let n = (Hash.valueNoise(fl / 24, t / 6, seed: vhsSeed &+ 81)
                     + 0.5 * Hash.valueNoise(fl / 12, t / 3, seed: vhsSeed &+ 82)) / 1.5
            var off = amplitude * n + (field == 1 ? fieldOffset : 0)
            if fl < flagLines {
                let r = 1 - fl / flagLines
                off += flagAmplitude * r * r
            }
            return Float(off)
        }
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("time_base", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "L8 time base"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        setFloats(enc, lineOffsets(frame: frame.frameIndex, lines: output.height), index: 0)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

// MARK: - L9 Capture

public enum Deinterlace: String, CaseIterable, Sendable {
    case weave, bob, blend
    public var label: String { rawValue.capitalized }
    var index: UInt32 { UInt32(Deinterlace.allCases.firstIndex(of: self)!) }
    static var options: [LayerParameter.Option] { allCases.map { .init(value: $0.rawValue, label: $0.label) } }
}

/// L9: the capture card. Optional composite separation (the L2 pass with the card's own
/// separator), YIQ to RGB (the exact inverse of L1), clip, then the deinterlace: weave, bob
/// of the second field, or a field blend (each line half its own and a quarter of each
/// neighbor, the capture software's "blend"). With temporal fields on, weave takes the even lines from the
/// previous source frame, so motion combs as in a real capture.
///
/// Runs exactly when L1 runs, so its toggle follows L1's and is locked.
@MainActor
@Observable
public final class CaptureLayer: Layer {
    public let id = "capture"
    public let name = "L9 Capture (YIQ to RGB, fields)"
    public let isRequired = true
    public var composite = false
    public var separator: Separator = .notch
    public var deinterlace: Deinterlace = .weave
    public var temporalFields = false

    @ObservationIgnored let outputCard: OutputCardLayer
    @ObservationIgnored let link = CompositeLinkLayer()
    @ObservationIgnored private var pipeline: MTLComputePipelineState?
    @ObservationIgnored private var scratch: MTLTexture?
    @ObservationIgnored private var history: MTLTexture?
    @ObservationIgnored private var pending: MTLTexture?
    @ObservationIgnored private var historyFrame: UInt64?

    public init(outputCard: OutputCardLayer) {
        self.outputCard = outputCard
    }

    public var enabled: Bool {
        get { outputCard.enabled }
        set { _ = newValue }
    }

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "composite", name: "Composite input", value: .bool(composite)),
            LayerParameter(id: "separator", name: "Card separator", value: .choice(separator.rawValue),
                           options: Separator.options, isActive: composite),
            LayerParameter(id: "deinterlace", name: "Deinterlace", value: .choice(deinterlace.rawValue),
                           options: Deinterlace.options),
            LayerParameter(id: "temporal", name: "Temporal fields", value: .bool(temporalFields),
                           isActive: deinterlace == .weave),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("composite", .bool(let b)): composite = b
        case ("separator", .choice(let raw)): if let s = Separator(rawValue: raw) { separator = s }
        case ("deinterlace", .choice(let raw)): if let d = Deinterlace(rawValue: raw) { deinterlace = d }
        case ("temporal", .bool(let b)): temporalFields = b
        default: break
        }
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("capture_fields", device: device, library: library)
        try link.prepare(device: device, library: library)
        scratch = try makeRasterTexture(device: device, label: "L9 composite")
        history = try makeRasterTexture(device: device, label: "L9 previous frame")
        pending = try makeRasterTexture(device: device, label: "L9 current frame")
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let scratch, var history, var pending else { return }
        var source = input
        if composite {
            link.encodePass(commandBuffer: commandBuffer, in: input, out: scratch, frame: frame, separator: separator)
            source = scratch
        }
        let temporal = temporalFields && deinterlace == .weave
        if temporal {
            if historyFrame == nil {
                blit(commandBuffer, from: source, to: history)
            } else if historyFrame != frame.frameIndex {
                // A new source frame: the last one rendered becomes the previous frame.
                swap(&history, &pending)
                self.history = history
                self.pending = pending
            }
            historyFrame = frame.frameIndex
        } else {
            historyFrame = nil
        }
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "L9 capture"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(history, index: 1)
        enc.setTexture(output, index: 2)
        setFloats(enc, YIQ.floats(YIQ.inverse), index: 0)
        // clampRGB stays 0: the raster keeps unclipped floats so the exporter can take the true
        // Y' and chroma from them (a capture card digitizes Y'CbCr before any gamut clip). The
        // preview's bgra8Unorm drawable and the 2vuy code clamp do the clipping at the ends.
        var p: [UInt32] = [deinterlace.index, temporal ? 1 : 0, 0]
        enc.setBytes(&p, length: p.count * 4, index: 1)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
        if temporal { blit(commandBuffer, from: source, to: pending) }
    }

    /// Forgets the previous frame; the next temporal weave starts from its own frame.
    public func reset() {
        historyFrame = nil
    }

    private func blit(_ cb: MTLCommandBuffer, from: MTLTexture, to: MTLTexture) {
        guard let b = cb.makeBlitCommandEncoder() else { return }
        b.copy(from: from, to: to)
        b.endEncoding()
    }
}

// MARK: - The chain

/// L1 to L9 built and wired: L1 is forced on whenever a layer between it and L9 is on, L9
/// follows L1, and L5 and L6 follow L3's and L4's cuts.
@MainActor
public struct VHSLayers {
    public let outputCard = OutputCardLayer()
    public let frame = FrameLayer()
    public let compositeLink = CompositeLinkLayer()
    public let luma = LumaBandwidthLayer()
    public let colorUnder = ColorUnderLayer()
    public let noise = TapeNoiseLayer()
    public let halo = EdgeHaloLayer()
    public let headSwitch = HeadSwitchLayer()
    public let timeBase = TimeBaseLayer()
    public let osd = OSDLayer()
    public let dropouts = DropoutLayer()
    public let levels = LevelsLayer()
    public let camera = CameraLayer()
    public let generation: GenerationLayer
    public let capture: CaptureLayer
    /// The Damage pass's picture layers (DamageLayers.swift), off unless switched on.
    public let damage = DamageLayers()
    /// The Tape stage's switch (TapeStage.swift), on by default. Off, `all` does not run.
    public let tape = TapeStageLayer()
    /// The Film source (FilmLayers.swift), off unless its master switch is on. Not in `all`.
    public let film = FilmLayers()
    /// The Telecine stage (TelecineLayers.swift), between the Film and the tape, off
    /// unless its master switch and the Film are on. Not in `all`.
    public let telecine = TelecineLayers()
    /// The Display stage's layers (CRTLayers.swift), after the capture, off unless switched on.
    /// Not in `all`: they run at the Display size after the chain, and the Looks leave them be.
    public let crt = CRTLayers()
    /// The Re-capture stage's layers (RecaptureLayers.swift), a camera filming the Display's
    /// screen. Not in `all`, off unless its switch and a CRT layer are on.
    public let recapture = RecaptureLayers()
    /// The file's size (OutputSize.swift), Auto unless picked on the Look tab. Not in `all`
    /// and not in `saved`: like Framing it is the clip's, so the sidecar carries it beside
    /// Framing and a Look or a preset never sets it.
    public let output = OutputSizeLayer()

    public init() {
        capture = CaptureLayer(outputCard: outputCard)
        generation = GenerationLayer(luma: luma, colorUnder: colorUnder, noise: noise, dropouts: dropouts,
                                     halo: halo, headSwitch: headSwitch, timeBase: timeBase)
        let middle = self.middle
        outputCard.isNeeded = { middle.contains { $0.enabled } }
        let luma = luma, colorUnder = colorUnder, noise = noise
        osd.speed = { luma.speed }
        noise.lumaCutMHz = { luma.cutMHz }
        noise.chromaCutKHz = { colorUnder.cutKHz }
        noise.comb = { colorUnder.enabled && colorUnder.verticalBlend }
        colorUnder.combInPlayback = { noise.enabled }
        halo.lumaCutMHz = { luma.cutMHz }
        damage.clog.lumaSNR = { noise.lumaSNR }
        damage.crease.speed = { luma.speed }
    }

    /// The layers between L1 and L9. The frame (blanking) is first: the output card emits it
    /// with the picture. The Damage layers follow the link into the deck and come before L3:
    /// the damage is on the tape, so the playback stages from the luma bandwidth on
    /// soften it like the picture. Dropouts follow the tape noise (playback, where the DOC
    /// acts). The VCR on-screen display comes after playback: the deck adds it to its output,
    /// so it reaches the capture card but not the tape. Levels are the capture card's, last.
    public var middle: [any Layer] {
        [frame, compositeLink] + damage.all
            + [luma, colorUnder, noise, dropouts, halo, headSwitch, timeBase, generation, osd, levels]
    }

    /// In signal order, for `SignalChain.effects`. The camera works on the RGB source, before
    /// the output card's conversion, so it does not need L1.
    public var all: [any Layer] { [camera, outputCard] + middle + [capture] }

    /// What a Look sets and reads back: `all`, the Tape switch, then the Film layers, then the
    /// Telecine's. The Display and the camera are set apart (`Looks.applyDisplay`).
    public var lookLayers: [any Layer] { all + [tape] + film.all + telecine.all }

    /// Every layer a file can name: the Look's, then the Display stage's, then the Re-capture
    /// stage's.
    public var saved: [any Layer] { lookLayers + crt.all + recapture.all }

    /// What a sidecar or a preset writes: `all`, the Tape switch only while it is off, the
    /// Film layers or the Telecine's only once they are moved from their defaults (a file
    /// that leaves them unused matches one written before they existed), then the Display and
    /// Re-capture stages.
    public var savedLayers: [any Layer] {
        all + (tape.enabled ? [] : [tape]) + (film.isAtDefault ? [] : film.all)
            + (telecine.isAtDefault ? [] : telecine.all) + crt.all + recapture.all
    }

    /// True when the picture goes through the Telecine stage: its switch on. With the Film on
    /// the film is transferred, with it off the framed source is, as if the clip were the film.
    public var telecineInUse: Bool { telecine.isOn }

    /// True when the picture reaching the tape is the Film or a transfer, not a camcorder's,
    /// so the tape chain's Camera does not run.
    public var replacesCamera: Bool { film.isOn || telecineInUse }

    /// The stages in the path's order, each a switch the chain asks "is it on": Film
    /// (the source), Telecine, Tape, Display, Re-capture. Re-capture needs the Display, as the
    /// sidebar says.
    public var stagesOn: (film: Bool, telecine: Bool, tape: Bool, display: Bool, recapture: Bool) {
        (film.isOn, telecineInUse, tape.enabled, crt.isOn, recaptureIsOn)
    }

    /// Folds the Film output choice an older file carries (Scan, Tape, Telecine) into the
    /// stage switches once a file, the clipboard or `--set` has been read: with the Film on,
    /// Scan is the film with no tape and no transfer, so it loads as Tape off and Telecine off,
    /// and Tape loads as Telecine off. Telecine needs nothing, the stage's own switch routes
    /// the film. With the Film off the old choice does nothing.
    public func foldLegacyFilmOutput() {
        guard let old = film.legacyOutput else { return }
        film.legacyOutput = nil
        guard film.isOn else { return }
        switch old {
        case .scan:
            tape.enabled = false
            telecine.source.enabled = false
        case .tape:
            telecine.source.enabled = false
        case .telecine:
            break
        }
    }

    /// True when the camera films the screen: the Re-capture switch on and a CRT layer on.
    public var recaptureIsOn: Bool { recapture.stage.enabled && crt.isOn }

    /// Every layer off, the conversion included: the chain is Framing alone.
    public func allOff() {
        outputCard.userEnabled = false
        camera.enabled = false
        for l in middle { l.enabled = false }
    }
}
