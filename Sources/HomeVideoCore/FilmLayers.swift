import Foundation
import Metal
import Observation

// The Film source (docs/FILM.md): what a home movie camera and its stock do to the
// picture, ahead of everything else, since film is what shot it. Off unless its master switch
// is on, and then it replaces the camcorder stage. The stage switches say where the picture
// goes: with Tape off it is a film scan (the Scan, the VHS chain bypassed), with Tape on it
// goes through the VHS chain as the Look sets it, and with Telecine on through the transfer.
//
// The layers live on `VHSLayers.film` but outside `VHSLayers.all`, so the chain's
// fingerprint, the clipboard and a sidecar read exactly as they would without Film while
// Film is unused. Looks, Reset, user presets and sidecars reach them through
// `VHSLayers.lookLayers`. Kernels: Shaders/Film.metal. Every figure is marked READ or
// INFERRED in docs/FILM.md.

// MARK: - Choices

/// The gauge. Grain, halation, blur and weave scale with the frame's width against Super 8's
/// 5.46 mm (camera aperture widths: Regular 8 4.8, Super 8 5.46, 16mm 10.26, 35mm Academy 22.0 mm).
public enum FilmFormat: String, CaseIterable, Sendable {
    case regular8, super8, sixteen, thirtyFive

    public var label: String { ["Regular 8", "Super 8", "16mm", "35mm"][index] }
    public var frameWidthMM: Double { [4.8, 5.46, 10.26, 22.0][index] }
    /// Grain, blur and halation on the picture, relative to Super 8: 5.46 over the width.
    public var scale: Double { 5.46 / frameWidthMM }
    /// Weave relative to Super 8 (INFERRED from the doc's defaults, 0.3 percent on Super 8 and
    /// 0.1 on 16mm, Regular 8's camera gate like Super 8's, 35mm's pin registered gate half
    /// of 16mm's).
    public var weave: Double { [1.0, 1.0, 1.0 / 3.0, 1.0 / 6.0][index] }

    var index: Int { FilmFormat.allCases.firstIndex(of: self)! }
    static var options: [LayerParameter.Option] { allCases.map { .init(value: $0.rawValue, label: $0.label) } }
}

/// The stock. Reversal stocks are projected or scanned as they are, negatives are printed or
/// scanned and inverted, which sets the polarity of dust and the tone curve.
public enum FilmStock: String, CaseIterable, Sendable {
    case kodachrome40, ektachrome160, fujiR25N, vision50D, vision500T

