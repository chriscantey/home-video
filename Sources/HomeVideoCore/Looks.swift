import Foundation

// Looks: named presets above the component pickers. A Look is a picker selection plus a few layer
// values on top. Choosing one
// resets every layer to its default, then applies the selection, then the overrides, all
// through the layers' own `setParameter`. It reads back by comparing every layer's switch and
// values with the chain the Look builds, so moving any picker or slider turns it to Custom
// with no bookkeeping. docs/LOOKS.md has the source of every number.

/// The Look menu's sections, each under a header. The cases run in the menu's order.
public enum LookCategory: String, CaseIterable, Sendable {
    /// The round trip to tape alone: Film, Telecine and the camera off.
    case tape
    /// The Film stage on, scanned, no Telecine.
    case film
    /// Film through the Telecine stage. Telecine is film put onto video, so every one has Film on.
    case telecine
    /// A Look that sets the Display: the tape on a tube TV, filmed off the screen.
    case display
    /// A user's saved preset or a clip's own settings.
    case custom

    /// The menu's header.
    public var title: String {
        switch self {
        case .tape: return "Tape"
        case .film: return "Film"
        case .telecine: return "Telecine"
        case .display: return "Display"
        case .custom: return "Custom"
        }
    }
}

/// One named Look.
public struct Look: Identifiable, Equatable, Sendable {
    /// One layer value on top of the selection. `parameter` "enabled" takes a bool and sets
    /// the layer's switch. `layer` may name a video layer or an audio layer.
    public struct Override: Equatable, Sendable {
        public var layer: String
        public var parameter: String
        public var value: ParameterValue
        public init(_ layer: String, _ parameter: String, _ value: ParameterValue) {
            self.layer = layer
            self.parameter = parameter
            self.value = value
        }
    }

    public var id: String
    public var name: String
    /// The menu section it sits under. A Look built from a file (a saved preset, a sidecar) is custom.
    public var category: LookCategory
    /// One line for the picker's tooltip.
    public var blurb: String
    public var selection: PresetSelection
    public var overrides: [Override]

    public init(id: String, name: String, category: LookCategory = .custom, blurb: String, selection: PresetSelection,
                overrides: [Override] = []) {
        self.id = id
        self.name = name
        self.category = category
        self.blurb = blurb
        self.selection = selection
        self.overrides = overrides
    }
}

public enum Looks {
    /// Shoebox's own values (the 1986 home movie), measured against a 1986 home tape
    /// (docs/LOOKS.md): the faded color-under, the camcorder a third of a stop under with
    /// the toe up, its tungsten cast, and the tape's lifted blacks (the Aged lift, 19 codes).
    static let homeMovie1986: [Look.Override] = [
        .init("color-under", "gain", .float(0.6)),
        .init("camera", "exposure", .float(-0.3)),
        .init("camera", "toe", .float(0.12)),
        .init("camera", "cb", .float(-6)),
        .init("camera", "cr", .float(15)),
        .init("camera", "hue", .float(-15)),
        .init("levels", "black", .float(DeckValues.aged.blackIRE)),
    ]

    /// The camcorder's own mic on: Shoebox keeps the Linear track and adds the motor.
    /// The Camcorder Look takes it through the Camcorder audio preset instead.
    static let cameraMic = Look.Override("audio-camcorder", "enabled", .bool(true))

    /// The ids of the built-in Looks whose audio carries the camcorder mic. Every other
    /// built-in Look has it off.
    public static let motor: Set<String> = ["camcorder", "home-movie-1986"]

    /// Good Deck's values on the Clean deck (docs/LOOKS.md): a line TBC (no jitter, no flagging),
    /// noise reduction (luma and chroma S/N 48), no dropouts on fresh tape, and a head switch
    /// one line high with no shift. S-VHS is the same deck class.
    static let goodDeck: [Look.Override] = [
        .init("time-base", "amplitude", .float(0)),
        .init("time-base", "flag", .float(0)),
        .init("dropouts", "rate", .float(0)),
        .init("tape-noise", "luma", .float(48)),
        .init("tape-noise", "chroma", .float(48)),
        .init("head-switch", "height", .float(1)),
        .init("head-switch", "shift", .float(0)),
    ]

