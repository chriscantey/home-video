import Foundation
import Metal
import Observation

// Re-capture: to a CRT and back. The Display stage's tube plays the tape, and a newer camera
// (a phone, or a 4:3 camcorder) films its screen. That recording is the output. Seven layers,
// each a named mechanism with its figures in docs/RECAPTURE.md.
//
// Where it sits: after the Display canvas. The camera samples the drawn canvas at its own
// sensor grid, which is what makes the moire, so with Re-capture on the tube is drawn at the
// 2880 by 2160 canvas (above the camera's resolution) and then resampled through the camera to
// the camera's size. The stage runs only while its switch is on and a CRT layer is on (it
// "needs Display"). Unused, nothing here runs and the picture is the Display stage's, byte for
// byte.
//
// Seeded and deterministic: the hand, the exposure's hunting and the sensor noise are pure
// functions of the stage's seed and the camera frame's time (frame index over the camera rate).

/// A layer of the Re-capture stage. A `CRTLayer` too, so the CLI marks it `display` and
/// `--set <id>.enabled` works, and so the chain never calls its own encode.
@MainActor
public protocol RecaptureLayer: CRTLayer {}

/// Where the camera frames the screen.
public enum RecaptureFraming: String, CaseIterable, Sendable {
    /// Inside the picture, so no bezel, corner or curve shows. The default.
    case tight
    /// The whole tube: its corners, a dark bezel and the room around it.
    case whole

    var label: String { self == .tight ? "Tight" : "Whole" }
    /// Margin inside the screen's edge in Tight, a share of its size, so the corners the
    /// Geometry's barrel bends and the hand's drift never reach the frame (INFERRED).
    static let tightMargin = 0.1
    /// The screen's height as a share of the frame's in Whole (INFERRED).
    static let wholeHeight = 0.78
}

/// The camera that films the screen, which sets the output's size.
public enum RecaptureCamera: String, CaseIterable, Sendable {
    /// A phone in landscape at 1080p: 16:9, so Tight crops the 4:3 picture top and bottom.
    case phone = "phone-1920x1080"
    /// A 4:3 camera at 1440 by 1080, the whole picture's shape.
    case fourThree = "camera-1440x1080"
    /// A phone held upright at 1080 by 1920: 9:16, so Tight crops the picture's sides and keeps
    /// its height.
    case phoneUpright = "phone-1080x1920"

    public var width: Int {
        switch self {
        case .phone: 1920
        case .fourThree: 1440
        case .phoneUpright: 1080
        }
    }
    public var height: Int { self == .phoneUpright ? 1920 : 1080 }
    var label: String {
        switch self {
        case .phone: "16:9 phone"
        case .fourThree: "4:3 camera"
        case .phoneUpright: "9:16 phone"
        }
    }
    /// True when the sensor's rows run down the frame rather than across it: a phone's sensor is
    /// wider than tall and reads out a row at a time down its short side, so held upright its
    /// rows stand on end and the readout sweeps across the frame, left to right (INFERRED: the
    /// sensor turned a quarter counterclockwise from landscape with the camera at the top left).
    var readsAcross: Bool { self == .phoneUpright }
}

// MARK: - The stage switch

/// The stage's own switch and its choices: the Framing, the Camera and the seed. Off by default.
@MainActor
@Observable
public final class RecaptureStageLayer: RecaptureLayer {
    public let id = "recapture"
    public let name = "Re-capture (filmed TV)"
    public var enabled = false
    public var framing: RecaptureFraming = .tight
    public var camera: RecaptureCamera = .phone
    public var seed = 1.0

    public static let seedRange = 0.0...999.0

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "framing", name: "Framing", value: .choice(framing.rawValue),
                        options: RecaptureFraming.allCases.map { .init(value: $0.rawValue, label: $0.label) }),
         // The camera's shape, not the file's size: the Output size on the Look tab is that.
         LayerParameter(id: "camera", name: "Camera shape", value: .choice(camera.rawValue),
                        options: RecaptureCamera.allCases.map { .init(value: $0.rawValue, label: $0.label) }),
         LayerParameter(id: "seed", name: "Seed", value: .float(seed), range: Self.seedRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("framing", .choice(let c)): if let f = RecaptureFraming(rawValue: c) { framing = f }
        case ("camera", .choice(let c)): if let k = RecaptureCamera(rawValue: c) { camera = k }
        case ("seed", .float(let v)): seed = clamped(v.rounded(), Self.seedRange)
        default: break
        }
    }
}

