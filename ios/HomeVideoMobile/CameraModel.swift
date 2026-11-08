import AVFoundation
import CoreMedia
import Metal
import MetalKit
import Observation
import os
import UIKit

/// The camera screen: every camera frame goes through the chain as it arrives,
/// with the current Look, and is drawn at once, so the picture is the processed picture with
/// no wait for a display link. While recording, the same frame is also converted and written
/// in the export's format by `CameraRecorder`. Uses the editor's own chain, so a Look picked
/// here is the editor's Look, and suspends the editor's preview while open (the chain's
/// intermediates are shared, as with an export).
@MainActor
@Observable
final class CameraModel {
    enum State: Equatable {
        case starting
        case noCamera
        case denied(String)
        case failed(String)
        case live
        case recording
        case saving
        case saved(frames: Int, dropped: Int)
    }

    private(set) var state: State = .starting
    /// Readouts, refreshed twice a second.
    private(set) var fps: Double = 0
    private(set) var chainMs: Double = 0
    private(set) var latencyMs: Double = 0
    private(set) var dropped = 0
    private(set) var recordSeconds: Double = 0
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private(set) var usingFixture = false
    /// The lens's zoom factor as last asked for, and the buttons the device offers.
    private(set) var zoom: CGFloat = 1
    var lens: CameraLens? { feed?.lens }

    let model: MobileModel
    private var chain: SignalChain { model.chain }
    @ObservationIgnored private var feed: CameraFeed?
    @ObservationIgnored private var device: MTLDevice?
    @ObservationIgnored private var queue: MTLCommandQueue?
    @ObservationIgnored private var library: MTLLibrary?
    @ObservationIgnored private var pipeline: MTLRenderPipelineState?
    @ObservationIgnored private var textureCache: CVMetalTextureCache?
    @ObservationIgnored weak var view: MTKView?
    @ObservationIgnored private var recorder: CameraRecorder?
    @ObservationIgnored private var recordStart: CMTime?
    /// Three converters in turn, so a frame's bytes are read by the writer while the next
    /// frame is converted. A frame that finds all three busy is not recorded (and counted).
    @ObservationIgnored private var converters: [RasterConverter] = []
    @ObservationIgnored private var convertersBusy = [false, false, false]
    @ObservationIgnored private var nextConverter = 0
    @ObservationIgnored private var recordDrops = 0
    @ObservationIgnored private var savedRotation = 0
    @ObservationIgnored private var frameIndex: UInt64 = 0
    @ObservationIgnored private var firstTime: CMTime?
    /// The newest frame waiting for the main thread. A newer one replaces it (counted as
    /// dropped), so the picture never runs behind the camera.
    @ObservationIgnored private let slot = OSAllocatedUnfairLock<FrameSlot>(initialState: FrameSlot())
    @ObservationIgnored private let stats = CameraStats()
    @ObservationIgnored private var publishTimer: Timer?

    init(model: MobileModel) {
        self.model = model
    }

    // MARK: Open and close

