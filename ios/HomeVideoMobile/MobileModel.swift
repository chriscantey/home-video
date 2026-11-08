import AVFoundation
import Foundation
import MetalKit
import Observation
import Photos
import PhotosUI
import QuartzCore
import SwiftUI
import VideoToolbox

/// The phone's whole state: one chain, one renderer, one clip. No library, no batch, no
/// copied settings, no saved presets.
/// The controls themselves are the Mac's, read straight off the chain's layers, so a value set
/// here is the value the Mac's sidebar would show.
@MainActor
@Observable
final class MobileModel {
    enum ExportState: Equatable {
        case idle
        case running(Double)
        /// Saved to Photos: the frames written and the file kept for Share.
        case saved(frames: Int, file: URL)
        case failed(String)
        case cancelled
    }

    /// The sizes the phone writes: SD is the main conversion, and there is no 4K.
    static let outputSizes: [OutputSize] = [.sd, .hd, .phone]
    /// The codecs the phone writes: H.264 and HEVC, then every ProRes flavor this phone can
    /// encode.
    static let codecs: [ExportCodec] = [.h264, .hevc] + proRes

    /// The ProRes flavors this phone encodes, decided at runtime, never by the model's name: the
    /// writer takes the flavor's settings (Core's `ExportCodecAvailability`, the Mac's probe) and
    /// VideoToolbox has an encoder for it at 1080p. A phone without a ProRes encoder gets none.
    static let proRes: [ExportCodec] = ExportCodec.allCases.filter {
        $0.isProRes && ExportCodecAvailability.available.contains($0) && hasEncoder($0)
    }

    /// True when VideoToolbox lists an encoder for the codec's four character code.
    nonisolated static func hasEncoder(_ c: ExportCodec) -> Bool {
        let fourCC = c.avCodec.rawValue.utf8.reduce(FourCharCode(0)) { $0 << 8 | FourCharCode($1) }
        var id: CFString?
        var props: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(width: 1920, height: 1080, codecType: fourCC,
                                                           encoderSpecification: nil, encoderIDOut: &id,
                                                           supportedPropertiesOut: &props) == noErr
    }

    /// About how many gigabytes a minute of picture takes in a ProRes flavor at `size`: Apple's
    /// target data rates for 1920 by 1080 at 29.97 (the ProRes white paper), scaled by the pixel
    /// count. The Mac shows no such number, so these are the white paper's.
    static func proResGBPerMinute(_ c: ExportCodec, width: Int, height: Int) -> Double? {
        let mbps1080: Double
        switch c {
        case .proRes422Proxy: mbps1080 = 45
        case .proRes422LT: mbps1080 = 102
        case .proRes422: mbps1080 = 147
        case .proRes422HQ: mbps1080 = 220
        case .proRes4444: mbps1080 = 330
        case .proRes4444XQ: mbps1080 = 500
        default: return nil
        }
        let mbps = mbps1080 * Double(width * height) / Double(1920 * 1080)
        return mbps * 60 / 8 / 1000
    }

    let chain: SignalChain
    let renderer: PreviewRenderer
    let stages: StageSwitches
    let stagePresets = StagePresets()
    let stills: LookStills
    @ObservationIgnored private let audioFeed: AudioPreviewFeed
    private(set) var source: FrameSource?
    private(set) var exportState: ExportState = .idle
    @ObservationIgnored private var exporter: Exporter?
    /// Bumped on every Look picked, for the selection haptic.
    private(set) var lookChanges = 0
    /// Bumped on every export saved, for the success haptic.
    private(set) var exportsSaved = 0
    /// True once a Look is picked, so the Look section reads back what it set on the stages.
    private(set) var lookPicked = false

    /// The export's codec and quality, kept between launches. The container follows the codec.
    var exportSettings: ExportSettings {
        didSet { Self.store(exportSettings) }
    }

    /// The source bypass, as on the Mac: while held the preview shows and plays the clip itself.
    var bypass = false {
        didSet {
            guard bypass != oldValue else { return }
            renderer.bypass = bypass
            audioFeed.bypass = bypass
        }
    }