    /// The clean Looks' pickers: Source Digital, SP, S-Video, Clean deck, Weave, Hi-Fi, no
    /// border, no tracking noise. Off the TV adds the tuner's composite into the deck as overrides.
    static func cleanSelection() -> PresetSelection {
        PresetSelection(tape: .sp, link: .svideo, deck: .clean, trackingNoise: false,
                        capture: .weave, audio: .hifi, source: .digital, border: false)
    }

    /// Fresh SP's pickers with its sound, the default (`AudioChain.defaultPreset`), for the
    /// Display Looks that film a fresh SP tape, so Fresh SP with a filmed Display preset over it
    /// reads as that Look.
    static func freshSP() -> PresetSelection {
        var s = cleanSelection()
        s.audio = AudioChain.defaultPreset
        return s
    }

    /// Off the TV's link: the tuner's composite through a 2-line comb into the deck (L2 on,
    /// comb2), the deck's S-Video out to the card (capture composite stays off). A comb at both
    /// ends reads softer than Fresh SP.
    static let tunerComposite: [Look.Override] = [
        .init("composite-link", "enabled", .bool(true)),
        .init("composite-link", "separator", .choice(Separator.comb2.rawValue)),
    ]

    /// One Damage layer of a worn Look: its switch on, a Strength in the middle of its
    /// range, a Rate and a fixed Seed, so the Look lands the same events on every render.
    /// `layer` names a picture layer (`damage-tear`) or an audio one (`audio-damage-glide`).
    static func wear(_ layer: String, strength: Double, rate: Double, seed: Double,
                     _ extra: [(String, ParameterValue)] = []) -> [Look.Override] {
        [.init(layer, "enabled", .bool(true)), .init(layer, "strength", .float(strength)),
         .init(layer, "rate", .float(rate)), .init(layer, "seed", .float(seed))]
            + extra.map { .init(layer, $0.0, $0.1) }
    }

    /// The ids of the built-in Looks that carry wear. Every other built-in Look has every
    /// Damage layer off.
    public static let worn: Set<String> = ["rental", "dub-of-a-dub", "attic-tape", "hot-car", "sticky-shed"]

