import Foundation

// Presets: four pickers above the layer list (Tape, Link, Deck, Capture), each owning a set of
// layer parameters. A preset writes through the layers' own `setParameter`, the same path the
// sliders use, and a picker's shown state is read back from those parameters, so moving a
// slider off a preset's value turns that picker to Custom with no extra bookkeeping.

/// Tape speed preset: the L3 luma cut and the L4 chroma cut and delay per speed.
public typealias TapePreset = TapeSpeed

/// How the signal reaches the deck and leaves it.
public enum LinkPreset: String, CaseIterable, Sendable {
    /// Y/C kept apart: L2 off and the capture card's composite input off.
    case svideo
    /// One wire: L2 on and the card's composite input on, both with the same separator.
    case composite

    public var label: String { self == .svideo ? "S-Video" : "Composite" }
}

/// The deck's (and the tape's) condition. Aged is a faded tape on a clean deck.
public enum DeckPreset: String, CaseIterable, Sendable {
    case clean, worn, aged
    public var label: String { rawValue.capitalized }
}

/// What was recorded: a digital source straight to tape, or a camcorder's picture.
public enum SourcePreset: String, CaseIterable, Sendable {
    case digital, camcorder
    public var label: String { self == .digital ? "Digital" : "Camcorder" }
}

/// The values the Source picker owns, per source (the camcorder's exposure and white
/// balance). The capture border is its own switch, not the camcorder's.
public struct SourceValues: Equatable, Sendable {
    public var camera: Bool
    public var levelsGain: Double
    public var levelsClip: Bool
    public var cbCodes: Double
    public var crCodes: Double
    public var hueDegrees: Double

    public static let digital = SourceValues(camera: false, levelsGain: 1, levelsClip: false,
                                             cbCodes: 0, crCodes: 0, hueDegrees: 0)
    /// A tungsten white balance measured on a 1986 home tape, gain 1.15 into a code 255 clip.
    public static let camcorder = SourceValues(camera: true, levelsGain: 1.15,
                                               levelsClip: true, cbCodes: -3, crCodes: 5, hueDegrees: -15)

    public static func values(for s: SourcePreset) -> SourceValues { s == .digital ? .digital : .camcorder }
}

/// How the capture card builds a frame from two fields.
public typealias CapturePreset = Deinterlace

/// One deck condition's values for the parameters the Deck picker owns.
public struct DeckValues: Equatable, Sendable {
    public var lumaSNR: Double
    public var chromaSNR: Double
    public var peaking: Double
    public var headSwitchShift: Double
    public var timeBaseAmplitude: Double
    public var topFlagging: Double
    /// L7 height in field lines (3 of them hidden).
    public var headSwitchHeight: Double = 6
    public var chromaDelay: Double = 1
    public var dropoutRate: Double = 3
    public var chromaGain: Double = 1
    public var blackIRE: Double = 0

    /// The defaults, as the layers are built (docs/SIGNAL-CHAIN.md).
    public static let clean = DeckValues(lumaSNR: 45, chromaSNR: 45, peaking: 0, headSwitchShift: 24,
                                         timeBaseAmplitude: 0.5, topFlagging: 2)
    /// Lower S/N, some peaking, the big head switch band (12 visible lines, 120 px), doubled
    /// jitter and flagging, 2 px chroma lag, 25 dropouts a minute.
    public static let worn = DeckValues(lumaSNR: 40, chromaSNR: 38, peaking: 0.2, headSwitchShift: 120,
                                        timeBaseAmplitude: clean.timeBaseAmplitude * 2,
                                        topFlagging: clean.topFlagging * 2, headSwitchHeight: 15, chromaDelay: 2,
                                        dropoutRate: 25)
    /// A faded tape on a clean deck: chroma at 0.8 and blacks lifted 19 codes (8 IRE), as
    /// measured on faded home tapes.
    public static let aged: DeckValues = {
        var v = clean
        v.chromaGain = 0.8
        v.blackIRE = 19.0 / 219 * 92.5
        return v
    }()

