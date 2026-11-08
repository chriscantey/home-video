import Foundation

// The Damage pass's audio events, after the preset's steady stages, each with a
// switch, a Strength (0 to 1, how hard each event hits), a Rate (events a minute) and a
// Seed (0 to 999), off by default. Each `maxPerMinute` below is the rate Strength 1 set in
// files saved before Rate had its own control. The default Rate is half of it, the rate at
// the default Strength, 0.5. Events are timed by
// `DamageSchedule` on the processor's sample clock (seconds since the processor started, so
// an export repeats exactly and a different seed is a different take). Numbers and sources
// are in each processor's comment and in docs/SIGNAL-CHAIN.md, "Damage".
//
// Two sounds stand out on a worn tape: every now and then it phases, or it loses its high
// end. Phasing is a Hi-Fi dropout: the deck
// falls back to the linear track, which differs in band and sits a little off in time, so
// every switch is a jump in tone and delay. Losing the high end is the head's azimuth
// wandering off (and, slower, a clog).

extension AudioLayerKind {
    /// The Damage layers, in the order they run after the preset's stages: the tape's motion
    /// (glide, flutter), then the head (azimuth, clog), then the tape's surface (a worn
    /// stretch, crackle), then the Hi-Fi fallback, which mixes in a linear rendering of the
    /// chain's input, and last the mute, which silences whatever plays.
    public static let damage: [AudioLayerKind] = [.wowGlide, .flutterBurst, .azimuthWander, .clogMuffle,
                                                  .wornStretch, .crackleBurst, .hifiDropoutBurst, .muteDrop]

    var isDamage: Bool { AudioLayerKind.damage.contains(self) }

    var damageID: String {
        switch self {
        case .hifiDropoutBurst: return "audio-damage-hifi"
        case .azimuthWander: return "audio-damage-azimuth"
        case .clogMuffle: return "audio-damage-clog"
        case .wowGlide: return "audio-damage-glide"
        case .wornStretch: return "audio-damage-worn"
        case .crackleBurst: return "audio-damage-crackle"
        case .muteDrop: return "audio-damage-mute"
        default: return "audio-damage-flutter"
        }
    }

    var damageName: String {
        switch self {
        case .hifiDropoutBurst: return "Hi-Fi dropout (to linear)"
        case .azimuthWander: return "Azimuth wander (high loss)"
        case .clogMuffle: return "Head clog (muffled)"
        case .wowGlide: return "Wow glide (sticky spot)"
        case .wornStretch: return "Worn stretch (hiss jumps)"
        case .crackleBurst: return "Crackle burst"
        case .muteDrop: return "Dropout to silence"
        default: return "Flutter burst"
        }
    }

    /// Events a minute by default: the rate the default Strength, 0.5, set before Rate had its
    /// own control, so a file without a Rate plays the same events.
    var defaultRatePerMinute: Double {
        switch self {
        case .flutterBurst: return FlutterBurst.maxPerMinute / 2
        case .azimuthWander: return AzimuthWander.maxPerMinute / 2
        case .clogMuffle: return HeadClogTiming.defaultPerMinute
        case .hifiDropoutBurst: return HiFiDropoutBurst.maxPerMinute / 2
        case .wowGlide: return WowGlide.maxPerMinute / 2
        case .wornStretch: return WornStretch.maxPerMinute / 2
        case .crackleBurst: return CrackleBurst.maxPerMinute / 2
        case .muteDrop: return MuteDrop.maxPerMinute / 2
        default: return 0
        }
    }

    var damageParameters: [LayerParameter] {
        func f(_ id: String, _ name: String, _ v: Double, _ r: ClosedRange<Double>) -> LayerParameter {
            LayerParameter(id: id, name: name, value: .float(v), range: r)
        }
        let common = [f("strength", "Strength", 0.5, 0...1),
                      f("rate", "Rate (per minute)", defaultRatePerMinute, 0...60),
                      f("seed", "Seed", 0, 0...999)]
        switch self {
        case .hifiDropoutBurst:
            return common + [f("offset", "Linear offset (ms)", HiFiDropoutBurst.defaultOffsetMs, 0...30),
                             f("click", "Click (dBFS)", -30, -90...(-10))]
        case .clogMuffle:
            return common + [LayerParameter(id: "follow", name: "Follow the picture", value: .bool(true))]
        default:
            return common
        }
    }
}

