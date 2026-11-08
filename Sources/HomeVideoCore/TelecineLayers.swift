import Foundation
import Metal

// The Telecine stage (docs/TELECINE.md): how the film became NTSC video, between the Film
// source and the tape. Two routes, a choice in the section: Home transfer (a projector aimed at
// a camcorder, the screen or a mirror box) and Pro telecine (a flying spot or CCD scanner).
// Each runs only its own layers. Off unless its master switch is on, and then the film goes
// through it to 29.97 interlaced at the 720 by 480 raster before the VHS chain. With the Film
// off the framed source goes through it as if the clip were the film.
//
// The frames: every output frame is two fields, the first in time on the odd rows (NTSC DV is
// bottom field first), the second on the even rows. Each field shows the film frame the
// transfer puts there: the Pro cadence counts fields (2:3, 3:3:4, 3:4:4:4), the Home camera
// integrates the projector's flashes over its exposure, row by row on a tube, so a field can
// hold two film frames and its brightness beats against the flash rate. The weights are
// worked out here on the CPU from the blade and field arithmetic, never drawn.
//
// The layers live on `VHSLayers.telecine`, outside `VHSLayers.all`, so the chain, the
// fingerprint and the files read exactly as they would without Telecine while it is unused.
// Kernels: Shaders/Telecine.metal. Every figure is marked READ or INFERRED in docs/TELECINE.md.

/// A Telecine layer is the Film's kind of layer: a switch and a table of typed values.
public typealias TelecineLayer = FilmLayer

/// Which machine made the transfer.
public enum TelecineRoute: String, CaseIterable, Sendable {
    case home, pro
    public var label: String { self == .home ? "Home transfer" : "Pro telecine" }
    static var options: [LayerParameter.Option] { allCases.map { .init(value: $0.rawValue, label: $0.label) } }
}

/// The transfer's quality tier, a starting point for the route's sliders (INFERRED, the tier
/// table in docs/TELECINE.md).
public enum TelecineQuality: String, CaseIterable, Sendable {
    case mall, mid, pro
    public var label: String { ["Mall", "Mid-grade", "Pro"][index] }
    var index: Int { TelecineQuality.allCases.firstIndex(of: self)! }
    static var options: [LayerParameter.Option] { allCases.map { .init(value: $0.rawValue, label: $0.label) } }
}

@MainActor
public final class TelecineLayers {
    /// NTSC field rate, 60000/1001 (READ).
    public nonisolated static let fieldRate = 60000.0 / 1001.0

    /// The master switch, the route and the quality tier. Off by default.
    public let source = TelecineLayer(id: "telecine", name: "Telecine", enabled: false, kernel: nil, [
        .init("route", "Route", choice: TelecineRoute.home.rawValue, TelecineRoute.options),
        .init("quality", "Quality", choice: TelecineQuality.mall.rawValue, TelecineQuality.options),
    ])
    /// Both routes: Pro counts fields by the film's speed, Home runs the projector free.
    public let cadence = TelecineLayer(id: "telecine-cadence", name: "Cadence", kernel: nil, [
        .init("speed", "Film speed (Pro)", choice: "film",
              [.init(value: "film", label: "As shot"), .init(value: "24", label: "24 fps, 2:3"),
               .init(value: "18", label: "18 fps, 3:3:4"), .init(value: "16", label: "16 fps, 3:4:4:4")]),
        .init("projector", "Projector speed (fps, Home)", 18, 14...26),
    ])
    public let flicker = TelecineLayer(id: "telecine-flicker", name: "Shutter flicker", kernel: nil, [
        .init("blades", "Shutter blades", choice: "3",
              [.init(value: "2", label: "2"), .init(value: "3", label: "3"), .init(value: "5", label: "5")]),
        .init("camera", "Camera", choice: "tube", [.init(value: "tube", label: "Tube"), .init(value: "ccd", label: "CCD")]),
        .init("shutter", "CCD shutter (1/s)", 60, 60...250),
    ])
    public let light = TelecineLayer(id: "telecine-light", name: "Projector light", kernel: "tc_light", [
        .init("hotspot", "Hot spot (%)", 35, 0...50),
        .init("falloff", "Falloff (%)", 40, 0...60),
        .init("lamp", "Lamp (K)", 3000, 2800...3400),
    ])
    public let geometry = TelecineLayer(id: "telecine-geometry", name: "Geometry", kernel: "tc_geometry", [
        .init("keystone", "Keystone (deg)", 4, 0...10),
        .init("edge", "Gate edge", 0.6, 0...1),
        .init("texture", "Screen texture", 0.6, 0...1),
    ])
    public let camera = TelecineLayer(id: "telecine-camera", name: "Camera", kernel: "tc_camera", [
        .init("softness", "Softness", 0.5, 0...1),
        .init("lag", "Tube lag", 0.5, 0...1),
        .init("hunt", "Iris and white balance hunt", 0.6, 0...1),
        .init("glow", "Glow", 0.4, 0...1),
        .init("seed", "Seed", 0, 0...999),
    ])
    public let scanner = TelecineLayer(id: "telecine-scanner", name: "Scanner", kernel: "tc_scanner", [
        .init("afterglow", "Afterglow", 0.3, 0...1),
        .init("noise", "Noise", 0.4, 0...1),
        .init("streaks", "CCD streaks", 0, 0...1),
        .init("seed", "Seed", 0, 0...999),
    ])
    public let grade = TelecineLayer(id: "telecine-grade", name: "Grade", kernel: "tc_grade", [
        .init("liftR", "Lift red", 0, -0.1...0.1),
        .init("liftG", "Lift green", 0, -0.1...0.1),
        .init("liftB", "Lift blue", 0, -0.1...0.1),
        .init("gammaR", "Gamma red", 1, 0.5...2),
        .init("gammaG", "Gamma green", 1, 0.5...2),
        .init("gammaB", "Gamma blue", 1, 0.5...2),
        .init("gainR", "Gain red", 1, 0.5...1.5),
        .init("gainG", "Gain green", 1, 0.5...1.5),
        .init("gainB", "Gain blue", 1, 0.5...1.5),
        .init("fade", "Fade correction", 0, 0...1),
    ])
    public let gate = TelecineLayer(id: "telecine-gate", name: "Gate", kernel: "tc_gate", [
        .init("dust", "Dust and hair", 0.7, 0...1),
        .init("bump", "Splice bump", 1, 0...1),
        .init("weave", "Weave (px)", 0.6, 0...1),
        .init("overscan", "Overscan (%)", 8, 0...10),
        .init("seed", "Seed", 0, 0...999),
    ])

