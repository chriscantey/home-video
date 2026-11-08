import Foundation
import Metal
import Observation

// The Display stage: what a consumer NTSC tube does to the light after the capture. Six
// layers, each a named mechanism with its figures in docs/CRT.md, each off by default, no Look
// turns one on.
//
// A triad on a TV is about one source pixel wide and 480 scanlines fill a 480 line raster, so
// the mask and the gaps between lines need more output pixels than the raster has. With any
// CRT layer on, the stage draws the 720 by 480 raster onto its own 4:3 canvas at the Display
// size (960 by 720, 1440 by 1080 the default, 2880 by 2160), and the preview and the export use
// that canvas. With all six off the stage does not run and the raster goes out as the chain made it.
//
// The stage works in linear light: Transfer decodes the signal with the tube's gamma (2.2,
// the encode, when Transfer is off, so nothing else moves the tone), the beam, the mask and the
// glow act on light, and Glass encodes with 1/2.2 for the file or the screen the canvas lands
// on. Nothing in the stage is random. The interlace alternates its brighter field on the frame
// number, so a render repeats exactly.

/// A layer of the Display stage. Not in `VHSLayers.all`: the stage runs after the chain, at
/// the Display size, and only the Looks that film the screen set or read these layers.
@MainActor
public protocol CRTLayer: Layer {}

public extension CRTLayer {
    func prepare(device: MTLDevice, library: MTLLibrary) throws {}
    /// The stage's `CRTRenderer` runs the kernels for every CRT layer at once, so a layer's
    /// own encode is never called by the chain.
    func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                frame: FrameContext) {}
}

/// The canvas the Display stage draws, always 4:3 with square pixels.
public enum DisplaySize: String, CaseIterable, Sendable {
    case small = "960x720"
    case standard = "1440x1080"
    case large = "2880x2160"

    public var width: Int {
        switch self {
        case .small: return 960
        case .standard: return 1440
        case .large: return 2880
        }
    }
    public var height: Int { width * 3 / 4 }
    /// The Detail's names: how fine the tube is drawn, never the file's size. The raw values
    /// stay for files.
    public var label: String {
        switch self {
        case .small: return "Standard"
        case .standard: return "High"
        case .large: return "Max"
        }
    }
}

// MARK: - Display size

/// The Display stage's canvas size, kept as a layer so a sidecar, a preset and the clipboard
/// carry it like any value. Its switch reads on when any CRT layer is on and cannot be set.
@MainActor
@Observable
public final class CRTDisplayLayer: CRTLayer {
    public let id = "crt-display"
    public let name = "Display"
    public let isRequired = true
    public var size: DisplaySize = .standard
    @ObservationIgnored var anyOn: () -> Bool = { false }

    public init() {}

    public var enabled: Bool {
        get { anyOn() }
        set { _ = newValue }
    }

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "size", name: "Detail", value: .choice(size.rawValue),
                        options: DisplaySize.allCases.map { .init(value: $0.rawValue, label: $0.label) })]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        if id == "size", case .choice(let c) = value, let s = DisplaySize(rawValue: c) { size = s }
    }
}

// MARK: - 1 Transfer

/// The tube's transfer: the signal was encoded for a 2.2 display (System M), a consumer tube
/// decodes it at 2.35 to 2.55 (READ, en.wikipedia "Gamma correction"), crt-royale's crt_gamma
/// is 2.5 (READ). Black lift is the brightness knob set a little high (INFERRED, 0 to 3
/// percent). The white point: SMPTE C's white is D65, 6500 K, NTSC-J recommends 9300 K and US
/// consumer sets shipped bluer than 6500 K (READ, en.wikipedia "Color temperature"), so the
/// default is 9300 K. The phosphors are SMPTE C (READ, en.wikipedia "NTSC"), the primaries the
/// export is tagged with, so no primaries matrix is needed: the white point is the change.
@MainActor
@Observable
public final class CRTTransferLayer: CRTLayer {
    public let id = "crt-transfer"
    public let name = "Transfer (gamma, white point)"
    public var enabled = false
    public var gamma = 2.5
    public var blackLift = 0.01
    public var whiteKelvin = 9300.0