    public static let all: [Look] = [
        Look(id: "s-vhs", name: "S-VHS", category: .tape,
             blurb: "Super VHS on a deck with a line TBC: twice the luma detail, steady lines, almost no grain.",
             selection: cleanSelection(),
             overrides: [.init("luma-bandwidth", "cut", .float(5.0))] + goodDeck),
        Look(id: "good-deck", name: "Good Deck", category: .tape,
             blurb: "A late four-head deck with a line TBC and noise reduction, fresh SP tape: steady, quiet, still VHS soft.",
             selection: cleanSelection(),
             overrides: [.init("luma-bandwidth", "cut", .float(3.0))] + goodDeck),
        Look(id: "off-the-tv", name: "Off the TV", category: .tape,
             blurb: "A good deck taping broadcast: the tuner's composite through a comb filter, nothing else wrong.",
             selection: cleanSelection(),
             overrides: tunerComposite + [.init("luma-bandwidth", "cut", .float(3.0))] + goodDeck),
        // Shown as Fresh SP, the id kept for scripts. Its sound is `AudioChain.defaultPreset`,
        // the linear track with its noise reduction.
        Look(id: "clean-sp", name: "Fresh SP", category: .tape,
             blurb: "A fresh SP tape on a good deck, S-Video out, the mono linear track's roll off and a softer hiss. The default.",
             selection: PresetSelection(tape: .sp, link: .svideo, deck: .clean, trackingNoise: false, capture: .weave,
                                        audio: AudioChain.defaultPreset, source: .digital, border: false)),
        Look(id: "camcorder", name: "Camcorder", category: .tape,
             blurb: "Shot on a camcorder, played back clean: soft, warm, hot whites, its motor humming in the pauses.",
             selection: PresetSelection(tape: .sp, link: .svideo, deck: .clean, trackingNoise: false, capture: .weave,
                                        audio: .camcorder, source: .camcorder, border: false)),
        Look(id: "home-movie-1986", name: "Shoebox", category: .tape,
             blurb: "Chases a 1986 home tape: faded color, a dark tungsten cast, composite, the camera's motor in the pauses.",
             selection: PresetSelection(tape: .sp, link: .composite, separator: .comb1, deck: .clean,
                                        trackingNoise: false, capture: .weave, audio: .linear, source: .camcorder,
                                        border: false),
             overrides: homeMovie1986 + [cameraMic]),
        Look(id: "transfer-1986", name: "Tape Transfer", category: .tape,
             blurb: "The Shoebox tape as the capture house sent it back: border, a big head switch band, tracking noise.",
             selection: PresetSelection(tape: .sp, link: .composite, separator: .comb1, deck: .clean,
                                        trackingNoise: true, capture: .weave, osd: false, audio: .linear,
                                        source: .camcorder, border: true),
             overrides: homeMovie1986 + [
                 .init("head-switch", "height", .float(DeckValues.worn.headSwitchHeight)),
                 .init("head-switch", "shift", .float(DeckValues.worn.headSwitchShift)),
             ]),
        Look(id: "rental", name: "Rental", category: .tape,
             blurb: "An EP rental played a hundred times on a tired deck: smeared and noisy, a tracking tear now and then, snow.",
             selection: PresetSelection(tape: .ep, link: .composite, separator: .notch, deck: .worn,
                                        trackingNoise: true, capture: .bob, audio: .epLinear, source: .digital,
                                        border: false),
             overrides: [
                 .init("dropouts", "rate", .float(25)),
             ] + wear("damage-tear", strength: 0.4, rate: 3, seed: 11)
               + wear("damage-snow", strength: 0.3, rate: 60, seed: 11)),
        Look(id: "dub-of-a-dub", name: "Dub of a Dub", category: .tape,
             blurb: "A copy of a copy of an LP tape on a worn deck: snow and smear three times over, the Hi-Fi dropping out.",
             selection: PresetSelection(tape: .lp, link: .composite, separator: .comb1, deck: .worn,
                                        trackingNoise: false, capture: .weave, audio: .hifi, source: .digital,
                                        border: false),
             overrides: [
                 .init("generation", "enabled", .bool(true)),
                 .init("generation", "generation", .float(3)),
             ] + wear("damage-snow", strength: 0.35, rate: 120, seed: 23)
               + wear("audio-damage-hifi", strength: 0.4, rate: 2, seed: 23)),
        Look(id: "attic-tape", name: "Attic Tape", category: .tape,
             blurb: "A camcorder tape thirty years in an attic on a worn deck: faded, creased, a clogging head, a sagging pitch.",
             selection: PresetSelection(tape: .sp, link: .composite, separator: .comb1, deck: .worn,
                                        trackingNoise: true, capture: .weave, audio: .wornLinear, source: .camcorder,
                                        border: false),
             overrides: [
                 .init("color-under", "gain", .float(DeckValues.aged.chromaGain)),
                 .init("levels", "black", .float(DeckValues.aged.blackIRE)),
                 .init("dropouts", "rate", .float(25)),
             ] + wear("damage-crease", strength: 0.5, rate: 4, seed: 37)
               + wear("damage-clog", strength: 0.5, rate: 1.5, seed: 37)
               + wear("audio-damage-glide", strength: 0.5, rate: 2, seed: 37)),
        Look(id: "off-air", name: "Off-Air", category: .tape,
             blurb: "Taped off broadcast TV: composite all the way, a notch filter's dot crawl and FM moire.",
             selection: PresetSelection(tape: .sp, link: .composite, separator: .notch, deck: .clean,
                                        trackingNoise: false, capture: .weave, audio: .hifi, source: .digital,
                                        border: false),
             overrides: [.init("luma-bandwidth", "moire", .float(0.05))]),
        Look(id: "wedding-video", name: "Wedding Video", category: .tape,
             blurb: "Camcorder footage edited to a master and dubbed to the couple's copy: warm, soft, one generation down.",
             selection: PresetSelection(tape: .sp, link: .composite, separator: .comb2, deck: .clean,
                                        trackingNoise: false, capture: .weave, audio: .hifi, source: .camcorder,
                                        border: false),
             overrides: [
                 .init("generation", "enabled", .bool(true)),
                 .init("generation", "generation", .float(2)),
             ]),
        Look(id: "six-hour-tape", name: "Six Hour Tape", category: .tape,
             blurb: "A whole night of TV on one EP tape on a good deck: the tuner's composite, a third of SP's speed, linear sound.",
             selection: PresetSelection(tape: .ep, link: .svideo, deck: .clean, trackingNoise: false, capture: .weave,
                                        audio: .epLinear, source: .digital, border: false),
             overrides: tunerComposite),
        Look(id: "hot-car", name: "Hot Car", category: .tape,
             blurb: "A movie left a summer in a hot car: the tape stretched and its edge warped, so it creases, tears and wows.",
             selection: PresetSelection(tape: .sp, link: .composite, separator: .comb1, deck: .clean,
                                        trackingNoise: true, capture: .weave, audio: .hifi, source: .digital,
                                        border: false),
             overrides: [
                 .init("time-base", "amplitude", .float(2)),
             ] + wear("damage-crease", strength: 0.45, rate: 6, seed: 6, [("tone", .choice(CreaseLayer.Tone.dark.rawValue))])
               + wear("damage-tear", strength: 0.5, rate: 4, seed: 6,
                      [("position", .choice(TrackingTearLayer.Position.anywhere.rawValue))])
               + wear("audio-damage-glide", strength: 0.6, rate: 4, seed: 6)),
        Look(id: "sticky-shed", name: "Sticky Shed", category: .tape,
             blurb: "An LP tape whose binder has gone sticky: oxide sheds onto the heads, so it clogs, snows and scrapes.",
             selection: PresetSelection(tape: .lp, link: .composite, separator: .comb1, deck: .aged,
                                        trackingNoise: false, capture: .weave, audio: .hifi, source: .digital,
                                        border: false),
             overrides: [
                 .init("dropouts", "rate", .float(40)),
             ] + wear("damage-clog", strength: 0.6, rate: 4, seed: 19)
               + wear("damage-snow", strength: 0.4, rate: 200, seed: 19)
               + wear("audio-damage-flutter", strength: 0.5, rate: 4, seed: 19)
               + wear("audio-damage-clog", strength: 0.5, rate: 4, seed: 19)),
        // Two film Looks, each a scan with the Tape off. Their names stay shorter than the
        // longest Look before them, since the Look menu takes its width from its longest name
        // and the first screen keeps its layout.
        Look(id: "super8-kodachrome", name: "Super 8", category: .film,
             blurb: "Super 8 Kodachrome 40 in daylight, scanned: a small frame's soft detail and fine grain, rich warm dyes.",
             selection: cleanSelection(),
             overrides: [.init("film", "enabled", .bool(true)), .init("tape", "enabled", .bool(false))]),
        Look(id: "sixteen-ektachrome-faded", name: "16mm Faded", category: .film,
             blurb: "16mm Ektachrome under lamps, thirty five years in the can: cyan and yellow dyes gone, so it runs magenta.",
             selection: cleanSelection(),
             overrides: [
                 .init("film", "enabled", .bool(true)),
                 .init("tape", "enabled", .bool(false)),
                 .init("film-format", "format", .choice(FilmFormat.sixteen.rawValue)),
                 .init("film-stock", "stock", .choice(FilmStock.ektachrome160.rawValue)),
                 .init("film-light", "light", .choice(FilmLight.tungsten.rawValue)),
                 .init("film-fade", "years", .float(35)),
                 .init("film-damage", "enabled", .bool(true)),
                 .init("film-damage", "dust", .float(0.3)),
                 .init("film-damage", "hair", .float(0.1)),
                 .init("film-damage", "scratches", .float(0.15)),
                 .init("film-damage", "seed", .float(16)),
             ]),
        // A Telecine Look: the film sent through the Telecine stage. Its name stays short for
        // the Look menu's width, as the film Looks' do.
        Look(id: "home-movie-transfer", name: "8mm to Tape", category: .telecine,
             blurb: "Super 8 Kodachrome on a screen, shot onto SP with a camcorder: the flicker beat, a hot spot, tube lag.",
             selection: PresetSelection(tape: .sp, link: .composite, separator: .comb1, deck: .aged,
                                        trackingNoise: false, capture: .weave, audio: .linear, source: .digital,
                                        border: false),
             overrides: [
                 .init("film", "enabled", .bool(true)),
                 .init("telecine", "enabled", .bool(true)),
             ]),
        // Two Looks that film the screen, the tube and the camera at their defaults.
        Look(id: "filmed-tv", name: "Filmed TV", category: .display,
             blurb: "A fresh SP tape on a tube TV, filmed off the screen with a phone: the rolling bar, moire, a little blue.",
             selection: freshSP(),
             overrides: filmed),
        Look(id: "phone-dub", name: "Phone Dub", category: .display,
             blurb: "A dub of a dub on a worn deck on a TV, filmed on a phone held upright at a low bitrate in a dim room.",
             selection: PresetSelection(tape: .lp, link: .composite, separator: .comb1, deck: .worn,
                                        trackingNoise: false, capture: .weave, audio: .hifi, source: .digital,
                                        border: false),
             overrides: [
                 .init("generation", "enabled", .bool(true)),
                 .init("generation", "generation", .float(3)),
             ] + filmed + [
                 // The phone held upright, Tight filling it, so Auto's file is 1080 by 1920.
                 .init("recapture", "camera", .choice(RecaptureCamera.phoneUpright.rawValue)),
                 .init("recapture", "framing", .choice(RecaptureFraming.tight.rawValue)),
                 .init("recapture-exposure", "bias", .float(0.5)),
                 .init("recapture-hand", "drift", .float(1.2)),
                 .init("recapture-processing", "bitrate", .float(8.5)),
             ]),
        // These Looks come after the rest so Shuffle's seeded rolls and the Tape presets keep
        // their order. Every name stays narrower than Wedding Video, the widest before them,
        // measured in the menu's font. Film first: each a scan, the Tape off, as Super 8 is.
        Look(id: "regular8-summer", name: "Summer Reel", category: .film,
             blurb: "Regular 8 Kodachrome on a bright summer day, scanned: a small frame, deep reds and blues, sun glints blooming.",
             selection: cleanSelection(),
             overrides: scan + [
                 .init("film-format", "format", .choice(FilmFormat.regular8.rawValue)),
                 .init("film-stock", "saturation", .float(1.35)),
                 .init("film-tone", "contrast", .float(1.25)),
                 .init("film-halation", "strength", .float(0.3)),
                 .init("film-halation", "threshold", .float(0.6)),
             ]),
        Look(id: "super8-living-room", name: "Living Room", category: .film,
             blurb: "Super 8 Ektachrome 160 at night by table lamps, a stop and a half under: heavy grain, warm, lamps blooming.",
             selection: cleanSelection(),
             overrides: scan + [
                 .init("film-stock", "stock", .choice(FilmStock.ektachrome160.rawValue)),
                 .init("film-light", "light", .choice(FilmLight.lowLight.rawValue)),
                 .init("film-light", "under", .float(0.5)),
                 .init("film-tone", "drift", .float(0.4)),
                 .init("film-grain", "strength", .float(0.75)),
                 .init("film-halation", "strength", .float(0.3)),
                 .init("film-halation", "threshold", .float(0.55)),
             ]),
        Look(id: "super8-estate-sale", name: "Estate Sale", category: .film,
             blurb: "Super 8 Ektachrome from the seventies, from an estate sale: fifty years faded to magenta, dust, hair, splices.",
             selection: cleanSelection(),
             overrides: scan + [
                 .init("film-stock", "stock", .choice(FilmStock.ektachrome160.rawValue)),
                 .init("film-fade", "years", .float(50)),
                 .init("film-damage", "enabled", .bool(true)),
                 .init("film-damage", "dust", .float(0.5)),
                 .init("film-damage", "hair", .float(0.25)),
                 .init("film-damage", "scratches", .float(0.3)),
                 .init("film-damage", "splices", .float(2)),
                 .init("film-damage", "seed", .float(74)),
             ]),
        Look(id: "sixteen-news", name: "16mm News", category: .film,
             blurb: "16mm Vision3 500T handheld outdoors at 24 fps, scanned: big fast grain, a soft negative curve, a steady gate.",
             selection: cleanSelection(),
             overrides: scan + [
                 .init("film-format", "format", .choice(FilmFormat.sixteen.rawValue)),
                 .init("film-stock", "stock", .choice(FilmStock.vision500T.rawValue)),
                 .init("film-shutter", "fps", .choice("24")),
                 .init("film-grain", "strength", .float(0.65)),
                 .init("film-tone", "drift", .float(0.3)),
             ]),
        Look(id: "thirtyfive-vision", name: "Cinema 35", category: .film,
             blurb: "35mm Vision3 50D in daylight at 24 fps, scanned: the finest grain, twelve stops of latitude, no flicker.",
             selection: cleanSelection(),
             overrides: scan + [
                 .init("film-format", "format", .choice(FilmFormat.thirtyFive.rawValue)),
                 .init("film-stock", "stock", .choice(FilmStock.vision50D.rawValue)),
                 .init("film-shutter", "fps", .choice("24")),
                 .init("film-shutter", "flicker", .float(0)),
                 .init("film-tone", "drift", .float(0)),
                 .init("film-optics", "vignette", .float(0.15)),
                 .init("film-optics", "softness", .float(0.1)),
             ]),
        // Telecine: the Film on and through the stage, the route and tier first since a tier
        // sets the route's sliders.
        Look(id: "mall-transfer", name: "Mall Transfer", category: .telecine,
             blurb: "Regular 8 Kodachrome through a mall kiosk's mirror box onto SP: five blade shutter, a CCD camera, even light.",
             selection: PresetSelection(tape: .sp, link: .composite, separator: .comb1, deck: .clean,
                                        trackingNoise: false, capture: .weave, audio: .linear, source: .digital,
                                        border: false),
             overrides: [
                 .init("film", "enabled", .bool(true)),
                 .init("film-format", "format", .choice(FilmFormat.regular8.rawValue)),
                 .init("telecine", "enabled", .bool(true)),
                 .init("telecine", "route", .choice(TelecineRoute.home.rawValue)),
                 .init("telecine", "quality", .choice(TelecineQuality.mid.rawValue)),
             ]),
        Look(id: "pro-scan", name: "Pro Scan", category: .telecine,
             blurb: "16mm Vision3 50D on a flying spot scanner, graded, straight to the master: 2:3 pulldown, almost no dust.",
             selection: cleanSelection(),
             overrides: scan + [
                 .init("film-format", "format", .choice(FilmFormat.sixteen.rawValue)),
                 .init("film-stock", "stock", .choice(FilmStock.vision50D.rawValue)),
                 .init("film-shutter", "fps", .choice("24")),
                 .init("telecine", "enabled", .bool(true)),
                 .init("telecine", "route", .choice(TelecineRoute.pro.rawValue)),
                 .init("telecine", "quality", .choice(TelecineQuality.pro.rawValue)),
             ]),
        // Display: the tape on the tube, filmed, as Filmed TV is, the camera set apart.
        Look(id: "tripod-tv", name: "Tripod TV", category: .display,
             blurb: "A fresh SP tape on a tube TV, filmed whole from a tripod: the bezel, curved corners, a lamp's glare, no shake.",
             selection: freshSP(),
             overrides: filmed + [
                 .init("recapture", "framing", .choice(RecaptureFraming.whole.rawValue)),
                 .init("recapture", "camera", .choice(RecaptureCamera.fourThree.rawValue)),
                 .init("recapture-hand", "drift", .float(0)),
                 .init("recapture-hand", "shake", .float(0)),
                 .init("recapture-hand", "yaw", .float(0)),
                 .init("recapture-glare", "strength", .float(0.1)),
             ]),
        Look(id: "up-close", name: "Up Close", category: .display,
             blurb: "A fresh SP tape filmed inches from a shadow mask tube: every red, green and blue phosphor dot shows.",
             selection: freshSP(),
             overrides: filmed + [
                 .init("crt-mask", "kind", .choice(CRTMaskLayer.Kind.shadowMask.rawValue)),
                 // The widest triad and the full mask, each the top of its slider, as the Close-up
                 // Mask Display preset sets them.
                 .init("crt-mask", "triad", .float(6)),
                 .init("crt-mask", "strength", .float(1)),
                 .init("recapture-lens", "defocus", .float(0)),
             ]),
    ]

