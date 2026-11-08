import SwiftUI

/// Every control the Mac's sidebar has over the picture and the sound, in one native Form:
/// the Look first, then the stages in flow order (Film, Telecine, Tape, Display, Audio), each
/// with its switch, its stage presets, every layer with its switch and values, and a reset.
/// A row of stage chips on top jumps to a stage, as the Mac's tab strip opens a room.
struct AllControlsView: View {
    let model: MobileModel
    /// Shown in a sheet (a Done button), or inline in landscape's side column.
    var inSheet = true
    /// Shuffle needs a picture to show: a clip in the editor, the live feed on the camera.
    var canShuffle: Bool? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                lookSection
                framingSection
                if let vhs = model.chain.vhs {
                    filmSection(vhs)
                    telecineSection(vhs)
                    tapeSection(vhs)
                    damageSection(vhs)
                    displaySection(vhs)
                    recaptureSection(vhs)
                }
                audioSection
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                StageChips(model: model) { stage in
                    withAnimation { proxy.scrollTo(stage.rawValue, anchor: .top) }
                }
            }
        }
        // Inline in landscape's column the bar is the editor's, over the picture, so no title.
        .navigationTitle(inSheet ? "All Controls" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("allControlsDone")
                }
            }
        }
        .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) { model.resetEverything() }
        } message: {
            Text("Back to Fresh SP with only Tape and Audio on, Framing at its defaults.")
        }
    }

    // MARK: Look and Framing

    private var lookSection: some View {
        Section {
            LookMenu(model: model)
            Text(model.look?.blurb ?? "Custom: a picker or slider has moved off every Look.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.lookPicked {
                LabeledContent("Stages set") {
                    Text(model.stagePresets.readback(model.chain, switches: model.stages))
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                }
            }
            Button("Shuffle", systemImage: "dice") { model.shuffle() }
                .disabled(!(canShuffle ?? (model.source != nil)))
            Button("Reset Everything", systemImage: "arrow.counterclockwise", role: .destructive) {
                confirmReset = true
            }
        } header: {
            Text(SidebarTab.firstTitle)
        }
        .id("look")
    }

    private var framingSection: some View {
        Section("Framing") {
            let framing = model.chain.framing
            ParameterRows(parameters: framing.parameters, layerID: framing.id) {
                framing.setParameter($0, to: $1)
            }
        }
    }

    // MARK: Stages

    /// A stage's head rows: its switch with the "needs" note, and its preset menu.
    @ViewBuilder private func stageHead(_ stage: ChainStage, preset: Stage) -> some View {
        StageToggle(switches: model.stages, stage: stage)
        StagePresetPicker(model: model, stage: preset)
    }

    private func resetButton(_ stage: Stage) -> some View {
        Button("Reset \(stage.title)", systemImage: "arrow.counterclockwise") { model.reset(stage) }
            .accessibilityIdentifier("reset-\(stage.rawValue)")
    }

    private func filmSection(_ vhs: VHSLayers) -> some View {
        let film = vhs.film
        return Section {
            stageHead(.film, preset: .film)
            Caption("Shot on film instead of a camcorder: gauge, stock, light, grain. With the tape on it goes onto the tape, with it off it is a film scan.")
            ParameterRows(parameters: film.source.parameters, layerID: film.source.id, enabled: film.source.enabled) {
                film.source.setParameter($0, to: $1)
            }
            ForEach(Array(film.all.dropFirst().enumerated()), id: \.offset) { _, layer in
                LayerRow(layer, live: film.isOn)
            }
            resetButton(.film)
        } header: {
            Label("Film", systemImage: StageChips.glyph(.film))
        }
        .id(ChainStage.film.rawValue)
    }

    private func telecineSection(_ vhs: VHSLayers) -> some View {
        let t = vhs.telecine
        return Section {
            stageHead(.telecine, preset: .telecine)
            Caption("The film transferred to video: a projector shot by a camcorder at home, or a telecine scanner. With Film off, the clip itself is the film.")
            ParameterRows(parameters: t.source.parameters, layerID: t.source.id, enabled: t.source.enabled) {
                t.source.setParameter($0, to: $1)
            }
            ForEach(Array(t.layers(for: t.route).enumerated()), id: \.offset) { _, layer in
                LayerRow(layer, parameters: t.parameters(of: layer, route: t.route), live: vhs.telecineInUse)
            }
            resetButton(.telecine)
        } header: {
            Label("Telecine", systemImage: StageChips.glyph(.telecine))
        }
        .id(ChainStage.telecine.rawValue)
    }

    private func tapeSection(_ vhs: VHSLayers) -> some View {
        let tapeOn = vhs.tape.enabled
        return Section {
            stageHead(.tape, preset: .tape)
            Caption("The round trip to tape and back. Off, the picture skips the tape and the mic plays alone.")
            Group {
                TapePickers(presets: model.presets)
                ForEach(Array(model.chain.effects.enumerated()), id: \.offset) { _, layer in
                    if !(layer is OSDLayer) && !(layer is any DamageLayer) && LayerTitle.isListed(layer) {
                        LayerRow(layer)
                    }
                }
            }
            .disabled(!tapeOn)
            resetButton(.tape)
        } header: {
            Label("Tape", systemImage: StageChips.glyph(.tape))
        }
        .id(ChainStage.tape.rawValue)
    }

    private func damageSection(_ vhs: VHSLayers) -> some View {
        Section {
            Caption("Worn tape and a tired deck, now and then. The worn Looks set some. The same seed lands the same events.")
            ForEach(Array(vhs.damage.all.enumerated()), id: \.offset) { _, layer in
                LayerRow(layer)
            }
        } header: {
            Text("Tape Damage")
        }
        .disabled(!vhs.tape.enabled)
    }

    private func displaySection(_ vhs: VHSLayers) -> some View {
        let crt = vhs.crt
        return Section {
            stageHead(.display, preset: .display)
            Caption("The picture on a tube TV: its gamma and white, the beam's lines, the phosphor mask, the glass. Pinch the picture to look up close.")
            ParameterRows(parameters: crt.display.parameters, layerID: crt.display.id) {
                crt.display.setParameter($0, to: $1)
            }
            ForEach(Array(crt.layers.enumerated()), id: \.offset) { _, layer in
                LayerRow(layer)
            }
            resetButton(.display)
        } header: {
            Label("Display", systemImage: StageChips.glyph(.display))
        }
        .id(ChainStage.display.rawValue)
    }

    private func recaptureSection(_ vhs: VHSLayers) -> some View {
        let r = vhs.recapture
        let live = vhs.crt.isOn
        return Section {
            StageToggle(switches: model.stages, stage: .recapture)
            ParameterRows(parameters: r.stage.parameters, layerID: r.stage.id, enabled: r.stage.enabled && live) {
                r.stage.setParameter($0, to: $1)
            }
            ForEach(Array(r.layers.enumerated()), id: \.offset) { _, layer in
                LayerRow(layer, live: r.stage.enabled && live)
            }
        } header: {
            Label("Re-capture", systemImage: StageChips.glyph(.recapture))
        } footer: {
            Text(live ? "A camera films the screen: the shutter's rolling bar, the sensor's moire, the hand, the phone's processing."
                      : "Re-capture needs Display: switch on the Display first.")
        }
    }

    private var audioSection: some View {
        let audio = model.chain.audio
        return Section {
            stageHead(.audio, preset: .audio)
            AudioRows(audio: audio)
            resetButton(.audio)
        } header: {
            Label("Audio", systemImage: StageChips.glyph(.audio))
        }
        .id(ChainStage.audio.rawValue)
    }
}

