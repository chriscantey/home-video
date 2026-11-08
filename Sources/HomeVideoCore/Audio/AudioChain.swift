import Foundation
import Observation

// The audio chain: an ordered list of audio layers with the video Layer's shape (id, name,
// enabled, LayerParameter list, setParameter), so the sidebar and `homevideo-render --set` treat
// them alike. The layers hold settings only. `spec` snapshots them as plain values, and an
// `AudioChainProcessor` built from a spec runs the DSP on any thread: the exporter's audio
// queue, the preview's processing tap, a test.

/// Where the sound starts: the scene as it was, or the camcorder's own mic with its
/// motor, preamp hiss and AGC. The mic is the `audio-camcorder` layer's switch.
public enum AudioMic: String, CaseIterable, Sendable {
    case clean
    case camcorder

    public var label: String {
        switch self {
        case .clean: return "Clean"
        case .camcorder: return "Camcorder"
        }
    }
}

/// Which track of the tape the deck's line out plays. It follows Tape: with Tape off
/// there is no track and the mic plays alone.
public enum AudioTrack: String, CaseIterable, Sendable {
    case hifi
    /// The linear track on a good deck with its noise reduction matched, the default.
    case linearNR = "linearnr"
    case linear
    case worn
    case ep
    case off

    public var label: String {
        switch self {
        case .hifi: return "Hi-Fi"
        case .linearNR: return "Linear NR"
        case .linear: return "Linear"
        case .worn: return "Worn Linear"
        case .ep: return "EP Linear"
        case .off: return "Off"
        }
    }

    /// The old preset that builds this track's layers and values.
    public var recipe: AudioPreset {
        switch self {
        case .hifi: return .hifi
        case .linearNR: return .linearNR
        case .linear: return .linear
        case .worn: return .wornLinear
        case .ep: return .epLinear
        case .off: return .off
        }
    }
}

/// The old one-menu Audio picker, kept as the name a sidecar, a saved preset, the
/// clipboard, a Look and `--preset audio=` carry. Each maps to a mic and a track:
/// Camcorder is the camcorder mic on Hi-Fi, every other preset the clean mic on its track.
public enum AudioPreset: String, CaseIterable, Sendable {
    /// The FM Hi-Fi track, which a Hi-Fi deck's line out plays by default.
    case hifi
    /// Hi-Fi with the camcorder's own mic on: the drum and transport whine, the preamp
    /// hiss, and the AGC swelling them in the quiet gaps.
    case camcorder
    /// The linear track at SP on a good deck with B type noise reduction matched on record and
    /// playback: Linear's band, mono and wow and flutter, the hiss up to 10 dB lower in the
    /// treble. The default.
    case linearNR = "linearnr"
    /// The linear track at SP: band limited, hissy, a little wobbly, mono.
    case linear
    /// The linear track at SP on a tired deck: twice the wow and flutter, 6 dB more hiss, a
    /// stronger head bump, and short dropouts that mute the sound.
    case wornLinear = "wornlinear"
    /// The linear track of a six-hour (EP) tape: a band near 4 kHz, three times Linear's
    /// flutter, and azimuth loss on the highs.
    case epLinear = "eplinear"
    /// The source audio, untouched.
    case off

    public var label: String {
        switch self {
        case .hifi: return "Hi-Fi"
        case .camcorder: return "Camcorder"
        case .linearNR: return "Linear NR"
        case .linear: return "Linear"
        case .wornLinear: return "Worn Linear"
        case .epLinear: return "EP Linear"
        case .off: return "Off"
        }
    }

    public var mic: AudioMic { self == .camcorder ? .camcorder : .clean }

    public var track: AudioTrack {
        switch self {
        case .hifi, .camcorder: return .hifi
        case .linearNR: return .linearNR
        case .linear: return .linear
        case .wornLinear: return .worn
        case .epLinear: return .ep
        case .off: return .off
        }
    }

    /// The old preset a mic and a track make, nil for a pair the old menu never had (the
    /// camcorder mic on any track but Hi-Fi).
    public init?(mic: AudioMic, track: AudioTrack) {
        switch (mic, track) {
        case (.camcorder, .hifi): self = .camcorder
        case (.camcorder, _): return nil
        case (.clean, _): self = track.recipe
        }
    }

    /// The values this preset sets over its layers' defaults, as (layer id, parameter id,
    /// value). Every number names its source, or says INFERRED where there is none. A tape
    /// speed choice also sets the linear lowpass. A parameter "enabled" with a bool sets the
    /// layer's switch.
    var overrides: [(layer: String, parameter: String, value: ParameterValue)] {
        switch self {
        case .linear, .off:
            return []
        case .linearNR:
            // Linear SP as it is: the same band, mono, saturation and the 0.2% wow and flutter
            // of a deck in spec (Sencore TT190), which Worn Linear doubles for a tired one. The
            // hiss stays the tape's own -42 dBFS (a 42 dB S/N). The noise reduction layer, on in
            // this track's list, takes the treble of that hiss down on playback.
            return []
        case .hifi:
            // Hi-Fi is stereo: its mono sum is there for the Audio wear slider, off here.
            return [("audio-mono", "enabled", .bool(false))]
        case .camcorder:
            return AudioPreset.hifi.overrides + [("audio-camcorder", "enabled", .bool(true))]
        case .wornLinear:
            return [
                // Wow and flutter doubled: 0.4% against a deck's 0.2% (Sencore TT190).
                ("audio-wow", "depth", .float(0.4)),
                // Hiss 6 dB up: -36 dBFS against the -42 of a 42 dB S/N.
                ("audio-hiss", "level", .float(-36)),
                // Head bump at the top of +2 to +3 dB near 60 to 100 Hz (INFERRED): +3 dB, and
                // a broader Q 0.7 so the boom spreads over that band.
                ("audio-bump", "gain", .float(3)),
                ("audio-bump", "q", .float(0.7)),
                // The mute dropouts keep their defaults: 3 a minute, 5 to 30 ms (INFERRED, no
                // source gives a linear dropout figure).
            ]
        case .epLinear:
            return [
                // The six-hour band: highpass 100 Hz, lowpass 6 kHz (one user's EP sweep) for the
                // head and tape, and the azimuth shelf below takes the whole response to about
                // 4.4 kHz at -3 dB, near the 4 kHz usually given for EP. A 4 kHz lowpass plus the
                // shelf measured 2.8 kHz, narrower than any EP figure found, so the shelf would
                // count twice.
                ("audio-band", "speed", .choice(TapeSpeed.ep.rawValue)),
                ("audio-band", "lowpass", .float(6_000)),
                // Flutter up again: 0.3% total with half of it flutter, 0.15% of flutter
                // against Linear's 0.05% (0.2% at a 0.25 share). The tape moves at
                // a third of SP's speed (11.1 against 33.3 mm/s), so the same
                // capstan and guide irregularities are a larger share of it (INFERRED).
                ("audio-wow", "depth", .float(0.3)),
                ("audio-wow", "flutter", .float(0.5)),
            ]
        }
    }
}