    /// A film Look's start: the Film on and the Tape off, so it comes out as a scan.
    static let scan: [Look.Override] = [.init("film", "enabled", .bool(true)), .init("tape", "enabled", .bool(false))]

    /// The ids of the Looks that switch the Film source on. Every other Look has it off.
    public static let film: Set<String> = ["super8-kodachrome", "sixteen-ektachrome-faded", "home-movie-transfer",
                                           "regular8-summer", "super8-living-room", "super8-estate-sale", "sixteen-news",
                                           "thirtyfive-vision", "mall-transfer", "pro-scan"]

    /// The Look menu's order inside each section, the plainest first: Fresh SP, the default,
    /// then clean to worn, the film at the stage's defaults then further from them, the Telecine
    /// from the pro scan down, the Display from the camera's defaults out. `all` keeps its own
    /// order, which Shuffle's seeded rolls and the Tape stage presets read.
    static let menuOrder: [String] = [
        "clean-sp", "good-deck", "s-vhs", "off-the-tv", "off-air", "six-hour-tape", "camcorder", "wedding-video",
        "home-movie-1986", "transfer-1986", "rental", "dub-of-a-dub", "attic-tape", "hot-car", "sticky-shed",
        "super8-kodachrome", "regular8-summer", "thirtyfive-vision", "sixteen-news", "super8-living-room",
        "sixteen-ektachrome-faded", "super8-estate-sale",
        "pro-scan", "mall-transfer", "home-movie-transfer",
        "filmed-tv", "tripod-tv", "up-close", "phone-dub",
    ]

