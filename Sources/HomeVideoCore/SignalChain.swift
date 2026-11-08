import Foundation
import Metal
import Observation

/// The ordered list of layers, in signal path order, and the textures they run through.
///
/// Framing is always first and always on: it turns the source frame into the working raster.
/// Every later enabled layer reads the previous result and writes the other of two RGBA16Float
/// intermediates (ping-pong). The chain's output is whichever intermediate the last enabled
/// layer wrote.
@MainActor
@Observable
public final class SignalChain {
    /// NTSC DV working raster.
    public nonisolated static let rasterWidth = 720
    public nonisolated static let rasterHeight = 480

    public let framing: FramingLayer
    /// Effect layers after framing, in signal path order.
    public var effects: [any Layer]

    public var layers: [any Layer] { [framing] + effects }

    /// The audio chain (Sources/HomeVideoCore/Audio), run by the exporter and the preview tap.
    public let audio = AudioChain()

    @ObservationIgnored private var intermediates: [MTLTexture] = []
    @ObservationIgnored private var preparedIDs: Set<ObjectIdentifier> = []

    public init(framing: FramingLayer? = nil, effects: [any Layer] = []) {
        self.framing = framing ?? FramingLayer()
        self.effects = effects
    }

    /// The chain the app and `homevideo-render` both build, so the preview, the export and the
    /// headless renderer run the same layers. New effect layers are registered here.
    public static func standard() -> SignalChain {
        let vhs = VHSLayers()
        let chain = SignalChain(effects: vhs.all)
        chain.vhs = vhs
        let clog = vhs.damage.clog, luma = vhs.luma
        chain.audio.pictureClog = { (clog.enabled, clog.strength, clog.rate, clog.seed) }
        chain.audio.videoSpeed = { luma.speed }
        // The Tape stage carries its sound track: off drops the track, its wear and the
        // audio Damage, and the mic plays alone, wherever the switch is set from.
        let audio = chain.audio
        audio.tapeIsOn = vhs.tape.enabled
        vhs.tape.onSwitch = { [weak audio] on in audio?.tapeIsOn = on }
        return chain
    }

    /// The VHS layers L1 to L9 when the chain was built by `standard()`, wired together.
    @ObservationIgnored public private(set) var vhs: VHSLayers?

    /// The Display stage's layers (the size, then the six CRT layers), empty on a chain not
    /// built by `standard()`.
    public var displayLayers: [any Layer] { (vhs?.crt.all ?? []) + (vhs?.recapture.all ?? []) }
    /// The Tape switch, the Film source's and the Telecine stage's layers, empty on a chain not
    /// built by `standard()`.
    public var stageLayers: [any Layer] {
        guard let vhs else { return [] }
        return [vhs.tape] + vhs.film.all + vhs.telecine.all
    }
    /// Every layer a setting can name: the raster chain's, then the Tape, Film and Telecine's,
    /// then the Display stage's.
    public var settingsLayers: [any Layer] { layers + stageLayers + displayLayers + (vhs.map { [$0.output] } ?? []) }
    /// True when a CRT layer is on, so the output is the Display canvas.
    public var displayIsOn: Bool { vhs?.crt.isOn ?? false }
    /// True when the camera films the Display, so the output is the camera's frame.
    public var recaptureIsOn: Bool { vhs?.recaptureIsOn ?? false }

    /// The layers a frame runs through, in the path's order: Framing, the Film's and the
    /// Telecine's while in use, the tape's while it is on (the Camera not under Film), then the
    /// Display's and the camera's while on.
    public var layersInUse: [any Layer] {
        guard let vhs else { return layers.filter(\.enabled) }
        var used: [any Layer] = []
        // Framing places the source on every path, every stage off included.
        used.append(framing)
        if vhs.film.isOn { used += vhs.film.all.filter(\.enabled) }
        if vhs.telecineInUse { used += vhs.telecine.all.filter(\.enabled) }
        if vhs.tape.enabled {
            used += effects.filter { $0.enabled && !(vhs.replacesCamera && $0 is CameraLayer) }
        }
        if vhs.crt.isOn { used += vhs.crt.all.filter(\.enabled) }
        if vhs.recaptureIsOn { used += vhs.recapture.all.filter(\.enabled) }
        return used
    }

