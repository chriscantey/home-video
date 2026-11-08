import Foundation
import Metal
import Observation

// The Damage layers: optional event layers on top of any Look, each with a switch, a Strength
// (0 to 1, how hard each event hits), a Rate (how often events come) and a Seed (0 to 999).
// Each Rate defaults to the frequency an earlier version gave the layer's default Strength, so
// a file saved without a Rate plays the same events. Every one is off by default. Events are a pure
// function of the seed and the source time
// (`DamageSchedule`), so a render repeats exactly, a paused frame is stable, and a different
// seed is a different take. Every rate, length and depth names its source here and in
// docs/SIGNAL-CHAIN.md, "Damage".
//
// The four picture layers share one kernel, `damage_events` in Shaders/Damage.metal: each
// layer works out a table of twelve floats per raster line on the CPU (shift, noise, chroma
// gain, blur, a span with its kind, level and fuzz) and the kernel applies it. They run in
// YIQ inside the chain, on the tape, after the link into the deck and before the playback stages
// (luma bandwidth,
// color-under, tape noise, dropouts, halo, head switch, time base), so those soften and
// smear the damage as they do the picture. `SignalChain.standard()` sets that order.

/// The tape geometry the damage numbers come from. Distances in mm, speeds in mm/s. Sources:
/// the repair FAQ's VHS table (https://www.repairfaq.org/REPAIR/F_vcrfaqd.html: SP 33.3375
/// mm/s, track widths, pitch 58/39/19 um), de.wikipedia "Video Home System" (62 mm drum, EP
/// 11.12 mm/s, track length 97.34 mm), en.wikipedia "VHS" (1798.2 rpm NTSC).
public enum VHSGeometry {
    /// Linear tape speed per speed setting, NTSC: SP 33.34, LP 16.67, EP 11.12 mm/s.
    public static func tapeSpeed(_ s: TapeSpeed) -> Double {
        switch s {
        case .sp: return 33.34
        case .lp: return 16.67
        case .ep: return 11.12
        }
    }

    /// Head to tape writing speed: the 62 mm drum at 1798.2 rpm moves its heads at 5.84 m/s,
    /// with the tape, so 5.80 m/s relative to it.
    public static let writingSpeed = 5_800.0
    /// One field's video track, 97.34 mm long, at 5.96 degrees to the tape edge (the
    /// standard's angle. The sources fetched say "about 5 degrees", which moves the span
    /// below by 0.2 percent).
    public static let trackLength = 97.34
    public static let trackAngleDegrees = 5.96
    /// The track's length along the tape: 97.34 cos(5.96 deg), 96.8 mm.
    public static var trackSpanAlongTape: Double { trackLength * cos(trackAngleDegrees * .pi / 180) }
    /// FM luma carrier, the middle of the 3.4 to 4.4 MHz deviation (US patent 4,597,021).
    public static let carrierHz = 3.9e6
    /// The carrier's wavelength on tape, um: 5.8 m/s over 3.9 MHz, 1.49 um.
    public static var carrierWavelength: Double { writingSpeed * 1_000 / carrierHz }
    /// Mono linear audio track width, mm.
    public static let linearAudioTrackWidth = 1.0

    /// Wallace's spacing loss in dB for a gap `d` um at wavelength `lambda` um: 54.6 d / lambda.
    public static func spacingLossDB(spacing d: Double, wavelength lambda: Double) -> Double {
        lambda > 0 ? 54.6 * d / lambda : 0
    }
}

/// When a damage layer's events land: a pure function of (layer salt, seed, time). Time is cut
/// into slots as long as the longest event, and each slot holds at most one event, which
/// starts there with probability 1 - exp(-rate * w * slot) (a Poisson process thinned to one
/// per slot). Start offset and length come from the same hash, so asking about any time window
/// gives the same events.
///
/// Sporadic, not steady, and still deterministic: damage on a tape comes in bad stretches, the BBC's
/// "occasional bursts" (Monograph 57). So the rate is weighted per 15 s stretch of tape by
/// w = 4 u^3, u uniform from the seed: the mean of w is 1, so the long run rate is still
/// Strength times the maximum, but half the stretches carry under half of it, one in five is
/// nearly clean (w < 0.03), and one in ten carries 2.9 times it or more. The stretch length and the cube are INFERRED.
public struct DamageSchedule: Equatable, Sendable {
    public struct Event: Equatable, Sendable {
        /// The slot number, unique per event.
        public var index: Int64
        public var start: Double
        public var length: Double
        /// A spare uniform 0 to 1 the layer may use (a position, a polarity).
        public var u: Double
        public var end: Double { start + length }

