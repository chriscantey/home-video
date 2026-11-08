import Foundation
import Observation

// User presets: the whole chain saved under a name, as a file a person can keep, send and
// import. A preset file holds
// every effect layer's switch and parameter values and the audio chain's preset and values,
// written from the layers' own parameter lists. Framing is not part of a preset: it belongs to
// the clip, as it does for the built-in Looks. Loading turns the file into a Look whose
// overrides are every saved value, so it applies and reads back exactly as a built-in Look
// does (`Presets.setLook`, `Presets.look`).
//
// The file, `<name>.homevideopreset` in `~/Library/Application Support/Home Video/Presets/`, is JSON:
//
//   { "version": 1, "name": "Warm Rental", "audio": "linear",
//     "layers": [ { "id": "luma-bandwidth", "enabled": true,
//                   "parameters": [ { "id": "speed", "value": "sp" }, { "id": "cut", "value": 2.4 } ] }, ... ],
//     "audioLayers": [ { "id": "audio-hiss", "enabled": true, "parameters": [ ... ] }, ... ] }
//
// A value is a JSON number for a slider, true or false for a switch, a string for a choice.

/// One saved preset: its name, its file and the Look it builds.
public struct UserPreset: Identifiable, Equatable, Sendable {
    public var name: String
    public var url: URL
    public var look: Look
    public var id: String { look.id }
}

public enum UserPresetError: Error, Equatable, CustomStringConvertible {
    case badName(String)
    case malformed(String, reason: String)
    case noChain

    public var description: String {
        switch self {
        case .badName(let n):
            return "'\(n)' is not a usable preset name (not empty, no slash or colon, not starting with a dot)"
        case .malformed(let file, let reason): return "\(file) is not a Home Video preset:\(reason)"
        case .noChain: return "the chain has no VHS layers to save"
        }
    }
}

@MainActor
@Observable
public final class UserPresets {
    public static let fileExtension = "homevideopreset"
    public nonisolated static let formatVersion = 1
    /// The prefix that keeps a user preset's Look id apart from the built-in ids.
    public nonisolated static let idPrefix = "user:"

    /// `~/Library/Application Support/Home Video/Presets`.
    public nonisolated static var defaultFolder: URL {
        AppFolders.support.appendingPathComponent("Presets", isDirectory: true)
    }

    public let folder: URL
    /// The presets in the folder, sorted by name, as of the last `refresh`.
    public private(set) var presets: [UserPreset] = []

    public init(folder: URL = UserPresets.defaultFolder) {
        self.folder = folder
        refresh()
    }

    /// Rereads the folder and hands the presets to `Presets.look` for read-back.
    public func refresh() {
        presets = list()
        Looks.user = presets.map(\.look)
    }

