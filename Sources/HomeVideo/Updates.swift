import Combine
import Sparkle
import SwiftUI

/// Updates: Sparkle's standard updater, made at launch only when the bundle names a feed and
/// started when the main window appears (`SUFeedURL`, written by tools/bundle-app.sh for the release
/// and beta lines). A dev build names none, so no updater exists, nothing is checked, and the
/// update item, the settings switch and the privacy line are all absent. Nothing here turns on
/// system profiling: the only traffic is the feed and, when the person says install, the zip.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()

    /// The words in About, the same on the site.
    static let privacyLine = "If you let it, the app checks homevideo.app once a day for a new version, with a standard HTTPS request and nothing else."

    /// nil on a build with no feed.
    let controller: SPUStandardUpdaterController?
    /// Mirrors the updater's own `canCheckForUpdates`, false while a check is running.
    @Published private(set) var canCheckForUpdates = false

    var updater: SPUUpdater? { controller?.updater }

    private init() {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty else {
            controller = nil
            return
        }
        // Made here, started by `start()` once the main window is up. Started in App.init, Sparkle's
        // first question ("Check for updates automatically?") runs modal before SwiftUI opens the
        // main window, and closing it then closes the app's last window, which quits the app.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller?.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    private var started = false

    /// Starts the updater once, from the main window's appearance.
    func start() {
        guard let controller, !started else { return }
        started = true
        controller.startUpdater()
    }
}

/// The app menu's "Check for Updates…", after About. Not drawn at all on a build with no feed.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updates: Updates

    var body: some View {
        if let updater = updates.updater {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }
    }
}

/// Home Video > Settings: the one update setting, "Check for updates automatically", bound to the
/// updater's own switch (Sparkle keeps it in the app's defaults). A build with no feed says it does
/// not check.
struct SettingsView: View {
    @ObservedObject var updates: Updates
    @State private var automatic = false

    var body: some View {
        Form {
            Section("Updates") {
                if let updater = updates.updater {
                    Toggle("Check for updates automatically", isOn: $automatic)
                        .onAppear { automatic = updater.automaticallyChecksForUpdates }
                        .onChange(of: automatic) { _, on in updater.automaticallyChecksForUpdates = on }
                    Text(Updates.privacyLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("This build does not check for updates.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }
}
