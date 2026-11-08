#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreVideo
import Metal
import MetalKit
import Observation
import QuartzCore

/// Keeps a CVMetalTexture alive into a command buffer's completion handler. Only retained
/// and released there, never read, so crossing threads is safe.
private final class TextureHold: @unchecked Sendable {
    let texture: CVMetalTexture?
    init(_ texture: CVMetalTexture?) { self.texture = texture }
}

/// Mean milliseconds per frame for the three stages the status bar shows.
public struct FrameTimes: Equatable, Sendable {
    /// Asking the video output for a frame until the pixel buffer is in hand (new frames only).
    public var decode: Double = 0
    /// The command buffer's GPU time, `gpuStartTime` to `gpuEndTime`: the chain plus the
    /// preview draw.
    public var chain: Double = 0
    /// CPU time from commit to the drawable's present, or to the command buffer's completion
    /// in a window where no presented handler fired (the log's `presents=0`).
    public var present: Double = 0

    public init(decode: Double = 0, chain: Double = 0, present: Double = 0) {
        self.decode = decode
        self.chain = chain
        self.present = present
    }
}

/// One second of preview counts, for the log's tail fields and the readout. Read together they
/// say which stage stalls: frames from the output (`newFrames`), chain runs (`draws`), fresh
/// drawables (`drawables`) and presented handlers fired (`presents`). Playing in real time on a
/// 60 Hz display with a 30 fps clip: 30, 60, 60, 60.
public struct PreviewCounters: Equatable, Sendable {
    /// Times the video output's `hasNewPixelBuffer` answered true.
    public var newFrames = 0
    /// Draws that encoded and committed a command buffer (the chain runs on each).
    public var draws = 0
    /// Draws that got a drawable different from the previous draw's (by `drawableID`).
    public var drawables = 0
    /// Presented handlers fired.
    public var presents = 0
    /// Ticks with no drawable, plus presents the system dropped (`presentedTime` 0) or that
    /// landed more than 100 ms after the commit.
    public var presentErrors = 0
    public var playerRate: Double = 0
    /// Item status and time control status, as `ready/playing`.
    public var playerStatus = "?"
    /// The item time for now minus the shown frame's time, in ms.
    public var driftMs: Double = 0
    /// True while a media data change notification is pending on the video output.
    public var outputSuspended = false
    /// The enabled audio tracks' codecs, and the codec of the track the tap is on.
    public var audioTracks = "none"
    public var tapTrack = ""

    public init() {}
}

/// One host time handed from the main thread to a drawable's presented handler.
private final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CFTimeInterval?
    var value: CFTimeInterval? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The rolling performance log: one line a second while playing, at
/// `~/Library/Logs/Home Video/perf.log`, so a slow Mac can be read without access to it. Kept under
/// `limit` bytes: trimmed to its newest half on launch and whenever a write would pass it.
public final class PerfLog {
    public static var defaultURL: URL {
        AppFolders.logs.appendingPathComponent("perf.log")
    }
    public static let limit = 1_000_000

    /// One logged second.
    public struct Entry {
        public var date: Date
        public var clipSize: CGSize
        public var codec: String
        public var sourceFPS: Double
        public var times: FrameTimes
        public var fps: Double
        public var drawRate: Double
        public var cpuPercent: Double
        /// Drawables reported presented in the last second.
        public var presents: Int
        /// The tail fields, after `cpu`.
        public var counters: PreviewCounters
        /// `ChainFingerprint` of the renderer's chain at this second, last on the line.
        public var chain: String

        public init(date: Date, clipSize: CGSize, codec: String, sourceFPS: Double, times: FrameTimes,
                    fps: Double, drawRate: Double, cpuPercent: Double, presents: Int = 0,
                    counters: PreviewCounters = PreviewCounters(), chain: String = "none") {
            self.presents = presents
            self.counters = counters
            self.chain = chain
            self.date = date
            self.clipSize = clipSize
            self.codec = codec
            self.sourceFPS = sourceFPS
            self.times = times
            self.fps = fps
            self.drawRate = drawRate
            self.cpuPercent = cpuPercent
        }
    }