    public static let gammaRange = 2.2...2.6
    public static let liftRange = 0.0...0.03
    public static let kelvinRange = 6500.0...9300.0
    /// System M's encoding gamma, the decode with Transfer off.
    public static let encodeGamma = 2.2

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "gamma", name: "Display gamma", value: .float(gamma), range: Self.gammaRange),
         LayerParameter(id: "lift", name: "Black lift", value: .float(blackLift), range: Self.liftRange),
         LayerParameter(id: "white", name: "White point (K)", value: .float(whiteKelvin), range: Self.kelvinRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("gamma", .float(let v)): gamma = clamped(v, Self.gammaRange)
        case ("lift", .float(let v)): blackLift = clamped(v, Self.liftRange)
        case ("white", .float(let v)): whiteKelvin = clamped(v, Self.kelvinRange)
        default: break
        }
    }

    /// The gun gains that move SMPTE C's D65 white to `kelvin` on the CIE daylight locus,
    /// scaled so the strongest gun is at 1 (the tube cannot drive past full). 6500 K is 1, 1, 1.
    public nonisolated static func whiteGains(kelvin: Double) -> SIMD3<Double> {
        let rgb = WhitePoint.rgb(of: WhitePoint.daylight(kelvin)), ref = WhitePoint.rgb(of: WhitePoint.daylight(6504))
        let g = rgb / ref
        return g / max(g.x, g.y, g.z)
    }
}

/// CIE daylight chromaticity and SMPTE C's RGB, for the Transfer layer's white point.
enum WhitePoint {
    /// SMPTE C primaries and D65 white, xy (READ, en.wikipedia "NTSC").
    static let primaries: [(Double, Double)] = [(0.63, 0.34), (0.31, 0.595), (0.155, 0.07)]
    static let d65 = (0.3127, 0.3290)

    /// The CIE daylight locus, x and y for a correlated color temperature of 4000 to 25000 K.
    static func daylight(_ t: Double) -> (Double, Double) {
        let x = t <= 7000
            ? -4.6070e9 / (t * t * t) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063
            : -2.0064e9 / (t * t * t) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040
        return (x, -3 * x * x + 2.870 * x - 0.275)
    }

    static func xyz(_ p: (Double, Double)) -> SIMD3<Double> { SIMD3(p.0 / p.1, 1, (1 - p.0 - p.1) / p.1) }

    /// The RGB to XYZ matrix's columns, scaled so RGB 1, 1, 1 is D65.
    static var columns: [SIMD3<Double>] {
        let c = primaries.map(xyz)
        let s = solve(c, xyz(d65))
        return [c[0] * s.x, c[1] * s.y, c[2] * s.z]
    }

    /// The SMPTE C RGB of a white of chromaticity `p` (Y 1).
    static func rgb(of p: (Double, Double)) -> SIMD3<Double> { solve(columns, xyz(p)) }

    /// Solves the 3 by 3 system with columns `c` for `b`, by Cramer's rule.
    static func solve(_ c: [SIMD3<Double>], _ b: SIMD3<Double>) -> SIMD3<Double> {
        func det(_ a: SIMD3<Double>, _ e: SIMD3<Double>, _ f: SIMD3<Double>) -> Double {
            a.x * (e.y * f.z - e.z * f.y) - e.x * (a.y * f.z - a.z * f.y) + f.x * (a.y * e.z - a.z * e.y)
        }
        let d = det(c[0], c[1], c[2])
        return SIMD3(det(b, c[1], c[2]) / d, det(c[0], b, c[2]) / d, det(c[0], c[1], b) / d)
    }
}

// MARK: - 2 Beam and scanlines