/// All Controls as a sheet, the one presentation the editor and the camera share: the same
/// detents, the picture in view above the lower one, the pink, and the editor's appearance.
/// The camera's own screen stays dark, so it passes the editor's scheme in.
struct AllControlsSheet: View {
    let model: MobileModel
    var scheme: ColorScheme? = nil
    var canShuffle: Bool? = nil

    var body: some View {
        NavigationStack { AllControlsView(model: model, canShuffle: canShuffle) }
            .tint(HomeVideoMobileApp.pink)
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationContentInteraction(.scrolls)
            .preferredColorScheme(scheme)
    }
}

/// A stage's switch, as the Mac's room header draws it, with its "needs" note.
struct StageToggle: View {
    let switches: StageSwitches
    let stage: ChainStage

    var body: some View {
        let need = switches.need(stage)
        Toggle(isOn: Binding(get: { switches.switchIsOn(stage) }, set: { switches.set(stage, on: $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title).fontWeight(.semibold)
                if let need {
                    Text(need).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(need != nil)
        .accessibilityIdentifier("stage-\(stage.rawValue)")
    }
}

/// A stage's preset menu, as on the Mac: the stage's built-ins, Custom when it matches none.
/// Choosing one changes its stage and nothing else. Saving presets stays on the Mac.
struct StagePresetPicker: View {
    let model: MobileModel
    let stage: Stage

    var body: some View {
        let store = model.stagePresets
        let current = store.matching(stage, in: model.chain)
        let builtIn = store.presets(for: stage).builtIn
        Picker("Preset", selection: Binding(get: { current?.id ?? "" }, set: { id in
            if let p = builtIn.first(where: { $0.id == id }) { try? store.apply(p, to: model.chain) }
        })) {
            if current == nil { Text("Custom").tag("") }
            ForEach(builtIn) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("preset-\(stage.rawValue)")
    }
}

/// The Look as a menu with the Mac's category headers, Custom when the chain matches none.
struct LookMenu: View {
    let model: MobileModel

    var body: some View {
        Picker("Look", selection: Binding(get: { model.look?.id ?? "" }, set: { id in
            if let l = Looks.look(id: id) { model.choose(l) }
        })) {
            if model.look == nil { Text("Custom").tag("") }
            ForEach(Looks.grouped, id: \.category) { section in
                Section(section.category.title) {
                    ForEach(section.looks) { Text($0.name).tag($0.id) }
                }
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("lookMenu")
    }
}

/// The Tape's component pickers (the Mac's PresetBar): Source, Tape, Link and its Separator,
/// Deck and Tracking noise, Capture and its switches. "Custom" when a slider has moved off.
struct TapePickers: View {
    let presets: Presets

    var body: some View {
        Picker("Source", selection: Binding(get: { presets.source }, set: { if let s = $0 { presets.setSource(s) } })) {
            if presets.source == nil { Text("Custom").tag(SourcePreset?.none) }
            ForEach(SourcePreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        .disabled(presets.vhs.film.isOn)
        if presets.vhs.film.isOn {
            Caption("Film is on: the film camera shot it.")
        }
        Picker("Tape", selection: Binding(get: { presets.tape }, set: { if let t = $0 { presets.setTape(t) } })) {
            if presets.tape == nil { Text("Custom").tag(TapePreset?.none) }
            ForEach(TapePreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Picker("Link", selection: Binding(get: { presets.link }, set: { if let l = $0 { presets.setLink(l) } })) {
            if presets.link == nil { Text("Custom").tag(LinkPreset?.none) }
            ForEach(LinkPreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        if presets.link == .composite {
            Picker("Separator", selection: Binding(get: { presets.separator }, set: { presets.setSeparator($0) })) {
                ForEach(Separator.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
        Picker("Deck", selection: Binding(get: { presets.deck }, set: { if let d = $0 { presets.setDeck(d) } })) {
            if presets.deck == nil { Text("Custom").tag(DeckPreset?.none) }
            ForEach(DeckPreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Toggle("Tracking noise", isOn: Binding(get: { presets.trackingNoise }, set: { presets.setTrackingNoise($0) }))
        Picker("Capture", selection: Binding(get: { presets.capture }, set: { presets.setCapture($0) })) {
            ForEach(CapturePreset.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        if presets.capture == .weave {
            Toggle("Temporal fields", isOn: Binding(get: { presets.temporalFields }, set: { presets.setTemporalFields($0) }))
        }
        Toggle("Capture border", isOn: Binding(get: { presets.border }, set: { presets.setBorder($0) }))
        Toggle("VCR on-screen display", isOn: Binding(get: { presets.osd }, set: { presets.osd = $0 }))
    }
}

/// The sound (the Mac's AudioSection): the Mic and its values, the tape Track and its layers,
/// the Audio wear and the sound's Damage. With Tape off the track rows wait, the mic plays alone.
struct AudioRows: View {
    let audio: AudioChain

    var body: some View {
        // A segmented picker shows no label of its own, so the row names it.
        LabeledContent("Mic") {
            Picker("Mic", selection: Binding(get: { audio.mic }, set: { audio.mic = $0 })) {
                ForEach(AudioMic.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        if audio.mic == .camcorder {
            WholeSlider(title: "Strength", value: audio.micStrength, range: AudioChain.strengthRange) {
                audio.setMicStrength($0.rounded())
            }
            ParameterRows(parameters: audio.micLayer.parameters.map { p in
                var p = p
                p.name = Self.micNames[p.id] ?? p.name
                return p
            }, layerID: audio.micLayer.id) { audio.micLayer.setParameter($0, to: $1) }
        }
        Group {
            Picker("Track", selection: Binding(get: { audio.track }, set: { audio.setTrack($0) })) {
                ForEach(AudioTrack.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if !audio.tapeIsOn {
                Caption("Tape is off, so the mic plays alone.")
            }
            ForEach(audio.layers.filter { $0 !== audio.micLayer }, id: \.id) { LayerRow($0) }
            WholeSlider(title: "Audio wear", value: audio.wear, range: AudioWear.range) {
                audio.setWear($0.rounded())
            }
            .disabled(audio.track == .off)
            ForEach(audio.damage, id: \.id) { LayerRow($0) }
        }
        .disabled(!audio.tapeIsOn)
    }

    /// The camcorder mic's parameters as the Mac names them.
    static let micNames: [String: String] = [
        "level": "Motor noise (dBFS)",
        "whine": "Motor pitch (Hz)",
        "lift": "Auto gain pumping (dB)",
        "seed": "Seed",
    ]
}

/// A whole number slider with its title and readout (the Mac's Strength and Audio wear).
struct WholeSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.rounded()))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value.rounded()))")
        }
    }
}

/// The stage chips over the sheet, the Mac's tab strip: Look and every stage in flow order,
/// a stage that is off dimmed. A tap scrolls to that section.
struct StageChips: View {
    let model: MobileModel
    let jump: (ChainStage) -> Void

    /// The Mac's glyphs per stage (`StageStrip.glyph`).
    static func glyph(_ stage: ChainStage) -> String {
        switch stage {
        case .film: "film"
        case .telecine: "videoprojector"
        case .tape: "recordingtape"
        case .display: "tv"
        case .audio: "waveform"
        case .recapture: "camera"
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ChainStage.strip) { stage in
                        let on = model.stages.switchIsOn(stage)
                        Button { jump(stage) } label: {
                            Label(stage.title, systemImage: Self.glyph(stage))
                                .font(.subheadline.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.primary : Color.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(on ? .regular.tint(HomeVideoMobileApp.pink.opacity(0.25)).interactive() : .regular.interactive(),
                                     in: Capsule())
                        .accessibilityLabel("\(stage.title), \(on ? "on" : "off")")
                        .accessibilityIdentifier("chip-\(stage.rawValue)")
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .insideMargins()
        // Solid under the chips, so the Form's pinned section headers do not show through.
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
