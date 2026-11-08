import AppKit
import HomeVideoCore
import SwiftUI
import UniformTypeIdentifiers

/// The one source of the display name, the version and the build number. tools/bundle-app.sh
/// reads all three into Info.plist (the name also names the .app). `displayName` is what the
/// person sees: the window title, About, the app menu and the prompts. The folders under
/// Library use `AppFolders.name` and the bundle id is `co.wonders.homevideo`.
struct AppInfo {
    static let displayName = "Home Video"
    static let version = "1.0.1"
    static let build = 38

    /// The version word the person sees: the bundle's `CFBundleShortVersionString`, which
    /// tools/bundle-app.sh writes by line ("0.2.0 beta 1" on the beta line, "0.2.0" otherwise),
    /// or `version` when there is no bundle string (a debug run).
    static var shortVersion: String {
        let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let s, !s.isEmpty else { return version }
        return s
    }
}

@main
struct HomeVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // The updater is made at launch when the bundle names a feed, and started when the main
        // window appears (Updates).
        _ = Updates.shared
    }

    var body: some Scene {
        Window(AppInfo.displayName, id: "main") {
            ContentView(model: AppModel.shared)
                // A 296 pt sidebar beside a 4:3 picture of at least 600 by 450 with its margins,
                // and the viewer column at least 480 pt even with the left panel open:
                // 180 + 1 + 480 + 1 + 296 = 958, so 960 holds it with 482 pt for the viewer.
                .frame(minWidth: ContentView.minWidth, minHeight: ContentView.minHeight)
                .tint(Color(.sRGB, red: 0xd6 / 255.0, green: 0x3a / 255.0, blue: 0x8c / 255.0))
                .preferredColorScheme(.dark)
                .background(WhatsNewLaunchOpener())
                .onAppear { Updates.shared.start() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
                CheckForUpdatesCommand(updates: Updates.shared)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { AppModel.shared.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            // Edit > Undo and Redo walk the chain's settings, a text field's own first.
            CommandGroup(replacing: .undoRedo) { UndoCommands(model: AppModel.shared) }
            CommandGroup(after: .saveItem) {
                Button("Export…") { AppModel.shared.showExportPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(AppModel.shared.source == nil || AppModel.shared.isExporting)
            }
            CommandGroup(after: .toolbar) {
                // Here so the M key can be found. The key itself is held (AppModel's monitor
                // takes it before this equivalent): chosen from the menu, the item latches the
                // source on until M or the toolbar's Source button is pressed and let go.
                Toggle("Show Source", isOn: Binding(get: { AppModel.shared.bypass },
                                                    set: { AppModel.shared.bypass = $0 }))
                    .keyboardShortcut("m", modifiers: [])
                    .help("Hold M to see and hear the source without the VHS chain, release to come back")
                // A test tool: a debug run, or a release build launched with
                // -homevideoPerformanceReadout on (AppModel.performanceReadoutAvailable).
                if AppModel.performanceReadoutAvailable {
                    Toggle("Performance Readout", isOn: Binding(get: { AppModel.shared.showPerformanceReadout },
                                                                set: { AppModel.shared.showPerformanceReadout = $0 }))
                }
            }
            CommandMenu("Look") { LookCommands(model: AppModel.shared) }
            CommandMenu("Clip") { ClipCommands(model: AppModel.shared) }
            // Help > What's New, then Export Log…, then Acknowledgements.
            CommandGroup(after: .help) {
                WhatsNewCommand()
                ExportLogCommand()
                AcknowledgementsCommand()
            }
        }

        Window("About \(AppInfo.displayName)", id: AboutView.windowID) { AboutView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
            .defaultPosition(.center)

        Window("Manage Presets", id: ManagePresetsView.windowID) { ManagePresetsView(model: AppModel.shared) }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 380, height: 340)

        Window("Export Log", id: ExportLogView.windowID) { ExportLogView(model: AppModel.shared) }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 760, height: 420)

        Window("What's New in \(AppInfo.displayName)", id: WhatsNewView.windowID) { WhatsNewView() }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 460, height: 620)

        // Home Video > Settings… (Command-comma): the update switch (Updates).
        Settings { SettingsView(updates: Updates.shared) }
    }
}

/// The Look menu: the built-in Looks under their section headers, the saved presets
/// under the Custom header, then the preset commands. The shown Look carries a check.
private struct LookCommands: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let shown = model.presets.look?.id
        let order = UserPresets.pickerOrder(user: model.userPresets.presets)
        ForEach(order.builtIn, id: \.category) { section in
            Section(section.category.title) {
                ForEach(section.looks) { look in
                    Toggle(look.name, isOn: Binding(get: { shown == look.id }, set: { _ in model.chooseLook(id: look.id) }))
                }
            }
        }
        if !order.user.isEmpty {
            Section(LookCategory.custom.title) {
                ForEach(order.user) { p in
                    Toggle(p.name, isOn: Binding(get: { shown == p.id }, set: { _ in model.chooseLook(id: p.id) }))
                }
            }
        }
        Divider()
        Button("Save Preset…") { model.showSavePresetPanel() }
            .keyboardShortcut("s", modifiers: [.command, .option])
        Button("Import Preset…") { model.showImportPresetPanel() }
        Button("Export Preset…") { model.showExportPresetPanel() }
        Divider()
        Button("Manage Presets…") { openWindow(id: ManagePresetsView.windowID) }
    }
}

/// The Clip menu: the shown clip's trim. The keys are named in the titles and handled by
/// `AppModel.installTrimKeys`, not bound as menu key equivalents (see there why).
private struct ClipCommands: View {
    let model: AppModel

    var body: some View {
        let source = model.source
        Button("Set In Point at Playhead (I)") { model.setInPoint() }
            .disabled(source == nil)
        Button("Set Out Point at Playhead (O)") { model.setOutPoint() }
            .disabled(source == nil)
        Divider()
        Button("Clear In Point (Option-I)") { model.clearInPoint() }
            .disabled(source?.trim == nil)
        Button("Clear Out Point (Option-O)") { model.clearOutPoint() }
            .disabled(source?.trim == nil)
        Button("Clear Trim") { model.clearTrim() }
            .disabled(source?.trim == nil)
    }
}

/// Edit > Undo and Redo over every change to the chain (`AppModel.undo`, `AppModel.redo`).
private struct UndoCommands: View {
    let model: AppModel

    var body: some View {
        Button("Undo") { model.undo() }
            .keyboardShortcut("z")
            .disabled(!model.canUndo || model.isExporting)
        Button("Redo") { model.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedo || model.isExporting)
    }
}

/// The app menu's About item, opening the app's own About window.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About \(AppInfo.displayName)") { openWindow(id: AboutView.windowID) }
    }
}

/// Receives files handed to the app by Finder or `open -a "Home Video" <file>`, including at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(AppModel.shared.open) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