/// What one audio layer does. Each kind owns its parameter list and defaults.
public enum AudioLayerKind: String, Sendable {
    // The camcorder's own mic, ahead of the tape in every track (CamcorderMic.swift).
    case camcorderMic
    // Linear SP, in the order they run.
    case mono, saturation, linearBand, headBump, wowFlutter, hiss, whine, dolbyMismatch
    // Worn Linear and EP Linear add these to Linear SP.
    case azimuth, mute
    // Linear NR adds the deck's matched noise reduction to Linear SP.
    case noiseReduction
    // Hi-Fi, in order.
    case compressor, fmNoise, headSwitchClick, expander, hifiBand, dropout
    // The Damage pass (AudioDamage.swift), after any preset's stages, off by default.
    case flutterBurst, azimuthWander, clogMuffle, hifiDropoutBurst
    case wowGlide, wornStretch, crackleBurst, muteDrop

    var id: String {
        switch self {
        case .flutterBurst, .azimuthWander, .clogMuffle, .hifiDropoutBurst,
             .wowGlide, .wornStretch, .crackleBurst, .muteDrop: return damageID
        case .camcorderMic: return "audio-camcorder"
        case .mono: return "audio-mono"
        case .saturation: return "audio-saturation"
        case .linearBand, .hifiBand: return "audio-band"
        case .headBump: return "audio-bump"
        case .wowFlutter: return "audio-wow"
        case .hiss: return "audio-hiss"
        case .whine: return "audio-whine"
        case .dolbyMismatch: return "audio-dolby"
        case .azimuth: return "audio-azimuth"
        case .mute: return "audio-mute"
        case .noiseReduction: return "audio-nr"
        case .compressor: return "audio-compressor"
        case .fmNoise: return "audio-fm-noise"
        case .headSwitchClick: return "audio-click"
        case .expander: return "audio-expander"
        case .dropout: return "audio-dropout"
        }
    }

    var name: String {
        switch self {
        case .flutterBurst, .azimuthWander, .clogMuffle, .hifiDropoutBurst,
             .wowGlide, .wornStretch, .crackleBurst, .muteDrop: return damageName
        case .camcorderMic: return "Camcorder mic"
        case .mono: return "Sum to mono"
        case .saturation: return "Tape saturation"
        case .linearBand: return "Band limit (linear)"
        case .headBump: return "Head bump"
        case .wowFlutter: return "Wow and flutter"
        case .hiss: return "Hiss"
        case .whine: return "Line-rate whine"
        case .dolbyMismatch: return "Dolby B mismatch"
        case .azimuth: return "Azimuth loss"
        case .mute: return "Dropouts (mute)"
        case .noiseReduction: return "Noise reduction"
        case .compressor: return "Compressor 2:1 (record)"
        case .fmNoise: return "FM channel noise"
        case .headSwitchClick: return "Head-switch click"
        case .expander: return "Expander 1:2 (playback)"
        case .hifiBand: return "Band limit (Hi-Fi)"
        case .dropout: return "Dropouts to linear"
        }
    }

    /// Off by default: the optional Dolby B mismatch toggle, the camcorder mic, and every
    /// Damage layer.
    var defaultEnabled: Bool { self != .dolbyMismatch && self != .camcorderMic && !isDamage }

    /// This kind's switch as `preset` sets it: the default unless the preset overrides it.
    func enabled(for preset: AudioPreset?) -> Bool {
        var on = defaultEnabled
        for o in preset?.overrides ?? [] where o.layer == id && o.parameter == "enabled" {
            if let b = o.value.boolValue { on = b }
        }
        return on
    }

