import Foundation

/// Copy and paste of a whole chain's settings as JSON: every video layer's switch and
/// parameters, then the audio preset and its layers. The viewer's right-click menu and the clip
/// panel both call these two functions. The pasteboard type is `typeIdentifier`, with the same
/// JSON as plain text beside it.
///
/// Framing's rotation is left out: it comes from each clip's track, so pasting one clip's
/// rotation onto another would turn it the wrong way.
public enum SettingsClipboard {
    /// The pasteboard type of the settings JSON.
    public static let typeIdentifier = "co.wonders.homevideo.settings"
    /// Marks the JSON as the app's settings, so a stray paste of other JSON is refused.
    public static let format = "homevideo-settings"
    public static let version = 1
    /// Parameters never copied, as `layer.parameter`.
    public static let skipped: Set<String> = ["framing.rotation"]

    public enum ApplyError: Error, Equatable, CustomStringConvertible {
        case notSettings(String)
        case unknownLayer(String)
        case unknownParameter(String)
        case badValue(String)

        public var description: String {
            switch self {
            case .notSettings(let why): return "Not Home Video settings:\(why)"
            case .unknownLayer(let id): return "Unknown layer '\(id)' in the settings"
            case .unknownParameter(let key): return "Unknown parameter '\(key)' in the settings"
            case .badValue(let key): return "Bad value for '\(key)' in the settings"
            }
        }
    }