    /// What the last stage on the path gives, which sets the file's size and tags.
    public enum Output: Equatable, Sendable {
        /// The 720 by 480 raster, 10:11 pixels shown 4:3, 601: the tape's capture, or with the
        /// tape off the Telecine's transfer, which is NTSC video too.
        case raster
        /// The Film's Scan canvas (Film on, Tape and Telecine off), square pixels in 709.
        case scan
        /// The source untouched at its own size (every stage off), square pixels in 709.
        case source
        /// The Display canvas (a CRT layer on), square pixels with the raster's tags.
        case display
        /// The camera's frame of the Display (Re-capture on), as the Display's.
        case camera

        /// True for the square pixel pictures, which the preview shows at their own shape.
        public var isSquare: Bool { self != .raster }
        /// True for the pictures tagged 709 throughout (the Film's scan, and the source).
        public var isHD: Bool { self == .scan || self == .source }
    }

    /// The last stage's picture: Re-capture, else the Display, else with the tape on its raster,
    /// else the Telecine's transfer (the raster), the Film's scan, or the source itself.
    public var naturalOutput: Output {
        guard let vhs else { return .raster }
        if vhs.crt.isOn { return vhs.recaptureIsOn ? .camera : .display }
        if vhs.tape.enabled || vhs.telecineInUse { return .raster }
        return vhs.film.isOn ? .scan : .source
    }

    /// The file's kind, which sets its tags and pixel shape: the last stage's at Auto. A
    /// picked Output size of SD is the raster's own (10:11 pixels, 601), and any other
    /// picked size of the raster's picture has square pixels with the raster's tags, as the
    /// Display canvas has.
    public var output: Output {
        let natural = naturalOutput
        guard let picked = vhs?.output, !picked.isAuto else { return natural }
        if picked.size == .sd { return .raster }
        return natural == .raster ? .display : natural
    }

    /// The source's displayed size (its rotation applied) the last time a frame ran, which is
    /// the output's size with every stage off and Match source's size. Every frame sets it, and
    /// the exporter before the first frame. Observed, so the Look tab's caption and the preview's
    /// shape follow a new clip (it changes only when the clip or the rotation does).
    public var sourceSize: (width: Int, height: Int) = (0, 0)

    /// The size the last stage makes, Auto's size: the raster, the Standard scan's 1440 by 1080
    /// whatever the Scan detail, the source's own size, the Display's 1440 by 1080 whatever its
    /// Detail (a detail says how fine the film is scanned or the tube is drawn, never the
    /// file's size), or the camera's frame. Under Fill the frame the scan, the tube and
    /// the camera's frame keep their height and take the frame's shape, and the raster stays 720
    /// by 480 with the wide picture squeezed into it.
    public var naturalSize: (width: Int, height: Int) {
        let wide = fillAspect
        func shaped(_ s: (width: Int, height: Int)) -> (width: Int, height: Int) {
            wide.map { (SignalChain.wideWidth(height: s.height, aspect: $0), s.height) } ?? s
        }
        switch naturalOutput {
        case .raster: return (SignalChain.rasterWidth, SignalChain.rasterHeight)
        case .scan: return shaped(FilmLayers.standardScanSize)
        case .source:
            return sourceSize.width > 0 && sourceSize.height > 0
                ? sourceSize : (SignalChain.rasterWidth, SignalChain.rasterHeight)
        case .display: return shaped((DisplaySize.standard.width, DisplaySize.standard.height))
        case .camera:
            return vhs.map { shaped(($0.recapture.stage.camera.width, $0.recapture.stage.camera.height)) } ?? (0, 0)
        }
    }

    /// Fill the frame: the display aspect every stage works at when the Picture choice fills a
    /// picked size that is not 4:3, else nil, the default, where the chain works in 4:3 and the
    /// picture fits inside the frame. Auto and SD are 4:3
    /// pictures already, so Fill does nothing there. With every stage off the untouched canvas is
    /// the frame's own shape whatever this says.
    public var fillAspect: CGFloat? {
        guard let o = vhs?.output, o.fill else { return nil }
        return pickedAspect
    }

