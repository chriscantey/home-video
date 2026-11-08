import Foundation
import Metal

/// Loads HomeVideoCore's Metal library.
///
/// SwiftPM compiles `Shaders/*.metal` into `default.metallib` inside the target's resource
/// bundle (`HomeVideo_HomeVideoCore.bundle`). The generated `Bundle.module` accessor looks for that bundle
/// at the app's root and then at the absolute build path, so inside a signed `.app` (where the
/// bundle lives in `Contents/Resources`) it would only work on the machine that built it.
/// `resourceBundle` checks `Contents/Resources` first.
public enum ShaderLibrary {
    public static let bundleName = "HomeVideo_HomeVideoCore.bundle"

    public static var resourceBundle: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           let bundle = Bundle(url: url) {
            return bundle
        }
        // `homevideo-render` inside the app (Contents/MacOS) started through a symlink on PATH:
        // the real file's Contents/Resources, whatever path it was started by.
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let url = exe.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources").appendingPathComponent(bundleName)
            if let bundle = Bundle(url: url) { return bundle }
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        // The phone app compiles these sources into itself and copies `Shaders` as a folder.
        return Bundle.main
        #endif
    }

    /// Where the plain `.metal` sources sit inside `resourceBundle`. SwiftPM copies them to its
    /// root, the phone app keeps the `Shaders` folder.
    #if SWIFT_PACKAGE
    static let sourceSubdirectory: String? = nil
    #else
    static let sourceSubdirectory: String? = "Shaders"
    #endif

    public enum LoadError: Error, CustomStringConvertible {
        case noLibrary(String)
        public var description: String {
            switch self {
            case .noLibrary(let detail): return "HomeVideoCore Metal library not found: \(detail)"
            }
        }
    }

    /// How the library was obtained, for the report and the about line.
    public enum Origin: String, Sendable {
        case precompiled = "precompiled metallib"
        case runtimeSource = "compiled at runtime from source"
    }

    /// Prefers the precompiled metallib, and falls back to compiling any `.metal` sources that
    /// were copied into the bundle as plain resources.
    public static func make(device: MTLDevice) throws -> (MTLLibrary, Origin) {
        let bundle = resourceBundle
        if let lib = try? device.makeDefaultLibrary(bundle: bundle) {
            return (lib, .precompiled)
        }
        let sources = (bundle.urls(forResourcesWithExtension: "metal", subdirectory: sourceSubdirectory) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sources.isEmpty else {
            throw LoadError.noLibrary("no default.metallib and no .metal sources in \(bundle.bundlePath)")
        }
        let text = try sources.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        return (try device.makeLibrary(source: text, options: nil), .runtimeSource)
    }
}
