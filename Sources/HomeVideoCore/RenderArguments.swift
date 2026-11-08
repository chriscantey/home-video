import Foundation

/// The command line of `homevideo-render`, parsed without touching the chain, so it is unit tested
/// on its own. `apply(to:)` then maps it onto a chain by layer and parameter id, so new layers
/// need no changes here.
public struct RenderArguments: Equatable, Sendable {
    public enum LayerSelection: Equatable, Sendable {
        /// The layers as `SignalChain.standard()` builds them, the app's defaults (L2 off).
        case standard
        case all
        case none
        /// Effect layers to turn on by id; every other effect layer is turned off.
        case only([String])
    }

    /// One `--stage <stage>=<name>`.
    public struct StagePick: Equatable, Sendable {
        public var stage: Stage
        public var name: String
    }

    /// One stage step, in the order given: `--stage <stage>=<name>` (a built-in) or
    /// `--stage-file <path.homevideostage>` (a stage preset saved from the app).
    public enum StageStep: Equatable, Sendable {
        case builtIn(StagePick)
        case file(String)
    }

    /// `--size`: one of the Output size menu's choices, Custom with its width and height.
    public struct SizePick: Equatable, Sendable {
        public var size: OutputSize
        public var width: Int?
        public var height: Int?
        public init(size: OutputSize, width: Int? = nil, height: Int? = nil) {
            self.size = size
            self.width = width
            self.height = height
        }
    }

    /// What `apply(to:)` found beyond the chain: the range to render and the sidecar it read.
    public struct Applied: Equatable, Sendable {
        /// The sidecar's trim with `--in` and `--out` over it, nil for the whole clip.
        public var trim: TrimRange?
        /// The sidecar read, nil when none was.
        public var sidecar: String?
    }

    /// One `--set <layer>.<parameter>=<value>`.
    public struct Setting: Equatable, Sendable {
        public var layer: String
        public var parameter: String
        public var value: String
        public init(layer: String, parameter: String, value: String) {
            self.layer = layer
            self.parameter = parameter
            self.value = value
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingPositional
        case extraPositional(String)
        case missingValue(String)
        case badFrames(String)
        case badSetting(String)
        case badPixelFormat(String)
        case badPreset(String)
        case badLook(String)
        case badWear(String)
        case badExport(String, option: String, expected: [String])
        case badTime(String, option: String)
        case badRange(inPoint: Double, outPoint: Double)
        case twoSidecars
        case unknownOption(String)

        public var description: String {
            switch self {
            case .missingPositional: return "need an input movie and an output .mov"
            case .extraPositional(let s): return "unexpected argument '\(s)'"
            case .missingValue(let s): return "\(s) needs a value"
            case .badFrames(let s): return "--frames wants a positive whole number, got '\(s)'"
            case .badSetting(let s): return "--set wants <layer>.<parameter>=<value>, got '\(s)'"
            case .badPixelFormat(let s): return "--pixel-format wants 2vuy or bgra, got '\(s)'"
            case .badPreset(let s): return PresetSelection.ParseError(text: s).description
            case .badLook(let s): return "--look wants one of \(Looks.ids), got '\(s)'"
            case .badWear(let s): return "--audio-wear wants a number from 0 to 100, got '\(s)'"
            case .badExport(let s, let option, let expected):
                return "\(option) wants one of \(expected.joined(separator: "|")), got '\(s)'"
            case .badTime(let s, let option):
                return "\(option) wants a time in the clip, seconds (12.5) or minutes and seconds (1:02.5), got '\(s)'"
            case .badRange(let a, let b):
                return "--in \(a) is not before --out \(b)"
            case .twoSidecars: return "--sidecar and --clip-sidecar name two sidecars; pick one"
            case .unknownOption(let s): return "unknown option '\(s)'"
            }
        }
    }

    public enum ApplyError: Error, Equatable, CustomStringConvertible {
        case unknownLayer(String, known: [String])
        case unknownParameter(String, layer: String, known: [String])
        case badValue(String, for: String, expected: String)
        case badFile(String, option: String, reason: String)

