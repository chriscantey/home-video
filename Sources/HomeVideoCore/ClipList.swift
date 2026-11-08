import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// One open clip as the left panel lists it. An unshown clip holds only this: its URL, a
/// display name, its duration and a small poster frame. It never holds a decoder.
public struct OpenClip: Identifiable {
    public let id = UUID()
    public let url: URL
    public var name: String { url.lastPathComponent }
    /// Seconds, 0 until the asset's duration has loaded.
    public internal(set) var duration: Double = 0
    /// The first frame at `ClipPoster.width` pixels wide, nil until made or when it fails.
    public internal(set) var poster: CGImage?
    /// Whether the file is on disk, as of the last presence check.
    public internal(set) var presence: ClipPresenceState = .present
    /// The clip's sidecar, nil while it has none (the panel's edited dot).
    public internal(set) var sidecar: URL?

    public init(url: URL) { self.url = url }

    /// True when the sidecar sits in Application Support because the clip's folder is read only.
    public var sidecarIsFallback: Bool {
        guard let sidecar else { return false }
        return sidecar.standardizedFileURL != Sidecar.besideURL(for: url).standardizedFileURL
    }
}

/// What a clip's poster loader returns.
public struct ClipInfo {
    public var duration: Double
    public var poster: CGImage?

    public init(duration: Double, poster: CGImage?) {
        self.duration = duration
        self.poster = poster
    }
}

/// The poster frame: the first frame at 160 px wide, made once per clip.
public enum ClipPoster {
    public static let width: CGFloat = 160

    public static func load(_ url: URL) async -> ClipInfo {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration))?.seconds ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // Height 0 keeps the aspect, so a portrait clip gets a 160 px wide portrait poster.
        gen.maximumSize = CGSize(width: width, height: 0)
        let image = try? await gen.image(at: .zero).image
        return ClipInfo(duration: d.isFinite ? d : 0, poster: image)
    }
}

/// The open clips, with at most one shown. Only the shown clip has a `Source` (a decoder).
///
/// Generic over the source so the rule "one decoder alive" is testable without AVPlayer.
/// The app uses `ClipList<FrameSource>`. Opening a URL that is already open selects it.
/// Switching closes the old source before the new one is made. Removing touches only the
/// list, never the disk. Main actor only, like `FrameSource`.
@MainActor
@Observable
public final class ClipList<Source: AnyObject> {
    public private(set) var clips: [OpenClip] = []
    public private(set) var shownIndex: Int?
    public private(set) var source: Source?
    /// The selected clips by id. Never empty while a clip is shown, and the shown clip is the
    /// first selected one in list order. Selection changes nothing else: settings stay the
    /// shown clip's, and only Export reads the whole selection.
    public private(set) var selection: Set<UUID> = []
    /// Where a Shift click's range starts: the last plain or Command click.
    @ObservationIgnored private var anchor: UUID?

    /// Called after the shown clip changes, with the new source or nil when none is shown.
    @ObservationIgnored public var onShow: ((Source?) -> Void)?
    /// Called before the shown clip is closed (switch or remove), while the chain still holds
    /// its settings, so a pending sidecar write lands for the right clip.
    @ObservationIgnored public var onWillHide: ((OpenClip) -> Void)?
    /// Called after a clip joins or leaves the list (the presence watcher follows it).
    @ObservationIgnored public var onListChange: (() -> Void)?

    @ObservationIgnored private let makeSource: (URL) -> Source
    @ObservationIgnored private let closeSource: (Source) -> Void
    @ObservationIgnored private let loadInfo: (URL) async -> ClipInfo

    public init(makeSource: @escaping (URL) -> Source,
                closeSource: @escaping (Source) -> Void,
                loadInfo: @escaping (URL) async -> ClipInfo = ClipPoster.load) {
        self.makeSource = makeSource
        self.closeSource = closeSource
        self.loadInfo = loadInfo
    }

    public var shown: OpenClip? { shownIndex.map { clips[$0] } }

    public func index(of url: URL) -> Int? {
        let key = url.standardizedFileURL
        return clips.firstIndex { $0.url.standardizedFileURL == key }
    }

    /// Records a presence check's answer for the clip at `url`.
    public func setPresence(_ state: ClipPresenceState, for url: URL) {
        guard let i = index(of: url), clips[i].presence != state else { return }
        clips[i].presence = state
    }

    /// Records where the clip's sidecar is (nil when it has none).
    public func setSidecar(_ sidecar: URL?, for url: URL) {
        guard let i = index(of: url), clips[i].sidecar != sidecar else { return }
        clips[i].sidecar = sidecar
    }

    /// Appends the URL (or finds it) and shows it.
    public func open(_ url: URL) {
        if let i = index(of: url) {
            show(i)
            return
        }
        clips.append(OpenClip(url: url))
        let id = clips[clips.count - 1].id
        onListChange?()
        show(clips.count - 1)
        Task { @MainActor in
            let info = await loadInfo(url)
            guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
            clips[i].duration = info.duration
            clips[i].poster = info.poster
        }
    }

    public enum ClickModifier: Sendable { case none, command, shift }

    /// The selected clips in list order.
    public var selectedClips: [OpenClip] { clips.filter { selection.contains($0.id) } }

    /// A click on clip `index` in the panel, as Finder takes one. Plain selects only it,
    /// Command adds or removes it (the last selected clip stays selected), Shift selects the
    /// run from the anchor to it. The viewer then shows the first selected clip.
    public func click(_ index: Int, modifier: ClickModifier = .none) {
        guard clips.indices.contains(index) else { return }
        let id = clips[index].id
        switch modifier {
        case .none:
            selection = [id]
            anchor = id
        case .command:
            if selection.contains(id) {
                if selection.count > 1 { selection.remove(id) }
            } else {
                selection.insert(id)
            }
            anchor = id
        case .shift:
            let from = anchor.flatMap { a in clips.firstIndex { $0.id == a } } ?? shownIndex ?? index
            selection = Set(clips[min(from, index)...max(from, index)].map(\.id))
        }
        if let first = clips.firstIndex(where: { selection.contains($0.id) }) { show(first) }
    }

    /// Shows clip `index`: the old source is closed first, then the new one is made. A clip
    /// shown from outside the selection becomes the whole selection.
    public func show(_ index: Int) {
        guard clips.indices.contains(index) else { return }
        if !selection.contains(clips[index].id) {
            selection = [clips[index].id]
            anchor = clips[index].id
        }
        guard index != shownIndex else { return }
        if let shown { onWillHide?(shown) }
        if let s = source { closeSource(s) }
        source = nil
        shownIndex = index
        let s = makeSource(clips[index].url)
        source = s
        onShow?(s)
    }

    /// Takes clip `index` out of the list (the file stays where it is). Removing the shown
    /// clip shows its neighbor: the next one, or the previous when it was last.
    public func remove(at index: Int) {
        guard clips.indices.contains(index) else { return }
        selection.remove(clips[index].id)
        guard let shownIndex else {
            clips.remove(at: index)
            onListChange?()
            return
        }
        if index != shownIndex {
            clips.remove(at: index)
            if index < shownIndex { self.shownIndex = shownIndex - 1 }
            onListChange?()
            return
        }
        onWillHide?(clips[index])
        if let s = source { closeSource(s) }
        source = nil
        self.shownIndex = nil
        clips.remove(at: index)
        onListChange?()
        if clips.isEmpty {
            selection = []
            onShow?(nil)
        } else if let first = clips.firstIndex(where: { selection.contains($0.id) }) {
            // Others stay selected: the first of them shows.
            show(first)
        } else {
            show(min(index, clips.count - 1))
        }
    }
}
