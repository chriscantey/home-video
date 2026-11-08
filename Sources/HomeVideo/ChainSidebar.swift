import AppKit
import HomeVideoCore
import SwiftUI

/// The sidebar: the stage strip pinned under the title row, then a scrolling column with the
/// open tab, the Look tab at launch. The Look tab holds the Look picker with its blurb and the
/// saved presets, Framing, the Output size and the stage list. The Tape's room is Tune: the
/// component pickers (Source, Tape, Link, Deck, Capture with their switches), every picture
/// layer as its own collapsed group in chain order, then Damage. Framing is left out of Tune's
/// list because it is on the Look tab. The file name is in the window title.
struct ChainSidebar: View {
    @Bindable var model: AppModel

    /// The sidebar's width beside the viewer column. 296 keeps the minimum window at 960
    /// (180 + 1 + 480 + 1 + 296 = 958).
    static let width: CGFloat = 296

    /// The legacy scroll bar's width when the system shows one, else 0.
    @State private var scrollerWidth = ChainSidebar.reservedScrollerWidth()

    var body: some View {
        VStack(spacing: 0) {
            // The path as a strip above the column, pinned under the title row, one tab per
            // stage's room. The strip's drawing is its own view, so another treatment replaces it whole.
            // No bottom padding: the open room's bar sits on the rule, as a tab does.
            StageStrip(stages: model.stages, rooms: model.rooms)
                .padding(.horizontal, Self.inset)
                .padding(.top, 10)
            Divider()
            column
        }
    }

