import Foundation
import Observation

// Stage presets: a small preset menu for each stage beside the global Look. The Look stays the
// global preset: it saves and exports everything. A stage preset holds one stage's values only,
// and choosing one changes that stage and nothing else.
//
// The stages, in the path's order, and the layers each owns:
//   Film      `vhs.film.all` (the master switch, format, stock, light and the rest)
//   Telecine  `vhs.telecine.all` (the master switch with route and quality, then its layers)
//   Tape      `vhs.all` (the camera, the VHS chain from the output card to the capture, the
//             picture Damage layers) and the Tape switch
//   Display   `vhs.crt.all` (the Display size and the six CRT layers) and `vhs.recapture.all`
//   Audio     the mic and its Strength, the track and its layers, the wear, the audio Damage
//
// A user's stage preset is `<name>.homevideostage` in
// `~/Library/Application Support/Home Video/Stage Presets/<Stage>/`, JSON that names its stage
// and carries only that stage's values:
//
//   { "format": "homevideo-stage-preset", "version": 1, "stage": "display", "name": "Close-up",
//     "layers": [ { "id": "crt-mask", "enabled": true,
//                   "parameters": [ { "id": "kind", "value": "shadow-mask" }, ... ] }, ... ] }
//
// An Audio file adds "track" (hifi, linear, worn, ep, off), "audioWear" and "audioMicStrength".
// A layer whose switch follows another (the capture card, the Display size) has no "enabled".
// Reading a file applies it to a fresh stage and takes the stage back, so a layer the file
// leaves out reads at its default and every value is clamped as the sliders clamp it.

/// One stage of the path, as the sidebar names it.
public enum Stage: String, CaseIterable, Sendable, Identifiable {
    case film, telecine, tape, display, audio

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .film: return "Film"
        case .telecine: return "Telecine"
        case .tape: return "Tape"
        case .display: return "Display"
        case .audio: return "Audio"
        }
    }

    /// The picture layers the stage owns, in the sidebar's order. Audio owns none.
    @MainActor public func layers(in vhs: VHSLayers) -> [any Layer] {
        switch self {
        case .film: return vhs.film.all
        case .telecine: return vhs.telecine.all
        case .tape: return vhs.all + [vhs.tape]
        case .display: return vhs.crt.all + vhs.recapture.all
        case .audio: return []
        }
    }

    /// A layer's switch as a stage preset keeps it: the output card's own switch (it is also on
    /// whenever a later layer needs it), nil for the capture card and the Display size, whose
    /// switches follow other layers.
    @MainActor static func storedSwitch(_ layer: any Layer) -> Bool? {
        if let card = layer as? OutputCardLayer { return card.userEnabled }
        if layer is CaptureLayer || layer is CRTDisplayLayer { return nil }
        return layer.enabled
    }

    @MainActor static func setSwitch(_ layer: any Layer, _ on: Bool) {
        if let card = layer as? OutputCardLayer {
            card.userEnabled = on
        } else if !(layer is CaptureLayer || layer is CRTDisplayLayer) {
            layer.enabled = on
        }
    }

    /// The stage's values on `vhs` and `audio` as they stand.
    @MainActor public func snapshot(vhs: VHSLayers, audio: AudioChain) -> StageSnapshot {
        guard self == .audio else {
            return StageSnapshot(layers: layers(in: vhs).map(StageSnapshot.Record.init))
        }
        return StageSnapshot(layers: audio.allLayers.map(StageSnapshot.Record.init),
                             track: audio.track, wear: audio.wear, strength: audio.micStrength)
    }

    /// Sets the stage on `vhs` and `audio` to `snapshot`, through the layers' own switches and
    /// `setParameter`, in the stage's order (a Telecine tier or a film stock sets its
    /// neighbors first, then their saved values land as saved). Nothing outside the stage is
    /// touched.
    @MainActor public func apply(_ snapshot: StageSnapshot, vhs: VHSLayers, audio: AudioChain) {
        guard self == .audio else {
            let mine = layers(in: vhs)
            for r in snapshot.layers {
                guard let layer = mine.first(where: { $0.id == r.id }) else { continue }
                if let on = r.enabled { Stage.setSwitch(layer, on) }
                for v in r.values { layer.setParameter(v.id, to: v.value) }
            }
            return
        }
        // The track's layers come back at the track's own values, then the saved ones land.
        audio.restoreWear(0)
        audio.setTrack(snapshot.track ?? .hifi)
        for r in snapshot.layers {
            guard let layer = audio.allLayers.first(where: { $0.id == r.id }) else { continue }
            if let on = r.enabled { layer.enabled = on }
            for v in r.values { layer.setParameter(v.id, to: v.value) }
        }
        audio.restoreWear(snapshot.wear)
        audio.setMicStrength(snapshot.strength)
    }
}