    /// In the sidebar's order, the master first.
    public var all: [TelecineLayer] { [source, cadence, flicker, light, geometry, camera, scanner, grade, gate] }

    /// The layers each route runs and shows. Cadence and Gate belong to both.
    public func layers(for route: TelecineRoute) -> [TelecineLayer] {
        route == .home ? [cadence, flicker, light, geometry, camera, gate] : [cadence, scanner, grade, gate]
    }

    /// The parameters of a shared layer that one route shows (the Cadence's two speeds).
    public func parameters(of layer: TelecineLayer, route: TelecineRoute) -> [LayerParameter] {
        guard layer === cadence else { return layer.parameters }
        return layer.parameters.filter { $0.id == (route == .home ? "projector" : "speed") }
    }

    public init() {
        // A tier sets the route's layers to its row of the tier table. A new route takes the
        // tier as it stands. The sliders stay free after either.
        source.onSet = { [unowned self] id, _ in
            if id == "quality" || id == "route" { self.applyQuality() }
        }
    }

    // MARK: State

    public var isOn: Bool { source.enabled }
    public var route: TelecineRoute { TelecineRoute(rawValue: source.choice("route")) ?? .home }
    public var quality: TelecineQuality { TelecineQuality(rawValue: source.choice("quality")) ?? .mall }
    public var isAtDefault: Bool { all.allSatisfy(\.isAtDefault) }
    public func restoreDefaults() { for l in all { l.restoreDefaults() } }