extension AudioLayerSpec {
    var seed: Double { float("seed") }
    var strength: Double { float("strength") }
    /// Events a minute, the kind's default when the spec has none.
    var rate: Double { float("rate") }

    /// The tape speed in mm/s the chain sets on damage specs (`AudioChain.spec`), SP without one.
    var tapeSpeedMMs: Double {
        values["tapeSpeed"]?.doubleValue ?? VHSGeometry.tapeSpeed(.sp)
    }
}

func makeDamageProcessor(_ s: AudioLayerSpec, sampleRate: Double, channels: Int) -> AudioLayerProcessor {
    switch s.kind {
    case .hifiDropoutBurst: return HiFiDropoutBurst(spec: s, sampleRate: sampleRate, channels: channels)
    case .azimuthWander: return AzimuthWander(spec: s, sampleRate: sampleRate, channels: channels)
    case .clogMuffle: return ClogMuffle(spec: s, sampleRate: sampleRate, channels: channels)
    case .wowGlide: return WowGlide(spec: s, sampleRate: sampleRate, channels: channels)
    case .wornStretch: return WornStretch(spec: s, sampleRate: sampleRate, channels: channels)
    case .crackleBurst: return CrackleBurst(spec: s, sampleRate: sampleRate, channels: channels)
    case .muteDrop: return MuteDrop(spec: s, sampleRate: sampleRate, channels: channels)
    default: return FlutterBurst(spec: s, sampleRate: sampleRate, channels: channels)
    }
}

/// A delay line per channel: write a sample, read any earlier one (fractional, linear).
struct DelayLines {
    var buffers: [[Float]]
    var write = 0
    let size: Int

    init(channels: Int, size: Int) {
        self.size = max(4, size)
        buffers = Array(repeating: [Float](repeating: 0, count: self.size), count: channels)
    }

    mutating func push(_ c: Int, _ x: Float) { buffers[c][write] = x }
    mutating func advance() { write = (write + 1) % size }

    /// The sample `d` samples before the one just pushed (0 is that one).
    func read(_ c: Int, _ d: Double) -> Float {
        let i = Int(floor(d)), f = Float(d - Double(i))
        let a = buffers[c][((write - i) % size + size) % size]
        let b = buffers[c][((write - i - 1) % size + size) % size]
        return a + (b - a) * f
    }

    func at(_ c: Int, _ k: Int) -> Float { buffers[c][((write - k) % size + size) % size] }
}

// MARK: - Flutter burst

