import Foundation

/// The files the app writes for itself: a picked clip (`tmp/Picked`), the last export kept for
/// Share (`tmp/Exports`) and a camera recording on its way to Photos (`tmp/Camera`). None of
/// them outlives its use: a clip's file and its export go when the clip closes, a recording
/// once it is in Photos or the camera closes, and anything a crash left goes at launch.
enum TempFiles {
    static let picked = folder("Picked")
    static let exports = folder("Exports")
    static let camera = folder("Camera")

    private static func folder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// The app's own caches folder, which the system's frameworks may also write to.
    static var caches: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    /// At launch, before anything opens: every file under tmp and the caches folder, but the
    /// picked file `keeping`, the clip that comes back.
    static func sweepAll(keeping: URL?) {
        let fm = FileManager.default
        for root in [fm.temporaryDirectory, caches].compactMap({ $0 }) {
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if let keeping, item.standardizedFileURL == picked.standardizedFileURL {
                    for file in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    where file.lastPathComponent != keeping.lastPathComponent {
                        try? fm.removeItem(at: file)
                    }
                } else {
                    try? fm.removeItem(at: item)
                }
            }
        }
    }

    /// True for a file in the picked folder, the only one the app deletes a clip from.
    static func isPicked(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == picked.standardizedFileURL
    }

    /// An empty folder, made fresh.
    static func emptied(_ url: URL) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    #if DEBUG
    /// Test builds only: every file under tmp and the caches folder, as paths from those two
    /// roots, for the `tmpListing` probe.
    static func listing() -> [String] {
        var out: [String] = []
        for (name, root) in [("tmp", FileManager.default.temporaryDirectory), ("Caches", caches)] {
            guard let root, let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            let base = root.resolvingSymlinksInPath().path
            for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let path = url.resolvingSymlinksInPath().path
                out.append(name + (path.hasPrefix(base) ? String(path.dropFirst(base.count)) : "/" + url.lastPathComponent))
            }
        }
        return out.sorted()
    }

    /// Test builds only: `-homevideoPlantLeftovers YES` writes a file into each folder after the
    /// launch sweep, as a crash would leave them, for the next launch to sweep.
    static func plantLeftoversIfAsked() {
        guard UserDefaults.standard.bool(forKey: "homevideoPlantLeftovers") else { return }
        for dir in [picked, exports, camera] + [caches].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir.appendingPathComponent("leftover.mov").path,
                                           contents: Data(repeating: 1, count: 1024))
        }
    }
    #endif
}