    /// The built-in Looks as the menu shows them: one section per category in `LookCategory`'s
    /// order, each in `menuOrder`. Custom is empty here. The user's presets go under it.
    public static var grouped: [(category: LookCategory, looks: [Look])] {
        let rank = Dictionary(uniqueKeysWithValues: menuOrder.enumerated().map { ($1, $0) })
        return LookCategory.allCases.compactMap { c in
            let looks = all.filter { $0.category == c }.sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
            return looks.isEmpty ? nil : (c, looks)
        }
    }

    /// The filmed Looks' Display and camera: every CRT layer and the Re-capture switch
    /// on, at their defaults.
    static let filmed: [Look.Override] =
        ["crt-transfer", "crt-beam", "crt-mask", "crt-glow", "crt-geometry", "crt-glass", "recapture"]
            .map { Look.Override($0, "enabled", .bool(true)) }

    public static func look(id: String) -> Look? { all.first { $0.id == id } }

    /// The ids, for error messages.
    public static var ids: String { all.map(\.id).joined(separator: "|") }

    /// The saved user presets as Looks (`UserPresets.refresh` sets them), listed after the
    /// built-in Looks and read back the same way.
    @MainActor public static var user: [Look] = []

    /// A built-in Look by id, else a user preset's.
    @MainActor public static func anyLook(id: String) -> Look? { look(id: id) ?? user.first { $0.id == id } }