/// One stage's values: each layer's switch and parameters, and for Audio the track, the wear
/// and the mic Strength.
public struct StageSnapshot: Equatable, Sendable {
    public struct Value: Equatable, Sendable {
        public var id: String
        public var value: ParameterValue
    }

    public struct Record: Equatable, Sendable {
        public var id: String
        /// Nil for a layer whose switch follows another.
        public var enabled: Bool?
        public var values: [Value]

        @MainActor init(_ layer: any Layer) {
            id = layer.id
            enabled = Stage.storedSwitch(layer)
            values = layer.parameters.map { Value(id: $0.id, value: $0.value) }
        }

        @MainActor init(_ layer: AudioLayer) {
            id = layer.id
            enabled = layer.enabled
            values = layer.parameters.map { Value(id: $0.id, value: $0.value) }
        }

        init(id: String, enabled: Bool?, values: [Value]) {
            self.id = id
            self.enabled = enabled
            self.values = values
        }
    }

    public var layers: [Record]
    public var track: AudioTrack? = nil
    public var wear: Double = 0
    public var strength: Double = AudioChain.fullStrength

    /// Alike in every switch and value, numbers within the Look read-back's tolerance.
    public func matches(_ other: StageSnapshot) -> Bool {
        guard track == other.track, Presets.same(wear, other.wear), Presets.same(strength, other.strength),
              layers.count == other.layers.count else { return false }
        return zip(layers, other.layers).allSatisfy { a, b in
            a.id == b.id && a.enabled == b.enabled && a.values.count == b.values.count
                && zip(a.values, b.values).allSatisfy { $0.id == $1.id && Looks.same($0.value, $1.value) }
        }
    }
}

/// One stage preset: a built-in (no file) or the user's own.
public struct StagePreset: Identifiable, Equatable, Sendable {
    public var stage: Stage
    public var name: String
    public var snapshot: StageSnapshot
    /// The file in the stage's folder, nil for a built-in.
    public var url: URL?

    public var isBuiltIn: Bool { url == nil }
    public var id: String { (isBuiltIn ? "builtin:" : "user:") + stage.rawValue + ":" + name }
}

public enum StagePresetError: Error, Equatable, CustomStringConvertible {
    case badName(String)
    case malformed(String, reason: String)
    case wrongStage(String, found: Stage, wanted: Stage)
    case builtIn(String)
    case noChain

    public var description: String {
        switch self {
        case .badName(let n):
            return "'\(n)' is not a usable preset name (not empty, no slash or colon, not starting with a dot)"
        case .malformed(let file, let reason): return "\(file) is not a Home Video stage preset: \(reason)"
        case .wrongStage(let file, let found, let wanted):
            return "\(file) is a \(found.title) preset, not a \(wanted.title) preset"
        case .builtIn(let n): return "\(n) is built in and cannot be changed"
        case .noChain: return "the chain has no stages to save"
        }
    }
}

// MARK: - The built-ins