    public var label: String {
        ["Kodachrome 40", "Ektachrome 160", "Fuji R25N", "Vision3 50D", "Vision3 500T"][index]
    }
    public var isNegative: Bool { self == .vision50D || self == .vision500T }
    /// Balanced for daylight (else tungsten, Type A or T). READ: K40 3400 K, R25N daylight,
    /// 50D daylight, 500T tungsten. Ektachrome 160 Type A is INFERRED from the Super 8 G stock.
    public var daylight: Bool { self == .fujiR25N || self == .vision50D }
    /// Saturation in the doc's 0.8 to 1.4 (INFERRED by stock character: Kodachrome and Fuji
    /// rich, Ektachrome 160 plainer, a scanned negative flatter).
    public var saturation: Double { [1.25, 1.05, 1.2, 0.92, 0.88][index] }
    /// The stock's own cast, linear gains (INFERRED: Kodachrome warm, Ektachrome cool, Fuji green).
    public var cast: SIMD3<Double> {
        [SIMD3(1.03, 0.99, 0.95), SIMD3(0.97, 0.99, 1.05), SIMD3(0.98, 1.03, 0.99),
         SIMD3(1.0, 1.0, 1.0), SIMD3(1.01, 1.0, 0.99)][index]
    }
    /// Grain size and amplitude against an average stock. Kodachrome 40's RMS 9 is READ as
    /// "extremely fine", Vision3 50D "finest grain" READ. The reversal stocks' absolute amounts
    /// and every size stay INFERRED: the public domain scans are H.264 access copies, which
    /// quantize away the absolute amplitude and set the size by the scanner and the encoder.
    /// 500T's amount is READ against 50D's: Kodak's diffuse RMS granularity at normal exposure,
    /// luminance weighted, is 8.76 for 500T and 4.71 for 50D, a ratio of 1.86, so 0.65 times
    /// 1.86 is 1.21.
    public var grainSize: Double { [0.85, 1.3, 0.9, 0.7, 1.4][index] }
    public var grainAmount: Double { [0.8, 1.3, 0.9, 0.65, 1.21][index] }
    /// Grain amplitude against each dye layer's encoded value at 0, 0.25, 0.5, 0.75 and 1,
    /// interpolated in `film_grain`, 1 at 0.5 (the temporal residual of 8 public domain scans
    /// on the Internet Archive, sigma per luminance bin). A color reversal
    /// original loses its grain toward the highlights, where little dye is left. A negative is
    /// flat from the shadows of the positive up through its highlights, as Kodak's sigma D is
    /// flat across the straight line.
    /// - Kodachrome 40: MEASURED on Moquin_1965_1, moquin-1956-2 and pepe02, INFERRED for K40
    ///   since the named reels are 1956 Kodachrome Daylight.
    /// - Ektachrome 160: MEASURED on casfmta_000017 (Ektachrome ER, 16mm), INFERRED for 160 Type A.
    /// - Fuji R25N: INFERRED, a slow daylight reversal like Kodachrome (no data, no scan).
    /// - Vision3 50D: MEASURED shape on cstmaah_000019 (the one negative, black and white),
    ///   agreeing with the READ flat sigma D from 2 stops under to 4 over.
    /// - Vision3 500T: INFERRED, cstmaah_000019's shape with the READ rise of 500T's green sigma
    ///   D at 2 stops under (9.8 against 8.2 at normal) in the shadows.
    public var grainCurve: [Double] {
        [[1.2, 1.0, 1.0, 0.45, 0.2], [0.5, 1.0, 1.0, 0.5, 0.35], [1.2, 1.0, 1.0, 0.45, 0.2],
         [0.6, 0.93, 1.0, 0.97, 1.0], [0.6, 1.1, 1.0, 0.97, 1.0]][index]
    }
    /// Per dye layer (red, green, blue) grain amount and size against the stock's own, green 1,
    /// as measured, and the share of each layer's field that is its own rather than the three
    /// layers' shared part (0.3, INFERRED). Blue is the grainiest layer on every stock.
    /// - Kodachrome 40: amount 1.0, 1.0, 1.05 and size 1.0, 1.0, 1.05, MEASURED on the Moquin
    ///   pair, at the floor the 4:2:0 encode adds (the black and white control reads 1.04).
    /// - Ektachrome 160: amount 1.19, 1.0, 1.37 MEASURED on casfmta_000017, size 1.1, 1.0, 1.1
    ///   MEASURED there, part of it the chroma subsampling.
    /// - Fuji R25N: amount 1.0, 1.0, 1.1 and size 1.0, 1.0, 1.05, INFERRED from the reversal
    ///   reels' range.
    /// - Vision3 50D: amount 1.07, 1.0, 2.09 READ from Kodak's diffuse RMS granularity at normal
    ///   exposure (R 4.6, G 4.3, B 9.0), size 1.0, 1.0, 1.1 INFERRED (no size per layer published).
    /// - Vision3 500T: amount 0.80, 1.0, 2.52 READ the same way (R 6.6, G 8.2, B 20.7), size 1.0,
    ///   1.0, 1.1 INFERRED. Kodak's blue is a density figure, the yellow dye image, and a scanner's
    ///   own channel gains change what lands in the picture.
    /// The amounts are then divided by their luminance weighted mean (0.2126, 0.7152, 0.0722), so
    /// the luminance grain stays the stock's `grainAmount` and Strength keeps its meaning. The
    /// factors: Kodachrome 40 1.0036, Ektachrome 160 1.0671, Fuji R25N 1.0072, Vision3 50D
    /// 1.0936, Vision3 500T 1.0672.
    public var grainPerChannel: (size: SIMD3<Double>, amount: SIMD3<Double>, own: Double) {
        let size = [SIMD3(1.0, 1.0, 1.05), SIMD3(1.1, 1.0, 1.1), SIMD3(1.0, 1.0, 1.05),
                    SIMD3(1.0, 1.0, 1.1), SIMD3(1.0, 1.0, 1.1)][index]
        let amount = [SIMD3(1.0, 1.0, 1.05), SIMD3(1.19, 1.0, 1.37), SIMD3(1.0, 1.0, 1.1),
                      SIMD3(1.07, 1.0, 2.09), SIMD3(0.80, 1.0, 2.52)][index]
        return (size, amount / (amount * Self.lumaWeights).sum(), 0.3)
    }
    static let lumaWeights = SIMD3(0.2126, 0.7152, 0.0722)
    /// Reversal contrast (Kodachrome's "relatively high" READ), the negative's gentler curve.
    /// On top of a source already graded for viewing, so modest: Kodachrome's 1.1 is about 1.25
    /// times the source's slope at mid gray over 7 stops (INFERRED, by eye).
    public var contrast: Double { [1.1, 0.8, 1.0, 1.0, 1.0][index] }
    /// Latitude in stops: reversal 7 (doc 6 to 8), negative 12 (doc "about 12").
    public var latitude: Double { isNegative ? 12 : 7 }
    /// Halation against Super 8 reversal. Vision3 carries rem-jet backing (READ), INFERRED at 0.3.
    public var halation: Double { isNegative ? 0.3 : 1.0 }
    /// Years for each dye (cyan, magenta, yellow) to keep 1/e of its density. Kodachrome's
    /// yellow loses 20 percent in 185 years (READ), so 830, its others INFERRED slower.
    /// E-4 era Ektachrome lives about 30 years (READ) with cyan and yellow first (INFERRED).
    /// Fuji and the negatives INFERRED.
    public var fadeYears: SIMD3<Double> {
        [SIMD3(2000, 2000, 830), SIMD3(45, 160, 60), SIMD3(120, 220, 150),
         SIMD3(400, 600, 500), SIMD3(400, 600, 500)][index]
    }

    var index: Int { FilmStock.allCases.firstIndex(of: self)! }
    static var options: [LayerParameter.Option] { allCases.map { .init(value: $0.rawValue, label: $0.label) } }
}

/// The light the film was shot under.
public enum FilmLight: String, CaseIterable, Sendable {
    case daylight, tungsten, fluorescent, lowLight

    public var label: String { ["Daylight", "Tungsten", "Fluorescent", "Low light"][index] }
    var index: Int { FilmLight.allCases.firstIndex(of: self)! }
    static var options: [LayerParameter.Option] { allCases.map { .init(value: $0.rawValue, label: $0.label) } }

    /// The residual cast (linear gains, luminance kept) and the filter loss in stops, for a
    /// stock balanced for daylight or tungsten. A home camera carries a built in 85 filter for
    /// tungsten stock in daylight and nothing for daylight stock under lamps. Kodachrome 40's
    /// 85A loss 0.68 stops is READ (40 to 25), 2 stops for an 80A on daylight stock READ (50D
    /// EI 12), uncorrected fluorescent reads green and lamps on daylight stock orange (READ
    /// from the corrections the data sheets ask for). The gains are INFERRED.
    func cast(daylightStock: Bool) -> (gain: SIMD3<Double>, loss: Double, extraStops: Double) {
        switch (self, daylightStock) {
        case (.daylight, false): return (SIMD3(1.02, 1.0, 0.97), 0.68, 0)
        case (.tungsten, false): return (SIMD3(1.05, 1.0, 0.92), 0, 0)
        case (.fluorescent, false): return (SIMD3(1.0, 1.10, 0.86), 0.68, 0)
        case (.lowLight, false): return (SIMD3(1.12, 1.0, 0.80), 0, 1)
        case (.daylight, true): return (SIMD3(1, 1, 1), 0, 0)
        case (.tungsten, true): return (SIMD3(1.30, 1.0, 0.58), 0, 0)
        case (.fluorescent, true): return (SIMD3(0.96, 1.12, 0.94), 0, 0)
        case (.lowLight, true): return (SIMD3(1.38, 1.0, 0.52), 0, 1)
        }
    }
}

