import Foundation
import Observation

/// The stages as the sidebar shows them: the picture's path in order, Film, Telecine,
/// Tape, Display, with Re-capture inside the Display, then the sound. Each is a switch over the
/// chain's own state, so a Look, a file or `--set` that turns a stage on lights it, and the
/// sidebar's switch moves exactly what those move.
public enum ChainStage: String, CaseIterable, Identifiable, Sendable {
    case film, telecine, tape, display, recapture, audio

    public var id: String { rawValue }

    /// The stages with a tab and a row in the Look tab's stage list, in path order. Re-capture
    /// is a switch inside the Display.
    public static let strip: [ChainStage] = [.film, .telecine, .tape, .display, .audio]

    public var title: String {
        switch self {
        case .film: "Film"
        case .telecine: "Telecine"
        case .tape: "Tape"
        case .display: "Display"
        case .recapture: "Re-capture"
        case .audio: "Audio"
        }
    }

    /// One line of what the stage is, for the chip's help.
    public var blurb: String {
        switch self {
        case .film: "Shot on film: a home movie camera and its stock, before everything."
        case .telecine: "The film put onto video, by a projector or a scanner."
        case .tape: "The round trip to tape."
        case .display: "The picture on a tube TV, after the tape."
        case .recapture: "A camera filming the tube's screen."
        case .audio: "The sound: the mic, the tape's track, wear and damage."
        }
    }
}

/// Reads and sets the stage switches on a chain built by `SignalChain.standard()`.
///
/// - Film, Telecine and Re-capture are their master layers' switches, Tape is the Tape stage's
///   (which carries the sound track with it).
/// - The Display has no master layer: it runs while any CRT layer is on. Off switches every CRT
///   layer off and holds the ones that were on, and on gives them back (every CRT layer, as the
///   filmed Looks set them, when none were held).
/// - Audio is on while it changes the sound, the camcorder mic or a tape track. Off holds the
///   mic, its Strength and the track with its layers as they stand, and plays the clip's own
///   sound. On gives them back (the default Linear track when none were held).
///
/// Nothing here is saved: a file carries the layers the switches move.
@MainActor
public final class StageSwitches {
    public let chain: SignalChain
    private var heldDisplay: Set<String>?

    public init(chain: SignalChain) {
        self.chain = chain
    }

    /// Lit: the stage changes what comes out. Re-capture needs the Display, so it reads off
    /// while the Display is off.
    public func isOn(_ stage: ChainStage) -> Bool {
        guard let vhs = chain.vhs else { return stage == .tape || (stage == .audio && chain.audio.isOn) }
        switch stage {
        case .film: return vhs.film.isOn
        case .telecine: return vhs.telecineInUse
        case .tape: return vhs.tape.enabled
        case .display: return vhs.crt.isOn
        case .recapture: return vhs.recaptureIsOn
        case .audio: return chain.audio.isOn
        }
    }

    /// The stage's own switch, which for Re-capture can be on while the Display it needs is off.
    public func switchIsOn(_ stage: ChainStage) -> Bool {
        guard let vhs = chain.vhs else { return isOn(stage) }
        switch stage {
        case .telecine: return vhs.telecine.isOn
        case .recapture: return vhs.recapture.stage.enabled
        default: return isOn(stage)
        }
    }

    /// "needs Display" for Re-capture while the Display is off, else nil. Telecine needs nothing:
    /// with the Film off it transfers the clip itself.
    public func need(_ stage: ChainStage) -> String? {
        switch stage {
        case .recapture where !isOn(.display): return "needs Display"
        default: return nil
        }
    }

    public func set(_ stage: ChainStage, on: Bool) {
        if stage == .audio {
            chain.audio.setOn(on)
            return
        }
        guard let vhs = chain.vhs else { return }
        switch stage {
        case .film: vhs.film.source.enabled = on
        case .telecine: vhs.telecine.source.enabled = on
        case .tape: vhs.tape.enabled = on
        case .recapture: vhs.recapture.stage.enabled = on
        case .display:
            guard on != vhs.crt.isOn else { return }
            if on {
                let held = heldDisplay ?? []
                for l in vhs.crt.layers { l.enabled = held.isEmpty || held.contains(l.id) }
                heldDisplay = nil
            } else {
                heldDisplay = Set(vhs.crt.layers.filter(\.enabled).map(\.id))
                vhs.crt.allOff()
            }
        case .audio: break
        }
    }

    public func toggle(_ stage: ChainStage) {
        set(stage, on: !switchIsOn(stage))
    }

    /// Drops what the Display and Audio switches held, as at launch, so the next on gives the
    /// launch defaults (every CRT layer, the default track). Reset calls it.
    public func forgetHeld() {
        heldDisplay = nil
        chain.audio.forgetHeld()
    }
}

/// The sidebar's tabs. The first tab is not a stage: it holds the Look, Framing, the Output size
/// and the stage list. Then the stages in flow order, the way the picture and the sound travel.
/// Only the stages that are on show.
public enum SidebarTab: Hashable, Sendable, Identifiable {
    case look
    case stage(ChainStage)

    /// The first tab's name, in one place.
    public static let firstTitle = "Look"

    /// Every tab in flow order: the Look tab, then Film, Telecine, Tape, Display and Audio.
    public static let all: [SidebarTab] = [.look] + ChainStage.strip.map { .stage($0) }

    /// The tabs the strip shows: the Look tab always, a stage's tab while its own switch is on.
    /// At launch that is Look, Tape and Audio.
    @MainActor public static func visible(_ switches: StageSwitches) -> [SidebarTab] {
        all.filter { tab in tab.stage.map(switches.switchIsOn) ?? true }
    }

    public var id: String { stage?.rawValue ?? "look" }
    public var title: String { stage?.title ?? Self.firstTitle }
    public var stage: ChainStage? {
        if case .stage(let s) = self { return s }
        return nil
    }

    /// A launch argument's word: "look", or a stage on the strip.
    public init?(word: String) {
        if word == "look" || word == "start" {
            self = .look
        } else if let s = ChainStage(rawValue: word), Self.all.contains(.stage(s)) {
            self = .stage(s)
        } else {
            return nil
        }
    }
}

/// Which tab the sidebar shows, each stage a room. Kept apart from `StageSwitches`, which says
/// which stages are in use: a stage stays on while another room shows. An off stage has no tab,
/// so the strip calls `follow` whenever the visible tabs change and a room whose stage went off
/// gives way to the Look tab.
@MainActor
@Observable
public final class StageRooms {
    /// The tab showing. The Look tab at launch.
    public var selected: SidebarTab = .look

    public init() {}

    /// A press on a tab only opens it. Only the room's switch, a Look, a stage preset or a file
    /// turns a stage on.
    public func choose(_ tab: SidebarTab) {
        selected = tab
    }

    /// The Look tab opens when the open room's tab is no longer shown (its stage went off from
    /// the room's switch, the stage list, a Look, a file or Reset). Any other room stays open.
    public func follow(_ visible: [SidebarTab]) {
        if !visible.contains(selected) { selected = .look }
    }
}