/// A flutter burst: for a moment the tape sticks and slips (stick-slip, "usually called
/// scrape flutter", AV Artifact Atlas on soft binder syndrome) and the capstan servo hunts
/// ("Linear audio is changing in pitch (warbling)", Sencore TT132), on top of the steady wow
/// and flutter. A delay line read at a modulated position, like `ModulatedDelay`: the speed
/// deviation of a delay A sin(2 pi f t) peaks at 2 pi f A.
///
/// Numbers: scrape flutter sits above 100 Hz (lindos.co.uk, "Wow and flutter measurement"),
/// so 40 percent of the depth goes to one component at 100 to 200 Hz and 60 percent to a servo
/// hunt at 6 to 12 Hz. No source gives a sticking tape's flutter in percent: Strength 1 is a
/// 1.5 percent peak, seven times the 0.2 percent steady figure (Sencore TT190), and 4 bursts
/// a minute of 0.5 to 3 s each (INFERRED).
final class FlutterBurst: AudioLayerProcessor {
    static let maxDepthPercent = 1.5
    static let maxPerMinute = 4.0
    static let salt: UInt32 = 0xDA11
    let schedule: DamageSchedule
    let sampleRate: Double
    let depth: Double
    var lines: DelayLines
    let base: Double
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        schedule = DamageSchedule(salt: Self.salt, seed: Int(s.seed), ratePerSecond: s.rate / 60,
                                  shortest: 0.5, longest: 3)
        depth = s.strength * Self.maxDepthPercent / 100
        // The largest excursion: the whole depth at the slowest hunt, 6 Hz.
        base = depth / (2 * .pi * 6) * sampleRate + 4
        lines = DelayLines(channels: channels, size: Int(base * 2) + 8)
    }

    /// The modulation (seconds of delay) at `t` from event `e` at envelope `env`.
    func offset(_ t: Double, _ e: DamageSchedule.Event, _ env: Double) -> Double {
        let hunt = 6 + 6 * e.u
        let scrape = 150 + 50 * Hash.signed(schedule.seed, Self.salt, UInt32(truncatingIfNeeded: e.index), 7)
        return env * (0.6 * depth / (2 * .pi * hunt) * sin(2 * .pi * hunt * (t - e.start))
                      + 0.4 * depth / (2 * .pi * scrape) * sin(2 * .pi * scrape * (t - e.start)))
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let t0 = Double(n) / sampleRate
        let events = schedule.events(from: t0, to: t0 + Double(block.frames) / sampleRate)
        for i in 0..<block.frames {
            let t = Double(n + Int64(i)) / sampleRate
            var d = base
            for e in events {
                let env = e.envelope(at: t, ramp: 0.15)
                if env > 0 { d += offset(t, e, env) * sampleRate }
            }
            for (c, p) in block.channels.enumerated() where c < lines.buffers.count {
                lines.push(c, p[i])
                p[i] = lines.read(c, d)
            }
            lines.advance()
        }
        n += Int64(block.frames)
    }
}

// MARK: - Azimuth wander

