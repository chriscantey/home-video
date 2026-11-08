import Foundation
import Observation

/// One export the queue can run and stop. `Exporter` is the real one, tests use a stand-in.
@MainActor
public protocol ExportJob: AnyObject {
    /// Runs to the end, calling `progress` with 0...1. Returns the frames written. Throws
    /// `ExportError.cancelled` after `cancel()`, with the partial file removed.
    func run(progress: @escaping (Double) -> Void) async throws -> Int
    func cancel()
}

extension Exporter: ExportJob {
    public func run(progress: @escaping (Double) -> Void) async throws -> Int {
        let previous = onProgress
        onProgress = { p in
            previous?(p)
            progress(p)
        }
        defer { onProgress = previous }
        return try await run().framesWritten
    }
}

/// Exports clips one at a time, in order. The chain's textures are shared with the preview,
/// so never two at once. `willRun` sets the chain up for each clip (its own sidecar) right
/// before it starts. A failed clip is recorded and the queue goes on. `cancel()` stops the
/// running export at its next frame (the exporter removes the partial file) and skips the rest.
@MainActor
@Observable
public final class ExportQueue {
    public struct Item: Equatable, Sendable {
        public let source: URL
        public let destination: URL

        public init(source: URL, destination: URL) {
            self.source = source
            self.destination = destination
        }
    }

    public enum Outcome: Equatable, Sendable {
        case pending
        case running
        case written(frames: Int)
        case failed(String)
        case cancelled
        /// Not started, because the queue was cancelled first.
        case skipped

        public var isSettled: Bool { self != .pending && self != .running }
    }

    public let items: [Item]
    public private(set) var outcomes: [Outcome]
    /// The item running now, nil before the start and after the end.
    public private(set) var currentIndex: Int?
    /// The running item's progress, 0...1.
    public private(set) var itemProgress: Double = 0
    public private(set) var isStarted = false
    public private(set) var isFinished = false
    public private(set) var isCancelled = false

    /// Called on the main actor before each item, after the previous one ended. A throw
    /// fails that item with the error and the queue goes on.
    @ObservationIgnored public var willRun: ((Item) throws -> Void)?
    @ObservationIgnored private let makeJob: (Item) -> any ExportJob
    @ObservationIgnored private var job: (any ExportJob)?

    public init(items: [Item], makeJob: @escaping (Item) -> any ExportJob) {
        self.items = items
        self.outcomes = Array(repeating: .pending, count: items.count)
        self.makeJob = makeJob
    }

    /// Items settled so far (written, failed, cancelled or skipped).
    public var settledCount: Int { outcomes.filter(\.isSettled).count }

    /// The whole queue's progress, 0...1: settled items plus the running one's share.
    public var totalProgress: Double {
        guard !items.isEmpty else { return 1 }
        let running = currentIndex == nil ? 0 : itemProgress
        return min(1, (Double(settledCount) + running) / Double(items.count))
    }

    /// The written files, in queue order.
    public var written: [(item: Item, frames: Int)] {
        zip(items, outcomes).compactMap { item, o in
            if case .written(let f) = o { return (item, f) }
            return nil
        }
    }

    public func run() async {
        guard !isStarted else { return }
        isStarted = true
        for i in items.indices {
            if isCancelled {
                outcomes[i] = .skipped
                continue
            }
            currentIndex = i
            itemProgress = 0
            outcomes[i] = .running
            do {
                try willRun?(items[i])
                let j = makeJob(items[i])
                job = j
                // A cancel that landed while `willRun` ran still reaches this job.
                if isCancelled { j.cancel() }
                let frames = try await j.run { [weak self] p in self?.itemProgress = p }
                outcomes[i] = .written(frames: frames)
            } catch {
                outcomes[i] = isCancelled ? .cancelled : .failed("\(error)")
            }
            job = nil
        }
        currentIndex = nil
        isFinished = true
    }

    /// Stops the running export after its current frame and skips the clips after it.
    public func cancel() {
        guard !isFinished else { return }
        isCancelled = true
        job?.cancel()
    }

    /// The queue's files in `folder`: `<name> Home Video <stamp>.<ext>` per clip, with " 2",
    /// " 3" added when two clips share a name or a file of that name is already there
    /// (`exists`), and never a path that is one of the sources. Nothing is ever replaced.
    public static func destinations(for sources: [URL], in folder: URL, settings: ExportSettings,
                                    at date: Date = Date(), timeZone: TimeZone = .current,
                                    exists: (URL) -> Bool = ExportSettings.onDisk) -> [URL] {
        let sourcePaths = Set(sources.map { $0.standardizedFileURL.path })
        var taken = Set<String>()
        return sources.map { src in
            let url = ExportSettings.freeURL(for: settings.fileName(for: src, at: date, timeZone: timeZone),
                                             in: folder) { candidate in
                let key = candidate.standardizedFileURL.path
                return taken.contains(key) || sourcePaths.contains(key) || exists(candidate)
            }
            taken.insert(url.standardizedFileURL.path)
            return url
        }
    }
}

/// The chain's settings held aside while the queue borrows the chain for other clips, put
/// back exactly after: every layer and the audio (the settings clipboard's JSON) plus the
/// framing rotation the clipboard leaves out.
@MainActor
public struct ChainSnapshot {
    public let settings: String
    public let rotation: Int

    public init(_ chain: SignalChain) {
        settings = SettingsClipboard.encode(chain)
        rotation = chain.framing.rotation
    }

    public func restore(into chain: SignalChain) {
        // The JSON came from `encode`, so `apply` takes it.
        try? SettingsClipboard.apply(settings, to: chain)
        chain.framing.rotation = rotation
    }
}
