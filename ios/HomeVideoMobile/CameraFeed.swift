import AVFoundation
import CoreMedia
import CoreImage
import CoreVideo
import os
import UIKit

/// Where the camera screen's frames and sound come from: the phone's camera and microphone, or
/// in test builds a fixture file played at its own pace through the same callbacks
/// (`FixtureFeed`). Video arrives as BGRA pixel buffers stamped on the host clock, sound as the
/// microphone's own sample buffers on the same clock. Both callbacks run off the main thread.
protocol CameraFeed: AnyObject, Sendable {
    /// Called on the feed's video queue for every frame, with its presentation time.
    var onVideo: (@Sendable (CVPixelBuffer, CMTime) -> Void)? { get set }
    /// Called on the feed's audio queue for every buffer of sound.
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)? { get set }
    /// Frames the feed itself dropped (the capture output's late frames).
    var droppedFrames: Int { get }
    /// The clockwise turn applied to the sensor's frames (0, 90, 180, 270), set from the way the
    /// screen is turned (`CameraModel.captureAngle`) so the picture is upright on it. It holds
    /// still while recording.
    var rotationAngle: CGFloat { get set }
    /// The lens controls, nil where there are none.
    var lens: CameraLens? { get }
    var hasAudio: Bool { get }
    func start()
    func stop()
}

/// Zoom, focus and exposure on the camera, where the device offers them. Zoom factors are the
/// device's own (`videoZoomFactor`). The labels the iOS Camera shows are the factor times
/// `displayMultiplier` (0.5 on a phone whose widest lens is the ultra wide).
protocol CameraLens: AnyObject {
    /// The factors for the lens buttons: the widest, each switch-over to another lens, and 2x
    /// on the main lens where the range allows.
    var stops: [CGFloat] { get }
    var displayMultiplier: CGFloat { get }
    var zoomRange: ClosedRange<CGFloat> { get }
    /// The main lens's factor, the 1x the camera opens at.
    var mainZoom: CGFloat { get }
    var zoom: CGFloat { get }
    /// `animated` ramps to the factor, as a lens button does. Otherwise it is set at once (pinch).
    func setZoom(_ factor: CGFloat, animated: Bool)
    /// Focus and exposure at a point of the sensor's own frame (0 to 1, unrotated). False when
    /// the device can do neither.
    func focus(at point: CGPoint) -> Bool
}

