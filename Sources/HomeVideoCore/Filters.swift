import Foundation

/// One second order IIR section, y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2 (a0 normalized to 1).
/// A first order section is a biquad with b2 = a2 = 0.
///
/// Coefficients are designed here on the CPU and handed to the shaders in a uniform buffer as
/// five floats per section (see `VHS.metal`, `Biquad`). The shaders only run them.
public struct Biquad: Equatable, Sendable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Identity section.
    public static let passthrough = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public var floats: [Float] { [b0, b1, b2, a1, a2].map(Float.init) }

    public var dcGain: Double { (b0 + b1 + b2) / (1 + a1 + a2) }
}

/// Filter design for the per line causal filters. Frequencies are normalized: cycles per
/// sample, so 0.5 is Nyquist. On the 13.5 MHz raster, f MHz is f / 13.5.
public enum Filters {
    /// Rec. 601 sample rate of the 720 sample line.
    public static let sampleRateMHz = 13.5

    public static func normalized(mhz: Double) -> Double { mhz / sampleRateMHz }

    /// Bilinear transform prewarp constant for a normalized frequency, clamped under Nyquist.
    static func k(_ f: Double) -> Double { tan(Double.pi * min(max(f, 1e-6), 0.499)) }

    /// 2nd order lowpass (Butterworth at q = 1/sqrt(2)) by the bilinear transform.
    public static func lowpass2(cutoff f: Double, q: Double = 1 / 2.0.squareRoot()) -> Biquad {
        let k = k(f), kk = k * k
        let n = 1 / (1 + k / q + kk)
        let b0 = kk * n
        return Biquad(b0: b0, b1: 2 * b0, b2: b0, a1: 2 * (kk - 1) * n, a2: (1 - k / q + kk) * n)
    }

    /// 1st order lowpass by the bilinear transform.
    public static func lowpass1(cutoff f: Double) -> Biquad {
        let k = k(f)
        let b0 = k / (1 + k)
        return Biquad(b0: b0, b1: b0, b2: 0, a1: (k - 1) / (k + 1), a2: 0)
    }

    /// 3rd order Butterworth lowpass: a pole pair at Q = 1 and one real pole.
    public static func butterworth3(cutoff f: Double) -> [Biquad] {
        [lowpass2(cutoff: f, q: 1), lowpass1(cutoff: f)]
    }

    /// Notch at `center` (0 dB everywhere else). Its step response rings at the center.
    public static func notch(center f: Double, q: Double) -> Biquad {
        let k = k(f), kk = k * k
        let n = 1 / (1 + k / q + kk)
        let b0 = (1 + kk) * n
        let b1 = 2 * (kk - 1) * n
        return Biquad(b0: b0, b1: b1, b2: b0, a1: b1, a2: (1 - k / q + kk) * n)
    }

    /// The analog RC lowpass as a one pole recursion, y += alpha (x - y).
    /// A step reaches 1 - 1/e (63 percent) after about 1/alpha samples.
    public static func rc(alpha: Double) -> Biquad {
        Biquad(b0: alpha, b1: 0, b2: 0, a1: alpha - 1, a2: 0)
    }

    /// Runs `sections` over `x` on the CPU, the reference the shaders follow. With `primed`
    /// the state starts at the steady state of the first sample, as the shaders do.
    public static func run(_ sections: [Biquad], _ x: [Double], primed: Bool = false) -> [Double] {
        var signal = x
        for c in sections {
            var s1 = 0.0, s2 = 0.0
            if primed, let x0 = signal.first {
                let y0 = c.dcGain * x0
                s2 = c.b2 * x0 - c.a2 * y0
                s1 = c.b1 * x0 - c.a1 * y0 + s2
            }
            for i in signal.indices {
                let xi = signal[i]
                let y = c.b0 * xi + s1
                s1 = c.b1 * xi - c.a1 * y + s2
                s2 = c.b2 * xi - c.a2 * y
                signal[i] = y
            }
        }
        return signal
    }

    /// RMS gain of `sections` for white input, sqrt(sum h^2) over the impulse response.
    /// With `difference` the input first goes through 1 - z^-1 (the FM noise high boost).
    public static func noiseGain(_ sections: [Biquad], difference: Bool = false, length: Int = 4096) -> Double {
        var impulse = [Double](repeating: 0, count: length)
        impulse[0] = 1
        if difference, length > 1 { impulse[1] = -1 }
        return run(sections, impulse).reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    /// Flattens sections for a shader uniform buffer.
    public static func floats(_ sections: [Biquad]) -> [Float] { sections.flatMap(\.floats) }
}

/// The NTSC YIQ matrix (FCC 1953, Rec. 601 luma weights) and its exact inverse, applied to
/// the gamma encoded RGB the framing pass writes. The inverse is computed, not typed, so L1
/// then L9 is the identity to float precision.
public enum YIQ {
    public static let forward: [[Double]] = [
        [0.299, 0.587, 0.114],
        [0.595716, -0.274453, -0.321263],
        [0.211456, -0.522591, 0.311135],
    ]

    public static let inverse: [[Double]] = invert3(forward)

    static func invert3(_ m: [[Double]]) -> [[Double]] {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        return [
            [A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
            [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
            [C / det, -(a * h - b * g) / det, (a * e - b * d) / det],
        ]
    }

    /// Row major, nine floats.
    public static func floats(_ m: [[Double]]) -> [Float] { m.flatMap { $0.map(Float.init) } }
}

/// A small integer hash for CPU side per line randomness (head switch jitter, time base),
/// the same PCG step the shaders use, so seeds mean the same thing on both sides.
public enum Hash {
    public static func pcg(_ v: UInt32) -> UInt32 {
        let state = v &* 747796405 &+ 2891336453
        let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
        return (word >> 22) ^ word
    }

    /// A float in -1...1 from a list of integers.
    public static func signed(_ parts: UInt32...) -> Double {
        var h: UInt32 = 0x9E3779B9
        for p in parts { h = pcg(h ^ p) }
        return Double(h) / Double(UInt32.max) * 2 - 1
    }

    /// Smooth value noise over two integer lattices (line, time), in -1...1.
    public static func valueNoise(_ x: Double, _ t: Double, seed: UInt32) -> Double {
        let x0 = floor(x), t0 = floor(t)
        let fx = x - x0, ft = t - t0
        let sx = fx * fx * (3 - 2 * fx), st = ft * ft * (3 - 2 * ft)
        func corner(_ dx: Double, _ dt: Double) -> Double {
            signed(seed, UInt32(truncatingIfNeeded: Int64(x0 + dx)), UInt32(truncatingIfNeeded: Int64(t0 + dt)))
        }
        let a = corner(0, 0) + (corner(1, 0) - corner(0, 0)) * sx
        let b = corner(0, 1) + (corner(1, 1) - corner(0, 1)) * sx
        return a + (b - a) * st
    }
}
