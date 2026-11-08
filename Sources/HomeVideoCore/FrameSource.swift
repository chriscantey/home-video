import AVFoundation
import CoreVideo
import Foundation
import Observation

/// Plays one movie file and hands out its frames as BGRA pixel buffers.
///
/// Frames are pulled, not pushed: the preview's display link asks `newFrame(atHostTime:)` on
/// every tick and gets a buffer only when the video has advanced. Main actor only; under
/// Swift 6 strict concurrency `AVPlayer` and `CVPixelBuffer` are not Sendable, and the whole
/// engine stays on the main thread instead of crossing actors.
@MainActor
@Observable
public final class FrameSource {
    public let url: URL
    public let player: AVPlayer

    public private(set) var duration: Double = 0
    public private(set) var currentTime: Double = 0
    public private(set) var isPlaying = false
    /// Display size of the video track (natural size with its transform applied).
    public private(set) var naturalSize: CGSize = .zero
    /// Clockwise display rotation from the track's preferredTransform (0, 90, 180, 270).
    /// Decoded frames arrive unrotated; the framing pass applies it.
    public private(set) var rotation = 0
    public private(set) var codec: String = ""
    public private(set) var nominalFrameRate: Double = 0
    /// Distinct frames delivered since the file was opened.
    public private(set) var frameCount: UInt64 = 0
    public private(set) var loadError: String?
    public var loops = true
    /// The clip's trim, nil when the whole clip plays. Playback stops at the out point
    /// (the item's `forwardPlaybackEndTime`) and loops to the in point, and a seek lands
    /// inside the range. Set through `setTrim`, which clamps it to the duration once known.
    public private(set) var trim: TrimRange?
    /// Where playback starts and loops to, and where it ends: the trim's ends or the clip's.
    public var playStart: Double { trim?.inPoint ?? 0 }
    public var playEnd: Double { trim?.outPoint ?? duration }

    @ObservationIgnored private let item: AVPlayerItem
    @ObservationIgnored private let output: AVPlayerItemVideoOutput
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// The most recent frame, kept so a paused or parameter-changed picture can re-render.
    @ObservationIgnored public private(set) var lastFrame: CVPixelBuffer?
    @ObservationIgnored public private(set) var lastFrameTime: Double = 0
    /// Times `hasNewPixelBuffer` answered true since the last `takeNewFrameCount()`, for the
    /// preview counters (`new_frames`).
    @ObservationIgnored private var newFrameTally = 0
    /// True while a `requestNotificationOfMediaDataChange` is pending (`output_suspended`).
    @ObservationIgnored public private(set) var outputSuspended = false
    /// Audio track codecs by track id, loaded with the asset, for `audioTracks`.
    @ObservationIgnored private var audioCodecs: [CMPersistentTrackID: String] = [:]
    /// The codec of the track the processing tap sits on, empty until `attachAudio` has run.
    @ObservationIgnored public private(set) var tapTrackCodec = ""
    /// Host time of the last new frame, to notice a stall while playing.
    @ObservationIgnored private var lastNewFrameHost: CFTimeInterval = 0
    @ObservationIgnored private let pullDelegate = PullDelegate()

    public convenience init(url: URL) {
        self.init(url: url, asset: AVURLAsset(url: url))
    }