/// The camera and microphone through one `AVCaptureSession`: 1280 by 720 at 30 frames a second
/// from the back camera into a video data output asking for BGRA (the chain's input, the
/// same as the decoder's on the file path), and the microphone into an audio data output. The
/// late frames are discarded so the picture stays live rather than falling behind. The camera
/// is the virtual device that spans every back lens where there is one, so zoom switches lenses
/// as the iOS Camera does.
final class CaptureFeed: NSObject, CameraFeed, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onVideo: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    private let dropped = OSAllocatedUnfairLock(initialState: 0)
    var droppedFrames: Int { dropped.withLock { $0 } }
    private(set) var hasAudio = false
    private(set) var lens: CameraLens?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "homevideo.camera.session")
    private let videoQueue = DispatchQueue(label: "homevideo.camera.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "homevideo.camera.audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    /// The angle comes from the screen, not the `RotationCoordinator`'s horizon level angle,
    /// which follows gravity while the screen follows the interface orientation, so the two can
    /// disagree and turn the picture wrong.
    var rotationAngle: CGFloat = 90 {
        didSet {
            let angle = rotationAngle
            sessionQueue.async { [weak self] in self?.applyRotation(angle) }
        }
    }

    /// The back camera, nil where there is none (the Simulator): the virtual device over every
    /// back lens first, so the lens buttons come from the device itself, never a model name.
    static var camera: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back
        ).devices.first ?? AVCaptureDevice.default(for: .video)
    }

    /// Builds the session. Throws when the camera cannot be opened. `withAudio` false records
    /// a silent picture (the microphone was refused).
    init(withAudio: Bool, angle: CGFloat) throws {
        rotationAngle = angle
        super.init()
        guard let camera = Self.camera else { throw CameraError.noCamera }
        let deviceLens = DeviceLens(device: camera)
        lens = deviceLens
        // A virtual device starts on its widest lens. The iOS Camera opens at 1x.
        deviceLens.setZoom(deviceLens.mainZoom, animated: false)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraError.setup("camera input") }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.setup("video output") }
        session.addOutput(videoOutput)
        Self.lockFrameRate(camera, fps: 30)

        if withAudio, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                hasAudio = true
            }
        }

        // Buffers upright on the screen whichever way it is turned, so Framing's crop stays
        // centered and the file is what was shown.
        applyRotation(angle)
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let c = videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(angle) else { return }
        c.videoRotationAngle = angle
    }

    /// 30 frames a second, the NTSC frame rate the tape records (29.97 on the tape, 30 here).
    private static func lockFrameRate(_ camera: AVCaptureDevice, fps: Int32) {
        let d = CMTime(value: 1, timescale: fps)
        let ok = camera.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameDuration <= d && $0.maxFrameDuration >= d
        }
        guard ok, (try? camera.lockForConfiguration()) != nil else { return }
        camera.activeVideoMinFrameDuration = d
        camera.activeVideoMaxFrameDuration = d
        camera.unlockForConfiguration()
    }

    func start() {
        let s = Unchecked(value: session)
        sessionQueue.async { s.value.startRunning() }
    }

    func stop() {
        let s = Unchecked(value: session)
        sessionQueue.async { s.value.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            onVideo?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } else {
            onAudio?(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput { dropped.withLock { $0 += 1 } }
    }
}

enum CameraError: Error, CustomStringConvertible {
    case noCamera
    case setup(String)

    var description: String {
        switch self {
        case .noCamera: return "No camera available"
        case .setup(let s): return "The camera could not be set up (\(s))"
        }
    }
}

/// The lens controls on a real camera. Every choice is gated on what the device reports.
final class DeviceLens: CameraLens {
    private let device: AVCaptureDevice
    let stops: [CGFloat]
    let displayMultiplier: CGFloat

    init(device: AVCaptureDevice) {
        self.device = device
        displayMultiplier = device.displayVideoZoomFactorMultiplier
        let range = device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        // The main lens is the one after the ultra wide, where the virtual device starts on it.
        let startsUltraWide = device.constituentDevices.first?.deviceType == .builtInUltraWideCamera
        let main: CGFloat = startsUltraWide ? (switches.first ?? 1) : 1
        mainZoom = main
        var all = [range.lowerBound] + switches + [main * 2]
        all = all.filter { range.contains($0) }
        stops = Array(Set(all.map { ($0 * 100).rounded() / 100 })).sorted()
    }

    let mainZoom: CGFloat

    var zoomRange: ClosedRange<CGFloat> {
        // A cap at ten times the longest lens, as far as a pinch is useful on a 480 line picture.
        device.minAvailableVideoZoomFactor...min(device.maxAvailableVideoZoomFactor, (stops.last ?? 1) * 10)
    }

    var zoom: CGFloat { device.videoZoomFactor }

    func setZoom(_ factor: CGFloat, animated: Bool) {
        let f = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        guard (try? device.lockForConfiguration()) != nil else { return }
        if animated { device.ramp(toVideoZoomFactor: f, withRate: 6) } else { device.videoZoomFactor = f }
        device.unlockForConfiguration()
    }

    func focus(at point: CGPoint) -> Bool {
        let canFocus = device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus)
        let canExpose = device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure)
        guard canFocus || canExpose, (try? device.lockForConfiguration()) != nil else { return false }
        // The point of interest is set before the mode, which starts the measurement there.
        if canFocus {
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
        }
        if canExpose {
            device.exposurePointOfInterest = point
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
        return true
    }
}