/// Azimuth wander: the tape skews across the linear audio head (guide wear, uneven tension,
/// slitting, per the Standard Tape Lab manual), so the head's gap sits at an angle a to the
/// recorded wavefronts and the track's two edges are read a little apart in time. The loss is
/// the standard formula, A = 20 log10 |sin(pi w tan(a) / lambda) / (pi w tan(a) / lambda)|
/// (the STL manual, and Nortronics' R = W tan(a) / lambda), which is exactly a boxcar over
/// dt = w tan(a) / v seconds, the time the tape takes to carry a wavefront from one edge of
/// the gap to the other. This runs that boxcar, its length following a(t).
///
/// Numbers: the mono linear track is 1 mm wide (repair FAQ). The tape wanders all the time
/// by "600 microradians (0.03 degrees, or 2 minutes)" peak to peak with a basic period of
/// 300 mm of tape (McKnight, AES preprint 1666), 9 s at SP: at 1 mm that loses nothing
/// audible. The episodes are what you hear: 30 arcmin "will result in complete
/// cancellation of the signals at around 10 kHz" on a cassette track (US5552944A). On VHS's
/// 1 mm track at 33.34 mm/s it puts the first null at 3.8 kHz. Strength 1 is a 30 arcmin peak
/// and 4 episodes a minute of 2 to 8 s (rate and length INFERRED).
final class AzimuthWander: AudioLayerProcessor {
    static let maxArcmin = 30.0
    static let wanderArcmin = 1.0
    static let wanderPeriodMM = 300.0
    static let maxPerMinute = 4.0
    static let salt: UInt32 = 0xDA12
    let schedule: DamageSchedule
    let sampleRate: Double
    let strength: Double
    let speed: Double
    var lines: DelayLines
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        strength = s.strength
        speed = s.tapeSpeedMMs
        schedule = DamageSchedule(salt: Self.salt, seed: Int(s.seed), ratePerSecond: s.rate / 60,
                                  shortest: 2, longest: 8)
        let longest = Self.boxcar(arcmin: Self.maxArcmin + Self.wanderArcmin, speed: speed) * sampleRate
        lines = DelayLines(channels: channels, size: Int(longest) + 8)
    }

    /// Boxcar length in seconds: w tan(a) / v, with w in mm and v in mm/s.
    static func boxcar(arcmin: Double, speed: Double) -> Double {
        VHSGeometry.linearAudioTrackWidth * tan(abs(arcmin) / 60 * .pi / 180) / speed
    }

    /// The loss in dB at `hz` for an error of `arcmin` at `speed` mm/s.
    static func lossDB(hz: Double, arcmin: Double, speed: Double) -> Double {
        let x = Double.pi * hz * boxcar(arcmin: arcmin, speed: speed)
        return x < 1e-9 ? 0 : 20 * log10(max(abs(sin(x) / x), 1e-6))
    }

    /// The azimuth error in arcmin at `t`.
    func error(at t: Double, events: [DamageSchedule.Event]) -> Double {
        let wander = Self.wanderArcmin * Hash.valueNoise(t * speed / Self.wanderPeriodMM, 0, seed: schedule.seed &+ 3)
        var peak = 0.0
        for e in events { peak = max(peak, e.envelope(at: t, ramp: 1) * (0.6 + 0.4 * e.u)) }
        return wander + strength * Self.maxArcmin * peak
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let t0 = Double(n) / sampleRate
        let events = schedule.events(from: t0, to: t0 + Double(block.frames) / sampleRate)
        for i in 0..<block.frames {
            let t = Double(n + Int64(i)) / sampleRate
            let length = min(Self.boxcar(arcmin: error(at: t, events: events), speed: speed) * sampleRate,
                             Double(lines.size - 2))
            let whole = Int(floor(length)), frac = Float(length - Double(whole))
            for (c, p) in block.channels.enumerated() where c < lines.buffers.count {
                lines.push(c, p[i])
                guard length > 1 else { continue }
                var sum: Float = 0
                for k in 0..<whole { sum += lines.at(c, k) }
                sum += frac * lines.at(c, whole)
                p[i] = sum / Float(length)
            }
            lines.advance()
        }
        n += Int64(block.frames)
    }
}

// MARK: - Head clog muffling

