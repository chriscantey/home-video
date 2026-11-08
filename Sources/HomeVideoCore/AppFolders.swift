import Foundation

/// The app's folders under the user's Library, named for the app: `~/Library/Application
/// Support/Home Video/` (Presets, Imports, Sidecars) and `~/Library/Logs/Home Video/`.
public enum AppFolders {
    /// The folder name, the app's name.
    public static let name = "Home Video"

    /// `~/Library/Application Support`.
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// `~/Library/Application Support/Home Video`.
    public static var support: URL {
        applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    /// `~/Library/Logs/Home Video`.
    public static var logs: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        #else
        // The phone app's own container, `Library/Logs/Home Video`.
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        #endif
    }
}
