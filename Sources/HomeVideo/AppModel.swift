import AppKit
import Observation
import HomeVideoCore
import UniformTypeIdentifiers

/// App state: the open clips (one shown), the chain and the renderer. Main actor only.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let chain: SignalChain
    let vhs: VHSLayers
    let renderer: PreviewRenderer
    /// Every open clip, listed in the left panel. Only the shown one has a decoder. The chain
    /// is the session's one chain: a clip with a sidecar loads its own settings into it when
    /// shown, a clip without one keeps the chain as it is.
    let clips: ClipList<FrameSource>
    /// The shown clip's sidecar (`<clip>.homevideo.json`), written after each burst of changes.
    @ObservationIgnored let sidecars: SidecarSession
    /// Watches the open clips' folders for a clip going missing or its sidecar edited outside.
    @ObservationIgnored private var presenceWatch: ClipPresence?
    /// A short note the panel shows for a moment ("Settings reloaded").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The shown clip's decoder.
    var source: FrameSource? { clips.source }

    static let libraryOpenKey = "libraryPanelOpen"
    /// The left panel, open or closed across launches.
    var libraryOpen: Bool {
        didSet { UserDefaults.standard.set(libraryOpen, forKey: AppModel.libraryOpenKey) }
    }

    static let performanceReadoutKey = "performanceReadout"
    /// The launch argument that brings the readout back to a release build:
    /// `-homevideoPerformanceReadout on` shows the menu item and turns the readout on.
    static let performanceReadoutArgument = "homevideoPerformanceReadout"
    /// The readout is a test tool. A debug run has the View menu item; a release build has it
    /// only with the launch argument, so a shipped build never shows counters, even when a beta
    /// build left the readout switched on in the saved settings.
    static var performanceReadoutAvailable: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[performanceReadoutArgument] != nil
        #endif
    }
    /// View > Performance Readout: the decode, chain and present times, fps, the frame
    /// count and the counters in the status line. Off by default, remembered across launches
    /// where it is available (`performanceReadoutAvailable`). `perf.log` is written either way.
    var showPerformanceReadout: Bool {
        didSet { UserDefaults.standard.set(showPerformanceReadout, forKey: AppModel.performanceReadoutKey) }
    }
    /// Show Source: while held, by the M key or the toolbar's Source button, the viewer
    /// shows the source and the tap passes the source sound through untouched. Not persisted,
    /// not in the sidecar, a preset or the chain fingerprint: it lives on the renderer and the
    /// feed, never on the chain.
    var bypass = false {
        didSet {
            guard bypass != oldValue else { return }
            renderer.bypass = bypass
            audioFeed.bypass = bypass
        }
    }
    /// The M key's hold monitor (see `installSourceHoldKey`).
    @ObservationIgnored private var sourceHoldMonitor: Any?
    /// The I, O, Option-I and Option-O key monitor (see `installTrimKeys`).
    @ObservationIgnored private var trimKeyMonitor: Any?
    /// Copy and Paste Settings, through the pasteboard.
    @ObservationIgnored var settingsClipboard: any SettingsClipboarding = PasteboardSettingsClipboard()

    static let movieTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    /// The export sheet's clips while it is open (one, or the panel's selection).
    var exportRequest: ExportRequest?
    /// The sheet's codec, quality and container, stored on Export.
    var exportSettings = ExportSettings.load()
    /// The export's one line at the size the last stage writes: "720×480 H.264 Better
    /// (6 Mbps), .mp4" on the tape.
    var exportSummary: String { exportSettings.summary(size: chain.outputSize) }
    /// One clip: the file it goes to. Several: the folder they go to.
    var exportFile: URL?
    var exportFolder: URL?
    /// The time in the export's names, fixed when the sheet opens so they hold still while it shows.
    @ObservationIgnored private var exportStamp = Date()
    /// True once the save panel picked the one-clip file: its own Replace prompt then had the
    /// person's answer. A proposed name never replaces a file.
    @ObservationIgnored private var exportFileChosen = false
    /// The queue the sheet started, kept after it ends for the summary.
    private(set) var exportQueue: ExportQueue?
    /// The last export's outcome line, shown under the transport.
    private(set) var exportMessage: String?
    /// The folder of the last export this session, where the next one starts.
    @ObservationIgnored private var lastExportFolder: URL?
    /// True while the queue has the chain: the sidecar session neither writes nor reloads.
    @ObservationIgnored private var chainOnLoan = false

    var isExporting: Bool { exportQueue.map { $0.isStarted && !$0.isFinished } ?? false }
    /// Counts the export queues that have ended, so the Export Log window reloads.
    private(set) var exportLogGeneration = 0

    /// The layer groups opened by id, all collapsed at launch (remembered for the session only).
    var openLayerGroups: Set<String> = []

    /// The stages in use: one switch per stage over the chain's own state.
    @ObservationIgnored let stages: StageSwitches
    /// The stage whose room the sidebar shows, kept apart from which stages are in use.
    @ObservationIgnored let rooms = StageRooms()

    /// The Look and preset pickers over the chain's layers and its audio.
    var presets: Presets { Presets(vhs: vhs, audio: chain.audio) }
    /// The saved user presets (`~/Library/Application Support/Home Video/Presets`), listed in the
    /// Look menu after the built-in Looks.
    let userPresets = UserPresets()
    /// Each stage's own presets (`~/Library/Application Support/Home Video/Stage Presets`),
    /// the menus at the top of the stages' controls.
    let stagePresets = StagePresets()
    /// The audio chain's settings, handed to the preview's processing tap on every change.
    @ObservationIgnored let audioFeed: AudioPreviewFeed
    /// Screen check hooks (see `applyLaunchArguments`).
    @ObservationIgnored private var seekOnOpen: Double?
    @ObservationIgnored private var exportDirectory: URL?

    init() {
        // Framing, then L1 to L9 in signal order at the spec's defaults (L2 composite link off).
        chain = SignalChain.standard()
        vhs = chain.vhs ?? VHSLayers()
        stages = StageSwitches(chain: chain)
        renderer = PreviewRenderer(chain: chain)
        // HOMEVIDEO_AUDIO_DUMP or -homevideoAudioDump: the tap's in and out as WAV files, off otherwise.
        let feed = AudioPreviewFeed(spec: chain.audio.spec, dump: AudioTapDump.fromLaunch())
        audioFeed = feed
        let audio = chain.audio
        audio.onChange = { [unowned audio] in feed.update(audio.spec) }
        clips = ClipList(makeSource: { FrameSource(url: $0) }, closeSource: { $0.close() })
        libraryOpen = UserDefaults.standard.bool(forKey: AppModel.libraryOpenKey)
        #if DEBUG
        showPerformanceReadout = UserDefaults.standard.bool(forKey: AppModel.performanceReadoutKey)
        #else
        showPerformanceReadout = AppModel.performanceReadoutAvailable
        #endif
        sidecars = SidecarSession(chain: chain)
        clips.onShow = { [unowned self] in self.didShow($0) }
        applyLaunchArguments(UserDefaults.standard)
        history.rebase(SettingsClipboard.encode(chain))
        installPressMonitor()
        startSidecars()
        installTrimKeys()
        installSourceHoldKey()
        audio.onChange = { [unowned audio] in feed.update(audio.spec) }
    }

    /// True once a Look has been picked from the picker or the Look menu, until Reset: the
    /// caption under the picker then says what the Look set on the other tabs.
    var lookPicked = false

    // MARK: - Reset

    /// Reset lights while anything differs from a fresh launch, a hidden stage's values included,
    /// or while a room other than the Look tab is open.
    var canReset: Bool {
        FreshStart.drifted(chain) || rooms.selected != .look
    }

    /// Back to a fresh launch: Fresh SP, only Tape and Audio on, every other stage off at
    /// its defaults, Framing and the Output size at theirs, the Look tab open. The sidecar follows
    /// through the settings observer, as after a slider change.
    func resetToFreshStart() {
        FreshStart.reset(chain, switches: stages)
        rooms.choose(.look)
        lookPicked = false
    }

    // MARK: - Undo and Redo

    /// The shown clip's history of chain settings. Every change reaches it through
    /// `observeSettings`, whatever view made it, so nothing calls `record` but that observer.
    @ObservationIgnored private var history = ChainHistory<String>("")
    /// Each open clip's history, so showing another clip and coming back keeps its steps.
    @ObservationIgnored private var histories: [URL: ChainHistory<String>] = [:]
    /// Edit > Undo and Redo are lit while these hold, kept beside the history so the menu follows.
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// Counts left mouse presses, so changes under one press (a slider drag) are one step.
    @ObservationIgnored private var pressCount = 0
    @ObservationIgnored private var pressMonitor: Any?
    /// The press and time of the last change made under a press, for the drag's last value,
    /// which can land just after the button is up.
    @ObservationIgnored private var lastPressedChange: (press: Int, at: Date)?

    private func installPressMonitor() {
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { AppModel.shared.pressCount += 1 }
            return event
        }
    }

    /// The press a change now belongs to: the one held, or the one just let go if its drag
    /// changed the chain under a quarter second ago. Nil with no press.
    private func currentPress() -> Int? {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            lastPressedChange = (pressCount, Date())
            return pressCount
        }
        if let last = lastPressedChange, last.press == pressCount, Date().timeIntervalSince(last.at) < 0.25 {
            return last.press
        }
        return nil
    }

    /// The one entry into the history, from the settings observer.
    private func recordChange() {
        history.record(SettingsClipboard.encode(chain), gesture: currentPress())
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// Edit > Undo (Command-Z): a text field being edited takes its own undo first, else the
    /// chain steps back. The open clip and the play head stay where they are.
    func undo() {
        if textFieldTakes(redo: false) { return }
        guard !isExporting, let state = history.undo() else { return }
        put(state)
    }

    /// Edit > Redo (Shift-Command-Z).
    func redo() {
        if textFieldTakes(redo: true) { return }
        guard !isExporting, let state = history.redo() else { return }
        put(state)
    }

    /// Sets the chain to a state from the history. The settings observer then sees the same
    /// state the history holds, so the step is not recorded again.
    private func put(_ state: String) {
        try? SettingsClipboard.apply(state, to: chain)
        history.settle(SettingsClipboard.encode(chain))
        refreshUndoState()
    }

    /// True when a text field is being edited and has its own step to take, which it then takes.
    private func textFieldTakes(redo: Bool) -> Bool {
        guard let field = NSApp.keyWindow?.firstResponder as? NSTextView, field.isFieldEditor,
              let manager = field.undoManager, redo ? manager.canRedo : manager.canUndo else { return false }
        if redo { manager.redo() } else { manager.undo() }
        return true
    }

    /// The shown clip changed: its own history comes back, or a new one starts from the chain as
    /// it now reads (its sidecar already loaded).
    private func showHistory(for clip: URL?) {
        let state = SettingsClipboard.encode(chain)
        if let key = clip?.standardizedFileURL {
            let h = histories[key] ?? ChainHistory(state)
            h.settle(state)
            histories[key] = h
            history = h
        } else {
            history = ChainHistory(state)
        }
        lastPressedChange = nil
        refreshUndoState()
    }

    // MARK: - Shuffle

    /// Rolls a random tape on a fresh seed.
    func shuffle() {
        Shuffle.roll(presets, seed: Shuffle.freshSeed())
    }

    // MARK: - Show Source

    /// Hold M to see and hear the source. A local monitor rather than `onKeyPress` or the menu's
    /// key equivalent, so it works whatever holds focus, a dragged slider included, and sees the
    /// release. M in a text field goes straight to the field, before View > Show Source's key
    /// equivalent could take it from a name being typed.
    private func installSourceHoldKey() {
        sourceHoldMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { AppModel.shared.handleSourceHoldKey(e) }
            return handled ? nil : event
        }
        // A release lost to a switch to another app never leaves the source showing.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { self.bypass = false }
        }
    }

    private func handleSourceHoldKey(_ event: NSEvent) -> Bool {
        let inText = event.window?.firstResponder is NSText
        let phase = SourceHold.phase(type: event.type, isRepeat: event.type == .keyDown && event.isARepeat,
                                     characters: event.charactersIgnoringModifiers,
                                     modifiers: event.modifierFlags, textFieldHasFocus: inText, holding: bypass)
        switch SourceHold.action(phase) {
        case .show: bypass = true
        case .hide: bypass = false
        case .swallow: break
        case .notOurs:
            // A bare M typed into a field: the field gets it, the menu never does.
            if inText, event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "m",
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               let field = event.window?.firstResponder {
                field.keyDown(with: event)
                return true
            }
            return false
        }
        return true
    }

    // MARK: - Trim

    /// The shown clip's trim, after `FrameSource` clamped it, goes to the sidecar.
    func setTrim(_ range: TrimRange?) {
        guard let s = source else { return }
        s.setTrim(range)
        sidecars.setTrim(s.trim)
    }

    /// I: the in point at the playhead.
    func setInPoint() {
        guard let s = source, s.duration > 0 else { return }
        setTrim((s.trim ?? TrimRange(in: 0, out: s.duration)).settingIn(s.currentTime, duration: s.duration))
    }

    /// O: the out point at the playhead.
    func setOutPoint() {
        guard let s = source, s.duration > 0 else { return }
        setTrim((s.trim ?? TrimRange(in: 0, out: s.duration)).settingOut(s.currentTime, duration: s.duration))
    }

    /// Option-I: the in point back to the start, the out point kept.
    func clearInPoint() {
        guard let s = source, let t = s.trim else { return }
        setTrim(TrimRange(in: 0, out: t.outPoint))
    }

    /// Option-O: the out point back to the end, the in point kept.
    func clearOutPoint() {
        guard let s = source, let t = s.trim else { return }
        setTrim(TrimRange(in: t.inPoint, out: s.duration))
    }

    /// Clip > Clear Trim: the whole clip plays and exports again.
    func clearTrim() { setTrim(nil) }

    /// I and O set the trim at the playhead, Option-I and Option-O clear one end. A local key
    /// monitor rather than menu key equivalents: a plain letter as a menu equivalent would also
    /// fire while a name is typed in the Save Preset field, so these act only when the main
    /// window is key and no text is being edited.
    private func installTrimKeys() {
        trimKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread, so the event never leaves it.
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { AppModel.shared.handleTrimKey(e) }
            return handled ? nil : event
        }
    }

    private func handleTrimKey(_ event: NSEvent) -> Bool {
        guard source != nil, NSApp.modalWindow == nil, let window = event.window, window.isKeyWindow,
              window.attachedSheet == nil, !(window.firstResponder is NSText) else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods.isEmpty || mods == .option else { return false }
        switch (event.charactersIgnoringModifiers?.lowercased(), mods == .option) {
        case ("i", false): setInPoint()
        case ("o", false): setOutPoint()
        case ("i", true): clearInPoint()
        case ("o", true): clearOutPoint()
        default: return false
        }
        return true
    }

    /// The trim an export of `clip` honors: the shown source's, else the clip's sidecar's.
    func trim(for clip: URL) -> TrimRange? {
        if let s = source, s.url.standardizedFileURL == clip.standardizedFileURL { return s.trim }
        return Sidecar.existing(for: clip).flatMap(Sidecar.trim(at:))
    }

    // MARK: - Sidecars and presence

    /// Wires the sidecar session and the presence watcher: a pending write lands before the
    /// shown clip changes and at quit, any change to the chain schedules a write, and the
    /// watcher's checks mark missing clips and reload outside edits.
    private func startSidecars() {
        sidecars.onWrite = { [unowned self] clip, url in self.clips.setSidecar(url, for: clip) }
        sidecars.onError = { [unowned self] in self.showToast($0) }
        sidecars.onTrimLoaded = { [unowned self] in self.source?.setTrim($0) }
        clips.onWillHide = { [unowned self] _ in self.sidecars.debouncer.flush() }
        presenceWatch = ClipPresence { [unowned self] in self.checkPresence() }
        clips.onListChange = { [unowned self] in self.checkPresence() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { self.sidecars.debouncer.flush() }
        }
        observeSettings()
    }

    /// Tracks every value a sidecar holds (except the track's rotation) and tells the session
    /// on each change. The session compares and debounces.
    private func observeSettings() {
        withObservationTracking {
            _ = Sidecar.snapshot(of: chain, lookID: nil)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // An export borrowing the chain for another clip is never the shown clip's edit.
                if !self.chainOnLoan {
                    self.sidecars.changed(currentLookID: self.presets.look?.id)
                    self.recordChange()
                }
                self.observeSettings()
            }
        }
    }

    /// Each open clip's presence and sidecar, the watched folders, and an outside edit of the
    /// shown clip's sidecar.
    private func checkPresence() {
        for clip in clips.clips {
            clips.setPresence(ClipOnDisk.presence(of: clip.url), for: clip.url)
            clips.setSidecar(Sidecar.existing(for: clip.url), for: clip.url)
        }
        presenceWatch?.watch(folders: Set(clips.clips.map { $0.url.deletingLastPathComponent() }))
        if !chainOnLoan, sidecars.reloadIfEditedOutside() { showToast("Settings reloaded") }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func revealSidecar(_ clip: OpenClip) {
        guard let url = clip.sidecar ?? Sidecar.existing(for: clip.url) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Forget Settings: after a confirm, deletes the clip's sidecar and, for the shown clip,
    /// sets the chain back to the Look it was on.
    func forgetSettings(_ clip: OpenClip) {
        let alert = NSAlert()
        alert.messageText = "Forget the settings for \(clip.name)?"
        alert.informativeText = "Deletes \((clip.sidecar ?? Sidecar.besideURL(for: clip.url)).lastPathComponent). "
            + "The clip itself is not touched."
        alert.addButton(withTitle: "Forget Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        sidecars.forget(clip.url, look: sidecars.lookID.flatMap(Looks.anyLook(id:)))
        clips.setSidecar(nil, for: clip.url)
    }

    /// Screen check hooks, from launch arguments (`open -a "Home Video" clip.mov --args
    /// -homevideoOnly head-switch -homevideoSet "capture.deinterlace=bob;framing.mode=letterbox"`),
    /// so a shot of one state is reproducible without driving the sidebar.
    /// - homevideoOnly: every layer between L1 and L9 off except this id ("none" for all off).
    /// - homevideoSet: `layer.param=value` pairs split by `;`. `param` "enabled" takes on or off.
    ///   Other values are true or false for toggles, a number for sliders, else a choice.
    /// - homevideoLook: a Look id, as `homevideo-render --look` takes it, before homevideoPreset
    ///   and homevideoSet.
    /// - homevideoPreset: the preset pickers, as `homevideo-render --preset` takes them, before
    ///   homevideoSet.
    /// - homevideoSeek: seconds, where the opened file is paused.
    /// - homevideoExportDir: the folder File > Export's panel opens in, instead of the source's.
    /// - homevideoOpen: layer ids split by commas whose groups inside Tune open at launch.
    /// - homevideoRoom: the tab that shows at launch (look, tape, audio, film, telecine,
    ///   display), without switching its stage on. An off stage has no tab, so its room
    ///   gives way to the Look tab unless a Look or homevideoSet turns the stage on.
    func applyLaunchArguments(_ defaults: UserDefaults) {
        if let tab = defaults.string(forKey: "homevideoRoom").flatMap(SidebarTab.init(word:)) {
            rooms.selected = tab
        }
        if let id = defaults.string(forKey: "homevideoLook"), let look = Looks.look(id: id) {
            presets.setLook(look)
        }
        if let only = defaults.string(forKey: "homevideoOnly") {
            vhs.allOff()
            for l in vhs.saved where l.id == only { l.enabled = true }
        }
        // The preview's Display zoom for a screen check: "zoom,x,y", the center in the canvas's uv.
        if let z = defaults.string(forKey: "homevideoDisplayZoom") {
            let v = z.split(separator: ",").compactMap { Double($0) }
            if v.count == 3 {
                renderer.displayZoom.setZoom(v[0])
                renderer.displayZoom.pan(from: CGPoint(x: v[1], y: v[2]), drag: .zero)
            }
        }
        if let ids = defaults.string(forKey: "homevideoOpen") {
            openLayerGroups = Set(ids.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        if let text = defaults.string(forKey: "homevideoPreset"), let p = try? PresetSelection.parse(text) {
            presets.apply(p)
            if let a = p.audio { chain.audio.preset = a }
        }
        if defaults.object(forKey: "homevideoSeek") != nil { seekOnOpen = defaults.double(forKey: "homevideoSeek") }
        if let dir = defaults.string(forKey: "homevideoExportDir") {
            exportDirectory = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard let set = defaults.string(forKey: "homevideoSet") else { return }
        // Film's older output choice is folded into the stages once every pair is read.
        defer { chain.vhs?.foldLegacyFilmOutput() }
        for pair in set.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            var path = kv[0].split(separator: ".", maxSplits: 1).map(String.init)
            // A stage's switch in short: tape=off is tape.enabled=off.
            if path.count == 1, RenderArguments.stageSwitches.contains(path[0]) { path.append("enabled") }
            guard kv.count == 2, path.count == 2,
                  let layer = chain.settingsLayers.first(where: { $0.id == path[0] }) else { continue }
            let (param, raw) = (path[1], kv[1])
            if param == "enabled" { layer.enabled = raw == "on"; continue }
            let value: ParameterValue
            if raw == "true" || raw == "false" {
                value = .bool(raw == "true")
            } else if let d = Double(raw), layer.parameters.first(where: { $0.id == param })?.value.doubleValue != nil {
                value = .float(d)
            } else {
                value = .choice(raw)
            }
            layer.setParameter(param, to: value)
        }
    }

    // MARK: - Export

    /// The clips an Export acts on: the panel's selection when it holds several, else the shown
    /// clip. A right-click on a clip outside the selection exports that clip alone, as Finder
    /// does. Clips whose file is missing are left out.
    func exportTargets(clicked: URL? = nil) -> [URL] {
        let selected = clips.selectedClips.filter { $0.presence == .present }.map(\.url)
        if let clicked {
            let key = clicked.standardizedFileURL
            return selected.count > 1 && selected.contains(where: { $0.standardizedFileURL == key })
                ? selected : [clicked]
        }
        if selected.count > 1 { return selected }
        return source.map { [$0.url] } ?? []
    }

    /// File > Export, the transport's and the title bar's Export, and the panel's right-click
    /// Export: opens the export sheet for the targets. Nothing is written until its Export.
    func showExportPanel(for clipURL: URL? = nil) {
        let targets = exportTargets(clicked: clipURL)
        guard !targets.isEmpty, !isExporting else { return }
        exportSettings = ExportSettings.load()
        exportQueue = nil
        let folder = exportDirectory ?? lastExportFolder ?? targets[0].deletingLastPathComponent()
        exportFolder = folder
        exportStamp = Date()
        exportFileChosen = false
        exportFile = proposedFile(for: targets[0], in: folder)
        exportRequest = ExportRequest(clips: targets)
    }

    /// The one-clip file the sheet proposes: the clip's name, Home Video and the sheet's time, with
    /// a counter when that name is already in `folder` or is the clip itself.
    private func proposedFile(for clip: URL, in folder: URL) -> URL {
        ExportQueue.destinations(for: [clip], in: folder, settings: exportSettings, at: exportStamp)[0]
    }

    /// A codec or container change renames the one-clip file to the new extension: a proposed
    /// name is proposed again (a counter when the new name is taken), a chosen one keeps its stem.
    func exportSettingsChanged() {
        guard let file = exportFile else { return }
        let ext = exportSettings.container.fileExtension
        guard file.pathExtension.lowercased() != ext else { return }
        if !exportFileChosen, let clip = exportRequest?.clips.first {
            exportFile = proposedFile(for: clip, in: file.deletingLastPathComponent())
        } else {
            exportFile = file.deletingPathExtension().appendingPathExtension(ext)
            exportFileChosen = false
        }
    }

    /// Choose… in the sheet: a save panel for one clip, a folder panel for several.
    func chooseExportDestination() {
        guard let request = exportRequest else { return }
        if request.clips.count == 1 {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [exportSettings.container == .mov ? .quickTimeMovie : .mpeg4Movie]
            panel.nameFieldStringValue = exportFile?.lastPathComponent
                ?? exportSettings.fileName(for: request.clips[0], at: exportStamp)
            panel.directoryURL = exportFile?.deletingLastPathComponent()
            panel.message = "Export \(request.clips[0].lastPathComponent) as \(exportSummary)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            exportFile = url
            exportFolder = url.deletingLastPathComponent()
            // The panel asked before a name already there, so its answer stands.
            exportFileChosen = true
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Export Here"
            panel.directoryURL = exportFolder
            guard panel.runModal() == .OK, let url = panel.url else { return }
            exportFolder = url
        }
    }

    /// The files the sheet's Export writes, in clip order.
    var exportItems: [ExportQueue.Item] {
        guard let request = exportRequest else { return [] }
        if request.clips.count == 1, let file = exportFile {
            return [ExportQueue.Item(source: request.clips[0], destination: file)]
        }
        guard let folder = exportFolder else { return [] }
        return zip(request.clips, ExportQueue.destinations(for: request.clips, in: folder, settings: exportSettings,
                                                           at: exportStamp))
            .map { ExportQueue.Item(source: $0, destination: $1) }
    }

    /// Why Export is unavailable, nil when it can run.
    var exportBlocker: String? {
        let items = exportItems
        if items.isEmpty { return "Choose where the export goes." }
        if items.contains(where: { $0.source.standardizedFileURL == $0.destination.standardizedFileURL }) {
            return "The export would replace its source. Choose another name."
        }
        if !ExportCodecAvailability.available.contains(exportSettings.codec) {
            return "This Mac cannot write \(exportSettings.codec.name)."
        }
        return nil
    }

    /// The sheet's Export: stores the choices and runs the queue. The shown clip exports with
    /// the chain as it is now, every other clip with its own sidecar (or, without one, the
    /// shown clip's settings, as showing it would). The chain is put back after the last clip.
    func startExport() {
        guard exportBlocker == nil, !isExporting else { return }
        // A file that turned up under the proposed name while the sheet showed gets a counter.
        if exportRequest?.clips.count == 1, !exportFileChosen, let file = exportFile,
           let clip = exportRequest?.clips.first {
            exportFile = ExportSettings.freeURL(for: file.lastPathComponent, in: file.deletingLastPathComponent()) {
                ExportSettings.onDisk($0) || $0.standardizedFileURL == clip.standardizedFileURL
            }
        }
        let items = exportItems
        let settings = exportSettings.normalized
        settings.save()
        lastExportFolder = items.first?.destination.deletingLastPathComponent()

        // A pending sidecar write lands for the shown clip before the chain is lent out.
        sidecars.debouncer.flush()
        chainOnLoan = true
        let saved = ChainSnapshot(chain)
        let shown = source?.url.standardizedFileURL
        // The export uses the chain's shared textures, so the preview stops drawing until it ends.
        source?.pause()
        renderer.isSuspended = true
        let chain = chain, device = renderer.device
        let queue = ExportQueue(items: items) { [weak self] item in
            let ex = Exporter(source: item.source, destination: item.destination, chain: chain, device: device,
                              settings: settings)
            // Each clip exports its own trim, from its sidecar or the shown clip's range.
            ex.trim = self?.trim(for: item.source)
            return ex
        }
        queue.willRun = { item in
            saved.restore(into: chain)
            guard item.source.standardizedFileURL != shown,
                  let sidecar = Sidecar.existing(for: item.source) else { return }
            try Sidecar.read(sidecar, into: chain)
        }
        exportQueue = queue
        exportMessage = nil
        Task { @MainActor in
            await queue.run()
            saved.restore(into: chain)
            chainOnLoan = false
            renderer.isSuspended = false
            exportMessage = AppModel.outcomeLine(queue)
            exportLogGeneration += 1
        }
    }

    /// The status line after a run: "Exported 43 frames to Clip Home Video 2026-10-18
    /// 15.24.07.mp4", "Exported 3 files".
    static func outcomeLine(_ q: ExportQueue) -> String {
        let written = q.written
        let failed = q.outcomes.filter { if case .failed = $0 { return true } else { return false } }.count
        var line: String
        if q.items.count == 1, let w = written.first {
            line = "Exported \(w.frames) frames to \(w.item.destination.lastPathComponent)"
        } else {
            line = "Exported \(written.count) of \(q.items.count) files"
        }
        if q.isCancelled { line = written.isEmpty ? "Export cancelled" : line + ", then cancelled" }
        if failed > 0 { line += ", \(failed) failed" }
        return line
    }

    func cancelExport() {
        exportQueue?.cancel()
    }

    /// Done, or Cancel before Export: closes the sheet.
    func closeExportSheet() {
        guard !isExporting else { return }
        exportRequest = nil
        exportQueue = nil
    }

    /// Adds the file to the open clips (or selects it when already open) and shows it.
    func open(_ url: URL) {
        clips.open(url)
    }

    /// A click on open clip `index` in the panel: selects it (Command and Shift add to the
    /// selection) and shows the first selected clip in the viewer.
    func select(_ index: Int, modifier: ClipList<FrameSource>.ClickModifier = .none) {
        clips.click(index, modifier: modifier)
    }

    /// Takes a clip out of the list only. The file stays where it is.
    func removeClip(at index: Int) {
        clips.remove(at: index)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copySettings() {
        settingsClipboard.copy(from: chain)
    }

    func pasteSettings() {
        settingsClipboard.paste(into: chain)
    }

    var canPasteSettings: Bool { settingsClipboard.canPaste }

    /// The list switched clips: the renderer and the audio follow the new source.
    private func didShow(_ s: FrameSource?) {
        // The clip's sidecar is read before the renderer gets the source, so its first frame
        // already shows the clip's own settings.
        if let e = sidecars.show(s?.url, currentLookID: presets.look?.id) { showToast("\(e)") }
        if let url = s?.url { clips.setSidecar(sidecars.sidecarURL, for: url) }
        // Loading the clip's sidecar is not an edit: the clip's own history picks up from here.
        showHistory(for: s?.url)
        renderer.source = s
        guard let s else { return }
        // The clip's own trim, clamped by the source once its duration loads.
        s.setTrim(sidecars.trim)
        s.attachAudio(audioFeed)
        if let t = seekOnOpen {
            // `seek` clamps to the duration, which loads asynchronously.
            Task { @MainActor in
                while s.duration == 0 && s.loadError == nil { try? await Task.sleep(for: .milliseconds(50)) }
                s.pause()
                s.seek(to: t)
            }
        } else {
            s.play()
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.movieTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose movies to preview"
        if panel.runModal() == .OK {
            panel.urls.forEach(open)
        }
    }

    static func isMovie(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return movieTypes.contains { type.conforms(to: $0) }
    }
}

/// The clips one export sheet acts on.
struct ExportRequest: Identifiable {
    let id = UUID()
    let clips: [URL]
}

/// Copy and Paste Settings, as the viewer's menu and the panel's clip menu both call them.
/// `PasteboardSettingsClipboard` (in ViewerView.swift) is the one in use, over
/// `SettingsClipboard`'s two static functions.
@MainActor
protocol SettingsClipboarding {
    func copy(from chain: SignalChain)
    func paste(into chain: SignalChain)
    var canPaste: Bool { get }
}
