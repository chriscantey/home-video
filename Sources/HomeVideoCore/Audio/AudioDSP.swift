import Foundation

// Plain Swift DSP blocks for the audio chain. No AVAudioUnit graph: the same code runs in
// the exporter, the preview tap and the tests. Every block is one channel's state, and the
// layer processors keep one per channel. Filters are designed on the
// CPU from the RBJ cookbook, as the video layers design theirs.

// MARK: - AudioBiquad

/// A second order IIR section, direct form I, coefficients and state in Double so a 20 Hz
/// highpass at 48 kHz stays clean.
public final class AudioBiquad {
    public enum Design: Equatable, Sendable {
        case lowpass(hz: Double, q: Double)
        case highpass(hz: Double, q: Double)
        case peaking(hz: Double, q: Double, gainDB: Double)
        /// Shelf slope 1.
        case lowShelf(hz: Double, gainDB: Double)
        case highShelf(hz: Double, gainDB: Double)
    }

    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    public init(_ design: Design, sampleRate: Double) {
        set(design, sampleRate: sampleRate)
    }

    public func set(_ design: Design, sampleRate: Double) {
        func omega(_ hz: Double) -> Double { 2 * .pi * min(hz, sampleRate * 0.49) / sampleRate }
        var a0 = 1.0
        switch design {
        case .lowpass(let hz, let q):
            let w = omega(hz), alpha = sin(w) / (2 * q), c = cos(w)
            b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        case .highpass(let hz, let q):
            let w = omega(hz), alpha = sin(w) / (2 * q), c = cos(w)
            b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        case .peaking(let hz, let q, let gainDB):
            let A = pow(10, gainDB / 40), w = omega(hz), alpha = sin(w) / (2 * q), c = cos(w)
            b0 = 1 + alpha * A; b1 = -2 * c; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * c; a2 = 1 - alpha / A
        case .lowShelf(let hz, let gainDB), .highShelf(let hz, let gainDB):
            let A = pow(10, gainDB / 40), w = omega(hz), c = cos(w)
            let alpha = sin(w) / 2 * 2.0.squareRoot()  // slope 1
            let k = 2 * A.squareRoot() * alpha
            if case .lowShelf = design {
                b0 = A * ((A + 1) - (A - 1) * c + k)
                b1 = 2 * A * ((A - 1) - (A + 1) * c)
                b2 = A * ((A + 1) - (A - 1) * c - k)
                a0 = (A + 1) + (A - 1) * c + k
                a1 = -2 * ((A - 1) + (A + 1) * c)
                a2 = (A + 1) + (A - 1) * c - k
            } else {
                b0 = A * ((A + 1) + (A - 1) * c + k)
                b1 = -2 * A * ((A - 1) + (A + 1) * c)
                b2 = A * ((A + 1) + (A - 1) * c - k)
                a0 = (A + 1) - (A - 1) * c + k
                a1 = 2 * ((A - 1) - (A + 1) * c)
                a2 = (A + 1) - (A - 1) * c - k
            }
        }
        b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0
    }

    @inline(__always)
    public func process(_ x: Float) -> Float {
        let xd = Double(x)
        let y = b0 * xd + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = xd; y2 = y1; y1 = y
        return Float(y)
    }

    public func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    /// |H(e^jw)| of the design at `hz`.
    public func magnitude(at hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let im = -(c1 * sin(w) + c2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        return mag(b0, b1, b2) / mag(1, a1, a2)
    }
}

/// Q values of the two sections of a 4th order Butterworth.
let butterworth4Q = [0.541_196_100_146_197, 1.306_562_964_876_376]

// MARK: - Soft clip

/// Tape saturation: a treble pre-emphasis shelf, a tanh soft clip, and the matching
/// de-emphasis, so small signals pass flat and loud treble compresses first.
final class SoftClip {
    let pre: AudioBiquad
    let de: AudioBiquad
    /// tanh(k x) / k: unity small signal gain, gently squashing as k x nears 1.
    let k: Float

    init(drive: Double, emphasisDB: Double, sampleRate: Double) {
        pre = AudioBiquad(.highShelf(hz: 3_000, gainDB: emphasisDB), sampleRate: sampleRate)
        de = AudioBiquad(.highShelf(hz: 3_000, gainDB: -emphasisDB), sampleRate: sampleRate)
        k = Float(3 * max(0, drive))
    }