    /// The scrolling column: the Look tab or the open stage's room.
    var column: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionGap) {
                switch model.rooms.selected {
                case .look: lookTab
                case .stage(let stage): room(stage)
                }
            }
            // The column rule: every row is offered exactly the column inside its insets. A
            // vertical ScrollView otherwise takes its widest child's width, so one wide control
            // (a 322 pt segmented picker) widens the whole column past both of the frame's edges.
            // A legacy scroll bar (a mouse attached, or "Show scroll bars: Always") takes its
            // width out of the scroll view's clip, so that width comes off the rows too, or the
            // rows overhang the clip and push the bar off the window's edge.
            .frame(width: Self.width - 2 * Self.inset - scrollerWidth, alignment: .leading)
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 16)
            // The id sits on the padded column, so a new room comes back to the launch position
            // (on the Look section it would stop 16 pt short, under the strip's rule).
            .id(Self.topID)
        }
        // The bar's ends stay clear of the toolbar and the window's rounded bottom corner.
        .contentMargins(.vertical, 6, for: .scrollIndicators)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerWidth = Self.reservedScrollerWidth()
        }
        // Another room starts at the top of the column, as a page does, not at the last room's
        // scroll offset.
        .onChange(of: model.rooms.selected) { _, _ in
            proxy.scrollTo(Self.topID, anchor: .top)
        }
        }
    }

    /// The space between the column's edges and its rows.
    static let inset: CGFloat = 20

    /// How far a section's rows sit in from its header, and a layer's controls from its title.
    static let indent: CGFloat = 12

    /// The column's vertical rhythm, in order: sections apart more than groups, groups more than
    /// rows, rows more than a label from its own control.
    /// Between the sections (Look, Framing, Tune, Damage) and their dividers.
    static let sectionGap: CGFloat = 28
    /// Above and below every divider, on top of the gap around it.
    static let dividerAir: CGFloat = 6
    /// From a section's header to its first row.
    static let headerGap: CGFloat = 14
    /// Between Tune's pickers, Damage's layers and the layer groups.
    static let groupGap: CGFloat = 20
    /// Between the rows of the Look and Framing sections and a layer's sliders, and from a
    /// layer's title to its first slider. A label to its slider is 4.
    static let rowGap: CGFloat = 12

    // MARK: The rooms

    /// The id the column scrolls back to when another room is chosen.
    static let topID = "sidebar-top"

    /// The Look tab, the first tab and not a stage: the Look picker with its icon row,
    /// Framing, the Output size, and the stage list. The tab names the Look, so the
    /// picker's own label reads Preset and the tab does not say Look twice.
    @ViewBuilder var lookTab: some View {
        SidebarSection(title: "Preset", spacing: Self.rowGap) {
            LookPicker(presets: model.presets, userPresets: model.userPresets.presets) { model.lookPicked = true }
            // Once a Look is picked, what it set on the other tabs, as their menus read.
            if model.lookPicked {
                Text(model.stagePresets.readback(model.chain, switches: model.stages))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Stages set by the Look")
            }
            PresetIconRow(model: model, shown: model.shownUserPreset)
        }
        SidebarDivider()
        SidebarSection(title: "Framing", spacing: Self.rowGap) {
            FramingSection(framing: model.chain.framing)
        }
        if let output = model.chain.vhs?.output {
            SidebarDivider()
            SidebarSection(title: "Output size", spacing: Self.rowGap) {
                OutputSizeSection(output: output, chain: model.chain)
            }
        }
        // The stages switched from a list, each one on showing as a tab.
        SidebarDivider()
        SidebarSection(title: "Stages", spacing: Self.rowGap) {
            Text("Switch a stage on to give it a tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            StageList(switches: model.stages)
        }
    }

    /// One stage's room: a slim header with the stage's name, its "needs" note, On or
    /// Off and its drawn switch, then the stage's own controls. The Tape's room is
    /// Tune with the Damage under it, the Audio's the Audio section, the Display's the
    /// CRT layers with Re-capture inside.
    @ViewBuilder func room(_ stage: ChainStage) -> some View {
        VStack(alignment: .leading, spacing: Self.headerGap) {
            RoomHeader(switches: model.stages, stage: stage)
            VStack(alignment: .leading, spacing: Self.groupGap) { roomControls(stage) }
                .padding(.leading, Self.indent)
        }
    }

    /// Each room starts with its stage presets, one menu and its icon row directly under
    /// the stage's switch, then its controls. The Look above stays the whole chain's preset.
    @ViewBuilder func roomControls(_ stage: ChainStage) -> some View {
        if let vhs = model.chain.vhs {
            switch stage {
            case .film:
                StagePresetMenu(stage: .film, model: model)
                FilmSection(film: vhs.film, groupBinding: groupBinding)
            case .telecine:
                // Live with the Film off too: then the clip itself is transferred.
                StagePresetMenu(stage: .telecine, model: model)
                TelecineSection(vhs: vhs, groupBinding: groupBinding)
            case .tape:
                // The menu stays live while the Tape is off: its presets are one way back on.
                StagePresetMenu(stage: .tape, model: model)
                Text("The round trip to tape and back. Off, the picture skips the tape and the mic plays alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // While the Tape is off nothing below reaches the picture, so it reads dimmed and
                // waits.
                let tapeOn = vhs.tape.enabled
                Group {
                    tuneList
                    SidebarDivider()
                    Text("Damage").font(.headline)
                    DamageSection(model: model, groupBinding: groupBinding)
                }
                .opacity(tapeOn ? 1 : 0.5)
                .disabled(!tapeOn)
            case .display, .recapture:
                StagePresetMenu(stage: .display, model: model)
                DisplaySection(crt: vhs.crt, recapture: vhs.recapture, groupBinding: groupBinding)
            case .audio:
                StagePresetMenu(stage: .audio, model: model)
                AudioSection(audio: model.chain.audio, groupBinding: groupBinding)
            }
        }
    }

    /// Tune's list: the component pickers, then every picture layer as its own collapsed group.
    @ViewBuilder var tuneList: some View {
        PresetBar(presets: model.presets)
        SidebarDivider()
        ForEach(Array(model.chain.effects.enumerated()), id: \.offset) { _, layer in
            // The on-screen display is a Capture switch in the pickers, the Damage layers have
            // their own section below, and a layer nobody can change (the Output card) is
            // not listed.
            if !(layer is OSDLayer) && !(layer is any DamageLayer) && LayerTitle.isListed(layer) {
                LayerGroup(title: LayerTitle.display(layer.name), isOpen: groupBinding(layer.id),
                           isOn: layer.isRequired ? nil : Binding(get: { layer.enabled },
                                                                  set: { layer.enabled = $0 }),
                           opens: !layer.parameters.isEmpty) {
                    LayerControls(parameters: layer.parameters, enabled: layer.enabled) {
                        layer.setParameter($0, to: $1)
                    }
                }
            }
        }
    }

    static func reservedScrollerWidth() -> CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    /// A layer group's open state, kept on the model for the session (all collapsed at launch).
    func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.openLayerGroups.contains(id) },
                set: { open in
                    if open { model.openLayerGroups.insert(id) } else { model.openLayerGroups.remove(id) }
                })
    }
}