    public static func values(for deck: DeckPreset) -> DeckValues {
        switch deck {
        case .clean: return .clean
        case .worn: return .worn
        case .aged: return .aged
        }
    }
}

/// The L7 noise burst gain the "Tracking noise" switch turns on. The layer's default is 0
/// (off): the burst is damage, not a given.
public let trackingNoiseDefault = 0.08

/// The capture border the "Capture border" switch draws: the left bar and top dark rows
/// measured on two 1991 home tapes, one capture house's habit, off by default.
public let captureBorderLeft = 15.0
public let captureBorderTop = 5.0

/// A choice of presets, any of which may be left out (that picker is not touched). The
/// sub-selections only apply under their parent: `separator` under Composite, `temporalFields`
/// under Weave. `trackingNoise` and `border` are switches of their own under every choice.
public struct PresetSelection: Equatable, Sendable {
    public var tape: TapePreset?
    public var link: LinkPreset?
    public var separator: Separator?
    public var deck: DeckPreset?
    public var trackingNoise: Bool?
    public var capture: CapturePreset?
    public var temporalFields: Bool?
    public var osd: Bool?
    /// The audio chain's preset, applied to a `SignalChain`'s audio, not to `VHSLayers`.
    public var audio: AudioPreset?
    public var source: SourcePreset?
    /// The capture border (left bar and top rows), on or off.
    public var border: Bool?

    public init(tape: TapePreset? = nil, link: LinkPreset? = nil, separator: Separator? = nil,
                deck: DeckPreset? = nil, trackingNoise: Bool? = nil, capture: CapturePreset? = nil,
                temporalFields: Bool? = nil, osd: Bool? = nil, audio: AudioPreset? = nil,
                source: SourcePreset? = nil, border: Bool? = nil) {
        self.audio = audio
        self.source = source
        self.border = border
        self.tape = tape
        self.link = link
        self.separator = separator
        self.deck = deck
        self.trackingNoise = trackingNoise
        self.capture = capture
        self.temporalFields = temporalFields
        self.osd = osd
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var text: String
        public var description: String {
            "--preset wants key=value pairs split by commas (tape=sp|lp|ep, link=svideo|composite, "
                + "separator=notch|comb1|comb2, deck=clean|worn|aged, tracking=on|off, capture=weave|bob|blend, "
                + "temporal=on|off, osd=on|off, audio=hifi|camcorder|linearnr|linear|worn-linear|ep-linear|off, source=digital|camcorder, border=on|off), got '\(text)'"
        }
    }

    /// Parses `tape=EP,link=composite,deck=worn,capture=bob`. Keys and values ignore case, and
    /// "s-video" and "svideo" both name S-Video.
    public static func parse(_ text: String) throws -> PresetSelection {
        var s = PresetSelection()
        let fail = ParseError(text: text)
        func bool(_ v: String) throws -> Bool {
            switch v {
            case "on", "true", "yes", "1": return true
            case "off", "false", "no", "0": return false
            default: throw fail
            }
        }
        let pairs = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !pairs.isEmpty else { throw fail }
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.lowercased() }
            guard kv.count == 2 else { throw fail }
            let v = kv[1].replacingOccurrences(of: "-", with: "")
            switch kv[0] {
            case "tape": guard let t = TapePreset(rawValue: v) else { throw fail }; s.tape = t
            case "link": guard let l = LinkPreset(rawValue: v) else { throw fail }; s.link = l
            case "separator": guard let x = Separator(rawValue: v) else { throw fail }; s.separator = x
            case "deck": guard let d = DeckPreset(rawValue: v) else { throw fail }; s.deck = d
            case "tracking": s.trackingNoise = try bool(v)
            case "capture": guard let c = CapturePreset(rawValue: v) else { throw fail }; s.capture = c
            case "temporal": s.temporalFields = try bool(v)
            case "osd": s.osd = try bool(v)
            case "audio": guard let a = AudioPreset(rawValue: v) else { throw fail }; s.audio = a
            case "source": guard let x = SourcePreset(rawValue: v) else { throw fail }; s.source = x
            case "border": s.border = try bool(v)
            default: throw fail
            }
        }
        return s
    }
}