// MARK: - 1 Shutter

/// The camera's shutter against the tube's refresh. The beam passes each height once a field,
/// 59.94 fields a second (READ, en.wikipedia "Kinescope"). A row of the sensor exposed for S
/// catches the phosphor at
/// that height only if a beam pass lands in its exposure, and the phosphor then decays: a
/// shutter under one field leaves a dark bar over 1 minus S f of the height, and the bar moves
/// each camera frame by the fraction of f over the camera rate. A rolling shutter starts each
/// row Readout later down the frame (iPhone 4s 22.08 ms, READ, Linkoping University's rolling
/// shutter tutorial). The bar is never drawn: it
/// is the exposure integral of the decaying phosphor, worked out per row in `rc_optics`.
@MainActor
@Observable
public final class RecaptureShutterLayer: RecaptureLayer {
    public let id = "recapture-shutter"
    public let name = "Shutter (rolling bar)"
    public var enabled = true
    public var rate: Rate = .r30
    /// The shutter time's denominator: 70 is 1/70 s, a seventh of each field missed, a soft bar
    /// (INFERRED, by eye: 1/80 with the rolling readout darkens 40 percent of the frame).
    public var shutter = 70.0
    public var kind: Kind = .rolling
    public var readoutMS = 22.08
    /// The phosphor's decay time constant. P22 blue is 200 ns (READ), red and green have no
    /// figure: 2 ms (INFERRED, by eye) leaves the bar dim rather than black, as filmed sets show.
    public var decayMS = 2.0

    public enum Rate: String, CaseIterable, Sendable {
        case r24 = "24", r25 = "25", r2997 = "29.97", r30 = "30", r60 = "60"
        public var fps: Double {
            switch self {
            case .r24: return 24
            case .r25: return 25
            case .r2997: return 30000.0 / 1001
            case .r30: return 30
            case .r60: return 60
            }
        }
    }

    public enum Kind: String, CaseIterable, Sendable {
        case rolling, global
        var label: String { self == .rolling ? "Rolling" : "Global" }
    }

    /// NTSC's field rate.
    public nonisolated static let fieldRate = 60000.0 / 1001
    public static let shutterRange = 30.0...500.0
    public static let readoutRange = 0.0...33.0
    public static let decayRange = 0.05...4.0

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "rate", name: "Camera rate (fps)", value: .choice(rate.rawValue),
                        options: Rate.allCases.map { .init(value: $0.rawValue, label: $0.rawValue) }),
         LayerParameter(id: "shutter", name: "Shutter (1/s)", value: .float(shutter), range: Self.shutterRange),
         LayerParameter(id: "kind", name: "Shutter kind", value: .choice(kind.rawValue),
                        options: Kind.allCases.map { .init(value: $0.rawValue, label: $0.label) }),
         LayerParameter(id: "readout", name: "Readout (ms)", value: .float(readoutMS), range: Self.readoutRange),
         LayerParameter(id: "decay", name: "Phosphor decay (ms)", value: .float(decayMS), range: Self.decayRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("rate", .choice(let c)): if let r = Rate(rawValue: c) { rate = r }
        case ("shutter", .float(let v)): shutter = clamped(v, Self.shutterRange)
        case ("kind", .choice(let c)): if let k = Kind(rawValue: c) { kind = k }
        case ("readout", .float(let v)): readoutMS = clamped(v, Self.readoutRange)
        case ("decay", .float(let v)): decayMS = clamped(v, Self.decayRange)
        default: break
        }
    }

    /// How far the bar moves a camera frame, in screen heights, wrapped to minus a half to a
    /// half: the fraction of the fields that pass in one frame.
    public nonisolated static func barDrift(fps: Double) -> Double {
        let n = fieldRate / fps
        return n - n.rounded()
    }
}

// MARK: - 2 Sensor

