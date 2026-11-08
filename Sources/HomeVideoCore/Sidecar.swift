import CryptoKit
import Foundation

// A clip's settings, kept beside the clip. `clip.MOV` gets `clip.MOV.homevideo.json` in the
// same folder. When that folder is read
// only, the file goes to `~/Library/Application Support/Home Video/Sidecars/<sha256 of the
// clip's path>.json` instead.
//
// The file is a user preset (`UserPresets`) with more keys, so the preset reader reads it too:
//
//   { "formatVersion": 2, "kind": "homevideo-sidecar", "version": 1, "name": "clip.MOV",
//     "look": "rental", "audio": "linear",
//     "framing": { "mode": "cropCenter", "zoom": 1.2, "pan": 0, "panY": -0.3, "rotation": 90 },
//     "layers": [ ... as in a preset ... ], "audioLayers": [ ... as in a preset ... ] }
//
// `look` is the Look the chain was last on (null when none), which Forget Settings goes back
// to. `trim` is the clip's in and out points in seconds, `"trim": { "in": 5, "out": 10 }`,
// and the key is absent when the whole clip plays. `version` is the preset layout's version,
// for the preset reader. `formatVersion` is the sidecar's own.
//
// The format outlives versions. The rule for every future change:
//
// - A new field is added with a default, so a file without it reads as before. A field is never
//   renamed. A removed field is left in place in old files and ignored.
// - `formatVersion` goes up by one when a change needs an old file rewritten to be read, and the
//   step that rewrites it is added to `Sidecar.migrations`. A file without `formatVersion` is
//   version 1, which reads as version 2 does, so the list is empty today.
// - Reading keeps what it does not know: the file is read as a dictionary, and a write merges
//   the app's values into the dictionary it read, so unknown keys at every level, and layers or
//   parameters the app no longer has, are written back unchanged. Unknown ids are ignored.
// - A missing key takes its default. A known key with a value of the wrong type is refused, and
//   a malformed file throws before anything changes.
// - A file from a newer version loads what this version understands and is not rewritten until
//   the user changes something. Then it is written at this version with its unknown keys kept,
//   and the log says so.

public enum SidecarError: Error, Equatable, CustomStringConvertible {
    case malformed(String, reason: String)

    public var description: String {
        switch self {
        case .malformed(let file, let reason): return "\(file) is not a Home Video sidecar: \(reason)"
        }
    }
}

/// The framing a sidecar holds.
public struct SidecarFraming: Equatable, Sendable {
    public var mode: FramingMode
    public var zoom: Double
    public var pan: Double
    public var panY: Double
    public var rotation: Int

    public init(mode: FramingMode, zoom: Double, pan: Double, panY: Double, rotation: Int) {
        self.mode = mode
        self.zoom = zoom
        self.pan = pan
        self.panY = panY
        self.rotation = rotation
    }
}

/// What a sidecar says apart from the layers, which go straight into the chain.
public struct SidecarContents: Equatable, Sendable {
    public var name: String
    public var lookID: String?
    public var framing: SidecarFraming
    /// The clip's trim, nil when the file has none.
    public var trim: TrimRange?
    /// The `formatVersion` the file said (1 when it had none), before any migration.
    public var formatVersion: Int = Sidecar.formatVersion
}

public enum Sidecar {
    public static let suffix = ".homevideo.json"
    public static let kind = "homevideo-sidecar"
    /// The id prefix of the Look a sidecar read applies. Like a user preset it is the whole
    /// chain saved, so `Presets.setLook` sets the Damage layers for it too.
    public static let lookIDPrefix = "sidecar:"
    /// The sidecar format's own version, written as `formatVersion`.
    public static let formatVersion = 2
    /// The preset layout's version (`UserPresets.formatVersion`), written as `version` for the
    /// preset reader. A sidecar read does not check it.
    public static let presetVersion = UserPresets.formatVersion

    /// The steps from one format version to the next, in order: a step with `from: n` takes a
    /// version n file's dictionary to version n + 1, keeping every key it does not touch. A
    /// file runs every step from its own version up. Empty today: version 1 (a file without
    /// `formatVersion`) reads as version 2 does.
    public static let migrations: [(from: Int, step: ([String: Any]) -> [String: Any])] = []