/// The electron beam: each field line is drawn by a Gaussian spot whose sigma grows with the
/// gun's level, so dark lines are thin with a gap between them and highlights fatten and
/// bloom (crt-royale's beam_min_sigma and beam_max_sigma, 0.02 to 0.3 of a scanline, READ,
/// default 0.1 dark to 0.3 white). The spot is integrated over each output
/// pixel's height, so a thin line does not alias. Interlace: the 480 line raster is two fields
/// of 240 lines at 60 fields a second (READ, en.wikipedia "NTSC"). A 30 frame a second picture
/// shows both, the field drawn last brighter than the one before it while the phosphor fades
/// (Field fade, INFERRED, 0 for a steady picture), alternating on the frame number.
@MainActor
@Observable
public final class CRTBeamLayer: CRTLayer {
    public let id = "crt-beam"
    public let name = "Beam and scanlines"
    public var enabled = false
    public var sigmaDark = 0.1
    public var sigmaBright = 0.3
    public var fieldFade = 0.15

    public static let sigmaRange = 0.02...0.5
    public static let fadeRange = 0.0...1.0

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "dark", name: "Spot, dark (lines)", value: .float(sigmaDark), range: Self.sigmaRange),
         LayerParameter(id: "bright", name: "Spot, bright (lines)", value: .float(sigmaBright), range: Self.sigmaRange),
         LayerParameter(id: "fade", name: "Field fade", value: .float(fieldFade), range: Self.fadeRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("dark", .float(let v)): sigmaDark = clamped(v, Self.sigmaRange)
        case ("bright", .float(let v)): sigmaBright = clamped(v, Self.sigmaRange)
        case ("fade", .float(let v)): fieldFade = clamped(v, Self.fadeRange)
        default: break
        }
    }
}

// MARK: - 3 Mask

/// The phosphor mask: the beam lands through a shadow mask (rows of dots, alternate columns
/// offset half a cell) or an aperture grille (vertical stripes), red, green and blue in turn.
/// Triad size in output pixels, crt-royale's default 3.0 (READ), 2 to 6. A 20 inch set's
/// visible width holds fewer than about 1450 triads (INFERRED arithmetic from the 0.28 mm
/// monitor pitch, READ), so a real TV's triad is near one source pixel wide and needs at least
/// 3 output pixels to draw. Strength mixes the mask in, with its mean held at 1 so the picture
/// keeps its level. This is the layer most likely to read as a filter, so the default
/// strength is low (0.25, INFERRED).
@MainActor
@Observable
public final class CRTMaskLayer: CRTLayer {
    public let id = "crt-mask"
    public let name = "Mask (phosphor triads)"
    public var enabled = false
    /// The grille by default (INFERRED, by eye): at 1440 by 1080 a scanline
    /// is 2.25 canvas pixels and the shadow mask's rows beat with it into a plaid that reads as
    /// a screen door, while the grille's stripes run with the lines.
    public var kind: Kind = .apertureGrille
    public var triad = 3.0
    public var strength = 0.25

    public enum Kind: String, CaseIterable, Sendable {
        case shadowMask = "shadow-mask"
        case apertureGrille = "aperture-grille"
        // Short, so the sidebar draws the choice as a segmented control beside its name (long
        // labels push the name out to an ellipsis).
        var label: String { self == .shadowMask ? "Dots" : "Grille" }
        var index: UInt32 { self == .shadowMask ? 0 : 1 }
    }

    public static let triadRange = 2.0...6.0
    public static let strengthRange = 0.0...1.0

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "kind", name: "Mask", value: .choice(kind.rawValue),
                        options: Kind.allCases.map { .init(value: $0.rawValue, label: $0.label) }),
         LayerParameter(id: "triad", name: "Triad (px)", value: .float(triad), range: Self.triadRange),
         LayerParameter(id: "strength", name: "Strength", value: .float(strength), range: Self.strengthRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("kind", .choice(let c)): if let k = Kind(rawValue: c) { kind = k }
        case ("triad", .float(let v)): triad = clamped(v, Self.triadRange)
        case ("strength", .float(let v)): strength = clamped(v, Self.strengthRange)
        default: break
        }
    }
}

