import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The app's one screen: the picture on top, always in
/// view, the controls under it. Simple is the default. All Controls opens as a sheet over the
/// lower half (portrait) or fills the side column (any window wider than tall). Upright, the
/// sheet opens only from a tap on its button in the bar. The side column's Simple or All switch
/// is remembered, and never opens the sheet. A phone turned on its side shows the landscape
/// editor, and full screen opens only from its button, in either orientation.
struct ContentView: View {
    let model: MobileModel
    @State private var pick: PhotosPickerItem?
    @State private var exporting = false
    @State private var confirmReset = false
    @State private var picking = false
    @State private var fullScreen = false
    /// The camera screen, from its button beside Choose Video.
    @State private var camera = false
    @State private var about = false
    @State private var appIcon = false
    /// The side column's Simple or All switch, kept between launches.
    @AppStorage("showAllControls") private var showAll = false
    /// The upright sheet, open only after a tap on its button: never from a pick, a launch or
    /// the phone turning upright with All showing in the column.
    @State private var allSheet = false
    /// The editor's appearance, which the camera's All Controls sheet takes too.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// One screen in both orientations. There is one full screen, the cover, and the editor
    /// under it is never replaced. A second full screen player under the cover would show black
    /// when the X closes the cover, since the drawing goes back to the editor's view.
    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // The iPhone Duo on its side keeps a regular vertical size class, so the shape
                // says landscape, not the size class.
                let wide = geo.size.width > geo.size.height * 1.1
                Group {
                    if !showsEditor {
                        empty
                    } else if wide {
                        wideLayout
                    } else {
                        tallLayout
                    }
                }
                // On its side the bar's buttons move to the top of the controls column, and
                // the picture takes the height the bar had.
                .toolbarVisibility(wide && showsEditor ? .hidden : .automatic, for: .navigationBar)
                // The sheet belongs to the tall layout. A wide window shows every control inline.
                .sheet(isPresented: Binding(get: { allSheet && !wide && model.source != nil && !exporting },
                                            set: { if !$0 && !exporting { allSheet = false } })) {
                    AllControlsSheet(model: model)
                }
                // Turning the phone closes the sheet for good, so turning it back never opens it.
                .onChange(of: wide) { allSheet = false }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(showsEditor ? "" : "Home Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            VStack {
                ProbeLabel(id: "loadTiming", text: model.debugLoadTiming)
                ProbeLabel(id: "clipName", text: model.source?.url.lastPathComponent ?? "none")
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ProbeLabel(id: "tmpListing", text: TempFiles.listing().joined(separator: " "))
                }
            }
        }
        #endif
        .sheet(isPresented: $exporting) {
            ExportSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $about) {
            // Large, so the Privacy Policy and Support rows show without a drag on every phone
            // (at medium they sit under the fold, and on the Duo out of the list entirely).
            AboutView()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $appIcon) {
            AppIconView()
                .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $fullScreen, onDismiss: { model.returnToMainPreview() }) {
            FullScreenPlayer(model: model) { fullScreen = false }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraView(model: model, sheetScheme: colorScheme) { camera = false }
        }
        // The system picker runs outside the app and hands back only the clip picked, so the
        // app never asks to read the library.
        .photosPicker(isPresented: $picking, selection: $pick, matching: .videos, preferredItemEncoding: .current)
        .sensoryFeedback(.selection, trigger: model.lookChanges)
        .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) { model.resetEverything() }
        } message: {
            Text("Back to Fresh SP with only Tape and Audio on, Framing at its defaults.")
        }
        // iOS may end the app while it is away, so the clip and its settings are kept as it goes.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveSession() }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            model.load(item)
            // So the same clip can be picked again.
            pick = nil
        }
    }

    /// The editor shows with a clip open, and stays laid out while a pick made over a clip
    /// comes in, its preview empty under the progress.
    private var showsEditor: Bool {
        model.source != nil || model.loading?.overClip == true
    }

    // MARK: Layouts

    /// Portrait: the picture and the transport on a dark stage, then the Simple panel.
    private var tallLayout: some View {
        VStack(spacing: 0) {
            stage
            // All Controls opens from its button in the bar.
            ScrollView {
                SimplePanel(model: model, showAll: nil)
                    .idleWhile(loading: model.loading != nil)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    /// Landscape: the picture and transport on the left, the controls in a column on the right
    /// under the bar's own buttons, Simple or All by a segmented switch.
    private var wideLayout: some View {
        HStack(spacing: 0) {
            wideStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                // Four buttons in the 308 pt between the margins, so 8 pt apart.
                HStack(spacing: 8) {
                    Button("Choose Video", systemImage: "photo.badge.plus") { picking = true }
                        .labelStyle(.iconOnly)
                        .disabled(model.loading != nil)
                        .accessibilityIdentifier("pickClip")
                    cameraButton
                        .labelStyle(.iconOnly)
                    Spacer(minLength: 0)
                    moreMenu
                        .labelStyle(.iconOnly)
                    // On one line, or with Camera in the row it wraps to "Ex-port".
                    Button("Export") { exporting = true }
                        .buttonStyle(.glassProminent)
                        .fixedSize()
                        .disabled(model.isExporting || model.source == nil)
                        .accessibilityIdentifier("export")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.horizontal, Margins.side)
                .padding(.top, 6)
                Picker("Controls", selection: $showAll) {
                    Text("Simple").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("controlsMode")
                Group {
                    if showAll {
                        AllControlsView(model: model, inSheet: false)
                    } else {
                        ScrollView {
                            SimplePanel(model: model) { showAll = true }
                        }
                    }
                }
                .idleWhile(loading: model.loading != nil)
            }
            .frame(width: Self.columnWidth)
            .background(.background.secondary)
        }
    }

    /// Landscape's controls column: kept narrow, so the picture gets the
    /// width. The Look cards, Framing's menus and every All Controls row still fit at 16 pt in.
    static let columnWidth: CGFloat = 340

    /// The picture with the transport under it, on the near black a video wants in either
    /// appearance, upright.
    private var stage: some View {
        stageContent(slack: 30)
            .background(Color.black)
    }

    /// The transport's height as laid out, for fitting the picture above it.
    @State private var transportHeight: CGFloat = 64

    /// Landscape's stage: the picture as large as the pane's safe area allows, running to its
    /// edges, on a black that runs on under the Dynamic Island and the home indicator. Centering
    /// it on the whole pane, island included, would keep the island's width clear on the far
    /// side too and cost the picture that space.
    private var wideStage: some View {
        stageContent(slack: 8)
            .padding(.top, 6)
            .background(Color.black.ignoresSafeArea())
    }

    /// The picture and the transport on one center line.
    /// The transport is as wide as the picture, and never closer to the stage's sides than the
    /// margin: on its edges when the picture is narrower than the stage, 16 pt in from them
    /// when the picture fills the width. `slack` is the room kept free around the two.
    private func stageContent(slack: CGFloat) -> some View {
        GeometryReader { geo in
            let room = CGSize(width: max(geo.size.width, 1),
                              height: max(geo.size.height - transportHeight - slack, 1))
            let picture = FullScreenPlayer.fit(SignalChain.displayAspect(model.chain.output, model.chain.outputSize), in: room)
            VStack(spacing: 10) {
                PreviewArea(model: model) { fullScreen = true }
                    // Its full screen button and gestures are off under the card.
                    .disabled(model.loading != nil)
                    .frame(width: picture.width, height: picture.height)
                    .overlay {
                        if let loading = model.loading {
                            LoadingCard(loading: loading) { model.cancelLoad() }
                        }
                    }
                TransportBar(model: model)
                    .idleWhile(loading: model.loading != nil)
                    .frame(width: FullScreenPlayer.barWidth(picture: picture.width, screen: geo.size.width, sideInset: 0))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { transportHeight = $0 }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.colorScheme, .dark)
    }

    /// No clip yet: the two ways in side by side, a video from Photos or the camera, and a tap
    /// anywhere else on the empty screen opens the picker.
    private var empty: some View {
        ContentUnavailableView {
            Label("No Video", systemImage: "video.badge.waveform")
        } description: {
            Text(model.loadError ?? "Choose a video from Photos or shoot one with the camera, see it through a VHS round trip, then save it.")
        } actions: {
            if let loading = model.loading {
                LoadingCard(loading: loading) { model.cancelLoad() }
            } else {
                HStack(spacing: 12) {
                    Button {
                        picking = true
                    } label: {
                        Label("Choose Video", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("chooseVideo")
                    Button {
                        camera = true
                    } label: {
                        Label("Camera", systemImage: "video")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("emptyCamera")
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if model.loading == nil { picking = true } }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The two ways in on the left, the editing on the right.
        ToolbarItemGroup(placement: .topBarLeading) {
            // A pick on its way in is called off with the card's Cancel, so a second pick or
            // the camera never races it.
            Button("Choose Video", systemImage: "photo.badge.plus") { picking = true }
                .disabled(model.loading != nil)
                .accessibilityIdentifier("pickClip")
            cameraButton
        }
        if model.source != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button("All Controls", systemImage: "slider.horizontal.3") { allSheet = true }
                    .accessibilityHint("Every stage and layer, as on the Mac")
                    .accessibilityIdentifier("allControls")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            moreMenu
        }
        if model.source != nil {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Export") { exporting = true }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isExporting)
                    .accessibilityIdentifier("export")
            }
        }
    }

    /// The camera, beside Choose Video in the bar or, on its side, at the top of the column.
    private var cameraButton: some View {
        Button("Camera", systemImage: "video") { camera = true }
            .disabled(model.isExporting || model.loading != nil)
            .accessibilityIdentifier("camera")
    }

    /// The "..." menu, in the bar or, on its side, at the top of the controls column. About
    /// shows with no clip open too.
    private var moreMenu: some View {
        Menu {
            if model.source != nil {
                Button("Shuffle", systemImage: "dice") { model.shuffle() }
                Button("Clear Trim", systemImage: "scissors") { model.setTrim(nil) }
                    .disabled(model.source?.trim == nil)
                Divider()
                Button("Reset Everything", systemImage: "arrow.counterclockwise", role: .destructive) {
                    confirmReset = true
                }
                // Back to the empty screen, the clip's file and its export deleted.
                Button("Close Clip", systemImage: "xmark.circle", role: .destructive) { model.closeClip() }
                    .accessibilityIdentifier("closeClip")
                Divider()
            }
            Button("App Icon", systemImage: "app") { appIcon = true }
                .accessibilityIdentifier("appIcon")
            Button("About Home Video", systemImage: "info.circle") { about = true }
                .accessibilityIdentifier("about")
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("more")
    }

}

/// A picked video, moved out of the picker's temporary file into the app's own folder, or
/// copied where a move is refused. The picker has made one copy of the original already.
struct PickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = try TempFiles.emptied(TempFiles.picked)
            let mine = folder.appendingPathComponent(received.file.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: received.file, to: mine)
                #if DEBUG
                PickedMovie.lastHandOver = "moved"
                #endif
            } catch {
                try FileManager.default.copyItem(at: received.file, to: mine)
                #if DEBUG
                PickedMovie.lastHandOver = "copied"
                #endif
            }
            return PickedMovie(url: mine)
        }
    }

    #if DEBUG
    /// Test builds only: how the last pick's file came over, for the `loadTiming` probe.
    nonisolated(unsafe) static var lastHandOver = ""
    #endif
}