    /// `~/Library/Application Support/Home Video/Sidecars`, for clips in read only folders.
    public static var fallbackFolder: URL {
        AppFolders.support.appendingPathComponent("Sidecars", isDirectory: true)
    }

    /// `<clip file name>.homevideo.json` beside the clip.
    public static func besideURL(for clip: URL) -> URL {
        clip.deletingLastPathComponent().appendingPathComponent(clip.lastPathComponent + suffix)
    }

    /// `<fallback folder>/<sha256 of the clip's standardized path>.json`.
    public static func fallbackURL(for clip: URL, folder: URL = fallbackFolder) -> URL {
        let digest = SHA256.hash(data: Data(clip.standardizedFileURL.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hex + ".json")
    }

    /// The clip's sidecar on disk, beside it first, else in the fallback folder.
    public static func existing(for clip: URL, fallbackFolder: URL = fallbackFolder) -> URL? {
        let fm = FileManager.default
        let beside = besideURL(for: clip)
        if fm.fileExists(atPath: beside.path) { return beside }
        let fallback = fallbackURL(for: clip, folder: fallbackFolder)
        return fm.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// The JSON for the chain's current values, merged into `preserving` (the file as last
    /// read) so the keys this version does not know are written back unchanged.
    @MainActor
    public static func encode(chain: SignalChain, name: String, lookID: String?, trim: TrimRange? = nil,
                              preserving: [String: Any]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: document(chain: chain, name: name, lookID: lookID,
                                                            trim: trim, preserving: preserving),
                                   options: [.prettyPrinted, .sortedKeys])
    }

    /// The file's dictionary: the chain's values over `preserving`.
    @MainActor
    static func document(chain: SignalChain, name: String, lookID: String?, trim: TrimRange?,
                         preserving: [String: Any]?) -> [String: Any] {
        let r = record(chain: chain, name: name, lookID: lookID, rotation: chain.framing.rotation, trim: trim)
        guard let preserving else { return r }
        var out = merged(preserving, r) as? [String: Any] ?? r
        if trim == nil { out["trim"] = nil }
        // Back at Auto the Output size leaves the file, so it reads as a file saved before the
        // Output size existed.
        if r["output"] == nil { out["output"] = nil }
        // Back at 4:3 inside the fill key leaves too, since a merge keeps a key only the old file has.
        if var o = out["output"] as? [String: Any], (r["output"] as? [String: Any])?["fill"] == nil {
            o["fill"] = nil
            out["output"] = o
        }
        return out
    }

    /// `new` over `old`: dictionaries merge key by key (a key only `old` has stays), lists of
    /// records with an `id` merge record by record (a record only `old` has stays, after the
    /// new ones), and anything else is `new`.
    static func merged(_ old: Any?, _ new: Any) -> Any {
        if let n = new as? [String: Any], let o = old as? [String: Any] {
            var out = o
            for (k, v) in n { out[k] = merged(o[k], v) }
            return out
        }
        if let n = new as? [[String: Any]], let o = old as? [[String: Any]],
           n.allSatisfy({ $0["id"] is String }), o.allSatisfy({ $0["id"] is String }) {
            let olds = Dictionary(o.map { ($0["id"] as! String, $0) }, uniquingKeysWith: { a, _ in a })
            let newIDs = Set(n.map { $0["id"] as! String })
            return n.map { merged(olds[$0["id"] as! String], $0) } + o.filter { !newIDs.contains($0["id"] as! String) }
        }
        return new
    }

    /// Reads `url` as a dictionary at this format version: the file's own version (1 when it
    /// has none) and the dictionary after the migration steps. A newer file is returned as it
    /// is. Throws when it is not a JSON object or its `formatVersion` is not a whole number
    /// from 1.
    static func load(_ url: URL) throws -> (version: Int, root: [String: Any]) {
        let file = url.lastPathComponent
        func bad(_ reason: String) -> SidecarError { .malformed(file, reason: reason) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw bad("cannot read the file") }
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw bad("not a JSON object")
        }
        let version: Int
        switch root["formatVersion"] {
        case nil: version = 1
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue == n.doubleValue.rounded()
                                    && n.intValue >= 1:
            version = n.intValue
        default: throw bad("formatVersion is not a whole number from 1")
        }
        if version < formatVersion {
            for m in migrations where m.from >= version { root = m.step(root) }
            root["formatVersion"] = formatVersion
        }
        return (version, root)
    }