// MARK: - 4 Glow

/// Light that spreads in the glass: refractive diffusion mixes a wide blur into the picture,
/// crt-royale's diffusion_weight 0.075 (READ), 0 to 0.3. Halation, stray electrons and light
/// bouncing inside the faceplate, adds a wider blur on top, default 0 (READ), 0 to 0.2. The
/// blur widths are INFERRED (1 and 4 percent of the picture height): the source gives weights,
/// not radii.
@MainActor
@Observable
public final class CRTGlowLayer: CRTLayer {
    public let id = "crt-glow"
    public let name = "Glow (glass diffusion)"
    public var enabled = false
    public var diffusion = 0.075
    public var halation = 0.0

    public static let diffusionRange = 0.0...0.3
    public static let halationRange = 0.0...0.2
    /// Blur sigmas as a fraction of the canvas height (INFERRED).
    public static let diffusionSigma = 0.01
    public static let halationSigma = 0.04

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "diffusion", name: "Diffusion", value: .float(diffusion), range: Self.diffusionRange),
         LayerParameter(id: "halation", name: "Halation", value: .float(halation), range: Self.halationRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("diffusion", .float(let v)): diffusion = clamped(v, Self.diffusionRange)
        case ("halation", .float(let v)): halation = clamped(v, Self.halationRange)
        default: break
        }
    }
}

// MARK: - 5 Geometry

/// Where the beam lands. Overscan: the set shows less than the raster ("Some say 5%, some say
/// 10%", READ, en.wikipedia "Overscan"), which hides the head switch and the blanking bars.
/// Barrel: the curved faceplate bows straight lines out (0 to 0.1, INFERRED, crt-royale's
/// curvature radius 2.0 diagonals is a different measure). Corner falloff: the corners are
/// dimmer (0 to 30 percent, INFERRED). Rotation: a tube sits a little crooked in its yoke (0
/// to 0.5 degree, INFERRED, default 0). Convergence: the three beams miss each other by a
/// fraction of a line, red one way and blue the other (crt-royale's offsets 0.1 to 0.6 lines,
/// READ, default 0.1 here, INFERRED). The geometry is the scan, so it runs inside the beam's
/// kernel (`crt_scan`): moving the picture after the scanlines are drawn would resample them.
@MainActor
@Observable
public final class CRTGeometryLayer: CRTLayer {
    public let id = "crt-geometry"
    public let name = "Geometry (overscan, curve)"
    public var enabled = false
    public var overscan = 0.05
    public var barrel = 0.03
    public var cornerFalloff = 0.15
    public var rotation = 0.0
    public var convergence = 0.1

    public static let overscanRange = 0.0...0.10
    public static let barrelRange = 0.0...0.1
    public static let falloffRange = 0.0...0.30
    public static let rotationRange = 0.0...0.5
    public static let convergenceRange = 0.0...1.0

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "overscan", name: "Overscan", value: .float(overscan), range: Self.overscanRange),
         LayerParameter(id: "barrel", name: "Barrel", value: .float(barrel), range: Self.barrelRange),
         LayerParameter(id: "falloff", name: "Corner falloff", value: .float(cornerFalloff), range: Self.falloffRange),
         // "tilt", not "rotation": the clipboard never carries framing's rotation, and the id
         // must not read as it.
         LayerParameter(id: "tilt", name: "Tilt (degrees)", value: .float(rotation), range: Self.rotationRange),
         LayerParameter(id: "convergence", name: "Convergence (lines)", value: .float(convergence),
                        range: Self.convergenceRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("overscan", .float(let v)): overscan = clamped(v, Self.overscanRange)
        case ("barrel", .float(let v)): barrel = clamped(v, Self.barrelRange)
        case ("falloff", .float(let v)): cornerFalloff = clamped(v, Self.falloffRange)
        case ("tilt", .float(let v)): rotation = clamped(v, Self.rotationRange)
        case ("convergence", .float(let v)): convergence = clamped(v, Self.convergenceRange)
        default: break
        }
    }
}

