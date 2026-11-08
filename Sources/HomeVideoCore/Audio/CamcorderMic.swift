import Foundation

// The camcorder's own microphone, where you can hear the camcorder motor. A camcorder records its
// built-in mic before anything reaches the
// tape, so this layer runs first in every track's list. The mic hears three things besides the
// scene: the head drum and the tape transport (a steady whine over a low rumble), the mic
// preamp's own hiss, and the AGC, which raises the gain in quiet passages until that whole bed
// swells up and lowers it again when someone speaks.
//
// A sidecar or preset that names the parameters of an earlier zoom motor sound
// (`retiredParameters`) loads, and they are ignored.
//
// Motor level is the bed as heard in a silent passage, with the AGC fully lifted, so a render's
// silent stretch reads the set level. The bed goes into the AGC at Motor level minus AGC lift.

extension AudioLayerKind {
    /// The camcorder mic's parameters.
    var camcorderMicParameters: [LayerParameter] {
        func f(_ id: String, _ name: String, _ v: Double, _ r: ClosedRange<Double>) -> LayerParameter {
            LayerParameter(id: id, name: name, value: .float(v), range: r)
        }
        return [f("level", "Motor level (dBFS)", CamcorderMic.defaultLevel, -80...(-20)),
                f("whine", "Whine (Hz)", CamcorderMic.defaultWhine, 400...6_000),
                f("lift", "AGC lift (dB)", 12, 0...24),
                f("seed", "Seed", 0, 0...999)]
    }
}

/// The bed and the AGC, on every channel alike (one mic).
final class CamcorderMic: AudioLayerProcessor {
    static let defaultLevel = -44.0
    /// Near the whine a reference camcorder clip measures: 1257 Hz, with harmonics at 2514
    /// and 3771 Hz.
    static let defaultWhine = 1_250.0
    /// NTSC VHS drum rotation: 1798.2 rpm, 29.97 Hz.
    static let drumHz = 1_798.2 / 60
    /// The AGC's aim for the program's peak (INFERRED): anything quieter is lifted, up to `lift`.
    static let targetDB = -24.0
    /// The AGC's attack time constant (INFERRED, "tens of ms").
    static let attackSeconds = 0.03
    /// Seconds the AGC takes to climb the whole lift once the sound stops (INFERRED, 1 to 2 s).
    static let releaseSeconds = 1.5
    /// The parameters of an earlier zoom motor sound. A saved preset that names them still
    /// loads, and they are passed over (`UserPresets`).
    static let retiredParameters: Set<String> = ["zoom", "zoomLevel", "zoomRate", "zoomLength"]

    // The bed's power shares, summing to 1 (INFERRED): the whine and two partials, the drum's
    // rotation and its second harmonic, the transport's rumble noise, the preamp hiss.
    static let shares = (whine1: 0.40, whine2: 0.12, whine3: 0.04, drum1: 0.10, drum2: 0.04,
                         rumble: 0.10, hiss: 0.20)

    let sampleRate: Double
    let whineHz: Double
    let lift: Double
    let seed: UInt32
    let w1: Double, w2: Double, w3: Double, d1: Double, d2: Double
    let rumbleGain: Float
    let rumbleFilters: [AudioBiquad]
    let rumble: NoiseSource
    let hiss: NoiseSource
    var whinePhase = 0.0, drumPhase = 0.0
    var envelope = 0.0
    /// The AGC's gain now, in dB over unity (0 to `lift`).
    var gainDB: Double
    let attackCoef: Double
    let releaseStep: Double
    /// The mic Strength as a share: 1 is the mic as modeled, and below it the output is
    /// mixed with the scene the mic heard. The chain leaves the layer out at 0.
    let strength: Float
    var n: Int64 = 0

    init(spec s: AudioLayerSpec, sampleRate sr: Double) {
        sampleRate = sr
        strength = Float(min(max(s.values["strength"]?.doubleValue ?? 1, 0), 1))
        whineHz = s.float("whine")
        lift = max(0, s.float("lift"))
        seed = DamageSchedule.mix(Int(s.float("seed")))
        let a0 = pow(10, (s.float("level") - lift) / 20)
        func sine(_ share: Double) -> Double { (2 * share).squareRoot() * a0 }
        w1 = sine(Self.shares.whine1); w2 = sine(Self.shares.whine2); w3 = sine(Self.shares.whine3)
        d1 = sine(Self.shares.drum1); d2 = sine(Self.shares.drum2)
        let noiseSeed = (audioSeed ^ 0x434D) &+ UInt64(seed) &* 0x9E37_79B9
        rumble = NoiseSource(color: .pink, levelDB: 20 * log10(Self.shares.rumble.squareRoot() * a0), seed: noiseSeed)
        rumbleGain = bandLimitedNoiseGain(color: .pink, lowpass: 150, sampleRate: sr)
        rumbleFilters = butterworth4Q.map { AudioBiquad(.lowpass(hz: 150, q: $0), sampleRate: sr) }
        hiss = NoiseSource(color: .white, levelDB: 20 * log10(Self.shares.hiss.squareRoot() * a0), seed: noiseSeed ^ 0x48)
        // A camcorder switched on in a quiet room starts lifted.
        gainDB = lift
        attackCoef = exp(-1 / (Self.attackSeconds * sr))
        releaseStep = lift / (Self.releaseSeconds * sr)
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        let tau = 2 * Double.pi
        for i in 0..<block.frames {
            let t = Double(n + Int64(i)) / sampleRate
            // The whine wanders 0.2 percent in pitch and 25 percent in level, slowly.
            let drift = Hash.valueNoise(t * 0.5, 0, seed: seed ^ 0x57)
            let flutter = 1 + 0.25 * Hash.valueNoise(t * 2, 1, seed: seed ^ 0x46)
            whinePhase += tau * whineHz * (1 + 0.002 * drift) / sampleRate
            if whinePhase > tau { whinePhase -= tau }
            drumPhase += tau * Self.drumHz / sampleRate
            if drumPhase > tau { drumPhase -= tau }
            var bed = flutter * (w1 * sin(whinePhase) + w2 * sin(2 * whinePhase) + w3 * sin(3 * whinePhase))
            bed += d1 * sin(drumPhase) + d2 * sin(2 * drumPhase)
            bed += Double(rumbleGain * rumbleFilters.reduce(rumble.next()) { $1.process($0) })
            bed += Double(hiss.next())

            // The AGC rides the scene plus the bed.
            var peak = 0.0
            for p in block.channels {
                let x = Double(p[i]) + bed
                peak = max(peak, abs(x))
            }
            envelope = max(peak, envelope * 0.999_5)
            let level = 20 * log10(max(envelope, 1e-9))
            let want = min(lift, max(0, Self.targetDB - level))
            if want < gainDB {
                gainDB = want + (gainDB - want) * attackCoef
            } else {
                gainDB = min(want, gainDB + releaseStep)
            }
            let g = Float(pow(10, gainDB / 20))
            let heard = Float(bed)
            if strength < 1 {
                for p in block.channels {
                    let x = p[i]
                    p[i] = x + strength * ((x + heard) * g - x)
                }
            } else {
                for p in block.channels { p[i] = (p[i] + heard) * g }
            }
        }
        n += Int64(block.frames)
    }
}