/// One section of the sidebar: its header at the column's leading edge, its rows indented
/// under it, so the structure reads at a glance.
struct SidebarSection<Content: View>: View {
    let title: String
    var spacing: CGFloat = ChainSidebar.groupGap
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.headerGap) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
            }
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.leading, ChainSidebar.indent)
        }
    }
}

/// A rule between sections, with air above and below it.
struct SidebarDivider: View {
    var body: some View {
        Divider().padding(.vertical, ChainSidebar.dividerAir)
    }
}

/// Damage, under Tune in the Tape's room: the
/// picture's damage events, each a collapsed group with its switch, then Strength, Seed and its
/// own parameters. The sound's live in the Audio section beside the Audio wear. A Look
/// sets them: the worn Looks switch on their wear, every other Look switches them off.
struct DamageSection: View {
    let model: AppModel
    let groupBinding: (String) -> Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
            Text("Worn tape and a tired deck, now and then. The worn Looks set some. The same seed lands the same events.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array((model.chain.vhs?.damage.all ?? []).enumerated()), id: \.offset) { _, layer in
                LayerGroup(title: LayerTitle.display(layer.name), isOpen: groupBinding(layer.id),
                           isOn: Binding(get: { layer.enabled }, set: { layer.enabled = $0 }),
                           opens: !layer.parameters.isEmpty) {
                    LayerControls(parameters: layer.parameters, enabled: layer.enabled) {
                        layer.setParameter($0, to: $1)
                    }
                }
            }
        }
    }
}

/// Display, the Display's room: the tube the tape is watched on. The Display size,
/// then the six CRT layers in docs/CRT.md's order, each a collapsed group with its switch,
/// off by default and on in the Display Looks. With any of them on the preview and the export draw the
/// Display canvas, and a pinch on the picture comes up close to the mask.
struct DisplaySection: View {
    let crt: CRTLayers
    /// The camera that films the screen, nil on a chain not built by `standard()`.
    var recapture: RecaptureLayers? = nil
    let groupBinding: (String) -> Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
            Text("The picture on a tube TV: its gamma and white, the beam's lines, the phosphor mask, the glass. Off, the picture is as captured. Pinch to look up close.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LayerControls(parameters: crt.display.parameters, enabled: true) {
                crt.display.setParameter($0, to: $1)
            }
            // The Detail is how fine the tube is drawn, never the file's size.
            Text("Detail is how fine the tube is drawn. The file's size is the Output size on the Look tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(crt.layers.enumerated()), id: \.offset) { _, layer in
                LayerGroup(title: LayerTitle.display(layer.name), isOpen: groupBinding(layer.id),
                           isOn: Binding(get: { layer.enabled }, set: { layer.enabled = $0 }),
                           opens: !layer.parameters.isEmpty) {
                    LayerControls(parameters: layer.parameters, enabled: layer.enabled) {
                        layer.setParameter($0, to: $1)
                    }
                }
            }
            if let recapture {
                RecaptureSection(crt: crt, recapture: recapture, groupBinding: groupBinding)
            }
        }
    }
}

/// Re-capture, the last group in the Display's room: a
/// camera filming the tube's screen. Inside Display, not a sibling row, because it films the
/// Display's canvas and runs only with a CRT layer on. Its switch is a layer group's, drawn as the
/// Display's layers draw theirs. Off by default, dimmed with "needs Display" while every CRT layer
/// is off.
struct RecaptureSection: View {
    let crt: CRTLayers
    let recapture: RecaptureLayers
    let groupBinding: (String) -> Binding<Bool>