    /// Opens the camera: asks for the camera and then the microphone, the first time only and
    /// only here, never at launch. With no camera (the Simulator) it says so and asks nothing.
    func open() async {
        model.source?.pause()
        model.renderer.isSuspended = true
        savedRotation = chain.framing.rotation
        // The feed hands over upright frames.
        chain.framing.rotation = 0
        chain.reset()
        setUpMetal()
        var made: CameraFeed?
        #if DEBUG || HV_STORE_SCREENS
        if let url = FixtureFeed.fromLaunch {
            let f = FixtureFeed(url: url)
            f.rotationAngle = Self.captureAngle(Self.screenOrientation)
            made = f
            usingFixture = true
        }
        #endif
        if made == nil {
            guard CaptureFeed.camera != nil else {
                state = .noCamera
                return
            }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied("Home Video needs the camera to record. You can allow it in Settings.")
                return
            }
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            do {
                made = try CaptureFeed(withAudio: mic, angle: Self.captureAngle(Self.screenOrientation))
            } catch {
                state = .failed("\(error)")
                return
            }
        }
        guard let feed = made else { return }
        self.feed = feed
        zoom = feed.lens?.zoom ?? 1
        model.stills.clear()
        nextStills = 0
        // Only the camera's cards on screen are refreshed. One coming into view without a
        // still from the latest frame brings the next refresh forward.
        model.stills.watched = LookStills.camera
        model.stills.onStaleCardShown = { [weak self] in self?.stillsSoon() }
        let slot = self.slot
        let stats = self.stats
        feed.onVideo = { [weak self] pb, time in
            let wasWaiting = slot.withLock { s -> Bool in
                let waiting = s.frame != nil
                if waiting { s.replaced += 1 }
                s.frame = Unchecked(value: (pb, time))
                return waiting
            }
            stats.arrived()
            // A frame already waiting has a main thread hop on the way, which takes this one.
            guard !wasWaiting else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.takeFrame() } }
        }
        // The recorder is read off the main actor on purpose: it is set before the first sound
        // is wanted, and it is a serial queue of its own.
        let recorderBox = currentRecorder
        feed.onAudio = { sample in recorderBox.value?.appendAudio(sample) }
        feed.start()
        state = .live
        publishTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    func close() {
        if recorder != nil { stopRecording() }
        feed?.stop()
        feed = nil
        OrientationLock.release()
        publishTimer?.invalidate()
        publishTimer = nil
        chain.framing.rotation = savedRotation
        chain.reset()
        // A recording on its way to Photos removes its own file once saved.
        if state != .saving { TempFiles.remove(TempFiles.camera) }
        // The carousel goes back to the clip's own frame, every Look drawn.
        model.stills.watched = nil
        model.stills.onStaleCardShown = nil
        model.stills.clear()
        if model.source != nil { model.stills.schedule(for: model, after: 0.3) }
        model.renderer.isSuspended = false
        model.renderer.noteSeek()
        // The capture session took the audio session for recording. Back to playback.
        HomeVideoMobileApp.activateAudio()
    }

    private func setUpMetal() {
        guard device == nil else { return }
        device = model.renderer.device
        guard let device else { return }
        queue = device.makeCommandQueue()
        do {
            let (lib, _) = try ShaderLibrary.make(device: device)
            library = lib
            let d = MTLRenderPipelineDescriptor()
            d.label = "Camera preview"
            d.vertexFunction = lib.makeFunction(name: "preview_vertex")
            d.fragmentFunction = lib.makeFunction(name: "preview_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            state = .failed("\(error)")
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
    }

    // MARK: Frames

    /// The recorder as the audio queue reads it.
    @ObservationIgnored private let currentRecorder = UncheckedBox<CameraRecorder>()

    private func takeFrame() {
        guard let frame = slot.withLock({ s -> Unchecked<(CVPixelBuffer, CMTime)>? in
            defer { s.frame = nil }
            return s.frame
        }) else { return }
        pendingFrame = frame.value
        // The carousel's stills from the camera, once it has settled and then every few
        // seconds, so a hand over the lens at the start does not stay on the cards. Never
        // while recording: the recording keeps the frame time to itself.
        let now = CACurrentMediaTime()
        if !isRecording, frameIndex >= 20, now >= nextStills {
            nextStills = now + Self.stillsInterval
            model.stills.schedule(frame: frame.value.0, like: model.chain)
        }
        if let view, view.window != nil {
            view.draw()
        } else {
            render(into: nil)
        }
        pendingFrame = nil
    }

    @ObservationIgnored private var pendingFrame: (CVPixelBuffer, CMTime)?
    /// When the carousel's stills are next made from the live picture (`CACurrentMediaTime`).
    @ObservationIgnored private var nextStills: CFTimeInterval = 0
    static let stillsInterval: CFTimeInterval = 3

    /// A card came into view with an old still: the next refresh in a moment, not in 3 s.
    private func stillsSoon() {
        nextStills = min(nextStills, CACurrentMediaTime() + 0.3)
    }

    /// From the view's draw: the waiting frame through the chain and onto the screen.
    func drawFromView() { render(into: view) }

    private func render(into view: MTKView?) {
        guard let (pb, time) = pendingFrame, let device, let queue, let library, let pipeline,
              let cb = queue.makeCommandBuffer(), let (srcTex, cvTex) = makeTexture(pb) else { return }
        cb.label = "Home Video camera frame"
        if firstTime == nil { firstTime = time }
        let ctx = FrameContext(frameIndex: frameIndex, time: (time - (firstTime ?? time)).seconds,
                               sourceSize: PreviewRenderer.displaySize(of: pb),
                               rasterSize: CGSize(width: SignalChain.rasterWidth, height: SignalChain.rasterHeight))
        frameIndex &+= 1
        let raster: MTLTexture
        do {
            raster = try chain.encodeOutput(commandBuffer: cb, source: srcTex, frame: ctx, device: device,
                                            library: library)
        } catch {
            state = .failed("\(error)")
            return
        }
        if let recorder { encodeRecording(cb, raster: raster, recorder: recorder, time: time) }

        let hold = Unchecked(value: cvTex)
        let stats = self.stats
        cb.addCompletedHandler { b in
            withExtendedLifetime(hold) {}
            if b.gpuEndTime > b.gpuStartTime, b.gpuStartTime > 0 { stats.chain((b.gpuEndTime - b.gpuStartTime) * 1000) }
        }
        if let view, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable {
            pass.colorAttachments[0].clearColor = PreviewRenderer.surround
            pass.colorAttachments[0].loadAction = .clear
            if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
                let aspect = chain.output.isSquare
                    ? CGFloat(raster.width) / CGFloat(raster.height) : FramingMath.rasterDisplayAspect
                let r = FramingMath.fit(aspect: aspect, in: view.drawableSize)
                enc.setViewport(MTLViewport(originX: Double(r.minX), originY: Double(r.minY), width: Double(r.width),
                                            height: Double(r.height), znear: 0, zfar: 1))
                enc.setRenderPipelineState(pipeline)
                enc.setFragmentTexture(raster, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
            // Camera time to the picture on the glass, less the sensor's exposure and readout
            // before the stamp and the panel's scan after the present.
            let stamp = time.seconds
            #if targetEnvironment(simulator)
            cb.addCompletedHandler { _ in stats.latency((CACurrentMediaTime() - stamp) * 1000) }
            #else
            drawable.addPresentedHandler { d in
                if d.presentedTime > 0 { stats.latency((d.presentedTime - stamp) * 1000) }
            }
            #endif
            cb.present(drawable)
        }
        cb.commit()
        stats.drawn()
    }

    private func makeTexture(_ pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard let textureCache else { return nil }
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cv)
                == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return (tex, cv)
    }

    // MARK: Recording

    var isRecording: Bool { state == .recording }

    /// Starts a file in the export sheet's codec and quality at the Output size (SD unless the
    /// export sheet picked another), with the chain's sound.
    func startRecording() {
        guard state == .live || isSaved, let device, let library, let feed else { return }
        let settings = ExportSettings(codec: model.exportSettings.codec, quality: model.exportSettings.quality,
                                      container: .mp4)
        guard let folder = try? TempFiles.emptied(TempFiles.camera) else { return }
        let url = folder.appendingPathComponent(settings.fileName(for: URL(fileURLWithPath: "Camera.mov"), at: Date()))
        let output = chain.output
        let size = chain.outputSize
        do {
            converters = try (0..<3).map { _ in
                try RasterConverter(device: device, library: library, format: .yuv422,
                                    matrix: output.isHD ? .bt709 : .bt601, width: size.width, height: size.height)
            }
            convertersBusy = [false, false, false]
            let r = try CameraRecorder(url: url, settings: settings, output: output, size: size,
                                       picked: !(chain.vhs?.output.isAuto ?? true),
                                       audio: chain.audio.isPassthrough ? nil : chain.audio.spec,
                                       withSound: feed.hasAudio)
            recorder = r
            currentRecorder.value = r
        } catch {
            state = .failed("\(error)")
            return
        }
        recordDrops = 0
        recordStart = nil
        recordSeconds = 0
        // The screen holds its orientation while recording, so the file is one way up and
        // matches what was on the screen throughout.
        OrientationLock.hold()
        // The tape starts with the recording: no history from the frames before it.
        chain.reset()
        for case let osd as OSDLayer in chain.layers { osd.paused = false }
        state = .recording
    }

    private func encodeRecording(_ cb: MTLCommandBuffer, raster: MTLTexture, recorder: CameraRecorder,
                                 time: CMTime) {
        if recordStart == nil { recordStart = time }
        recordSeconds = (time - (recordStart ?? time)).seconds
        let order = (0..<3).map { ($0 + nextConverter) % 3 }
        guard let i = order.first(where: { !convertersBusy[$0] }) else {
            recordDrops += 1
            return
        }
        nextConverter = (i + 1) % 3
        convertersBusy[i] = true
        let c = converters[i]
        c.encode(commandBuffer: cb, raster: raster)
        let bytes = Unchecked(value: c.buffer)
        let row = c.bytesPerRow, rows = c.height
        cb.addCompletedHandler { [weak self] _ in
            recorder.appendVideo(bytes: bytes, bytesPerRow: row, rows: rows, at: time) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.convertersBusy[i] = false } }
            }
        }
    }

    /// Ends the file and adds it to Photos (add-only access, as the export does).
    func stopRecording() {
        guard let recorder else { return }
        self.recorder = nil
        currentRecorder.value = nil
        OrientationLock.release()
        state = .saving
        let extra = recordDrops
        Task { @MainActor in
            do {
                let counts = try await recorder.finish()
                try await MobileModel.addToPhotos(recorder.url)
                // In Photos now, so the app's copy goes.
                TempFiles.remove(recorder.url)
                state = .saved(frames: counts.written, dropped: counts.dropped + extra)
            } catch {
                // Kept while the camera is open, gone once it closes.
                if feed == nil { TempFiles.remove(recorder.url) }
                state = .failed("\(error)")
            }
        }
    }

    private var isSaved: Bool {
        if case .saved = state { return true }
        return false
    }

    /// Back to the live picture after a saved message.
    func dismissResult() {
        if isSaved { state = .live }
    }

    // MARK: Orientation

    /// The way the screen is turned now.
    static var screenOrientation: UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.effectiveGeometry.interfaceOrientation ?? .portrait
    }

    /// The capture connection's clockwise turn for a screen orientation, so the frames are
    /// upright on that screen. The back sensor's own frame is upright with the screen in
    /// `landscapeRight` (the top of the phone to the left). Interface and device orientations
    /// name the two landscapes the opposite ways round, so this reads the interface's.
    nonisolated static func captureAngle(_ o: UIInterfaceOrientation) -> CGFloat {
        switch o {
        case .landscapeRight: 0
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }

    /// The screen turned: the frames follow it, except while recording (the screen is held).
    func screenTurned() {
        guard let feed, !isRecording, state != .saving else { return }
        let angle = Self.captureAngle(Self.screenOrientation)
        if feed.rotationAngle != angle { feed.rotationAngle = angle }
    }

    // MARK: Lens

    /// A lens button: ramps to its factor.
    func setZoom(_ factor: CGFloat, animated: Bool) {
        guard let lens else { return }
        let f = min(max(factor, lens.zoomRange.lowerBound), lens.zoomRange.upperBound)
        lens.setZoom(f, animated: animated)
        zoom = f
    }

    /// Tap to focus and expose: a point on the camera view, through the picture's place in it
    /// and Framing's crop, to the sensor's own frame. False when the device can do neither.
    func focus(at p: CGPoint, in size: CGSize) -> Bool {
        guard let lens, let feed else { return false }
        let aspect = chain.output.isSquare
            ? CGFloat(chain.outputSize.width) / CGFloat(chain.outputSize.height) : FramingMath.rasterDisplayAspect
        let r = FramingMath.fit(aspect: aspect, in: size)
        guard r.width > 0, r.height > 0 else { return false }
        let u = min(max((p.x - r.minX) / r.width, 0), 1), v = min(max((p.y - r.minY) / r.height, 0), 1)
        let crop = chain.framing.cropRect
        let a = crop.minX + u * crop.width, b = crop.minY + v * crop.height
        return lens.focus(at: Self.sensorPoint(a, b, angle: feed.rotationAngle))
    }

    /// A point of the upright frame on the sensor's unturned frame, for a clockwise turn.
    nonisolated static func sensorPoint(_ a: CGFloat, _ b: CGFloat, angle: CGFloat) -> CGPoint {
        switch Int(angle) {
        case 90: CGPoint(x: b, y: 1 - a)
        case 180: CGPoint(x: 1 - a, y: 1 - b)
        case 270: CGPoint(x: 1 - b, y: a)
        default: CGPoint(x: a, y: b)
        }
    }

    // MARK: Readouts

    private func publish() {
        let s = stats.take()
        fps = s.fps
        chainMs = s.chainMs
        latencyMs = s.latencyMs
        dropped = (feed?.droppedFrames ?? 0) + slot.withLock { $0.replaced } + recordDrops
        thermal = ProcessInfo.processInfo.thermalState
    }

    #if DEBUG
    /// Test builds only: the line the camera's readout shows. Release builds show no numbers.
    var readout: String {
        String(format: "%.1f fps · chain %.1f ms · lag %.0f ms · dropped %d", fps, chainMs, latencyMs, dropped)
    }

    var thermalText: String {
        switch thermal {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    #endif
}

/// The frame waiting for the main thread, and how many were replaced before it was taken.
struct FrameSlot: @unchecked Sendable {
    var frame: Unchecked<(CVPixelBuffer, CMTime)>?
    var replaced = 0
}

/// A reference read from more than one thread where the writes are ordered by the app's flow.
final class UncheckedBox<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Counts and means for the readouts, from the GPU's and the feed's threads.
final class CameraStats: @unchecked Sendable {
    private let lock = NSLock()
    private var drawnCount = 0
    private var chainSum = 0.0, chainN = 0
    private var latencySum = 0.0, latencyN = 0
    private var since = CACurrentMediaTime()
    private var last = (fps: 0.0, chainMs: 0.0, latencyMs: 0.0)

    func arrived() {}
    func drawn() { lock.withLock { drawnCount += 1 } }
    func chain(_ ms: Double) { lock.withLock { chainSum += ms; chainN += 1 } }
    func latency(_ ms: Double) { lock.withLock { latencySum += ms; latencyN += 1 } }

    /// The means since the last call. A window with no samples keeps the last value shown.
    func take() -> (fps: Double, chainMs: Double, latencyMs: Double) {
        lock.withLock {
            let now = CACurrentMediaTime()
            let elapsed = max(now - since, 1e-3)
            since = now
            last.fps = Double(drawnCount) / elapsed
            if chainN > 0 { last.chainMs = chainSum / Double(chainN) }
            if latencyN > 0 { last.latencyMs = latencySum / Double(latencyN) }
            drawnCount = 0
            chainSum = 0; chainN = 0
            latencySum = 0; latencyN = 0
            return last
        }
    }
}