    init() {
        // Whatever an ended or crashed run left in tmp or the caches goes before anything
        // opens, all but the clip that was open, which comes back.
        let kept = Self.restoresSession ? Self.sessionClip() : nil
        if kept == nil { Self.forgetSession() }
        TempFiles.sweepAll(keeping: kept)
        #if DEBUG
        TempFiles.plantLeftoversIfAsked()
        #endif
        chain = SignalChain.standard()
        renderer = PreviewRenderer(chain: chain)
        // The phone keeps no perf log of its own.
        renderer.perfLog = nil
        stages = StageSwitches(chain: chain)
        stills = LookStills(device: renderer.device)
        exportSettings = Self.storedSettings()
        // `HOMEVIDEO_AUDIO_DUMP=<folder>` writes what the tap hears, as on the Mac.
        let feed = AudioPreviewFeed(spec: chain.audio.spec, dump: AudioTapDump.fromLaunch())
        audioFeed = feed
        let audio = chain.audio
        audio.onChange = { [unowned audio] in feed.update(audio.spec) }
        Self.setPhoneSize(chain)
        sessionTimer = Timer.scheduledTimer(withTimeInterval: Self.sessionCheck, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSessionIfChanged() }
        }
    }

    var presets: Presets { Presets(vhs: chain.vhs!, audio: chain.audio) }

    // MARK: Preview views

    /// The editing screen's preview view. The renderer draws into one view at a time, so after
    /// the full-screen cover closes it comes back here.
    @ObservationIgnored weak var mainPreview: MTKView?
    /// The full screen cover's view while it is up.
    @ObservationIgnored weak var fullScreenPreview: MTKView?

    func returnToMainPreview() {
        fullScreenPreview = nil
        if let v = mainPreview { renderer.attach(to: v) }
    }

    // MARK: The clip

    /// A picked clip on its way in: the picker's progress, and whether a clip was open when the
    /// pick started, so the editor stays laid out under the progress.
    struct Loading {
        let progress: Progress
        let overClip: Bool
        let started = Date()
        /// When the file came in. Nil while the picker still has it.
        var arrived: Date?
        /// Test builds only: a Progress shown in place of the picker's, for screenshots
        /// part way through (`-homevideoShowProgress <fraction>`).
        var stand: Progress?

        /// The Progress the card reads.
        var display: Progress { stand ?? progress }

        /// A clip on the phone is in hand in well under a second, so one that isn't after this
        /// long is coming over the network. Test builds can stretch it (`-homevideoLocalLimit
        /// <seconds>`), since the picker takes most of a second to slide away.
        static var localLimit: TimeInterval {
            #if DEBUG
            let asked = UserDefaults.standard.double(forKey: "homevideoLocalLimit")
            if asked > 0 { return asked }
            #endif
            return 1.0
        }

        /// True while the file is still on its way past the limit. The picker's Progress never
        /// says where a file comes from on a phone, so the timing is the only rule.
        func downloading(at now: Date) -> Bool {
            arrived == nil && now.timeIntervalSince(started) >= Self.localLimit
        }
    }

    /// Set from the pick until the clip shows, or the load fails or is canceled.
    private(set) var loading: Loading?

    /// The file is in: the card goes back to "Opening video…".
    private func noteArrival() {
        guard loading != nil, loading?.arrived == nil else { return }
        loading?.arrived = Date()
    }
    /// Why the last pick did not open, shown on the empty screen.
    private(set) var loadError: String?
    /// Bumped by every pick and cancel, so the answer of a load called off is dropped.
    @ObservationIgnored private var loadToken = 0

    /// Takes a pick from the Photos picker. The open clip goes first, so its memory is free
    /// while the new file comes in.
    func load(_ item: PhotosPickerItem) {
        let overClip = source != nil || loading?.overClip == true
        loadToken += 1
        loading?.progress.cancel()
        closeClip()
        loadError = nil
        let token = loadToken
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        let progress = item.loadTransferable(type: PickedMovie.self) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                #if DEBUG
                // `-homevideoHoldArrival <seconds>` holds the file back that long before the app
                // takes it, as a download from iCloud would, for the card's download line.
                let arrival = UserDefaults.standard.double(forKey: "homevideoHoldArrival")
                if arrival > 0 { try? await Task.sleep(for: .seconds(arrival)) }
                #endif
                if token == self.loadToken, case .success(_?) = result { self.noteArrival() }
                #if DEBUG
                self.debugReceived = CACurrentMediaTime() - started
                // `-homevideoHoldLoad <seconds>` keeps the progress up that long once the file
                // is in, since a simulator's local clip loads too fast to see. The timing
                // leaves the hold out.
                let hold = UserDefaults.standard.double(forKey: "homevideoHoldLoad")
                if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
                self.debugStarted = started + hold
                #endif
                self.finishLoad(result, token: token)
            }
        }
        loading = Loading(progress: progress, overClip: overClip)
        #if DEBUG
        let shown = UserDefaults.standard.double(forKey: "homevideoShowProgress")
        if shown > 0 {
            let stand = Progress(totalUnitCount: 300_000_000)
            stand.kind = .file
            stand.completedUnitCount = Int64(shown * 300_000_000)
            loading?.stand = stand
        }
        #endif
    }

    private func finishLoad(_ result: Result<PickedMovie?, Error>, token: Int) {
        guard token == loadToken else {
            // Called off after the file came in: it goes.
            if case .success(let movie?) = result { TempFiles.remove(movie.url) }
            return
        }
        switch result {
        case .success(let movie?):
            open(movie.url)
        case .success(nil):
            failLoad("That video could not be opened.")
        case .failure(let error):
            failLoad("That video could not be opened: \(error.localizedDescription)")
        }
    }

    /// Stops a load and drops whatever it brought in. The editor goes back to the empty screen.
    func cancelLoad() {
        guard let loading else { return }
        loadToken += 1
        loading.progress.cancel()
        TempFiles.remove(TempFiles.picked)
        failLoad("Opening the video was canceled.")
    }

    private func failLoad(_ message: String) {
        loading = nil
        loadError = message
    }

    /// Closes the open clip and frees it: playback stops, the stills go, and its file and its
    /// export are deleted.
    func closeClip() {
        if isExporting { cancelExport() }
        guard let s = source else { return }
        s.close()
        renderer.source = nil
        source = nil
        stills.clear()
        exportState = .idle
        if TempFiles.isPicked(s.url) { TempFiles.remove(s.url) }
        TempFiles.remove(TempFiles.exports)
        Self.forgetSession()
    }

    // MARK: Session

    /// The open clip and its settings, kept so a relaunch (iOS ends a backgrounded app when it
    /// wants the memory) opens it again as it was. The settings are a sidecar (`Sidecar`): the
    /// Look, every stage's values, Framing, the Output size and the trim. Its `name` is the
    /// picked file's name in `tmp/Picked`.
    static var sessionURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Session", isDirectory: true)
            .appendingPathComponent("current" + Sidecar.suffix)
    }

    /// True when a launch opens the last clip again. Test builds do it only when asked
    /// (`-homevideoRestoreSession YES`), so every other UI test starts on the empty screen.
    static var restoresSession: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "homevideoRestoreSession")
        #else
        true
        #endif
    }

    /// The picked file the session names, when it is still on disk.
    static func sessionClip() -> URL? {
        guard let data = try? Data(contentsOf: sessionURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = root["name"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        let url = TempFiles.picked.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func forgetSession() {
        TempFiles.remove(sessionURL)
    }

    /// Writes the session for the open clip: when it opens, when the app leaves the screen, and
    /// within `sessionCheck` of any change, so a crash or a phone that never reports leaving
    /// keeps the edits too.
    func saveSession() {
        guard let source, TempFiles.isPicked(source.url), !isExporting else { return }
        do {
            try Sidecar.write(chain: chain, name: source.url.lastPathComponent, lookID: look?.id,
                              trim: source.trim, to: Self.sessionURL)
            savedSettings = Sidecar.snapshot(of: chain, lookID: look?.id, trim: source.trim)
        } catch {
            NSLog("Home Video: session not saved: \(error)")
        }
    }

    /// How often the settings are compared with the session last written.
    static let sessionCheck: TimeInterval = 2
    @ObservationIgnored private var savedSettings = Data()
    @ObservationIgnored private var sessionTimer: Timer?

    private func saveSessionIfChanged() {
        guard let source, !isExporting,
              Sidecar.snapshot(of: chain, lookID: look?.id, trim: source.trim) != savedSettings else { return }
        saveSession()
    }

    /// At launch: the last clip again, with its settings, when its file is still there.
    func restoreSessionIfAny() {
        guard Self.restoresSession, source == nil, loading == nil, let url = Self.sessionClip() else { return }
        guard let contents = try? Sidecar.read(Self.sessionURL, into: chain) else {
            Self.forgetSession()
            return
        }
        lookPicked = contents.lookID != nil
        restoredTrim = contents.trim
        open(url)
    }

    /// The restored clip's trim, set once its source exists.
    @ObservationIgnored private var restoredTrim: TrimRange?

    #if DEBUG
    /// Test builds only: when the last pick started and how long its file took, then the
    /// `loadTiming` probe's line once its first frame is in.
    @ObservationIgnored private var debugStarted: CFTimeInterval = 0
    @ObservationIgnored private var debugReceived: CFTimeInterval = 0
    private(set) var debugLoadTiming = ""

    private func noteFirstFrame(_ s: FrameSource) {
        guard debugStarted > 0 else { return }
        let started = debugStarted, received = debugReceived
        debugStarted = 0
        Task { [weak self, weak s] in
            for _ in 0..<6000 {
                guard let s else { return }
                if s.lastFrame != nil {
                    self?.debugLoadTiming = String(format: "received %.3f first frame %.3f", received,
                                                   CACurrentMediaTime() - started) + " " + PickedMovie.lastHandOver
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    #endif

    /// Shows a picked clip, closing the one before it.
    func open(_ url: URL) {
        Task {
            let asset = await Self.playableAsset(url)
            show(url, asset)
        }
    }

    private func show(_ url: URL, _ asset: AVAsset) {
        if source?.url != url { closeClip() }
        source?.close()
        loading = nil
        loadError = nil
        // Another app may have taken the session since launch.
        HomeVideoMobileApp.activateAudio()
        let s = FrameSource(url: url, asset: asset)
        renderer.source = s
        source = s
        exportState = .idle
        if let t = restoredTrim {
            s.setTrim(t)
            restoredTrim = nil
        }
        s.attachAudio(audioFeed)
        s.play()
        stills.clear()
        stills.schedule(for: self, after: 0.8)
        saveSession()
        #if DEBUG
        noteFirstFrame(s)
        #endif
    }

    /// An iPhone clip with spatial audio has an AAC track and an APAC track, and both sit in ONE
    /// audible option (`[apac, aac]`), so a media selection cannot pick AAC. Core's tap sits on
    /// AAC and the mix holds APAC at volume 0. The simulator renders AAC and the tap hears it,
    /// but a phone that can render APAC may play APAC from that option: held at 0, with the tap
    /// never fed, a silent preview while the export (which reads AAC) has sound. So the player
    /// gets a composition of the picture and the AAC track alone, and has no APAC to choose. A clip with one audio track plays as it is.
    static func playableAsset(_ url: URL) async -> AVAsset {
        let file = AVURLAsset(url: url)
        #if DEBUG
        // Test builds can play the file itself, to compare the two.
        if UserDefaults.standard.bool(forKey: "homevideoPlayFile") { return file }
        #endif
        guard let audio = try? await file.loadTracks(withMediaType: .audio), audio.count > 1,
              let video = try? await file.loadTracks(withMediaType: .video),
              let duration = try? await file.load(.duration) else { return file }
        var aac: AVAssetTrack?
        for t in audio {
            if let f = try? await t.load(.formatDescriptions).first,
               CMFormatDescriptionGetMediaSubType(f) == kAudioFormatMPEG4AAC {
                aac = t
                break
            }
        }
        guard let aac else { return file }
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        do {
            for v in video {
                guard let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return file }
                try t.insertTimeRange(range, of: v, at: .zero)
                t.preferredTransform = try await v.load(.preferredTransform)
            }
            guard let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return file }
            try a.insertTimeRange(range, of: aac, at: .zero)
        } catch {
            NSLog("Home Video: AAC-only composition failed, playing the file: \(error)")
            return file
        }
        return comp
    }

    /// Test builds only: `-homevideoTestClip <path>` opens a fixture as if picked, copied into
    /// the app's own folder first, so a UI test can run everything after the system picker.
    func openTestClipIfAsked() {
        #if DEBUG || HV_STORE_SCREENS
        guard source == nil, let path = UserDefaults.standard.string(forKey: "homevideoTestClip"),
              FileManager.default.fileExists(atPath: path) else { return }
        // The folder is not emptied, so a planted leftover stays for the next launch to sweep.
        try? FileManager.default.createDirectory(at: TempFiles.picked, withIntermediateDirectories: true)
        let copy = TempFiles.picked.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        TempFiles.remove(copy)
        guard (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)) != nil else { return }
        open(copy)
        #endif
    }

    // MARK: Looks

    /// The Look the chain reads back as, nil for Custom.
    var look: Look? { presets.look }

    /// A Look sets the whole picture on the phone, the Display included: the Display goes off
    /// unless the Look sets it, so a tape Look clears the screen. The Mac's `setLook` leaves the
    /// Display as it is. All Controls keeps the Display's switch.
    func choose(_ look: Look) {
        presets.setLook(look)
        Self.displayFollows(look, stages)
        lookPicked = true
        lookChanges += 1
    }

    static func displayFollows(_ look: Look, _ stages: StageSwitches) {
        if !look.setsDisplay { stages.set(.display, on: false) }
    }

    /// A random tape on a random Look, as on the Mac, a fresh seed every press.
    func shuffle() {
        let look = Shuffle.roll(presets, seed: Shuffle.freshSeed())
        Self.displayFollows(look, stages)
        lookPicked = true
        lookChanges += 1
    }

    /// Back to a fresh launch, as on the Mac: Fresh SP, Tape and Audio on, every other stage off.
    /// Framing's rotation is the clip's and stays, and the phone's SD size comes back.
    func resetEverything() {
        FreshStart.reset(chain, switches: stages)
        Self.setPhoneSize(chain)
        lookPicked = false
        renderer.displayZoom.reset()
    }

    /// One stage back to its fresh launch values, its switch kept as it stands.
    func reset(_ stage: Stage) {
        guard let vhs = chain.vhs, let chainStage = ChainStage(rawValue: stage.rawValue) else { return }
        let wasOn = stages.switchIsOn(chainStage)
        let fresh = SignalChain.standard()
        guard let freshVHS = fresh.vhs else { return }
        stage.apply(stage.snapshot(vhs: freshVHS, audio: fresh.audio), vhs: vhs, audio: chain.audio)
        if stages.switchIsOn(chainStage) != wasOn { stages.set(chainStage, on: wasOn) }
    }

    /// The SD size the phone writes by default (the Mac's default is Auto).
    private static func setPhoneSize(_ chain: SignalChain) {
        chain.vhs?.output.setParameter("size", to: .choice(OutputSize.sd.rawValue))
    }

    // MARK: Trim

    func setTrim(_ range: TrimRange?) {
        source?.setTrim(range)
    }

    // MARK: Export

    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    /// Renders the clip through the chain at the Output size into the app's temporary folder,
    /// then adds it to Photos with add-only access.
    func export() {
        guard let source, !isExporting else { return }
        // MPEG-4 for H.264 and HEVC, QuickTime for ProRes (the writer refuses ProRes in .mp4).
        let settings = ExportSettings(codec: exportSettings.codec, quality: exportSettings.quality,
                                      container: exportSettings.codec.containers[0])
        let name = settings.fileName(for: source.url, at: Date())
        // One export kept at a time, for Share, until its clip closes.
        guard let folder = try? TempFiles.emptied(TempFiles.exports) else { return }
        let destination = folder.appendingPathComponent(name)
        source.pause()
        let saved = ChainSnapshot(chain)
        // The export uses the chain's shared textures, so the preview stops drawing until it ends.
        renderer.isSuspended = true
        let ex = Exporter(source: source.url, destination: destination, chain: chain, device: renderer.device,
                          settings: settings)
        ex.log = nil
        ex.trim = source.trim
        ex.onProgress = { [weak self] p in
            Task { @MainActor in
                if case .running = self?.exportState { self?.exportState = .running(p) }
            }
        }
        exporter = ex
        exportState = .running(0)
        Task { @MainActor in
            defer {
                saved.restore(into: chain)
                renderer.isSuspended = false
                exporter = nil
            }
            do {
                let result = try await ex.run()
                try await MobileModel.addToPhotos(destination)
                exportState = .saved(frames: result.framesWritten, file: destination)
                exportsSaved += 1
            } catch ExportError.cancelled {
                exportState = .cancelled
            } catch {
                exportState = .failed("\(error)")
            }
        }
    }

    /// Stops the export at the next frame. The partial file is removed by the exporter.
    func cancelExport() {
        exporter?.cancel()
    }

    /// Back to the export form after a result was read.
    func dismissExportResult() {
        if !isExporting { exportState = .idle }
    }

    /// Add-only access: the app can put a video in the library and never read it.
    nonisolated static func addToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "HomeVideoMobile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Photos access was not given"])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    // MARK: Stored export choices

    private static let settingsKey = "phoneExportSettings"

    private static func storedSettings() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: data),
              codecs.contains(s.codec) else { return ExportSettings(codec: .h264, quality: .better, container: .mp4) }
        return s
    }

    private static func store(_ s: ExportSettings) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: settingsKey) }
    }
}