        public var description: String {
            switch self {
            case .badFile(let path, let option, let reason):
                return "\(option) \(path): \(reason)"
            case .unknownLayer(let id, let known):
                return "no layer '\(id)' (layers: \(known.joined(separator: ", ")))"
            case .unknownParameter(let p, let layer, let known):
                return "layer '\(layer)' has no parameter '\(p)' (parameters: \(known.joined(separator: ", ")))"
            case .badValue(let v, let key, let expected):
                return "'\(v)' is not a valid value for \(key) (expected \(expected))"
            }
        }
    }

    public var input: String
    public var output: String
    public var frames: Int?
    public var layers: LayerSelection = .standard
    public var settings: [Setting] = []
    public var pixelFormat: ExportPixelFormat = .yuv422
    public var listLayers = false
    public var listLooks = false
    /// `--look <id>`, applied first, before `--preset` and `--set`.
    public var look: Look?
    /// `--preset tape=EP,link=composite,deck=worn,capture=bob`, applied before any `--set`.
    public var preset: PresetSelection?
    /// `--preset-file <path>`, a saved user preset, applied after `--look`, before `--preset`.
    public var presetFile: String?
    /// `--audio-wear 0...100`, applied after `--look`, `--preset-file` and `--preset`, before any `--set`.
    public var audioWear: Double?
    /// `--audio-mic`, `--audio-track`, `--mic-strength` and `--audio-tape`, applied after
    /// `--preset`: the mic and the track first, then the wear, then the Strength and the Tape switch.
    public var audioMic: AudioMic?
    public var audioTrack: AudioTrack?
    public var micStrength: Double?
    public var audioTape: Bool?
    /// `--stage <stage>=<name>`, a built-in stage preset by its menu name (`film=Summer Reel`,
    /// `telecine=Mall transfer`), applied as the stage menu applies it, after `--preset` and the
    /// audio options, before any `--set`, in the order given.
    public var stages: [StagePick] {
        stageSteps.compactMap { if case .builtIn(let p) = $0 { return p } else { return nil } }
    }
    /// `--stage` and `--stage-file` together, in the order given.
    public var stageSteps: [StageStep] = []
    /// `--sidecar <path.homevideo.json>`: a clip's sidecar, the whole chain, Framing, the
    /// Output size and its trim, applied after `--look`, before everything else.
    public var sidecar: String?
    /// `--clip-sidecar`: the input clip's own sidecar (beside it, else in the app's fallback
    /// folder), where `--sidecar` would go. Never read unless asked for, so a run with the same
    /// flags renders the same picture whatever the app has saved.
    public var clipSidecar = false
    /// `--settings <file.json>`: the app's Copy Settings JSON, after the sidecar, before
    /// `--preset-file`.
    public var settingsFile: String?
    /// `--size` and `--fit`, the Output size and its Picture choice, after the stages, before
    /// any `--set`.
    public var size: SizePick?
    public var fill: Bool?
    /// `--in` and `--out`, seconds of the clip, over the sidecar's trim end by end.
    public var inPoint: Double?
    public var outPoint: Double?
    /// `--codec`, `--quality` and `--container`, the export sheet's choices. The tool's default is the
    /// master (ProRes 422 .mov), not the app's sharing default, so measurements see no encoder loss.
    public var export = ExportSettings.master

    public init(input: String, output: String, frames: Int? = nil, layers: LayerSelection = .standard,
                settings: [Setting] = [], pixelFormat: ExportPixelFormat = .yuv422) {
        self.input = input
        self.output = output
        self.frames = frames
        self.layers = layers
        self.settings = settings
        self.pixelFormat = pixelFormat
    }

