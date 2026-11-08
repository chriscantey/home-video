import Metal
import XCTest
@testable import HomeVideoCore

/// A 720 by 480 raster read back from the GPU, RGBA floats.
struct Raster {
    static let matrix = YIQ.forward.map { $0.map(Float.init) }
    let width: Int, height: Int
    var data: [Float]

    func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = (y * width + x) * 4
        return SIMD3(data[i], data[i + 1], data[i + 2])
    }

    /// The pixel converted to YIQ with the chain's own matrix.
    func yiq(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let c = rgb(x, y), m = Raster.matrix
        return SIMD3(m[0][0] * c.x + m[0][1] * c.y + m[0][2] * c.z,
                     m[1][0] * c.x + m[1][1] * c.y + m[1][2] * c.z,
                     m[2][0] * c.x + m[2][1] * c.y + m[2][2] * c.z)
    }

    func row(_ y: Int, _ channel: (SIMD3<Float>) -> Float, yiq: Bool = false) -> [Float] {
        (0..<width).map { channel(yiq ? self.yiq($0, y) : rgb($0, y)) }
    }
}

/// Runs a chain on a 720 by 480 BGRA source with full raster framing (a 1:1 copy) and reads
/// the result back. The readback: blit the private raster to a managed
/// texture, synchronize, decode the halves by hand (Float16 is unavailable on x86_64).
@MainActor
final class GPUHarness {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    static let w = SignalChain.rasterWidth, h = SignalChain.rasterHeight

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        self.device = device
        self.queue = queue
        library = try ShaderLibrary.make(device: device).0
    }

    /// A source picture from a function of (x, y) to 8 bit RGB.
    func source(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> MTLTexture {
        let w = Self.w, h = Self.h
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                         mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        let t = try XCTUnwrap(device.makeTexture(descriptor: d))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = pixel(x, y)
                let i = (y * w + x) * 4
                bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r
            }
        }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        return t
    }

    func run(_ chain: SignalChain, _ source: MTLTexture, frame: UInt64 = 0) throws -> Raster {
        try run(chain, source, frame: frame, raw: false).0
    }

    /// The raster and its raw half float bits.
    func run(_ chain: SignalChain, _ source: MTLTexture, frame: UInt64, raw: Bool) throws -> (Raster, [UInt16]) {
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let ctx = FrameContext(frameIndex: frame, time: Double(frame) / 29.97,
                               sourceSize: CGSize(width: Self.w, height: Self.h), rasterSize: .zero)
        let raster = try chain.encode(commandBuffer: cb, source: source, frame: ctx, device: device, library: library)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Self.w, height: Self.h,
                                                         mipmapped: false)
        d.storageMode = .managed
        let readable = try XCTUnwrap(device.makeTexture(descriptor: d))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: raster, to: readable)
        blit.synchronize(resource: readable)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        var bits = [UInt16](repeating: 0, count: Self.w * Self.h * 4)
        readable.getBytes(&bits, bytesPerRow: Self.w * 8, from: MTLRegionMake2D(0, 0, Self.w, Self.h), mipmapLevel: 0)
        let table = halfTable
        return (Raster(width: Self.w, height: Self.h, data: bits.map { table[Int($0)] }), bits)
    }

    /// A chain with full raster framing and the VHS layers, every one of them off.
    func vhsChain() -> (SignalChain, VHSLayers) {
        let vhs = VHSLayers()
        vhs.allOff()
        return (SignalChain(framing: FramingLayer(mode: .fullRaster), effects: vhs.all), vhs)
    }
}

/// Every half decoded once, since the debug build is too slow to decode 1.4M halves per run.
let halfTable: [Float] = (0...UInt16.max).map(halfToFloat)

func halfToFloat(_ h: UInt16) -> Float {
    let sign: Float = (h & 0x8000) != 0 ? -1 : 1
    let exp = Int((h >> 10) & 0x1F)
    let frac = Float(h & 0x3FF)
    if exp == 0 { return sign * frac * powf(2, -24) }
    if exp == 31 { return frac == 0 ? sign * .infinity : .nan }
    return sign * (1 + frac / 1024) * powf(2, Float(exp - 15))
}

/// Width in samples of a rising transition from lo to hi: from the first sample past 10
/// percent to the first past 90 percent, searched from `from`.
func transitionWidth(_ s: [Float], lo: Float, hi: Float, from: Int = 0) -> Int {
    let a = lo + 0.1 * (hi - lo), b = lo + 0.9 * (hi - lo)
    guard let i = s[from...].firstIndex(where: { $0 > a }),
          let j = s[i...].firstIndex(where: { $0 > b }) else { return -1 }
    return j - i
}

/// Subpixel position where a rising signal first crosses the midpoint of lo and hi.
func crossing(_ s: [Float], lo: Float, hi: Float, from: Int = 0) -> Double {
    let m = (lo + hi) / 2
    guard let j = s[from...].firstIndex(where: { $0 > m }), j > 0 else { return -1 }
    let a = s[j - 1], b = s[j]
    return Double(j - 1) + Double((m - a) / (b - a))
}