    /// The presets in the folder, sorted by name. Malformed files are skipped.
    public func list() -> [UserPreset] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == Self.fileExtension }
            .compactMap { try? Self.read($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func url(forName name: String) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
    }

    /// Writes the chain's current values as `<name>.homevideopreset`, replacing a preset of the
    /// same name.
    @discardableResult
    public func save(name: String, chain: SignalChain) throws -> UserPreset {
        let name = try Self.checkedName(name)
        guard let vhs = chain.vhs else { throw UserPresetError.noChain }
        let data = try Self.encode(name: name, vhs: vhs, audio: chain.audio)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = url(forName: name)
        try data.write(to: url, options: .atomic)
        refresh()
        return try Self.read(url)
    }

    /// Writes the chain's current values as a preset file at `destination`, outside the
    /// folder (File > Export Preset when the chain is a built-in Look or Custom).
    public func write(name: String, chain: SignalChain, to destination: URL) throws {
        let name = try Self.checkedName(name)
        guard let vhs = chain.vhs else { throw UserPresetError.noChain }
        try Self.encode(name: name, vhs: vhs, audio: chain.audio).write(to: destination, options: .atomic)
    }

    /// Applies a preset file to the chain through the layers' own `setParameter`. A malformed
    /// file throws before anything changes.
    public func load(_ url: URL, into chain: SignalChain) throws {
        try Self.apply(url, to: chain)
    }

    /// Copies a preset out of the folder to `destination`, replacing a file there.
    public func export(_ url: URL, to destination: URL) throws {
        _ = try Self.read(url)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: url, to: destination)
    }

    /// Copies a preset file into the folder under the name it carries, replacing a preset of
    /// that name. A malformed file throws and nothing is copied.
    @discardableResult
    public func `import`(from source: URL) throws -> UserPreset {
        let preset = try Self.read(source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = url(forName: preset.name)
        if dest.standardizedFileURL != source.standardizedFileURL {
            let data = try Data(contentsOf: source)
            try data.write(to: dest, options: .atomic)
        }
        refresh()
        return try Self.read(dest)
    }

    /// Removes a preset's file from the folder.
    public func delete(_ preset: UserPreset) throws {
        try FileManager.default.removeItem(at: preset.url)
        refresh()
    }

    /// Renames a preset: its file becomes `<name>.homevideopreset` and the name it carries
    /// changes with it, every other key kept as it was. A name another preset or file in the
    /// folder already has gets " 2" (then " 3" and on). Renaming to its own name changes
    /// nothing. When the folder or file cannot be written it throws and nothing changes.
    @discardableResult
    public func rename(_ preset: UserPreset, to newName: String) throws -> UserPreset {
        let wanted = try Self.checkedName(newName)
        if wanted == preset.name { return preset }
        let own = preset.name.lowercased()
        let others = Set(list().filter { $0.url.standardizedFileURL != preset.url.standardizedFileURL }
            .map { $0.name.lowercased() })
        let fm = FileManager.default
        let name = Self.freeName(wanted) { candidate in
            others.contains(candidate.lowercased())
                || (candidate.lowercased() != own && fm.fileExists(atPath: url(forName: candidate).path))
        }

        guard var root = (try JSONSerialization.jsonObject(with: Data(contentsOf: preset.url))) as? [String: Any] else {
            throw UserPresetError.malformed(preset.url.lastPathComponent, reason: "not a JSON object")
        }
        root["name"] = name
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])

        // Move first, so a folder that cannot be written refuses before anything changes. A
        // change of case only goes through a temporary name, since the folder is usually case
        // insensitive and sees the two names as one file.
        let dest = url(forName: name)
        if name.lowercased() == own {
            let temp = folder.appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: preset.url, to: temp)
            do { try fm.moveItem(at: temp, to: dest) } catch {
                try? fm.moveItem(at: temp, to: preset.url)
                throw error
            }
        } else {
            try fm.moveItem(at: preset.url, to: dest)
        }
        do { try data.write(to: dest, options: .atomic) } catch {
            try? fm.moveItem(at: dest, to: preset.url)
            refresh()
            throw error
        }
        refresh()
        return try Self.read(dest)
    }

    /// `name`, or `name 2`, `name 3` and on, the first that `isTaken` refuses.
    static func freeName(_ name: String, isTaken: (String) -> Bool) -> String {
        var candidate = name
        var n = 2
        while isTaken(candidate) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }

    /// The Look picker's order: the built-in Looks in their menu sections
    /// (`Looks.grouped`), then, under the Custom header, the user's presets sorted by name.
    /// `user` is empty when there are none, and the picker shows no Custom header then.
    public static func pickerOrder(user: [UserPreset]) -> (builtIn: [(category: LookCategory, looks: [Look])], user: [UserPreset]) {
        (Looks.grouped, user.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// The built-in Look a preset was built on, as its values tell it: the one that differs
    /// from it in the fewest values (every layer's switch and parameters, the audio preset and
    /// the audio layers), Fresh SP on a tie. Deleting the shown preset falls back to it.
    public static func baseLook(of preset: UserPreset) -> Look {
        let mine = fingerprint(Looks.reference(preset.look))
        let fresh = Looks.look(id: "clean-sp")!
        var best = fresh
        var bestDistance = distance(mine, fingerprint(Looks.reference(fresh)))
        for look in Looks.all where look.id != fresh.id {
            let d = distance(mine, fingerprint(Looks.reference(look)))
            if d < bestDistance {
                best = look
                bestDistance = d
            }
        }
        return best
    }

    static func fingerprint(_ chain: (vhs: VHSLayers, audio: AudioChain)) -> [String: String] {
        var f: [String: String] = ["audio": chain.audio.preset.rawValue, "audio.strength": "\(chain.audio.micStrength)"]
        for l in chain.vhs.all {
            f["\(l.id).enabled"] = Looks.userSwitch(l).map(String.init) ?? "-"
            for p in l.parameters { f["\(l.id).\(p.id)"] = "\(p.value)" }
        }
        for l in chain.audio.layers {
            f["\(l.id).enabled"] = String(l.enabled)
            for p in l.parameters { f["\(l.id).\(p.id)"] = "\(p.value)" }
        }
        return f
    }

    static func distance(_ a: [String: String], _ b: [String: String]) -> Int {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.count
    }

    // MARK: - The file

    static func checkedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw UserPresetError.badName(raw)
        }
        return name
    }

    static func json(_ v: ParameterValue) -> Any {
        switch v {
        case .float(let d): return d
        case .bool(let b): return b
        case .choice(let s): return s
        }
    }

    static func layerRecord(id: String, enabled: Bool, parameters: [LayerParameter]) -> [String: Any] {
        ["id": id, "enabled": enabled,
         "parameters": parameters.map { ["id": $0.id, "value": json($0.value)] as [String: Any] }]
    }

    static func encode(name: String, vhs: VHSLayers, audio: AudioChain) throws -> Data {
        let layers = vhs.savedLayers.map { l in
            layerRecord(id: l.id, enabled: Looks.userSwitch(l) ?? l.enabled, parameters: l.parameters)
        }
        let audioLayers = audio.allLayers.map { layerRecord(id: $0.id, enabled: $0.enabled, parameters: $0.parameters) }
        var root: [String: Any] = ["version": formatVersion, "name": name, "audio": audio.preset.rawValue,
                                   "layers": layers, "audioLayers": audioLayers]
        // The Audio wear, only when moved, so a preset at 0 reads as it always did.
        if audio.wear > 0 { root[AudioWear.id] = audio.wear }
        // The mic Strength, only below 100, for the same reason.
        if audio.micStrength < AudioChain.fullStrength { root[AudioChain.strengthID] = audio.micStrength }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Reads and checks a preset file against fresh layers: every layer and parameter id must
    /// exist and every value must have its parameter's type (a choice one of its options, a
    /// number finite). Throws `malformed` otherwise.
    public static func read(_ url: URL) throws -> UserPreset {
        let file = url.lastPathComponent
        func bad(_ reason: String) -> UserPresetError { .malformed(file, reason: reason) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw bad("cannot read the file") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw bad("not a JSON object")
        }
        guard let version = root["version"] as? Int, version == formatVersion else {
            throw bad("version is not \(formatVersion)")
        }
        guard let rawName = root["name"] as? String, let name = try? checkedName(rawName) else {
            throw bad("no usable name")
        }
        let (audioPreset, overrides) = try settings(in: root, lenient: false, bad: bad)
        let look = Look(id: idPrefix + name, name: name, blurb: "Your preset, saved as \(file).",
                        selection: PresetSelection(audio: audioPreset), overrides: overrides)
        return UserPreset(name: name, url: url, look: look)
    }

    /// The audio preset and the layer values a file's `audio`, `layers` and `audioLayers` hold,
    /// checked against fresh layers. Strict (a preset): every layer and parameter id must exist
    /// and the audio preset and layers list must be there. Lenient (a sidecar, which outlives
    /// versions): a layer or parameter id the app does not know is skipped, and a missing audio
    /// preset or list takes the defaults. Either way a value of the wrong type throws.
    static func settings(in root: [String: Any], lenient: Bool,
                         bad: (String) -> UserPresetError) throws -> (AudioPreset, [Look.Override]) {
        let audioPreset: AudioPreset
        if let audioRaw = root["audio"] as? String, let p = AudioPreset(rawValue: audioRaw) {
            audioPreset = p
        } else if lenient && root["audio"] == nil {
            // A sidecar without the audio key was saved under an earlier Hi-Fi default, so it
            // reads as Hi-Fi, not the current Linear default.
            audioPreset = .hifi
        } else {
            throw bad("no audio preset")
        }
        let layers: [[String: Any]]
        if let l = root["layers"] as? [[String: Any]] {
            layers = l
        } else if lenient && root["layers"] == nil {
            layers = []
        } else {
            throw bad("no layers list")
        }
        let audioLayers = root["audioLayers"] as? [[String: Any]] ?? []

        let freshVHS = VHSLayers()
        let freshAudio = AudioChain(preset: audioPreset)
        var overrides: [Look.Override] = []
        func collect(_ records: [[String: Any]], known: [String: [LayerParameter]], skipSwitch: Set<String>) throws {
            var seen: Set<String> = []
            for r in records {
                guard let id = r["id"] as? String else { throw bad("a layer has no id") }
                guard let params = known[id] else {
                    if lenient { continue }
                    throw bad("unknown layer \(id)")
                }
                guard seen.insert(id).inserted else { throw bad("layer \(id) twice") }
                if let enabled = boolValue(r["enabled"]) {
                    if !skipSwitch.contains(id) { overrides.append(.init(id, "enabled", .bool(enabled))) }
                } else if !(lenient && r["enabled"] == nil) {
                    throw bad("layer \(id) has no enabled switch")
                }
                let values: [[String: Any]]
                if let v = r["parameters"] as? [[String: Any]] {
                    values = v
                } else if lenient && r["parameters"] == nil {
                    values = []
                } else {
                    throw bad("layer \(id) has no parameters list")
                }
                for var v in values {
                    // Older files name the crease's Average gap `period`.
                    if id == "damage-crease", v["id"] as? String == "period", let s = v["value"] as? Double {
                        v = ["id": "rate", "value": CreaseLayer.rate(fromPeriod: s)]
                    }
                    // Older files carry Film's output choice, which the stage switches hold:
                    // it is handed on as it was, and the Look's reference folds it
                    // (`VHSLayers.foldLegacyFilmOutput`).
                    if id == "film", v["id"] as? String == "output", let s = v["value"] as? String,
                       FilmOutput(rawValue: s) != nil {
                        overrides.append(.init(id, "output", .choice(s)))
                        continue
                    }
                    // Some older files carry the camcorder's zoom sound, which the app no longer has.
                    if id == AudioLayerKind.camcorderMic.id, let pid = v["id"] as? String,
                       CamcorderMic.retiredParameters.contains(pid) {
                        continue
                    }
                    guard let pid = v["id"] as? String, let p = params.first(where: { $0.id == pid }) else {
                        if lenient && v["id"] is String { continue }
                        throw bad("layer \(id) has no parameter \(v["id"] ?? "")")
                    }
                    guard let value = parameterValue(v["value"], like: p) else {
                        throw bad("\(id).\(pid) has a value of the wrong type")
                    }
                    overrides.append(.init(id, pid, value))
                }
            }
        }
        // The capture card's switch follows the output card, and the Display size's follows the
        // CRT layers, so neither is applied.
        try collect(layers, known: Dictionary(uniqueKeysWithValues: freshVHS.saved.map { ($0.id, $0.parameters) }),
                    skipSwitch: ["capture", "crt-display"])
        // The Audio wear goes before the audio layers: it moves the preset's values, then the
        // saved values land exactly as saved.
        if let w = root[AudioWear.id] {
            guard let d = (w as? NSNumber)?.doubleValue, d.isFinite else { throw bad("\(AudioWear.id) is not a number") }
            overrides.append(.init(AudioWear.id, "value", .float(min(max(d, AudioWear.range.lowerBound),
                                                                      AudioWear.range.upperBound))))
        }
        if let s = root[AudioChain.strengthID] {
            guard let d = (s as? NSNumber)?.doubleValue, d.isFinite else {
                throw bad("\(AudioChain.strengthID) is not a number")
            }
            let r = AudioChain.strengthRange
            overrides.append(.init(AudioChain.strengthID, "value", .float(min(max(d, r.lowerBound), r.upperBound))))
        }
        try collect(audioLayers, known: Dictionary(uniqueKeysWithValues: freshAudio.allLayers.map { ($0.id, $0.parameters) }),
                    skipSwitch: [])
        return (audioPreset, overrides)
    }

    /// Applies a preset file to the chain (the path `homevideo-render --preset-file` takes too).
    public static func apply(_ url: URL, to chain: SignalChain) throws {
        let preset = try read(url)
        guard let vhs = chain.vhs else { throw UserPresetError.noChain }
        Presets(vhs: vhs, audio: chain.audio).setLook(preset.look)
    }

    /// A JSON true or false (not a number that bridges to one).
    static func boolValue(_ any: Any?) -> Bool? {
        guard let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func parameterValue(_ any: Any?, like p: LayerParameter) -> ParameterValue? {
        switch p.value {
        case .float:
            guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return .float(n.doubleValue)
        case .bool:
            return boolValue(any).map(ParameterValue.bool)
        case .choice:
            guard let s = any as? String, p.options.isEmpty || p.options.contains(where: { $0.value == s }) else { return nil }
            return .choice(s)
        }
    }
}