        /// A raised cosine over the event: 0 at both ends, 1 in the middle, the edges taking
        /// `ramp` seconds each (half the length at most).
        public func envelope(at t: Double, ramp: Double) -> Double {
            guard t >= start, t < end else { return 0 }
            let r = min(ramp, length / 2)
            guard r > 0 else { return 1 }
            let edge = min(t - start, end - t)
            guard edge < r else { return 1 }
            return 0.5 - 0.5 * cos(.pi * edge / r)
        }
    }

    public var salt: UInt32
    public var seed: UInt32
    public var ratePerSecond: Double
    public var shortest: Double
    public var longest: Double

    public init(salt: UInt32, seed: Int, ratePerSecond: Double, shortest: Double, longest: Double) {
        self.salt = salt
        self.seed = DamageSchedule.mix(seed)
        self.ratePerSecond = max(0, ratePerSecond)
        self.shortest = max(1e-4, min(shortest, longest))
        self.longest = max(1e-4, max(shortest, longest))
    }

    /// The video seed with the layer's seed slider folded in.
    public static func mix(_ seed: Int) -> UInt32 { vhsSeed ^ (UInt32(truncatingIfNeeded: seed) &* 0x9E37_79B1) }

    var slot: Double { longest }

    /// Seconds of tape per stretch of the clustering weight.
    public static let stretch = 15.0

    func unit(_ k: Int64, _ j: UInt32) -> Double {
        (Hash.signed(seed, salt, UInt32(truncatingIfNeeded: k), UInt32(truncatingIfNeeded: k >> 32), j) + 1) / 2
    }

    /// The clustering weight at time `t`: 4 u^3 for the stretch holding `t`, mean 1.
    public static func weight(salt: UInt32, seed: UInt32, at t: Double) -> Double {
        let j = Int64(floor(t / stretch))
        let u = (Hash.signed(seed, salt, UInt32(truncatingIfNeeded: j), UInt32(truncatingIfNeeded: j >> 32), 0xC1) + 1) / 2
        return 4 * u * u * u
    }

    public func weight(at t: Double) -> Double { Self.weight(salt: salt, seed: seed, at: t) }

    /// The event of slot `k`, if one starts there.
    public func event(slot k: Int64) -> Event? {
        let p = 1 - exp(-ratePerSecond * weight(at: Double(k) * slot) * slot)
        guard p > 0, unit(k, 1) < p else { return nil }
        let length = shortest + (longest - shortest) * unit(k, 3)
        return Event(index: k, start: (Double(k) + unit(k, 2)) * slot, length: length, u: unit(k, 4))
    }

    /// Every event that overlaps [from, to).
    public func events(from a: Double, to b: Double) -> [Event] {
        guard ratePerSecond > 0, b > a else { return [] }
        let first = Int64(floor((a - longest) / slot)), last = Int64(floor(b / slot))
        guard last >= first, last - first < 1_000_000 else { return [] }
        return (first...last).compactMap { event(slot: $0) }.filter { $0.end > a && $0.start < b }
    }

    /// Every event that starts in [from, to).
    public func starts(from a: Double, to b: Double) -> [Event] {
        events(from: a, to: b).filter { $0.start >= a && $0.start < b }
    }

    /// The strongest envelope of the events at `t`, with its event.
    public func active(at t: Double, ramp: Double) -> (level: Double, event: Event?) {
        var best: (Double, Event?) = (0, nil)
        for e in events(from: t, to: t + 1e-9) {
            let v = e.envelope(at: t, ramp: ramp)
            if v > best.0 { best = (v, e) }
        }
        return best
    }
}

/// A damage layer: off by default, with a Strength and a Seed ahead of its own parameters.
/// The sidebar lists these under Damage, not under Tune. A Look sets them: the worn Looks
/// switch on their wear, every other Look switches them off.
@MainActor
public protocol DamageLayer: Layer {
    var strength: Double { get }
    var seed: Double { get }
}

/// The parameters every damage layer leads with: Strength (how hard each event hits), Rate (how
/// often events come) and Seed (which take). Strength does not move the rate. At most
/// one event starts per `DamageSchedule` slot, so near the top of a range the Rate thins
/// (40 tears a minute come out near 28): events of one kind do not pile on each other.
func damageCommon(strength: Double, rate: Double, rateName: String = "Rate (per minute)",
                  rateRange: ClosedRange<Double>, seed: Double) -> [LayerParameter] {
    [LayerParameter(id: "strength", name: "Strength", value: .float(strength), range: 0...1),
     LayerParameter(id: "rate", name: rateName, value: .float(rate), range: rateRange),
     LayerParameter(id: "seed", name: "Seed", value: .float(seed), range: 0...999)]
}