/// The sensor samples the screen on its own grid through a Bayer mosaic, half green, a quarter
/// red and a quarter blue (READ, en.wikipedia "Bayer filter"), then demosaics. Undersampling
/// the phosphors' fine regular pattern is the moire (READ, en.wikipedia "Moire pattern"), so it
/// comes and goes with the Mask, the triad, the framing and the hand. The optical low pass
/// filter blurs before the sampling (READ, en.wikipedia "Bayer filter", its width
/// INFERRED, phones carry a weak one or none). Noise is shot and read noise (INFERRED).
@MainActor
@Observable
public final class RecaptureSensorLayer: RecaptureLayer {
    public let id = "recapture-sensor"
    public let name = "Sensor (Bayer, moire)"
    public var enabled = true
    public var mosaic = 1.0
    public var olpf = 0.25
    public var noise = 0.01

    public static let mosaicRange = 0.0...1.0
    public static let olpfRange = 0.0...1.0
    public static let noiseRange = 0.0...0.05

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "mosaic", name: "Bayer mosaic", value: .float(mosaic), range: Self.mosaicRange),
         LayerParameter(id: "olpf", name: "Low pass (px)", value: .float(olpf), range: Self.olpfRange),
         LayerParameter(id: "noise", name: "Noise", value: .float(noise), range: Self.noiseRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("mosaic", .float(let v)): mosaic = clamped(v, Self.mosaicRange)
        case ("olpf", .float(let v)): olpf = clamped(v, Self.olpfRange)
        case ("noise", .float(let v)): noise = clamped(v, Self.noiseRange)
        default: break
        }
    }
}

// MARK: - 3 Exposure

/// Auto exposure and white balance. Bias: a phone metering a bright screen sets its own
/// exposure, here a third of a stop over, so the highlights clip at the sensor's full well
/// (INFERRED). Hunt: the auto exposure's slow breathing as it chases the picture, a seeded slow
/// wave in stops (INFERRED, no figure found). Camera white: the color temperature the camera
/// balances for. The tube's white is 9300 K when its Transfer is on, a camera aims for 6500 K
/// (READ, en.wikipedia "Color temperature"), and auto white balance meets it partway, 7500 K
/// (INFERRED), so a filmed
/// TV stays a little blue.
@MainActor
@Observable
public final class RecaptureExposureLayer: RecaptureLayer {
    public let id = "recapture-exposure"
    public let name = "Exposure (AE, white balance)"
    public var enabled = true
    public var bias = 0.3
    public var hunt = 0.15
    public var period = 4.0
    public var whiteKelvin = 7500.0

    public static let biasRange = -2.0...2.0
    public static let huntRange = 0.0...1.0
    public static let periodRange = 1.0...10.0
    public static let kelvinRange = 5000.0...9300.0

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "bias", name: "Exposure (stops)", value: .float(bias), range: Self.biasRange),
         LayerParameter(id: "hunt", name: "Hunting (stops)", value: .float(hunt), range: Self.huntRange),
         LayerParameter(id: "period", name: "Hunting period (s)", value: .float(period), range: Self.periodRange),
         LayerParameter(id: "white", name: "Camera white (K)", value: .float(whiteKelvin), range: Self.kelvinRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("bias", .float(let v)): bias = clamped(v, Self.biasRange)
        case ("hunt", .float(let v)): hunt = clamped(v, Self.huntRange)
        case ("period", .float(let v)): period = clamped(v, Self.periodRange)
        case ("white", .float(let v)): whiteKelvin = clamped(v, Self.kelvinRange)
        default: break
        }
    }

    /// The camera's white balance gains: the inverse of a `kelvin` white's RGB, green at 1.
    public nonisolated static func balance(kelvin: Double) -> SIMD3<Double> {
        let w = CRTTransferLayer.whiteGains(kelvin: kelvin)
        let g = SIMD3(1 / w.x, 1 / w.y, 1 / w.z)
        return g / g.y
    }
}

// MARK: - 4 Lens

/// The camera's lens. Focus: the camera focuses on the glass or the phosphors and a little
/// off, a blur disc of this radius in sensor pixels, which also softens the moire (INFERRED,
/// by eye). Vignette: the corners darker by the cosine fourth law's shape (en.wikipedia
/// "Vignetting"), its depth INFERRED.
@MainActor
@Observable
public final class RecaptureLensLayer: RecaptureLayer {
    public let id = "recapture-lens"
    public let name = "Lens (focus, vignette)"
    public var enabled = true
    public var defocus = 0.6
    public var vignette = 0.2