// MARK: - 6 Glass

/// The faceplate: a neutral density tint that darkens the picture (and the room's light twice
/// over, which is why tubes had it), the room's light reflected off the front (a lift over the
/// whole canvas), and a faint glow in the blacks from the light scattered in the glass. No
/// published figures were found for any of them: all INFERRED, tuned by eye, the defaults
/// subtle.
@MainActor
@Observable
public final class CRTGlassLayer: CRTLayer {
    public let id = "crt-glass"
    public let name = "Glass (tint, reflection)"
    public var enabled = false
    public var tint = 0.1
    public var reflection = 0.01
    public var blackGlow = 0.02

    public static let tintRange = 0.0...0.5
    public static let reflectionRange = 0.0...0.1
    public static let blackGlowRange = 0.0...0.2

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "tint", name: "Tint", value: .float(tint), range: Self.tintRange),
         LayerParameter(id: "reflection", name: "Room reflection", value: .float(reflection),
                        range: Self.reflectionRange),
         LayerParameter(id: "blackglow", name: "Black glow", value: .float(blackGlow), range: Self.blackGlowRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("tint", .float(let v)): tint = clamped(v, Self.tintRange)
        case ("reflection", .float(let v)): reflection = clamped(v, Self.reflectionRange)
        case ("blackglow", .float(let v)): blackGlow = clamped(v, Self.blackGlowRange)
        default: break
        }
    }
}

// MARK: - The stage

/// The Display stage's layers, in the order docs/CRT.md lists them, with the Display size first.
@MainActor
public struct CRTLayers {
    public let display = CRTDisplayLayer()
    public let transfer = CRTTransferLayer()
    public let beam = CRTBeamLayer()
    public let mask = CRTMaskLayer()
    public let glow = CRTGlowLayer()
    public let geometry = CRTGeometryLayer()
    public let glass = CRTGlassLayer()

    public init() {
        let six = layers
        display.anyOn = { six.contains { $0.enabled } }
    }

    /// The six CRT layers, each with its own switch.
    public var layers: [any CRTLayer] { [transfer, beam, mask, glow, geometry, glass] }
    /// Every layer the stage saves: the Display size, then the six.
    public var all: [any Layer] { [display] + layers }
    /// True when any CRT layer is on: the stage runs and the output is the Display size.
    public var isOn: Bool { layers.contains { $0.enabled } }
    public var size: DisplaySize { display.size }

    public func allOff() {
        for l in layers { l.enabled = false }
    }

    /// Every switch and value of `src` onto `dst`, through `setParameter`.
    static func copy(_ src: CRTLayers, to dst: CRTLayers) {
        for (d, s) in zip(dst.all, src.all) {
            if !(d is CRTDisplayLayer) { d.enabled = s.enabled }
            for p in s.parameters { d.setParameter(p.id, to: p.value) }
        }
    }
}

/// The preview's window onto the Display canvas: a zoom and a center in the canvas's uv.
/// The viewer's pinch sets the zoom and its drag the center while a CRT layer is on, and a
/// double-click goes back to the whole canvas. Never saved.
public struct DisplayZoom: Equatable, Sendable {
    public static let range = 1.0...16.0
    public private(set) var zoom = 1.0
    public private(set) var center = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    public var isZoomed: Bool { zoom > 1.001 }

    public mutating func setZoom(_ z: Double) {
        zoom = clamped(z, Self.range)
        clampCenter()
    }

