import CoreGraphics
import Metal
import XCTest
@testable import HomeVideoCore

final class FramingRotationTests: XCTestCase {
    let hd = CGSize(width: 1920, height: 1080)
    /// The iPhone portrait track transform for a 1920 by 1080 stream.
    let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    func testRotationFromPreferredTransform() {
        XCTAssertEqual(FramingMath.rotation(of: .identity), 0)
        XCTAssertEqual(FramingMath.rotation(of: portrait), 90)
        XCTAssertEqual(FramingMath.rotation(of: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)), 180)
        XCTAssertEqual(FramingMath.rotation(of: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)), 270)
        XCTAssertEqual(FramingMath.normalizedRotation(-90), 270)
        XCTAssertEqual(FramingMath.normalizedRotation(450), 90)
    }

    /// bufferPoint agrees with the transform itself: a buffer pixel pushed through the
    /// preferredTransform lands on the display point that maps back to it.
    func testBufferPointInvertsThePortraitTransform() {
        for (bx, by) in [(0.0, 0.0), (1920.0, 0.0), (480.0, 270.0), (1920.0, 1080.0)] {
            let d = CGPoint(x: bx, y: by).applying(portrait)
            let display = CGPoint(x: d.x / 1080, y: d.y / 1920)
            let b = FramingMath.bufferPoint(display, rotation: 90)
            XCTAssertEqual(b.x, bx / 1920, accuracy: 1e-9)
            XCTAssertEqual(b.y, by / 1080, accuracy: 1e-9)
        }
        let p = CGPoint(x: 0.3, y: 0.8)
        XCTAssertEqual(FramingMath.bufferPoint(p, rotation: 0), p)
        // 270 undoes 90.
        let q = FramingMath.bufferPoint(p, rotation: 90)
        let back = FramingMath.bufferPoint(CGPoint(x: 1 - q.x, y: 1 - q.y), rotation: 180)
        XCTAssertEqual(FramingMath.bufferPoint(back, rotation: 270).x, FramingMath.bufferPoint(p, rotation: 0).x,
                       accuracy: 0.6)
    }

    func testPortraitLetterboxIsPillarboxedAndCropTakesTheMiddle() {
        let shown = FramingMath.displaySize(hd, rotation: 90)
        XCTAssertEqual(shown, CGSize(width: 1080, height: 1920))
        let lb = FramingMath.rects(sourceSize: shown, mode: .letterbox)
        // (1080 / 1920) / (4 / 3) = 0.421875 of the raster width, centered.
        XCTAssertEqual(lb.destination.width, 0.421875, accuracy: 1e-9)
        XCTAssertEqual(lb.destination.minX, (1 - 0.421875) / 2, accuracy: 1e-9)
        XCTAssertEqual(lb.destination.height, 1, accuracy: 1e-9)
        let crop = FramingMath.rects(sourceSize: shown, mode: .cropCenter)
        XCTAssertEqual(crop.source.height, 0.421875, accuracy: 1e-9)
        XCTAssertEqual(crop.source.minY, (1 - 0.421875) / 2, accuracy: 1e-9)
        XCTAssertEqual(FramingMath.displaySize(hd, rotation: 180), hd)
    }

    /// A 180 degree landscape stays landscape (letterboxed) and samples upside down.
    func testUpsideDownLandscape() {
        let shown = FramingMath.displaySize(hd, rotation: 180)
        let lb = FramingMath.rects(sourceSize: shown, mode: .letterbox)
        XCTAssertEqual(lb.destination.height, 0.75, accuracy: 1e-9)
        let p = FramingMath.bufferPoint(CGPoint(x: 0.1, y: 0.2), rotation: 180)
        XCTAssertEqual(p.x, 0.9, accuracy: 1e-12)
        XCTAssertEqual(p.y, 0.8, accuracy: 1e-12)
    }

    /// A clip of 720 by 1280 pixels and no transform pillarboxes from the raw size.
    func testRawPortraitPixelsPillarboxWithoutRotation() {
        let raw = CGSize(width: 720, height: 1280)
        XCTAssertEqual(FramingMath.rotation(of: .identity), 0)
        let lb = FramingMath.rects(sourceSize: FramingMath.displaySize(raw, rotation: 0), mode: .letterbox)
        XCTAssertEqual(lb.destination.width, 0.421875, accuracy: 1e-9)
        XCTAssertEqual(lb.destination.height, 1, accuracy: 1e-9)
    }

    @MainActor
    func testFramingLayerRotationParameter() {
        let f = FramingLayer()
        f.setParameter("rotation", to: .choice("270"))
        XCTAssertEqual(f.rotation, 270)
        f.rotation = 360
        XCTAssertEqual(f.rotation, 0)
        f.setParameter("rotation", to: .float(90))
        XCTAssertEqual(f.rotation, 90)
    }

    /// On the GPU: a landscape buffer whose left quarter is red, rotated 90 and letterboxed,
    /// shows a pillarboxed portrait picture with the red at the top.
    @MainActor
    func testRotatedRenderPutsBufferLeftAtTheTop() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let lib = try ShaderLibrary.make(device: device).0
        let w = 64, h = 36
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        let src = try XCTUnwrap(device.makeTexture(descriptor: d))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w where x < 16 { bytes[(y * w + x) * 4] = 0; bytes[(y * w + x) * 4 + 1] = 0 } }
        src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)

        let chain = SignalChain(framing: FramingLayer(mode: .letterbox, rotation: 90))
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let raster = try chain.encode(commandBuffer: cb, source: src,
                                      frame: FrameContext(frameIndex: 0, time: 0, sourceSize: CGSize(width: w, height: h),
                                                          rasterSize: .zero),
                                      device: device, library: lib)
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 720, height: 480, mipmapped: false)
        rd.storageMode = .managed
        let readable = try XCTUnwrap(device.makeTexture(descriptor: rd))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: raster, to: readable)
        blit.synchronize(resource: readable)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        func px(_ x: Int, _ y: Int) -> SIMD3<Float> {
            var p = [UInt16](repeating: 0, count: 4)
            readable.getBytes(&p, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return SIMD3(halfToFloat(p[0]), halfToFloat(p[1]), halfToFloat(p[2]))
        }
        XCTAssertEqual(px(20, 240), SIMD3(0, 0, 0), "pillarbox bar")
        let top = px(360, 20), bottom = px(360, 460)
        XCTAssertEqual(top.x, 1, accuracy: 0.01)
        XCTAssertEqual(top.y, 0, accuracy: 0.01, "the buffer's left (red) is the display's top")
        XCTAssertEqual(bottom.y, 1, accuracy: 0.01)
    }
}