    /// True when the Picture choice shows on the Look tab: a picked size whose shape is not 4:3.
    public var fillApplies: Bool { pickedAspect != nil }

    /// The picked size's display aspect when it is not 4:3, else nil (Auto, SD, a 4:3 size).
    private var pickedAspect: CGFloat? {
        guard let o = vhs?.output, !o.isAuto, o.size != .sd else { return nil }
        let s: (width: Int, height: Int)
        switch o.size {
        case .source:
            guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
            s = sourceSize
        case .custom: s = (o.width, o.height)
        default:
            guard let f = o.size.fixed else { return nil }
            s = f
        }
        let a = CGFloat(s.width) / CGFloat(s.height)
        return abs(a - FramingMath.rasterDisplayAspect) < 0.005 ? nil : a
    }

    /// The width of a picture `height` tall shown at `aspect` with square pixels, to the
    /// nearest even number (4:2:0 and 4:2:2 codecs want even sizes).
    public nonisolated static func wideWidth(height: Int, aspect: CGFloat) -> Int {
        max(2, Int((CGFloat(height) * aspect / 2).rounded()) * 2)
    }

    /// The size of what `encodeOutput` returns, the file's size: the Output size picked on the
    /// Look tab, or at Auto the size the last stage makes.
    public var outputSize: (width: Int, height: Int) {
        let natural = naturalSize
        guard let picked = vhs?.output else { return natural }
        let source = sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize : natural
        return picked.resolve(natural: natural, source: source)
    }

    /// The display aspect of a picture `size` of kind `kind`: 4:3 for the raster's 10:11
    /// pixels, else its own width over height.
    public nonisolated static func displayAspect(_ kind: Output, _ size: (width: Int, height: Int)) -> CGFloat {
        kind == .raster || size.height <= 0 ? FramingMath.rasterDisplayAspect
            : CGFloat(size.width) / CGFloat(size.height)
    }
    @ObservationIgnored private var displayRenderer: CRTRenderer?
    @ObservationIgnored private var recaptureRenderer: RecaptureRenderer?
    @ObservationIgnored private var displayInput: MTLTexture?
    @ObservationIgnored private var untouched: MTLTexture?

    /// The whole path: the source stage, the tape when it is on, then the Display stage,
    /// then Re-capture. Returns the picture itself (the very texture `encode` returns) when every
    /// CRT layer is off, else the Display canvas, else with Re-capture on the camera's frame of
    /// that canvas. The preview and the export both draw this.
    public func encodeOutput(commandBuffer: MTLCommandBuffer, source: MTLTexture, frame: FrameContext,
                             device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        // Match source needs the clip's size whatever the stages do, or with a stage on the
        // caption and the preview would read the tape's 720 by 480.
        let shown = FramingMath.displaySize(CGSize(width: source.width, height: source.height),
                                            rotation: framing.rotation)
        let shownSize = (Int(shown.width), Int(shown.height))
        if shownSize != sourceSize { sourceSize = shownSize }
        let picture = try encodeLastStage(commandBuffer: commandBuffer, source: source, frame: frame,
                                          device: device, library: library)
        // The Output size: the last stage's picture fitted into the file's size whole, never
        // stretched or cropped, black bars where the shapes differ. At Auto the sizes agree and
        // the picture is returned as it is.
        let size = outputSize
        guard picture.width != size.width || picture.height != size.height else { return picture }
        return try fitToOutput(picture, size: size, commandBuffer: commandBuffer, device: device, library: library)
    }