    public static let defocusRange = 0.0...4.0
    public static let vignetteRange = 0.0...0.6

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "defocus", name: "Defocus (px)", value: .float(defocus), range: Self.defocusRange),
         LayerParameter(id: "vignette", name: "Vignette", value: .float(vignette), range: Self.vignetteRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("defocus", .float(let v)): defocus = clamped(v, Self.defocusRange)
        case ("vignette", .float(let v)): vignette = clamped(v, Self.vignetteRange)
        default: break
        }
    }
}

// MARK: - 5 Hand

/// The hand holding the camera. Drift: a slow wander, in percent of the frame. Shake: a
/// faster tremor, in output pixels. Yaw and pitch: the camera off the screen's axis, which
/// keystones the picture (aiming off axis is also what en.wikipedia "Moire pattern" advises). All
/// INFERRED, seeded sums of slow waves, so a render repeats.
@MainActor
@Observable
public final class RecaptureHandLayer: RecaptureLayer {
    public let id = "recapture-hand"
    public let name = "Hand (drift, keystone)"
    public var enabled = true
    public var drift = 0.5
    public var shake = 0.8
    public var yaw = 4.0
    public var pitch = -2.0

    public static let driftRange = 0.0...3.0
    public static let shakeRange = 0.0...4.0
    public static let yawRange = -20.0...20.0
    public static let pitchRange = -15.0...15.0
    /// The camera's distance from the screen, in screen heights (INFERRED, a phone's wide lens
    /// filling its frame with a 20 inch set).
    static let distance = 2.5

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "drift", name: "Drift (%)", value: .float(drift), range: Self.driftRange),
         LayerParameter(id: "shake", name: "Shake (px)", value: .float(shake), range: Self.shakeRange),
         LayerParameter(id: "yaw", name: "Yaw (degrees)", value: .float(yaw), range: Self.yawRange),
         LayerParameter(id: "pitch", name: "Pitch (degrees)", value: .float(pitch), range: Self.pitchRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("drift", .float(let v)): drift = clamped(v, Self.driftRange)
        case ("shake", .float(let v)): shake = clamped(v, Self.shakeRange)
        case ("yaw", .float(let v)): yaw = clamped(v, Self.yawRange)
        case ("pitch", .float(let v)): pitch = clamped(v, Self.pitchRange)
        default: break
        }
    }
}

// MARK: - 6 Glare

/// Light from the room on the glass. A lamp's reflection: a soft spot on the screen, fixed to
/// the glass, so it moves with the hand like the picture. Room: the room's light lifting the
/// black of the glass. No published figures were found: all INFERRED.
@MainActor
@Observable
public final class RecaptureGlareLayer: RecaptureLayer {
    public let id = "recapture-glare"
    public let name = "Glare (reflection)"
    public var enabled = true
    public var strength = 0.04
    public var size = 0.25
    public var x = 0.78
    public var y = 0.22
    public var room = 0.006

    public static let strengthRange = 0.0...0.3
    public static let sizeRange = 0.05...0.6
    public static let positionRange = 0.0...1.0
    public static let roomRange = 0.0...0.05

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "strength", name: "Reflection", value: .float(strength), range: Self.strengthRange),
         LayerParameter(id: "size", name: "Reflection size", value: .float(size), range: Self.sizeRange),
         LayerParameter(id: "x", name: "Across", value: .float(x), range: Self.positionRange),
         LayerParameter(id: "y", name: "Down", value: .float(y), range: Self.positionRange),
         LayerParameter(id: "room", name: "Room light", value: .float(room), range: Self.roomRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("strength", .float(let v)): strength = clamped(v, Self.strengthRange)
        case ("size", .float(let v)): size = clamped(v, Self.sizeRange)
        case ("x", .float(let v)): x = clamped(v, Self.positionRange)
        case ("y", .float(let v)): y = clamped(v, Self.positionRange)
        case ("room", .float(let v)): room = clamped(v, Self.roomRange)
        default: break
        }
    }
}

// MARK: - 7 Processing

/// The camera's own processing after the sensor. Noise reduction smears fine noise (a range
/// weighted blur, INFERRED). Sharpening is an unsharp mask, its radius 1.2 px inside the 0.5 to
/// 2 pixels commonly advised (en.wikipedia "Unsharp masking"), which rings at edges. The codec:
/// 4:2:0 chroma (READ, en.wikipedia "Macroblock") and a block transform quantized for the
/// bitrate, 16 Mbps the iPhone 8 Plus's H.264 1080p30 (READ, GSMArena's iPhone 8 Plus review),
/// then 8 bits. The step size for
/// a bitrate is INFERRED, by eye.
@MainActor
@Observable
public final class RecaptureProcessingLayer: RecaptureLayer {
    public let id = "recapture-processing"
    public let name = "Processing (sharpen, codec)"
    public var enabled = true
    public var sharpen = 0.8
    public var denoise = 0.4
    public var bitrate = 16.0