    /// The chain each Look builds on fresh layers, made once per Look and remade when a Look
    /// of the same id changes (a user preset saved again under its name).
    @MainActor static var references: [String: (look: Look, vhs: VHSLayers, audio: AudioChain)] = [:]

    @MainActor static func reference(_ look: Look) -> (vhs: VHSLayers, audio: AudioChain) {
        if let r = references[look.id], r.look == look { return (r.vhs, r.audio) }
        let vhs = VHSLayers()
        let audio = AudioChain(preset: look.selection.audio ?? .hifi)
        let p = Presets(vhs: vhs)
        p.apply(look.selection)
        for o in look.overrides { apply(o, vhs: vhs, audio: audio) }
        // An older file that names Film's output: fold it into the stages.
        vhs.foldLegacyFilmOutput()
        references[look.id] = (look, vhs, audio)
        return (vhs, audio)
    }

    @MainActor static func apply(_ o: Look.Override, vhs: VHSLayers, audio: AudioChain?) {
        let layer: (any Layer)? = vhs.saved.first { $0.id == o.layer }
        if let layer {
            if o.parameter == "enabled", case .bool(let b) = o.value { layer.enabled = b } else { layer.setParameter(o.parameter, to: o.value) }
            return
        }
        // The Audio wear: a saved file lists it before its layers, so the wear moves the
        // preset's values and the saved values then land exactly as they were saved.
        if o.layer == AudioWear.id, let w = o.value.doubleValue {
            audio?.setWear(w)
            return
        }
        // The mic Strength, a value on the chain like the wear.
        if o.layer == AudioChain.strengthID, let s = o.value.doubleValue {
            audio?.setMicStrength(s)
            return
        }
        guard let a = audio?.allLayers.first(where: { $0.id == o.layer }) else { return }
        if o.parameter == "enabled", case .bool(let b) = o.value { a.enabled = b } else { a.setParameter(o.parameter, to: o.value) }
    }

