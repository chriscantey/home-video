import Foundation

/// Whether an open clip's file is on disk, and when it is not, whether it was deleted (or
/// moved or renamed) or sits on a volume that is not mounted now. Both read the same from the
/// filesystem, so the volume a path would live on is read from the path string, never from
/// the missing file. Either way the panel keeps
/// the clip, its poster and its settings: a stale row costs nothing, a forgotten one costs the
/// clip's settings.
public enum ClipPresenceState: Equatable, Sendable {
    case present
    /// The volume is mounted and the file is not there: deleted, renamed or moved.
    case missing
    /// The volume that would hold the file is not mounted.
    case volumeNotMounted

    /// The panel's badge, nil when the file is there.
    public var badge: String? {
        switch self {
        case .present: return nil
        case .missing: return "missing"
        case .volumeNotMounted: return "volume not mounted"
        }
    }
}

public enum ClipOnDisk {
    /// The mount point a path would live under, read from the string: `/Volumes/<name>`,
    /// `/net/<name>`, `/private/var/automount/<name>`, else `/`.
    public static func expectedVolumeRoot(forPath path: String) -> String {
        guard path.hasPrefix("/") else { return "/" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return "/Volumes/\(parts[1])" }
        if parts.count >= 2, parts[0] == "net" { return "/net/\(parts[1])" }
        if parts.count >= 4, parts[0] == "private", parts[1] == "var", parts[2] == "automount" {
            return "/private/var/automount/\(parts[3])"
        }
        return "/"
    }

    /// The pure rule, with the facts passed in. A path that is not there is first followed
    /// through a symlink (a link to an ejected drive reads as missing under the link's own
    /// path). The root volume is mounted by definition. A volume counts as mounted when it is
    /// listed or its mount point exists.
    public static func presence(ofPath path: String,
                                exists: (String) -> Bool,
                                symlinkTarget: (String) -> String? = { _ in nil },
                                mountedVolumePaths: () -> [String]) -> ClipPresenceState {
        var path = path
        for _ in 0..<8 {
            if exists(path) { return .present }
            guard let target = symlinkTarget(path) else { break }
            path = target.hasPrefix("/") ? target : (path as NSString).deletingLastPathComponent + "/" + target
        }
        if exists(path) { return .present }
        let root = expectedVolumeRoot(forPath: path)
        guard root != "/" else { return .missing }
        let listed = mountedVolumePaths().contains {
            let p = $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0
            return p.compare(root, options: .caseInsensitive) == .orderedSame
        }
        return (listed || exists(root)) ? .missing : .volumeNotMounted
    }

    /// The live rule, over the real filesystem.
    public static func presence(of url: URL) -> ClipPresenceState {
        presence(ofPath: url.standardizedFileURL.path,
                 exists: { FileManager.default.fileExists(atPath: $0) },
                 symlinkTarget: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
                 mountedVolumePaths: {
                     (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
                         .map(\.standardizedFileURL.path)
                 })
    }
}

/// Watches the open clips' folders: a dispatch source on each folder (a file added, removed or
/// renamed there fires at once) plus a check every few seconds, which also covers a volume
/// going away and a sidecar edited in place. Each fires `check` on the main actor.
@MainActor
public final class ClipPresence {
    public let interval: TimeInterval
    private let check: @MainActor () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: Timer?

    public init(interval: TimeInterval = 3, check: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.check = check
    }

    /// Watches exactly these folders (the parents of the open clips) and starts the timer.
    /// Called again whenever the list changes, and on each check, so a folder that came back
    /// with its volume gets a source again.
    public func watch(folders: Set<URL>) {
        let wanted = Set(folders.map(\.standardizedFileURL.path))
        for (path, source) in sources where !wanted.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        for path in wanted where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [.write, .delete, .rename, .revoke],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The folder itself went away or its volume was ejected: drop the source,
                    // the next watch makes a new one when the folder is back.
                    if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                        source.cancel()
                        self.sources[path] = nil
                    }
                    self.check()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
        if timer == nil, !wanted.isEmpty {
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if wanted.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The folders with a live source, for tests.
    public var watchedPaths: Set<String> { Set(sources.keys) }

    public func stop() {
        watch(folders: [])
    }
}