extension StagePresets {
    /// Each stage's built-ins, drawn from what the app already has (the Looks, the stocks, the
    /// Telecine tiers, the audio presets), never new values of their own. A built-in that
    /// would equal an earlier one in every value is left out.
    @MainActor public static func builtIns(_ stage: Stage) -> [StagePreset] {
        if let cached = builtInCache[stage] { return cached }
        var list: [StagePreset] = []
        func add(_ name: String, _ snapshot: StageSnapshot) {
            guard !list.contains(where: { $0.snapshot.matches(snapshot) }) else { return }
            list.append(StagePreset(stage: stage, name: name, snapshot: snapshot, url: nil))
        }
        // The stage on fresh layers with `overrides` on top, as a Look sets them.
        func fresh(_ overrides: [Look.Override] = []) -> StageSnapshot {
            let vhs = VHSLayers(), audio = AudioChain()
            for o in overrides { Looks.apply(o, vhs: vhs, audio: audio) }
            return stage.snapshot(vhs: vhs, audio: audio)
        }
        func look(_ id: String) -> StageSnapshot {
            let ref = Looks.reference(Looks.look(id: id)!)
            return stage.snapshot(vhs: ref.vhs, audio: ref.audio)
        }
        func on(_ layer: String) -> Look.Override { .init(layer, "enabled", .bool(true)) }

        switch stage {
        case .film:
            add("Off", fresh())
            add("Super 8 Kodachrome", look("super8-kodachrome"))
            add("16mm Faded", look("sixteen-ektachrome-faded"))
            // The film Looks, each under its Look's name, in the Look menu's order. A twin of
            // one above is left out.
            for l in Looks.grouped.flatMap(\.looks) where l.category == .film {
                add(l.name, look(l.id))
            }
            // The Telecine Looks' film under their names too, so the Film room never reads
            // Custom on a built-in Look. A twin of one above is left out.
            for l in Looks.grouped.flatMap(\.looks) where l.category == .telecine {
                add(l.name, look(l.id))
            }
            for stock in FilmStock.allCases {
                add(stock.label, fresh([on("film"), .init("film-stock", "stock", .choice(stock.rawValue))]))
            }
        case .telecine:
            add("Off", fresh())
            let tiers: [(String, TelecineRoute, TelecineQuality)] =
                [("Mall transfer", .home, .mall), ("Mid-grade", .home, .mid), ("Pro telecine", .pro, .pro)]
            for (name, route, quality) in tiers {
                add(name, fresh([on("telecine"), .init("telecine", "route", .choice(route.rawValue)),
                                 .init("telecine", "quality", .choice(quality.rawValue))]))
            }
            // The Telecine Looks' transfers, under their names: each is a tier above at its own
            // values, so the no-twins rule leaves them out until one moves a slider.
            for l in Looks.grouped.flatMap(\.looks) where l.category == .telecine { add(l.name, look(l.id)) }
        case .tape:
            // Every built-in Look's tape in the Look menu's order, then the Tape switched off.
            for l in Looks.all {
                let tape = look(l.id)
                if tape.layers.contains(where: { $0.id == "tape" && $0.enabled == true }) { add(l.name, tape) }
            }
            add("Off", fresh([.init("tape", "enabled", .bool(false))]))
        case .display:
            let tube = ["crt-transfer", "crt-beam", "crt-mask", "crt-glow", "crt-geometry", "crt-glass"].map(on)
            add("Off", fresh())
            add("Tube TV", fresh(tube))
            // The phosphor triads as seen up close: dots, the widest triad
            // and the mask at full strength, each at the end of its own slider.
            add("Close-up Mask", fresh(tube + [.init("crt-mask", "kind", .choice(CRTMaskLayer.Kind.shadowMask.rawValue)),
                                               .init("crt-mask", "triad", .float(CRTMaskLayer.triadRange.upperBound)),
                                               .init("crt-mask", "strength", .float(CRTMaskLayer.strengthRange.upperBound))]))
            add("Filmed TV", look("filmed-tv"))
            add("Phone Dub", look("phone-dub"))
            // The Display Looks, under their names.
            add("Tripod TV", look("tripod-tv"))
            add("Up Close", look("up-close"))
        case .audio:
            // Linear NR is the default sound, so Fresh SP's sound reads it by name.
            let presets: [(String, AudioPreset)] = [("Clean Hi-Fi", .hifi), ("Camcorder", .camcorder),
                                                    ("Linear NR", .linearNR), ("Linear", .linear),
                                                    ("Worn Linear", .wornLinear), ("EP Linear", .epLinear)]
            for (name, preset) in presets {
                add(name, stage.snapshot(vhs: VHSLayers(), audio: AudioChain(preset: preset)))
            }
            // Every built-in Look's sound, so the Audio room never reads Custom on one:
            // the worn Looks add audio damage to a track and Shoebox the camera's motor. Each is
            // named for what it does to the sound, in its Look's words, and a Look with no name
            // here reads its own. A twin of one above is left out.
            for l in Looks.all { add(Self.audioNames[l.id] ?? l.name, look(l.id)) }
        }
        builtInCache[stage] = list
        return list
    }