// HV_STORE_SCREENS is set only on the command line of the App Store screenshot run, never in
// the project, so an archive never carries this.
#if DEBUG || HV_STORE_SCREENS
/// Test builds only: a fixture file stands in for the camera (`-homevideoCameraFixture <path>`),
/// read in real time and handed to the same callbacks the capture session uses, stamped on the
/// host clock as capture is. Sound is decoded to 16 bit integers at the file's rate, the shape a
/// microphone hands over, so the recorder's conversion runs as it does on a phone. Loops the file.
///
/// The file is the world, upright. The feed plays a sensor in it: held upright the phone sees a
/// portrait part of the world, on its side a landscape one, and the sensor's frames are turned
/// by the device's real turn (`UIDevice` orientation, which the Simulator's rotation sets) then
/// by the app's `rotationAngle`, as the capture connection would. A wrong angle in the app shows
/// as a turned picture here. The lens zooms digitally, with the stops of a three lens phone.
final class FixtureFeed: CameraFeed, @unchecked Sendable {
    var onVideo: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    var droppedFrames: Int { 0 }
    let hasAudio = true
    private let url: URL
    private let queue = DispatchQueue(label: "homevideo.camera.fixture", qos: .userInteractive)
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let turn = OSAllocatedUnfairLock(initialState: (app: CGFloat(90), device: CGFloat(90)))
    private let fixtureLens = FixtureLens()
    var lens: CameraLens? { fixtureLens }
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var orientationWatch: NSObjectProtocol?

    var rotationAngle: CGFloat {
        get { turn.withLock { $0.app } }
        set { turn.withLock { $0.app = newValue } }
    }

    /// `-homevideoCameraAngleError <degrees>` adds a wrong turn to the app's angle, so a test
    /// can show the fixture catches one (the negative control).
    private let angleError = CGFloat(UserDefaults.standard.integer(forKey: "homevideoCameraAngleError"))