/// Head clog muffling: oxide on the audio head holds the tape off it by a gap d, and
/// Wallace's spacing loss, 54.6 d / lambda dB, takes the highs first. At wavelength
/// lambda = v / f that is 54.6 d f / v dB, a loss exponential in frequency, exp(-k f), whose
/// impulse response is a Cauchy (Lorentzian) kernel, (a / pi) / (a^2 + t^2) with
/// 2 pi a = k. This runs that kernel as a symmetric FIR (96 taps a side, a constant 2 ms of
/// latency while the layer is on), its width following the gap.
///
/// Numbers: Wallace (Nortronics, 3M's "Magnetic Recording Media"). With "Follow the picture"
/// on and the picture's Head clog on, the episodes are the picture's (`HeadClogTiming`, the
/// same seed and rate), so the sound muffles with the smear. Strength 1 is a 2 um gap at the
/// peak, 33 dB down at 10 kHz and 3.3 dB at 1 kHz at SP (INFERRED: no source gives a gap).
final class ClogMuffle: AudioLayerProcessor {
    static let maxGap = 2.0
    static let halfWidth = 96
    static let salt: UInt32 = 0xDA13
    let schedule: DamageSchedule
    let sampleRate: Double
    let gapScale: Double
    let speed: Double
    var lines: DelayLines
    var kernel: [Float] = []
    var kernelGap = -1.0
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        speed = s.tapeSpeedMMs
        gapScale = s.strength * Self.maxGap
        if let pr = s.values["pictureRate"]?.doubleValue, let pseed = s.values["pictureSeed"]?.doubleValue {
            schedule = HeadClogTiming.schedule(perMinute: pr, seed: pseed)
        } else {
            var own = HeadClogTiming.schedule(perMinute: s.rate, seed: s.seed)
            own.salt = Self.salt
            schedule = own
        }
        lines = DelayLines(channels: channels, size: 2 * Self.halfWidth + 8)
    }

    /// Spacing loss in dB at `hz` for a gap in um at `speed` mm/s.
    static func lossDB(hz: Double, gap: Double, speed: Double) -> Double {
        VHSGeometry.spacingLossDB(spacing: gap, wavelength: speed * 1_000 / hz)
    }

    /// The Cauchy kernel for `gap`, normalized to unity at DC.
    func makeKernel(gap: Double) -> [Float] {
        let k = 54.6 * gap / (speed * 1_000) * log(10) / 20
        let a = k / (2 * .pi) * sampleRate
        let h = Self.halfWidth
        var w = (-h...h).map { i -> Double in a / .pi / (a * a + Double(i * i)) }
        let sum = w.reduce(0, +)
        w = w.map { $0 / sum }
        return w.map(Float.init)
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let h = Self.halfWidth
        for j in 0..<block.frames {
            let abs64 = n + Int64(j)
            // Rebuild the kernel when the gap moves, checked every 64 samples of the processor's
            // own clock, so the result does not depend on how the audio is cut into blocks.
            if abs64 % 64 == 0 {
                let gap = schedule.active(at: Double(abs64) / sampleRate, ramp: HeadClogTiming.ramp).level * gapScale
                if abs(gap - kernelGap) > 0.002 {
                    kernel = gap > 0.002 ? makeKernel(gap: gap) : []
                    kernelGap = gap
                }
            }
            for (c, p) in block.channels.enumerated() where c < lines.buffers.count {
                lines.push(c, p[j])
                if kernel.isEmpty {
                    p[j] = lines.at(c, h)
                } else {
                    var y: Float = 0
                    for (m, w) in kernel.enumerated() { y += w * lines.at(c, m) }
                    p[j] = y
                }
            }
            lines.advance()
        }
        n += Int64(block.frames)
    }
}

// MARK: - Hi-Fi dropout to linear