    @inline(__always)
    func process(_ x: Float) -> Float {
        let e = pre.process(x)
        let c = k < 1e-4 ? e : tanh(k * e) / k
        return de.process(c)
    }
}

// MARK: - Noise

/// SplitMix64: small, fast, seedable, the same stream on every platform.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
}

public enum NoiseColor: String, CaseIterable, Sendable {
    case white, pink
    public var label: String { rawValue.capitalized }
}

/// A seeded noise generator whose RMS is `levelDB` below full scale.
public final class NoiseSource {
    let color: NoiseColor
    let gain: Float
    var rng: SplitMix64
    // Paul Kellet's refined pink filter state.
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0

    /// Unit RMS white noise: uniform in [-1, 1) has RMS 1 / sqrt(3).
    static let whiteScale = 3.0.squareRoot()

    /// The pink filter's output RMS for unit RMS white input, measured once over a long run.
    static let pinkRMS: Double = {
        let probe = NoiseSource(color: .pink, gain: 1, seed: 0x5049_4E4B)
        var sum = 0.0
        let n = 1 << 18
        for _ in 0..<4_096 { _ = probe.rawPink() }
        for _ in 0..<n { let v = probe.rawPink(); sum += v * v }
        return (sum / Double(n)).squareRoot()
    }()

    public convenience init(color: NoiseColor, levelDB: Double, seed: UInt64) {
        let amp = pow(10, levelDB / 20)
        self.init(color: color, gain: Float(color == .pink ? amp / NoiseSource.pinkRMS : amp), seed: seed)
        if color == .pink { for _ in 0..<4_096 { _ = rawPink() } }  // settle the filter
    }

    init(color: NoiseColor, gain: Float, seed: UInt64) {
        self.color = color
        self.gain = gain
        rng = SplitMix64(seed: seed)
    }

    @inline(__always)
    func white() -> Double { (rng.unit() * 2 - 1) * NoiseSource.whiteScale }

    func rawPink() -> Double {
        let w = white()
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        let p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        return p
    }

    @inline(__always)
    public func next() -> Float {
        Float(color == .pink ? rawPink() : white()) * gain
    }
}

// MARK: - Wow and flutter

/// A delay line read at a modulated position: a 0.5 Hz wow sine plus three flutter sines in
/// the 10 to 30 Hz band. Pitch deviation of a sine delay A sin(2 pi f t) peaks at 2 pi f A, so
/// each component's delay amplitude is its share of the deviation over 2 pi f.
final class ModulatedDelay {
    struct Component { var hz: Double; var seconds: Double; var phase: Double }

    let components: [Component]
    let sampleRate: Double
    let baseDelay: Double
    var buffer: [Float]
    var write = 0
    var t = 0.0

    static let flutterRates = [11.3, 17.9, 26.1]

    /// `depthPercent` is the total peak deviation, and `flutterShare` of it goes to flutter.
    init(depthPercent: Double, wowHz: Double, flutterShare: Double, sampleRate: Double, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let depth = max(0, depthPercent) / 100
        let share = min(max(flutterShare, 0), 1)
        var cs = [Component(hz: wowHz, seconds: depth * (1 - share) / (2 * .pi * max(wowHz, 0.01)),
                            phase: rng.unit() * 2 * .pi)]
        for hz in ModulatedDelay.flutterRates {
            cs.append(Component(hz: hz, seconds: depth * share / 3 / (2 * .pi * hz), phase: rng.unit() * 2 * .pi))
        }
        components = cs
        self.sampleRate = sampleRate
        let excursion = cs.reduce(0) { $0 + $1.seconds } * sampleRate
        baseDelay = excursion + 4
        buffer = [Float](repeating: 0, count: Int(baseDelay * 2) + 8)
    }