    /// Moves the picture with a drag of `d`, in fractions of the view: the canvas follows the
    /// cursor, so the window moves the other way.
    public mutating func pan(from start: CGPoint, drag d: CGVector) {
        center = CGPoint(x: start.x - d.dx / zoom, y: start.y - d.dy / zoom)
        clampCenter()
    }

    public mutating func reset() { self = DisplayZoom() }

    private mutating func clampCenter() {
        let half = 0.5 / zoom
        center = CGPoint(x: min(max(center.x, half), 1 - half), y: min(max(center.y, half), 1 - half))
    }

    /// The fragment's window: x, y, width, height in uv, then 1 when a canvas pixel covers at
    /// least two drawable pixels (drawn as squares) else 0.
    public func window(canvasWidth: Int, viewWidth: Double) -> [Float] {
        let size = 1 / zoom
        let pixel = viewWidth * zoom / Double(max(canvasWidth, 1))
        return [Float(center.x - size / 2), Float(center.y - size / 2), Float(size), Float(size), pixel >= 2 ? 1 : 0]
    }
}

extension Look {
    /// True when the Look sets a CRT layer: a user preset or a clip's sidecar from a build with
    /// the Display stage. The built-in Looks never do, so choosing one leaves the Display alone.
    var setsDisplay: Bool { overrides.contains { $0.layer.hasPrefix("crt-") || $0.layer.hasPrefix("recapture") } }
    /// True when the Look turns the camera on: the Looks that film the screen. Their
    /// Display and Re-capture count when the picker reads the chain back.
    var filmsTheScreen: Bool {
        overrides.contains { $0.layer == "recapture" && $0.parameter == "enabled" && $0.value == .bool(true) }
    }
}

/// Runs the Display stage's kernels (Shaders/CRT.metal) from the 720 by 480 raster onto the
/// canvas. Textures are made at the Display size on first use and remade when it changes.
@MainActor
final class CRTRenderer {
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var linear: MTLTexture?
    private var canvas: [MTLTexture] = []
    private var quarter: [MTLTexture] = []
    private var size: (width: Int, height: Int)?

    static let kernels = ["crt_transfer", "crt_scan", "crt_mask", "crt_glow_down", "crt_blur", "crt_glow", "crt_glass"]

    func prepare(device: MTLDevice, library: MTLLibrary) throws {
        guard pipelines.isEmpty else { return }
        for k in Self.kernels { pipelines[k] = try makePipeline(k, device: device, library: library) }
        linear = try makeRasterTexture(device: device, label: "CRT linear raster")
    }

