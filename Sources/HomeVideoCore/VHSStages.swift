import Foundation
import Metal
import Observation

// More of the chain: the frame around the picture,
// dropouts and the compensator, the capture levels, and the camcorder ahead of the deck.
// Same style as VHSLayers.swift: CPU side parameters and per line randomness, kernels in
// Shaders/VHS.metal.

/// Y units per IRE: the working Y runs 0 to 1 from setup black (7.5 IRE) to white (100 IRE).
let yPerIRE = 1.0 / 92.5

/// Fields per second and lines per field of the 480 line raster.
let fieldsPerSecond = 59.94
let fieldLines = SignalChain.rasterHeight / 2

// MARK: - Frame: blanking and H offset

/// The frame around the picture. The capture card digitizes 720 samples of a line whose
/// active picture is shorter, so blanking shows at the sides, and a recording is often
/// shifted left a little, which makes the right bar the wider one. Some captures also show a
/// few dark rows at the top. Runs before L3 and L4, so the bar edges soften and pick up the
/// chroma lag like the picture does.
///
/// Defaults measured on four digitized home tapes, at 720: the right bar is 14 to 17
/// px on every tape, so 17. A left bar (12 to 14) and 5 dark top rows show only on the two
/// 1991 tapes, so they default to 0 and the Camcorder source preset sets 15 and 5.
@MainActor
@Observable
public final class FrameLayer: Layer {
    public let id = "frame"
    public let name = "Frame (blanking, H offset)"
    public var enabled = true
    public var leftBar = 0.0
    public var rightBar = 17.0
    /// Samples the picture moves left inside the window (the recording's H shift).
    public var offset = 2.0
    /// Top rows blanked to black.
    public var topRows = 0.0
    static let barRange = 0.0...32.0
    static let offsetRange = 0.0...6.0
    static let topRange = 0.0...12.0
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "left", name: "Left bar (px)", value: .float(leftBar), range: Self.barRange),
            LayerParameter(id: "right", name: "Right bar (px)", value: .float(rightBar), range: Self.barRange),
            LayerParameter(id: "offset", name: "H offset (px)", value: .float(offset), range: Self.offsetRange),
            LayerParameter(id: "top", name: "Top dark rows", value: .float(topRows), range: Self.topRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        guard case .float(let v) = value else { return }
        switch id {
        case "left": leftBar = clamped(v, Self.barRange).rounded()
        case "right": rightBar = clamped(v, Self.barRange).rounded()
        case "offset": offset = clamped(v, Self.offsetRange)
        case "top": topRows = clamped(v, Self.topRange).rounded()
        default: break
        }
    }

    /// The window [left, right) in output samples.
    func window(width: Int = SignalChain.rasterWidth) -> (left: Double, right: Double) {
        (leftBar, Double(width) - rightBar)
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("frame_blanking", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let w = window(width: output.width)
        enc.label = "Frame blanking"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        setFloats(enc, [Float(w.left), Float(w.right), Float(offset), Float(topRows)], index: 0)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

// MARK: - Dropouts and the compensator

/// Dropouts: a speck of missing oxide drops the FM carrier for 5 to 25 us. The deck's
/// dropout compensator (DOC) fills the gap with the same span of the previous line of the
/// same field from its 1H delay, so the dropout reads as a short misplaced smear. Now and
/// then the DOC misses one and a raw white fleck shows. Events are Bernoulli per field line
/// at the rate per minute (a Poisson process at these rates). Runs after L5, on the playback
/// signal.
///
/// Rates: "two or three" a minute on very good tape (US patent 3,525,930, for broadcast
/// tape), up to 25 a minute in Sony's allowance for half inch tape, so 3 here and 25 under
/// Worn.
@MainActor
@Observable
public final class DropoutLayer: Layer {
    public let id = "dropouts"
    public let name = "Dropouts (with compensator)"
    public var enabled = true
    public var ratePerMinute = 3.0
    /// Share of dropouts the compensator misses (a raw white fleck).
    public var fleckChance = 0.1
    /// Up to 20000 a minute (about 11 a frame): oxide shedding off a
    /// chewed tape, and a way to see the DOC.
    static let rateRange = 0.0...20000.0
    static let fleckRange = 0.0...1.0
    /// 5 to 25 us at 13.5 MHz.
    static let lengthRange = 67.0...340.0
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "rate", name: "Rate (per minute)", value: .float(ratePerMinute), range: Self.rateRange),
            LayerParameter(id: "fleck", name: "Missed by DOC", value: .float(fleckChance), range: Self.fleckRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        guard case .float(let v) = value else { return }
        switch id {
        case "rate": ratePerMinute = clamped(v, Self.rateRange)
        case "fleck": fleckChance = clamped(v, Self.fleckRange)
        default: break
        }
    }

    /// Per raster line: (start px, end px, kind 0 none, 1 DOC copy, 2 white fleck, unused).
    func events(frame: UInt32, width: Int = SignalChain.rasterWidth,
                lines: Int = SignalChain.rasterHeight) -> [Float] {
        let p = ratePerMinute / 60 / fieldsPerSecond / Double(fieldLines)
        var out = [Float](repeating: 0, count: lines * 4)
        guard p > 0 else { return out }
        for y in 0..<lines {
            func u(_ k: UInt32) -> Double { (Hash.signed(vhsSeed, k, frame, UInt32(y)) + 1) / 2 }
            guard u(91) < p else { continue }
            let length = Self.lengthRange.lowerBound + u(93) * (Self.lengthRange.upperBound - Self.lengthRange.lowerBound)
            let start = u(92) * Double(width) - length / 2
            out[y * 4] = Float(start)
            out[y * 4 + 1] = Float(start + length)
            out[y * 4 + 2] = u(94) < fleckChance ? 2 : 1
        }
        return out
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("dropouts", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "Dropouts"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        setFloats(enc, events(frame: frame.frame32, width: output.width, lines: output.height), index: 0)
        var p: [UInt32] = [vhsSeed, frame.frame32]
        enc.setBytes(&p, length: p.count * 4, index: 1)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

// MARK: - Levels

/// The capture levels: a black offset (setup left in or taken out, or a faded tape's lift),
/// a gain, a soft white clip whose clipped excess blooms a few px, a slow per field black
/// drift and a per field gain wander (AGC pumping). Runs last before L9, in YIQ.
///
/// Defaults: identity for the static levels, since a clean SP capture sits where the source
/// does. The Camcorder source sets gain 1.15 with the clip at code 255 (Y 1.091), Aged sets a
/// +19 code black lift (8 IRE). Drift and pumping default small (0.5 IRE, 1 percent,
/// INFERRED: no published figure).
@MainActor
@Observable
public final class LevelsLayer: Layer {
    public let id = "levels"
    public let name = "Levels (black, gain, clip, drift)"
    public var enabled = true
    public var blackIRE = 0.0
    public var gain = 1.0
    public var clip = false
    public var clipLevel = codeToY(255)
    public var bloom = 0.5
    public var driftIRE = 0.5
    public var pumpingPercent = 1.0
    /// The strength tops: black lift to 30 IRE (a tape so faded its blacks sit at dark gray),
    /// bloom to 6, black drift to 16 IRE (the picture breathing light and dark over seconds),
    /// AGC pumping to 20 percent (a gain riding hard on every field).
    static let blackRange = -4.0...30.0
    static let gainRange = 0.5...1.5
    static let clipRange = 0.8...1.2
    static let bloomRange = 0.0...6.0
    static let driftRange = 0.0...16.0
    static let pumpingRange = 0.0...20.0
    /// Width of the soft knee under the clip, Y.
    static let softness = 0.08
    /// Bloom radius, px.
    static let bloomRadius = 3
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    /// An 8 bit studio code (16 black, 235 white) as working Y.
    public static func codeToY(_ code: Double) -> Double { (code - 16) / 219 }

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "black", name: "Black offset (IRE)", value: .float(blackIRE), range: Self.blackRange),
            LayerParameter(id: "gain", name: "Gain", value: .float(gain), range: Self.gainRange),
            LayerParameter(id: "clip", name: "White clip", value: .bool(clip)),
            LayerParameter(id: "clipLevel", name: "Clip level (Y)", value: .float(clipLevel), range: Self.clipRange,
                           isActive: clip),
            LayerParameter(id: "bloom", name: "Bloom", value: .float(bloom), range: Self.bloomRange, isActive: clip),
            LayerParameter(id: "drift", name: "Black drift (IRE)", value: .float(driftIRE), range: Self.driftRange),
            LayerParameter(id: "pumping", name: "AGC pumping (%)", value: .float(pumpingPercent),
                           range: Self.pumpingRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("black", .float(let v)): blackIRE = clamped(v, Self.blackRange)
        case ("gain", .float(let v)): gain = clamped(v, Self.gainRange)
        case ("clip", .bool(let b)): clip = b
        case ("clipLevel", .float(let v)): clipLevel = clamped(v, Self.clipRange)
        case ("bloom", .float(let v)): bloom = clamped(v, Self.bloomRange)
        case ("drift", .float(let v)): driftIRE = clamped(v, Self.driftRange)
        case ("pumping", .float(let v)): pumpingPercent = clamped(v, Self.pumpingRange)
        default: break
        }
    }

    /// Black (Y) and gain for each field of one frame: the static values plus slow value
    /// noise over field time (drift over about 4 s, pumping over about half a second).
    func fieldLevels(frame: UInt64) -> (black: [Float], gain: [Float]) {
        var black: [Float] = [], gains: [Float] = []
        for field in 0..<2 {
            let t = Double(frame) * 2 + Double(field)
            let d = driftIRE * Hash.valueNoise(t / 240, 0, seed: vhsSeed &+ 101)
            let g = pumpingPercent / 100 * Hash.valueNoise(t / 30, 0, seed: vhsSeed &+ 102)
            black.append(Float((blackIRE + d) * yPerIRE))
            gains.append(Float(gain * (1 + g)))
        }
        return (black, gains)
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("levels", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let (black, gains) = fieldLevels(frame: frame.frameIndex)
        enc.label = "Levels"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        setFloats(enc, black + gains + [clip ? Float(clipLevel) : 0, Float(Self.softness), Float(bloom),
                                        Float(Self.bloomRadius)], index: 0)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

// MARK: - Camera

/// The camcorder ahead of the deck, in the RGB the framing writes: a soft lens and tube or
/// CCD (a Gaussian lowpass both ways), exposure with a soft highlight clip whose excess
/// blooms, a toe that crushes the blacks, the white balance (a Cb and Cr shift and a hue
/// turn), and a lens vignette. Off by default. The "Camcorder" source preset turns it on.
///
/// Defaults, measured on digitized home tapes: the soft focus is -3 dB at 1.6 MHz, so
/// Camcorder plus SP lands at the sharpest tape's -10 dB point. The cast is 0 here and the
/// Camcorder preset sets a 1986 tape's tungsten balance (Cb -3, Cr +5 codes, hue -15
/// degrees). Bloom, toe and vignette are INFERRED, by eye against stills from those tapes.
@MainActor
@Observable
public final class CameraLayer: Layer {
    public let id = "camera"
    public let name = "Camera (camcorder source)"
    public var enabled = false
    public var focusMHz = 1.6
    public var exposureStops = 0.0
    public var bloom = 0.6
    public var toe = 0.04
    public var cbCodes = 0.0
    public var crCodes = 0.0
    public var hueDegrees = 0.0
    public var vignette = 0.15
    static let focusRange = 0.8...6.75
    static let exposureRange = -2.0...2.0
    /// The strength tops: bloom to 6 (highlights glowing over their neighbors), black crush to
    /// 1 (the shadows gone to black), white balance to 60 codes either way (a camcorder left on
    /// its daylight setting indoors or the reverse), vignette to 1 (the corners at black, as far
    /// as the lens model goes).
    static let bloomRange = 0.0...6.0
    static let toeRange = 0.0...1.0
    static let castRange = -60.0...60.0
    static let hueRange = -45.0...45.0
    static let vignetteRange = 0.0...1.0
    /// The gather radius, px. It covers the soft focus Gaussian down to 0.8 MHz and the bloom.
    static let radius = 3
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        [
            LayerParameter(id: "focus", name: "Soft focus (MHz, -3 dB)", value: .float(focusMHz), range: Self.focusRange),
            LayerParameter(id: "exposure", name: "Exposure (stops)", value: .float(exposureStops),
                           range: Self.exposureRange),
            LayerParameter(id: "bloom", name: "Highlight bloom", value: .float(bloom), range: Self.bloomRange),
            LayerParameter(id: "toe", name: "Black crush", value: .float(toe), range: Self.toeRange),
            LayerParameter(id: "cb", name: "White balance Cb (codes)", value: .float(cbCodes), range: Self.castRange),
            LayerParameter(id: "cr", name: "White balance Cr (codes)", value: .float(crCodes), range: Self.castRange),
            LayerParameter(id: "hue", name: "Hue (deg)", value: .float(hueDegrees), range: Self.hueRange),
            LayerParameter(id: "vignette", name: "Vignette", value: .float(vignette), range: Self.vignetteRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        guard case .float(let v) = value else { return }
        switch id {
        case "focus": focusMHz = clamped(v, Self.focusRange)
        case "exposure": exposureStops = clamped(v, Self.exposureRange)
        case "bloom": bloom = clamped(v, Self.bloomRange)
        case "toe": toe = clamped(v, Self.toeRange)
        case "cb": cbCodes = clamped(v, Self.castRange)
        case "cr": crCodes = clamped(v, Self.castRange)
        case "hue": hueDegrees = clamped(v, Self.hueRange)
        case "vignette": vignette = clamped(v, Self.vignetteRange)
        default: break
        }
    }

    /// Gaussian sigma (px) whose response is -3 dB at `mhz`: exp(-2 pi^2 s^2 f^2) = 1/sqrt 2.
    static func sigma(forMHz mhz: Double) -> Double {
        let f = Filters.normalized(mhz: mhz)
        return (log(2) / 2).squareRoot() / (Double.pi * f) / 2.0.squareRoot()
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("camera", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "Camera"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        let h = hueDegrees * .pi / 180
        // Studio codes: Cb and Cr span 224 codes over -0.5...0.5.
        setFloats(enc, [Float(Self.sigma(forMHz: focusMHz)), Float(pow(2, exposureStops)), Float(bloom), Float(toe),
                        Float(cbCodes / 224), Float(crCodes / 224), Float(cos(h)), Float(sin(h)),
                        Float(vignette), Float(Self.radius)], index: 0)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

// MARK: - Second generation

/// A dub: the played back signal recorded onto a second tape and played again, so L3 to L8
/// run twice, the second time with fresh noise, dropouts and jitter. The second emphasis
/// clip acts on edges that already carry streaks, so they compound. Off by default. Its private
/// copies of L3 to L8 take the
/// main layers' parameters and toggles on every frame, so the second pass is the same deck.
/// `generation` is the copy you watch: 2 is one dub (the default), 3 a dub of a dub, each
/// further pass on the same deck with its own noise.
@MainActor
@Observable
public final class GenerationLayer: Layer {
    public let id = "generation"
    public let name = "Second generation (dub)"
    public var enabled = false
    public var generation = 2.0
    /// To 6: five dubs in a row. Each pass runs the deck again, so
    /// the top costs about five chains of GPU time.
    static let generationRange = 2.0...6.0

    @ObservationIgnored let pairs: [(source: any Layer, copy: any Layer)]
    @ObservationIgnored private var scratch: [MTLTexture] = []

    init(luma: LumaBandwidthLayer, colorUnder: ColorUnderLayer, noise: TapeNoiseLayer, dropouts: DropoutLayer,
         halo: EdgeHaloLayer, headSwitch: HeadSwitchLayer, timeBase: TimeBaseLayer) {
        let l = LumaBandwidthLayer(), c = ColorUnderLayer(), n = TapeNoiseLayer()
        n.lumaCutMHz = { l.cutMHz }
        n.chromaCutKHz = { c.cutKHz }
        n.comb = { c.enabled && c.verticalBlend }
        c.combInPlayback = { n.enabled }
        let h = EdgeHaloLayer()
        h.lumaCutMHz = { l.cutMHz }
        pairs = [(luma, l), (colorUnder, c), (noise, n), (dropouts, DropoutLayer()), (halo, h),
                 (headSwitch, HeadSwitchLayer()), (timeBase, TimeBaseLayer())]
    }

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "generation", name: "Generation", value: .float(generation), range: Self.generationRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        guard id == "generation", case .float(let v) = value else { return }
        generation = clamped(v, Self.generationRange).rounded()
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        for p in pairs { try p.copy.prepare(device: device, library: library) }
        scratch = try (0..<2).map { try makeRasterTexture(device: device, label: "dub \($0)") }
    }

    /// Copies every toggle and parameter from the main layers.
    func sync() {
        for p in pairs {
            p.copy.enabled = p.source.enabled
            for param in p.source.parameters { p.copy.setParameter(param.id, to: param.value) }
        }
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        sync()
        let active = pairs.map(\.copy).filter(\.enabled)
        guard !active.isEmpty, scratch.count == 2 else {
            guard let b = commandBuffer.makeBlitCommandEncoder() else { return }
            b.copy(from: input, to: output)
            b.endEncoding()
            return
        }
        let passes = max(1, Int(generation) - 1)
        let steps = passes * active.count
        var current = input
        for k in 0..<steps {
            var ctx = frame
            // A different frame number reseeds every hash, so each dub's noise is its own.
            ctx.frameIndex = frame.frameIndex &+ 0x5EED_0000 &* UInt64(k / active.count + 1)
            let out = k == steps - 1 ? output : scratch[k & 1]
            active[k % active.count].encode(commandBuffer: commandBuffer, in: current, out: out, frame: ctx)
            current = out
        }
    }
}