    /// A layer's own switch as the user sets it: the output card's derived state (it is on
    /// whenever a later layer needs it) and the capture card's (it follows L1) do not count.
    @MainActor static func userSwitch(_ layer: any Layer) -> Bool? {
        if let card = layer as? OutputCardLayer { return card.userEnabled }
        if layer is CaptureLayer { return nil }
        return layer.enabled
    }

    static func same(_ a: ParameterValue, _ b: ParameterValue) -> Bool {
        if case .float(let x) = a, case .float(let y) = b { return Presets.same(x, y) }
        return a == b
    }

    static func same(_ a: [LayerParameter], _ b: [LayerParameter]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && same($0.value, $1.value) }
    }

    /// The Display and Re-capture stages alike in every switch and value.
    @MainActor static func sameDisplay(_ a: VHSLayers, _ b: VHSLayers) -> Bool {
        zip(a.crt.all + a.recapture.all, b.crt.all + b.recapture.all).allSatisfy { x, y in
            x.enabled == y.enabled && same(x.parameters, y.parameters)
        }
    }

    /// What choosing or resetting to `look` does to the Display and the camera: a file or a
    /// filmed Look that carries them sets them, any other Look switches the camera off and
    /// leaves the Display as it is.
    @MainActor static func applyDisplay(_ look: Look, from ref: VHSLayers, to vhs: VHSLayers) {
        if look.setsDisplay {
            CRTLayers.copy(ref.crt, to: vhs.crt)
            RecaptureLayers.copy(ref.recapture, to: vhs.recapture)
        } else {
            vhs.recapture.stage.enabled = false
        }
    }
}