    private func texture(_ device: MTLDevice, _ w: Int, _ h: Int, _ label: String) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else {
            throw ShaderLibrary.LoadError.noLibrary("could not allocate \(label)")
        }
        t.label = label
        return t
    }

    private func allocate(_ w: Int, _ h: Int, device: MTLDevice) throws {
        if let size, size == (w, h) { return }
        canvas = try (0..<3).map { try texture(device, w, h, "CRT canvas \($0)") }
        quarter = try (0..<3).map { try texture(device, w / 4, h / 4, "CRT glow \($0)") }
        size = (w, h)
    }

    private func run(_ cb: MTLCommandBuffer, _ name: String, _ textures: [MTLTexture], floats: [Float],
                     width: Int, height: Int) {
        guard let p = pipelines[name], let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = name
        enc.setComputePipelineState(p)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        setFloats(enc, floats, index: 0)
        dispatch2D(enc, pipeline: p, width: width, height: height)
        enc.endEncoding()
    }

    private func blur(_ cb: MTLCommandBuffer, from: MTLTexture, via: MTLTexture, to: MTLTexture, sigma: Double) {
        run(cb, "crt_blur", [from, via], floats: [1, 0, Float(sigma)], width: via.width, height: via.height)
        run(cb, "crt_blur", [via, to], floats: [0, 1, Float(sigma)], width: to.width, height: to.height)
    }

    /// Encodes the stage over `raster` and returns the canvas, in the raster's encoding
    /// (gamma 2.2 R'G'B'), at the Display size. Under Fill the frame `aspect` is the frame's
    /// shape: the tube keeps the Display size's height and takes that shape, the same
    /// curvature, mask and scan lines over a wider glass, the squeezed raster drawn across it.
    func encode(_ crt: CRTLayers, size s: DisplaySize, aspect: CGFloat? = nil, commandBuffer cb: MTLCommandBuffer,
                raster: MTLTexture, frame: FrameContext, device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        try prepare(device: device, library: library)
        let h = s.height
        let w = aspect.map { SignalChain.wideWidth(height: h, aspect: $0) } ?? s.width
        try allocate(w, h, device: device)
        guard let linear else { return raster }

        // 1 Transfer: decode to linear light.
        let t = crt.transfer
        let gains = t.enabled ? CRTTransferLayer.whiteGains(kelvin: t.whiteKelvin) : SIMD3(1, 1, 1)
        run(cb, "crt_transfer", [raster, linear],
            floats: [Float(t.enabled ? t.gamma : CRTTransferLayer.encodeGamma), Float(t.enabled ? t.blackLift : 0),
                     Float(gains.x), Float(gains.y), Float(gains.z)],
            width: linear.width, height: linear.height)

        // 2 Beam and 5 Geometry: the scan onto the canvas.
        let b = crt.beam, g = crt.geometry
        run(cb, "crt_scan", [linear, canvas[0]],
            floats: [b.enabled ? 1 : 0, Float(b.sigmaDark), Float(b.sigmaBright), Float(b.fieldFade),
                     Float(frame.frameIndex % 2),
                     g.enabled ? 1 : 0, Float(g.overscan), Float(g.barrel), Float(g.cornerFalloff),
                     Float(g.rotation * .pi / 180), Float(g.convergence), Float(aspect ?? 0)],
            width: w, height: h)
        var current = 0

        // 3 Mask.
        let m = crt.mask
        if m.enabled {
            run(cb, "crt_mask", [canvas[0], canvas[1]],
                floats: [Float(m.kind.index), Float(m.triad), Float(m.strength)], width: w, height: h)
            current = 1
        }

        // 4 Glow, and the wide blur Glass's black glow reads.
        let gl = crt.glow, glass = crt.glass
        let wantsHalo = (gl.enabled && gl.halation > 0) || (glass.enabled && glass.blackGlow > 0)
        let wantsGlow = gl.enabled || wantsHalo
        let qh = Double(h / 4)
        if wantsGlow {
            run(cb, "crt_glow_down", [canvas[current], quarter[0]], floats: [], width: w / 4, height: h / 4)
            // quarter[1] the diffusion blur, quarter[2] the halation blur, canvas[2] the scratch.
            blur(cb, from: quarter[0], via: quarter[2], to: quarter[1], sigma: CRTGlowLayer.diffusionSigma * qh)
            if wantsHalo {
                // Reuses quarter[0] as the scratch once the diffusion blur has read it.
                blur(cb, from: quarter[1], via: quarter[0], to: quarter[2],
                     sigma: sqrt(pow(CRTGlowLayer.halationSigma, 2) - pow(CRTGlowLayer.diffusionSigma, 2)) * qh)
            }
        }
        if gl.enabled {
            let out = current == 1 ? 0 : 1
            run(cb, "crt_glow", [canvas[current], quarter[1], quarter[2], canvas[out]],
                floats: [Float(gl.diffusion), Float(wantsHalo ? gl.halation : 0)], width: w, height: h)
            current = out
        }

        // 6 Glass, and the encode for the file or the screen.
        run(cb, "crt_glass", [canvas[current], quarter[2], canvas[2]],
            floats: [glass.enabled ? 1 : 0, Float(glass.tint), Float(glass.reflection),
                     Float(wantsHalo ? glass.blackGlow : 0), Float(1 / CRTTransferLayer.encodeGamma)],
            width: w, height: h)
        return canvas[2]
    }
}