    /// The tier table (INFERRED, docs/TELECINE.md).
    public static func tier(_ q: TelecineQuality, route: TelecineRoute) -> [(layer: String, parameter: String, value: ParameterValue)] {
        let i = q.index
        func f(_ l: String, _ p: String, _ v: [Double]) -> (String, String, ParameterValue) { (l, p, .float(v[i])) }
        func c(_ l: String, _ p: String, _ v: [String]) -> (String, String, ParameterValue) { (l, p, .choice(v[i])) }
        let gate = [
            f("telecine-gate", "dust", [0.7, 0.3, 0.05]),
            f("telecine-gate", "bump", [1, 0.6, 0.3]),
            f("telecine-gate", "weave", [0.6, 0.35, 0.1]),
            f("telecine-gate", "overscan", [8, 5, 3]),
        ]
        switch route {
        case .home:
            // Each tier's blades and projector speed set its beat: Mall 3 at 18 fps (54 flashes,
            // the strong 6 Hz beat), Mid-grade the telecine projector's 5 at 24 fps (120 flashes,
            // two a field), Pro 3 at 20 fps (60, the READ fix). Five blades at 18 fps would be
            // 90 flashes, a 29.9 Hz beat that flashes the fields bright and dark.
            return [
                f("telecine-cadence", "projector", [18, 24, 20]),
                c("telecine-flicker", "blades", ["3", "5", "3"]),
                c("telecine-flicker", "camera", ["tube", "ccd", "ccd"]),
                f("telecine-flicker", "shutter", [60, 60, 60]),
                f("telecine-light", "hotspot", [35, 12, 3]),
                f("telecine-light", "falloff", [40, 15, 5]),
                f("telecine-light", "lamp", [3000, 3150, 3200]),
                f("telecine-geometry", "keystone", [4, 0.5, 0]),
                f("telecine-geometry", "edge", [0.6, 0.25, 0]),
                f("telecine-geometry", "texture", [0.6, 0.1, 0]),
                f("telecine-camera", "softness", [0.5, 0.3, 0.15]),
                f("telecine-camera", "lag", [0.5, 0.15, 0.05]),
                f("telecine-camera", "hunt", [0.6, 0.25, 0.05]),
                f("telecine-camera", "glow", [0.4, 0.2, 0.1]),
            ] + gate
        case .pro:
            return [
                c("telecine-cadence", "speed", ["film", "film", "film"]),
                f("telecine-scanner", "afterglow", [0.3, 0.15, 0.05]),
                f("telecine-scanner", "noise", [0.4, 0.25, 0.1]),
                f("telecine-scanner", "streaks", [0, 0.15, 0.05]),
                f("telecine-grade", "fade", [0, 0.5, 1]),
            ] + gate
        }
    }

    func applyQuality() {
        for (l, p, v) in Self.tier(quality, route: route) {
            all.first { $0.id == l }?.setParameter(p, to: v)
        }
    }

    // MARK: Cadence

    /// The Pro pulldown for a film speed: fields per film frame, repeating (READ: 2:3 for 24,
    /// 3:3:4 for 18, 3:4:4:4 for 16).
    public nonisolated static func pulldown(speed: Int) -> [Int] {
        switch speed {
        case 16: return [3, 4, 4, 4]
        case 18: return [3, 3, 4]
        default: return [2, 3]
        }
    }

    /// The film frame a field shows under a pulldown: field 0 starts the cycle.
    public nonisolated static func cadenceFrame(field: Int64, pulldown: [Int]) -> Int64 {
        let period = Int64(pulldown.reduce(0, +))
        let cycle = field >= 0 ? field / period : (field - period + 1) / period
        var r = field - cycle * period
        var frame = cycle * Int64(pulldown.count)
        for n in pulldown {
            if r < Int64(n) { break }
            r -= Int64(n)
            frame += 1
        }
        return frame
    }

    /// The film speed "As shot" assumes with the Film off, where there is no Film frame rate to
    /// read: 24 fps, the sound speed a telecine is built around, so 2:3 (INFERRED). The
    /// Home route needs none, its projector's speed is its own slider.
    public nonisolated static let speedWithoutFilm = 24

    /// The Pro film speed in whole fps: the Cadence's choice, or the Film's frame rate (24 with
    /// the Film off).
    public func proSpeed(film: FilmLayers) -> Int {
        let s = cadence.choice("speed")
        guard s == "film" else { return Int(s) ?? 24 }
        return film.isOn ? Int(film.frameRate) : TelecineLayers.speedWithoutFilm
    }

    /// Film frames per second through the transfer: the projector's speed at Home, the Pro
    /// speed slowed by 1000/1001 (READ, 23.976 for 24) on a telecine.
    public func transferRate(film: FilmLayers) -> Double {
        route == .home ? cadence.float("projector") : Double(proSpeed(film: film)) * 1000 / 1001
    }

    // MARK: Home exposure

    /// The share of each projector frame cycle a blade leaves open. INFERRED: half, the blades
    /// and the gaps alike. The pulldown happens behind the last blade.
    public nonisolated static let bladeDuty = 0.5

    /// Is the projector's light on the screen at time t, and from which film frame.
    nonisolated static func projected(_ t: Double, rate: Double, blades: Int) -> (lit: Bool, frame: Int64) {
        let u = t * rate
        let frame = floor(u)
        let v = u - frame
        let w = v * Double(blades)
        return (w - floor(w) < bladeDuty, Int64(frame))
    }