    var body: some View {
        let stage = recapture.stage
        let live = crt.isOn
        LayerGroup(title: LayerTitle.display(stage.name), isOpen: groupBinding(stage.id),
                   isOn: Binding(get: { stage.enabled }, set: { stage.enabled = $0 }), opens: true) {
            VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
                Text(live ? "A camera films the screen: the shutter's rolling bar, the sensor's moire, the hand, the phone's processing."
                          : "Re-capture needs Display: switch on a CRT layer first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LayerControls(parameters: stage.parameters, enabled: stage.enabled && live) {
                    stage.setParameter($0, to: $1)
                }
                ForEach(Array(recapture.layers.enumerated()), id: \.offset) { _, layer in
                    LayerGroup(title: LayerTitle.display(layer.name), isOpen: groupBinding(layer.id),
                               isOn: Binding(get: { layer.enabled }, set: { layer.enabled = $0 }),
                               opens: !layer.parameters.isEmpty) {
                        LayerControls(parameters: layer.parameters, enabled: layer.enabled && stage.enabled && live) {
                            layer.setParameter($0, to: $1)
                        }
                    }
                }
            }
        }
        .opacity(live ? 1 : 0.5)
        .help(live ? "" : "needs Display")
    }
}

/// Film: what a home movie camera and its stock do, ahead of everything. The room's header
/// carries the stage switch, so the Film's own values sit directly under the blurb, then each
/// Film layer as a collapsed group. Where the film goes is the stages' switches: with the Tape
/// on it goes onto the tape, with it off it is a film scan.
struct FilmSection: View {
    let film: FilmLayers
    let groupBinding: (String) -> Binding<Bool>

    var sourceParameters: [LayerParameter] { film.source.parameters }

    /// The Scan detail is how fine the film is scanned, never the file's size (as the Display's
    /// Detail).
    static var scanCaption: some View {
        Text("Scan detail is how fine the film is scanned. The file's size is the Output size on the Look tab.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
            Text("Shot on film instead of a camcorder: gauge, stock, light, grain. With the tape on it goes onto the tape, with it off it is a film scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LayerControls(parameters: sourceParameters, enabled: film.source.enabled) {
                film.source.setParameter($0, to: $1)
            }
            Self.scanCaption
            ForEach(Array(film.all.dropFirst().enumerated()), id: \.offset) { _, layer in
                LayerGroup(title: layer.name, isOpen: groupBinding(layer.id),
                           isOn: Binding(get: { layer.enabled }, set: { layer.enabled = $0 })) {
                    LayerControls(parameters: layer.parameters, enabled: layer.enabled && film.isOn) {
                        layer.setParameter($0, to: $1)
                    }
                }
            }
        }
    }
}

/// Telecine: how the film became video, between Film and the tape. The room's header carries
/// the stage switch, as for the Film, so the route and the quality tier sit under the blurb,
/// then the route's own layers as collapsed groups. On, the film goes through the transfer.
struct TelecineSection: View {
    let vhs: VHSLayers
    let groupBinding: (String) -> Binding<Bool>

    var body: some View {
        let t = vhs.telecine
        VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
            Text("The film transferred to video: a projector shot by a camcorder at home, or a telecine scanner. With Film off, the clip itself is the film. Then the tape, or with it off the transfer as it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LayerControls(parameters: t.source.parameters, enabled: t.source.enabled) {
                t.source.setParameter($0, to: $1)
            }
            ForEach(Array(t.layers(for: t.route).enumerated()), id: \.offset) { _, layer in
                LayerGroup(title: layer.name, isOpen: groupBinding(layer.id),
                           isOn: Binding(get: { layer.enabled }, set: { layer.enabled = $0 })) {
                    LayerControls(parameters: t.parameters(of: layer, route: t.route),
                                  enabled: layer.enabled && vhs.telecineInUse) {
                        layer.setParameter($0, to: $1)
                    }
                }
            }
        }
    }
}

/// Framing under the Look: the framing layer's own parameters (Mode, Pan, and whatever else
/// the layer lists, such as Rotation or Zoom), built from its parameter list.
struct FramingSection: View {
    let framing: FramingLayer

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.rowGap) {
            ForEach(framing.parameters) { p in
                ParameterControl(parameter: p) { framing.setParameter(p.id, to: $0) }
                    .disabled(!p.isActive)
            }
        }
    }
}