/// One raster line of the `damage_events` table (Shaders/Damage.metal): twelve floats.
struct DamageLine {
    var shift: Float = 0
    var noise: Float = 0
    var chroma: Float = 1
    var blur: Float = 0
    var start: Float = 0
    var end: Float = 0
    var kind: Kind = .none
    var level: Float = 0
    /// How much the span's level breaks up along the line (0 a solid span, 1 broken into
    /// patches), so a fold or a streak reads as a lost carrier, not a ruled line.
    var fuzz: Float = 0

    enum Kind: Float { case none = 0, white = 1, black = 2, repeatLine = 3, noiseBar = 4 }

    var floats: [Float] { [shift, noise, chroma, blur, start, end, kind.rawValue, level, fuzz, 0, 0, 0] }

    static func table(_ lines: [DamageLine]) -> [Float] { lines.flatMap(\.floats) }
}

/// The time of field `f` (0 or 1) of the frame shown at `time`.
func fieldTime(_ time: Double, _ f: Int) -> Double { time + Double(f) / fieldsPerSecond }

/// A stable per field number for the kernel's noise, from the source time.
func fieldNumber(_ time: Double) -> UInt32 {
    UInt32(truncatingIfNeeded: Int64((time * fieldsPerSecond).rounded()))
}

@MainActor
func encodeDamageLines(_ pipeline: MTLComputePipelineState?, label: String, commandBuffer: MTLCommandBuffer,
                       input: MTLTexture, output: MTLTexture, table: [Float], seed: UInt32, salt: UInt32,
                       time: Double) {
    guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
    enc.label = label
    enc.setComputePipelineState(pipeline)
    enc.setTexture(input, index: 0)
    enc.setTexture(output, index: 1)
    setFloats(enc, table, index: 0)
    var p: [UInt32] = [seed, salt, fieldNumber(time), 0]
    enc.setBytes(&p, length: p.count * 4, index: 1)
    dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
    enc.endEncoding()
}

// MARK: - Tracking tear

/// Tracking tear: for a few frames the heads ride off their tracks, the FM carrier falls into
/// the guard between tracks and the deck's horizontal sync slips. A band of lines skews right
/// as the slip builds down the band (and relaxes over the lines after it while the sync
/// re-locks), a noise bar sits in the band's middle, and the band loses its chroma (the color
/// killer drops it when the burst is lost).
///
/// Numbers: the band's height and skew default to ntsc-rs's `tracking_noise` (height 12 rows,
/// wave_intensity 15 px, the intensity ramping toward the band's bottom, from ntsc-rs
/// crates/ntscrs/src/settings/standard.rs and src/ntsc.rs) at Strength 0.25. Strength 1 is
/// four times the skew, the band half again as tall, a solid noise bar, the chroma killed
/// outright and 15 lines of re-lock below it (INFERRED by eye, an unmistakable top). Sencore's
/// servo notes say the bar "passes through the picture from time to
/// time" (TT132) with no figure, so the default rate, 3 tears a minute, and the length, 3 to
/// 15 frames (0.1 to 0.5 s), are INFERRED (docs/SIGNAL-CHAIN.md, "Damage", lists them as
/// unsourced).
@MainActor
@Observable
public final class TrackingTearLayer: DamageLayer {
    public let id = "damage-tear"
    public let name = "Tracking tear"
    public var enabled = false
    /// 0 to 1, how hard a tear hits. At 1: 4 times the skew, a solid noise bar, no chroma.
    public var strength = 0.5
    /// Tears a minute on average (Poisson, clustered per `DamageSchedule`). The default is
    /// an earlier version's rate at the default Strength.
    public var rate = 3.0
    public var seed = 0.0
    /// Field lines in the band at Strength 0.33 (it grows with Strength).
    public var height = 12.0
    /// The skew at the band's bottom at Strength 0.25, px (4 times this at Strength 1).
    public var skew = 15.0
    /// Where the band sits: near the bottom (above the head switch) or anywhere in the field.
    public var position: Position = .bottom

    public enum Position: String, CaseIterable, Sendable {
        case bottom, anywhere
        var label: String { self == .bottom ? "Bottom" : "Anywhere" }
    }