    public let url: URL
    public let chip = PerfLog.sysctlString("machdep.cpu.brand_string") ?? "unknown"
    public let macOS: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Nil when the folder cannot be made.
    public init?(url: URL) {
        self.url = url
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            return nil
        }
        trimIfNeeded(adding: 0)
    }

    /// `2026-10-15T17:58:01Z chip="Apple M2" macos=15.1.0 clip=1920x1080 codec=avc1
    /// source_fps=29.97 decode_ms=0.4 chain_ms=4.8 present_ms=12.1 fps=30.0 draw_hz=60.0 cpu=38.2`
    public func line(_ e: Entry) -> String {
        let iso = ISO8601DateFormatter().string(from: e.date)
        return String(format: "%@ chip=\"%@\" macos=%@ clip=%dx%d codec=%@ source_fps=%.2f decode_ms=%.1f chain_ms=%.1f present_ms=%.1f presents=%d fps=%.1f draw_hz=%.1f cpu=%.1f",
                      iso, chip, macOS, Int(e.clipSize.width), Int(e.clipSize.height),
                      e.codec.isEmpty ? "?" : e.codec, e.sourceFPS, e.times.decode, e.times.chain,
                      e.times.present, e.presents, e.fps, e.drawRate, e.cpuPercent) + PerfLog.tail(e.counters)
            + " chain=\(e.chain)"
    }

    /// ` new_frames=30 draws=60 drawables=60 present_err=0 player_rate=1.00 player_status=ready/playing
    /// drift_ms=33 output_suspended=false audio=mp4a tap=mp4a`, appended to every line.
    static func tail(_ c: PreviewCounters) -> String {
        String(format: " new_frames=%d draws=%d drawables=%d present_err=%d player_rate=%.2f player_status=%@ drift_ms=%.0f output_suspended=%@ audio=%@ tap=%@",
               c.newFrames, c.draws, c.drawables, c.presentErrors, c.playerRate, c.playerStatus, c.driftMs,
               c.outputSuspended ? "true" : "false", c.audioTracks, c.tapTrack.isEmpty ? "none" : c.tapTrack)
    }

    public func write(_ e: Entry) {
        let data = Data((line(e) + "\n").utf8)
        trimIfNeeded(adding: data.count)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Keeps the newest half, cut at a line start, when the file plus `adding` would pass `limit`.
    func trimIfNeeded(adding: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size + adding > PerfLog.limit, let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(PerfLog.limit / 2)
        let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
        try? Data(tail[start...]).write(to: url)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// The process's CPU use between calls, in percent of one core (`getrusage`, user plus
    /// system time, over wall time).
    public struct CPUMeter {
        private var lastCPU: Double?
        private var lastWall: CFTimeInterval = 0

        public init() {}

        public static func processSeconds() -> Double {
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
            return s(u.ru_utime) + s(u.ru_stime)
        }

        public mutating func percent(now: CFTimeInterval) -> Double {
            let c = CPUMeter.processSeconds()
            defer {
                lastCPU = c
                lastWall = now
            }
            guard let lastCPU, now > lastWall else { return 0 }
            return (c - lastCPU) / (now - lastWall) * 100
        }
    }
}

/// Sums of the GPU and present times, written from Metal's completion threads and read on the
/// main actor.
private final class TimingSums: @unchecked Sendable {
    private struct Mean {
        var total = 0.0
        var count = 0
        var value: Double? { count > 0 ? total / Double(count) : nil }
        mutating func add(_ ms: Double) {
            total += ms
            count += 1
        }
    }

    private let lock = NSLock()
    private var chain = Mean()
    private var present = Mean()
    private var completed = Mean()

    func addChain(_ ms: Double) { lock.withLock { chain.add(ms) } }
    func addPresent(_ ms: Double) { lock.withLock { present.add(ms) } }
    func addCompleted(_ ms: Double) { lock.withLock { completed.add(ms) } }

    /// Presented handlers fired and the bad ones among them, for the one second counters.
    private var presentedTally = 0
    private var presentErrTally = 0
    func addPresented(error: Bool) {
        lock.withLock {
            presentedTally += 1
            if error { presentErrTally += 1 }
        }
    }

    /// Presents and present errors since the last call, then zeroed.
    func takePresented() -> (presents: Int, errors: Int) {
        lock.withLock {
            defer {
                presentedTally = 0
                presentErrTally = 0
            }
            return (presentedTally, presentErrTally)
        }
    }

    /// The means since the last call, then zeroed. A stage with no samples gives nil. Present
    /// falls back to commit-to-completed when no drawable reported its present in the window
    /// (on an Intel Mac under macOS 26 the presented handler never fires).
    func take() -> (chain: Double?, present: Double?, presents: Int) {
        lock.withLock {
            let r = (chain.value, present.value ?? completed.value, present.count)
            chain = Mean()
            present = Mean()
            completed = Mean()
            return r
        }
    }
}

/// Pulls frames from the `FrameSource` on the view's display link, runs the `SignalChain`,
/// and draws the 720 by 480 result into an `MTKView` as a 4:3 picture letterboxed in the view.
/// Measures frames presented per second.
///
/// One GPU path: CVMetalTextureCache wraps the BGRA pixel buffer, compute kernels build the
/// raster, one render pass draws it. Main actor only (see `FrameSource`).
@MainActor
@Observable
public final class PreviewRenderer: NSObject {
    /// Distinct source frames that went through the chain and were presented, per second.
    public private(set) var fps: Double = 0
    /// Display link ticks drawn per second (the chain re-runs on every tick).
    public private(set) var drawRate: Double = 0
    /// Distinct source frames presented since the file was opened.
    public private(set) var presentedFrames: UInt64 = 0
    /// Stage times averaged over the last half second.
    public private(set) var times = FrameTimes()
    public private(set) var errorText: String?
    public private(set) var libraryOrigin: ShaderLibrary.Origin?
    /// The last full second's counters, for the log, the readout and `--preview-check`.
    public private(set) var counters = PreviewCounters()

    public let chain: SignalChain
    /// While true the display link skips drawing, so an `Exporter` can use the chain's shared
    /// intermediates without the preview writing them from another command queue.
    public var isSuspended = false
    /// The source bypass: while true the viewer shows the decoded source through the
    /// framing layer alone, at the viewer's own resolution, in the same 4:3 rect with the same
    /// crop, pan, zoom, rotation and bars, so the picture does not move. The chain still runs
    /// on every frame (its frame history stays whole), so letting go shows the chain's picture
    /// on the next tick. Never part of the chain, its fingerprint or a sidecar.
    @ObservationIgnored public var bypass = false
    @ObservationIgnored private var bypassTexture: MTLTexture?
    /// The Display zoom: with a CRT layer on, the viewer's pinch and drag move a window
    /// over the Display canvas, so zooming in shows the mask's triads and the scanlines up close.
    /// 1 is the whole canvas, up to `DisplayZoom.range`'s top. Preview only, never part of the
    /// chain, an export or a sidecar.
    @ObservationIgnored public var displayZoom = DisplayZoom()
    @ObservationIgnored private var zoomPipeline: MTLRenderPipelineState?
    public var source: FrameSource? {
        didSet {
            // Another clip is a new run, as a seek is.
            source?.onSeek = { [weak self] in self?.noteSeek() }
            noteSeek()
            presentedFrames = 0
            appliedRotation = nil
            frameStamps.removeAll()
            fps = 0
            times = FrameTimes()
        }
    }

    /// The status bar's readout: `d 3.1 · c 4.8 · p 1.2 ms · 30.0 fps · new 30 draw 60 drw 60 pres 60 err 0`.
    public var readout: String {
        String(format: "d %.1f · c %.1f · p %.1f ms · %.1f fps · new %d draw %d drw %d pres %d err %d",
               times.decode, times.chain, times.present, fps, counters.newFrames, counters.draws,
               counters.drawables, counters.presents, counters.presentErrors)
    }

    /// One line a second to `PerfLog.defaultURL` while playing. Nil when the log cannot be opened.
    @ObservationIgnored public var perfLog: PerfLog? = PerfLog(url: PerfLog.defaultURL)

    @ObservationIgnored public let device: MTLDevice?
    @ObservationIgnored private var queue: MTLCommandQueue?
    @ObservationIgnored private var library: MTLLibrary?
    @ObservationIgnored private var pipeline: MTLRenderPipelineState?
    @ObservationIgnored private var textureCache: CVMetalTextureCache?
    @ObservationIgnored private weak var view: MTKView?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var frameStamps: [CFTimeInterval] = []
    @ObservationIgnored private var drawStamps: [CFTimeInterval] = []
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    @ObservationIgnored private var appliedRotation: Int?
    @ObservationIgnored private let sums = TimingSums()
    /// Drawables reported presented in the last half second window, for the log.
    @ObservationIgnored private var presentsPerWindow = 0
    @ObservationIgnored private var decodeSum = 0.0
    @ObservationIgnored private var decodeCount = 0
    @ObservationIgnored private var lastLog: CFTimeInterval = 0
    @ObservationIgnored private var cpu = PerfLog.CPUMeter()
    /// Tallies for the current second of `counters`, and when that second began.
    @ObservationIgnored private var drawTally = 0
    @ObservationIgnored private var drawableTally = 0
    @ObservationIgnored private var noDrawableTally = 0
    @ObservationIgnored private var lastDrawableID: Int?
    @ObservationIgnored private var countStart: CFTimeInterval = 0
    /// Whether the tick that asked for this draw pulled a new frame.
    @ObservationIgnored private var pendingNewFrame = false

    /// Near black around the 4:3 picture, matching the app's video surround. The app sizes the
    /// view to 4:3, so this only shows while a resize settles.
    public static let surround = MTLClearColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1)

    public init(chain: SignalChain) {
        self.chain = chain
        self.device = MTLCreateSystemDefaultDevice()
        super.init()
        do {
            try setUp()
        } catch {
            errorText = "\(error)"
        }
    }

    private func setUp() throws {
        guard let device else { throw ShaderLibrary.LoadError.noLibrary("no Metal device") }
        queue = device.makeCommandQueue()
        let (lib, origin) = try ShaderLibrary.make(device: device)
        library = lib
        libraryOrigin = origin
        let d = MTLRenderPipelineDescriptor()
        d.label = "Preview"
        d.vertexFunction = lib.makeFunction(name: "preview_vertex")
        d.fragmentFunction = lib.makeFunction(name: "preview_fragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        d.label = "Preview Display zoom"
        d.fragmentFunction = lib.makeFunction(name: "preview_display_zoom")
        zoomPipeline = try device.makeRenderPipelineState(descriptor: d)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
    }

    /// An MTKView that never takes the mouse, so the SwiftUI gestures laid over it (the
    /// viewer's drag, pinch, double-click and menu) get the events instead.
    final class PassThroughView: MTKView {
        /// The renderer's frame, run from inside MTKView's own draw cycle.
        var onDraw: (() -> Void)?
        #if os(macOS)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        // MTKView hands out a fresh `currentDrawable` only after a drawing function returns
        // ("The view changes the value of this property only after returning from a drawing
        // function", MTKView.currentDrawable). The display link therefore calls `draw()`, which
        // calls this, and the drawable is released when it returns.
        override func draw(_ dirtyRect: NSRect) { onDraw?() }
        #else
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func draw(_ rect: CGRect) { onDraw?() }
        #endif
    }

    /// Makes the view this renderer draws into, with its display link running.
    public func makeView() -> MTKView {
        let v = PassThroughView(frame: .zero, device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.clearColor = PreviewRenderer.surround
        // Explicit drawing mode (MTKView: "set isPaused to true and enableSetNeedsDisplay to
        // false", then call draw()). The display link below calls draw() once per tick.
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        // Set on purpose, at the values the present path assumes: a present goes out on the
        // command buffer's schedule, not with a Core Animation transaction, synced to the
        // display, from a pool of three, and the drawable follows the backing scale.
        v.presentsWithTransaction = false
        v.autoResizeDrawable = true
        if let layer = v.layer as? CAMetalLayer {
            #if os(macOS)
            layer.displaySyncEnabled = true
            #endif
            layer.maximumDrawableCount = 3
        }
        v.onDraw = { [weak self] in self?.drawPending() }
        attach(to: v)
        return v
    }

    public func attach(to view: MTKView) {
        detach()
        self.view = view
        #if os(macOS)
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        #else
        // iOS has no per view display link. The screen's link ticks at the display's rate.
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public func detach() {
        displayLink?.invalidate()
        displayLink = nil
        view = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if isSuspended { return }
        let now = CACurrentMediaTime()
        var isNew = false
        if let source {
            let asked = CACurrentMediaTime()
            if source.newFrame(atHostTime: link.targetTimestamp) != nil {
                isNew = true
                decodeSum += (CACurrentMediaTime() - asked) * 1000
                decodeCount += 1
            }
        }
        // Through MTKView's draw cycle, never `draw(newFrame:)` directly: called outside it,
        // `currentDrawable` stays the first drawable for the life of the view, every tick
        // re-presents it, the presented handler never fires again (`presents=0`), and the
        // picture shows only when the compositor happens to re-read that surface. An Intel Mac
        // can hide this. Apple silicon shows a frame every few seconds.
        pendingNewFrame = isNew
        view?.draw()
        drawStamps.append(now)
        if isNew {
            presentedFrames &+= 1
            frameStamps.append(now)
        }
        takeCounters(now: now)
        publishRates(now: now)
    }

    /// Closes a second of counts into `counters`, scaled to per second by the real elapsed time.
    private func takeCounters(now: CFTimeInterval) {
        guard countStart > 0 else {
            countStart = now
            return
        }
        let elapsed = now - countStart
        guard elapsed >= 1 else { return }
        countStart = now
        func perSecond(_ n: Int) -> Int { Int((Double(n) / elapsed).rounded()) }
        let presented = sums.takePresented()
        var c = PreviewCounters()
        c.newFrames = perSecond(source?.takeNewFrameCount() ?? 0)
        c.draws = perSecond(drawTally)
        c.drawables = perSecond(drawableTally)
        c.presents = perSecond(presented.presents)
        c.presentErrors = perSecond(presented.errors + noDrawableTally)
        if let source {
            let state = source.playerState
            c.playerRate = state.rate
            c.playerStatus = state.status
            c.driftMs = source.driftMs(atHostTime: now)
            c.outputSuspended = source.outputSuspended
            c.audioTracks = source.audioTracks
            c.tapTrack = source.tapTrackCodec
        }
        counters = c
        drawTally = 0
        drawableTally = 0
        noDrawableTally = 0
    }

    private func publishRates(now: CFTimeInterval) {
        guard now - lastPublish >= 0.5 else { return }
        lastPublish = now
        let window: CFTimeInterval = 1.0
        frameStamps.removeAll { now - $0 > window }
        drawStamps.removeAll { now - $0 > window }
        fps = Double(frameStamps.count) / window
        drawRate = Double(drawStamps.count) / window
        let taken = sums.take()
        // Decode keeps its last value while paused (no new frames). The other two run every tick,
        // so a window without samples reads 0 rather than a stale number.
        times = FrameTimes(decode: decodeCount > 0 ? decodeSum / Double(decodeCount) : times.decode,
                           chain: taken.chain ?? 0, present: taken.present ?? 0)
        presentsPerWindow = taken.presents
        decodeSum = 0
        decodeCount = 0
        logIfPlaying(now: now)
    }

    /// One line a second while the clip plays, with the readout's numbers as they are shown.
    private func logIfPlaying(now: CFTimeInterval) {
        guard let perfLog, let source, source.isPlaying else {
            lastLog = 0
            return
        }
        // The first second after play starts only primes the CPU meter.
        guard lastLog > 0 else {
            lastLog = now
            _ = cpu.percent(now: now)
            return
        }
        guard now - lastLog >= 1 else { return }
        lastLog = now
        perfLog.write(PerfLog.Entry(date: Date(), clipSize: source.naturalSize, codec: source.codec,
                                    sourceFPS: source.nominalFrameRate, times: times, fps: fps,
                                    drawRate: drawRate, cpuPercent: cpu.percent(now: now),
                                    presents: counters.presents, counters: counters,
                                    chain: ChainFingerprint.of(chain)))
    }

    /// Set by a seek (or a new source) until the next new frame.
    @ObservationIgnored private(set) var seekPending = false

    /// The source seeked: the chain's frame history (the Film's hold and last frame, the
    /// Telecine's cached frames and lag, the tape's previous fields) is cleared before the frame
    /// the seek lands on, as the exporter clears it before frame 0.
    public func noteSeek() { seekPending = true }

    /// Before the chain encodes a frame. Ticks that still show the frame from before the seek
    /// leave the history alone, so the reset lands just before the first frame after it, and a
    /// paused frame after a seek is drawn fresh.
    func prepareChain(newFrame: Bool) {
        guard seekPending, newFrame else { return }
        chain.reset()
        seekPending = false
    }

    /// MTKView's drawing function, from `PassThroughView.draw(_:)`.
    private func drawPending() {
        draw(newFrame: pendingNewFrame)
        pendingNewFrame = false
    }

    private func draw(newFrame: Bool) {
        guard let view, let queue, let pipeline, let library, let device,
              let cb = queue.makeCommandBuffer() else { return }
        cb.label = "Home Video frame"

        var raster: MTLTexture?
        var heldTexture: CVMetalTexture?
        prepareChain(newFrame: newFrame)
        if let pb = source?.lastFrame, let (srcTex, cvTex) = makeTexture(pb) {
            heldTexture = cvTex
            // The track's rotation arrives with the async property load.
            // Applied when it changes, so the sidebar's Rotation still overrides it.
            if let r = source?.rotation, r != appliedRotation {
                chain.framing.rotation = r
                appliedRotation = r
            }
            // The deck's on-screen display shows the transport: PAUSE while paused.
            for case let osd as OSDLayer in chain.layers where osd.paused == (source?.isPlaying ?? false) {
                osd.paused = !(source?.isPlaying ?? false)
            }
            let ctx = FrameContext(frameIndex: source?.frameCount ?? 0,
                                   time: source?.lastFrameTime ?? 0,
                                   sourceSize: PreviewRenderer.displaySize(of: pb),
                                   rasterSize: CGSize(width: SignalChain.rasterWidth,
                                                      height: SignalChain.rasterHeight))
            do {
                raster = try chain.encodeOutput(commandBuffer: cb, source: srcTex, frame: ctx,
                                                device: device, library: library)
                if bypass, let shown = encodeBypass(commandBuffer: cb, source: srcTex, frame: ctx,
                                                    drawableSize: view.drawableSize, device: device) {
                    raster = shown
                }
            } catch {
                errorText = "\(error)"
            }
        }

        // The drawable is fetched after the chain is encoded, as late as possible (MTKView,
        // CAMetalLayer), so a pool slot is held only for the preview pass. Without one the chain
        // still commits, so its frame history stays whole.
        let hold = TextureHold(heldTexture)
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            noDrawableTally += 1
            cb.addCompletedHandler { _ in withExtendedLifetime(hold) {} }
            cb.commit()
            return
        }
        drawTally += 1
        #if targetEnvironment(simulator)
        // The Simulator's Metal has no drawable ids or presented handlers, so every draw
        // counts as a fresh drawable there and presents are counted at command completion.
        drawableTally += 1
        #else
        if drawable.drawableID != lastDrawableID {
            drawableTally += 1
            lastDrawableID = drawable.drawableID
        }
        #endif
        pass.colorAttachments[0].clearColor = PreviewRenderer.surround
        pass.colorAttachments[0].loadAction = .clear
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.label = "Preview"
            if let raster {
                let size = view.drawableSize
                // A square pixel picture is shown at its own shape: the camera's frame, 16:9 for
                // the phone, or the source itself with every stage off. The raster's
                // 10:11 pixels are shown 4:3.
                let aspect = chain.output.isSquare && !bypass
                    ? CGFloat(raster.width) / CGFloat(raster.height) : FramingMath.rasterDisplayAspect
                let r = FramingMath.fit(aspect: aspect, in: size)
                enc.setViewport(MTLViewport(originX: Double(r.minX), originY: Double(r.minY),
                                            width: Double(r.width), height: Double(r.height),
                                            znear: 0, zfar: 1))
                if chain.displayIsOn, !bypass, displayZoom.isZoomed, let zoomPipeline {
                    var window = displayZoom.window(canvasWidth: raster.width, viewWidth: Double(r.width))
                    enc.setRenderPipelineState(zoomPipeline)
                    enc.setFragmentBytes(&window, length: window.count * 4, index: 0)
                } else {
                    enc.setRenderPipelineState(pipeline)
                }
                enc.setFragmentTexture(raster, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
        }
        let sums = self.sums
        // The commit time, set on the main thread just before the commit, for the present time.
        let commitBox = TimeBox()
        #if targetEnvironment(simulator)
        cb.addCompletedHandler { _ in
            if let c = commitBox.value { sums.addPresent((CACurrentMediaTime() - c) * 1000) }
            sums.addPresented(error: false)
        }
        #else
        drawable.addPresentedHandler { d in
            // presentedTime can read 0 on macOS. The handler then fires at the present itself.
            let t = d.presentedTime > 0 ? d.presentedTime : CACurrentMediaTime()
            var late = false
            if let c = commitBox.value {
                sums.addPresent((t - c) * 1000)
                late = t - c > 0.1
            }
            sums.addPresented(error: d.presentedTime == 0 || late)
        }
        #endif
        // The handler is registered before the present, the present goes on the command buffer
        // before commit, and nothing calls `drawable.present()` too (MTLCommandBuffer.present).
        cb.present(drawable)
        // Keep the CVMetalTexture alive until the GPU has read it.
        cb.addCompletedHandler { b in
            withExtendedLifetime(hold) {}
            if b.gpuEndTime > b.gpuStartTime, b.gpuStartTime > 0 {
                sums.addChain((b.gpuEndTime - b.gpuStartTime) * 1000)
            }
            if let c = commitBox.value { sums.addCompleted((CACurrentMediaTime() - c) * 1000) }
        }
        commitBox.value = CACurrentMediaTime()
        cb.commit()
    }

    /// The bypass picture: the framing layer alone, from the decoded source into a texture the
    /// size of the 4:3 rect it is drawn in (at most 4096 wide), so the source is seen at the
    /// viewer's resolution rather than through the 720 by 480 raster. Run after the chain,
    /// which has prepared the framing layer.
    private func encodeBypass(commandBuffer: MTLCommandBuffer, source: MTLTexture, frame: FrameContext,
                              drawableSize: CGSize, device: MTLDevice) -> MTLTexture? {
        let rect = FramingMath.fit(aspect: FramingMath.rasterDisplayAspect, in: drawableSize)
        let w = min(4096, max(4, Int(rect.width.rounded())))
        let h = min(3072, max(3, Int(rect.height.rounded())))
        if bypassTexture?.width != w || bypassTexture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            bypassTexture = device.makeTexture(descriptor: d)
            bypassTexture?.label = "bypass"
        }
        guard let out = bypassTexture else { return nil }
        var ctx = frame
        ctx.rasterSize = CGSize(width: w, height: h)
        chain.framing.encode(commandBuffer: commandBuffer, in: source, out: out, frame: ctx)
        return out
    }

    private func makeTexture(_ pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard let textureCache else { return nil }
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil,
                                                               .bgra8Unorm, w, h, 0, &cv)
        guard status == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return (tex, cv)
    }

    /// Pixel size corrected by the buffer's pixel aspect ratio, if it carries one.
    static func displaySize(of pb: CVPixelBuffer) -> CGSize {
        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        if let par = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any],
           let hs = (par[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber)?.doubleValue,
           let vs = (par[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber)?.doubleValue,
           hs > 0, vs > 0 {
            return CGSize(width: w * CGFloat(hs / vs), height: h)
        }
        return CGSize(width: w, height: h)
    }
}