    /// The settings as a value to compare: the file without the name and the rotation, which
    /// comes from the clip's track and is set by the preview on every open, so it is no edit.
    @MainActor
    public static func snapshot(of chain: SignalChain, lookID: String?, trim: TrimRange? = nil) -> Data {
        let r = record(chain: chain, name: "", lookID: lookID, rotation: 0, trim: trim)
        return (try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])) ?? Data()
    }

    /// Only the trim of the sidecar at `url`, for a clip that is not the shown one (its export
    /// still honors its range). Nil when there is no file, no trim, or the file is malformed.
    public static func trim(at url: URL) -> TrimRange? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (try? parseTrim(root["trim"])) ?? nil
    }

    /// `{ "in": 5, "out": 10 }` as a range, nil when absent or null. Anything else throws.
    static func parseTrim(_ value: Any?) throws -> TrimRange? {
        switch value {
        case nil, is NSNull: return nil
        case let t as [String: Any]:
            func number(_ key: String) -> Double? {
                guard let n = t[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
                return n.doubleValue
            }
            guard let a = number("in"), let b = number("out") else { throw TrimParseError() }
            return TrimRange(in: a, out: b)
        default:
            throw TrimParseError()
        }
    }

    struct TrimParseError: Error {}

    @MainActor
    static func record(chain: SignalChain, name: String, lookID: String?, rotation: Int,
                       trim: TrimRange? = nil) -> [String: Any] {
        let f = chain.framing
        let framing: [String: Any] = ["mode": f.mode.rawValue, "zoom": f.zoom, "pan": f.pan, "panY": f.panY,
                                      "rotation": rotation]
        let layers = (chain.vhs?.savedLayers ?? []).map { l in
            UserPresets.layerRecord(id: l.id, enabled: Looks.userSwitch(l) ?? l.enabled, parameters: l.parameters)
        }
        let audioLayers = chain.audio.allLayers.map {
            UserPresets.layerRecord(id: $0.id, enabled: $0.enabled, parameters: $0.parameters)
        }
        var r: [String: Any] = ["formatVersion": formatVersion, "version": presetVersion, "kind": kind,
                                "name": name, "look": lookID ?? NSNull(),
                                "audio": chain.audio.preset.rawValue, "framing": framing,
                                "layers": layers, "audioLayers": audioLayers]
        if let trim { r["trim"] = ["in": trim.inPoint, "out": trim.outPoint] }
        // The Output size, the clip's like Framing, only off Auto.
        if let o = chain.vhs?.output, !o.isAuto {
            var d: [String: Any] = ["size": o.size.rawValue, "width": o.width, "height": o.height]
            // Fill the frame only when picked, so a 4:3 inside file reads as one saved before
            // the fill key existed.
            if o.fill { d["fill"] = true }
            r["output"] = d
        }
        // The Audio wear, only when moved, so a file at 0 reads as it always did.
        if chain.audio.wear > 0 { r[AudioWear.id] = chain.audio.wear }
        // The mic Strength, only below 100, for the same reason.
        if chain.audio.micStrength < AudioChain.fullStrength { r[AudioChain.strengthID] = chain.audio.micStrength }
        return r
    }

    /// Writes the chain's values (and the clip's trim, when set) to `url` atomically, making
    /// its folder when needed, merged into `preserving` (the file as last read). Returns the
    /// dictionary written.
    @MainActor
    @discardableResult
    public static func write(chain: SignalChain, name: String, lookID: String?, trim: TrimRange? = nil,
                             preserving: [String: Any]? = nil, to url: URL) throws -> [String: Any] {
        let doc = document(chain: chain, name: name, lookID: lookID, trim: trim, preserving: preserving)
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return doc
    }

    /// Reads `url` and sets the chain from it. Everything is checked first, so a malformed
    /// file throws and the chain stays as it was.
    @MainActor
    @discardableResult
    public static func read(_ url: URL, into chain: SignalChain) throws -> SidecarContents {
        try readDocument(url, into: chain).contents
    }

    /// `read`, also returning the file's dictionary at this format version, which a later
    /// write merges into.
    @MainActor
    public static func readDocument(_ url: URL, into chain: SignalChain) throws
        -> (contents: SidecarContents, root: [String: Any]) {
        let file = url.lastPathComponent
        func bad(_ reason: String) -> SidecarError { .malformed(file, reason: reason) }
        let (fileVersion, root) = try load(url)
        guard root["kind"] as? String == kind else { throw bad("kind is not \(kind)") }
        let name: String
        switch root["name"] {
        case nil: name = ""
        case let s as String: name = s
        default: throw bad("name is not a string")
        }
        let lookID: String?
        switch root["look"] {
        case nil, is NSNull: lookID = nil
        case let s as String: lookID = s
        default: throw bad("look is not a string or null")
        }
        let defaults = FramingLayer()
        let f: [String: Any]
        switch root["framing"] {
        case nil: f = [:]
        case let d as [String: Any]: f = d
        default: throw bad("framing is not an object")
        }
        let mode: FramingMode
        switch f["mode"] {
        case nil: mode = defaults.mode
        case let s as String:
            guard let m = FramingMode(rawValue: s) else { throw bad("framing has no mode \(s)") }
            mode = m
        default: throw bad("framing mode is not a string")
        }
        func number(_ key: String, _ fallback: Double) throws -> Double {
            guard let v = f[key] else { return fallback }
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw bad("framing \(key) is not a number")
            }
            return n.doubleValue
        }
        let framing = SidecarFraming(mode: mode, zoom: try number("zoom", defaults.zoom), pan: try number("pan", defaults.pan),
                                     panY: try number("panY", defaults.panY),
                                     rotation: FramingMath.normalizedRotation(
                                        Int(try number("rotation", Double(defaults.rotation)).rounded())))
        let trim: TrimRange?
        do { trim = try parseTrim(root["trim"]) } catch { throw bad("trim is not { in, out } in seconds") }
        let audioPreset: AudioPreset
        let overrides: [Look.Override]
        do {
            (audioPreset, overrides) = try UserPresets.settings(in: root, lenient: true) {
                UserPresetError.malformed(file, reason: $0)
            }
        } catch UserPresetError.malformed(_, let reason) {
            throw bad(reason)
        }
        guard let vhs = chain.vhs else { throw bad("the chain has no VHS layers") }

        let look = Look(id: lookIDPrefix + name, name: name, blurb: "The settings in \(file).",
                        selection: PresetSelection(audio: audioPreset), overrides: overrides)
        Presets(vhs: vhs, audio: chain.audio).setLook(look)
        chain.framing.setParameter("mode", to: .choice(framing.mode.rawValue))
        chain.framing.setParameter("zoom", to: .float(framing.zoom))
        chain.framing.setParameter("pan", to: .float(framing.pan))
        chain.framing.setParameter("panY", to: .float(framing.panY))
        chain.framing.rotation = framing.rotation
        // The Output size: absent is Auto. A value this build does not know reads as Auto.
        if let output = chain.vhs?.output {
            let o = root["output"] as? [String: Any] ?? [:]
            output.size = (o["size"] as? String).flatMap(OutputSize.init(rawValue:)) ?? .auto
            if let w = (o["width"] as? NSNumber)?.doubleValue { output.setParameter("width", to: .float(w)) }
            if let h = (o["height"] as? NSNumber)?.doubleValue { output.setParameter("height", to: .float(h)) }
            // Fill the frame: absent, as in every file saved before the fill key, is 4:3 inside.
            output.fill = (o["fill"] as? Bool) ?? false
        }
        return (SidecarContents(name: name, lookID: lookID, framing: framing, trim: trim, formatVersion: fileVersion),
                root)
    }

    /// The modification date of a file, nil when it is not there.
    public static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Runs the last action handed to it once `delay` has passed with nothing new: one write per