    /// The light one camera row gathers over its exposure, per film frame: the first frame in
    /// the window and the next. 1 is the average a steady exposure of this length would get, so
    /// a camera with its iris set for the screen reads 1 on average and the beat is the swing
    /// about it. A tube reads each row a field after the last read, its rows at their scan
    /// time down the field (a rolling band). A CCD exposes the whole field over its shutter,
    /// ending at the field time.
    public nonisolated static func exposure(fieldTime: Double, row: Double, rate: Double, blades: Int,
                                            tube: Bool, shutter: Double) -> (first: Int64, a: Double, b: Double) {
        let period = 1 / fieldRate
        let end = tube ? fieldTime + row * period : fieldTime
        let length = tube ? period : 1 / shutter
        let start = end - length
        let first = Int64(floor(start * rate))
        let n = 240
        var a = 0.0, b = 0.0
        for i in 0..<n {
            let t = start + (Double(i) + 0.5) / Double(n) * length
            let p = projected(t, rate: rate, blades: blades)
            guard p.lit else { continue }
            if p.frame <= first { a += 1 } else { b += 1 }
        }
        let norm = Double(n) * bladeDuty
        return (first, a / norm, b / norm)
    }

    /// The beat a camera at the field rate sees against the projector's flashes: the flash
    /// rate's distance to the nearest multiple of the field rate (18 fps by 3 blades is 54
    /// flashes, about 6 Hz against 59.94).
    public nonisolated static func beat(rate: Double, blades: Int) -> Double {
        let flashes = rate * Double(blades)
        return abs(flashes - fieldRate * (flashes / fieldRate).rounded())
    }

    // MARK: Rendering

    private var temps: [MTLTexture] = []
    private var cache: [(frame: Int64, texture: MTLTexture)] = []
    /// What the cached film frames were drawn under: where Framing put the source, every Film
    /// setting, and the Telecine's film side (the route, the speeds, the gate, the projector's
    /// light and the screen). A pan, zoom or rotation moved since, or a Look or a slider
    /// changed, drops them and the camera's lag of the old picture, so the transfer draws them
    /// again.
    private struct CacheKey: Equatable {
        var placement: FramingLayer.Placement
        var film: FilmLayers.Settings
        var switches: [Bool]
        var values: [[String: ParameterValue]]
    }
    private var cacheKey: CacheKey?
    private var free: [MTLTexture] = []
    private var fields: [MTLTexture] = []
    private var lag: [MTLTexture] = []
    private var lagCurrent = 0
    private var hasLag = false
    private var out: MTLTexture?
    private var compose: MTLComputePipelineState?
    private var interlace: MTLComputePipelineState?
    private var prepared = false

    /// Clears the frames held for the cadence and the camera's lag, before an export's frame 0
    /// or after a seek.
    public func reset() {
        free += cache.map(\.texture)
        cache.removeAll()
        hasLag = false
    }

    func prepare(device: MTLDevice, library: MTLLibrary) throws {
        guard !prepared else { return }
        for l in all { try l.prepare(device: device, library: library) }
        compose = try makePipeline("tc_compose", device: device, library: library)
        interlace = try makePipeline("tc_interlace", device: device, library: library)
        let w = SignalChain.rasterWidth, h = SignalChain.rasterHeight
        func make(_ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else {
                throw ShaderLibrary.LoadError.noLibrary("could not allocate \(label)")
            }
            t.label = label
            return t
        }
        temps = try (0..<2).map { try make("telecine temp \($0)") }
        free = try (0..<4).map { try make("telecine frame \($0)") }
        fields = try (0..<2).map { try make("telecine field \($0)") }
        lag = try (0..<2).map { try make("telecine lag \($0)") }
        out = try make("telecine out")
        prepared = true
    }

    /// One field's plan: its time and the rows' film frames and weights.
    struct FieldPlan {
        var index: Int64
        var time: Double
        var first: Int64
        /// Per raster row: the first frame's weight and the next frame's.
        var weights: [Float]
    }

