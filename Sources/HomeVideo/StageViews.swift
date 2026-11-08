import HomeVideoCore
import SwiftUI

/// The tab strip, one flow with the stages as rooms, drawn as room tabs. It holds the Look tab
/// and the tabs of the stages that are on, in flow order (`SidebarTab.visible`): Look, Tape and
/// Audio at launch. Each tab is an SF Symbol over a 9 pt word and a bar under the open one
/// (`StageRooms`), and the visible tabs share the width. Only the open tab is marked, so no
/// other tab reads as selected. A press only opens the tab. A stage comes and goes with its switch,
/// in its room's
/// header or in the Look tab's stage list. When the open room's stage goes off, the Look tab opens.
///
/// The whole drawing is here, in one view over the two models, so another treatment of the
/// strip replaces this file's `StageStrip` and nothing else.
struct StageStrip: View {
    let stages: StageSwitches
    let rooms: StageRooms

    /// Each tab's glyph, in one place so one can change alone. Every name is checked with
    /// `NSImage(systemSymbolName:)` (`projector` is not an SF Symbol and draws blank).
    static func glyph(_ tab: SidebarTab) -> String {
        switch tab {
        case .look: "camera.filters"
        case .stage(.film): "film"
        case .stage(.telecine): "videoprojector"
        case .stage(.tape): "recordingtape"
        case .stage(.display): "tv"
        case .stage(.audio): "waveform"
        case .stage(.recapture): "camera"
        }
    }

    var body: some View {
        let visible = SidebarTab.visible(stages)
        HStack(spacing: 0) {
            ForEach(visible) { tab in
                self.tab(tab).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: visible, initial: true) { _, now in rooms.follow(now) }
    }

    private func tab(_ tab: SidebarTab) -> some View {
        let stage = tab.stage
        let open = rooms.selected == tab
        return Button {
            rooms.choose(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: Self.glyph(tab))
                    .font(.system(size: 14))
                    .frame(height: 18)
                Text(tab.title)
                    .font(.system(size: 9, weight: open ? .semibold : .regular))
                    .fixedSize()
                Rectangle()
                    .fill(open ? Color.primary.opacity(0.85) : Color.clear)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
            .foregroundStyle(open ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The open tab's bar is the only mark: no focus ring stays on a tab once it is pressed.
        .focusEffectDisabled()
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// The stage list at the bottom of the Look tab, where the stages are switched on and off: one row
/// per stage in flow order,
/// Film, Telecine, Tape, Display, Audio, each its drawn switch and its name.
/// A row on adds the stage's tab, off takes it away. The room's own switch is the same
/// `StageSwitch` over the same `StageSwitches`, so the two always agree.
struct StageList: View {
    let switches: StageSwitches

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.rowGap) {
            ForEach(ChainStage.strip) { stage in
                StageListRow(switches: switches, stage: stage)
            }
        }
    }
}

/// One row of the stage list: the switch and the name at the leading end.
struct StageListRow: View {
    let switches: StageSwitches
    let stage: ChainStage

    var body: some View {
        let on = switches.switchIsOn(stage)
        HStack(spacing: 8) {
            StageSwitch(switches: switches, stage: stage)
            Text(stage.title)
                .foregroundStyle(on ? Color.primary : Color.secondary)
            Spacer(minLength: 8)
        }
        .frame(minHeight: 20)
    }
}

/// A room's slim header: the stage's name in the body size,
/// its "needs" note, then "On" or "Off" and the stage's drawn switch at the trailing end. The
/// tab above already names the room, so there is no big title.
struct RoomHeader: View {
    let switches: StageSwitches
    let stage: ChainStage

    var body: some View {
        let on = switches.switchIsOn(stage)
        HStack(spacing: 8) {
            Text(stage.title).font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let need = switches.need(stage) {
                Text(need).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(on ? "On" : "Off")
                .font(.caption)
                .foregroundStyle(on ? Color.primary : Color.secondary)
            StageSwitch(switches: switches, stage: stage)
        }
    }
}

/// A stage's switch, drawn at the mini switch's size rather than a `.switch` Toggle: added
/// system switches in the column move how Tahoe draws Framing's slider thumbs. Lit is on. Disabled
/// while the stage it needs is off.
struct StageSwitch: View {
    let switches: StageSwitches
    let stage: ChainStage

    var body: some View {
        let on = switches.switchIsOn(stage)
        let need = switches.need(stage)
        Button { switches.toggle(stage) } label: {
            Capsule()
                .fill(on ? Color.accentColor : Color.primary.opacity(0.18))
                .frame(width: 26, height: 15)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(Color.white).padding(1.5).shadow(radius: 0.5)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(need == nil ? 1 : 0.4)
        .disabled(need != nil)
        .help(need.map { "\(stage.title) \($0)" } ?? (on ? "Take out \(stage.title)" : "Add \(stage.title)"))
        .accessibilityLabel("\(stage.title) switch")
        .accessibilityValue(on ? "On" : "Off")
    }
}