    /// The last stage's own picture at its own size. Internal, so the CRT tests read the
    /// tube's canvas at its Detail before the Output size fits it.
    func encodeLastStage(commandBuffer: MTLCommandBuffer, source: MTLTexture, frame: FrameContext,
                                 device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        if let vhs, !vhs.tape.enabled, !vhs.film.isOn, !vhs.telecineInUse, !vhs.crt.isOn {
            return try encodeUntouched(commandBuffer: commandBuffer, source: source, frame: frame,
                                       device: device, library: library)
        }
        var raster = try encode(commandBuffer: commandBuffer, source: source, frame: frame, device: device,
                                library: library)
        guard let vhs, vhs.crt.isOn else { return raster }
        // The tube draws its own 480 lines whatever it is fed: the tape's raster, a
        // Telecine transfer and the framed source are the raster already, a Film scan is brought
        // to it first, its 4:3 picture filling the 720 by 480 grid as a player's output would.
        if raster.width != SignalChain.rasterWidth || raster.height != SignalChain.rasterHeight {
            raster = try fitToRaster(raster, commandBuffer: commandBuffer, device: device, library: library)
        }
        let r = displayRenderer ?? CRTRenderer()
        displayRenderer = r
        // The camera samples the screen at its own grid, so the tube is drawn above the
        // camera's resolution, at the 2880 by 2160 canvas, whatever the Display size says.
        // Under Fill the frame the tube is the frame's shape: the same height, curvature,
        // mask and scan lines over a wider glass, the squeezed raster drawn across it.
        let filmed = vhs.recaptureIsOn
        let wide = fillAspect
        let canvas = try r.encode(vhs.crt, size: filmed ? .large : vhs.crt.size, aspect: wide,
                                  commandBuffer: commandBuffer, raster: raster, frame: frame, device: device,
                                  library: library)
        guard filmed else { return canvas }
        let c = recaptureRenderer ?? RecaptureRenderer()
        recaptureRenderer = c
        return try c.encode(vhs.recapture, aspect: wide, commandBuffer: commandBuffer, canvas: canvas, frame: frame,
                            device: device, library: library)
    }

    /// Clears every layer's temporal state (previous frames, history), before an export's
    /// frame 0 or after a seek, so a run does not depend on what was shown before it.
    public func reset() {
        for layer in layers { layer.reset() }
        vhs?.film.reset()
        vhs?.telecine.reset()
    }

    /// One step of a run: which layer, and which texture slot it reads and writes.
    /// Slot `nil` input means the source frame. Slots 0 and 1 are the two intermediates.
    public struct Step: Equatable {
        public var layerIndex: Int
        public var input: Int?
        public var output: Int
    }

    /// The run order for a given list of enabled flags (index 0 is framing, always run).
    /// Pure, so the ordering is unit tested without a GPU.
    public nonisolated static func plan(enabled: [Bool]) -> [Step] {
        var steps: [Step] = []
        var current: Int? = nil
        for (i, on) in enabled.enumerated() where on || i == 0 {
            let out = current == 0 ? 1 : 0
            steps.append(Step(layerIndex: i, input: current, output: out))
            current = out
        }
        return steps
    }

    public func plan() -> [Step] {
        SignalChain.plan(enabled: layers.map { $0.enabled })
    }

    /// Encodes the enabled layers into `commandBuffer` and returns the texture holding the
    /// result. Pipelines and intermediates are built on first use.
    public func encode(commandBuffer: MTLCommandBuffer, source: MTLTexture, frame: FrameContext,
                       device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        try allocateIfNeeded(device: device)
        let all = layers
        for layer in all where !preparedIDs.contains(ObjectIdentifier(layer)) {
            try layer.prepare(device: device, library: library)
            preparedIDs.insert(ObjectIdentifier(layer))
        }
        var ctx = frame
        ctx.rasterSize = CGSize(width: SignalChain.rasterWidth, height: SignalChain.rasterHeight)
        // Every stage from here fills a 4:3 picture: the raster, the Film's canvas. Under Fill the
        // frame they fill the frame's shape instead: the raster squeezed (anamorphic, as
        // widescreen camcorders and DVD recorders put 16:9 on tape), the Film's canvas wide.
        let wide = fillAspect
        framing.canvasAspect = wide
        vhs?.film.displayAspect = wide.map(Double.init)
        vhs?.telecine.displayAspect = wide.map(Double.init)
        // The Film source (FilmLayers.swift) while its master switch is on, and the Telecine
        // while its own is, with or without the Film.
        if let vhs, vhs.film.isOn || vhs.telecineInUse {
            let film = vhs.film
            return try encodeFilm(film, commandBuffer: commandBuffer, source: source, frame: ctx,
                                  device: device, library: library)
        }
        // The Tape off: Framing alone, the framed source on the raster, which the
        // Display draws. No VHS layer runs.
        let tapeOn = vhs?.tape.enabled ?? true
        var result = intermediates[0]
        for step in tapeOn ? plan() : SignalChain.plan(enabled: [true]) {
            let input = step.input.map { intermediates[$0] } ?? source
            let output = intermediates[step.output]
            all[step.layerIndex].encode(commandBuffer: commandBuffer, in: input, out: output, frame: ctx)
            result = output
        }
        return result
    }