    /// The two fields of the output frame at `time`, the first in time first.
    func plan(time: Double, film: FilmLayers) -> [FieldPlan] {
        let rate = transferRate(film: film)
        let f0 = 2 * Int64((time * TelecineLayers.fieldRate / 2).rounded())
        let h = SignalChain.rasterHeight
        return (0..<2).map { k in
            let f = f0 + Int64(k)
            let t = Double(f) / TelecineLayers.fieldRate
            // No cadence: the film frame at the output frame's time in both fields, whole, as a
            // transfer locked to the frame.
            let locked = Int64(floor(time * rate + 1e-6))
            if !cadence.enabled && (route == .pro || !flicker.enabled) {
                return FieldPlan(index: f, time: t, first: locked, weights: (0..<2 * h).map { $0 % 2 == 0 ? 1 : 0 })
            }
            if route == .pro {
                let m = TelecineLayers.cadenceFrame(field: f, pulldown: TelecineLayers.pulldown(speed: proSpeed(film: film)))
                return FieldPlan(index: f, time: t, first: m, weights: (0..<2 * h).map { $0 % 2 == 0 ? 1 : 0 })
            }
            let blades = Int(flicker.choice("blades")) ?? 3
            let tube = flicker.choice("camera") != "ccd"
            let shutter = flicker.float("shutter")
            // Without the Shutter flicker layer the camera sees the frame on the screen at the
            // field time, steady.
            guard flicker.enabled else {
                let m = Int64(floor(t * rate))
                return FieldPlan(index: f, time: t, first: m, weights: (0..<2 * h).map { $0 % 2 == 0 ? 1 : 0 })
            }
            var w = [Float](repeating: 0, count: 2 * h)
            var first = Int64.max
            var rows: [(first: Int64, a: Double, b: Double)] = []
            for y in 0..<h {
                let e = TelecineLayers.exposure(fieldTime: t, row: (Double(y) + 0.5) / Double(h), rate: rate,
                                                blades: blades, tube: tube, shutter: shutter)
                rows.append(e)
                first = min(first, e.first)
            }
            if !cadence.enabled {
                // The flicker alone: each row's light, all of it on the locked frame.
                for (y, e) in rows.enumerated() { w[2 * y] = Float(e.a + e.b) }
                return FieldPlan(index: f, time: t, first: locked, weights: w)
            }
            for (y, e) in rows.enumerated() {
                // Each row's two frames, placed against the field's first.
                if e.first == first {
                    w[2 * y] = Float(e.a); w[2 * y + 1] = Float(e.b)
                } else {
                    w[2 * y] = 0; w[2 * y + 1] = Float(e.a + e.b)
                }
            }
            return FieldPlan(index: f, time: t, first: first, weights: w)
        }
    }

    /// The transfer of one output frame: the film frames it needs, each through the gate (and
    /// at Home the projector and the screen), the two fields composed and through the camera
    /// or the scanner, then woven into the frame. Returns a raster texture the Telecine owns.
    func encode(commandBuffer cb: MTLCommandBuffer, film: FilmLayers, source: MTLTexture, framing: FramingLayer,
                frame ctx: FrameContext, device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        try film.prepare(device: device, library: library)
        try prepare(device: device, library: library)
        guard let out, let compose, let interlace else { throw ShaderLibrary.LoadError.noLibrary("telecine") }
        let rate = transferRate(film: film)
        let filmSide = [self.source, cadence, gate, light, geometry]
        let key = CacheKey(placement: framing.placement, film: film.settings, switches: filmSide.map(\.enabled),
                           values: filmSide.map(\.values))
        if cacheKey != key {
            free += cache.map(\.texture)
            cache.removeAll()
            hasLag = false
            cacheKey = key
        }
        let plans = plan(time: ctx.time, film: film)
        let needed = Set(plans.flatMap { [$0.first, $0.first + 1] })
        // Frames behind the earliest needed are done with.
        let low = needed.min() ?? 0
        for (i, c) in cache.enumerated().reversed() where c.frame < low || cache.count > 4 {
            free.append(c.texture)
            cache.remove(at: i)
        }
        var rendered = false
        for m in needed.sorted() where !cache.contains(where: { $0.frame == m }) {
            // Only the frames a field actually weighs: the next frame of a field is drawn when
            // a row needs it.
            let used = plans.contains { p in
                if p.first == m { return true }
                guard p.first + 1 == m else { return false }
                return stride(from: 1, to: p.weights.count, by: 2).contains { p.weights[$0] > 0 }
            }
            guard used else { continue }
            if free.isEmpty, let oldest = cache.indices.min(by: { cache[$0].frame < cache[$1].frame }) {
                free.append(cache.remove(at: oldest).texture)
            }
            let slot = free.removeLast()
            try renderFrame(cb, film: film, source: source, framing: framing, ctx: ctx, n: m, rate: rate,
                            into: slot, device: device)
            cache.append((m, slot))
            rendered = true
        }
        if !rendered, film.isOn { film.advance(commandBuffer: cb, source: source, framing: framing, frame: ctx) }
        func picture(_ m: Int64) -> MTLTexture? {
            cache.first { $0.frame == m }?.texture ?? cache.max(by: { $0.frame < $1.frame })?.texture
        }
        for (k, p) in plans.enumerated() {
            guard let a = picture(p.first), let enc = cb.makeComputeCommandEncoder() else { continue }
            let b = cache.first { $0.frame == p.first + 1 }?.texture ?? a
            enc.label = "Telecine field"
            enc.setComputePipelineState(compose)
            enc.setTexture(a, index: 0)
            enc.setTexture(b, index: 1)
            enc.setTexture(temps[0], index: 2)
            p.weights.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            dispatch2D(enc, pipeline: compose, width: out.width, height: out.height)
            enc.endEncoding()
            var cur = temps[0], other = temps[1]
            let fieldLayers: [TelecineLayer] = route == .home ? [camera] : [scanner, grade]
            for layer in fieldLayers where layer.enabled {
                encodeField(layer, cb: cb, in: cur, out: other, plan: p, film: film)
                swap(&cur, &other)
            }
            blit(cb, from: cur, to: fields[k])
        }
        guard let enc = cb.makeComputeCommandEncoder() else { return out }
        enc.label = "Telecine interlace"
        enc.setComputePipelineState(interlace)
        enc.setTexture(fields[0], index: 0)
        enc.setTexture(fields[1], index: 1)
        enc.setTexture(out, index: 2)
        dispatch2D(enc, pipeline: interlace, width: out.width, height: out.height)
        enc.endEncoding()
        return out
    }