/// burst of changes. Main actor only.
@MainActor
public final class Debouncer {
    public let delay: Duration
    private var task: Task<Void, Never>?
    private var pending: (() -> Void)?

    public init(delay: Duration = .milliseconds(500)) { self.delay = delay }

    public var isPending: Bool { pending != nil }

    public func schedule(_ action: @escaping () -> Void) {
        pending = action
        task?.cancel()
        task = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Runs the pending action now, if any.
    public func flush() {
        task?.cancel()
        task = nil
        let action = pending
        pending = nil
        action?()
    }

    public func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}

/// The shown clip's sidecar: read when the clip opens, written after each burst of changes,
/// reloaded when it is edited outside the app. One per app, over the session's one chain.
@MainActor
public final class SidecarSession {
    public let chain: SignalChain
    public let fallbackFolder: URL
    public let debouncer: Debouncer
    /// The shown clip, nil when none is.
    public private(set) var clip: URL?
    /// The Look the chain was last on, written as the sidecar's `look`.
    public private(set) var lookID: String?
    /// Where the shown clip's sidecar is, nil until one exists.
    public private(set) var sidecarURL: URL?
    /// The shown clip's trim, nil when the whole clip plays. Read with the sidecar, set
    /// with `setTrim`, written as the file's `trim`.
    public private(set) var trim: TrimRange?
    /// Called when a read (on show or an outside edit) or Forget changed `trim`, so the
    /// shown source follows it.
    public var onTrimLoaded: ((TrimRange?) -> Void)?
    /// The settings as last read or written, so a notification that changed nothing writes
    /// nothing and a clip without a sidecar gets none until something changes.
    private var baseline = Data()
    /// The sidecar's modification date as last read or written.
    private var knownDate: Date?
    /// The sidecar's dictionary as last read or written, so a write keeps the keys this
    /// version does not know.
    private var document: [String: Any]?
    /// The `formatVersion` the file said when last read, for the log line a newer file's
    /// rewrite gets.
    private var readVersion: Int?
    /// Where the sidecar's moves and rewrites are told.
    public var log: (String) -> Void = { NSLog("Home Video: %@", $0) }
    /// Called after each write, with the clip and the file.
    public var onWrite: ((URL, URL) -> Void)?
    /// Called when a write fails.
    public var onError: ((String) -> Void)?
    /// Swappable for tests: whether a folder takes a new file.
    public var isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }

    public init(chain: SignalChain, fallbackFolder: URL = Sidecar.fallbackFolder,
                delay: Duration = .milliseconds(500)) {
        self.chain = chain
        self.fallbackFolder = fallbackFolder
        self.debouncer = Debouncer(delay: delay)
    }

    /// Where a write goes for `clip`: beside it when its folder is writable, else the
    /// fallback folder.
    public func writeURL(for clip: URL) -> URL {
        isWritable(clip.deletingLastPathComponent())
            ? Sidecar.besideURL(for: clip) : Sidecar.fallbackURL(for: clip, folder: fallbackFolder)
    }

    /// A clip is shown: any pending write for the previous one lands first, then the clip's own
    /// sidecar is read into the chain. Without one the chain keeps its values and nothing is
    /// written until something changes. Returns the error when a sidecar was there but
    /// malformed (the chain is then unchanged).
    @discardableResult
    public func show(_ clip: URL?, currentLookID: String?) -> SidecarError? {
        debouncer.flush()
        self.clip = clip
        sidecarURL = nil
        knownDate = nil
        document = nil
        readVersion = nil
        lookID = currentLookID
        trim = nil
        var failure: SidecarError?
        if let clip, let url = Sidecar.existing(for: clip, fallbackFolder: fallbackFolder) {
            do {
                let (c, root) = try Sidecar.readDocument(url, into: chain)
                lookID = c.lookID
                trim = c.trim
                sidecarURL = url
                knownDate = Sidecar.modificationDate(url)
                document = root
                readVersion = c.formatVersion
            } catch let e as SidecarError {
                failure = e
            } catch {
                failure = .malformed(url.lastPathComponent, reason: "\(error)")
            }
        }
        baseline = Sidecar.snapshot(of: chain, lookID: lookID, trim: trim)
        return failure
    }

    /// The shown clip's trim changed (a handle, a key, Clear Trim): one write after the quiet
    /// period, as for a chain change.
    public func setTrim(_ range: TrimRange?) {
        guard range != trim else { return }
        trim = range
        changed(currentLookID: nil)
    }

