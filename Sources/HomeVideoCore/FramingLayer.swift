import Foundation
import Metal
import Observation

/// The first pass, always on: places the source picture on the NTSC working raster.
@MainActor
@Observable
public final class FramingLayer: Layer {
    public let id = "framing"
    public let name = "Framing"
    public let isRequired = true

    public var enabled: Bool {
        get { true }
        set { _ = newValue } // required layer: cannot be turned off
    }

    /// Center crop by default: a clip with no sidecar opens
    /// filling the 4:3 raster. A sidecar's mode still wins, and Looks never set framing.
    public var mode: FramingMode = .cropCenter
    /// -1 (left) to 1 (right). Moves the center crop, and Fit inside's window once zoomed.
    public var pan: Double = 0
    /// -1 (top) to 1 (bottom), as `pan`. On a portrait clip under the center crop this is the
    /// axis with room at zoom 1.
    public var panY: Double = 0
    /// 1 to 2: the center crop's window shrinks by this on both axes, giving the pans room.
    /// Under Fit inside the fitted picture grows by it and the bars shrink.
    public var zoom: Double = 1
    /// The displayed (rotated) size of the last frame encoded, so the pan controls show only
    /// along an axis with room. Zero until a frame has run.
    public private(set) var shownSize: CGSize = .zero
    /// Clockwise display rotation of the decoded frames (0, 90, 180, 270), from the track's
    /// preferredTransform. Applied before letterbox, crop or full raster. The preview sets it
    /// from `FrameSource.rotation`; the export path sets it the same way.
    public var rotation: Int = 0 {
        didSet {
            let r = FramingMath.normalizedRotation(rotation)
            if r != rotation { rotation = r }
        }
    }

    /// The display aspect of the picture Framing fills, when it is not the 4:3 raster: with every
    /// stage off Framing places the source on the output's own canvas. Nil is 4:3. Set by
    /// the chain before each frame, never saved.
    @ObservationIgnored public var canvasAspect: CGFloat?

    /// Everything that moves where the source lands: two frames placed with equal placements
    /// are the same picture. The Film's held frame and the Telecine's cached frames are kept
    /// only while it stands, so a pan moved while paused redraws them.
    public struct Placement: Equatable, Sendable {
        var mode: FramingMode, pan: Double, panY: Double, zoom: Double, rotation: Int, aspect: CGFloat?
    }

    /// The canvas's display aspect: 4:3 unless the chain set another.
    var aspect: CGFloat { canvasAspect ?? FramingMath.rasterDisplayAspect }

    public var placement: Placement {
        Placement(mode: mode, pan: pan, panY: panY, zoom: zoom, rotation: rotation, aspect: canvasAspect)
    }

    @ObservationIgnored private var pipeline: MTLComputePipelineState?

    public init(mode: FramingMode = .cropCenter, pan: Double = 0, panY: Double = 0, zoom: Double = 1,
                rotation: Int = 0) {
        self.mode = mode
        self.pan = Double(FramingMath.clampPan(pan))
        self.panY = Double(FramingMath.clampPan(panY))
        self.zoom = Double(FramingMath.clampZoom(zoom))
        self.rotation = FramingMath.normalizedRotation(rotation)
    }

    /// True when pan, panY and zoom are all at their defaults.
    public var isCropAtDefault: Bool { pan == 0 && panY == 0 && zoom == 1 }

    /// Pan and zoom back to the centered, unzoomed crop (the viewer's double-click).
    public func resetCrop() {
        pan = 0
        panY = 0
        zoom = 1
    }

    /// The crop window for the current settings on the last encoded frame's size.
    public var cropRect: CGRect {
        FramingMath.rects(sourceSize: shownSize, mode: mode, pan: CGFloat(pan), panY: CGFloat(panY),
                          zoom: CGFloat(zoom), rasterAspect: aspect).source
    }

    public var parameters: [LayerParameter] {
        let crop = mode.movesWindow
        // Before the first frame the size is unknown, so both pans stay live, except under Fit
        // inside at zoom 1, which shows the whole picture with no room on either axis.
        let known = (shownSize.width > 0 && shownSize.height > 0) || (mode == .letterbox && zoom <= 1)
        let window = cropRect
        return [
            LayerParameter(id: "mode", name: "Mode", value: .choice(mode.rawValue),
                           options: FramingMode.allCases.map { .init(value: $0.rawValue, label: $0.label) }),
            LayerParameter(id: "zoom", name: "Zoom", value: .float(zoom), range: 1...2, isActive: crop),
            // The ids stay "pan" and "panY" so sidecars, presets and --set keep working.
            LayerParameter(id: "pan", name: "Pan X", value: .float(pan), range: -1...1,
                           isActive: crop && (!known || window.width < 1 - 1e-9)),
            LayerParameter(id: "panY", name: "Pan Y", value: .float(panY), range: -1...1,
                           isActive: crop && (!known || window.height < 1 - 1e-9)),
            LayerParameter(id: "rotation", name: "Rotation", value: .choice(String(rotation)),
                           options: [0, 90, 180, 270].map { .init(value: String($0), label: "\($0)°") }),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("mode", .choice(let raw)):
            if let m = FramingMode(rawValue: raw) { mode = m }
        case ("pan", .float(let v)):
            pan = Double(FramingMath.clampPan(CGFloat(v)))
        case ("panY", .float(let v)):
            panY = Double(FramingMath.clampPan(CGFloat(v)))
        case ("zoom", .float(let v)):
            zoom = Double(FramingMath.clampZoom(CGFloat(v)))
        case ("rotation", .choice(let raw)):
            if let r = Int(raw) { rotation = FramingMath.normalizedRotation(r) }
        case ("rotation", .float(let v)):
            // The export path may pass degrees as a float.
            if v.isFinite { rotation = FramingMath.normalizedRotation(Int(v.rounded())) }
        default:
            break
        }
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        guard pipeline == nil else { return }
        guard let fn = library.makeFunction(name: "framing") else {
            throw ShaderLibrary.LoadError.noLibrary("kernel 'framing'")
        }
        pipeline = try device.makeComputePipelineState(function: fn)
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let pipeline, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        // The rects live in the displayed (rotated) picture; the shader maps back to the buffer.
        let shown = FramingMath.displaySize(frame.sourceSize, rotation: rotation)
        if shown != shownSize { shownSize = shown }
        let r = FramingMath.rects(sourceSize: shown, mode: mode, pan: CGFloat(pan), panY: CGFloat(panY),
                                  zoom: CGFloat(zoom), rasterAspect: aspect)
        // Padded to the Metal struct's 48 bytes (two float4 and a uint, 16 byte aligned).
        var params: [Float] = [
            Float(r.source.minX), Float(r.source.minY), Float(r.source.width), Float(r.source.height),
            Float(r.destination.minX), Float(r.destination.minY),
            Float(r.destination.width), Float(r.destination.height),
            Float(bitPattern: UInt32(rotation)), 0, 0, 0,
        ]
        enc.label = "Framing"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        enc.setBytes(&params, length: params.count * MemoryLayout<Float>.stride, index: 0)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}