    /// Film frame `n` through the film-side stages: the film itself, the gate, and at Home the
    /// projector's light and the screen as the camera frames it. With the Film off the film
    /// frame is the framed source at that moment, as if the clip were the film.
    private func renderFrame(_ cb: MTLCommandBuffer, film: FilmLayers, source: MTLTexture, framing: FramingLayer,
                             ctx: FrameContext, n: Int64, rate: Double, into slot: MTLTexture, device: MTLDevice) throws {
        let stages: [TelecineLayer] = ([gate] + (route == .home ? [light, geometry] : [])).filter(\.enabled)
        let first = stages.isEmpty ? slot : temps[0]
        if film.isOn {
            try film.encodeFrame(commandBuffer: cb, source: source, framing: framing, frame: ctx, film: n, rate: rate,
                                 into: first, device: device)
        } else {
            framing.encode(commandBuffer: cb, in: source, out: first, frame: ctx)
        }
        var cur = first, other = temps[1]
        for (i, layer) in stages.enumerated() {
            let dst = i == stages.count - 1 ? slot : other
            encodeFrameStage(layer, cb: cb, in: cur, out: dst, film: film, n: n, rate: rate)
            other = cur
            cur = dst
        }
    }

    private func blit(_ cb: MTLCommandBuffer, from: MTLTexture, to: MTLTexture) {
        guard let b = cb.makeBlitCommandEncoder() else { return }
        b.copy(from: from, to: to)
        b.endEncoding()
    }

    private func run(_ layer: TelecineLayer, cb: MTLCommandBuffer, textures: [MTLTexture], values: [Float],
                     width: Int, height: Int) {
        guard let pipeline = layer.pipeline, let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Telecine \(layer.name)"
        enc.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        setFloats(enc, values, index: 0)
        dispatch2D(enc, pipeline: pipeline, width: width, height: height)
        enc.endEncoding()
    }

    private func encodeFrameStage(_ layer: TelecineLayer, cb: MTLCommandBuffer, in input: MTLTexture,
                                  out output: MTLTexture, film: FilmLayers, n: Int64, rate: Double) {
        let values: [Float]
        switch layer.id {
        case "telecine-gate": values = gateTable(film: film, n: n, rate: rate)
        case "telecine-light": values = lightValues().map(Float.init)
        default: values = geometryValues().map(Float.init)
        }
        run(layer, cb: cb, textures: [input, output], values: values, width: output.width, height: output.height)
    }

    private func encodeField(_ layer: TelecineLayer, cb: MTLCommandBuffer, in input: MTLTexture,
                             out output: MTLTexture, plan p: FieldPlan, film: FilmLayers) {
        switch layer.id {
        case "telecine-camera":
            let prev = lag[lagCurrent], next = lag[1 - lagCurrent]
            run(layer, cb: cb, textures: [input, output, prev, next],
                values: cameraValues(time: p.time).map(Float.init), width: output.width, height: output.height)
            lagCurrent = 1 - lagCurrent
            hasLag = true
        case "telecine-scanner":
            run(layer, cb: cb, textures: [input, output], values: scannerValues(field: p.index),
                width: output.width, height: output.height)
        default:
            run(layer, cb: cb, textures: [input, output], values: gradeValues(film: film).map(Float.init),
                width: output.width, height: output.height)
        }
    }

    // MARK: Values per layer

    /// The raster's pixel aspect, width over height of one pixel (8/9 for 720 by 480 at 4:3).
    nonisolated static let aspect = (4.0 / 3.0) / (720.0 / 480.0)
    /// The display aspect of the transfer under Fill the frame: the wide frame squeezed
    /// onto the raster, as a widescreen transfer to tape was. Nil for 4:3. Set by the chain.
    public var displayAspect: Double?
    /// The raster's pixel aspect for the picture the transfer holds: 8/9 at 4:3, wider under Fill.
    var pixelAspect: Double { displayAspect.map { $0 / (720.0 / 480.0) } ?? TelecineLayers.aspect }

