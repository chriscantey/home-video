#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

/// One promised file, as a drag from Apple Photos carries it. `NSFilePromiseReceiver` is the
/// real one. Tests pass a fake that writes a file on the queue it is handed.
public protocol PromisedFile {
    var fileTypes: [String] { get }
    func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any],
                              operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void)
}

extension NSFilePromiseReceiver: PromisedFile {}

/// Drops of movies: file URLs (Finder) open where they are, file promises (Photos) are
/// received into `~/Library/Application Support/Home Video/Imports/` and open from there.
public enum FilePromiseDrop {
    /// `~/Library/Application Support/Home Video/Imports/`, where promised files land.
    public static var importsFolder: URL {
        AppFolders.support.appendingPathComponent("Imports", isDirectory: true)
    }

    /// The pasteboard types a drop destination registers for: promises and file URLs.
    public static var draggedTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) } + [.fileURL]
    }

    /// Promises are written off the main thread, one at a time.
    public static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Home Video file promises"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    static let movieTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    public static func isMovie(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return movieTypes.contains { type.conforms(to: $0) }
    }

    static func isMovie(_ promise: PromisedFile) -> Bool {
        promise.fileTypes.contains { id in
            guard let type = UTType(id) else { return false }
            return movieTypes.contains { type.conforms(to: $0) }
        }
    }

    /// True when the pasteboard holds at least one movie URL or a promise of one.
    public static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        let (urls, promises) = read(pasteboard)
        return !urls.isEmpty || !promises.isEmpty
    }

    /// The movie URLs and movie promises on a drag pasteboard, in drag order.
    public static func read(_ pasteboard: NSPasteboard) -> (urls: [URL], promises: [PromisedFile]) {
        let objects = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self, NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) ?? []
        var urls: [URL] = []
        var promises: [PromisedFile] = []
        for o in objects {
            if let p = o as? NSFilePromiseReceiver, isMovie(p) {
                promises.append(p)
            } else if let u = o as? URL, isMovie(u) {
                urls.append(u)
            }
        }
        return (urls, promises)
    }

    /// Reads a drop and calls `completion` on the main actor with every movie it carries:
    /// the URLs as they are, then each promise once it is written into `folder`. A promise
    /// that fails is left out. `completion` runs once, after the last promise.
    public static func receive(from pasteboard: NSPasteboard, into folder: URL = importsFolder,
                               queue: OperationQueue = queue,
                               completion: @escaping @MainActor ([URL]) -> Void) {
        let (urls, promises) = read(pasteboard)
        receive(urls: urls, promises: promises, into: folder, queue: queue, completion: completion)
    }

    public static func receive(urls: [URL], promises: [PromisedFile], into folder: URL,
                               queue: OperationQueue = queue,
                               completion: @escaping @MainActor ([URL]) -> Void) {
        let movies = promises.filter(isMovie)
        guard !movies.isEmpty else {
            Task { @MainActor in completion(urls) }
            return
        }
        let results = Results(count: movies.count)
        let group = DispatchGroup()
        for (i, promise) in movies.enumerated() {
            // Each promise gets its own incoming folder, so a file of the same name already in
            // the imports folder is never overwritten. It moves up under a free name after.
            let incoming = folder.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            } catch {
                continue
            }
            group.enter()
            promise.receivePromisedFiles(atDestination: incoming, options: [:], operationQueue: queue) { url, error in
                defer {
                    try? FileManager.default.removeItem(at: incoming)
                    group.leave()
                }
                guard error == nil, let landed = try? moveUp(url, into: folder) else { return }
                results.set(i, landed)
            }
        }
        group.notify(queue: .main) {
            let received = results.all()
            MainActor.assumeIsolated { completion(urls + received) }
        }
    }

    /// Moves `file` into `folder` under its own name, or `name 2.ext`, `name 3.ext` when taken.
    static func moveUp(_ file: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var target = folder.appendingPathComponent(file.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            target = folder.appendingPathComponent(name)
            n += 1
        }
        try fm.moveItem(at: file, to: target)
        return target
    }

    /// Slots filled from the promise queue, read once on main after the group drains.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [URL?]
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ url: URL) {
            lock.withLock { slots[i] = url }
        }
        func all() -> [URL] {
            lock.withLock { slots.compactMap { $0 } }
        }
    }
}
#endif