    var defaultParameters: [LayerParameter] {
        func f(_ id: String, _ name: String, _ v: Double, _ r: ClosedRange<Double>) -> LayerParameter {
            LayerParameter(id: id, name: name, value: .float(v), range: r)
        }
        switch self {
        case .flutterBurst, .azimuthWander, .clogMuffle, .hifiDropoutBurst,
             .wowGlide, .wornStretch, .crackleBurst, .muteDrop:
            return damageParameters
        case .camcorderMic:
            return camcorderMicParameters
        case .mono:
            return []
        case .saturation:
            return [f("drive", "Drive", 0.3, 0...1), f("emphasis", "Pre-emphasis (dB)", 6, 0...12)]
        case .linearBand:
            return [LayerParameter(id: "speed", name: "Tape speed", value: .choice(TapeSpeed.sp.rawValue),
                                   options: TapeSpeed.options),
                    f("highpass", "Highpass (Hz)", 100, 20...300),
                    f("lowpass", "Lowpass (Hz)", 10_000, 2_000...20_000)]
        case .headBump:
            return [f("gain", "Gain (dB)", 2, 0...6), f("frequency", "Frequency (Hz)", 80, 40...200),
                    f("q", "Q", 1, 0.3...3)]
        case .wowFlutter:
            return [f("depth", "Depth (%)", 0.2, 0...2), f("wow", "Wow rate (Hz)", 0.5, 0.1...2),
                    f("flutter", "Flutter share", 0.25, 0...1)]
        case .hiss:
            return [f("level", "Level (dBFS)", -42, -90...(-20)),
                    LayerParameter(id: "color", name: "Color", value: .choice(NoiseColor.pink.rawValue),
                                   options: NoiseColor.allCases.map { .init(value: $0.rawValue, label: $0.label) })]
        case .whine:
            return [f("level", "Level (dBFS)", -60, -90...(-30))]
        case .dolbyMismatch:
            return [f("gain", "Treble shelf (dB)", 4, 0...8), f("frequency", "Shelf (Hz)", 5_000, 2_000...10_000)]
        case .azimuth:
            // A head tilted against the recording loses short wavelengths first: the loss goes
            // as sinc(pi w tan(theta) / lambda), and at EP's 11.1 mm/s a 3 kHz tone is 3.7 um
            // long, a third of SP's. No source gives an azimuth figure, so the gentle shelf,
            // -3 dB above 2 kHz, is INFERRED.
            return [f("gain", "Treble loss (dB)", -3, -12...0), f("frequency", "Shelf (Hz)", 2_000, 1_000...8_000)]
        case .mute:
            // Linear dropouts: oxide shed or a crease lifts the tape off the stationary head and
            // the sound drops out for a moment. Rate and lengths are INFERRED: a few a minute,
            // 5 to 30 ms each.
            return [f("rate", "Rate (per minute)", 3, 0...30), f("shortest", "Shortest (ms)", 5, 1...100),
                    f("longest", "Longest (ms)", 30, 1...200)]
        case .noiseReduction:
            // A B type sliding band pair, matched: the record side lifts quiet treble and the
            // playback side takes it back down, so the program comes out flat and the hiss the
            // tape added in between comes out lower. Wikipedia's Dolby noise reduction page:
            // "effective from approximately 1 kHz upwards ... 3 dB at 600 Hz,
            // 6 dB at 1.2 kHz, 8 dB at 2.4 kHz, and 10 dB at 5 kHz", "about 9 dB" A weighted,
            // full on "a low-level signal" and none at "Dolby Level". A first order shelf 10 dB
            // deep turning at 540 Hz gives 3.0, 6.0, 8.5 and 9.6 dB at those four (fitted).
            // Its VHS page: "linear stereo VHS VCRs use Dolby B noise reduction for recording
            // and playback". The levels where the cut slides off are INFERRED.
            return [f("cut", "Hiss cut (dB)", 10, 0...20), f("frequency", "Turnover (Hz)", 540, 200...4_000)]
        case .compressor:
            return [f("attack", "Attack (ms)", 5, 1...50), f("release", "Release (ms)", 100, 20...500)]
        case .fmNoise:
            return [f("level", "Level (dBFS)", -48, -90...(-30))]
        case .headSwitchClick:
            return [f("level", "Level (dBFS)", -55, -90...(-20))]
        case .expander:
            return [f("attack", "Attack (ms)", 5, 1...50), f("release", "Release (ms)", 100, 20...500),
                    f("tracking", "Tracking error (dB)", 0.5, -3...3)]
        case .hifiBand:
            return [f("highpass", "Highpass (Hz)", 20, 10...200), f("lowpass", "Lowpass (Hz)", 20_000, 5_000...22_000)]
        case .dropout:
            return [f("rate", "Rate (per minute)", 2, 0...30), f("length", "Length (ms)", 150, 20...1_000),
                    f("click", "Click (dBFS)", -30, -90...(-10))]
        }
    }

    /// Every track starts with the camcorder mic, off unless the preset or a Look turns it on.
    static let linearSP: [AudioLayerKind] = [.camcorderMic, .mono, .saturation, .linearBand, .headBump, .wowFlutter,
                                             .hiss, .whine, .dolbyMismatch]
    /// Linear SP with the mute dropouts last, so a dropout silences the hiss too (the tape is
    /// off the head).
    static let wornLinear: [AudioLayerKind] = linearSP + [.mute]
    /// Linear SP with the playback side of the noise reduction right after the hiss, where the
    /// head's output reaches the decoder.
    static let linearNR: [AudioLayerKind] = [.camcorderMic, .mono, .saturation, .linearBand, .headBump, .wowFlutter,
                                             .hiss, .noiseReduction, .whine, .dolbyMismatch]
    /// Linear SP with the azimuth loss right after the band limit, where the head reads.
    static let epLinear: [AudioLayerKind] = [.camcorderMic, .mono, .saturation, .linearBand, .azimuth, .headBump,
                                             .wowFlutter, .hiss, .whine, .dolbyMismatch]
    /// Hi-Fi, with a mono sum last that the preset leaves off (the Audio wear slider sets it).
    static let hifi: [AudioLayerKind] = [.camcorderMic, .compressor, .fmNoise, .headSwitchClick, .expander,
                                         .hifiBand, .dropout, .mono]

    /// Off has no track, only the camcorder mic, which plays alone when switched on.
    static func kinds(for preset: AudioPreset) -> [AudioLayerKind] {
        switch preset {
        case .hifi, .camcorder: return hifi
        case .linear: return linearSP
        case .linearNR: return linearNR
        case .wornLinear: return wornLinear
        case .epLinear: return epLinear
        case .off: return [.camcorderMic]
        }
    }

    /// This kind's parameters as `preset` sets them: the defaults with the preset's overrides.
    func parameters(for preset: AudioPreset?) -> [LayerParameter] {
        var ps = defaultParameters
        for o in preset?.overrides ?? [] where o.layer == id {
            guard let i = ps.firstIndex(where: { $0.id == o.parameter }) else { continue }
            ps[i].value = o.value
            if self == .linearBand, o.parameter == "speed", let c = o.value.choiceValue, let speed = TapeSpeed(rawValue: c),
               let j = ps.firstIndex(where: { $0.id == "lowpass" }) {
                ps[j].value = .float(AudioLayer.linearLowpass(speed))
            }
        }
        return ps
    }
}

