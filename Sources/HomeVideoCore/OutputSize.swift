import Foundation
import Metal
import Observation

/// The file's size, picked on the Look tab.
public enum OutputSize: String, CaseIterable, Sendable {
    /// The size the last stage makes (`SignalChain.naturalSize`), the default.
    case auto
    /// The source's own size, upright.
    case source
    /// 720 by 480 shown 4:3, the tape's raster with its 10:11 pixels and 601 tags.
    case sd
    /// 1920 by 1080, square pixels.
    case hd
    /// 3840 by 2160, square pixels.
    case uhd
    /// 1080 by 1920, square pixels, a phone held upright. A size like the others, never set by
    /// a Look.
    case phone
    /// The width and height typed in, even numbers inside `widthRange` and `heightRange`.
    case custom

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .source: "Match source"
        case .sd: "SD 720×480"
        case .hd: "HD 1920×1080"
        case .uhd: "4K 3840×2160"
        case .phone: "Phone 1080×1920"
        case .custom: "Custom"
        }
    }

    /// The fixed sizes' own width and height, nil for the ones that depend on the clip or the field.
    public var fixed: (width: Int, height: Int)? {
        switch self {
        case .sd: (SignalChain.rasterWidth, SignalChain.rasterHeight)
        case .hd: (1920, 1080)
        case .uhd: (3840, 2160)
        case .phone: (1080, 1920)
        default: nil
        }
    }
}

/// The Output size kept as a layer, so a sidecar, a preset, the clipboard and `--set
/// output.size=hd` carry it like any value. It draws nothing itself: `SignalChain.encodeOutput`
/// fits the last stage's picture into it. A file names it only once it is moved from Auto, so a
/// file written at Auto matches one written before the Output size existed. A Look never sets
/// it, as it never sets Framing.
@MainActor
@Observable
public final class OutputSizeLayer: Layer {
    public let id = "output"
    public let name = "Output size"
    public let isRequired = true

    public var enabled: Bool {
        get { true }
        set { _ = newValue }
    }

    public var size: OutputSize = .auto
    /// The Picture choice: false, the default, fits the chain's 4:3 picture inside the frame,
    /// true has every stage work at the frame's shape
    /// so the picture fills it (`SignalChain.fillAspect`). Only a picked size that is not 4:3 uses it.
    public var fill = false
    /// Custom's width and height, kept while another size is chosen.
    public var width = 1280
    public var height = 720

    /// Sane ends for Custom: a thumbnail to 8K.
    public static let widthRange = 128...7680
    public static let heightRange = 96...4320

    public init() {}

    /// True at Auto, the default, where nothing about the file changes.
    public var isAuto: Bool { size == .auto }

    /// A typed number brought to the nearest even value inside `range` (4:2:0 and 4:2:2 codecs
    /// want even sizes).
    public nonisolated static func clamp(_ v: Double, to range: ClosedRange<Int>) -> Int {
        guard v.isFinite else { return range.lowerBound }
        let even = Int((v / 2).rounded()) * 2
        return min(max(even, range.lowerBound), range.upperBound)
    }

    /// The file's size for a last stage that makes `natural`, from a source shown at `source`.
    public func resolve(natural: (width: Int, height: Int), source: (width: Int, height: Int)) -> (width: Int, height: Int) {
        switch size {
        case .auto: return natural
        case .source: return source.width > 0 && source.height > 0 ? source : natural
        case .custom: return (width, height)
        case .sd, .hd, .uhd, .phone: return size.fixed ?? natural
        }
    }

    public var parameters: [LayerParameter] {
        let custom = size == .custom
        return [
            LayerParameter(id: "size", name: "Output size", value: .choice(size.rawValue),
                           options: OutputSize.allCases.map { .init(value: $0.rawValue, label: $0.label) }),
            LayerParameter(id: "fill", name: "Picture", value: .bool(fill), isActive: size != .auto && size != .sd),
            LayerParameter(id: "width", name: "Width", value: .float(Double(width)),
                           range: Double(Self.widthRange.lowerBound)...Double(Self.widthRange.upperBound),
                           isActive: custom),
            LayerParameter(id: "height", name: "Height", value: .float(Double(height)),
                           range: Double(Self.heightRange.lowerBound)...Double(Self.heightRange.upperBound),
                           isActive: custom),
        ]
    }

    public func setParameter(_ id: String, to value: ParameterValue) {
        switch (id, value) {
        case ("size", .choice(let c)):
            if let s = OutputSize(rawValue: c) { size = s }
        case ("fill", .bool(let v)):
            fill = v
        case ("width", .float(let v)):
            width = Self.clamp(v, to: Self.widthRange)
        case ("height", .float(let v)):
            height = Self.clamp(v, to: Self.heightRange)
        default:
            break
        }
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {}

    /// Never a chain step. Copies, so the protocol's contract holds if one is ever listed.
    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let b = commandBuffer.makeBlitCommandEncoder() else { return }
        b.copy(from: input, to: output)
        b.endEncoding()
    }
}