    /// The chain may have changed. `currentLookID` is the Look it matches now, if any; the
    /// last one matched is kept otherwise. A real change schedules one write after the quiet
    /// period.
    public func changed(currentLookID: @autoclosure () -> String?) {
        guard clip != nil else { return }
        // Cheap test first: the Look read-back compares the chain with every Look.
        guard Sidecar.snapshot(of: chain, lookID: lookID, trim: trim) != baseline else { return }
        if let id = currentLookID() { lookID = id }
        let now = Sidecar.snapshot(of: chain, lookID: lookID, trim: trim)
        guard now != baseline else { return }
        debouncer.schedule { [weak self] in self?.writeNow() }
    }

    /// Writes the shown clip's sidecar now, when the settings differ from the last read or
    /// written ones. The file read is the base, so its unknown keys are kept.
    public func writeNow() {
        guard let clip else { return }
        let now = Sidecar.snapshot(of: chain, lookID: lookID, trim: trim)
        guard now != baseline else { return }
        var url = writeURL(for: clip)
        do {
            let written: [String: Any]
            do {
                written = try Sidecar.write(chain: chain, name: clip.lastPathComponent, lookID: lookID, trim: trim,
                                            preserving: document, to: url)
            } catch where url != Sidecar.fallbackURL(for: clip, folder: fallbackFolder) {
                // The folder said writable but refused (a locked volume): keep it in Support.
                url = Sidecar.fallbackURL(for: clip, folder: fallbackFolder)
                written = try Sidecar.write(chain: chain, name: clip.lastPathComponent, lookID: lookID, trim: trim,
                                            preserving: document, to: url)
            }
            if let v = readVersion, v > Sidecar.formatVersion {
                log("\(url.path) was format version \(v), written at version \(Sidecar.formatVersion) "
                    + "with the keys this version does not know kept")
            }
            baseline = now
            sidecarURL = url
            knownDate = Sidecar.modificationDate(url)
            document = written
            readVersion = Sidecar.formatVersion
            onWrite?(clip, url)
        } catch {
            onError?("Could not save the settings for \(clip.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Reloads the sidecar when its file is newer than the one last read or written (edited
    /// outside the app). Returns true when it reloaded. A malformed edit is left alone.
    @discardableResult
    public func reloadIfEditedOutside() -> Bool {
        guard let clip, let url = Sidecar.existing(for: clip, fallbackFolder: fallbackFolder),
              let date = Sidecar.modificationDate(url) else { return false }
        if let knownDate, date <= knownDate { return false }
        // A first sidecar appearing for a clip shown without one also counts as an edit.
        debouncer.cancel()
        guard let r = try? Sidecar.readDocument(url, into: chain) else {
            knownDate = date
            return false
        }
        let c = r.contents
        document = r.root
        readVersion = c.formatVersion
        lookID = c.lookID
        if c.trim != trim {
            trim = c.trim
            onTrimLoaded?(trim)
        }
        sidecarURL = url
        knownDate = date
        baseline = Sidecar.snapshot(of: chain, lookID: lookID, trim: trim)
        return true
    }

    /// Forget Settings for `clip`: deletes its sidecar (beside and in Support) and, when it is
    /// the shown clip, sets the chain back to the Look it was on (`look`, or the defaults
    /// when none) without writing a new sidecar.
    public func forget(_ clip: URL, look: Look?) {
        let fm = FileManager.default
        for url in [Sidecar.besideURL(for: clip), Sidecar.fallbackURL(for: clip, folder: fallbackFolder)]
        where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        guard clip.standardizedFileURL == self.clip?.standardizedFileURL else { return }
        debouncer.cancel()
        if let vhs = chain.vhs {
            let base = look ?? Look(id: "defaults", name: "Defaults", blurb: "", selection: PresetSelection(),
                                    overrides: [])
            Presets(vhs: vhs, audio: chain.audio).setLook(base)
        }
        if trim != nil {
            trim = nil
            onTrimLoaded?(nil)
        }
        sidecarURL = nil
        knownDate = nil
        document = nil
        readVersion = nil
        baseline = Sidecar.snapshot(of: chain, lookID: lookID, trim: trim)
    }
}