    @MainActor static var builtInCache: [Stage: [StagePreset]] = [:]

    /// The Audio built-ins drawn from a Look's sound, by Look id, in the blurbs' words.
    static let audioNames: [String: String] = [
        "home-movie-1986": "Linear and Motor",
        "dub-of-a-dub": "Hi-Fi Dropouts",
        "attic-tape": "Sagging Linear",
        "hot-car": "Stretched Hi-Fi",
        "sticky-shed": "Shedding Hi-Fi",
    ]
}

// MARK: - The store

@MainActor
@Observable
public final class StagePresets {
    public static let fileExtension = "homevideostage"
    /// The file's type, beside `co.wonders.homevideo`'s preset type.
    public static let typeIdentifier = "co.wonders.homevideo.stage-preset"
    public nonisolated static let formatTag = "homevideo-stage-preset"
    public nonisolated static let formatVersion = 1

    /// `~/Library/Application Support/Home Video/Stage Presets`, beside `Presets`.
    public nonisolated static var defaultFolder: URL {
        AppFolders.support.appendingPathComponent("Stage Presets", isDirectory: true)
    }

    public let folder: URL
    /// The user's presets per stage, sorted by name, as of the last `refresh`.
    public private(set) var user: [Stage: [StagePreset]] = [:]

    public init(folder: URL = StagePresets.defaultFolder) {
        self.folder = folder
        refresh()
    }

    public func refresh() {
        var all: [Stage: [StagePreset]] = [:]
        for stage in Stage.allCases { all[stage] = list(stage) }
        user = all
    }

    /// One stage's folder, `Stage Presets/<Title>`.
    public func folder(for stage: Stage) -> URL {
        folder.appendingPathComponent(stage.title, isDirectory: true)
    }

    public func url(forName name: String, stage: Stage) -> URL {
        folder(for: stage).appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
    }