    /// Plays `asset` in place of the file itself, such as the phone's composition of the
    /// picture and the AAC track alone. `url` stays the file, for the export and the sidecar.
    public init(url: URL, asset: AVAsset) {
        self.url = url
        item = AVPlayerItem(asset: asset)
        // BGRA, Metal compatible, and IOSurface backed on purpose: CVMetalTextureCache wraps
        // only IOSurface buffers without a copy. avc1 decodes natively to 4:2:0 biplanar, so
        // BGRA costs a conversion in the decoder session (in hardware on Intel and Apple silicon
        // Macs). The chain samples BGRA, and 420v would change its input, so it stays.
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20),
                                                      queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loops else { return }
                let start = CMTime(seconds: self.playStart, preferredTimescale: 600)
                self.currentTime = start.seconds
                self.player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in self.player.play() }
                }
                self.onSeek?()
            }
        }
        output.setDelegate(pullDelegate, queue: .main)
        pullDelegate.onChange = { [weak self] in self?.outputSuspended = false }
        Task { await self.loadProperties(asset) }
    }

    /// Plays the audio through the chain: an audio mix with a processing tap fed by `feed`, on
    /// the track the exporter would pick, and the player made to play that track and only it.
    /// Without an audio track nothing changes.
    ///
    /// An iPhone clip with spatial audio carries an AAC track and an APAC track in one
    /// alternate group, and the player plays the item's default pick (APAC on macOS 26) while
    /// the exporter reads AAC, so the tap would sit on a track nobody hears. The item enables
    /// the tapped track and disables the others, and the mix holds every other audio track at
    /// volume 0. Selecting the track's audible media selection option instead left the item
    /// `unknown/waiting` on a spatial audio iPhone clip, so it is not used.
    public func attachAudio(_ feed: AudioPreviewFeed) {
        let asset = item.asset
        audioAttach = Task { @MainActor in
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
                  let track = await Exporter.pickAudioTrack(tracks),
                  let mix = feed.makeAudioMix(for: track, silencing: tracks.filter { $0.trackID != track.trackID })
            else { return }
            item.audioMix = mix
            tapTrackID = track.trackID
            if let f = try? await track.load(.formatDescriptions).first {
                tapTrackCodec = FrameSource.fourCC(CMFormatDescriptionGetMediaSubType(f))
            }
            if tracks.count > 1 { await playOnly(track) }
        }
    }

    /// The running `attachAudio`, so `play` can start after the track choice. Switching the
    /// enabled track while playing makes the item re-prepare (`unknown/waiting` for 1 to 3 s on
    /// an iPhone clip), switching before the first play does not.
    @ObservationIgnored private var audioAttach: Task<Void, Never>?

    /// The asset track id the processing tap sits on, 0 until `attachAudio` has run.
    @ObservationIgnored public private(set) var tapTrackID: CMPersistentTrackID = 0

    /// The ids of the audio tracks the item has enabled, the ones the player plays.
    public var enabledAudioTrackIDs: [CMPersistentTrackID] {
        item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }.compactMap { $0.assetTrack?.trackID }
    }

    /// Enables `track` and disables every other audio track of the item. The item lists its
    /// tracks once it is ready to play, so this waits up to 10 s for them.
    private func playOnly(_ track: AVAssetTrack) async {
        for _ in 0..<200 {
            let audio = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
            if !audio.isEmpty {
                for t in audio { t.isEnabled = t.assetTrack?.trackID == track.trackID }
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // `deinit` cannot touch main actor state; the owner calls `close()` before dropping a source.
    public func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        lastFrame = nil
    }

    private func loadProperties(_ asset: AVAsset) async {
        do {
            let d = try await asset.load(.duration)
            duration = d.seconds.isFinite ? d.seconds : 0
            // A trim set from the sidecar before the duration was known is clamped now.
            if let trim { setTrim(trim) }
            // Audio first, so `audioTracks` names the codecs on a file without video too.
            for t in try await asset.loadTracks(withMediaType: .audio) {
                if let f = try? await t.load(.formatDescriptions).first {
                    audioCodecs[t.trackID] = FrameSource.fourCC(CMFormatDescriptionGetMediaSubType(f))
                }
            }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                loadError = "No video track"
                return
            }
            let (size, transform, rate, formats) = try await track.load(.naturalSize, .preferredTransform,
                                                                        .nominalFrameRate, .formatDescriptions)
            let r = CGRect(origin: .zero, size: size).applying(transform)
            naturalSize = CGSize(width: abs(r.width), height: abs(r.height))
            rotation = FramingMath.rotation(of: transform)
            nominalFrameRate = Double(rate)
            if let f = formats.first {
                codec = FrameSource.fourCC(CMFormatDescriptionGetMediaSubType(f))
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Sets the trim. Clamped to the duration when it is known, and a range covering the
    /// whole clip is no trim. The playhead moves inside the new range.
    public func setTrim(_ range: TrimRange?) {
        var r = range
        if let given = r, duration > 0 {
            let c = given.clamped(to: duration)
            r = c.isWhole(of: duration) ? nil : c
        }
        trim = r
        item.forwardPlaybackEndTime = r.map { CMTime(seconds: $0.outPoint, preferredTimescale: 600) } ?? .invalid
        if let r, !r.contains(currentTime) { seek(to: currentTime) }
    }

    public func play() {
        if duration > 0, currentTime >= playEnd - 0.01 || currentTime < playStart { seek(to: playStart) }
        isPlaying = true
        guard let attach = audioAttach else {
            player.play()
            return
        }
        // The time observer resets `isPlaying` from the rate, so a pause meanwhile is its own flag.
        playAfterAttach = true
        Task { @MainActor in
            await attach.value
            audioAttach = nil
            if playAfterAttach { player.play() }
            playAfterAttach = false
        }
    }

    @ObservationIgnored private var playAfterAttach = false

    public func pause() {
        playAfterAttach = false
        player.pause()
        isPlaying = false
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    /// Seeks to `seconds`, moved inside the trim (a seek outside it snaps to the nearer end)
    /// and inside the clip.
    public func seek(to seconds: Double) {
        let inside = trim?.clamp(seconds) ?? seconds
        let t = CMTime(seconds: max(0, min(inside, duration)), preferredTimescale: 600)
        currentTime = t.seconds
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        onSeek?()
    }

    /// Told on every seek (the scrubber, a trim handle, a trim snap, play from the end and the
    /// loop back to the in point), so the preview clears the chain's frame history before the
    /// frame the seek lands on.
    @ObservationIgnored public var onSeek: (() -> Void)?

    /// Returns a new frame if the video has advanced to one by `hostTime`, else nil.
    /// The last frame stays in `lastFrame`.
    public func newFrame(atHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? {
        // `hostTime` is the display link's `targetTimestamp`: CACurrentMediaTime seconds of the
        // next refresh, the unit and moment `itemTime(forHostTime:)` documents.
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            // Playing with no new frame for a second: ask the output to say when media data
            // changes, once. The display link keeps running (Apple's pattern pauses it), so the
            // request only marks the stall for the log (`output_suspended`) until the delegate
            // or the next frame clears it.
            if player.rate != 0, !outputSuspended, lastNewFrameHost > 0, hostTime - lastNewFrameHost > 1 {
                output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
                outputSuspended = true
            }
            return nil
        }
        newFrameTally += 1
        lastNewFrameHost = hostTime
        outputSuspended = false
        var displayTime = CMTime.invalid
        guard let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else {
            return nil
        }
        lastFrame = pb
        lastFrameTime = displayTime.isValid ? displayTime.seconds : itemTime.seconds
        frameCount &+= 1
        return pb
    }

    /// Times the output had a new frame since the last call, then zeroed.
    public func takeNewFrameCount() -> Int {
        defer { newFrameTally = 0 }
        return newFrameTally
    }

    /// How far the shown frame trails the item time the output maps `hostTime` to, in ms.
    /// Near one frame while playing in real time, seconds when the picture is stale.
    public func driftMs(atHostTime hostTime: CFTimeInterval) -> Double {
        let t = output.itemTime(forHostTime: hostTime)
        guard t.isValid, t.seconds.isFinite, lastFrame != nil else { return 0 }
        return (t.seconds - lastFrameTime) * 1000
    }

    /// The codecs of the audio tracks the item has enabled, joined with `+` (`aac` is `mp4a`,
    /// Apple Positional Audio is `apac`), or `none`.
    public var audioTracks: String {
        let ids = item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }
            .compactMap { $0.assetTrack?.trackID }
        let names = ids.map { audioCodecs[$0] ?? "?" }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    /// The player's rate, and the item's status with the player's time control status,
    /// as `ready/playing` (`unknown`, `ready`, `failed` / `paused`, `waiting`, `playing`).
    public var playerState: (rate: Double, status: String) {
        let item: String
        switch self.item.status {
        case .readyToPlay: item = "ready"
        case .failed: item = "failed"
        default: item = "unknown"
        }
        let control: String
        switch player.timeControlStatus {
        case .playing: control = "playing"
        case .waitingToPlayAtSpecifiedRate: control = "waiting"
        default: control = "paused"
        }
        return (Double(player.rate), "\(item)/\(control)")
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let s = String(bytes: bytes, encoding: .ascii) ?? ""
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// The video output's pull delegate, on the main queue: media data is about to change after a
/// `requestNotificationOfMediaDataChange`.
private final class PullDelegate: NSObject, AVPlayerItemOutputPullDelegate, @unchecked Sendable {
    var onChange: (@MainActor () -> Void)?

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        MainActor.assumeIsolated { onChange?() }
    }
}