    /// An earlier version's tears a minute at Strength 1, which set the default rate (half of it).
    static let maxPerMinute = 6.0
    static let rateRange = 0.0...60.0
    static let skewRange = 0.0...80.0
    static let shortest = 0.1
    static let longest = 0.5
    static let heightRange = 4.0...60.0
    /// Lines the sync takes to settle after the band (time constant, field lines).
    static let relock = 3.0
    static let salt: UInt32 = 0xDA01
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        damageCommon(strength: strength, rate: rate, rateRange: Self.rateRange, seed: seed) + [
            LayerParameter(id: "position", name: "Position", value: .choice(position.rawValue),
                           options: Position.allCases.map { .init(value: $0.rawValue, label: $0.label) }),
            LayerParameter(id: "height", name: "Height (field lines)", value: .float(height), range: Self.heightRange),
            LayerParameter(id: "skew", name: "Skew (px)", value: .float(skew), range: Self.skewRange),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("strength", .float(let v)): strength = clamped(v, 0...1)
        case ("rate", .float(let v)): rate = clamped(v, Self.rateRange)
        case ("seed", .float(let v)): seed = clamped(v, 0...999).rounded()
        case ("height", .float(let v)): height = clamped(v, Self.heightRange).rounded()
        case ("skew", .float(let v)): skew = clamped(v, Self.skewRange)
        case ("position", .choice(let c)): if let p = Position(rawValue: c) { position = p }
        default: break
        }
    }

    public var schedule: DamageSchedule {
        DamageSchedule(salt: Self.salt, seed: Int(seed), ratePerSecond: rate / 60,
                       shortest: Self.shortest, longest: Self.longest)
    }

    func lines(time: Double, lines: Int = SignalChain.rasterHeight) -> [DamageLine] {
        var out = [DamageLine](repeating: DamageLine(), count: lines)
        let fieldLines = lines / 2, sched = schedule, s = DamageSchedule.mix(Int(seed))
        let a = strength
        let h = min(fieldLines / 2, max(2, Int((height * (0.5 + 1.5 * a)).rounded())))
        let relock = Self.relock * (1 + 4 * a)
        let tail = Int((3 * relock).rounded(.up))
        for f in 0..<2 {
            let tf = fieldTime(time, f)
            let (e, ev) = sched.active(at: tf, ramp: 0.06)
            guard e > 0, let ev else { continue }
            let fn = fieldNumber(tf)
            let jitter = Int((2 * Hash.signed(s, Self.salt, 5, fn)).rounded())
            let top: Int
            switch position {
            case .bottom: top = fieldLines - 10 - h + jitter
            case .anywhere: top = Int(ev.u * Double(fieldLines - h)) + jitter
            }
            var lastShift = 0.0
            let kill = e * min(1, 2 * a)
            for i in 0..<(h + tail) {
                let fl = top + i
                guard fl >= 0, fl < fieldLines else { continue }
                let y = fl * 2 + f
                var line = DamageLine()
                if i < h {
                    let u = Double(i) / Double(max(h - 1, 1))
                    lastShift = e * skew * 4 * a * pow(u, 1.5) + 9 * a * e * Hash.signed(s, Self.salt, 6, fn, UInt32(i))
                    line.shift = Float(lastShift)
                    line.chroma = Float(1 - kill)
                    line.blur = Float(1.5 * a * e)
                    let core = 1 - abs(u - 0.5) / (0.3 + 0.15 * a)
                    line.noise = Float(0.16 * a * e)
                    if core > 0 {
                        line.kind = .noiseBar
                        line.start = 0
                        line.end = Float(SignalChain.rasterWidth)
                        line.level = Float(e * min(1, 2 * a) * min(1, core * 1.5))
                        line.fuzz = Float(0.6 * (1 - a))
                    }
                } else {
                    let r = Double(i - h + 1)
                    line.shift = Float(lastShift * exp(-r / relock))
                    line.chroma = Float(1 - kill * exp(-r / relock))
                }
                out[y] = line
            }
        }
        return out
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("damage_events", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        encodeDamageLines(pipeline, label: "Damage tracking tear", commandBuffer: commandBuffer, input: input,
                          output: output, table: DamageLine.table(lines(time: frame.time, lines: output.height)),
                          seed: DamageSchedule.mix(Int(seed)), salt: Self.salt, time: frame.time)
    }
}

// MARK: - Snow