/// One audio layer's settings. Main actor, observed by the sidebar like a video layer.
@MainActor
@Observable
public final class AudioLayer {
    public let kind: AudioLayerKind
    public var id: String { kind.id }
    public var name: String { kind.name }
    public var isRequired: Bool { false }
    public var enabled: Bool { didSet { onChange?() } }
    public private(set) var parameters: [LayerParameter]
    @ObservationIgnored var onChange: (() -> Void)?

    /// A layer at `preset`'s values (the kind's defaults without one).
    public init(kind: AudioLayerKind, preset: AudioPreset? = nil) {
        self.kind = kind
        enabled = kind.enabled(for: preset)
        parameters = kind.parameters(for: preset)
    }

    public func value(_ id: String) -> ParameterValue? { parameters.first { $0.id == id }?.value }

    /// Sets a parameter, clamping floats to the range and ignoring unknown choices. The tape
    /// speed picks the linear lowpass (10, 7 or 4 kHz for SP, LP, EP).
    public func setParameter(_ id: String, to value: ParameterValue) {
        guard let i = parameters.firstIndex(where: { $0.id == id }) else { return }
        let p = parameters[i]
        switch (p.value, value) {
        case (.float, .float(let v)):
            parameters[i].value = .float(min(max(v, p.range.lowerBound), p.range.upperBound))
        case (.bool, .bool):
            parameters[i].value = value
        case (.choice, .choice(let c)):
            guard p.options.contains(where: { $0.value == c }) else { return }
            parameters[i].value = value
            if kind == .linearBand, id == "speed", let speed = TapeSpeed(rawValue: c),
               let j = parameters.firstIndex(where: { $0.id == "lowpass" }) {
                parameters[j].value = .float(AudioLayer.linearLowpass(speed))
            }
        default:
            return
        }
        onChange?()
    }

    /// The linear track's lowpass per tape speed.
    public nonisolated static func linearLowpass(_ speed: TapeSpeed) -> Double {
        switch speed {
        case .sp: return 10_000
        case .lp: return 7_000
        case .ep: return 4_000
        }
    }

    var spec: AudioLayerSpec {
        AudioLayerSpec(kind: kind, values: Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.value) }))
    }
}

/// The ordered audio layers: the mic, then the chosen track's.
@MainActor
@Observable
public final class AudioChain {
    /// The tape track. Choosing one rebuilds the track's layers at its defaults and the wear,
    /// and keeps the mic as it is.
    public private(set) var track: AudioTrack
    /// The camcorder mic layer, first in `layers` on every track, kept across track changes.
    public let micLayer: AudioLayer
    public private(set) var layers: [AudioLayer] = []
    /// How much of the camcorder mic plays, 0 to 100: 100 is the mic as modeled, 0 the
    /// clean mic, and between them the mic's output mixed with the scene it heard.
    public var micStrength: Double = AudioChain.fullStrength {
        didSet { onChange?() }
    }
    public nonisolated static let fullStrength = 100.0
    public nonisolated static let strengthRange: ClosedRange<Double> = 0...100
    /// The key a sidecar, a saved preset and the clipboard store the Strength under, and the
    /// layer id of the Look override that carries it.
    public nonisolated static let strengthID = "audioMicStrength"
    /// Whether the Tape stage is on. Off skips the track, its wear and the audio
    /// Damage, so the mic plays alone. An input from the stage switch, never saved with the
    /// audio settings.
    public var tapeIsOn = true {
        didSet { onChange?() }
    }
    /// The mic: clean, or the camcorder mic layer switched on.
    public var mic: AudioMic {
        get { micLayer.enabled ? .camcorder : .clean }
        set { micLayer.enabled = newValue == .camcorder }
    }

    /// The old one-menu preset the mic and the track read as: Camcorder on Hi-Fi
    /// with the mic on, else the track's own (the camcorder mic on Linear reads Linear with the
    /// mic layer on, as the Shoebox Look sets it). Setting it resets the mic, its Strength
    /// and the track to that preset's defaults, as the old menu did, even when it is unchanged.
    public var preset: AudioPreset {
        get { AudioPreset(mic: mic, track: track) ?? track.recipe }
        set {
            let fresh = AudioLayer(kind: .camcorderMic, preset: newValue)
            micLayer.enabled = fresh.enabled
            for p in fresh.parameters { micLayer.setParameter(p.id, to: p.value) }
            micStrength = Self.fullStrength
            track = newValue.track
            rebuild()
        }
    }

    /// Sets the track and rebuilds its layers, keeping the mic.
    public func setTrack(_ value: AudioTrack) {
        track = value
        rebuild()
    }

    /// Sets the mic Strength, clamped to 0 to 100.
    public func setMicStrength(_ value: Double) {
        micStrength = min(max(value, Self.strengthRange.lowerBound), Self.strengthRange.upperBound)
    }
    /// The Audio wear slider (AudioWear.swift), 0 to 100: 0 is the preset's own values.
    /// `setWear` moves the layers, and a new preset is built at the same wear.
    public internal(set) var wear: Double = 0
    /// The Damage pass's audio layers: kept across preset changes, off by default, run after
    /// the preset's layers (not on Off, and the Hi-Fi dropout only on Hi-Fi).
    public let damage: [AudioLayer]
    /// The preset's layers, then the Damage layers.
    public var allLayers: [AudioLayer] { layers + damage }
    /// Called after any preset, enabled or parameter change (the preview tap's hook).
    @ObservationIgnored public var onChange: (() -> Void)?
    /// The picture's head clog (switch, strength, rate a minute, seed), for the audio clog's
    /// "Follow the picture". `SignalChain.standard()` wires it.
    @ObservationIgnored public var pictureClog: (() -> (enabled: Bool, strength: Double, rate: Double, seed: Double))?
    /// The picture's tape speed, for the damage layers when the preset has no linear band.
    @ObservationIgnored public var videoSpeed: (() -> TapeSpeed)?