/// Hi-Fi dropout bursts: the FM carriers drop, and "If the carriers drop out, for even an
/// instant, the muting circuitry switches from Hi-Fi Stereo audio to linear mono audio",
/// with "a popping noise" (Sencore TT190). The linear track is a different sound (50 Hz to 8
/// kHz, 0.2 percent flutter, 45 dB against Hi-Fi's 20 Hz to 20 kHz, 0.005 percent, 80 dB,
/// the same note) and sits off in time: it is read by the stationary A/C head 79.244 mm down
/// the tape from the drum (SMPTE 32M's X distance), so every 0.1 mm of X error on the deck
/// that plays it is 3 ms at SP. Switching back and forth between two copies a few ms apart and
/// a band apart is the "phases weird" sound. The Hi-Fi preset's own rare dropout stays as it
/// is. This layer is the bursts, and runs only on the Hi-Fi preset.
///
/// Numbers: bursts follow BBC Monograph 57's "occasional bursts during which several
/// drop-outs occur within a second or two": each burst is 0.5 to 4 s. In three bursts of five
/// the carrier chatters, dropping 8 times a second for 30 to 150 ms each. In the other two it
/// stays lost and the deck holds the linear track for the whole burst, seconds of it. Strength
/// 0.5 is bursts of 0.5 to 4 s with two in five held solid, Strength 1 up to 8 s with four in
/// five.
/// The shares and rates are INFERRED. The offset defaults to 2 ms (an X error of 0.067 mm, INFERRED: no source gives
/// the error in ms).
final class HiFiDropoutBurst: AudioLayerProcessor {
    static let defaultOffsetMs = 2.0
    static let maxPerMinute = 6.0
    /// The share of bursts that hold the linear track for their whole length, at Strength 0.5
    /// (twice it at 1).
    static let solidShare = 0.4
    static let salt: UInt32 = 0xDA14
    let bursts: DamageSchedule
    let drops: DamageSchedule
    /// The share of bursts held solid at this Strength.
    let solidShare: Double
    let sampleRate: Double
    let linear: AudioChainProcessor
    let offset: Double
    let fade: Double
    let clickAmplitude: Float
    let clickDecay: Float
    var lines: DelayLines
    var scratch: [[Float]] = []
    var click: Float = 0
    var lastMix = 0.0
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        bursts = DamageSchedule(salt: Self.salt, seed: Int(s.seed), ratePerSecond: s.rate / 60,
                                shortest: 0.5, longest: max(0.5, 8 * s.strength))
        solidShare = 2 * Self.solidShare * s.strength
        drops = DamageSchedule(salt: Self.salt &+ 1, seed: Int(s.seed), ratePerSecond: 8, shortest: 0.03, longest: 0.15)
        linear = AudioChainProcessor(spec: .defaults(.linear), sampleRate: sampleRate, channels: channels)
        offset = s.float("offset") / 1_000 * sampleRate
        fade = 0.003 * sampleRate
        clickAmplitude = Float(pow(10, s.float("click") / 20))
        clickDecay = Float(exp(-1 / (0.000_5 * sampleRate)))
        lines = DelayLines(channels: channels, size: Int(30.0 / 1_000 * sampleRate) + 8)
    }

    /// The share of linear in the output at `t`, 0 to 1, with 3 ms fades at each switch.
    func linearShare(at t: Double, bursts inBurst: [DamageSchedule.Event], drops events: [DamageSchedule.Event]) -> Double {
        guard let b = inBurst.first(where: { t >= $0.start && t < $0.end }) else { return 0 }
        // A solid burst: the deck sits on the linear track for the whole of it.
        if b.u < solidShare { return min(1, min(t - b.start, b.end - t) * sampleRate / fade) }
        var m = 0.0
        for e in events where t >= e.start && t < e.end {
            m = max(m, min(1, min(t - e.start, e.end - t) * sampleRate / fade))
        }
        return m
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let frames = block.frames
        if scratch.count != block.channels.count || scratch.first?.count ?? 0 < frames {
            scratch = Array(repeating: [Float](repeating: 0, count: max(frames, 4_096)), count: block.channels.count)
        }
        // The linear rendering runs all the time on the dry input, so its filters are warm.
        for c in 0..<block.channels.count {
            for i in 0..<frames { scratch[c][i] = c < dry.channels.count ? dry.channels[c][i] : 0 }
        }
        AudioBlock.withPlanar(&scratch, range: 0..<frames) { linear.process($0) }
        let t0 = Double(n) / sampleRate, t1 = t0 + Double(frames) / sampleRate
        let inBurst = bursts.events(from: t0, to: t1)
        let events = inBurst.isEmpty ? [] : drops.events(from: t0, to: t1)
        for i in 0..<frames {
            let t = Double(n + Int64(i)) / sampleRate
            let mix = inBurst.isEmpty ? 0 : linearShare(at: t, bursts: inBurst, drops: events)
            // A pop at each switch, either way (Sencore TT190).
            if (mix > 0) != (lastMix > 0) { click = clickAmplitude }
            lastMix = mix
            let k = click
            click *= clickDecay
            for (c, p) in block.channels.enumerated() where c < lines.buffers.count {
                lines.push(c, scratch[c][i])
                guard mix > 0 || k > 1e-7 else { continue }
                let lin = lines.read(c, offset)
                p[i] = p[i] * Float(1 - mix) + lin * Float(mix) + k
            }
            lines.advance()
        }
        n += Int64(frames)
    }
}

// MARK: - Wow glide