    public static let usage = """
        usage: homevideo-render <in> <out.mov> [--frames N] [--layers default|all|none|<id,id,...>]
                                [--look <id>] [--sidecar <file.homevideo.json> | --clip-sidecar]
                                [--settings <file.json>] [--preset-file <file.homevideopreset>]
                                [--preset tape=sp|lp|ep,link=svideo|composite,deck=clean|worn|aged,capture=weave|bob|blend]
                                [--stage <stage>=<name>]... [--stage-file <file.homevideostage>]...
                                [--size <size>] [--fit inside|fill] [--in <time>] [--out <time>]
                                [--set <layer>.<parameter>=<value>]... [--pixel-format 2vuy|bgra]
                                [--codec <codec>] [--quality good|better|best] [--container mov|mp4]
               homevideo-render --list-layers [--look <id>]
               homevideo-render --list-looks

        Renders <in> through the Home Video signal chain to a ProRes 422 .mov at the last stage's
        own size (Output size Auto): 720x480 shown 4:3 when the tape or the telecine is last, the
        Display's canvas (or the camera's frame with Re-capture) with a CRT layer on, the film's
        scan with the film alone, the source's own size with every stage off. --size picks another.
        <in> is any movie AVFoundation reads, as the app opens (.mov, .mp4, .m4v and the like).

        The order every run applies them in, whatever order they are typed: --layers, --look,
        the sidecar, --settings, --preset-file, --preset, the audio options, --stage and
        --stage-file in the order given, --size and --fit, then each --set in the order given.
        A later step wins where two set the same value. --in and --out pick the range last.

        Export, as the app's Export sheet: --codec picks the encoder
        (\(ExportCodec.allCases.map(\.rawValue).joined(separator: "|")), default proRes422, the master,
        where the app's sheet starts at h264), --quality good|better|best the H.264 or HEVC bitrate
        (\(ExportQuality.allCases.map { q in "\(q.rawValue) \(q.bitrate(for: .h264).map { "\($0 / 1_000_000)" } ?? "-")/\(q.bitrate(for: .hevc).map { "\($0 / 1_000_000)" } ?? "-")" }.joined(separator: ", ")) Mbps H.264/HEVC, default better,
        none for ProRes), --container mov|mp4 the file type the codec takes (ProRes .mov only,
        H.264 and HEVC .mp4 by default, or .mov). The sound follows the audio chain, as in the app.

        Output size, as the Look tab's: --size auto|source|sd|hd|uhd|phone|<width>x<height>
        (auto is the last stage's own size, 720x480 for the tape, source the clip's, sd 720x480,
        hd 1920x1080, uhd 3840x2160, phone 1080x1920, <width>x<height> is Custom in even numbers,
        \(OutputSizeLayer.widthRange.lowerBound) to \(OutputSizeLayer.widthRange.upperBound) by \(OutputSizeLayer.heightRange.lowerBound) to \(OutputSizeLayer.heightRange.upperBound)). --fit inside|fill is the Picture choice
        for a size that is not 4:3: inside fits the 4:3 picture whole (the default), fill has every
        stage work at the frame's shape so the picture fills it. Same as --set output.size=hd,
        --set output.fill=on, --set output.width=1280 --set output.height=720.

        In and out points, as the Clip menu's: --in <time> and --out <time>, seconds (12.5) or
        minutes and seconds (1:02.5) of the clip. Only that range is rendered and the file starts
        at zero. Either end alone keeps the other at the clip's own start or end. --frames then
        counts from the in point.

        A clip's sidecar (the clip.MOV.homevideo.json the app keeps beside it) is read only when
        asked for, so the same flags always render the same picture: --sidecar <file> reads that
        file, --clip-sidecar reads <in>'s own (beside it, else the app's fallback folder, and with
        none found it renders without one). It sets the whole chain, Framing, the Output size and
        the trim, as opening the clip in the app does. --in and --out override its trim end by end.
        --settings <file.json> applies the JSON the app's Copy Settings puts on the clipboard
        (every layer, Framing but its rotation, the Output size and the audio):
        pbpaste > clip.json, then --settings clip.json.

        Framing always runs; --layers picks the effect layers after it. The default is the
        app's default chain (every VHS layer but the L2 composite link), the Fresh SP Look,
        framed Center crop (--set framing.mode=letterbox fits the whole picture inside).
        --look sets the whole chain to a named Look first (--list-looks prints id, name and
        blurb, one per line). --preset then sets the app's preset pickers before any --set; it
        also takes source=digital|camcorder, separator=notch|comb1|comb2, tracking=on|off,
        border=on|off, temporal=on|off and osd=on|off.

        Audio: --preset audio=hifi|camcorder|linearnr|linear|worn-linear|ep-linear|off picks the audio chain
        (default linearnr, Fresh SP's: the linear track with its noise reduction matched). Camcorder is Hi-Fi with the camcorder's own mic on (audio-camcorder: the
        motor's whine, preamp hiss, the AGC).
        Off copies the source track untouched, the others decode it, run the chain and write AAC
        48 kHz stereo. Audio layers take --set like video layers (audio-hiss.level=-36,
        audio-dolby.enabled=on); --list-layers shows them for the default preset.
        --audio-wear <0...100> moves every audio layer of the preset toward its worn end (0 is the
        preset's own values), after --look and --preset, before any --set.
        The same chain split by where the sound happens: --audio-mic clean|camcorder,
        --audio-track hifi|linearnr|linear|worn|ep|off, --mic-strength <0...100> (100 is the camcorder mic
        as modeled, 0 the clean mic) and --audio-tape on|off (off plays the mic alone, no track).
        --preset-file <path.homevideopreset> applies a preset saved from the app's Look menu
        (Save Preset or Export Preset), every layer and the audio. A preset holds no Framing, no
        Output size and no export choice: give those with --set framing.*, --size and --codec.
        --stage film|telecine|tape|display=<name> applies a built-in stage preset by its menu name
        (--stage "film=Summer Reel" --stage "telecine=Mall transfer"), as the stage menu does,
        after --preset, before any --set. --stage-file <path.homevideostage> applies a stage
        preset saved or exported from a stage menu, that stage only.
        Stage switches: --set film=on, telecine=on, tape=off, display=on (every CRT layer),
        recapture=on, audio=off (the Audio switch: Track Off, Mic Clean).
        Framing: --set framing.mode=cropCenter|letterbox|fullRaster, framing.zoom,
        framing.pan, framing.panY (--list-layers shows the modes and ranges).

        Damage (set by the worn Looks, off in the rest, marked in --list-layers): damage-tear, damage-snow,
        damage-clog, damage-crease, audio-damage-glide, audio-damage-flutter,
        audio-damage-azimuth, audio-damage-clog, audio-damage-worn, audio-damage-crackle,
        audio-damage-hifi, audio-damage-mute. Events are sporadic and repeat exactly for a
        seed. Switch one on with --set <id>.enabled=on and tune
        it with --set <id>.strength=0.7, --set <id>.rate=12 (events a minute, damage-snow a
        second) and --set <id>.seed=42. --layers all leaves them off,
        and --layers <id,...> may name the picture ones.
        """

