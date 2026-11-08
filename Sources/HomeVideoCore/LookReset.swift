import Foundation

// Reset to Look puts every layer back to a Look's reference chain, the Damage layers included,
// whatever `setLook`
// does with Damage for a built-in Look. Kept apart from Looks.swift so the button does not hang
// on how a Look change treats Damage.

public enum LookReset {
    /// Sets every video, audio and Damage layer's switch and every parameter to the Look's
    /// reference chain, each through the layer's own `setParameter`, so the sidecar follows
    /// as it would after a slider change. Framing is the clip's, not the Look's, and stays.
    @MainActor public static func reset(_ presets: Presets, to look: Look) {
        let ref = Looks.reference(look)
        for (dst, src) in zip(presets.vhs.lookLayers, ref.vhs.lookLayers) {
            if let card = dst as? OutputCardLayer, let from = src as? OutputCardLayer {
                card.userEnabled = from.userEnabled
            } else if !(dst is CaptureLayer) {
                dst.enabled = src.enabled
            }
            for p in src.parameters { dst.setParameter(p.id, to: p.value) }
        }
        // The Display stage goes back only to a preset that carries it, as in `setLook`.
        Looks.applyDisplay(look, from: ref.vhs, to: presets.vhs)
        guard let audio = presets.audio else { return }
        audio.preset = ref.audio.preset
        for (dst, src) in zip(audio.allLayers, ref.audio.allLayers) {
            dst.enabled = src.enabled
            for p in src.parameters { dst.setParameter(p.id, to: p.value) }
        }
        audio.restoreWear(ref.audio.wear)
        audio.setMicStrength(ref.audio.micStrength)
    }

    /// True when any layer, Damage included, differs from the Look's reference chain in its
    /// switch or any value: the chain has drifted and Reset has something to do.
    @MainActor public static func drifted(_ presets: Presets, from look: Look) -> Bool {
        let ref = Looks.reference(look)
        for (a, b) in zip(presets.vhs.lookLayers, ref.vhs.lookLayers) {
            guard Looks.userSwitch(a) == Looks.userSwitch(b), Looks.same(a.parameters, b.parameters) else { return true }
        }
        // The camera: a filmed Look drifts with its Display or camera, any other with
        // the camera on.
        if look.filmsTheScreen ? !Looks.sameDisplay(presets.vhs, ref.vhs) : presets.vhs.recaptureIsOn { return true }
        guard let audio = presets.audio else { return false }
        guard audio.preset == ref.audio.preset, audio.allLayers.count == ref.audio.allLayers.count,
              Presets.same(audio.micStrength, ref.audio.micStrength) else { return true }
        return !zip(audio.allLayers, ref.audio.allLayers).allSatisfy { a, b in
            a.enabled == b.enabled && Looks.same(a.parameters, b.parameters)
        }
    }

    /// The Look the button goes back to: the one the picker reads, else the last one it read
    /// (`behindID`, a built-in Look or a saved preset), else nil (Custom with no Look behind it).
    @MainActor public static func target(_ presets: Presets, behindID: String?) -> Look? {
        presets.look ?? behindID.flatMap(Looks.anyLook(id:))
    }

    /// The button's rule: lit only with a Look behind the chain and something to put back.
    public static func isEnabled(hasLook: Bool, drifted: Bool) -> Bool { hasLook && drifted }

    /// The button's tooltip.
    public static func help(_ look: Look?) -> String {
        look.map { "Back to \($0.name)" } ?? "Reset to Look: choose a Look first"
    }
}

// The Look row's Reset button puts the whole chain back to a fresh launch, every stage
// included, not to the shown Look.

public enum FreshStart {
    /// Sets every layer a setting can name (Framing, the picture layers, the Tape, Film,
    /// Telecine and Display stages, Re-capture, the Output size) and the whole sound to the chain
    /// a fresh launch builds, `SignalChain.standard()`: Fresh SP, Tape and Audio on, every other
    /// stage off at its defaults, Framing and the Output size at theirs. Each value goes through
    /// the layer's own `setParameter`, so the sidecar follows as after a slider change. Framing's
    /// rotation is the clip's (from its track), so it stays. What the Display and Audio switches
    /// held is dropped, as at launch.
    @MainActor public static func reset(_ chain: SignalChain, switches: StageSwitches) {
        let fresh = SignalChain.standard()
        for (dst, src) in zip(chain.settingsLayers, fresh.settingsLayers) {
            if let card = dst as? OutputCardLayer, let from = src as? OutputCardLayer {
                card.userEnabled = from.userEnabled
            } else if !dst.isRequired {
                dst.enabled = src.enabled
            }
            for p in src.parameters where !skipped.contains("\(src.id).\(p.id)") {
                dst.setParameter(p.id, to: p.value)
            }
        }
        let audio = chain.audio, ref = fresh.audio
        audio.preset = ref.preset
        for (dst, src) in zip(audio.allLayers, ref.allLayers) {
            dst.enabled = src.enabled
            for p in src.parameters { dst.setParameter(p.id, to: p.value) }
        }
        audio.restoreWear(ref.wear)
        audio.setMicStrength(ref.micStrength)
        switches.forgetHeld()
    }

    /// The values Reset leaves alone, as `layer.parameter`: the clip's own rotation.
    public static let skipped: Set<String> = SettingsClipboard.skipped

    /// True when anything a setting can name differs from a fresh launch (the clip's rotation
    /// aside), hidden stages included: Reset has something to do.
    @MainActor public static func drifted(_ chain: SignalChain) -> Bool {
        SettingsClipboard.encode(chain) != freshSettings
    }

    /// A fresh launch's settings, as the clipboard writes them, made once.
    @MainActor private static let freshSettings = SettingsClipboard.encode(SignalChain.standard())
}