/// A wow glide: a sticky spot on the tape drags it, the pitch sags, and the capstan servo,
/// which is locked to the control track's phase, then runs the tape fast until it has caught
/// up, so the pitch swings back above before it settles (Sencore TT132 on capstan servos and
/// "Linear audio is changing in pitch (warbling)"). Because the servo restores the phase, the
/// sound ends where it started in time: the read position follows a raised cosine
/// A (1 - cos 2 pi x) / 2 over the glide, whose speed deviation peaks at pi A / L, down first
/// then up.
///
/// Numbers: Strength 1 is a 3 percent peak deviation, fifteen times the steady 0.2 percent
/// (Sencore TT190), glides of 0.4 to 1.5 s, 4 a minute. All three are INFERRED (no source
/// gives a sticky spot's glide in percent).
final class WowGlide: AudioLayerProcessor {
    static let maxDeviationPercent = 3.0
    static let maxPerMinute = 4.0
    static let salt: UInt32 = 0xDA15
    let schedule: DamageSchedule
    let sampleRate: Double
    let depth: Double
    var lines: DelayLines
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        schedule = DamageSchedule(salt: Self.salt, seed: Int(s.seed), ratePerSecond: s.rate / 60,
                                  shortest: 0.4, longest: 1.5)
        depth = s.strength * Self.maxDeviationPercent / 100
        lines = DelayLines(channels: channels, size: Int(depth * 1.5 / .pi * sampleRate) + 8)
    }

    /// The read delay in seconds at `t`.
    func delay(at t: Double, events: [DamageSchedule.Event]) -> Double {
        var d = 0.0
        for e in events where t >= e.start && t < e.end {
            let x = (t - e.start) / e.length
            d += depth * e.length / .pi * (1 - cos(2 * .pi * x)) / 2
        }
        return d
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let t0 = Double(n) / sampleRate
        let events = schedule.events(from: t0, to: t0 + Double(block.frames) / sampleRate)
        for i in 0..<block.frames {
            let d = min(delay(at: Double(n + Int64(i)) / sampleRate, events: events) * sampleRate, Double(lines.size - 2))
            for (c, p) in block.channels.enumerated() where c < lines.buffers.count {
                lines.push(c, p[i])
                if d > 0 { p[i] = lines.read(c, d) }
            }
            lines.advance()
        }
        n += Int64(block.frames)
    }
}

// MARK: - Worn stretch

/// A worn stretch: oxide shed from a length of tape lowers what the head reads off it, and
/// the hiss floor jumps for as long as the stretch lasts. The program drops 3 dB and pink hiss
/// comes in 12 dB over the linear track's floor (-42 dBFS from its 42 dB S/N), -30 dBFS, ramping in
/// and out over 0.3 s as the stretch reaches the head at tape speed.
/// One tape, so one noise on every channel.
///
/// Numbers: stretches of 2 to 10 s. Strength 0.5 is the jump and drop above, Strength 1 twice
/// both (a 24 dB jump). The jump, the drop and the rate are
/// INFERRED (the Worn Linear preset's own +6 dB is the steady version).
final class WornStretch: AudioLayerProcessor {
    static let floorDB = -42.0
    static let jumpDB = 12.0
    static let dropDB = 3.0
    static let maxPerMinute = 3.0
    static let salt: UInt32 = 0xDA16
    let schedule: DamageSchedule
    let sampleRate: Double
    let noise: NoiseSource
    /// The program's drop in dB at this Strength.
    let drop: Double
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        schedule = DamageSchedule(salt: Self.salt, seed: Int(s.seed), ratePerSecond: s.rate / 60,
                                  shortest: 2, longest: 10)
        drop = 2 * Self.dropDB * s.strength
        noise = NoiseSource(color: .pink, levelDB: Self.floorDB + 2 * Self.jumpDB * s.strength,
                            seed: audioSeed ^ 0xDA16 ^ (UInt64(Int(s.seed)) << 20))
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let t0 = Double(n) / sampleRate
        let events = schedule.events(from: t0, to: t0 + Double(block.frames) / sampleRate)
        for i in 0..<block.frames {
            // The noise runs on every sample so its stream does not depend on the events.
            let h = noise.next()
            guard !events.isEmpty else { continue }
            let t = Double(n + Int64(i)) / sampleRate
            var env = 0.0
            for e in events { env = max(env, e.envelope(at: t, ramp: 0.3)) }
            guard env > 0 else { continue }
            let g = Float(pow(10, -drop * env / 20))
            for p in block.channels { p[i] = p[i] * g + h * Float(env) }
        }
        n += Int64(block.frames)
    }
}