    /// Parses arguments without the program name.
    public static func parse(_ args: [String]) throws -> RenderArguments {
        var positional: [String] = []
        var frames: Int?
        var layers: LayerSelection = .standard
        var settings: [Setting] = []
        var pixelFormat: ExportPixelFormat = .yuv422
        var list = false
        var listLooks = false
        var look: Look?
        var preset: PresetSelection?
        var presetFile: String?
        var audioWear: Double?
        var audioMic: AudioMic?
        var audioTrack: AudioTrack?
        var micStrength: Double?
        var audioTape: Bool?
        var stageSteps: [StageStep] = []
        var sidecar: String?
        var clipSidecar = false
        var settingsFile: String?
        var size: SizePick?
        var fill: Bool?
        var inPoint: Double?
        var outPoint: Double?
        var codec = ExportSettings.master.codec
        var quality = ExportSettings.master.quality
        var container: ExportContainer?

        var i = 0
        func value(_ name: String) throws -> String {
            i += 1
            guard i < args.count else { throw ParseError.missingValue(name) }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            // Accept --name=value as well as --name value.
            var name = a, inline: String?
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                name = String(a[..<eq])
                inline = String(a[a.index(after: eq)...])
            }
            func next() throws -> String { if let inline { return inline }; return try value(name) }
            switch name {
            case "--frames":
                let s = try next()
                guard let n = Int(s), n > 0 else { throw ParseError.badFrames(s) }
                frames = n
            case "--layers":
                let s = try next()
                switch s {
                case "default": layers = .standard
                case "all": layers = .all
                case "none": layers = .none
                default:
                    let ids = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    layers = ids.isEmpty ? .none : .only(ids)
                }
            case "--set":
                settings.append(try parseSetting(try next()))
            case "--pixel-format":
                let s = try next()
                guard let f = ExportPixelFormat(rawValue: s) else { throw ParseError.badPixelFormat(s) }
                pixelFormat = f
            case "--preset":
                let s = try next()
                guard let p = try? PresetSelection.parse(s) else { throw ParseError.badPreset(s) }
                preset = p
            case "--look":
                let s = try next()
                guard let l = Looks.look(id: s.lowercased()) else { throw ParseError.badLook(s) }
                look = l
            case "--list-looks":
                listLooks = true
            case "--list-layers":
                list = true
            case "--preset-file":
                presetFile = try next()
            case "--audio-wear":
                let s = try next()
                guard let w = Double(s), AudioWear.range.contains(w) else { throw ParseError.badWear(s) }
                audioWear = w
            case "--audio-mic":
                let s = try next()
                guard let m = AudioMic(rawValue: s.lowercased()) else {
                    throw ParseError.badExport(s, option: name, expected: AudioMic.allCases.map(\.rawValue))
                }
                audioMic = m
            case "--audio-track":
                let s = try next()
                guard let t = AudioTrack(rawValue: s.lowercased()) else {
                    throw ParseError.badExport(s, option: name, expected: AudioTrack.allCases.map(\.rawValue))
                }
                audioTrack = t
            case "--mic-strength":
                let s = try next()
                guard let v = Double(s), AudioChain.strengthRange.contains(v) else {
                    throw ParseError.badExport(s, option: name, expected: ["a number from 0 to 100"])
                }
                micStrength = v
            case "--audio-tape":
                let s = try next()
                switch s.lowercased() {
                case "on": audioTape = true
                case "off": audioTape = false
                default: throw ParseError.badExport(s, option: name, expected: ["on", "off"])
                }
            case "--stage":
                let s = try next()
                guard let eq = s.firstIndex(of: "="), let stage = Stage(rawValue: s[..<eq].lowercased()),
                      stage != .audio, s.index(after: eq) < s.endIndex else {
                    throw ParseError.badExport(s, option: name, expected: ["film=<name>", "telecine=<name>",
                                                                           "tape=<name>", "display=<name>"])
                }
                stageSteps.append(.builtIn(StagePick(stage: stage, name: String(s[s.index(after: eq)...]))))
            case "--stage-file":
                stageSteps.append(.file(try next()))
            case "--sidecar":
                sidecar = try next()
            case "--clip-sidecar":
                clipSidecar = true
            case "--settings":
                settingsFile = try next()
            case "--size":
                size = try parseSize(try next())
            case "--fit":
                let s = try next()
                switch s.lowercased() {
                case "inside": fill = false
                case "fill": fill = true
                default: throw ParseError.badExport(s, option: name, expected: ["inside", "fill"])
                }
            case "--in":
                let s = try next()
                guard let t = parseTime(s) else { throw ParseError.badTime(s, option: name) }
                inPoint = t
            case "--out":
                let s = try next()
                guard let t = parseTime(s) else { throw ParseError.badTime(s, option: name) }
                outPoint = t
            case "--codec":
                let s = try next()
                guard let c = ExportCodec(rawValue: s) else {
                    throw ParseError.badExport(s, option: name, expected: ExportCodec.allCases.map(\.rawValue))
                }
                codec = c
            case "--quality":
                let s = try next()
                guard let q = ExportQuality(rawValue: s) else {
                    throw ParseError.badExport(s, option: name, expected: ExportQuality.allCases.map(\.rawValue))
                }
                quality = q
            case "--container":
                let s = try next()
                guard let c = ExportContainer(rawValue: s) else {
                    throw ParseError.badExport(s, option: name, expected: ExportContainer.allCases.map(\.rawValue))
                }
                container = c
            default:
                if a.hasPrefix("-"), a.count > 1 { throw ParseError.unknownOption(a) }
                positional.append(a)
            }
            i += 1
        }
        if (list || listLooks) && positional.isEmpty {
            var r = RenderArguments(input: "", output: "")
            r.listLayers = list
            r.listLooks = listLooks
            r.look = look
            return r
        }
        guard positional.count >= 2 else { throw ParseError.missingPositional }
        guard positional.count == 2 else { throw ParseError.extraPositional(positional[2]) }
        var r = RenderArguments(input: positional[0], output: positional[1], frames: frames, layers: layers,
                                settings: settings, pixelFormat: pixelFormat)
        r.listLayers = list
        r.listLooks = listLooks
        r.look = look
        r.preset = preset
        r.presetFile = presetFile
        r.audioWear = audioWear
        r.audioMic = audioMic
        r.audioTrack = audioTrack
        r.micStrength = micStrength
        r.audioTape = audioTape
        r.stageSteps = stageSteps
        if sidecar != nil && clipSidecar { throw ParseError.twoSidecars }
        r.sidecar = sidecar
        r.clipSidecar = clipSidecar
        r.settingsFile = settingsFile
        r.size = size
        r.fill = fill
        if let a = inPoint, let b = outPoint, b <= a { throw ParseError.badRange(inPoint: a, outPoint: b) }
        r.inPoint = inPoint
        r.outPoint = outPoint
        if let container, !codec.containers.contains(container) {
            throw ParseError.badExport(container.rawValue, option: "--container",
                                       expected: codec.containers.map(\.rawValue))
        }
        r.export = ExportSettings(codec: codec, quality: quality, container: container)
        return r
    }