    /// The sound a new chain starts with, Fresh SP's: the linear track with its noise
    /// reduction, less hiss than plain Linear and not as clean as Hi-Fi.
    public nonisolated static let defaultPreset: AudioPreset = .linearNR

    public convenience init(preset: AudioPreset = AudioChain.defaultPreset) {
        self.init(mic: preset.mic, track: preset.track)
    }

    public init(mic: AudioMic, track: AudioTrack) {
        self.track = track
        micLayer = AudioLayer(kind: .camcorderMic, preset: AudioPreset(mic: mic, track: .hifi))
        damage = AudioLayerKind.damage.map { AudioLayer(kind: $0) }
        rebuild()
        micLayer.onChange = { [weak self] in self?.onChange?() }
        for l in damage { l.onChange = { [weak self] in self?.onChange?() } }
    }

    /// The mic, then the track's layers (every track's list starts with the mic) at the
    /// track's values and the wear.
    private func rebuild() {
        let recipe = track.recipe
        layers = [micLayer] + AudioLayerKind.kinds(for: recipe).filter { $0 != .camcorderMic }
            .map { AudioLayer(kind: $0, preset: recipe) }
        if wear > 0 { applyWear() }
        for l in layers where l !== micLayer { l.onChange = { [weak self] in self?.onChange?() } }
        onChange?()
    }

    /// The Audio stage's switch: on while the chain changes the sound, the camcorder mic
    /// or a tape track. The Tape stage still decides whether the track plays.
    public var isOn: Bool { mic == .camcorder || track != .off }

    /// What the Audio switch held when it went off: the mic, its Strength, the track and the
    /// track's layers as they stood, so on gives back the same sound.
    @ObservationIgnored private var held: (mic: Bool, strength: Double, track: AudioTrack, layers: [AudioLayer])?

    /// Off holds the sound and plays the clip's own (the clean mic, no track). On gives back
    /// what was held, or the default track (`defaultPreset`'s) when nothing was.
    public func setOn(_ on: Bool) {
        guard on != isOn else { return }
        if on {
            guard let h = held else { return setTrack(Self.defaultPreset.track) }
            held = nil
            micLayer.enabled = h.mic
            micStrength = h.strength
            track = h.track
            layers = h.layers
            onChange?()
        } else {
            held = (micLayer.enabled, micStrength, track, layers)
            micLayer.enabled = false
            track = .off
            rebuild()
        }
    }

    /// Forgets the held sound, so the next on gives the default track as at launch.
    public func forgetHeld() {
        held = nil
    }

    /// True when the chain leaves audio untouched: the clean mic on Off, or every layer disabled.
    public var isPassthrough: Bool { spec.layers.isEmpty }

    /// A value snapshot of the enabled layers, safe to hand to another thread. The mic's spec
    /// carries its Strength below 100 and is left out at 0. Damage specs also carry the tape
    /// speed in mm/s and, for a clog that follows the picture, the picture clog's strength and
    /// seed. With Tape off only the mic is left.
    public var spec: AudioChainSpec {
        var specs: [AudioLayerSpec] = []
        for l in layers where l.enabled {
            guard l === micLayer else {
                if tapeIsOn { specs.append(l.spec) }
                continue
            }
            guard micStrength > Self.strengthRange.lowerBound else { continue }
            var s = l.spec
            if micStrength < Self.fullStrength { s.values["strength"] = .float(micStrength / Self.fullStrength) }
            specs.append(s)
        }
        guard tapeIsOn, track != .off else { return AudioChainSpec(layers: specs) }
        let speed = layers.first { $0.kind == .linearBand }?.value("speed")?.choiceValue.flatMap(TapeSpeed.init)
            ?? videoSpeed?() ?? .sp
        // The Hi-Fi dropout burst plays on the Hi-Fi track, with either mic.
        for l in damage where l.enabled && (l.kind != .hifiDropoutBurst || track == .hifi) {
            var s = l.spec
            s.values["tapeSpeed"] = .float(VHSGeometry.tapeSpeed(speed))
            if l.kind == .clogMuffle, l.value("follow")?.boolValue == true, let p = pictureClog?(), p.enabled {
                s.values["pictureStrength"] = .float(p.strength)
                s.values["pictureRate"] = .float(p.rate)
                s.values["pictureSeed"] = .float(p.seed)
            }
            specs.append(s)
        }
        return AudioChainSpec(layers: specs)
    }

    /// One line for the closed Audio section and the export sheet: "Camcorder mic, Hi-Fi
    /// track", "Clean mic, no track", "Camcorder mic at 40, Tape off".
    public var summary: String {
        var mic = "\(self.mic.label) mic"
        if self.mic == .camcorder, micStrength < Self.fullStrength { mic += " at \(Int(micStrength.rounded()))" }
        guard tapeIsOn else { return "\(mic), Tape off" }
        return track == .off ? "\(mic), no track" : "\(mic), \(track.label) track"
    }

    public func makeProcessor(sampleRate: Double, channels: Int) -> AudioChainProcessor {
        AudioChainProcessor(spec: spec, sampleRate: sampleRate, channels: channels)
    }
}

// MARK: - Specs

public struct AudioLayerSpec: Equatable, Sendable {
    public var kind: AudioLayerKind
    public var values: [String: ParameterValue]

    func float(_ id: String) -> Double {
        values[id]?.doubleValue ?? kind.defaultParameters.first { $0.id == id }?.value.doubleValue ?? 0
    }

    func choice(_ id: String) -> String? { values[id]?.choiceValue }

