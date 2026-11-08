import Foundation

// Shuffle rolls a tape. A random built-in Look is the basis, set with `setLook` so the picker
// and Reset know it, then the listed sliders are nudged around it, a few switches flipped, some
// Damage switched on and the audio preset sometimes swapped. Everything moves through each
// layer's own switch and `setParameter`, so the sidecar follows as it would after a slider
// change. Framing is the clip's and is never touched. A seeded generator makes a roll a pure
// function of its seed: the button draws a fresh seed for every press.

public enum Shuffle {
    /// How far a nudged slider may move from the Look's value, as a share of its range width.
    static let nudge = 0.25
    /// The odds that a listed slider is nudged at all.
    static let nudgeOdds = 0.5
    /// The odds that an optional layer switch flips.
    static let flipOdds = 0.2
    /// The odds that a Damage layer comes on.
    static let damageOdds = 0.3
    /// Where a Damage layer's Strength lands, as a share of the way through its range.
    static let damageStrength = 0.3...0.6
    /// The odds that the basis Look's audio preset stays.
    static let keepAudioOdds = 0.7

    /// Rolls a tape on the chain and returns the basis Look. Same seed, same chain.
    @discardableResult
    @MainActor public static func roll(_ presets: Presets, seed: UInt64) -> Look {
        var rng = SplitMix64(seed: seed)
        // A roll is a tape, not a camera: neither the film Looks nor the Looks that film the
        // screen are a basis, so a seed rolls the same tape it did before those Looks existed.
        let basis = Looks.all.filter { !$0.filmsTheScreen && !Looks.film.contains($0.id) }.randomElement(using: &rng)!
        presets.setLook(basis)

        // The audio preset first: a new preset rebuilds the audio layers at its own values.
        if let audio = presets.audio, !rng.chance(keepAudioOdds) {
            // Linear NR is left out of the swap so a seed rolls the sound it did before Linear NR.
            // It still comes with Fresh SP, the basis that keeps its sound.
            audio.preset = AudioPreset.allCases.filter { $0 != .off && $0 != .linearNR }.randomElement(using: &rng)!
        }

        // Every listed picture layer (the sidebar's Tune list), then every audio layer.
        let picture = presets.vhs.all.filter {
            !($0 is OSDLayer) && !($0 is any DamageLayer) && LayerTitle.isListed($0)
        }
        for layer in picture {
            if !layer.isRequired, let on = Looks.userSwitch(layer), rng.chance(flipOdds) {
                if let card = layer as? OutputCardLayer { card.userEnabled = !on } else { layer.enabled = !on }
            }
            nudgeSliders({ layer.parameters }, layer.setParameter, &rng)
        }
        // The camcorder's removed zoom sliders still take their draws, so a seed rolls the tape
        // it did before (`retiredMicSliders`).
        for layer in presets.audio?.layers ?? [] {
            if rng.chance(flipOdds) { layer.enabled.toggle() }
            nudgeSliders({ withRetiredSliders(layer) }, layer.setParameter, &rng)
        }

        // Damage, picture and audio: some layers come on at a mid Strength with a fresh Seed,
        // the Rate as the Look set it (its own or the default). The rest stay as the Look set them.
        for layer in presets.vhs.damage.all where rng.chance(damageOdds) {
            layer.enabled = true
            wear(layer.parameters, layer.setParameter, &rng)
        }
        for layer in presets.audio?.damage ?? [] where rng.chance(damageOdds) {
            layer.enabled = true
            wear(layer.parameters, layer.setParameter, &rng)
        }
        return basis
    }

    /// The camcorder mic's Zoom rate and Zoom length, from an earlier version with a zoom sound,
    /// at that version's defaults and ranges. Shuffle nudges them after the Whine, where they
    /// sat, so each seed spends the same draws and every later layer rolls as it did. The layer
    /// has no such parameter, so the nudge sets nothing. (That version's Zoom level was never
    /// nudged and its Zoom sound is a choice, so neither took a draw.)
    static let retiredMicSliders = [
        LayerParameter(id: "zoomRate", name: "Zoom rate (per minute)", value: .float(1), range: 0...20),
        LayerParameter(id: "zoomLength", name: "Zoom length (s)", value: .float(2), range: 0.5...5),
    ]

    /// `layer`'s parameters, with `retiredMicSliders` back in place on the camcorder mic.
    @MainActor static func withRetiredSliders(_ layer: AudioLayer) -> [LayerParameter] {
        var p = layer.parameters
        guard layer.kind == .camcorderMic, let whine = p.firstIndex(where: { $0.id == "whine" }) else { return p }
        p.insert(contentsOf: retiredMicSliders, at: whine + 1)
        return p
    }

    /// A Damage layer switched on by a roll: Strength 0.3 to 0.6 of the way through its range
    /// and a fresh whole Seed. Rate and the rest stay.
    @MainActor static func wear(_ parameters: [LayerParameter], _ set: (String, ParameterValue) -> Void,
                                _ rng: inout SplitMix64) {
        if let p = parameters.first(where: { $0.id == "strength" }) {
            let w = p.range.upperBound - p.range.lowerBound
            set("strength", .float(p.range.lowerBound + w * Double.random(in: damageStrength, using: &rng)))
        }
        if let p = parameters.first(where: { $0.id == "seed" }) {
            set("seed", .float(Double(Int.random(in: Int(p.range.lowerBound)...Int(p.range.upperBound), using: &rng))))
        }
    }

    /// Each float slider, on a coin flip, moves up to a quarter of its range from where the Look
    /// put it. Choices and toggles stay. The layer's `setParameter` clamps, and so does this.
    @MainActor static func nudgeSliders(_ parameters: () -> [LayerParameter], _ set: (String, ParameterValue) -> Void,
                                        _ rng: inout SplitMix64) {
        // Read each value fresh: one parameter can move another (an audio tape speed, its lowpass).
        for id in parameters().map(\.id) {
            guard let p = parameters().first(where: { $0.id == id }), let v = p.value.doubleValue,
                  rng.chance(nudgeOdds) else { continue }
            let w = p.range.upperBound - p.range.lowerBound
            var next = min(max(v + w * Double.random(in: -nudge...nudge, using: &rng), p.range.lowerBound), p.range.upperBound)
            if id == "seed" { next = next.rounded() }
            set(id, .float(next))
        }
    }

    /// The button's tooltip.
    public static let help = "Shuffle: roll a random tape"

    /// A seed for one press of the button, from the system generator.
    public static func freshSeed() -> UInt64 {
        var system = SystemRandomNumberGenerator()
        return system.next()
    }
}

/// The system generator is not seedable, so a roll draws from the audio noise's SplitMix64
/// (AudioDSP.swift), the same stream on every platform. Not for anything secret.
extension SplitMix64: RandomNumberGenerator {
    /// True with probability `p`.
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}