/// The Film output choice an older file carries. The stage switches say where the film goes
/// (Film with Tape off is the Scan, Film with Tape on goes onto the tape, Telecine on routes it
/// through the transfer), so the choice is only read from an old file and folded in
/// (`VHSLayers.foldLegacyFilmOutput`).
public enum FilmOutput: String, CaseIterable, Sendable {
    case scan, tape, telecine
}

// MARK: - One Film layer

/// One Film layer: a switch and a table of typed values, each a slider over its range or a
/// picker. `FilmLayers` encodes it with its kernel and the values the other layers lend it.
@MainActor
@Observable
public final class FilmLayer: Layer {
    public struct Spec: Sendable {
        public var id: String
        public var name: String
        public var value: ParameterValue
        public var range: ClosedRange<Double>
        public var options: [LayerParameter.Option]
        init(_ id: String, _ name: String, _ value: Double, _ range: ClosedRange<Double>) {
            self.id = id; self.name = name; self.value = .float(value); self.range = range; options = []
        }
        init(_ id: String, _ name: String, choice: String, _ options: [LayerParameter.Option]) {
            self.id = id; self.name = name; value = .choice(choice); range = 0...1; self.options = options
        }
    }

    public let id: String
    public let name: String
    public var enabled: Bool
    public let defaultEnabled: Bool
    public private(set) var values: [String: ParameterValue]
    @ObservationIgnored public let specs: [Spec]
    @ObservationIgnored let kernel: String?
    @ObservationIgnored var pipeline: MTLComputePipelineState?
    /// Called after a value is set, so one layer can move another (the Stock sets the Tone).
    @ObservationIgnored var onSet: ((String, ParameterValue) -> Void)?
    /// Called for an id the layer no longer has, so an old file's value can be folded in.
    @ObservationIgnored var onUnknown: ((String, ParameterValue) -> Void)?

    init(id: String, name: String, enabled: Bool = true, kernel: String?, _ specs: [Spec]) {
        self.id = id
        self.name = name
        self.enabled = enabled
        defaultEnabled = enabled
        self.kernel = kernel
        self.specs = specs
        values = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0.value) })
    }

    public var parameters: [LayerParameter] {
        specs.map { s in
            LayerParameter(id: s.id, name: s.name, value: values[s.id] ?? s.value, range: s.range, options: s.options)
        }
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        guard let s = specs.first(where: { $0.id == id }) else {
            onUnknown?(id, value)
            return
        }
        switch (s.value, value) {
        case (.float, .float(let v)) where v.isFinite:
            values[id] = .float(clamped(v, s.range))
        case (.choice, .choice(let c)) where s.options.contains(where: { $0.value == c }):
            values[id] = .choice(c)
        case (.choice, .float(let v)) where v.isFinite:
            // A number for a choice of numbers (the frame rate, the scan size) from the render tool.
            let c = String(Int(v.rounded()))
            if s.options.contains(where: { $0.value == c }) { values[id] = .choice(c) } else { return }
        default:
            return
        }
        onSet?(id, values[id]!)
    }

    public func float(_ id: String) -> Double { values[id]?.doubleValue ?? 0 }
    public func choice(_ id: String) -> String { values[id]?.choiceValue ?? "" }

    /// Every value and the switch back to the layer as built.
    func restoreDefaults() {
        enabled = defaultEnabled
        for s in specs { values[s.id] = s.value }
    }

    var isAtDefault: Bool {
        enabled == defaultEnabled && specs.allSatisfy { s in
            guard let v = values[s.id] else { return true }
            if case .float(let a) = v, case .float(let b) = s.value { return abs(a - b) < 1e-9 }
            return v == s.value
        }
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        if let kernel, pipeline == nil { pipeline = try makePipeline(kernel, device: device, library: library) }
    }

    /// Film layers run inside `FilmLayers.encode`, never as chain steps. Kept a copy so the
    /// protocol's contract (every pixel written) holds if one is ever listed in a chain.
    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let b = commandBuffer.makeBlitCommandEncoder() else { return }
        b.copy(from: input, to: output)
        b.endEncoding()
    }
}

// MARK: - The Film source

/// The Film layers, the master switch first, built and wired, and the canvas they run on.
@MainActor
public final class FilmLayers {
    /// The master switch and the scan's detail. Off by default. Where the film goes is the
    /// stages' switches: Tape off is the Scan. The detail is how fine the film is scanned, never
    /// the file's size, as with the Display's Detail. The raw values stay for files.
    public let source = FilmLayer(id: "film", name: "Film", enabled: false, kernel: nil, [
        .init("scan", "Scan detail", choice: "1440",
              [.init(value: "1440", label: "Standard"), .init(value: "2880", label: "Fine")]),
    ])
    public let format = FilmLayer(id: "film-format", name: "Format", kernel: "film_format", [
        .init("format", "Format", choice: FilmFormat.super8.rawValue, FilmFormat.options),
        .init("blur", "Blur (px at 1080, Super 8)", 1.6, 0...4),
    ])
    public let stock = FilmLayer(id: "film-stock", name: "Stock", kernel: "film_stock", [
        .init("stock", "Stock", choice: FilmStock.kodachrome40.rawValue, FilmStock.options),
        .init("saturation", "Saturation", FilmStock.kodachrome40.saturation, 0.8...1.4),
    ])
    public let light = FilmLayer(id: "film-light", name: "Light", kernel: "film_light", [
        .init("light", "Light", choice: FilmLight.daylight.rawValue, FilmLight.options),
        .init("under", "Underexposure (stops)", 0, 0...2),
    ])
    public let tone = FilmLayer(id: "film-tone", name: "Tone", kernel: "film_tone", [
        .init("latitude", "Latitude (stops)", 7, 6...14),
        .init("contrast", "Contrast", FilmStock.kodachrome40.contrast, 0.5...2.5),
        .init("drift", "Auto exposure drift (stops)", 0.15, 0...1),
    ])
    public let grain = FilmLayer(id: "film-grain", name: "Grain", kernel: "film_grain", [
        .init("strength", "Strength", 0.5, 0...1),
        .init("size", "Size (px at 1080, Super 8)", 1.2, 0.5...3),
        .init("seed", "Seed", 0, 0...999),
    ])
    public let halation = FilmLayer(id: "film-halation", name: "Halation", kernel: "film_halation", [
        .init("strength", "Strength", 0.15, 0...0.5),
        .init("radius", "Radius (% of width, Super 8)", 1, 0...5),
        .init("threshold", "Threshold", 0.75, 0.3...1),
    ])
    public let weave = FilmLayer(id: "film-weave", name: "Weave", kernel: "film_weave", [
        .init("amount", "Amount (% of width, Super 8)", 0.3, 0...1),
        .init("seed", "Seed", 0, 0...999),
    ])
    public let shutter = FilmLayer(id: "film-shutter", name: "Shutter and flicker", kernel: "film_shutter", [
        .init("fps", "Frame rate", choice: "18", [.init(value: "18", label: "18 fps"), .init(value: "24", label: "24 fps")]),
        .init("angle", "Shutter angle (deg)", 180, 90...230),
        .init("flicker", "Flicker (%)", 1.5, 0...5),
    ])
    public let optics = FilmLayer(id: "film-optics", name: "Optics", kernel: "film_optics", [
        .init("softness", "Softness", 0.25, 0...1),
        .init("vignette", "Vignette (stops)", 0.35, 0...1.5),
        .init("ca", "Lateral CA (px at 1080)", 0.4, 0...2),
    ])
    public let fade = FilmLayer(id: "film-fade", name: "Fade", kernel: "film_fade", [
        .init("years", "Years", 0, 0...50),
    ])
    public let damage = FilmLayer(id: "film-damage", name: "Damage", enabled: false, kernel: "film_damage", [
        .init("dust", "Dust", 0.4, 0...1),
        .init("hair", "Hair", 0.2, 0...1),
        .init("scratches", "Scratches", 0.2, 0...1),
        .init("splices", "Splices (per minute)", 1, 0...6),
        .init("fog", "Roll end fog", 0, 0...1),
        .init("frameLine", "Frame line", 0, 0...1),
        .init("seed", "Seed", 0, 0...999),
    ])