    public static let sharpenRange = 0.0...2.0
    public static let denoiseRange = 0.0...1.0
    public static let bitrateRange = 2.0...50.0
    /// The unsharp mask's radius, sensor pixels (INFERRED).
    static let sharpenSigma = 1.2

    public init() {}

    public var parameters: [LayerParameter] {
        [LayerParameter(id: "sharpen", name: "Sharpening", value: .float(sharpen), range: Self.sharpenRange),
         LayerParameter(id: "denoise", name: "Noise reduction", value: .float(denoise), range: Self.denoiseRange),
         LayerParameter(id: "bitrate", name: "Bitrate (Mbps)", value: .float(bitrate), range: Self.bitrateRange)]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("sharpen", .float(let v)): sharpen = clamped(v, Self.sharpenRange)
        case ("denoise", .float(let v)): denoise = clamped(v, Self.denoiseRange)
        case ("bitrate", .float(let v)): bitrate = clamped(v, Self.bitrateRange)
        default: break
        }
    }

    /// The codec's quantizer step for the DC coefficient, in 0 to 1 code values, at a bitrate
    /// for 1080p30 (INFERRED: 16 Mbps gives about 1.5 codes of 255).
    public nonisolated static func step(bitrate: Double) -> Double { 0.006 * 16 / bitrate }
}

// MARK: - The stage

/// The Re-capture stage: its switch with the Framing, Camera and seed, then the seven layers in
/// the order the light meets them.
@MainActor
public struct RecaptureLayers {
    public let stage = RecaptureStageLayer()
    public let shutter = RecaptureShutterLayer()
    public let sensor = RecaptureSensorLayer()
    public let exposure = RecaptureExposureLayer()
    public let lens = RecaptureLensLayer()
    public let hand = RecaptureHandLayer()
    public let glare = RecaptureGlareLayer()
    public let processing = RecaptureProcessingLayer()

    public init() {}

    /// The seven layers, each with its own switch.
    public var layers: [any RecaptureLayer] { [shutter, sensor, exposure, lens, hand, glare, processing] }
    /// Every layer the stage saves: its switch, then the seven.
    public var all: [any Layer] { [stage] + layers }

    /// Every switch and value of `src` onto `dst`.
    static func copy(_ src: RecaptureLayers, to dst: RecaptureLayers) {
        for (d, s) in zip(dst.all, src.all) {
            d.enabled = s.enabled
            for p in s.parameters { d.setParameter(p.id, to: p.value) }
        }
    }

    /// The camera's motion and exposure at camera time `t` seconds, from the seed: pure, so a
    /// frame renders the same whenever it is drawn.
    nonisolated static func wave(seed: Double, salt: Double, t: Double, hz: [Double]) -> Double {
        var s = 0.0, total = 0.0
        for (i, f) in hz.enumerated() {
            let phase = fract(sin(seed * 12.9898 + salt * 78.233 + Double(i) * 37.719) * 43758.5453) * 2 * .pi
            let w = 1 / Double(i + 1)
            s += w * sin(2 * .pi * f * t + phase)
            total += w
        }
        return s / total
    }

    nonisolated static func fract(_ v: Double) -> Double { v - floor(v) }

    /// Where a point of the frame (frame heights from its center, already scaled to screen
    /// heights) lands on the screen through the keystone, as `rc_optics` works it out.
    nonisolated static func keystone(_ q: SIMD2<Double>, yaw: Double, pitch: Double) -> SIMD2<Double> {
        let d = RecaptureHandLayer.distance
        let x = q.x * d / (d * cos(yaw) - q.x * sin(yaw))
        let y = q.y * (d + x * sin(yaw)) / d
        let y2 = y * d / (d * cos(pitch) - y * sin(pitch))
        return SIMD2(x * (d + y2 * sin(pitch)) / d, y2)
    }