/// Snow: RF dropouts the compensator does not hide. Oxide shed off a worn tape drops the FM
/// carrier for a moment and the demodulator puts out a white streak (or a black one), from a
/// few pixels to a whole line. With "Compensator" on, the deck's 1H delay fills each one with
/// the line above from the same field, the "repeat the last line" look.
///
/// Numbers: ntsc-rs's default snow turns a pixel to snow with probability 0.00025 x 0.01
/// (`snow_intensity` times its 0.01 scale), 0.86 a frame at 720 by 480, 26 a second, and the
/// default Rate, 78 a second, is three times it (an earlier version's rate at the default
/// Strength). Strength sets each streak: at 0.5 the streaks are full white (or black) and run the
/// lengths below, at 1 they run 120 px to past a whole line and each drops the carrier on a
/// clump of up to ten lines of its field (INFERRED by eye). For scale, BBC Monograph 57
/// (Geddes, 1965) finds two or three dropouts a minute on exceptionally good tape and five to
/// ten common, "together with occasional bursts", and Sony allows 25 a minute on half inch
/// tape. Snow is a tape far past those. Lengths are log uniform from ntsc-rs's shortest
/// transient, 8 px, to the 25 us (340 px) past which the BBC found "virtually no drop-outs".
/// The visible 5 to 25 us of US patent 3,525,930 sits inside.
/// The compensator is the BBC's "video delay of one line-period" that substitutes the
/// previous line. White against black is 4 to 1 (INFERRED: a lost carrier reads past white
/// in the limiter).
@MainActor
@Observable
public final class SnowLayer: DamageLayer {
    public let id = "damage-snow"
    public let name = "Snow"
    public var enabled = false
    /// 0 to 1, how much each streak drops. At 1: streaks 120 px to past a whole line, each a
    /// clump of up to ten lines of its field.
    public var strength = 0.3
    /// Dropouts a second on average. The default is an earlier version's rate at the default
    /// Strength.
    public var rate = 78.0
    public var seed = 0.0
    /// The dropout compensator fills each streak with the line above.
    public var compensator = false

    /// An earlier version's dropouts a second at Strength 1, which set the default rate.
    static let maxPerSecond = 260.0
    static let rateRange = 0.0...2_000.0
    static let shortestPx = 8.0
    static let longestPx = 340.0
    static let whiteShare = 0.8
    static let salt: UInt32 = 0xDA02
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        damageCommon(strength: strength, rate: rate, rateName: "Rate (per second)", rateRange: Self.rateRange,
                     seed: seed) + [
            LayerParameter(id: "compensator", name: "Compensator (repeat line)", value: .bool(compensator)),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("strength", .float(let v)): strength = clamped(v, 0...1)
        case ("rate", .float(let v)): rate = clamped(v, Self.rateRange)
        case ("seed", .float(let v)): seed = clamped(v, 0...999).rounded()
        case ("compensator", .bool(let b)): compensator = b
        default: break
        }
    }

    /// Dropouts per second.
    public var ratePerSecond: Double { rate }

    /// The streaks of one frame, one at most starting per line. A long streak at high Strength
    /// carries on over the next lines of its field.
    func lines(time: Double, lines: Int = SignalChain.rasterHeight, width: Int = SignalChain.rasterWidth) -> [DamageLine] {
        var out = [DamageLine](repeating: DamageLine(), count: lines)
        let s = DamageSchedule.mix(Int(seed)), a = strength
        // Sporadic like every Damage layer: the rate follows the stretch's clustering weight.
        let p = ratePerSecond * DamageSchedule.weight(salt: Self.salt, seed: s, at: time)
            / fieldsPerSecond / Double(lines / 2)
        guard p > 0, a > 0 else { return out }
        // Past 0.5 the streaks lengthen from both ends: at 1 they run 120 px to past a line.
        let top = max(0, 2 * a - 1)
        let longest = Self.longestPx * (0.25 + 1.5 * a) + 380 * top
        let shortest = Self.shortestPx + 112 * top
        let level = Float(min(1, 2 * a))
        for y in 0..<lines {
            let fn = fieldNumber(fieldTime(time, y & 1))
            func u(_ k: UInt32) -> Double { (Hash.signed(s, Self.salt, fn, UInt32(y >> 1), k) + 1) / 2 }
            guard u(1) < p else { continue }
            let length = shortest * pow(longest / shortest, u(2))
            let start = u(3) * (Double(width) + length) - length
            var line = DamageLine()
            line.start = Float(start)
            line.end = Float(start + length)
            line.kind = compensator ? .repeatLine : (u(4) < Self.whiteShare ? .white : .black)
            line.level = level
            line.fuzz = compensator ? 0 : 0.35
            // A long dropout keeps the carrier down on the lines that follow, and past 0.5 every
            // dropout is a clump of up to seven lines of its field, ragged at both ends.
            let extra = (length > 0.25 * Double(width) ? Int((3 * a * u(5)).rounded()) : 0)
                + Int((6 * top * u(6)).rounded())
            for k in 0...extra where y + 2 * k < lines && (k == 0 || out[y + 2 * k].kind == .none) {
                var l = line
                if k > 0 {
                    let ragged = Float(0.15 * length * (u(UInt32(7 + k)) - 0.5))
                    l.start += ragged
                    l.end -= ragged
                }
                out[y + 2 * k] = l
            }
        }
        return out
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("damage_events", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        encodeDamageLines(pipeline, label: "Damage snow", commandBuffer: commandBuffer, input: input, output: output,
                          table: DamageLine.table(lines(time: frame.time, lines: output.height, width: output.width)),
                          seed: DamageSchedule.mix(Int(seed)), salt: Self.salt, time: frame.time)
    }
}