/// Reads and writes the presets on a `VHSLayers`. Holds no state of its own.
@MainActor
public struct Presets {
    public let vhs: VHSLayers
    /// The audio chain a Look sets and reads back. Without one, Looks cover the video alone.
    public let audio: AudioChain?

    public init(vhs: VHSLayers, audio: AudioChain? = nil) {
        self.vhs = vhs
        self.audio = audio
    }

    nonisolated static let tolerance = 1e-6
    nonisolated static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < tolerance }

    // MARK: Reading back (nil is Custom)

    /// The tape speed whose two cuts match L3 and L4, else nil (Custom). The chroma delay is
    /// the deck's (the Y delay line equalizes the filter, so speed does not move it).
    public var tape: TapePreset? {
        TapePreset.allCases.first { s in
            Self.same(vhs.luma.cutMHz, s.lumaCutMHz) && Self.same(vhs.colorUnder.cutKHz, s.chromaCutKHz)
        }
    }

    /// S-Video when L2 and the card's composite input are both off, Composite when both are on
    /// with one separator, anything else Custom.
    public var link: LinkPreset? {
        let l2 = vhs.compositeLink.enabled, card = vhs.capture.composite
        if !l2 && !card { return .svideo }
        if l2 && card && vhs.compositeLink.separator == vhs.capture.separator { return .composite }
        return nil
    }

    /// The separator both ends use under Composite.
    public var separator: Separator { vhs.compositeLink.separator }

    /// Clean, Worn or Aged when every owned value matches, else nil (Custom). The tracking
    /// noise burst is its own switch and does not count.
    public var deck: DeckPreset? {
        DeckPreset.allCases.first { d in
            let v = DeckValues.values(for: d)
            return Self.same(vhs.noise.lumaSNR, v.lumaSNR) && Self.same(vhs.noise.chromaSNR, v.chromaSNR)
                && Self.same(vhs.halo.peaking, v.peaking) && Self.same(vhs.headSwitch.maxShift, v.headSwitchShift)
                && Self.same(vhs.timeBase.amplitude, v.timeBaseAmplitude)
                && Self.same(vhs.timeBase.flagAmplitude, v.topFlagging)
                && Self.same(vhs.headSwitch.height, v.headSwitchHeight)
                && Self.same(vhs.colorUnder.delay, v.chromaDelay) && Self.same(vhs.colorUnder.gain, v.chromaGain)
                && Self.same(vhs.dropouts.ratePerMinute, v.dropoutRate) && Self.same(vhs.levels.blackIRE, v.blackIRE)
        }
    }

    /// The tracking noise burst: on when L7's noise burst is above zero.
    public var trackingNoise: Bool { vhs.headSwitch.noise > Self.tolerance }

    /// The capture border: on when the frame layer draws a left bar or top rows.
    public var border: Bool { vhs.frame.leftBar > Self.tolerance || vhs.frame.topRows > Self.tolerance }

    /// Weave or Bob always reads back (the L9 choice has no other values).
    public var capture: CapturePreset { vhs.capture.deinterlace }
    public var temporalFields: Bool { vhs.capture.temporalFields }

    // MARK: Writing

    public func setTape(_ t: TapePreset) {
        // The speed choice on each layer sets its cuts and delay together.
        vhs.luma.setParameter("speed", to: .choice(t.rawValue))
        vhs.colorUnder.setParameter("speed", to: .choice(t.rawValue))
    }

    public func setLink(_ l: LinkPreset, separator: Separator? = nil) {
        let composite = l == .composite
        vhs.compositeLink.enabled = composite
        vhs.capture.setParameter("composite", to: .bool(composite))
        if composite { setSeparator(separator ?? self.separator) }
    }

    /// The separator at both ends (the deck's link and the capture card).
    public func setSeparator(_ s: Separator) {
        vhs.compositeLink.setParameter("separator", to: .choice(s.rawValue))
        vhs.capture.setParameter("separator", to: .choice(s.rawValue))
    }

    /// Sets every value the deck owns. The tracking noise switch is left as it is.
    public func setDeck(_ d: DeckPreset) {
        let v = DeckValues.values(for: d)
        vhs.noise.setParameter("luma", to: .float(v.lumaSNR))
        vhs.noise.setParameter("chroma", to: .float(v.chromaSNR))
        vhs.halo.setParameter("peaking", to: .float(v.peaking))
        vhs.headSwitch.setParameter("shift", to: .float(v.headSwitchShift))
        vhs.timeBase.setParameter("amplitude", to: .float(v.timeBaseAmplitude))
        vhs.timeBase.setParameter("flag", to: .float(v.topFlagging))
        vhs.headSwitch.setParameter("height", to: .float(v.headSwitchHeight))
        vhs.colorUnder.setParameter("delay", to: .float(v.chromaDelay))
        vhs.colorUnder.setParameter("gain", to: .float(v.chromaGain))
        vhs.dropouts.setParameter("rate", to: .float(v.dropoutRate))
        vhs.levels.setParameter("black", to: .float(v.blackIRE))
    }

    /// Digital or Camcorder when every value the Source picker owns matches, else nil.
    public var source: SourcePreset? {
        SourcePreset.allCases.first { s in
            let v = SourceValues.values(for: s)
            return vhs.camera.enabled == v.camera && Self.same(vhs.levels.gain, v.levelsGain)
                && vhs.levels.clip == v.levelsClip && Self.same(vhs.camera.cbCodes, v.cbCodes)
                && Self.same(vhs.camera.crCodes, v.crCodes) && Self.same(vhs.camera.hueDegrees, v.hueDegrees)
        }
    }

    public func setSource(_ s: SourcePreset) {
        let v = SourceValues.values(for: s)
        vhs.camera.enabled = v.camera
        vhs.levels.setParameter("gain", to: .float(v.levelsGain))
        vhs.levels.setParameter("clip", to: .bool(v.levelsClip))
        vhs.camera.setParameter("cb", to: .float(v.cbCodes))
        vhs.camera.setParameter("cr", to: .float(v.crCodes))
        vhs.camera.setParameter("hue", to: .float(v.hueDegrees))
    }

    public func setTrackingNoise(_ on: Bool) {
        vhs.headSwitch.setParameter("noise", to: .float(on ? trackingNoiseDefault : 0))
    }

    public func setBorder(_ on: Bool) {
        vhs.frame.setParameter("left", to: .float(on ? captureBorderLeft : 0))
        vhs.frame.setParameter("top", to: .float(on ? captureBorderTop : 0))
    }

    public func setCapture(_ c: CapturePreset, temporalFields: Bool? = nil) {
        vhs.capture.setParameter("deinterlace", to: .choice(c.rawValue))
        if let temporalFields { setTemporalFields(temporalFields) }
    }

    public func setTemporalFields(_ on: Bool) {
        vhs.capture.setParameter("temporal", to: .bool(on))
    }

    public var osd: Bool {
        get { vhs.osd.enabled }
        nonmutating set { vhs.osd.enabled = newValue }
    }

    /// Applies every picker the selection names, in Source, Tape, Link, Deck, Capture order,
    /// then the sub-selections and switches on their own (so `separator=comb2` alone retunes an
    /// existing Composite).
    public func apply(_ s: PresetSelection) {
        if let src = s.source { setSource(src) }
        if let t = s.tape { setTape(t) }
        if let l = s.link { setLink(l, separator: s.separator) } else if let sep = s.separator { setSeparator(sep) }
        if let d = s.deck { setDeck(d) }
        if let n = s.trackingNoise { setTrackingNoise(n) }
        if let b = s.border { setBorder(b) }
        if let c = s.capture { setCapture(c, temporalFields: s.temporalFields) }
        else if let tf = s.temporalFields { setTemporalFields(tf) }
        if let o = s.osd { osd = o }
    }
}