    /// A lamp at `kelvin` against the camera set for 3200 K tungsten, linear gains with the
    /// luminance kept: Planck's law at 610, 550 and 465 nm (INFERRED, the camera's indoor
    /// preset).
    public nonisolated static func lampGain(kelvin: Double) -> SIMD3<Double> {
        func planck(_ nm: Double, _ k: Double) -> Double {
            let l = nm * 1e-9
            return 1 / (pow(l, 5) * (exp(1.4388e-2 / (l * k)) - 1))
        }
        func ratio(_ nm: Double) -> Double { planck(nm, kelvin) / planck(nm, 3200) }
        var g = SIMD3(ratio(610), ratio(550), ratio(465))
        g /= 0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z
        return g
    }

    func lightValues() -> [Double] {
        let g = TelecineLayers.lampGain(kelvin: light.float("lamp"))
        // The last value is the picture's shape under Fill the frame, 0 for 4:3.
        return [light.float("hotspot") / 100, light.float("falloff") / 100, g.x, g.y, g.z, pixelAspect,
                displayAspect ?? 0]
    }

    func geometryValues() -> [Double] {
        [tan(geometry.float("keystone") * .pi / 180), geometry.float("edge"), geometry.float("texture"),
         pixelAspect, displayAspect ?? 0]
    }

    /// The camcorder: softness, its tube's lag, the iris and white balance hunting, its glow.
    /// The hunting is two slow wanders (INFERRED, about 0.3 and 0.7 Hz): up to half a stop and
    /// a few percent of red against blue at full.
    func cameraValues(time t: Double) -> [Double] {
        let hunt = camera.float("hunt")
        let seed = UInt32(camera.float("seed").rounded())
        let iris = Hash.valueNoise(t * 0.3, 0, seed: seed ^ 0x4952_4953)
        let wb = Hash.valueNoise(t * 0.7, 1, seed: seed ^ 0x5742_4142)
        let exposure = pow(2, 0.5 * hunt * iris)
        let r = 1 + 0.06 * hunt * wb, b = 1 - 0.06 * hunt * wb
        // Tube lag: the charge left behind decays by this share per field (INFERRED, no figure
        // found: a Saticon's comet tail lasts several fields at full).
        let keep = 0.5 + 0.42 * camera.float("lag")
        return [camera.float("softness") * 1.5, camera.float("lag") > 0 ? keep : 0, hasLag ? 1 : 0,
                camera.float("glow"), exposure * r, exposure, exposure * b, pixelAspect]
    }

    /// The flying spot's afterglow tail, the photomultiplier noise and a CCD's column streaks.
    /// The tail: about 20 us (READ, the afterglow corrector's delay span of 20 to 50 us in US
    /// patent 5,278,653), 13.7 raster px per
    /// us over the 52.6 us active line.
    func scannerValues(field: Int64) -> [Float] {
        let tau = 20.0 * 720 / 52.6
        let seed = UInt32(scanner.float("seed").rounded())
        return [Float(scanner.float("afterglow")), Float(tau), Float(scanner.float("noise")),
                Float(scanner.float("streaks")), Float(bitPattern: seed &* 0x9E37_79B1 ^ 0x5343_4E52),
                Float(bitPattern: UInt32(truncatingIfNeeded: field))]
    }

    /// The colorist's primaries, and the fade correction: a gray balance against the film's
    /// dye loss, with half its lost contrast put back (INFERRED). The fade takes each channel
    /// to the power k (`film_fade`), so white and black stay neutral and the cast is in the
    /// tones between. The correction takes each channel to the power s/k, one contrast s for
    /// all three, so every tone comes out gray, white still white: s is halfway from the fade's
    /// mean contrast back to the film's own. A gain per channel would pin mid gray and tint
    /// white the other way, turning a faded magenta reel mint green under Pro telecine.
    func gradeValues(film: FilmLayers) -> [Double] {
        let amount = grade.float("fade")
        var k = SIMD3<Double>(1, 1, 1)
        if film.isOn && film.fade.enabled {
            let y = film.fade.float("years"), tau = film.stockChoice.fadeYears
            k = SIMD3(exp(-y / tau.x), exp(-y / tau.y), exp(-y / tau.z))
        }
        let mean = (k.x + k.y + k.z) / 3
        let s = mean + (1 - mean) * 0.5
        func power(_ k: Double) -> Double { 1 + (s / k - 1) * amount }
        return [grade.float("liftR"), grade.float("liftG"), grade.float("liftB"),
                grade.float("gammaR"), grade.float("gammaG"), grade.float("gammaB"),
                grade.float("gainR"), grade.float("gainG"), grade.float("gainB"),
                power(k.x), power(k.y), power(k.z), 1, 1, 1]
    }

