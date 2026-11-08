import Foundation

// Audio wear: one value, 0 to 100, on the audio chain. 0 is the preset's own values. Each
// layer kind declares where its parameters sit on a badly worn tape played on a tired deck, and
// the slider moves every parameter of the active preset's layers along the straight line from
// the preset's value to that worn end, through `setParameter`, so every slider under it still
// shows the value and can be nudged after. On Hi-Fi the mono sum comes on past the midpoint.
//
// Every worn end is INFERRED: the published deck figures are for a good machine, not a worn
// one. The ends are set so wear 100 is unmistakable against the preset.
//
// The camcorder mic and the Damage layers have no worn end: the mic records before the tape,
// and the Damage layers are events with their own Strength and Rate.

public enum AudioWear {
    public static let range: ClosedRange<Double> = 0...100
    /// The key a sidecar, a saved preset and the clipboard store the wear under, and the layer
    /// id of the Look override that carries it.
    public static let id = "audioWear"
    /// The wear above which a Hi-Fi chain's mono sum switches on.
    public static let monoAbove = 50.0

    /// Where `kind`'s parameters land at wear 100, as parameter id and value.
    static func wornEnd(_ kind: AudioLayerKind) -> [String: Double] {
        switch kind {
        case .linearBand:
            // Highpass 100 up to 250 Hz, lowpass down to 2.5 kHz: the worn band is a phone line.
            // The narrowest published deck figure is EP's 4 kHz.
            return ["highpass": 250, "lowpass": 2_500]
        case .hiss:
            // -28 dBFS, 14 dB over a good deck's -42, 8 over Worn Linear's -36.
            return ["level": -28]
        case .wowFlutter:
            // 1.5 percent, 7.5 times a good deck's 0.2: a stretched tape on a slipping capstan.
            return ["depth": 1.5]
        case .azimuth:
            return ["gain": -12]
        case .saturation:
            return ["drive": 0.9]
        case .headBump:
            return ["gain": 6]
        case .mute:
            // Twenty short mutes a minute, up to 80 ms each: shed oxide on every pass.
            return ["rate": 20, "longest": 80]
        case .hifiBand:
            // The Hi-Fi band down to 6 kHz with a 150 Hz highpass: a worn drum's carrier loses its
            // deviation and the deck's filter keeps less of it.
            return ["highpass": 150, "lowpass": 6_000]
        case .fmNoise:
            // -32 dBFS against the -48 default: the carrier sits closer to the noise floor.
            return ["level": -32]
        case .dropout:
            // Twenty dropouts to linear a minute against the default two, each about 0.4 s,
            // so a worn Hi-Fi tape falls to its linear track all the time.
            return ["rate": 20, "length": 400]
        case .headSwitchClick:
            return ["level": -42]
        case .expander:
            // The playback expander tracks the compressor 2.5 dB off, so the level pumps.
            return ["tracking": 2.5]
        // The noise reduction keeps its cut: the worn hiss above comes down by it all the same.
        case .camcorderMic, .mono, .whine, .dolbyMismatch, .noiseReduction, .compressor,
             .flutterBurst, .azimuthWander, .clogMuffle, .hifiDropoutBurst,
             .wowGlide, .wornStretch, .crackleBurst, .muteDrop:
            return [:]
        }
    }

    /// The value of a parameter at `wear`: from the preset's `base` to `worn`.
    static func value(base: Double, worn: Double, wear: Double) -> Double {
        let t = min(max(wear, range.lowerBound), range.upperBound) / range.upperBound
        return base + (worn - base) * t
    }
}

extension AudioChain {
    /// Sets the Audio wear and moves every layer of the preset to it, through `setParameter`.
    public func setWear(_ value: Double) {
        wear = min(max(value, AudioWear.range.lowerBound), AudioWear.range.upperBound)
        applyWear()
    }

    /// Sets the Audio wear number without moving any layer: a file's saved layer values already
    /// hold the wear they were saved at.
    func restoreWear(_ value: Double) {
        wear = min(max(value, AudioWear.range.lowerBound), AudioWear.range.upperBound)
    }

    /// Moves the track's layers. The mic has no worn end, and the track's own values come from
    /// its old preset.
    func applyWear() {
        let recipe = track.recipe
        for layer in layers {
            let base = layer.kind.parameters(for: recipe)
            for (id, worn) in AudioWear.wornEnd(layer.kind) {
                guard let b = base.first(where: { $0.id == id })?.value.doubleValue else { continue }
                layer.setParameter(id, to: .float(AudioWear.value(base: b, worn: worn, wear: wear)))
            }
            if layer.kind == .mono, !layer.kind.enabled(for: recipe) {
                layer.enabled = wear > AudioWear.monoAbove
            }
        }
    }
}