    /// A layer at its defaults, or at `preset`'s values.
    static func defaults(_ kind: AudioLayerKind, preset: AudioPreset? = nil) -> AudioLayerSpec {
        AudioLayerSpec(kind: kind, values: Dictionary(uniqueKeysWithValues:
            kind.parameters(for: preset).map { ($0.id, $0.value) }))
    }
}

public struct AudioChainSpec: Equatable, Sendable {
    public var layers: [AudioLayerSpec]
    public init(layers: [AudioLayerSpec]) { self.layers = layers }

    /// A preset's chain with every layer at its default (enabled state included).
    public static func defaults(_ preset: AudioPreset) -> AudioChainSpec {
        AudioChainSpec(layers: AudioLayerKind.kinds(for: preset).filter { $0.enabled(for: preset) }
            .map { AudioLayerSpec.defaults($0, preset: preset) })
    }
}

/// Seed for every audio noise source, so preview and export agree (the video's `vhsSeed`).
let audioSeed: UInt64 = 0x5241_4441_5544_494F

// MARK: - Blocks

/// One block of planar Float32 audio: a pointer per channel and a frame count.
public struct AudioBlock {
    public var channels: [UnsafeMutablePointer<Float>]
    public var frames: Int
    /// The clip time of the first frame in seconds, where the caller knows it (the tap and the
    /// export). No layer reads it.
    public var time: Double?

    public init(channels: [UnsafeMutablePointer<Float>], frames: Int, time: Double? = nil) {
        self.channels = channels
        self.frames = frames
        self.time = time
    }

    /// Runs `body` on `range` of planar arrays (copied out and back).
    public static func withPlanar(_ buffers: inout [[Float]], range: Range<Int>, _ body: (AudioBlock) -> Void) {
        let n = range.count
        let ptrs = buffers.map { ch -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
            for i in 0..<n { p[i] = ch[range.lowerBound + i] }
            return p
        }
        body(AudioBlock(channels: ptrs, frames: n))
        for c in buffers.indices {
            for i in 0..<n { buffers[c][range.lowerBound + i] = ptrs[c][i] }
            ptrs[c].deallocate()
        }
    }
}

// MARK: - Processors

/// One layer's DSP for every channel of a block. `dry` is the chain's input block (the
/// dropout layer crossfades to a linear rendering of it).
protocol AudioLayerProcessor: AnyObject {
    func process(_ block: AudioBlock, dry: AudioBlock)
}

/// Runs a spec's layers in order on blocks of audio. Not thread safe: one thread at a time
/// (the exporter's audio queue or the tap's render thread). An empty spec touches nothing.
public final class AudioChainProcessor: @unchecked Sendable {
    let processors: [AudioLayerProcessor]
    /// How many leading processors run before the dry copy: the camcorder mic, which records
    /// ahead of the tape, so a Hi-Fi dropout's linear track carries the motor too.
    let headCount: Int
    let needsDry: Bool
    let channelCount: Int
    var dryStorage: [UnsafeMutablePointer<Float>] = []
    var dryCapacity = 0

    public init(spec: AudioChainSpec, sampleRate: Double, channels: Int) {
        channelCount = max(1, channels)
        // Tape hiss plays back through the same head and amplifier as the program, so it is
        // band limited by the linear lowpass when the chain has one (the 42 dB S/N figure is
        // measured on that output).
        let hissLowpass = spec.layers.first { $0.kind == .linearBand }.map { $0.float("lowpass") }
        // The playback side of a matched noise reduction acts on that hiss only (the program
        // comes out of the pair flat), so the hiss stage takes its settings.
        let noiseReduction = spec.layers.first { $0.kind == .noiseReduction }
        processors = spec.layers.map {
            makeLayerProcessor($0, sampleRate: sampleRate, channels: max(1, channels), hissLowpass: hissLowpass,
                               noiseReduction: noiseReduction)
        }
        headCount = spec.layers.prefix { $0.kind == .camcorderMic }.count
        needsDry = spec.layers.contains { $0.kind == .dropout || $0.kind == .hifiDropoutBurst }
    }

    deinit { for p in dryStorage { p.deallocate() } }

    public var isPassthrough: Bool { processors.isEmpty }

    public func process(_ block: AudioBlock) {
        guard !processors.isEmpty, block.frames > 0 else { return }
        for p in processors.prefix(headCount) { p.process(block, dry: block) }
        var dry = block
        if needsDry {
            if dryCapacity < block.frames {
                for p in dryStorage { p.deallocate() }
                dryCapacity = max(block.frames, 4_096)
                dryStorage = block.channels.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: dryCapacity) }
            }
            for (c, src) in block.channels.enumerated() where c < dryStorage.count {
                dryStorage[c].update(from: src, count: block.frames)
            }
            dry = AudioBlock(channels: Array(dryStorage.prefix(block.channels.count)), frames: block.frames)
        }
        for p in processors.dropFirst(headCount) { p.process(block, dry: dry) }
    }
}