/// The Output size on the Look tab: one menu, Custom's width and height fields, and one line
/// saying what the file will be.
struct OutputSizeSection: View {
    let output: OutputSizeLayer
    let chain: SignalChain

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.rowGap) {
            MenuRow(title: "Size") {
                Picker("Size", selection: Binding(get: { output.size },
                                                  set: { output.setParameter("size", to: .choice($0.rawValue)) })) {
                    ForEach(OutputSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            if output.size == .custom {
                HStack(spacing: 6) {
                    field("Width", output.width) { output.setParameter("width", to: .float($0)) }
                    Text("×").foregroundStyle(.secondary)
                    field("Height", output.height) { output.setParameter("height", to: .float($0)) }
                }
            }
            // A size that is not 4:3 can take the chain's 4:3 picture inside it (the
            // default) or have every stage work at its shape so the picture fills it.
            if chain.fillApplies {
                MenuRow(title: "Picture") {
                    Picker("Picture", selection: Binding(get: { output.fill },
                                                         set: { output.setParameter("fill", to: .bool($0)) })) {
                        // Short, so the row keeps its "Picture" label (the longer "4:3 inside the
                        // frame" truncates it to "Pic...").
                        Text("4:3 inside").tag(false)
                        Text("Fill the frame").tag(true)
                    }
                }
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        let s = chain.outputSize
        let size = "\(s.width)×\(s.height)"
        if output.isAuto { return "The size the last stage makes, \(size) now. Pick one to fix the file's size." }
        if chain.fillAspect != nil {
            return "The file is \(size). Every stage works at its shape, so the picture fills it edge to edge."
        }
        return "The file is \(size) whatever the stages do. The picture fits inside whole, black bars where the shapes differ."
    }

    /// A number field that clamps to an even size in range when it is committed.
    private func field(_ title: String, _ value: Int, set: @escaping (Double) -> Void) -> some View {
        TextField(title, value: Binding(get: { value }, set: { set(Double($0)) }), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
            .accessibilityLabel(title)
    }
}


// MARK: - Looks

/// The named Looks in a menu, one header per section (Tape, Film, Telecine, Display,
/// then Custom for the user's presets), "Custom" when the chain matches none of them, the
/// Look's blurb as its help.
struct LookPicker: View {
    let presets: Presets
    /// The saved user presets, listed under the Custom header after the built-in Looks.
    let userPresets: [UserPreset]
    /// Called after a Look is picked here.
    var picked: () -> Void = {}

    var body: some View {
        let current = presets.look
        let order = UserPresets.pickerOrder(user: userPresets)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Look", selection: Binding(get: { current?.id ?? "" },
                                              set: { id in
                                                  if let l = Looks.anyLook(id: id) { presets.setLook(l); picked() }
                                              })) {
                if current == nil { Text("Custom").tag("") }
                ForEach(order.builtIn, id: \.category) { section in
                    Section(section.category.title) {
                        ForEach(section.looks) { Text($0.name).tag($0.id).help($0.blurb) }
                    }
                }
                // The user's own presets under the Custom header, none without them.
                if !order.user.isEmpty {
                    Section(LookCategory.custom.title) {
                        ForEach(order.user) { Text($0.name).tag($0.id).help($0.look.blurb) }
                    }
                }
            }
            .sidebarMenu()
            .labelsHidden()
            .help(current?.blurb ?? "Custom: a picker or slider has moved off every Look.")
            .accessibilityLabel("Look")
            Text(current?.blurb ?? "Custom: a picker or slider has moved off every Look.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The preset actions under the Look's blurb as one row of icon buttons: borderless SF Symbols
/// in 22 by 18 frames (26 by 18 at the trailing end), the list's own actions at the leading end
/// and the file actions at the trailing end, the words under each glyph and in its accessibility
/// label. Plus to add (Save), pencil for Rename, trash for a delete that removes the file, and
/// the square and arrow for Import and Export. Rename and Delete act on the shown user preset
/// and are disabled on a built-in Look, so the row never changes shape. A SwiftUI menu picker's
/// items take no right-click, so the controls sit here. Reset follows Delete: the
/// counterclockwise arrow, back to a fresh launch, lit while anything differs from one.
/// Shuffle follows Reset: the dice, a random tape on a random Look, on with a clip open.
struct PresetIconRow: View {
    let model: AppModel
    /// The user preset the chain reads back as, nil on a built-in Look or Custom. Read in the
    /// sidebar's body and passed in: the presets folder is not observed, so this row's own body
    /// is not asked again after a save.
    let shown: UserPreset?
    @State private var renaming: UserPreset?
    @State private var deleting: UserPreset?
    // A word under every glyph, always visible, so nothing needs a hover, and no tooltips to
    // collide with each other. The row starts under the Look picker's indent, so it has 244 pt:
    // at 9 pt the seven columns measure 202 pt, and with 4 pt spacing and a 4 pt least gap the
    // row takes 234 (caption2 is 10 pt here and runs the words together).
    var body: some View {
        HStack(spacing: 4) {
            icon("plus", "Save Preset", word: "Save") {
                model.showSavePresetPanel()
            }
            icon("pencil", "Rename Preset", word: "Rename", disabled: shown == nil) {
                renaming = shown
            }
            icon("trash", "Delete Preset", word: "Delete", disabled: shown == nil) {
                deleting = shown
            }
            // Back to a fresh launch: Fresh SP, only Tape and Audio on, the Look tab open. Lit
            // while anything differs from a fresh launch.
            icon("arrow.counterclockwise", "Reset to Fresh Start", word: "Reset", disabled: !model.canReset) {
                model.resetToFreshStart()
            }
            // A random tape on a random Look, a fresh seed every press.
            icon("dice", "Shuffle", word: "Shuffle", disabled: model.source == nil) {
                model.shuffle()
            }
            Spacer(minLength: 4)
            icon("square.and.arrow.down", "Import Preset", word: "Import", width: 26) {
                model.showImportPresetPanel()
            }
            icon("square.and.arrow.up", "Export Preset", word: "Export", width: 26) {
                model.showExportPresetPanel()
            }
        }
        .buttonStyle(.borderless)
        // Neutral glyphs, not the app's pink accent.
        .tint(Color.secondary)
        .sheet(item: $renaming) { p in
            RenamePresetSheet(preset: p) { model.renamePreset(p, to: $0) }
        }
        .confirmationDialog("Delete the preset “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { p in
            Button("Delete", role: .destructive) { model.deletePreset(p) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("\(p.url.lastPathComponent) is removed from the Presets folder. The picture goes back to \(UserPresets.baseLook(of: p).name).")
        }
    }

    /// One glyph button with its word, a 9 pt line under the glyph. The word takes the dimmed style
    /// itself, since its own foreground style is not dimmed by the button.
    private func icon(_ symbol: String, _ label: String, word: String, width: CGFloat = 22,
                      disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).frame(width: width, height: 18)
                Text(word)
                    .font(.system(size: 9))
                    .foregroundStyle(disabled ? HierarchicalShapeStyle.tertiary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .disabled(disabled)
    }
}

/// The Rename sheet: the name field, filled with the preset's name, and Rename or Cancel.
struct RenamePresetSheet: View {
    let preset: UserPreset
    let rename: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(preset: UserPreset, rename: @escaping (String) -> Void) {
        self.preset = preset
        self.rename = rename
        _name = State(initialValue: preset.name)
    }

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Preset").font(.headline)
            Text("Renames \(preset.name) and its file in the Presets folder. A name already in use gets a number.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Preset name", text: $name)
                .onSubmit { if !trimmed.isEmpty { commit() } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commit() {
        rename(name)
        dismiss()
    }
}

// MARK: - Presets

struct PresetBar: View {
    let presets: Presets

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
            PresetRow(title: "Source", isCustom: presets.source == nil) {
                Picker("Source", selection: Binding(get: { presets.source }, set: { if let s = $0 { presets.setSource(s) } })) {
                    ForEach(SourcePreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .disabled(presets.vhs.film.isOn)
            } sub: {
                // Film replaces the camera stage while it is on.
                if presets.vhs.film.isOn {
                    Text("Film is on: the film camera shot it.").font(.caption).foregroundStyle(.secondary)
                }
            }

            PresetRow(title: "Tape", isCustom: presets.tape == nil) {
                Picker("Tape", selection: Binding(get: { presets.tape }, set: { if let t = $0 { presets.setTape(t) } })) {
                    ForEach(TapePreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
            }

            PresetRow(title: "Link", isCustom: presets.link == nil) {
                Picker("Link", selection: Binding(get: { presets.link }, set: { if let l = $0 { presets.setLink(l) } })) {
                    ForEach(LinkPreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
            } sub: {
                if presets.link == .composite {
                    SubRow {
                        MenuRow(title: "Separator") {
                            Picker("Separator", selection: Binding(get: { presets.separator },
                                                                   set: { presets.setSeparator($0) })) {
                                ForEach(Separator.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                        }
                    }
                }
            }

            PresetRow(title: "Deck", isCustom: presets.deck == nil) {
                Picker("Deck", selection: Binding(get: { presets.deck }, set: { if let d = $0 { presets.setDeck(d) } })) {
                    ForEach(DeckPreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
            } sub: {
                SwitchRow(title: "Tracking noise", isOn: Binding(get: { presets.trackingNoise },
                                                                  set: { presets.setTrackingNoise($0) }))
            }

            PresetRow(title: "Capture", isCustom: false) {
                Picker("Capture", selection: Binding(get: { presets.capture }, set: { presets.setCapture($0) })) {
                    ForEach(CapturePreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } sub: {
                VStack(alignment: .leading, spacing: ChainSidebar.rowGap) {
                    if presets.capture == .weave {
                        SubRow {
                            SwitchRow(title: "Temporal fields", isOn: Binding(get: { presets.temporalFields },
                                                                               set: { presets.setTemporalFields($0) }))
                        }
                    }
                    SwitchRow(title: "Capture border", isOn: Binding(get: { presets.border },
                                                                     set: { presets.setBorder($0) }))
                    SwitchRow(title: "VCR on-screen display", isOn: Binding(get: { presets.osd },
                                                                            set: { presets.osd = $0 }))
                }
            }

            // The Audio picker and the Audio wear are in the Audio section.
        }
        .animation(.easeOut(duration: 0.15), value: presets.link)
        .animation(.easeOut(duration: 0.15), value: presets.deck)
        .animation(.easeOut(duration: 0.15), value: presets.capture)
    }
}

/// One preset picker: its title, a "Custom" note when a slider has moved off every preset
/// (no segment is selected then, and Custom itself is not a choice), the segmented control,
/// then its sub-selection.
struct PresetRow<Control: View, Sub: View>: View {
    let title: String
    let isCustom: Bool
    @ViewBuilder let control: Control
    @ViewBuilder let sub: Sub

    init(title: String, isCustom: Bool, @ViewBuilder control: () -> Control,
         @ViewBuilder sub: () -> Sub = { EmptyView() }) {
        self.title = title
        self.isCustom = isCustom
        self.control = control()
        self.sub = sub()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                if isCustom {
                    Text("Custom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                }
            }
            FittingPicker { control }
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(isCustom ? "Custom" : "")
            sub
        }
    }
}

/// A picker as a segmented control when its segments fit the column, a menu when they do not
/// (a five-segment picker's segments are 322 pt, the column inside its insets 248). A
/// segmented control never shrinks below its segments, so it is never offered past the column.
struct FittingPicker<Control: View>: View {
    @ViewBuilder let control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            control.pickerStyle(.segmented).fixedSize()
            control.sidebarMenu().fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A label with a menu picker trailing at the row's end, on one line like a `SwitchRow`, so it
/// reads plainly as a drop-down. The picker
/// is the system's bordered menu style, the same control as the Framing section's Mode and
/// Rotation menus, with its chevrons and the current choice as its title, sized to its title so
/// it never reaches past the column.
struct MenuRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            control
                .sidebarMenu()
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(title)
        }
    }
}

/// Every menu picker in the sidebar. On Tahoe's dark sidebar the system pop-up button is a gray
/// fill a few levels
/// above the background, so it reads as a label. A 1 pt rim at the bezel's own corner radius
/// gives it the edge a pop-up has in System Settings, and the system draws the title and the
/// chevrons inside as before. The rim follows the control's frame, so it holds at every window
/// size the column rule allows.
struct MenuBorder: ViewModifier {
    static let cornerRadius: CGFloat = 6

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.32), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// The system menu picker with the sidebar's rim.
    func sidebarMenu() -> some View {
        pickerStyle(.menu).modifier(MenuBorder())
    }
}

/// A sub-selection, indented under its parent picker.
struct SubRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .controlSize(.small)
            .padding(.leading, 16)
            .transition(.opacity)
    }
}

/// A label with its switch trailing at the row's end.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

// MARK: - Layers

/// One layer as a collapsed group inside Tune: its name and its switch ("Always on" for a
/// required layer) as the label, its controls inside.
/// Only a layer with something inside carries a chevron. A layer with no parameters is a plain
/// row whose title lines up with the others. The controls sit indented under the title.
struct LayerGroup<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    /// The layer's switch, nil for a required layer.
    let isOn: Binding<Bool>?
    /// False for a layer with no parameters: no chevron, nothing to open.
    var opens: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        // The title reads whole: the name on the first line, its parenthetical as a smaller
        // secondary line under it, and either wraps rather than truncating. At 296 wide several
        // titles do not fit on one line ("Luma record (emphasi...").
        let parts = LayerTitle.parts(title)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DisclosureChevron.gap) {
                DisclosureChevron(isOpen: $isOpen, title: title, shown: opens)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts.name).fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = parts.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if opens { DisclosureChevron.toggle($isOpen) } }
                Spacer(minLength: 8)
                if let isOn {
                    Toggle(title, isOn: isOn)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                } else {
                    Text("Always on").font(.caption).foregroundStyle(.secondary)
                }
            }
            if opens && isOpen {
                content
                    .padding(.top, ChainSidebar.rowGap)
                    .padding(.leading, DisclosureChevron.width + DisclosureChevron.gap)
                    .transition(.opacity)
            }
        }
    }
}

/// The disclosure chevron of a layer row, drawn here rather than by DisclosureGroup so a row
/// with nothing to open can keep the same title position with no chevron at all, and so
/// the chevron stays inside the column (DisclosureGroup's hit area starts 22 pt left of it).
struct DisclosureChevron: View {
    static let width: CGFloat = 12
    static let gap: CGFloat = 6
    @Binding var isOpen: Bool
    let title: String
    /// False draws an empty slot of the same width.
    let shown: Bool

    static func toggle(_ isOpen: Binding<Bool>) {
        withAnimation(.easeOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
    }

    var body: some View {
        if shown {
            Button { Self.toggle($isOpen) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: Self.width, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide \(title)" : "Show \(title)")
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        } else {
            Color.clear.frame(width: Self.width, height: 16).accessibilityHidden(true)
        }
    }
}

/// A layer's parameters, disabled while the layer is off.
struct LayerControls: View {
    let parameters: [LayerParameter]
    let enabled: Bool
    let set: (String, ParameterValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.rowGap) {
            ForEach(parameters) { p in
                ParameterControl(parameter: p) { set(p.id, $0) }
                    .disabled(!p.isActive || !enabled)
            }
        }
    }
}

struct ParameterControl: View {
    let parameter: LayerParameter
    let set: (ParameterValue) -> Void

    var body: some View {
        switch parameter.value {
        case .choice(let current):
            let picker = Picker(parameter.name, selection: Binding(get: { current }, set: { set(.choice($0)) })) {
                ForEach(parameter.options, id: \.value) { Text($0.label).tag($0.value) }
            }
            if parameter.options.count <= 3 && parameter.options.allSatisfy({ $0.label.count <= 6 }) {
                LabeledContent(parameter.name) { FittingPicker { picker }.labelsHidden() }
            } else {
                // The label beside the menu, so the rim goes round the pop-up alone.
                MenuRow(title: parameter.name) { picker }
            }
        case .float(let v):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(parameter.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(parameter.readout(v)).font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Slider(value: Binding(get: { v }, set: { set(.float(parameter.id == "seed" ? $0.rounded() : $0)) }),
                       in: parameter.range)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        case .bool(let b):
            SwitchRow(title: parameter.name, isOn: Binding(get: { b }, set: { set(.bool($0)) }))
        }
    }
}