    @inline(__always)
    func process(_ x: Float) -> Float {
        let n = buffer.count
        buffer[write] = x
        var d = baseDelay
        for c in components { d += c.seconds * sampleRate * sin(2 * .pi * c.hz * t + c.phase) }
        t += 1 / sampleRate
        // Cubic Hermite read between the four samples around the fractional position.
        let pos = Double(write) - d
        let i = Int(floor(pos))
        let f = Float(pos - Double(i))
        func at(_ k: Int) -> Float { buffer[((i + k) % n + n) % n] }
        let ym1 = at(-1), y0 = at(0), y1 = at(1), y2 = at(2)
        let c1 = 0.5 * (y1 - ym1)
        let c2 = ym1 - 2.5 * y0 + 2 * y1 - 0.5 * y2
        let c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)
        write = (write + 1) % n
        return ((c3 * f + c2) * f + c1) * f + y0
    }
}

// MARK: - Line-rate whine and field-rate click

/// NTSC timing: line rate 4.5 MHz / 286, field rate line rate / 262.5.
public enum NTSCAudioTiming {
    public static let lineHz = 4_500_000.0 / 286
    public static let fieldHz = lineHz / 262.5
    /// Lines of vertical sync at the top of each field, where the line-rate pulses stop.
    public static let verticalLines = 9.0
}

/// A sine at the line rate, gated off during the vertical interval of each field.
final class LineWhine {
    let amplitude: Float
    let lineStep: Double
    let fieldStep: Double
    var linePhase = 0.0
    var fieldPhase = 0.0

    init(levelDB: Double, sampleRate: Double) {
        amplitude = Float(pow(10, levelDB / 20))
        lineStep = NTSCAudioTiming.lineHz / sampleRate
        fieldStep = NTSCAudioTiming.fieldHz / sampleRate
    }

    @inline(__always)
    func next() -> Float {
        let inVertical = fieldPhase * 262.5 < NTSCAudioTiming.verticalLines
        let v = inVertical ? 0 : amplitude * Float(sin(2 * .pi * linePhase))
        linePhase += lineStep
        if linePhase >= 1 { linePhase -= 1 }
        fieldPhase += fieldStep
        if fieldPhase >= 1 { fieldPhase -= 1 }
        return v
    }
}

/// A short decaying click once per field (the head switch), alternating polarity.
final class FieldClick {
    let amplitude: Float
    let decay: Float
    let period: Double
    var untilNext: Double
    var env: Float = 0
    var sign: Float = 1

    init(levelDB: Double, sampleRate: Double) {
        amplitude = Float(pow(10, levelDB / 20))
        decay = Float(exp(-1 / (0.000_3 * sampleRate)))  // 0.3 ms
        period = sampleRate / NTSCAudioTiming.fieldHz
        untilNext = period
    }

    @inline(__always)
    func next() -> Float {
        untilNext -= 1
        if untilNext <= 0 {
            untilNext += period
            env = amplitude
            sign = -sign
        }
        let v = env * sign
        env *= decay
        return v
    }
}

// MARK: - Compander

/// The Hi-Fi noise reduction: a decilinear 2:1 compressor (record) or 1:2 expander
/// (playback) around full scale, with a peak detector (attack and release time constants).
/// The detector's error on a steady waveform is a fixed ratio, so a compressor and expander
/// with matched times cancel it and return the level exactly.
public final class Compander {
    public enum Mode: Sendable { case compress, expand }

    let mode: Mode
    let attack: Double
    let release: Double
    /// Expander exponent 1 + error, where error is the tracking error in dB per 20 dB.
    let exponent: Double
    let floor: Double
    var env = 0.0

    public init(mode: Mode, sampleRate: Double, attackMs: Double, releaseMs: Double, trackingErrorDB: Double = 0) {
        self.mode = mode
        attack = 1 - exp(-1 / (max(attackMs, 0.01) / 1_000 * sampleRate))
        release = 1 - exp(-1 / (max(releaseMs, 0.01) / 1_000 * sampleRate))
        exponent = 1 + trackingErrorDB / 20
        // Compressor boost and expander cut both stop at 45 dB.
        floor = mode == .compress ? pow(10, -90.0 / 20) : pow(10, -45.0 / 20)
    }

    @inline(__always)
    public func process(_ x: Float) -> Float {
        let a = Double(abs(x))
        env += (a - env) * (a > env ? attack : release)
        let e = max(env, floor)
        let g = mode == .compress ? 1 / e.squareRoot() : pow(e, exponent)
        return Float(Double(x) * g)
    }
}
