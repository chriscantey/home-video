import Foundation

/// A short hash of the chain the preview actually draws with: every video layer's enabled
/// flag and parameter values, the audio preset, and every audio layer's flag and values, as 8
/// hex digits (32 bits of FNV-1a 64). `perf.log` carries it as `chain=` on every line, so a
/// slider that changes nothing in the picture can be told apart from one whose change never
/// reached the renderer's chain. Not shown in the status bar.
public enum ChainFingerprint {
    @MainActor
    public static func of(_ chain: SignalChain) -> String {
        var text = ""
        // A Damage layer counts only while it is on, so the Damage layers leave the default
        // chain's hash alone and switching one on changes the hash.
        for l in chain.layers where l.enabled || !(l is any DamageLayer) {
            text += "\(l.id)=\(l.enabled ? 1 : 0)"
            for p in l.parameters { text += ";\(p.id)=\(p.value)" }
            text += "|"
        }
        // The Tape switch counts only while it is off, so the hash with it on is the default's.
        if chain.vhs?.tape.enabled == false { text += "tape=0|" }
        // The Film layers count only while Film is on, so the hash with Film unused is the default's.
        for l in chain.vhs?.film.all ?? [] where chain.vhs?.film.isOn == true {
            text += "\(l.id)=\(l.enabled ? 1 : 0)"
            for p in l.parameters { text += ";\(p.id)=\(p.value)" }
            text += "|"
        }
        // The Telecine's only while the Film goes through it, so the hash is `film`'s until then.
        for l in chain.vhs?.telecine.all ?? [] where chain.vhs?.telecineInUse == true {
            text += "\(l.id)=\(l.enabled ? 1 : 0)"
            for p in l.parameters { text += ";\(p.id)=\(p.value)" }
            text += "|"
        }
        // The Display stage counts only while a CRT layer is on, for the same reason.
        // Re-capture's layers count only while the camera films the screen.
        if chain.displayIsOn {
            for l in (chain.vhs?.crt.all ?? []) + (chain.recaptureIsOn ? chain.vhs?.recapture.all ?? [] : []) {
                text += "\(l.id)=\(l.enabled ? 1 : 0)"
                for p in l.parameters { text += ";\(p.id)=\(p.value)" }
                text += "|"
            }
        }
        // The Output size counts only off Auto, so it leaves the default chain's hash alone.
        if let out = chain.vhs?.output, !out.isAuto {
            text += "output=\(out.size.rawValue)"
            if out.size == .custom { text += ";\(out.width)x\(out.height)" }
            // Fill the frame counts only while it fills, so a 4:3 inside chain hashes as it does without it.
            if chain.fillAspect != nil { text += ";fill" }
            text += "|"
        }
        text += "audio=\(chain.audio.preset.rawValue)|"
        // The mic Strength and the Tape switch count only off their defaults, so they leave the
        // default chain's hash alone.
        if chain.audio.micStrength < AudioChain.fullStrength { text += "strength=\(chain.audio.micStrength)|" }
        if !chain.audio.tapeIsOn { text += "tape=0|" }
        for l in chain.audio.layers + chain.audio.damage.filter(\.enabled) {
            text += "\(l.id)=\(l.enabled ? 1 : 0)"
            for p in l.parameters { text += ";\(p.id)=\(p.value)" }
            text += "|"
        }
        return hash(text)
    }

    /// FNV-1a 64 over the UTF-8 bytes, folded to 32 bits, as 8 lowercase hex digits.
    public static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h ^ (h >> 32)))
    }
}