// MARK: - Crackle burst

/// A crackle burst: flakes of oxide and static at the head make short pops, "popping noise or
/// static" (Sencore TT190) and "pops and clicks" (tapeheads.net). Each pop
/// is a step that decays in 0.15 ms, of either sign, from -36 to -12 dBFS, arriving at random
/// 300 times a second inside a burst. One tape, so the same pops on every channel.
///
/// Numbers: bursts of 0.2 to 1.5 s. The 300 pops a second are Strength 0.5, and Strength 1 is
/// 600. The density, levels and decay are
/// INFERRED.
final class CrackleBurst: AudioLayerProcessor {
    static let maxPerMinute = 8.0
    static let density = 300.0
    static let salt: UInt32 = 0xDA17
    let schedule: DamageSchedule
    let sampleRate: Double
    /// Pops a second inside a burst at this Strength.
    let density: Double
    let decay: Float
    var rng: SplitMix64
    var pop: Float = 0
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        schedule = DamageSchedule(salt: Self.salt, seed: Int(s.seed), ratePerSecond: s.rate / 60,
                                  shortest: 0.2, longest: 1.5)
        density = 2 * Self.density * s.strength
        decay = Float(exp(-1 / (0.000_15 * sampleRate)))
        rng = SplitMix64(seed: audioSeed ^ 0xDA17 ^ (UInt64(Int(s.seed)) << 20))
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let t0 = Double(n) / sampleRate
        let events = schedule.events(from: t0, to: t0 + Double(block.frames) / sampleRate)
        let chance = density / sampleRate
        for i in 0..<block.frames {
            let t = Double(n + Int64(i)) / sampleRate
            if events.contains(where: { t >= $0.start && t < $0.end }), rng.unit() < chance {
                let level = pow(10, (-36 + 24 * rng.unit()) / 20)
                pop += Float(rng.unit() < 0.5 ? -level : level)
            }
            guard abs(pop) > 1e-7 else { continue }
            for p in block.channels { p[i] += pop }
            pop *= decay
        }
        n += Int64(block.frames)
    }
}

// MARK: - Dropout to silence

/// A dropout to silence: for a beat both tracks are gone (a crease or a splice lifts the tape
/// off every head), and the deck's mute circuit (Sencore TT190) leaves nothing. 50 to 400 ms of
/// silence with 2 ms edges so the mute itself does not click.
///
/// Numbers: the 50 to 400 ms are Strength 0.5, and Strength 1 runs to 800 ms. Lengths
/// and rate are INFERRED (the Worn Linear preset's
/// own mutes, 5 to 30 ms, are the short steady kind).
final class MuteDrop: AudioLayerProcessor {
    static let maxPerMinute = 6.0
    static let salt: UInt32 = 0xDA18
    let schedule: DamageSchedule
    let sampleRate: Double
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        schedule = DamageSchedule(salt: Self.salt, seed: Int(s.seed), ratePerSecond: s.rate / 60,
                                  shortest: 0.05, longest: max(0.05, 0.8 * s.strength))
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let t0 = Double(n) / sampleRate
        let events = schedule.events(from: t0, to: t0 + Double(block.frames) / sampleRate)
        if !events.isEmpty {
            for i in 0..<block.frames {
                let t = Double(n + Int64(i)) / sampleRate
                var env = 0.0
                for e in events { env = max(env, e.envelope(at: t, ramp: 0.002)) }
                guard env > 0 else { continue }
                for p in block.channels { p[i] *= Float(1 - env) }
            }
        }
        n += Int64(block.frames)
    }
}