extension Presets {
    /// The Look the chain matches in every layer switch and value (and the audio chain's,
    /// when there is one), a built-in Look first, then a saved user preset, else nil (Custom).
    public var look: Look? {
        Looks.all.first { matches($0) } ?? Looks.user.first { matches($0) }
    }

    func matches(_ look: Look) -> Bool {
        let ref = Looks.reference(look)
        // Damage sits on top of the Look: switching it on does not turn the picker to Custom.
        for (a, b) in zip(vhs.lookLayers, ref.vhs.lookLayers) where !(a is any DamageLayer) {
            guard Looks.userSwitch(a) == Looks.userSwitch(b), Looks.same(a.parameters, b.parameters) else { return false }
        }
        // The camera is part of a Look: a Look that films the screen matches only with its
        // Display and camera as it sets them, and any other Look only with the camera off.
        if look.filmsTheScreen {
            guard Looks.sameDisplay(vhs, ref.vhs) else { return false }
        } else if vhs.recaptureIsOn {
            return false
        }
        guard let audio else { return true }
        guard audio.preset == ref.audio.preset, audio.layers.count == ref.audio.layers.count,
              Presets.same(audio.micStrength, ref.audio.micStrength) else { return false }
        return zip(audio.layers, ref.audio.layers).allSatisfy { a, b in
            a.enabled == b.enabled && Looks.same(a.parameters, b.parameters)
        }
    }

    /// Resets every layer to the Look's chain: the layer switches and every value, through
    /// `setParameter`, then the audio preset and its values on the chain when there is one.
    /// The Damage layers are set too: a worn Look switches on its wear, every other
    /// Look switches Damage off, and a user preset or a clip's sidecar sets them as saved.
    public func setLook(_ look: Look) {
        let ref = Looks.reference(look)
        for (dst, src) in zip(vhs.lookLayers, ref.vhs.lookLayers) {
            if let card = dst as? OutputCardLayer, let from = src as? OutputCardLayer {
                card.userEnabled = from.userEnabled
            } else if !(dst is CaptureLayer) {
                dst.enabled = src.enabled
            }
            for p in src.parameters { dst.setParameter(p.id, to: p.value) }
        }
        // The Display stage is set only by a file that carries it (a preset or a sidecar saved
        // with one) or a Look that films the screen. Any other built-in Look
        // leaves the Display as it is and switches the camera off.
        Looks.applyDisplay(look, from: ref.vhs, to: vhs)
        guard let audio else { return }
        audio.preset = ref.audio.preset
        for (dst, src) in zip(audio.layers, ref.audio.layers) {
            dst.enabled = src.enabled
            for p in src.parameters { dst.setParameter(p.id, to: p.value) }
        }
        for (dst, src) in zip(audio.damage, ref.audio.damage) {
            dst.enabled = src.enabled
            for p in src.parameters { dst.setParameter(p.id, to: p.value) }
        }
        audio.restoreWear(ref.audio.wear)
        audio.setMicStrength(ref.audio.micStrength)
    }
}