    /// Tight framing's scale, screen heights per frame height: the largest that keeps every
    /// corner of the frame, moved as far as the hand reaches (frame heights) and through the
    /// keystone, inside the picture less the margin. So no bezel or corner ever shows.
    /// `tube` is the screen's shape, 4:3 unless Fill the frame made it the frame's.
    nonisolated static func tightScale(aspect: Double, reach: Double, yaw: Double, pitch: Double,
                                       tube: Double = 4.0 / 3) -> Double {
        let m = 1 - RecaptureFraming.tightMargin
        var s = min(tube * m / aspect, m)
        for _ in 0..<40 {
            var worst = 0.0
            for sx in [-1.0, 1.0] {
                for sy in [-1.0, 1.0] {
                    let corner = SIMD2(sx * (aspect / 2 + reach), sy * (0.5 + reach)) * s
                    let p = keystone(corner, yaw: yaw, pitch: pitch)
                    worst = max(worst, abs(p.x) / (tube / 2 * m), abs(p.y) / (0.5 * m))
                }
            }
            if worst <= 1 { break }
            s /= worst * 1.0005
        }
        return s
    }
}

/// Runs the Re-capture kernels (Shaders/Recapture.metal) from the Display canvas to the camera's
/// frame. Textures are made at the camera's size on first use and remade when it changes.
@MainActor
final class RecaptureRenderer {
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var frames: [MTLTexture] = []
    private var size: (width: Int, height: Int)?

    static let kernels = ["rc_optics", "rc_optics_across", "rc_sensor", "rc_demosaic", "rc_denoise", "crt_blur", "rc_sharpen", "rc_codec"]

    func prepare(device: MTLDevice, library: MTLLibrary) throws {
        guard pipelines.isEmpty else { return }
        for k in Self.kernels { pipelines[k] = try makePipeline(k, device: device, library: library) }
    }

