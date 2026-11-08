import CoreImage
import CoreVideo
import Metal
import Observation
import UIKit

/// The Look carousel's stills: the clip's current frame through each Look, made once per clip
/// on a chain of its own, so the preview's chain and its frame history are never touched.
/// One Look is drawn per run loop turn, so the carousel fills in while the clip keeps playing.
@MainActor
@Observable
final class LookStills {
    /// The still per Look id for the clip open now.
    private(set) var images: [String: UIImage] = [:]

    @ObservationIgnored private let device: MTLDevice?
    @ObservationIgnored private var queue: MTLCommandQueue?
    @ObservationIgnored private var library: MTLLibrary?
    @ObservationIgnored private var cache: CVMetalTextureCache?
    @ObservationIgnored private var chain: SignalChain?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let context = CIContext(options: [.cacheIntermediates: false])

    /// The still's width in pixels, two and a bit times a card's width in points.
    static let width: CGFloat = 320

    init(device: MTLDevice?) {
        self.device = device
    }

    func clear() {
        task?.cancel()
        images = [:]
        fresh = []
    }

    // MARK: Cards on screen

    /// The two carousels: the editor's, and the camera's, which the editor's stays under.
    static let editor = "editor"
    static let camera = "camera"

    /// The Look cards on screen now, per carousel.
    @ObservationIgnored private var shown: [String: Set<String>] = [:]
    /// The Looks drawn from the latest frame.
    @ObservationIgnored private var fresh: Set<String> = []
    /// The carousel whose cards decide what a frame's run draws, nil to draw every Look. The
    /// camera sets it while live, so its refreshes draw only what can be seen.
    @ObservationIgnored var watched: String?
    /// Called when a card of the watched carousel comes into view without a still from the
    /// latest frame, so the camera can bring its next refresh forward.
    @ObservationIgnored var onStaleCardShown: (() -> Void)?

    func setShown(_ id: String, _ isShown: Bool, in carousel: String) {
        if isShown {
            shown[carousel, default: []].insert(id)
            if carousel == watched, !fresh.contains(id) { onStaleCardShown?() }
        } else {
            shown[carousel]?.remove(id)
        }
    }

    /// The watched carousel's cards on screen and one each side of them, nil for every Look.
    private func wanted() -> Set<String>? {
        guard let watched, let ids = shown[watched], !ids.isEmpty else { return nil }
        let order = Looks.grouped.flatMap(\.looks).map(\.id)
        var out = Set<String>()
        for (i, id) in order.enumerated() where ids.contains(id) {
            out.insert(id)
            if i > 0 { out.insert(order[i - 1]) }
            if i + 1 < order.count { out.insert(order[i + 1]) }
        }
        return out
    }

    /// Draws every Look's still once the clip has a frame on screen.
    func schedule(for model: MobileModel, after delay: Double) {
        task?.cancel()
        task = Task { [weak self, weak model] in
            try? await Task.sleep(for: .seconds(delay))
            // The first frame can take a moment to decode.
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if model?.source?.lastFrame != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, let model, let frame = model.source?.lastFrame else { return }
            await self.drawAll(frame: frame, like: model.chain)
        }
    }

    /// Draws the stills of the cards on screen, and one each side, from one camera frame.
    func schedule(frame: CVPixelBuffer, like chain: SignalChain) {
        task?.cancel()
        let held = Unchecked(value: frame)
        let only = wanted()
        task = Task { [weak self] in await self?.drawAll(frame: held.value, like: chain, only: only) }
    }