// MARK: - Head clog

/// When clog episodes land, shared by the picture's head clog and the audio's (its "Follow
/// the picture" switch). INFERRED: 1 episode a minute by default (an earlier version's 2 a
/// minute at Strength 1, at the default Strength), 1.5 to 6 s each with 0.5 s ramps (no source gives a
/// clog's duration, AV Artifact Atlas and Sencore describe it only).
public enum HeadClogTiming {
    /// An earlier version's episodes a minute at Strength 1, which set the default rate (half of it).
    public static let maxPerMinute = 2.0
    public static let defaultPerMinute = 1.0
    public static let rateRange = 0.0...20.0
    public static let shortest = 1.5
    public static let longest = 6.0
    public static let ramp = 0.5
    public static let salt: UInt32 = 0xDA03

    public static func schedule(perMinute: Double, seed: Double) -> DamageSchedule {
        DamageSchedule(salt: salt, seed: Int(seed), ratePerSecond: perMinute / 60,
                       shortest: shortest, longest: longest)
    }
}

/// Head clog smear: a speck of oxide rides on a video head for a few seconds. It holds the
/// head off the tape by a gap d, and Wallace's spacing loss, 54.6 d / lambda dB, takes the FM
/// carrier down by that much at its 1.49 um wavelength. FM noise rises dB for dB as the carrier
/// falls, so the picture's S/N drops by the same figure and it goes soft and grainy. One head
/// clogged is one field noisy (vhs-decode's "Head Clog is one field full of snow"), the "One
/// head" switch, on by default.
///
/// Numbers: Wallace's 54.6 d / lambda (the Nortronics head guide and 3M's "Magnetic
/// Recording Media", 55 dB per wavelength of spacing). Strength 1 is a 1.2 um gap at the
/// episode's peak (44 dB of carrier loss, the field nearly all noise), and 0.5 um (18.4 dB) is
/// Strength 0.42. The color-under carrier at 629 kHz is 9.2 um long on
/// tape, so the same gap costs it a sixth as much and the color fades late. Episodes come at
/// the Rate (`HeadClogTiming`). The gap size and the softening, a Gaussian up to 4 px at
/// 1.2 um, are INFERRED by eye.
@MainActor
@Observable
public final class HeadClogLayer: DamageLayer {
    public let id = "damage-clog"
    public let name = "Head clog"
    public var enabled = false
    /// 0 to 1. At 1: a 1.2 um gap at each episode's peak (44 dB of the carrier lost).
    public var strength = 0.5
    /// Episodes a minute on average.
    public var rate = HeadClogTiming.defaultPerMinute
    public var seed = 0.0
    public var oneHead = true