    private func allocate(_ w: Int, _ h: Int, device: MTLDevice) throws {
        if let size, size == (w, h) { return }
        frames = try (0..<4).map { i in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w,
                                                             height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else {
                throw ShaderLibrary.LoadError.noLibrary("could not allocate the camera frame")
            }
            t.label = "Re-capture \(i)"
            return t
        }
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

    /// Encodes the camera over `canvas` (the Display stage's output, gamma 2.2 R'G'B') and
    /// returns the camera's frame in the same encoding, at the camera's size. Under Fill the frame
    /// `aspect` is the frame's shape: the tube on the canvas is that shape, and the
    /// camera, set to the same shape, keeps its height and frames it as it frames a 4:3 tube.
    func encode(_ rc: RecaptureLayers, aspect wide: CGFloat? = nil, commandBuffer cb: MTLCommandBuffer,
                canvas: MTLTexture, frame: FrameContext, device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        try prepare(device: device, library: library)
        let st = rc.stage
        let h = st.camera.height
        let w = wide.map { SignalChain.wideWidth(height: h, aspect: $0) } ?? st.camera.width
        try allocate(w, h, device: device)
        let tube = wide.map(Double.init) ?? 4.0 / 3
        let sh = rc.shutter, se = rc.sensor, ex = rc.exposure, le = rc.lens, ha = rc.hand, gl = rc.glare
        let pr = rc.processing

        // The camera's clock: frame n at n over the camera rate.
        let fps = sh.rate.fps
        let t = Double(frame.frameIndex) / fps
        let fields = t * RecaptureShutterLayer.fieldRate
        let phase = fields - floor(fields)

        // The framing: screen heights per frame height.
        let aspect = Double(w) / Double(h)
        let scale: Double
        switch st.framing {
        case .tight:
            let reach = ha.enabled ? ha.drift / 100 + ha.shake / Double(h) : 0
            scale = RecaptureLayers.tightScale(aspect: aspect, reach: reach,
                                               yaw: ha.enabled ? ha.yaw * .pi / 180 : 0,
                                               pitch: ha.enabled ? ha.pitch * .pi / 180 : 0, tube: tube)
        case .whole:
            // The screen's height a share of the frame's, or on a frame narrower than the 4:3
            // screen (the upright phone) its width a share of the frame's, so the whole picture
            // goes across with the room above and below. Under Fill the screen is the frame's shape.
            let across = wide == nil ? tube / aspect : 1
            scale = max(1, across) / RecaptureFraming.wholeHeight
        }

        // The hand: drift in percent of the frame, shake in output pixels, both in frame heights.
        let seed = st.seed
        var dx = 0.0, dy = 0.0
        if ha.enabled {
            dx = ha.drift / 100 * RecaptureLayers.wave(seed: seed, salt: 1, t: t, hz: [0.11, 0.23, 0.37])
                + ha.shake / Double(h) * RecaptureLayers.wave(seed: seed, salt: 2, t: t, hz: [3.1, 5.3, 8.7])
            dy = ha.drift / 100 * RecaptureLayers.wave(seed: seed, salt: 3, t: t, hz: [0.13, 0.29, 0.41])
                + ha.shake / Double(h) * RecaptureLayers.wave(seed: seed, salt: 4, t: t, hz: [2.9, 4.7, 7.9])
        }

        // 1 Hand, Lens, Glare and Shutter: the light that reaches each sensor site.
        let optics: [Float] = [
            Float(scale), Float(dx), Float(dy),
            ha.enabled ? Float(ha.yaw * .pi / 180) : 0, ha.enabled ? Float(ha.pitch * .pi / 180) : 0,
            Float(RecaptureHandLayer.distance),
            st.framing == .whole ? 1 : 0,
            le.enabled ? Float(le.defocus) : 0, se.enabled ? Float(se.olpf) : 0,
            le.enabled ? Float(le.vignette) : 0,
            gl.enabled ? Float(gl.strength) : 0, Float(gl.size), Float(gl.x), Float(gl.y),
            gl.enabled ? Float(gl.room) : 0,
            sh.enabled ? 1 : 0, Float(phase), Float(sh.kind == .rolling ? sh.readoutMS / 1000 * RecaptureShutterLayer.fieldRate : 0),
            Float(RecaptureShutterLayer.fieldRate / sh.shutter), Float(sh.decayMS / 1000 * RecaptureShutterLayer.fieldRate),
            // The tube's shape under Fill the frame, 0 for 4:3.
            Float(wide ?? 0),
        ]
        // The upright phone's readout sweeps across the frame, its own kernel.
        run(cb, st.camera.readsAcross ? "rc_optics_across" : "rc_optics", [canvas, frames[0]], floats: optics,
            width: w, height: h)

        // 2 Exposure and the Sensor: gain, white balance, noise, the full well, the mosaic.
        var gain = 1.0
        var wb = SIMD3<Double>(1, 1, 1)
        if ex.enabled {
            let ev = ex.bias + ex.hunt * RecaptureLayers.wave(seed: seed, salt: 5, t: t / ex.period, hz: [1, 0.37])
            gain = pow(2, ev)
            wb = RecaptureExposureLayer.balance(kelvin: ex.whiteKelvin)
        }
        run(cb, "rc_sensor", [frames[0], frames[1]],
            floats: [Float(gain), Float(wb.x), Float(wb.y), Float(wb.z),
                     se.enabled ? Float(se.noise) : 0, se.enabled ? Float(se.mosaic) : 0,
                     Float(frame.frameIndex % 65536), Float(seed)],
            width: w, height: h)
        run(cb, "rc_demosaic", [frames[1], frames[0]], floats: [se.enabled ? Float(se.mosaic) : 0],
            width: w, height: h)

        // 3 Processing: noise reduction, sharpening and the encode, then the codec.
        run(cb, "rc_denoise", [frames[0], frames[1]], floats: [pr.enabled ? Float(pr.denoise) : 0],
            width: w, height: h)
        let sigma = Float(RecaptureProcessingLayer.sharpenSigma)
        run(cb, "crt_blur", [frames[1], frames[2]], floats: [1, 0, sigma], width: w, height: h)
        run(cb, "crt_blur", [frames[2], frames[3]], floats: [0, 1, sigma], width: w, height: h)
        run(cb, "rc_sharpen", [frames[1], frames[3], frames[2]],
            floats: [pr.enabled ? Float(pr.sharpen) : 0, Float(1 / CRTTransferLayer.encodeGamma)],
            width: w, height: h)
        if pr.enabled {
            run(cb, "rc_codec", [frames[2], frames[3]],
                floats: [Float(RecaptureProcessingLayer.step(bitrate: pr.bitrate))],
                width: (w + 7) / 8, height: (h + 7) / 8)
            return frames[3]
        }
        return frames[2]
    }
}