    /// In the sidebar's order, the master first.
    public var all: [FilmLayer] {
        [source, format, stock, light, tone, grain, halation, weave, shutter, optics, fade, damage]
    }

    /// The order the picture goes through them: the shutter's exposure, the light, the lens,
    /// the emulsion's blur and its halation at exposure, the dyes and the curve at the
    /// develop, the grain of the developed image, the years in the can, the dirt at the scan,
    /// and the frame's place in the gate.
    var renderOrder: [FilmLayer] { [shutter, light, optics, format, halation, stock, tone, grain, fade, damage, weave] }

    public init() {
        source.onUnknown = { [unowned self] id, value in
            if id == "output", let old = value.choiceValue.flatMap(FilmOutput.init(rawValue:)) { legacyOutput = old }
        }
        let tone = tone, stock = stock
        // A new stock brings its own saturation, contrast and latitude, as a Look would. Its
        // sliders then move them on their own.
        stock.onSet = { id, value in
            guard id == "stock", let raw = value.choiceValue, let s = FilmStock(rawValue: raw) else { return }
            stock.setParameter("saturation", to: .float(s.saturation))
            tone.setParameter("contrast", to: .float(s.contrast))
            tone.setParameter("latitude", to: .float(s.latitude))
        }
    }

    // MARK: State

    public var isOn: Bool { source.enabled }
    /// An old file's output choice, read and not yet folded into the stage switches.
    public var legacyOutput: FilmOutput?
    public var formatChoice: FilmFormat { FilmFormat(rawValue: format.choice("format")) ?? .super8 }
    public var stockChoice: FilmStock { FilmStock(rawValue: stock.choice("stock")) ?? .kodachrome40 }
    public var lightChoice: FilmLight { FilmLight(rawValue: light.choice("light")) ?? .daylight }
    public var frameRate: Double { Double(shutter.choice("fps")) ?? 18 }

    /// The Scan canvas the film is drawn on: 1440 by 1080 at Standard, 2880 by 2160 at Fine, 4:3
    /// square pixels.
    public var scanSize: (width: Int, height: Int) { source.choice("scan") == "2880" ? (2880, 2160) : (1440, 1080) }
    /// The Standard scan's size, the file's size at Auto whatever the Scan detail.
    public nonisolated static let standardScanSize = (width: 1440, height: 1080)
    /// The display aspect of the picture the Film draws, nil for 4:3. Under Fill the frame
    /// the chain sets the frame's shape before each frame, so every layer works on a wide canvas
    /// (or the raster with the wide picture squeezed into it) as it does on 4:3. Never saved.
    public var displayAspect: Double?

    /// True when every Film layer is as built, so a sidecar or a preset leaves Film out.
    public var isAtDefault: Bool { all.allSatisfy(\.isAtDefault) }

    public func restoreDefaults() { for l in all { l.restoreDefaults() } }

    /// Every Film switch and value and the picture's shape: what a film frame is drawn under.
    struct Settings: Equatable {
        var switches: [Bool]
        var values: [[String: ParameterValue]]
        var display: Double?
    }

    var settings: Settings { Settings(switches: all.map(\.enabled), values: all.map(\.values), display: displayAspect) }

    // MARK: Rendering

    private var textures: [MTLTexture] = []
    /// The grain's field and its softened copy (`encodeGrain`).
    private var fields: [MTLTexture] = []
    private var fieldPipeline: MTLComputePipelineState?
    private var softenPipeline: MTLComputePipelineState?
    private var previous: MTLTexture?
    /// The last film frame's picture, shown again while the source stays inside that frame.
    private var held: MTLTexture?
    private var heldFrame: Int64?
    /// Where Framing put the source when the held frame was drawn. A pan, zoom or rotation
    /// moved since draws the frame again, even while paused.
    private var heldPlacement: FramingLayer.Placement?
    /// The settings the held frame was drawn under. A Look or a slider changed since draws the
    /// frame again, even while paused.
    private var heldSettings: Settings?
    private var hasPrevious = false
    private var lastTime: Double?
    private var sourceInterval = 1.0 / 30
    private var prepared = false

    /// Clears the hold and the previous frame, before an export's frame 0 or after a seek.
    public func reset() {
        heldFrame = nil
        hasPrevious = false
        lastTime = nil
    }