    static let maxGap = 1.2
    static let maxBlur = 4.0
    /// The color-under carrier's wavelength on tape, um: 5.8 m/s over 629 kHz.
    static let chromaWavelength = VHSGeometry.writingSpeed * 1_000 / 629e3
    static let salt = HeadClogTiming.salt
    /// The deck's luma S/N before the clog (L5's setting), dB.
    @ObservationIgnored var lumaSNR: () -> Double = { 45 }
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        damageCommon(strength: strength, rate: rate, rateRange: HeadClogTiming.rateRange, seed: seed) + [
            LayerParameter(id: "oneHead", name: "One head", value: .bool(oneHead)),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("strength", .float(let v)): strength = clamped(v, 0...1)
        case ("rate", .float(let v)): rate = clamped(v, HeadClogTiming.rateRange)
        case ("seed", .float(let v)): seed = clamped(v, 0...999).rounded()
        case ("oneHead", .bool(let b)): oneHead = b
        default: break
        }
    }

    public var schedule: DamageSchedule { HeadClogTiming.schedule(perMinute: rate, seed: seed) }

    /// The gap in um at time `t`.
    public func gap(at t: Double) -> Double {
        schedule.active(at: t, ramp: HeadClogTiming.ramp).level * strength * Self.maxGap
    }

    /// Carrier loss, and so S/N lost, in dB for a gap in um.
    public static func lossDB(gap: Double) -> Double {
        VHSGeometry.spacingLossDB(spacing: gap, wavelength: VHSGeometry.carrierWavelength)
    }

    /// Uniform noise amplitude (Y) to add so the S/N falls from `snr` by `loss` dB.
    static func noiseAmplitude(snr: Double, loss: Double) -> Double {
        let before = pow(10, -snr / 10), after = pow(10, -(snr - loss) / 10)
        return (max(0, after - before)).squareRoot() * 3.0.squareRoot()
    }

    func lines(time: Double, lines: Int = SignalChain.rasterHeight) -> [DamageLine] {
        var out = [DamageLine](repeating: DamageLine(), count: lines)
        let snr = lumaSNR()
        for f in 0..<2 where !(oneHead && f == 0) {
            let d = gap(at: fieldTime(time, f))
            guard d > 0 else { continue }
            var line = DamageLine()
            line.noise = Float(min(0.8, Self.noiseAmplitude(snr: snr, loss: Self.lossDB(gap: d))))
            line.blur = Float(Self.maxBlur * d / Self.maxGap)
            line.chroma = Float(pow(10, -VHSGeometry.spacingLossDB(spacing: d, wavelength: Self.chromaWavelength) / 20))
            for y in stride(from: f, to: lines, by: 2) { out[y] = line }
        }
        return out
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("damage_events", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        encodeDamageLines(pipeline, label: "Damage head clog", commandBuffer: commandBuffer, input: input,
                          output: output, table: DamageLine.table(lines(time: frame.time, lines: output.height)),
                          seed: DamageSchedule.mix(Int(seed)), salt: Self.salt, time: frame.time)
    }
}

// MARK: - Crease

/// Crease line: a fold across the tape lifts it off the drum where it crosses each track.
/// The video track runs 96.8 mm along the tape and the tape moves 0.556 mm a field at SP, so
/// a fold across the tape is crossed by 174 fields in a row. The heads move with the tape, so
/// each field meets the fold a little further along its track: a line that scrolls down
/// through the picture in 2.9 s at SP (5.8 s at LP, 8.7 s at EP), 1.4 field lines a field. A
/// digitalfaq poster's creased tape shows exactly that, "horizontal fuzzy lines scrolling
/// down", in "the same place" on every replay
/// (https://www.digitalfaq.com/forum/video-restore/15395-scrolling-horizontal-fuzzy.html).
/// Each line is 0.37 mm of track (97.34 mm over 262.5 lines), so the fold itself takes about
/// one line, a dropout gone bright or dark, and the tape lifted around it adds noise to a
/// few lines either side.
///
/// Not a ruled line: the lifted tape is a hump, so the carrier fades in and out over a few
/// lines with a Gaussian profile, and along the line the contact comes and goes in patches,
/// so the fold breaks up. Around it the timing slips a few pixels and the color fades. Then
/// the chain's own later stages (chroma, noise, halo, head switch, time base) run over it.
///
/// Numbers: the geometry is `VHSGeometry`'s. Strength 1 is a fold 2 field lines thick at its
/// sigma, fully white (or black) at its core, with noise, slip and color loss 15 lines either
/// side (INFERRED by eye). Passes arrive sporadically at the Rate, 5 a minute by default
/// (a 12 s average gap, INFERRED: a creased stretch of tape).
@MainActor
@Observable
public final class CreaseLayer: DamageLayer {
    public let id = "damage-crease"
    public let name = "Crease"
    public var enabled = false
    /// 0 to 1. At 1: a fold 2 lines thick at its sigma, white (or black) at its core, with
    /// noise, slip and color loss 15 lines either side.
    public var strength = 0.6
    /// Passes a minute on average.
    public var rate = 5.0
    public var seed = 0.0
    public var tone: Tone = .bright

    public enum Tone: String, CaseIterable, Sendable {
        case bright, dark
        var label: String { self == .bright ? "Bright" : "Dark" }
    }

    /// Average seconds from one pass to the next (the control an older file stores).
    public var period: Double { rate > 0 ? 60 / rate : .infinity }

    static let rateRange = 0.0...30.0
    /// An older file's Average gap range, s.
    nonisolated static let periodRange = 3.0...60.0