    /// The gate for film frame `n`: weave, a splice's bump and flash, the overscan crop, and
    /// the dust and hair the transfer did not clean off. Dust blocks light, so it is dark on a
    /// reversal original and light on a negative (the Film's polarity rule). Table layout in
    /// `tc_gate`.
    func gateTable(film: FilmLayers, n: Int64, rate: Double) -> [Float] {
        var t = [Float](repeating: 0, count: 128)
        let seed = UInt32(gate.float("seed").rounded())
        let n32 = UInt32(truncatingIfNeeded: n)
        let time = Double(n) / max(rate, 1)
        // Weave: the transfer gate's own, smoothed over about three frames, in raster px.
        func smooth(_ salt: UInt32) -> Double {
            let x = Double(n) / 3, i = floor(x), f = x - i
            let s = f * f * (3 - 2 * f)
            let a0 = Hash.signed(seed, salt, UInt32(truncatingIfNeeded: Int64(i)))
            let a1 = Hash.signed(seed, salt, UInt32(truncatingIfNeeded: Int64(i) + 1))
            return 0.75 * (a0 + (a1 - a0) * s) + 0.25 * Hash.signed(seed, salt &+ 1, n32)
        }
        let weave = gate.float("weave")
        var dx = weave * smooth(0x5443_5701), dy = weave * 0.8 * smooth(0x5443_5702)
        // A splice through the gate: the frame jumps up to 10 lines for two frames, with a
        // flash on the first (INFERRED, the tier table's "jump and flash"), one a minute.
        var flash = 1.0
        let bump = gate.float("bump")
        if bump > 0 {
            let sched = DamageSchedule(salt: 0x5443_5350, seed: Int(seed), ratePerSecond: 1.0 / 60,
                                       shortest: 2 / max(rate, 1), longest: 2 / max(rate, 1))
            if let e = sched.events(from: time, to: time + 1e-6).first {
                dy += bump * 10 * (0.5 + 0.5 * e.u)
                if time - e.start < 1 / max(rate, 1) { flash = 1 + 0.35 * bump }
            }
        }
        t[0] = Float(dx); t[1] = Float(dy)
        t[2] = Float(1 - gate.float("overscan") / 100)
        t[3] = Float(flash)
        // With the Film off the clip stands in for a positive, a print or a reversal original.
        t[4] = film.isOn && film.stockChoice.isNegative ? 1 : -1
        t[5] = Float(pixelAspect)
        // Dust: up to 10 specks a frame at full, a third of frames clean (INFERRED).
        let dust = gate.float("dust")
        func u(_ a: UInt32, _ b: UInt32) -> Double { (Hash.signed(seed, 0x5443_4453, n32, a, b) + 1) / 2 }
        var specks = 0
        if dust > 0, u(0, 0) > 0.33 {
            specks = min(20, Int((dust * 10 * (0.3 + u(0, 1))).rounded()))
            for i in 0..<specks {
                let o = 16 + i * 4, k = UInt32(i + 1)
                t[o] = Float(u(k, 1)); t[o + 1] = Float(u(k, 2))
                t[o + 2] = Float(0.6 + 2.4 * pow(u(k, 3), 2))
                t[o + 3] = Float(0.5 + 0.5 * u(k, 4))
            }
        }
        t[6] = Float(specks)
        // A hair caught in the gate, half a second to three, up to three a minute at full.
        if dust > 0 {
            let sched = DamageSchedule(salt: 0x5443_4852, seed: Int(seed), ratePerSecond: dust * 3 / 60,
                                       shortest: 0.5, longest: 3)
            if let e = sched.events(from: time, to: time + 1e-6).first {
                func hu(_ j: UInt32) -> Double { (Hash.signed(seed, 0x5443_4852, UInt32(truncatingIfNeeded: e.index), j) + 1) / 2 }
                let x0 = hu(1) < 0.5 ? 0.0 : 1.0, y0 = 0.15 + 0.7 * hu(2)
                let flutter = 0.004 * Hash.signed(seed, 0x464C, n32)
                let pts = [x0, y0, abs(x0 - 0.07 - 0.08 * hu(3)), y0 + 0.08 * (hu(4) - 0.5) + flutter,
                           abs(x0 - 0.12 - 0.1 * hu(5)), y0 + 0.12 * (hu(6) - 0.5) - flutter]
                for (j, v) in pts.enumerated() { t[100 + j] = Float(v) }
                t[7] = 1
                t[106] = Float(1.0 + 0.8 * dust)
            }
        }
        return t
    }
}