    /// Every stage off: the source upright (its track's rotation applied, as a player shows it)
    /// at its own size, through Framing on a canvas of the source's own shape, so pan, zoom and
    /// rotation work with the Tape off. At Crop to fill, zoom 1 and rotation 0 the window is the
    /// whole picture and each
    /// pixel is one texel read at its center, so the picture is the source's own values.
    private func encodeUntouched(commandBuffer: MTLCommandBuffer, source: MTLTexture, frame: FrameContext,
                                 device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        try framing.prepare(device: device, library: library)
        let shown = FramingMath.displaySize(CGSize(width: source.width, height: source.height),
                                            rotation: framing.rotation)
        sourceSize = (Int(shown.width), Int(shown.height))
        let (w, h) = untouchedCanvas
        if untouched?.width != w || untouched?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            untouched = device.makeTexture(descriptor: d)
            untouched?.label = "source untouched"
        }
        guard let out = untouched else { throw ShaderLibrary.LoadError.noLibrary("could not allocate the source") }
        framing.canvasAspect = untouchedAspect
        var ctx = frame
        ctx.sourceSize = CGSize(width: source.width, height: source.height)
        framing.encode(commandBuffer: commandBuffer, in: source, out: out, frame: ctx)
        return out
    }

    /// The canvas Framing fills with every stage off: the source's own size, or the picked
    /// Output size, so Crop to fill fills the file and Fit inside puts its bars there.
    private var untouchedCanvas: (width: Int, height: Int) {
        vhs?.output.isAuto ?? true ? sourceSize : outputSize
    }

    /// That canvas's display aspect (4:3 for SD's 10:11 pixels).
    private var untouchedAspect: CGFloat {
        SignalChain.displayAspect(vhs?.output.size == .sd ? .raster : .source, untouchedCanvas)
    }

    /// Fits `picture`, the last stage's, inside `size` whole: scaled by the Framing kernel's
    /// box filter to the largest rect of its own display shape, black around it.
    private func fitToOutput(_ picture: MTLTexture, size: (width: Int, height: Int), commandBuffer: MTLCommandBuffer,
                             device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        try outputFitter.prepare(device: device, library: library)
        if fitted?.width != size.width || fitted?.height != size.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.width,
                                                             height: size.height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            fitted = device.makeTexture(descriptor: d)
            fitted?.label = "Output size"
        }
        guard let out = fitted else { throw ShaderLibrary.LoadError.noLibrary("could not allocate the output") }
        // The shapes as shown: the raster's 10:11 pixels are 4:3, the rest square. Under Fill the
        // frame the raster holds the frame's shape squeezed, and every stage's picture is
        // the frame's shape, so the whole picture fills the whole frame (the unsqueeze), never
        // a stray bar from rounding a width to even.
        let wide = fillAspect
        let from = wide.map { naturalOutput == .raster ? $0 : CGFloat(picture.width) / CGFloat(picture.height) }
            ?? SignalChain.displayAspect(naturalOutput, (picture.width, picture.height))
        // The raster's unsqueeze takes the whole raster: the head switching band at the bottom, the
        // Frame layer's blanking bars and every edge the tape draws fill the frame,
        // as they sit inside the 4:3 picture at 4:3 inside.
        outputFitter.mode = wide == nil ? .letterbox : .fullRaster
        outputFitter.canvasAspect = SignalChain.displayAspect(output, size)
        let ctx = FrameContext(frameIndex: 0, time: 0, sourceSize: CGSize(width: from * 1000, height: 1000),
                               rasterSize: CGSize(width: out.width, height: out.height))
        outputFitter.encode(commandBuffer: commandBuffer, in: picture, out: out, frame: ctx)
        return out
    }

    /// The Output size's own pass, Fit inside, so the chain's Framing keeps its settings.
    @ObservationIgnored private let outputFitter = FramingLayer(mode: .letterbox)
    @ObservationIgnored private var fitted: MTLTexture?

    /// Resamples `picture` onto the 720 by 480 raster with the Framing kernel's box filter, the
    /// whole picture onto the whole raster (both are shown 4:3).
    private func fitToRaster(_ picture: MTLTexture, commandBuffer: MTLCommandBuffer,
                             device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        try fitter.prepare(device: device, library: library)
        if displayInput == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                             width: SignalChain.rasterWidth,
                                                             height: SignalChain.rasterHeight, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            displayInput = device.makeTexture(descriptor: d)
            displayInput?.label = "Display input"
        }
        guard let out = displayInput else {
            throw ShaderLibrary.LoadError.noLibrary("could not allocate the Display input")
        }
        let ctx = FrameContext(frameIndex: 0, time: 0,
                               sourceSize: CGSize(width: picture.width, height: picture.height),
                               rasterSize: CGSize(width: out.width, height: out.height))
        fitter.rotation = 0
        fitter.encode(commandBuffer: commandBuffer, in: picture, out: out, frame: ctx)
        return out
    }

    /// A Framing pass of its own, whole picture to whole texture, so the chain's Framing keeps
    /// its settings and its shown size.
    @ObservationIgnored private let fitter = FramingLayer(mode: .fullRaster)

    /// Film or Telecine on. With the Telecine on the transfer, 29.97 interlaced at the
    /// raster, of the film, or with the Film off of the framed source as if it were the film.
    /// Else the film itself: at the raster with the tape on, on the Scan canvas with it
    /// off. With the tape off that picture is returned as it is (a scan, or the transfer as
    /// digital video). With it on, the picture goes in Framing's place and the chain runs as
    /// the Look sets it, without the Camera (film or the transfer replaced the camcorder).
    private func encodeFilm(_ film: FilmLayers, commandBuffer: MTLCommandBuffer, source: MTLTexture,
                            frame ctx: FrameContext, device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        try film.prepare(device: device, library: library)
        let tapeOn = vhs?.tape.enabled ?? true
        let picture: MTLTexture
        if let vhs, vhs.telecineInUse {
            picture = try vhs.telecine.encode(commandBuffer: commandBuffer, film: film, source: source,
                                              framing: framing, frame: ctx, device: device, library: library)
        } else {
            // Under Fill the frame the scan keeps its height and takes the frame's shape, as a
            // scanner of a wide gauge would.
            let scan = fillAspect.map { (SignalChain.wideWidth(height: film.scanSize.height, aspect: $0),
                                         film.scanSize.height) } ?? film.scanSize
            let size = tapeOn ? (SignalChain.rasterWidth, SignalChain.rasterHeight) : scan
            picture = try film.encode(commandBuffer: commandBuffer, source: source, framing: framing, frame: ctx,
                                      width: size.0, height: size.1, device: device)
        }
        if !tapeOn { return picture }
        let all = layers
        var enabled = all.map { $0.enabled && !($0 is CameraLayer) }
        enabled[0] = true
        var result = intermediates[0]
        for step in SignalChain.plan(enabled: enabled) {
            let output = intermediates[step.output]
            if step.layerIndex == 0 {
                guard let blit = commandBuffer.makeBlitCommandEncoder() else { continue }
                blit.copy(from: picture, to: output)
                blit.endEncoding()
            } else {
                let input = step.input.map { intermediates[$0] } ?? source
                all[step.layerIndex].encode(commandBuffer: commandBuffer, in: input, out: output, frame: ctx)
            }
            result = output
        }
        return result
    }

    private func allocateIfNeeded(device: MTLDevice) throws {
        guard intermediates.isEmpty else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                         width: SignalChain.rasterWidth,
                                                         height: SignalChain.rasterHeight,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        for i in 0..<2 {
            guard let t = device.makeTexture(descriptor: d) else {
                throw ShaderLibrary.LoadError.noLibrary("could not allocate raster texture")
            }
            t.label = "raster \(i)"
            intermediates.append(t)
        }
    }
}