    /// An older file's `period` (s) as a `rate` (passes a minute): 60 over it. The strict
    /// reads (`UserPresets`, `SettingsClipboard`) take an old file's `period` through this.
    nonisolated static func rate(fromPeriod v: Double) -> Double { 60 / clamped(v, periodRange) }
    static let salt: UInt32 = 0xDA04
    /// The tape speed the deck plays at (L3's speed).
    @ObservationIgnored var speed: () -> TapeSpeed = { .sp }
    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init() {}

    public var parameters: [LayerParameter] {
        damageCommon(strength: strength, rate: rate, rateRange: Self.rateRange, seed: seed) + [
            LayerParameter(id: "tone", name: "Line", value: .choice(tone.rawValue),
                           options: Tone.allCases.map { .init(value: $0.rawValue, label: $0.label) }),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("strength", .float(let v)): strength = clamped(v, 0...1)
        case ("rate", .float(let v)): rate = clamped(v, Self.rateRange)
        case ("seed", .float(let v)): seed = clamped(v, 0...999).rounded()
        // An older file's Average gap: the same passes.
        case ("period", .float(let v)): rate = Self.rate(fromPeriod: v)
        case ("tone", .choice(let c)): if let t = Tone(rawValue: c) { tone = t }
        default: break
        }
    }

    /// Seconds a fold takes to cross the picture: the track's span along the tape over the
    /// tape speed.
    public static func passSeconds(_ s: TapeSpeed) -> Double {
        VHSGeometry.trackSpanAlongTape / VHSGeometry.tapeSpeed(s)
    }

    /// The passes: each as long as the tape takes to carry the fold across a track, arriving
    /// on average `rate` times a minute, sporadically (`DamageSchedule`'s clustering).
    public var schedule: DamageSchedule {
        let pass = Self.passSeconds(speed())
        return DamageSchedule(salt: Self.salt, seed: Int(seed), ratePerSecond: rate / 60, shortest: pass, longest: pass)
    }

    /// Where the fold is at `t`, as a fraction of the field from the top (0 entering at the
    /// top, 1 leaving at the bottom), or nil between passes.
    public func position(at t: Double) -> Double? {
        guard let e = schedule.events(from: t, to: t + 1e-9).first else { return nil }
        return (t - e.start) / e.length
    }

    func lines(time: Double, lines: Int = SignalChain.rasterHeight) -> [DamageLine] {
        var out = [DamageLine](repeating: DamageLine(), count: lines)
        let a = strength
        guard a > 0 else { return out }
        let fieldLines = lines / 2
        let sigma = 0.5 + 1.5 * a, reach = Int((3 * sigma).rounded(.up)) + Int((9 * a).rounded())
        let s = DamageSchedule.mix(Int(seed))
        for f in 0..<2 {
            let tf = fieldTime(time, f)
            guard let phi = position(at: tf) else { continue }
            let fn = fieldNumber(tf)
            let center = phi * Double(fieldLines)
            let c = Int(center.rounded(.down))
            let flicker = 0.85 + 0.15 * Hash.signed(s, Self.salt, 9, fn)
            for fl in (c - reach)...(c + reach) where fl >= 0 && fl < fieldLines {
                let dist = abs(Double(fl) + 0.5 - center)
                let near = max(0, 1 - dist / Double(reach + 1))
                let core = exp(-0.5 * dist * dist / (sigma * sigma))
                var line = DamageLine()
                line.noise = Float(0.4 * a * near)
                line.chroma = Float(1 - 0.8 * a * near)
                line.blur = Float(2 * a * near)
                line.shift = Float((2 + 6 * a) * a * core * Hash.signed(s, Self.salt, 10, fn, UInt32(fl)))
                if core > 0.02 {
                    line.kind = tone == .bright ? .white : .black
                    line.start = 0
                    line.end = Float(SignalChain.rasterWidth)
                    line.level = Float(min(1, 1.6 * a) * core * flicker)
                    line.fuzz = 0.7
                }
                out[fl * 2 + f] = line
            }
        }
        return out
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("damage_events", device: device, library: library)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        encodeDamageLines(pipeline, label: "Damage crease", commandBuffer: commandBuffer, input: input,
                          output: output, table: DamageLine.table(lines(time: frame.time, lines: output.height)),
                          seed: DamageSchedule.mix(Int(seed)), salt: Self.salt, time: frame.time)
    }
}

// MARK: - The set

/// The four picture damage layers, in the order they run (after L8).
@MainActor
public struct DamageLayers {
    public let tear = TrackingTearLayer()
    public let snow = SnowLayer()
    public let clog = HeadClogLayer()
    public let crease = CreaseLayer()

    public init() {}

    public var all: [any Layer] { [clog, crease, snow, tear] }
}