    private func drawAll(frame: CVPixelBuffer, like shown: SignalChain, only: Set<String>? = nil) async {
        #if DEBUG
        var spent: CFTimeInterval = 0
        var drawn: [String] = []
        #endif
        fresh = []
        for look in Looks.all where only?.contains(look.id) ?? true {
            if Task.isCancelled { return }
            #if DEBUG
            let start = CACurrentMediaTime()
            #endif
            if let image = render(look, frame: frame, like: shown) {
                images[look.id] = image
                fresh.insert(look.id)
            }
            #if DEBUG
            spent += CACurrentMediaTime() - start
            drawn.append(look.id)
            #endif
            await Task.yield()
        }
        #if DEBUG
        note(spent: spent, drawn: drawn)
        #endif
    }

    #if DEBUG
    /// Test builds only: what the last run of stills cost and what the stills hold, for the
    /// `stillsTiming` probe. The time is the renders' own, without the yields between them.
    private(set) var debugTiming = ""
    @ObservationIgnored private var spentPerRun: [CFTimeInterval] = []

    private func note(spent: CFTimeInterval, drawn: [String]) {
        spentPerRun.append(spent)
        let mean = spentPerRun.reduce(0, +) / Double(spentPerRun.count)
        let bytes = images.values.reduce(0) { $0 + ($1.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
        debugTiming = String(format: "last %.1f ms mean %.1f ms runs %d cards %d held %d bytes %d drawn ",
                             spent * 1000, mean * 1000, spentPerRun.count, drawn.count, images.count, bytes)
            + drawn.joined(separator: ",")
    }
    #endif

    private func setUp() throws -> (MTLDevice, MTLCommandQueue, MTLLibrary, CVMetalTextureCache, SignalChain) {
        guard let device else { throw ShaderLibrary.LoadError.noLibrary("no Metal device") }
        if queue == nil { queue = device.makeCommandQueue() }
        if library == nil { library = try ShaderLibrary.make(device: device).0 }
        if cache == nil {
            var c: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
            cache = c
        }
        if chain == nil { chain = SignalChain.standard() }
        guard let queue, let library, let cache, let chain else { throw ShaderLibrary.LoadError.noLibrary("setup") }
        return (device, queue, library, cache, chain)
    }

    /// One Look on the frame: the Look set on the stills chain, the clip's Framing and Output
    /// size copied over (a Look sets neither), one pass, read back as a small image.
    private func render(_ look: Look, frame: CVPixelBuffer, like shown: SignalChain) -> UIImage? {
        guard let (device, queue, library, cache, chain) = try? setUp(), let vhs = chain.vhs else { return nil }
        Presets(vhs: vhs, audio: chain.audio).setLook(look)
        // As `MobileModel.choose` sets it, so the card shows what a tap gives.
        if !look.setsDisplay { vhs.crt.allOff() }
        for p in shown.framing.parameters { chain.framing.setParameter(p.id, to: p.value) }
        if let output = shown.vhs?.output {
            for p in output.parameters { vhs.output.setParameter(p.id, to: p.value) }
        }
        chain.reset()
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        var cv: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, frame, nil, .bgra8Unorm, w, h, 0, &cv)
        guard let cv, let src = CVMetalTextureGetTexture(cv), let cb = queue.makeCommandBuffer() else { return nil }
        let ctx = FrameContext(frameIndex: 0, time: 0, sourceSize: PreviewRenderer.displaySize(of: frame),
                               rasterSize: CGSize(width: SignalChain.rasterWidth, height: SignalChain.rasterHeight))
        guard let out = try? chain.encodeOutput(commandBuffer: cb, source: src, frame: ctx, device: device,
                                                library: library) else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        // The chain's values are display encoded, as the preview draws them.
        guard var image = CIImage(mtlTexture: out, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        else { return nil }
        image = image.oriented(.downMirrored)
        let aspect = SignalChain.displayAspect(chain.output, chain.outputSize)
        let size = CGSize(width: Self.width, height: (Self.width / aspect).rounded())
        image = image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width,
                                                        y: size.height / image.extent.height))
        guard let cg = context.createCGImage(image, from: CGRect(origin: .zero, size: size)) else { return nil }
        return UIImage(cgImage: cg)
    }
}
