import Foundation
import Metal

/// The value of one layer parameter.
public enum ParameterValue: Equatable, Sendable {
    case float(Double)
    case bool(Bool)
    case choice(String)

    public var doubleValue: Double? { if case .float(let v) = self { return v } else { return nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var choiceValue: String? { if case .choice(let v) = self { return v } else { return nil } }
}

/// One typed parameter a layer exposes. The sidebar builds its control from this:
/// `.float` is a slider over `range`, `.bool` a toggle, `.choice` a picker over `options`.
public struct LayerParameter: Identifiable, Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var value: String
        public var label: String
        public init(value: String, label: String) { self.value = value; self.label = label }
    }

    public var id: String
    public var name: String
    public var value: ParameterValue
    public var range: ClosedRange<Double>
    public var options: [Option]
    /// False when the parameter has no effect in the current state (shown disabled).
    public var isActive: Bool

    public init(id: String, name: String, value: ParameterValue,
                range: ClosedRange<Double> = 0...1, options: [Option] = [], isActive: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.range = range
        self.options = options
        self.isActive = isActive
    }

    /// A float's readout beside its slider: whole numbers for a seed (0 to 999) and a Rate (per
    /// minute, 5 or 78 or 12000), two decimals for the rest.
    public func readout(_ v: Double) -> String {
        String(format: id == "seed" || id == "rate" ? "%.0f" : "%.2f", v)
    }
}

/// Per frame context handed to every layer. Effect layers that vary over time (noise,
/// head switching) seed from `frameIndex` so a paused frame is stable.
public struct FrameContext: Sendable {
    /// Count of distinct source frames delivered since the file was opened.
    public var frameIndex: UInt64
    /// Source presentation time in seconds.
    public var time: Double
    /// Size of the source picture in pixels.
    public var sourceSize: CGSize
    /// Size of the working raster in pixels.
    public var rasterSize: CGSize

    public init(frameIndex: UInt64, time: Double, sourceSize: CGSize, rasterSize: CGSize) {
        self.frameIndex = frameIndex
        self.time = time
        self.sourceSize = sourceSize
        self.rasterSize = rasterSize
    }
}

/// One stage of the signal chain, running one or more Metal compute kernels.
///
/// The first layer reads the source frame (BGRA, source size) and writes the working raster.
/// Every later layer reads and writes RGBA16Float textures at the working raster size.
/// `encode` must write every pixel of `output`.
@MainActor
public protocol Layer: AnyObject {
    var id: String { get }
    var name: String { get }
    /// Disabled layers are skipped. A layer with `isRequired` ignores attempts to disable it.
    var enabled: Bool { get set }
    var isRequired: Bool { get }
    var parameters: [LayerParameter] { get }
    func setParameter(_ id: String, to value: ParameterValue)

    /// Builds pipelines once. The chain calls it before the first encode.
    func prepare(device: MTLDevice, library: MTLLibrary) throws
    func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                frame: FrameContext)

    /// Clears temporal state (a previous frame, running history). Called before an
    /// export's frame 0. Stateless layers keep the default no-op.
    func reset()
}

public extension Layer {
    var isRequired: Bool { false }
    func reset() {}
}

/// Dispatches a 2D compute kernel over every pixel of `size`.
public func dispatch2D(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                       width: Int, height: Int) {
    let tw = pipeline.threadExecutionWidth
    let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
    let group = MTLSize(width: tw, height: th, depth: 1)
    let grid = MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1)
    encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
}
