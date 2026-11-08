#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreGraphics
import Metal
import Observation

/// The VCR's on-screen display, "PLAY ▶ SP" or "PAUSE ❚❚ SP" in white blocky letters with a dark
/// edge at the top left of the picture. Decks burned it into their video output, so captures
/// carry it: the layer runs after L8 and before the L9 capture card, in YIQ, and the exporter
/// runs it like any other layer. Off by default.
///
/// The text is drawn once per state change into a small texture at half the raster scale with
/// antialiasing off, then read nearest neighbor at 2x, which gives the coarse character cells
/// of a deck's character generator.
@MainActor
@Observable
public final class OSDLayer: Layer {
    public let id = "osd"
    public let name = "VCR on-screen display"
    public var enabled = false
    /// Set by the preview from the transport. The exporter clears it (an export is playing).
    public var paused = false
    /// The tape speed shown, read from L3 so it follows the Tape preset.
    @ObservationIgnored var speed: @MainActor () -> TapeSpeed = { .sp }

    /// Top left of the text in raster pixels, inside the 4:3 title safe area.
    static let origin = SIMD2<UInt32>(48, 36)
    /// Raster pixels per character-generator pixel.
    static let scale: UInt32 = 2
    static let fontSize: CGFloat = 13

    @ObservationIgnored private var pipeline: MTLComputePipelineState?
    @ObservationIgnored private var device: MTLDevice?
    @ObservationIgnored private var texture: MTLTexture?
    @ObservationIgnored private(set) var renderedText: String?

    public init() {}

    public var parameters: [LayerParameter] { [] }
    public func setParameter(_ id: String, to value: ParameterValue) {}

    /// What the deck shows right now.
    public var text: String {
        (paused ? "PAUSE \u{275A}\u{275A}" : "PLAY \u{25B6}") + "  " + speed().label
    }

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {
        pipeline = try makePipeline("osd_overlay", device: device, library: library)
        self.device = device
    }

    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        let t = text
        if t != renderedText, let device {
            texture = OSDLayer.makeTexture(text: t, device: device)
            renderedText = t
        }
        guard let pipeline, let texture, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "VCR OSD"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(texture, index: 1)
        enc.setTexture(output, index: 2)
        var p: [UInt32] = [OSDLayer.origin.x, OSDLayer.origin.y, OSDLayer.scale]
        enc.setBytes(&p, length: p.count * 4, index: 0)
        dispatch2D(enc, pipeline: pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }

    /// Draws `text` into an RGBA8 bitmap: a one cell dark edge (the text drawn black at the
    /// eight neighbors) under the white text. Memory row 0 is the top of the picture.
    static func makeBitmap(text: String) -> (pixels: [UInt8], width: Int, height: Int) {
        #if os(macOS)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).size(withAttributes: attrs)
        let width = Int(size.width.rounded(.up)) + 4
        let height = Int(size.height.rounded(.up)) + 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setShouldAntialias(false)
            ctx.setAllowsFontSmoothing(false)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            let base = CGPoint(x: 2, y: 2)
            let edge = attrs.merging([.foregroundColor: NSColor.black]) { $1 }
            for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                (text as NSString).draw(at: CGPoint(x: base.x + CGFloat(dx), y: base.y + CGFloat(dy)), withAttributes: edge)
            } }
            (text as NSString).draw(at: base, withAttributes: attrs.merging([.foregroundColor: NSColor.white]) { $1 })
            NSGraphicsContext.restoreGraphicsState()
        }
        return (pixels, width, height)
        #else
        // The same drawing through UIKit. UIKit draws top down, so the context is flipped first
        // and the text's top left sits 2 px in, where the Mac's bottom left origin puts it.
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).size(withAttributes: attrs)
        let width = Int(size.width.rounded(.up)) + 4
        let height = Int(size.height.rounded(.up)) + 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setShouldAntialias(false)
            ctx.setAllowsFontSmoothing(false)
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            let base = CGPoint(x: 2, y: 2)
            let edge = attrs.merging([.foregroundColor: UIColor.black]) { $1 }
            for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                (text as NSString).draw(at: CGPoint(x: base.x + CGFloat(dx), y: base.y + CGFloat(dy)), withAttributes: edge)
            } }
            (text as NSString).draw(at: base, withAttributes: attrs.merging([.foregroundColor: UIColor.white]) { $1 })
            UIGraphicsPopContext()
        }
        return (pixels, width, height)
        #endif
    }

    static func makeTexture(text: String, device: MTLDevice) -> MTLTexture? {
        let (pixels, w, h) = makeBitmap(text: text)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.label = "VCR OSD text"
        pixels.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4)
        }
        return t
    }
}