func makeLayerProcessor(_ s: AudioLayerSpec, sampleRate: Double, channels: Int,
                        hissLowpass: Double? = nil, noiseReduction: AudioLayerSpec? = nil) -> AudioLayerProcessor {
    let sr = sampleRate
    switch s.kind {
    case .camcorderMic:
        return CamcorderMic(spec: s, sampleRate: sr)
    case .mono:
        return MonoProcessor()
    case .saturation:
        return PerChannel(channels) { _ in
            let clip = SoftClip(drive: s.float("drive"), emphasisDB: s.float("emphasis"), sampleRate: sr)
            return { clip.process($0) }
        }
    case .linearBand, .hifiBand:
        let hp = s.float("highpass"), lp = s.float("lowpass")
        return PerChannel(channels) { _ in
            let fs = butterworth4Q.map { AudioBiquad(.highpass(hz: hp, q: $0), sampleRate: sr) }
                + butterworth4Q.map { AudioBiquad(.lowpass(hz: lp, q: $0), sampleRate: sr) }
            return { x in fs.reduce(x) { $1.process($0) } }
        }
    case .headBump:
        return PerChannel(channels) { _ in
            let f = AudioBiquad(.peaking(hz: s.float("frequency"), q: s.float("q"), gainDB: s.float("gain")), sampleRate: sr)
            return { f.process($0) }
        }
    case .dolbyMismatch, .azimuth:
        return PerChannel(channels) { _ in
            let f = AudioBiquad(.highShelf(hz: s.float("frequency"), gainDB: s.float("gain")), sampleRate: sr)
            return { f.process($0) }
        }
    case .mute:
        return MuteProcessor(spec: s, sampleRate: sr)
    case .wowFlutter:
        // One tape: every channel wobbles together (same seed).
        return PerChannel(channels) { _ in
            let d = ModulatedDelay(depthPercent: s.float("depth"), wowHz: s.float("wow"),
                                   flutterShare: s.float("flutter"), sampleRate: sr, seed: audioSeed ^ 0x57)
            return { d.process($0) }
        }
    case .hiss:
        // The linear track is mono, so its hiss is the same on both channels.
        let color = NoiseColor(rawValue: s.choice("color") ?? "") ?? .pink
        guard let lp = hissLowpass else {
            return PerChannel(channels) { _ in
                let n = NoiseSource(color: color, levelDB: s.float("level"), seed: audioSeed ^ 0x48)
                return { $0 + n.next() }
            }
        }
        let gain = bandLimitedNoiseGain(color: color, lowpass: lp, sampleRate: sr)
        guard let nr = noiseReduction else {
            return PerChannel(channels) { _ in
                let n = NoiseSource(color: color, levelDB: s.float("level"), seed: audioSeed ^ 0x48)
                let fs = butterworth4Q.map { AudioBiquad(.lowpass(hz: lp, q: $0), sampleRate: sr) }
                return { x in x + gain * fs.reduce(n.next()) { $1.process($0) } }
            }
        }
        return PerChannel(channels) { _ in
            let n = NoiseSource(color: color, levelDB: s.float("level"), seed: audioSeed ^ 0x48)
            let fs = butterworth4Q.map { AudioBiquad(.lowpass(hz: lp, q: $0), sampleRate: sr) }
            let decoder = SlidingHissCut(spec: nr, sampleRate: sr)
            return { x in x + decoder.process(gain * fs.reduce(n.next()) { $1.process($0) }, program: x) }
        }
    case .noiseReduction:
        // Its work is in the hiss stage above, the one signal the matched pair changes.
        return PassThrough()
    case .fmNoise:
        // Two FM carriers, independent noise per channel.
        return PerChannel(channels) { c in
            let n = NoiseSource(color: .white, levelDB: s.float("level"), seed: (audioSeed ^ 0x46) &+ UInt64(c) &* 0x9E37)
            return { $0 + n.next() }
        }
    case .whine:
        return PerChannel(channels) { _ in
            let w = LineWhine(levelDB: s.float("level"), sampleRate: sr)
            return { $0 + w.next() }
        }
    case .headSwitchClick:
        return PerChannel(channels) { _ in
            let k = FieldClick(levelDB: s.float("level"), sampleRate: sr)
            return { $0 + k.next() }
        }
    case .compressor:
        return PerChannel(channels) { _ in
            let c = Compander(mode: .compress, sampleRate: sr, attackMs: s.float("attack"), releaseMs: s.float("release"))
            return { c.process($0) }
        }
    case .expander:
        return PerChannel(channels) { _ in
            let c = Compander(mode: .expand, sampleRate: sr, attackMs: s.float("attack"), releaseMs: s.float("release"),
                              trackingErrorDB: s.float("tracking"))
            return { c.process($0) }
        }
    case .dropout:
        return DropoutProcessor(spec: s, sampleRate: sr, channels: channels)
    case .flutterBurst, .azimuthWander, .clogMuffle, .hifiDropoutBurst,
         .wowGlide, .wornStretch, .crackleBurst, .muteDrop:
        return makeDamageProcessor(s, sampleRate: sr, channels: channels)
    }
}

/// The gain that brings noise back to its set RMS after the 4th order lowpass at `lowpass`,
/// measured on a probe run (about 0.5 dB for pink at 10 kHz, more at 4 kHz or for white).
func bandLimitedNoiseGain(color: NoiseColor, lowpass: Double, sampleRate: Double) -> Float {
    let probe = NoiseSource(color: color, levelDB: 0, seed: 0x4C50)
    let fs = butterworth4Q.map { AudioBiquad(.lowpass(hz: lowpass, q: $0), sampleRate: sampleRate) }
    var sum = 0.0
    let n = 1 << 16
    for i in 0..<(n + 2_048) {
        let v = Double(fs.reduce(probe.next()) { $1.process($0) })
        if i >= 2_048 { sum += v * v }
    }
    let rms = (sum / Double(n)).squareRoot()
    return rms > 0 ? Float(1 / rms) : 1
}

/// A per-sample function per channel, each with its own state.
final class PerChannel: AudioLayerProcessor {
    let fns: [(Float) -> Float]

    init(_ channels: Int, make: (Int) -> (Float) -> Float) {
        fns = (0..<channels).map(make)
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        for (c, p) in block.channels.enumerated() {
            let fn = fns[min(c, fns.count - 1)]
            for i in 0..<block.frames { p[i] = fn(p[i]) }
        }
    }
}

/// A layer whose work another stage does (the noise reduction, run by the hiss stage).
final class PassThrough: AudioLayerProcessor {
    func process(_ block: AudioBlock, dry: AudioBlock) {}
}