    /// The JSON for the chain's current settings (pretty printed, keys sorted).
    @MainActor
    public static func encode(_ chain: SignalChain) -> String {
        let video = chain.settingsLayers.map { l in
            Payload.Layer(id: l.id, enabled: l.enabled,
                          parameters: l.parameters.filter { !skipped.contains("\(l.id).\($0.id)") }
                              .map { Payload.Parameter(id: $0.id, value: Payload.Value($0.value)) })
        }
        let audio = chain.audio.allLayers.map { l in
            Payload.Layer(id: l.id, enabled: l.enabled,
                          parameters: l.parameters.map { Payload.Parameter(id: $0.id, value: Payload.Value($0.value)) })
        }
        let p = Payload(format: format, version: version, layers: video,
                        audio: Payload.Audio(preset: chain.audio.preset.rawValue, layers: audio,
                                             wear: chain.audio.wear > 0 ? chain.audio.wear : nil,
                                             strength: chain.audio.micStrength < AudioChain.fullStrength
                                                 ? chain.audio.micStrength : nil))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Encoding plain strings, numbers and bools cannot fail.
        return (try? enc.encode(p)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Sets the chain from `json` through each layer's `setParameter`. Everything is checked
    /// first (format, every layer and parameter id, every value's type and choice), so a bad
    /// string throws and leaves the chain as it was. Layers the JSON does not name keep their
    /// values.
    @MainActor
    public static func apply(_ json: String, to chain: SignalChain) throws {
        let p: Payload
        do {
            p = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        } catch {
            throw ApplyError.notSettings("not settings JSON")
        }
        guard p.format == format else { throw ApplyError.notSettings("format '\(p.format)'") }
        guard p.version <= version else { throw ApplyError.notSettings("version \(p.version) is newer") }
        guard let preset = AudioPreset(rawValue: p.audio.preset) else {
            throw ApplyError.badValue("audio.preset")
        }
        if let w = p.audio.wear, !(w.isFinite && AudioWear.range.contains(w)) {
            throw ApplyError.badValue("audio.wear")
        }
        if let s = p.audio.strength, !(s.isFinite && AudioChain.strengthRange.contains(s)) {
            throw ApplyError.badValue("audio.strength")
        }

        // Check the video layers against the chain and the audio layers against the layers the
        // preset builds, without touching either.
        var video: [(any Layer, Payload.Layer, [(String, ParameterValue)])] = []
        for pl in p.layers {
            guard let layer = chain.settingsLayers.first(where: { $0.id == pl.id }) else {
                throw ApplyError.unknownLayer(pl.id)
            }
            video.append((layer, pl, try values(pl, known: layer.parameters)))
        }
        let audioKinds = AudioLayerKind.kinds(for: preset)
        var audio: [(Int, Payload.Layer, [(String, ParameterValue)])] = []
        var damage: [(AudioLayer, Payload.Layer, [(String, ParameterValue)])] = []
        for pl in p.audio.layers {
            // The Damage layers are kept across presets, so they are set on the chain's own.
            if let d = chain.audio.damage.first(where: { $0.id == pl.id }) {
                damage.append((d, pl, try values(pl, known: d.parameters)))
                continue
            }
            guard let i = audioKinds.firstIndex(where: { $0.id == pl.id }) else {
                throw ApplyError.unknownLayer(pl.id)
            }
            audio.append((i, pl, try values(pl, known: AudioLayer(kind: audioKinds[i]).parameters)))
        }

        for (layer, pl, vals) in video {
            if !layer.isRequired { layer.enabled = pl.enabled }
            for (id, v) in vals { layer.setParameter(id, to: v) }
        }
        // Setting the preset rebuilds the audio layers at its defaults and the wear, even when it
        // is unchanged, then the pasted values land as they were copied.
        chain.audio.restoreWear(p.audio.wear ?? 0)
        chain.audio.preset = preset
        for (i, pl, vals) in audio {
            let layer = chain.audio.layers[i]
            layer.enabled = pl.enabled
            for (id, v) in vals { layer.setParameter(id, to: v) }
        }
        for (layer, pl, vals) in damage {
            layer.enabled = pl.enabled
            for (id, v) in vals { layer.setParameter(id, to: v) }
        }
        chain.audio.setMicStrength(p.audio.strength ?? AudioChain.fullStrength)
    }

    /// The layer's values typed like the target's parameters, or a throw on any mismatch.
    private static func values(_ pl: Payload.Layer, known: [LayerParameter]) throws -> [(String, ParameterValue)] {
        try pl.parameters.compactMap { pp in
            var pp = pp
            // Older settings name the crease's Average gap `period`.
            if pl.id == "damage-crease", pp.id == "period", case .number(let s) = pp.value {
                pp = Payload.Parameter(id: "rate", value: .number(CreaseLayer.rate(fromPeriod: s)))
            }
            let key = "\(pl.id).\(pp.id)"
            if skipped.contains(key) { return nil }
            guard let k = known.first(where: { $0.id == pp.id }) else { throw ApplyError.unknownParameter(key) }
            switch (k.value, pp.value) {
            case (.float, .number(let d)) where d.isFinite:
                return (pp.id, .float(d))
            case (.bool, .bool(let b)):
                return (pp.id, .bool(b))
            case (.choice, .string(let s)) where k.options.contains(where: { $0.value == s }):
                return (pp.id, .choice(s))
            default:
                throw ApplyError.badValue(key)
            }
        }
    }

    struct Payload: Codable {
        var format: String
        var version: Int
        var layers: [Layer]
        var audio: Audio

        struct Audio: Codable {
            var preset: String
            var layers: [Layer]
            /// The Audio wear, left out at 0 so older settings read the same.
            var wear: Double?
            /// The mic Strength, left out at 100 so older settings read the same.
            var strength: Double?
        }

        struct Layer: Codable {
            var id: String
            var enabled: Bool
            var parameters: [Parameter]
        }

        struct Parameter: Codable {
            var id: String
            var value: Value
        }

        /// A JSON number, bool or string, as a parameter's float, toggle or choice.
        enum Value: Codable {
            case number(Double)
            case bool(Bool)
            case string(String)

            init(_ v: ParameterValue) {
                switch v {
                case .float(let d): self = .number(d)
                case .bool(let b): self = .bool(b)
                case .choice(let s): self = .string(s)
                }
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let b = try? c.decode(Bool.self) {
                    self = .bool(b)
                } else if let d = try? c.decode(Double.self) {
                    self = .number(d)
                } else {
                    self = .string(try c.decode(String.self))
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .number(let d): try c.encode(d)
                case .bool(let b): try c.encode(b)
                case .string(let s): try c.encode(s)
                }
            }
        }
    }
}