    func prepare(device: MTLDevice, library: MTLLibrary) throws {
        guard !prepared else { return }
        for l in all { try l.prepare(device: device, library: library) }
        fieldPipeline = try makePipeline("film_grain_field", device: device, library: library)
        softenPipeline = try makePipeline("film_grain_soften", device: device, library: library)
        prepared = true
    }

    private func canvas(device: MTLDevice, width: Int, height: Int) throws {
        if let t = held, t.width == width, t.height == height { return }
        textures = try (0..<2).map { try makeTexture(device: device, width: width, height: height, label: "film \($0)") }
        fields = try (0..<2).map { try makeTexture(device: device, width: width, height: height, label: "grain \($0)") }
        previous = try makeTexture(device: device, width: width, height: height, label: "film previous")
        held = try makeTexture(device: device, width: width, height: height, label: "film frame")
        reset()
    }

    private func makeTexture(device: MTLDevice, width: Int, height: Int, label: String) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else {
            throw ShaderLibrary.LoadError.noLibrary("could not allocate \(label)")
        }
        t.label = label
        return t
    }

    /// The film frame a source time falls in. With the Shutter layer on, frames are held to its
    /// rate (18 or 24 fps): every source frame inside one film frame shows the same picture.
    /// Without it, each source frame is its own film frame.
    public func filmFrame(time: Double, frameIndex: UInt64) -> Int64 {
        shutter.enabled ? Int64(floor(time * frameRate + 1e-6)) : Int64(frameIndex)
    }

    /// The film picture for one source frame, `width` by `height`, in a texture the Film owns.
    func encode(commandBuffer cb: MTLCommandBuffer, source: MTLTexture, framing: FramingLayer,
                frame: FrameContext, width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
        try canvas(device: device, width: width, height: height)
        guard let previous, let held else { throw ShaderLibrary.LoadError.noLibrary("film canvas") }
        noteTime(frame.time)
        var ctx = frame
        ctx.rasterSize = CGSize(width: width, height: height)
        let n = filmFrame(time: frame.time, frameIndex: frame.frameIndex)
        let now = settings
        if heldFrame == n && heldPlacement == framing.placement && heldSettings == now {
            // A held frame: only the shutter's previous frame moves on.
            advance(commandBuffer: cb, source: source, framing: framing, frame: ctx, previous: previous)
            return held
        }
        render(cb, source: source, framing: framing, frame: ctx, film: n,
               time: shutter.enabled ? Double(n) / frameRate : frame.time, into: held)
        heldFrame = n
        heldPlacement = framing.placement
        heldSettings = now
        return held
    }

    /// The Telecine's film frame: film frame `n` of a film running `rate` frames a
    /// second through the transfer, drawn from this source frame at the raster into `dst`.
    /// The transfer decides which film frame each field shows, so the Film's own hold is not
    /// used here.
    func encodeFrame(commandBuffer cb: MTLCommandBuffer, source: MTLTexture, framing: FramingLayer,
                     frame: FrameContext, film n: Int64, rate: Double, into dst: MTLTexture,
                     device: MTLDevice) throws {
        let width = SignalChain.rasterWidth, height = SignalChain.rasterHeight
        try canvas(device: device, width: width, height: height)
        noteTime(frame.time)
        var ctx = frame
        ctx.rasterSize = CGSize(width: width, height: height)
        render(cb, source: source, framing: framing, frame: ctx, film: n, time: Double(n) / max(rate, 1), into: dst)
    }

    /// A source frame that draws no new film frame for the Telecine: only the shutter's
    /// previous frame moves on.
    func advance(commandBuffer cb: MTLCommandBuffer, source: MTLTexture, framing: FramingLayer, frame: FrameContext) {
        guard let previous, previous.width == SignalChain.rasterWidth else { return }
        noteTime(frame.time)
        var ctx = frame
        ctx.rasterSize = CGSize(width: previous.width, height: previous.height)
        advance(commandBuffer: cb, source: source, framing: framing, frame: ctx, previous: previous)
    }

    private func advance(commandBuffer cb: MTLCommandBuffer, source: MTLTexture, framing: FramingLayer,
                         frame ctx: FrameContext, previous: MTLTexture) {
        if shutter.enabled {
            framing.encode(commandBuffer: cb, in: source, out: previous, frame: ctx)
            hasPrevious = true
        }
    }

    private func noteTime(_ time: Double) {
        if let t = lastTime {
            let dt = time - t
            if dt > 1e-4, dt < 0.2 { sourceInterval = dt }
        }
        lastTime = time
    }

    /// Film frame `n` through every Film layer that is on, into `dst`.
    private func render(_ cb: MTLCommandBuffer, source: MTLTexture, framing: FramingLayer, frame ctx: FrameContext,
                        film n: Int64, time: Double, into dst: MTLTexture) {
        guard let previous else { return }
        // The canvas: framing places the source at the canvas size, as it does the raster.
        var cur = 0
        framing.encode(commandBuffer: cb, in: source, out: textures[0], frame: ctx)
        let f = FilmFrame(width: dst.width, height: dst.height, film: n, time: time, display: displayAspect)
        for layer in renderOrder where layer.enabled {
            encode(layer, cb: cb, in: textures[cur], out: textures[1 - cur], frame: f)
            // The framed source of this frame is the next one's previous.
            if layer === shutter { blit(cb, from: textures[cur], to: previous) }
            cur = 1 - cur
        }
        hasPrevious = shutter.enabled
        blit(cb, from: textures[cur], to: dst)
    }

    private func blit(_ cb: MTLCommandBuffer, from: MTLTexture, to: MTLTexture) {
        guard let b = cb.makeBlitCommandEncoder() else { return }
        b.copy(from: from, to: to)
        b.endEncoding()
    }

    /// The canvas a layer draws on: its size, the pixel aspect (width over height of one
    /// pixel, 1 on the Scan canvas, 8/9 on the raster) and canvas px per 1080 line px. `display`
    /// is the picture's shape under Fill the frame, nil for 4:3.
    struct FilmFrame {
        var width: Int, height: Int
        var film: Int64
        var time: Double
        var display: Double? = nil
        var aspect: Double { (display ?? 4.0 / 3.0) / (Double(width) / Double(height)) }
        var unit: Double { Double(height) / 1080 }
        var film32: UInt32 { UInt32(truncatingIfNeeded: film) }
    }

    private func encode(_ layer: FilmLayer, cb: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                        frame f: FilmFrame) {
        if layer === grain {
            encodeGrain(cb, in: input, out: output, frame: f)
            return
        }
        guard let pipeline = layer.pipeline, let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Film \(layer.name)"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        if layer === shutter, let previous {
            enc.setTexture(hasPrevious ? previous : input, index: 2)
        }
        let values: [Float]
        if layer === damage {
            values = damageTable(frame: f)
        } else {
            values = floats(for: layer, frame: f).map { Float($0) }
        }
        setFloats(enc, values, index: 0)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }

    /// The grain in three steps: the field, the field through the scan's softening (the Format
    /// Gaussian at the scan's share, `grainSoftening`), the field on the picture. So the grain's
    /// spectrum is the scan's MTF times the field's own: never sharper than the scan, and about
    /// twice as sharp as the picture, which also went through the lens and the emulsion.
    private func encodeGrain(_ cb: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture, frame f: FilmFrame) {
        guard let fieldPipeline, let softenPipeline, let addPipeline = grain.pipeline, fields.count == 2 else { return }
        func pass(_ pipeline: MTLComputePipelineState, _ label: String, _ textures: [MTLTexture?],
                  _ values: [Float], _ out: MTLTexture) {
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.label = label
            enc.setComputePipelineState(pipeline)
            for (i, t) in textures.enumerated() where t != nil { enc.setTexture(t, index: i) }
            setFloats(enc, values, index: 0)
            dispatch2D(enc, pipeline: pipeline, width: out.width, height: out.height)
            enc.endEncoding()
        }
        let seed = UInt32(grain.float("seed").rounded()) &* 0x9E37_79B1 ^ 0x4649_4C4D
        let pc = stockChoice.grainPerChannel
        let soft = grainSoftening(f)
        let gains = grainGains(f, softening: soft)
        pass(fieldPipeline, "Film Grain field", [nil, fields[0]],
             [Float(grainCell(f)), Float(f.aspect), Float(pc.own), Float(bitPattern: seed), Float(bitPattern: f.film32),
              Float(pc.size.x), Float(pc.size.y), Float(pc.size.z),
              Float(gains.common), Float(gains.own.x), Float(gains.own.y), Float(gains.own.z)], fields[0])
        var cur = 0
        for s in soft {
            pass(softenPipeline, "Film Grain soften", [fields[cur], fields[1 - cur]],
                 [Float(s.sigma), Float(f.aspect)], fields[1 - cur])
            cur = 1 - cur
        }
        pass(addPipeline, "Film Grain", [input, output, fields[cur]],
             ([grainAmplitude] + stockChoice.grainCurve + [pc.amount.x, pc.amount.y, pc.amount.z]).map { Float($0) },
             output)
    }

    // MARK: Values per layer

    /// The previous frame's share in the shutter's exposure: the shutter is open angle/360 of
    /// a film frame, which covers `open / interval` source frames. Past one, the previous
    /// source frame is blended in.
    var shutterBlend: Double {
        let open = shutter.float("angle") / 360 / frameRate
        let extra = clamped(open / max(sourceInterval, 1e-3) - 1, 0...1)
        return extra / (1 + extra)
    }

    /// Exposure flicker: the camera's shutter speed varying frame to frame, plus or minus the
    /// slider's percent.
    func flickerGain(_ f: FilmFrame) -> Double {
        1 + shutter.float("flicker") / 100 * Hash.signed(0x4649_4C4B, f.film32, UInt32(truncatingIfNeeded: f.film >> 32))
    }

    /// The light's cast and exposure for the stock. A negative's scan is timed, so most of the
    /// cast is graded out (INFERRED, a third remains).
    func lightValues() -> (gain: SIMD3<Double>, exposure: Double) {
        let s = stockChoice, l = lightChoice
        let c = l.cast(daylightStock: s.daylight)
        var g = c.gain
        if s.isNegative { g = SIMD3(pow(g.x, 0.35), pow(g.y, 0.35), pow(g.z, 0.35)) }
        let y = 0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z
        g /= y
        // The meter makes up the filter's loss in good light. Indoors the lens is wide open, so
        // under fluorescent and low light the loss is real (INFERRED).
        let loss = (l == .fluorescent || l == .lowLight) ? c.loss : 0
        let stops = light.float("under") + c.extraStops + loss
        return (g, pow(2, -stops))
    }

    /// Auto exposure hunting: a slow wander of up to the drift slider in stops (INFERRED, two
    /// slow sines at 0.23 and 0.61 Hz).
    func autoExposure(_ f: FilmFrame) -> Double {
        let d = tone.float("drift")
        guard d > 0 else { return 1 }
        let t = f.time
        return pow(2, d * (0.6 * sin(2 * .pi * 0.23 * t + 1.1) + 0.4 * sin(2 * .pi * 0.61 * t + 2.7)))
    }

    var grainAmplitude: Double {
        let s = stockChoice
        var a = grain.float("strength") * 0.2 * s.grainAmount * formatChoice.scale.squareRoot()
        // An underexposed negative is printed up, and its grain comes up with it (INFERRED).
        if s.isNegative { a *= pow(2, 0.5 * light.float("under")) }
        return a
    }

    func grainCell(_ f: FilmFrame) -> Double {
        grain.float("size") * formatChoice.scale * stockChoice.grainSize * f.unit
    }

    /// One softening step on the grain field: the format's Gaussian, at its sigma in canvas px
    /// (vertical).
    struct GrainSoftening: Equatable {
        var sigma: Double
    }

    /// The scan's share of the Format blur's sigma (INFERRED from MEASURED ratios). The
    /// Format blur is the whole spread of the image on the scan: the camera original's own (the
    /// lens's focus, the light scattered in the emulsion before the dye forms) and the scanner's.
    /// The picture takes all of it, the grain only the scanner's, since the grain is the dye
    /// clouds themselves and never went through the lens or the emulsion's scatter. In 8 public
    /// domain scans the grain keeps half its amplitude at 1.68 to 2.13 times the picture's MTF50
    /// (median 1.9). The Optics softness at its default takes
    /// only 4 percent of the picture's MTF50 (0.1117 against the Format kernel's own 0.1158
    /// cycles per px on Super 8), so the scan has to be a part of the Format blur. Swept on the
    /// GPU (GrainMTFTests, the 7 film Looks): a share of 0.45 reads 1.41 to 1.78, 0.35 reads 1.56
    /// to 1.98, 0.3 reads 1.66 to 2.12 (Super 8 Kodachrome 2.05, 16mm News 1.68), 0.2 reads 1.88
    /// to 2.38. At 0.3 the 16mm grain is held by the field's own cell more than by the scan.
    static let grainScanShare = 0.3

    /// The softening the grain field takes: the scan alone, the Format layer's Gaussian with its
    /// own taps and sampler at the scan's share of its sigma. The lens (Optics) and the rest of
    /// the Format blur stay on the picture, before the grain.
    func grainSoftening(_ f: FilmFrame) -> [GrainSoftening] {
        guard format.enabled else { return [] }
        return [.init(sigma: floats(for: format, frame: f)[0] * Self.grainScanShare)]
    }

    /// The gains that put back the RMS the softening takes from the field: the shared part's
    /// and each dye layer's own. The field's mean variance after a linear filter `h` is the sum
    /// over tap pairs of h_m h_n times the field's autocorrelation at m - n. Value noise is a
    /// lattice under a smoothstep tent, so its autocorrelation is the tent's own, separable in
    /// x and y, at the lag over the cell (the cell in x is cell / aspect px).
    func grainGains(_ f: FilmFrame, softening: [GrainSoftening]) -> (common: Double, own: SIMD3<Double>) {
        guard !softening.isEmpty else { return (1, SIMD3(1, 1, 1)) }
        let hy = Self.grainKernel(softening, scale: 1)
        let hx = Self.grainKernel(softening, scale: 1 / f.aspect)
        func ratio(_ cell: Double) -> Double {
            let c = max(cell, 0.5)
            return Self.grainVariance(hx, cell: c / f.aspect) * Self.grainVariance(hy, cell: c)
        }
        let cell = grainCell(f)
        let common = (ratio(cell) + 0.25 * ratio(cell / 2)) / 1.25
        let size = stockChoice.grainPerChannel.size
        func gain(_ r: Double) -> Double { 1 / max(r, 1e-6).squareRoot() }
        return (gain(common), SIMD3(gain(ratio(cell * size.x)), gain(ratio(cell * size.y)), gain(ratio(cell * size.z))))
    }

    /// The softening on one axis as weights on whole px, lag 0 at index `offset`: each tap of
    /// each step split between its two neighbors as the linear sampler does, the steps
    /// convolved in turn. `scale` takes vertical px to the axis's px (1 / aspect across).
    static func grainKernel(_ steps: [GrainSoftening], scale: Double) -> (weights: [Double], offset: Int) {
        var h: [Int: Double] = [0: 1]
        for s in steps {
            let sigma = max(s.sigma, 0.01), step = max(sigma * 2.5 / 3, 0.35)
            let taps = (-3...3).map { i in (Double(i) * step, exp(-Double(i * i) * step * step / (2 * sigma * sigma))) }
            let total = taps.reduce(0) { $0 + $1.1 }
            var k: [Int: Double] = [:]
            for (o, w) in taps {
                let x = o * scale, lo = floor(x), t = x - lo
                k[Int(lo), default: 0] += w / total * (1 - t)
                k[Int(lo) + 1, default: 0] += w / total * t
            }
            var next: [Int: Double] = [:]
            for (a, wa) in h { for (b, wb) in k { next[a + b, default: 0] += wa * wb } }
            h = next
        }
        let lo = h.keys.min() ?? 0, hi = h.keys.max() ?? 0
        return ((lo...hi).map { h[$0] ?? 0 }, -lo)
    }

    /// The field's variance after the filter over its variance before, on one axis.
    static func grainVariance(_ h: (weights: [Double], offset: Int), cell: Double) -> Double {
        var v = 0.0
        for (m, a) in h.weights.enumerated() where a != 0 {
            for (n, b) in h.weights.enumerated() where b != 0 {
                v += a * b * tentCorrelation(Double(m - n) / cell)
            }
        }
        return v
    }

    /// The smoothstep tent's autocorrelation at a lag in cells, 1 at 0, 0 from 2 cells on:
    /// the integral of K(x) K(x + u) over the integral of K squared, K(x) = 1 - S(|x|).
    nonisolated static let tentTable: [Double] = {
        func k(_ x: Double) -> Double {
            let a = abs(x)
            return a >= 1 ? 0 : 1 - a * a * (3 - 2 * a)
        }
        let n = 2048
        func corr(_ u: Double) -> Double {
            (0..<n).reduce(0) { s, i in
                let x = -1 + (Double(i) + 0.5) * 2 / Double(n)
                return s + k(x) * k(x + u)
            }
        }
        let zero = corr(0)
        return (0...256).map { corr(Double($0) / 128) / zero }
    }()

    static func tentCorrelation(_ u: Double) -> Double {
        let x = abs(u) * 128
        guard x < 256 else { return 0 }
        let i = Int(x), t = x - Double(i)
        return tentTable[i] * (1 - t) + tentTable[i + 1] * t
    }

    func weaveOffset(_ f: FilmFrame) -> (dx: Double, dy: Double) {
        let a = weave.float("amount") / 100 * formatChoice.weave
        let seed = UInt32(weave.float("seed").rounded())
        // Smoothed over about four frames, with a little of each frame's own.
        func smooth(_ salt: UInt32) -> Double {
            let x = Double(f.film) / 4, i = floor(x), t = x - i
            let s = t * t * (3 - 2 * t)
            let a0 = Hash.signed(seed, salt, UInt32(truncatingIfNeeded: Int64(i)))
            let a1 = Hash.signed(seed, salt, UInt32(truncatingIfNeeded: Int64(i) + 1))
            return 0.7 * (a0 + (a1 - a0) * s) + 0.3 * Hash.signed(seed, salt &+ 1, f.film32)
        }
        // In canvas px: x on the display width, y on the height.
        let w = Double(f.height) * 4 / 3
        return (smooth(0x5745_0001) * a * w / f.aspect, 0.8 * smooth(0x5745_0002) * a * w)
    }

    func floats(for layer: FilmLayer, frame f: FilmFrame) -> [Double] {
        switch layer.id {
        case "film-shutter":
            return [shutterBlend, flickerGain(f)]
        case "film-light":
            let v = lightValues()
            return [v.gain.x, v.gain.y, v.gain.z, v.exposure]
        case "film-optics":
            // The fifth value is the picture's shape under Fill the frame, 0 for 4:3.
            return [optics.float("softness") * 1.5 * f.unit, optics.float("vignette"), optics.float("ca") * f.unit, f.aspect,
                    f.display ?? 0]
        case "film-format":
            return [format.float("blur") * formatChoice.scale * f.unit, f.aspect]
        case "film-halation":
            let r = halation.float("radius") / 100 * formatChoice.scale * Double(f.height) * 4 / 3
            return [halation.float("threshold"), halation.float("strength") * stockChoice.halation, r, f.aspect,
                    1.0, 0.18, 0.04]
        case "film-stock":
            let c = stockChoice.cast
            return [stock.float("saturation"), c.x, c.y, c.z]
        case "film-tone":
            return [stockChoice.isNegative ? 1 : 0, tone.float("latitude"),
                    tone.float("contrast"), autoExposure(f)]
        case "film-fade":
            let y = fade.float("years"), tau = stockChoice.fadeYears
            return [exp(-y / tau.x), exp(-y / tau.y), exp(-y / tau.z)]
        case "film-weave":
            let o = weaveOffset(f)
            return [o.dx, o.dy]
        default:
            return [0]
        }
    }

    // MARK: Damage

    /// The damage table for one film frame (see `film_damage`). Dust lands fresh on every
    /// frame. Hair, scratches and splices are sporadic events from `DamageSchedule`, seeded,
    /// so a render repeats exactly. Rates and sizes are INFERRED (docs/FILM.md).
    func damageTable(frame f: FilmFrame) -> [Float] {
        var t = [Float](repeating: 0, count: 256)
        let seed = Int(damage.float("seed").rounded())
        let mixed = DamageSchedule.mix(seed)
        t[0] = stockChoice.isNegative ? 1 : -1
        t[3] = Float(f.aspect)
        t[10] = Float(f.unit)
        func u(_ a: UInt32, _ b: UInt32) -> Double { (Hash.signed(mixed, 0x4455_5354, f.film32, a, b) + 1) / 2 }
        // Dust: a third of frames clean, the rest a few specks, up to 14 at full.
        let dust = damage.float("dust")
        var specks = 0
        if dust > 0, u(0, 0) > 0.3 {
            specks = min(48, Int((dust * 14 * (0.3 + u(0, 1))).rounded()))
            for i in 0..<specks {
                let o = 16 + i * 4, k = UInt32(i + 1)
                t[o] = Float(u(k, 1)); t[o + 1] = Float(u(k, 2))
                t[o + 2] = Float(0.8 + 5 * pow(u(k, 3), 3))
                t[o + 3] = Float(0.55 + 0.45 * u(k, 4))
            }
        }
        t[4] = Float(specks)
        // Scratches: a run of the film dragged on grit in the gate, 2 to 12 s, a few a minute.
        let scratch = damage.float("scratches")
        let time = f.time
        var ns = 0
        if scratch > 0 {
            let sched = DamageSchedule(salt: 0x5343_5241, seed: seed, ratePerSecond: scratch * 6 / 60,
                                       shortest: 2, longest: 12)
            for e in sched.events(from: time, to: time + 1e-6).prefix(4) {
                let o = 208 + ns * 4
                let wobble = 0.002 * sin(time * 1.7 + e.u * 9)
                t[o] = Float(0.08 + 0.84 * e.u + wobble)
                t[o + 1] = Float(1.0 + 1.5 * scratch)
                t[o + 2] = Float(0.35 + 0.5 * scratch)
                ns += 1
            }
        }
        t[5] = Float(ns)
        // Hair: caught in the gate for half a second to three, fluttering frame to frame.
        let hair = damage.float("hair")
        var nh = 0
        if hair > 0 {
            let sched = DamageSchedule(salt: 0x4841_4952, seed: seed, ratePerSecond: hair * 4 / 60,
                                       shortest: 0.5, longest: 3)
            for e in sched.events(from: time, to: time + 1e-6).prefix(3) {
                let o = 224 + nh * 10
                func hu(_ j: UInt32) -> Double { (Hash.signed(mixed, 0x4841_4952, UInt32(truncatingIfNeeded: e.index), j) + 1) / 2 }
                // From an edge into the frame.
                let edgeX = hu(1) < 0.5 ? 0.0 : 1.0
                let y0 = 0.15 + 0.7 * hu(2)
                let flutter = 0.004 * Hash.signed(mixed, 0x464C, f.film32, UInt32(nh))
                let pts: [Double] = [edgeX, y0,
                                     abs(edgeX - 0.08 - 0.1 * hu(3)), y0 + 0.1 * (hu(4) - 0.5) + flutter,
                                     abs(edgeX - 0.12 - 0.12 * hu(5)), y0 + 0.15 * (hu(6) - 0.5) - flutter,
                                     abs(edgeX - 0.18 - 0.15 * hu(7)), y0 + 0.2 * (hu(8) - 0.5)]
                for (j, v) in pts.enumerated() { t[o + j] = Float(v) }
                t[o + 8] = Float(1.2 + 1.2 * hair)
                t[o + 9] = Float(0.6 + 0.4 * hair)
                nh += 1
            }
        }
        t[6] = Float(nh)
        // A splice: two frames with the cement overlap's band.
        let rate = damage.float("splices")
        if rate > 0 {
            let len = 2 / frameRate
            let sched = DamageSchedule(salt: 0x5350_4C43, seed: seed, ratePerSecond: rate / 60,
                                       shortest: len, longest: len)
            if let e = sched.events(from: time, to: time + 1e-6).first {
                let top = 0.1 + 0.75 * e.u
                t[7] = Float(top); t[8] = Float(top + 0.06); t[9] = 0.8
            }
        }
        // Roll end fog: full over the first two seconds (the leader end), then a quarter.
        let fog = damage.float("fog")
        if fog > 0 { t[1] = Float(fog * (time < 2 ? 1 - 0.75 * time / 2 : 0.25)) }
        t[2] = Float(damage.float("frameLine") * 0.06)
        return t
    }
}