/// The playback side of a matched B type noise reduction, on the tape hiss alone. The hiss
/// splits at the turnover into a first order low part and the rest, and the rest comes down
/// by the cut: 10 dB deep at 540 Hz is the low level curve of the Wikipedia figures in
/// `AudioLayerKind.noiseReduction`. The band slides with the program's own treble, as the
/// decoder's control does: full below -55 dBFS and none at -15 dBFS, the "Dolby Level" taken
/// as +3 VU over 0 VU at -18 dBFS, with the full cut 40 dB under it, straight in dB between
/// (INFERRED, the page gives only the two ends). The control follows a peak of the treble
/// with a 2 ms attack and a 60 ms release (INFERRED). Every step is per sample, so a block
/// size never changes the sound.
final class SlidingHissCut {
    let maxCut: Double
    let split: Float
    let attack: Double
    let release: Double
    static let fullBelow = -55.0
    static let noneAbove = -15.0
    var hissLow: Float = 0
    var programLow: Float = 0
    var envelope = 0.0

    init(spec s: AudioLayerSpec, sampleRate: Double) {
        maxCut = s.float("cut")
        split = Float(1 - exp(-2 * .pi * s.float("frequency") / sampleRate))
        attack = 1 - exp(-1 / (0.002 * sampleRate))
        release = 1 - exp(-1 / (0.060 * sampleRate))
    }

    func process(_ hiss: Float, program: Float) -> Float {
        programLow += split * (program - programLow)
        let treble = Double(abs(program - programLow))
        envelope += (treble > envelope ? attack : release) * (treble - envelope)
        let level = 20 * log10(max(envelope, 1e-9))
        let share = min(max((Self.noneAbove - level) / (Self.noneAbove - Self.fullBelow), 0), 1)
        let g = Float(pow(10, -maxCut * share / 20))
        hissLow += split * (hiss - hissLow)
        return hissLow + g * (hiss - hissLow)
    }
}

/// Sums the channels to mono and writes it to every channel.
final class MonoProcessor: AudioLayerProcessor {
    func process(_ block: AudioBlock, dry: AudioBlock) {
        let n = Float(block.channels.count)
        guard n > 1 else { return }
        for i in 0..<block.frames {
            var sum: Float = 0
            for p in block.channels { sum += p[i] }
            let m = sum / n
            for p in block.channels { p[i] = m }
        }
    }
}

/// Linear dropouts: at random moments (Poisson, `rate` per minute) the sound mutes for a
/// length drawn evenly between `shortest` and `longest` ms, every channel together (one tape),
/// with a 1 ms ramp at each edge so the mute itself does not click. Seeded like every other
/// audio noise, so preview and export drop out at the same moments.
final class MuteProcessor: AudioLayerProcessor {
    let startChance: Double
    let shortest: Double
    let longest: Double
    let ramp: Int
    var rng = SplitMix64(seed: audioSeed ^ 0x4D)
    var remaining = 0
    var length = 0

    init(spec s: AudioLayerSpec, sampleRate: Double) {
        startChance = s.float("rate") / 60 / sampleRate
        let a = s.float("shortest") / 1_000 * sampleRate, b = s.float("longest") / 1_000 * sampleRate
        shortest = min(a, b)
        longest = max(a, b)
        ramp = max(1, Int(0.001 * sampleRate))
    }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        for i in 0..<block.frames {
            if remaining == 0, rng.unit() < startChance {
                length = max(2 * ramp, Int(shortest + (longest - shortest) * rng.unit()))
                remaining = length
            }
            guard remaining > 0 else { continue }
            let done = length - remaining
            let gain = 1 - min(1, Float(min(done, remaining)) / Float(ramp))
            remaining -= 1
            for p in block.channels { p[i] *= gain }
        }
    }
}

/// Hi-Fi carrier loss: at random moments (Poisson, `rate` per minute) the deck mutes Hi-Fi and
/// plays the linear mono track for about `length` ms, with a click at the switch. The linear
/// rendering runs all the time on the dry input so its filters are warm when a dropout lands.
final class DropoutProcessor: AudioLayerProcessor {
    let linear: AudioChainProcessor
    let startChance: Double
    let meanLength: Double
    let fade: Int
    let clickAmplitude: Float
    let clickDecay: Float
    var rng = SplitMix64(seed: audioSeed ^ 0x44)
    /// Samples left in the current dropout (0 when none), and the dropout's total length.
    var remaining = 0
    var length = 0
    var click: Float = 0
    var scratch: [UnsafeMutablePointer<Float>] = []
    var capacity = 0

    init(spec s: AudioLayerSpec, sampleRate: Double, channels: Int) {
        linear = AudioChainProcessor(spec: .defaults(.linear), sampleRate: sampleRate, channels: channels)
        startChance = s.float("rate") / 60 / sampleRate
        meanLength = s.float("length") / 1_000 * sampleRate
        fade = max(1, Int(0.003 * sampleRate))
        clickAmplitude = Float(pow(10, s.float("click") / 20))
        clickDecay = Float(exp(-1 / (0.000_5 * sampleRate)))
    }

    deinit { for p in scratch { p.deallocate() } }

    func process(_ block: AudioBlock, dry: AudioBlock) {
        if capacity < block.frames || scratch.count < block.channels.count {
            for p in scratch { p.deallocate() }
            capacity = max(block.frames, 4_096)
            scratch = block.channels.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
        }
        for (c, src) in dry.channels.enumerated() where c < scratch.count {
            scratch[c].update(from: src, count: block.frames)
        }
        let lin = AudioBlock(channels: Array(scratch.prefix(block.channels.count)), frames: block.frames)
        linear.process(lin)

        for i in 0..<block.frames {
            if remaining == 0, rng.unit() < startChance {
                length = max(2 * fade, Int(meanLength * (0.5 + rng.unit())))
                remaining = length
                click = clickAmplitude
            }
            var mix: Float = 0
            if remaining > 0 {
                let done = length - remaining
                mix = min(1, Float(min(done, remaining)) / Float(fade))
                remaining -= 1
            }
            let k = click
            click *= clickDecay
            if mix == 0 && k < 1e-7 { continue }
            for (c, p) in block.channels.enumerated() {
                p[i] = p[i] * (1 - mix) + lin.channels[c][i] * mix + k
            }
        }
    }
}