    /// One `--set` on an audio layer. `enabled` takes on or off, like a layer's switch.
    @MainActor
    static func apply(_ s: Setting, to layer: AudioLayer) throws {
        let key = "\(s.layer).\(s.parameter)"
        func bool(_ v: String) throws -> Bool {
            switch v.lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: throw ApplyError.badValue(v, for: key, expected: "true or false")
            }
        }
        if s.parameter == "enabled" {
            layer.enabled = try bool(s.value)
            return
        }
        guard let p = layer.parameters.first(where: { $0.id == s.parameter }) else {
            throw ApplyError.unknownParameter(s.parameter, layer: s.layer,
                                              known: ["enabled"] + layer.parameters.map { $0.id })
        }
        switch p.value {
        case .float:
            guard let v = Double(s.value), v.isFinite else {
                throw ApplyError.badValue(s.value, for: key, expected: "a number")
            }
            layer.setParameter(p.id, to: .float(v))
        case .bool:
            layer.setParameter(p.id, to: .bool(try bool(s.value)))
        case .choice:
            let values = p.options.map(\.value)
            guard values.contains(s.value) else {
                throw ApplyError.badValue(s.value, for: key, expected: values.joined(separator: "|"))
            }
            layer.setParameter(p.id, to: .choice(s.value))
        }
    }

    /// The stage switches a setting may name without a parameter: `tape=off`, `film=on`.
    /// `display` and `audio` are the strip's other two switches: `display=on` turns every CRT
    /// layer on, as the Display switch does at launch, and `audio=off` sets the Track to Off and
    /// the Mic to Clean, as the Audio switch does.
    public static let stageSwitches: Set<String> = ["tape", "film", "telecine", "recapture", "display", "audio"]

    /// `--size`'s words: the Output size menu's ids, or `<width>x<height>` for Custom (even
    /// numbers inside `OutputSizeLayer.widthRange` and `heightRange`, as the fields clamp them).
    static func parseSize(_ s: String) throws -> SizePick {
        let t = s.lowercased()
        if let size = OutputSize(rawValue: t), size != .custom { return SizePick(size: size) }
        let parts = t.split(separator: "x", omittingEmptySubsequences: false)
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
           OutputSizeLayer.widthRange.contains(w), OutputSizeLayer.heightRange.contains(h) {
            return SizePick(size: .custom,
                            width: OutputSizeLayer.clamp(Double(w), to: OutputSizeLayer.widthRange),
                            height: OutputSizeLayer.clamp(Double(h), to: OutputSizeLayer.heightRange))
        }
        let w = OutputSizeLayer.widthRange, h = OutputSizeLayer.heightRange
        throw ParseError.badExport(s, option: "--size", expected: OutputSize.allCases.filter { $0 != .custom }.map(\.rawValue)
                                   + ["<width>x<height> (\(w.lowerBound)...\(w.upperBound) by \(h.lowerBound)...\(h.upperBound))"])
    }

    /// A time in the clip: seconds (`12.5`), or minutes and seconds (`1:02.5`), or hours,
    /// minutes and seconds (`1:02:03`). Nil for anything else or a negative time.
    static func parseTime(_ s: String) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v.isFinite, v >= 0 else { return nil }
            // Minutes and seconds after the first field stay under 60.
            if i > 0 && v >= 60 { return nil }
            // Only the last field may carry a fraction.
            if i < parts.count - 1 && v != v.rounded() { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func parseSetting(_ s: String) throws -> Setting {
        guard let eq = s.firstIndex(of: "=") else { throw ParseError.badSetting(s) }
        let key = s[..<eq]
        let value = String(s[s.index(after: eq)...])
        // A stage's switch in short: tape=off is tape.enabled=off.
        if !key.contains("."), stageSwitches.contains(String(key)), !value.isEmpty {
            return Setting(layer: String(key), parameter: "enabled", value: value)
        }
        guard let dot = key.firstIndex(of: ".") else { throw ParseError.badSetting(s) }
        let layer = String(key[..<dot])
        let param = String(key[key.index(after: dot)...])
        guard !layer.isEmpty, !param.isEmpty, !value.isEmpty else { throw ParseError.badSetting(s) }
        return Setting(layer: layer, parameter: param, value: value)
    }

    /// Turns layers on and off and sets parameters, by id. Framing is required and stays on
    /// whatever the selection says. Unknown ids and unparsable values are errors, never ignored.
    ///
    /// The order: `--layers`, `--look`, the sidecar (`--sidecar` or `--clip-sidecar`),
    /// `--settings`, `--preset-file`, `--preset`, the audio options, `--stage` and
    /// `--stage-file` in the order given, `--size` and `--fit`, then every `--set`. Returns the
    /// range to render (the sidecar's trim with `--in` and `--out` over it) and the sidecar read.
    @MainActor
    @discardableResult
    public func apply(to chain: SignalChain) throws -> Applied {
        let known = chain.settingsLayers.map(\.id)
        func path(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        if case .only(let ids) = layers {
            for id in ids where !known.contains(id) { throw ApplyError.unknownLayer(id, known: known) }
        }
        for layer in chain.effects {
            switch layers {
            case .standard: break
            // "all" is every VHS layer. A Damage layer goes on only by name.
            case .all: layer.enabled = !(layer is any DamageLayer)
            case .none: layer.enabled = false
            case .only(let ids): layer.enabled = ids.contains(layer.id)
            }
        }
        if let look {
            guard let vhs = chain.vhs else { throw ApplyError.unknownLayer("looks", known: known) }
            Presets(vhs: vhs, audio: chain.audio).setLook(look)
        }
        var applied = Applied()
        var sidecarURL: URL?
        if let sidecar {
            sidecarURL = path(sidecar)
            guard FileManager.default.fileExists(atPath: sidecarURL!.path) else {
                throw ApplyError.badFile(sidecar, option: "--sidecar", reason: "no such file")
            }
        } else if clipSidecar, !input.isEmpty {
            // The clip's own, where the app keeps it. None is no error: the clip renders with
            // the rest of the flags, as a clip the app never saved anything for.
            sidecarURL = Sidecar.existing(for: path(input))
        }
        if let sidecarURL {
            let contents: SidecarContents
            do { contents = try Sidecar.read(sidecarURL, into: chain) } catch {
                throw ApplyError.badFile(sidecarURL.path, option: sidecar != nil ? "--sidecar" : "--clip-sidecar",
                                         reason: "\(error)")
            }
            applied.trim = contents.trim
            applied.sidecar = sidecarURL.path
        }
        if let settingsFile {
            let json: String
            do { json = try String(contentsOf: path(settingsFile), encoding: .utf8) } catch {
                throw ApplyError.badFile(settingsFile, option: "--settings", reason: "cannot read the file")
            }
            do { try SettingsClipboard.apply(json, to: chain) } catch {
                throw ApplyError.badFile(settingsFile, option: "--settings", reason: "\(error)")
            }
        }
        if let presetFile {
            try UserPresets.apply(path(presetFile), to: chain)
        }
        if let preset {
            guard let vhs = chain.vhs else { throw ApplyError.unknownLayer("presets", known: known) }
            Presets(vhs: vhs).apply(preset)
            if let a = preset.audio { chain.audio.preset = a }
        }
        if let audioMic { chain.audio.mic = audioMic }
        if let audioTrack { chain.audio.setTrack(audioTrack) }
        if let audioWear { chain.audio.setWear(audioWear) }
        if let micStrength { chain.audio.setMicStrength(micStrength) }
        if let audioTape { chain.audio.tapeIsOn = audioTape }
        for step in stageSteps {
            let preset: StagePreset
            switch step {
            case .builtIn(let pick):
                let builtIns = StagePresets.builtIns(pick.stage)
                guard let p = builtIns.first(where: { $0.name.lowercased() == pick.name.lowercased() }) else {
                    throw ApplyError.badValue(pick.name, for: "--stage \(pick.stage.rawValue)",
                                              expected: builtIns.map(\.name).joined(separator: "|"))
                }
                preset = p
            case .file(let file):
                do { preset = try StagePresets.read(path(file)) } catch {
                    throw ApplyError.badFile(file, option: "--stage-file", reason: "\(error)")
                }
            }
            guard let vhs = chain.vhs else { throw ApplyError.unknownLayer("stages", known: known) }
            preset.stage.apply(preset.snapshot, vhs: vhs, audio: chain.audio)
        }
        if let size, let output = chain.vhs?.output {
            output.setParameter("size", to: .choice(size.size.rawValue))
            if let w = size.width { output.setParameter("width", to: .float(Double(w))) }
            if let h = size.height { output.setParameter("height", to: .float(Double(h))) }
        }
        if let fill, let output = chain.vhs?.output { output.setParameter("fill", to: .bool(fill)) }
        if inPoint != nil || outPoint != nil {
            // An end not given keeps the sidecar's, else the clip's own start or end (the
            // exporter clamps the range to the clip).
            let a = inPoint ?? applied.trim?.inPoint ?? 0
            let b = outPoint ?? applied.trim?.outPoint ?? Double.greatestFiniteMagnitude
            applied.trim = TrimRange(in: a, out: b)
        }
        for s in settings {
            // The Display and Audio switches, as the strip sets them.
            if s.parameter == "enabled", s.layer == "display" || s.layer == "audio" {
                let on: Bool
                switch s.value.lowercased() {
                case "true", "on", "yes", "1": on = true
                case "false", "off", "no", "0": on = false
                default: throw ApplyError.badValue(s.value, for: "\(s.layer).enabled", expected: "true or false")
                }
                if s.layer == "audio" {
                    chain.audio.setOn(on)
                } else if let vhs = chain.vhs {
                    for l in vhs.crt.layers { l.enabled = on }
                }
                continue
            }
            if let audio = chain.audio.allLayers.first(where: { $0.id == s.layer }) {
                try Self.apply(s, to: audio)
                continue
            }
            guard let layer = chain.settingsLayers.first(where: { $0.id == s.layer }) else {
                throw ApplyError.unknownLayer(s.layer, known: known + chain.audio.allLayers.map { $0.id })
            }
            let key = "\(s.layer).\(s.parameter)"
            // Film's old output choice (the film branches) is folded into the stages after the
            // loop: --set film.output=scan is --set tape=off.
            if s.parameter == "output", let film = layer as? FilmLayer, film.id == "film" {
                guard FilmOutput(rawValue: s.value) != nil else {
                    throw ApplyError.badValue(s.value, for: key, expected: FilmOutput.allCases.map(\.rawValue).joined(separator: "|"))
                }
                film.setParameter("output", to: .choice(s.value))
                continue
            }
            // A stage's, a Damage, Film or CRT layer's switch, like an audio layer's:
            // --set tape=off, --set damage-snow.enabled=on, --set film.enabled=on,
            // --set crt-beam.enabled=on.
            if s.parameter == "enabled",
               layer is TapeStageLayer || layer is any DamageLayer || layer is FilmLayer || layer is any CRTLayer {
                switch s.value.lowercased() {
                case "true", "on", "yes", "1": layer.enabled = true
                case "false", "off", "no", "0": layer.enabled = false
                default: throw ApplyError.badValue(s.value, for: key, expected: "true or false")
                }
                continue
            }
            let params = layer.parameters
            guard let p = params.first(where: { $0.id == s.parameter }) else {
                throw ApplyError.unknownParameter(s.parameter, layer: s.layer, known: params.map(\.id))
            }
            switch p.value {
            case .float:
                guard let v = Double(s.value), v.isFinite else {
                    throw ApplyError.badValue(s.value, for: key, expected: "a number")
                }
                layer.setParameter(p.id, to: .float(v))
            case .bool:
                switch s.value.lowercased() {
                case "true", "on", "yes", "1": layer.setParameter(p.id, to: .bool(true))
                case "false", "off", "no", "0": layer.setParameter(p.id, to: .bool(false))
                default: throw ApplyError.badValue(s.value, for: key, expected: "true or false")
                }
            case .choice:
                let values = p.options.map(\.value)
                guard values.contains(s.value) else {
                    throw ApplyError.badValue(s.value, for: key, expected: values.joined(separator: "|"))
                }
                layer.setParameter(p.id, to: .choice(s.value))
            }
        }
        chain.vhs?.foldLegacyFilmOutput()
        return applied
    }
}