    init(url: URL) {
        self.url = url
        DispatchQueue.main.async { [weak self] in
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            self?.noteDevice()
            self?.orientationWatch = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteDevice() }
            }
        }
    }

    deinit {
        if let orientationWatch { NotificationCenter.default.removeObserver(orientationWatch) }
    }

    /// The horizon level angle for the device's physical turn: the back sensor's own frame is
    /// upright with the phone on its side, top to the left (`UIDeviceOrientation.landscapeLeft`).
    @MainActor private func noteDevice() {
        let a: CGFloat?
        switch UIDevice.current.orientation {
        case .portrait: a = 90
        case .landscapeLeft: a = 0
        case .landscapeRight: a = 180
        case .portraitUpsideDown: a = 270
        default: a = nil
        }
        if let a { turn.withLock { $0.device = a } }
    }

    /// The world as the sensor would hand it over, turned by the app's angle.
    private func sensorFrame(_ world: CVPixelBuffer) -> CVPixelBuffer? {
        let (angle, device) = turn.withLock { ($0.app, $0.device) }
        let app = angle + angleError
        var image = CIImage(cvPixelBuffer: world)
        let e = image.extent
        // The part of the world in view: portrait held upright, landscape on the side, as
        // large as fits, centered, and narrowed by the zoom.
        let upright = Int(device) % 180 != 0
        let view = upright ? CGSize(width: e.height * e.height / e.width, height: e.height) : e.size
        // 1x shows the whole file. The 0.5x lens sees past its edges, which come out black.
        let z = fixtureLens.zoom / fixtureLens.mainZoom
        let crop = CGRect(x: e.midX - view.width / (2 * z), y: e.midY - view.height / (2 * z),
                          width: view.width / z, height: view.height / z)
        image = image.composited(over: CIImage(color: .black)).cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = (upright ? 720 : 1280) / crop.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Turned by the difference between the app's angle and the true one: none when the app
        // is right. Clockwise on the screen.
        let off = Int((app - device).truncatingRemainder(dividingBy: 360) + 360) % 360
        switch off {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: break
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let size = CGSize(width: image.extent.width.rounded(), height: image.extent.height.rounded())
        if pool == nil || size != poolSize {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = size
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        context.render(image, to: out)
        return out
    }

    static var fromLaunch: URL? {
        guard let path = UserDefaults.standard.string(forKey: "homevideoCameraFixture"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func start() {
        running.withLock { $0 = true }
        let u = url
        queue.async { [weak self] in
            var loopStart = CMClockGetTime(CMClockGetHostTimeClock())
            while let self, self.running.withLock({ $0 }) {
                guard let end = self.playOnce(u, from: loopStart) else { return }
                loopStart = end
            }
        }
    }

    func stop() { running.withLock { $0 = false } }

    /// One pass through the file, frames and sound interleaved by time and each handed over
    /// when the host clock reaches it. Returns the host time the pass ended at.
    private func playOnce(_ url: URL, from start: CMTime) -> CMTime? {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        let tracks = Unchecked(value: Box<([AVAssetTrack], [AVAssetTrack])>(([], [])))
        Task {
            let v = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let a = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            tracks.value.value = (v, a)
            sem.signal()
        }
        sem.wait()
        guard let video = tracks.value.value.0.first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let audio = tracks.value.value.1.first {
            let o = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(o)
            aOut = o
        }
        guard reader.startReading() else { return nil }
        var nextVideo = vOut.copyNextSampleBuffer()
        var nextAudio = aOut?.copyNextSampleBuffer()
        var last = start
        while running.withLock({ $0 }), nextVideo != nil || nextAudio != nil {
            let vt = nextVideo.map(CMSampleBufferGetPresentationTimeStamp)
            let at = nextAudio.map(CMSampleBufferGetPresentationTimeStamp)
            let takeVideo = vt != nil && (at == nil || vt! <= at!)
            guard let sample = takeVideo ? nextVideo : nextAudio else { break }
            let host = CMTimeAdd(start, CMSampleBufferGetPresentationTimeStamp(sample))
            let wait = CMTimeSubtract(host, CMClockGetTime(CMClockGetHostTimeClock())).seconds
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            last = CMTimeAdd(host, CMSampleBufferGetDuration(sample).isNumeric
                             ? CMSampleBufferGetDuration(sample) : CMTime(value: 1, timescale: 30))
            if takeVideo {
                if let pb = CMSampleBufferGetImageBuffer(sample), let frame = sensorFrame(pb) { onVideo?(frame, host) }
                nextVideo = vOut.copyNextSampleBuffer()
            } else {
                if let shifted = Self.restamped(sample, at: host) { onAudio?(shifted) }
                nextAudio = aOut?.copyNextSampleBuffer()
            }
        }
        reader.cancelReading()
        return last
    }

    private static func restamped(_ sample: CMSampleBuffer, at time: CMTime) -> CMSampleBuffer? {
        // Linear PCM carries one timing entry for the whole buffer, its duration one sample's.
        guard let f = CMSampleBufferGetFormatDescription(sample),
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee.mSampleRate, rate > 0
        else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

/// The fixture's lens: the stops of a phone whose widest lens is the ultra wide (0.5x, 1x,
/// 2x, 5x as labeled), zoomed digitally, with no focus or exposure to set.
final class FixtureLens: CameraLens, @unchecked Sendable {
    let stops: [CGFloat] = [1, 2, 4, 10]
    let displayMultiplier: CGFloat = 0.5
    let zoomRange: ClosedRange<CGFloat> = 1...20
    let mainZoom: CGFloat = 2
    private let current = OSAllocatedUnfairLock(initialState: CGFloat(2))
    var zoom: CGFloat { current.withLock { $0 } }
    func setZoom(_ factor: CGFloat, animated: Bool) {
        let f = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        current.withLock { $0 = f }
    }
    func focus(at point: CGPoint) -> Bool { false }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
#endif
