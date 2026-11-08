import CoreVideo
import Metal
import XCTest
@testable import HomeVideoCore

/// A layer that records when it ran and copies input to output.
@MainActor
final class RecordingLayer: Layer {
    let id: String
    let name: String
    var enabled: Bool
    static var log: [String] = []
    init(_ id: String, enabled: Bool = true) {
        self.id = id
        self.name = id
        self.enabled = enabled
    }
    var parameters: [LayerParameter] { [] }
    func setParameter(_ id: String, to value: ParameterValue) {}
    func prepare(device: MTLDevice, library: MTLLibrary) throws {}
    func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                frame: FrameContext) {
        RecordingLayer.log.append(id)
    }
}

final class SignalChainTests: XCTestCase {
    func testPlanRunsFramingFirstThenEnabledInOrderPingPong() {
        let steps = SignalChain.plan(enabled: [true, false, true, true, false, true])
        XCTAssertEqual(steps.map(\.layerIndex), [0, 2, 3, 5])
        XCTAssertEqual(steps.map(\.input), [nil, 0, 1, 0])
        XCTAssertEqual(steps.map(\.output), [0, 1, 0, 1])
    }

    func testPlanAlwaysRunsFramingEvenIfFlaggedOff() {
        let steps = SignalChain.plan(enabled: [false, false])
        XCTAssertEqual(steps, [SignalChain.Step(layerIndex: 0, input: nil, output: 0)])
    }

    func testEveryStepReadsWhatThePreviousWrote() {
        let steps = SignalChain.plan(enabled: [true, true, true, true, true])
        for (a, b) in zip(steps, steps.dropFirst()) {
            XCTAssertEqual(b.input, a.output)
            XCTAssertNotEqual(b.output, b.input)
        }
    }

    @MainActor
    func testFramingIsRequiredAndCannotBeDisabled() {
        let chain = SignalChain()
        XCTAssertTrue(chain.layers.first === chain.framing)
        chain.framing.enabled = false
        XCTAssertTrue(chain.framing.enabled)
        XCTAssertTrue(chain.framing.isRequired)
    }

    @MainActor
    func testFramingParametersRoundTrip() {
        let f = FramingLayer()
        f.setParameter("mode", to: .choice("cropCenter"))
        f.setParameter("pan", to: .float(-3))
        XCTAssertEqual(f.mode, .cropCenter)
        XCTAssertEqual(f.pan, -1)
        XCTAssertEqual(f.parameters.first { $0.id == "pan" }?.isActive, true)
        f.setParameter("mode", to: .choice("letterbox"))
        XCTAssertEqual(f.parameters.first { $0.id == "pan" }?.isActive, false)
        f.setParameter("mode", to: .choice("bogus"))
        XCTAssertEqual(f.mode, .letterbox)
    }

    @MainActor
    func testEncodeRunsEnabledLayersInSignalOrder() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let (lib, _) = try ShaderLibrary.make(device: device)
        let chain = SignalChain(effects: [RecordingLayer("a"), RecordingLayer("b", enabled: false),
                                          RecordingLayer("c")])
        RecordingLayer.log = []
        let src = try makeSource(device: device, width: 64, height: 36)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        _ = try chain.encode(commandBuffer: cb, source: src,
                             frame: FrameContext(frameIndex: 0, time: 0, sourceSize: CGSize(width: 64, height: 36),
                                                 rasterSize: .zero),
                             device: device, library: lib)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(RecordingLayer.log, ["a", "c"])
    }

    /// Renders a white 16:9 source through letterbox framing and reads the raster back:
    /// rows inside the 360 line picture are white, the 60 line bars are black.
    @MainActor
    func testLetterboxRenderHasBlackBarsAndWhitePicture() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let (lib, _) = try ShaderLibrary.make(device: device)
        let chain = SignalChain(framing: FramingLayer(mode: .letterbox))
        let src = try makeSource(device: device, width: 192, height: 108, white: true)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let raster = try chain.encode(commandBuffer: cb, source: src,
                                      frame: FrameContext(frameIndex: 0, time: 0,
                                                          sourceSize: CGSize(width: 192, height: 108),
                                                          rasterSize: .zero),
                                      device: device, library: lib)
        // Copy the private raster to a shared texture to read it.
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 720, height: 480,
                                                         mipmapped: false)
        // Managed, not shared: the Intel Macs' discrete GPUs do not share texture memory.
        d.storageMode = .managed
        let readable = try XCTUnwrap(device.makeTexture(descriptor: d))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: raster, to: readable)
        blit.synchronize(resource: readable)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(raster.width, 720)
        XCTAssertEqual(raster.height, 480)

        func red(_ x: Int, _ y: Int) -> Float {
            // Float16 is unavailable on x86_64 macOS, so decode the half by hand.
            var px = [UInt16](repeating: 0, count: 4)
            readable.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return halfToFloat(px[0])
        }
        XCTAssertEqual(red(360, 10), 0, accuracy: 0.01)    // top bar
        XCTAssertEqual(red(360, 59), 0, accuracy: 0.01)    // last bar line
        XCTAssertEqual(red(360, 61), 1, accuracy: 0.01)    // first picture line (60.5 is the edge)
        XCTAssertEqual(red(360, 240), 1, accuracy: 0.01)   // center
        XCTAssertEqual(red(5, 240), 1, accuracy: 0.01)     // picture spans full width
        XCTAssertEqual(red(360, 470), 0, accuracy: 0.01)   // bottom bar
    }

    private func halfToFloat(_ h: UInt16) -> Float {
        let sign: Float = (h & 0x8000) != 0 ? -1 : 1
        let exp = Int((h >> 10) & 0x1F)
        let frac = Float(h & 0x3FF)
        if exp == 0 { return sign * frac * powf(2, -24) }
        if exp == 31 { return frac == 0 ? sign * .infinity : .nan }
        return sign * (1 + frac / 1024) * powf(2, Float(exp - 15))
    }

    private func makeSource(device: MTLDevice, width: Int, height: Int, white: Bool = false) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        let t = try XCTUnwrap(device.makeTexture(descriptor: d))
        let bytes = [UInt8](repeating: white ? 255 : 0, count: width * height * 4)
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
                  bytesPerRow: width * 4)
        return t
    }
}