    /// The user's presets for `stage`, sorted by name. Malformed files and files of another
    /// stage are skipped.
    public func list(_ stage: Stage) -> [StagePreset] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(for: stage), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == Self.fileExtension }
            .compactMap { try? Self.read($0) }
            .filter { $0.stage == stage }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The menu's order: the stage's built-ins, then under a separator the user's own.
    public func presets(for stage: Stage) -> (builtIn: [StagePreset], user: [StagePreset]) {
        (Self.builtIns(stage), user[stage] ?? [])
    }

    /// The preset the stage reads as now, a built-in first, else nil (Custom).
    public func matching(_ stage: Stage, in chain: SignalChain) -> StagePreset? {
        guard let vhs = chain.vhs else { return nil }
        let now = stage.snapshot(vhs: vhs, audio: chain.audio)
        let (builtIn, mine) = presets(for: stage)
        return builtIn.first { $0.snapshot.matches(now) } ?? mine.first { $0.snapshot.matches(now) }
    }

    /// What a Look set on the other tabs, for the caption under the Look picker: each stage that is
    /// on, in flow
    /// order, with the name its room's menu reads (`matching`), else Custom. "Tape Fresh SP,
    /// Audio Linear NR" at launch.
    public func readback(_ chain: SignalChain, switches: StageSwitches) -> String {
        ChainStage.strip.filter(switches.switchIsOn).compactMap { s in
            Stage(rawValue: s.rawValue).map { "\($0.title) \(matching($0, in: chain)?.name ?? "Custom")" }
        }.joined(separator: ", ")
    }

    /// Sets the preset's stage on the chain and nothing else.
    public func apply(_ preset: StagePreset, to chain: SignalChain) throws {
        guard let vhs = chain.vhs else { throw StagePresetError.noChain }
        preset.stage.apply(preset.snapshot, vhs: vhs, audio: chain.audio)
    }

    /// Writes the stage's current values as `<name>.homevideostage` in its folder, replacing a
    /// preset of the same name there.
    @discardableResult
    public func save(name: String, stage: Stage, chain: SignalChain) throws -> StagePreset {
        let name = try Self.checkedName(name)
        guard let vhs = chain.vhs else { throw StagePresetError.noChain }
        let data = try Self.encode(name: name, stage: stage, snapshot: stage.snapshot(vhs: vhs, audio: chain.audio))
        try FileManager.default.createDirectory(at: folder(for: stage), withIntermediateDirectories: true)
        let url = url(forName: name, stage: stage)
        try data.write(to: url, options: .atomic)
        refresh()
        return try Self.read(url)
    }

    /// Writes the stage's current values as a file at `destination`, outside the folder
    /// (Export while a built-in or Custom is shown).
    public func write(name: String, stage: Stage, chain: SignalChain, to destination: URL) throws {
        let name = try Self.checkedName(name)
        guard let vhs = chain.vhs else { throw StagePresetError.noChain }
        try Self.encode(name: name, stage: stage, snapshot: stage.snapshot(vhs: vhs, audio: chain.audio))
            .write(to: destination, options: .atomic)
    }

    /// Writes a preset out to `destination`: a user's file as it is, a built-in from its values.
    public func export(_ preset: StagePreset, to destination: URL) throws {
        let data: Data
        if let url = preset.url {
            _ = try Self.read(url)
            data = try Data(contentsOf: url)
        } else {
            data = try Self.encode(name: preset.name, stage: preset.stage, snapshot: preset.snapshot)
        }
        try data.write(to: destination, options: .atomic)
    }

    /// Copies a stage preset file into `stage`'s folder under the name it carries, replacing a
    /// preset of that name. A file for another stage or a malformed one throws, nothing copied.
    @discardableResult
    public func `import`(from source: URL, as stage: Stage) throws -> StagePreset {
        let preset = try Self.read(source)
        guard preset.stage == stage else {
            throw StagePresetError.wrongStage(source.lastPathComponent, found: preset.stage, wanted: stage)
        }
        try FileManager.default.createDirectory(at: folder(for: stage), withIntermediateDirectories: true)
        let dest = url(forName: preset.name, stage: stage)
        if dest.standardizedFileURL != source.standardizedFileURL {
            try Data(contentsOf: source).write(to: dest, options: .atomic)
        }
        refresh()
        return try Self.read(dest)
    }

    public func delete(_ preset: StagePreset) throws {
        guard let url = preset.url else { throw StagePresetError.builtIn(preset.name) }
        try FileManager.default.removeItem(at: url)
        refresh()
    }

    /// Renames a user's preset and its file. A name another preset of the stage has gets " 2"
    /// (then " 3" and on), as the Look's presets do.
    @discardableResult
    public func rename(_ preset: StagePreset, to newName: String) throws -> StagePreset {
        guard let old = preset.url else { throw StagePresetError.builtIn(preset.name) }
        let wanted = try Self.checkedName(newName)
        if wanted == preset.name { return preset }
        let own = preset.name.lowercased()
        let fm = FileManager.default
        let others = Set(list(preset.stage).filter { $0.url?.standardizedFileURL != old.standardizedFileURL }
            .map { $0.name.lowercased() })
        let name = UserPresets.freeName(wanted) { candidate in
            others.contains(candidate.lowercased())
                || (candidate.lowercased() != own && fm.fileExists(atPath: url(forName: candidate, stage: preset.stage).path))
        }
        let data = try Self.encode(name: name, stage: preset.stage, snapshot: preset.snapshot)
        // Move first, so a folder that cannot be written refuses before anything changes. A
        // change of case only goes through a temporary name, since the folder is usually case
        // insensitive.
        let dest = url(forName: name, stage: preset.stage)
        if name.lowercased() == own {
            let temp = folder(for: preset.stage).appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: old, to: temp)
            do { try fm.moveItem(at: temp, to: dest) } catch {
                try? fm.moveItem(at: temp, to: old)
                throw error
            }
        } else {
            try fm.moveItem(at: old, to: dest)
        }
        do { try data.write(to: dest, options: .atomic) } catch {
            try? fm.moveItem(at: dest, to: old)
            refresh()
            throw error
        }
        refresh()
        return try Self.read(dest)
    }

    // MARK: - The file

    static func checkedName(_ raw: String) throws -> String {
        do { return try UserPresets.checkedName(raw) } catch { throw StagePresetError.badName(raw) }
    }

    static func encode(name: String, stage: Stage, snapshot: StageSnapshot) throws -> Data {
        let layers: [[String: Any]] = snapshot.layers.map { r in
            var record: [String: Any] = ["id": r.id,
                                         "parameters": r.values.map { ["id": $0.id, "value": UserPresets.json($0.value)] as [String: Any] }]
            if let on = r.enabled { record["enabled"] = on }
            return record
        }
        var root: [String: Any] = ["format": formatTag, "version": formatVersion, "stage": stage.rawValue,
                                   "name": name, "layers": layers]
        if stage == .audio {
            root["track"] = (snapshot.track ?? .hifi).rawValue
            root[AudioWear.id] = snapshot.wear
            root[AudioChain.strengthID] = snapshot.strength
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Reads and checks a stage preset file: its format, version, stage and name, every layer
    /// id one of the stage's, every parameter one of the layer's with a value of its type.
    /// The values are applied to a fresh stage and read back, so the preset holds the whole
    /// stage as the sliders would. Throws `malformed` otherwise.
    public static func read(_ url: URL) throws -> StagePreset {
        let file = url.lastPathComponent
        func bad(_ reason: String) -> StagePresetError { .malformed(file, reason: reason) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw bad("cannot read the file") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw bad("not a JSON object")
        }
        guard root["format"] as? String == formatTag else { throw bad("no \(formatTag) format tag") }
        guard let version = root["version"] as? Int, version == formatVersion else {
            throw bad("version is not \(formatVersion)")
        }
        guard let raw = root["stage"] as? String, let stage = Stage(rawValue: raw) else { throw bad("no known stage") }
        guard let rawName = root["name"] as? String, let name = try? checkedName(rawName) else {
            throw bad("no usable name")
        }
        guard let records = root["layers"] as? [[String: Any]] else { throw bad("no layers list") }

        let vhs = VHSLayers()
        var track = AudioTrack.hifi
        if stage == .audio {
            guard let t = root["track"] as? String, let parsed = AudioTrack(rawValue: t) else { throw bad("no audio track") }
            track = parsed
        }
        let audio = AudioChain(mic: .clean, track: track)
        let known: [(id: String, parameters: [LayerParameter])] = stage == .audio
            ? audio.allLayers.map { ($0.id, $0.parameters) }
            : stage.layers(in: vhs).map { ($0.id, $0.parameters) }

        var parsed: [StageSnapshot.Record] = []
        for r in records {
            guard let id = r["id"] as? String else { throw bad("a layer has no id") }
            guard let params = known.first(where: { $0.id == id })?.parameters else {
                throw bad("\(id) is not a \(stage.title) layer")
            }
            guard !parsed.contains(where: { $0.id == id }) else { throw bad("layer \(id) twice") }
            var enabled: Bool?
            if r["enabled"] != nil {
                guard let b = UserPresets.boolValue(r["enabled"]) else { throw bad("layer \(id) has a switch that is not true or false") }
                enabled = b
            }
            guard let values = r["parameters"] as? [[String: Any]] else { throw bad("layer \(id) has no parameters list") }
            var out: [StageSnapshot.Value] = []
            for v in values {
                guard let pid = v["id"] as? String, let p = params.first(where: { $0.id == pid }) else {
                    throw bad("layer \(id) has no parameter \(v["id"] ?? "")")
                }
                guard let value = UserPresets.parameterValue(v["value"], like: p) else {
                    throw bad("\(id).\(pid) has a value of the wrong type")
                }
                out.append(.init(id: pid, value: value))
            }
            parsed.append(.init(id: id, enabled: enabled, values: out))
        }
        var snapshot = StageSnapshot(layers: parsed, track: stage == .audio ? track : nil)
        if stage == .audio {
            func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
                guard let any = root[key] else { return fallback }
                guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                    throw bad("\(key) is not a number")
                }
                return min(max(n.doubleValue, range.lowerBound), range.upperBound)
            }
            snapshot.wear = try number(AudioWear.id, 0, AudioWear.range)
            snapshot.strength = try number(AudioChain.strengthID, AudioChain.fullStrength, AudioChain.strengthRange)
        }
        // Applied to a fresh stage and read back: defaults for what the file leaves out.
        stage.apply(snapshot, vhs: vhs, audio: audio)
        return StagePreset(stage: stage, name: name, snapshot: stage.snapshot(vhs: vhs, audio: audio), url: url)
    }
}
