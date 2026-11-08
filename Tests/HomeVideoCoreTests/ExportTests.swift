import AVFoundation
import CoreGraphics
import Metal
import XCTest
@testable import HomeVideoCore

final class YCbCrReferenceTests: XCTestCase {
    func testBT601KnownTriples() {
        let m = YCbCrMatrix.bt601
        // Textbook 8 bit video range values for 75 and 100 percent primaries.
        XCTAssertTrue(m.encode(r: 1, g: 0, b: 0) == (81, 90, 240))
        XCTAssertTrue(m.encode(r: 0, g: 1, b: 0) == (145, 54, 34))
        XCTAssertTrue(m.encode(r: 0, g: 0, b: 1) == (41, 240, 110))
        XCTAssertTrue(m.encode(r: 1, g: 1, b: 1) == (235, 128, 128))
        XCTAssertTrue(m.encode(r: 0, g: 0, b: 0) == (16, 128, 128))
    }

    func testBT709Red() {
        XCTAssertTrue(YCbCrMatrix.bt709.encode(r: 1, g: 0, b: 0) == (63, 102, 240))
    }

    func testOutOfRangeIsClampedAndSyncCodesAvoided() {
        let m = YCbCrMatrix.bt601
        XCTAssertTrue(m.encode(r: 2, g: 2, b: 2) == (235, 128, 128))
        XCTAssertTrue(m.encode(r: -1, g: -1, b: -1) == (16, 128, 128))
    }
}

/// Runs the export kernels on the GPU over a tiny raster of known colors.
final class RasterConverterTests: XCTestCase {
    @MainActor
    private func convert(_ pixels: [(Float, Float, Float)], width: Int, height: Int,
                         format: ExportPixelFormat, matrix: YCbCrMatrix = .bt601) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let (lib, _) = try ShaderLibrary.make(device: device)
        // RGBA32Float, not the chain's RGBA16Float: Float16 is unavailable on x86_64 macOS and
        // the kernel reads `texture2d<float>` either way.
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        let tex = try XCTUnwrap(device.makeTexture(descriptor: d))
        let floats: [Float] = pixels.flatMap { p -> [Float] in [p.0, p.1, p.2, 1] }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: floats,
                    bytesPerRow: width * 16)
        let conv = try RasterConverter(device: device, library: lib, format: format, matrix: matrix,
                                       width: width, height: height)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        conv.encode(commandBuffer: cb, raster: tex)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        let p = conv.buffer.contents().bindMemory(to: UInt8.self, capacity: conv.buffer.length)
        return Array(UnsafeBufferPointer(start: p, count: conv.buffer.length))
    }

    private func assertNear(_ got: UInt8, _ want: UInt8, _ what: String, line: UInt = #line) {
        // Within 1/255: one code.
        XCTAssertLessThanOrEqual(abs(Int(got) - Int(want)), 1, "\(what): got \(got), want \(want)", line: line)
    }

    @MainActor
    func testKernelPacks2vuyWithBT601VideoRange() throws {
        let red: (Float, Float, Float) = (1, 0, 0)
        let white: (Float, Float, Float) = (1, 1, 1)
        let mid: (Float, Float, Float) = (0.25, 0.5, 0.75)
        let blue: (Float, Float, Float) = (0, 0, 1)
        // Row 0: [red, white] [mid, blue]; row 1: [blue, red] [white, mid].
        let bytes = try convert([red, white, mid, blue, blue, red, white, mid], width: 4, height: 2,
                                format: .yuv422)
        XCTAssertEqual(bytes.count, 4 * 2 * 2)
        let m = YCbCrMatrix.bt601
        func checkPair(_ offset: Int, even: (Float, Float, Float), odd: (Float, Float, Float), line: UInt = #line) {
            let e = m.encode(r: Double(even.0), g: Double(even.1), b: Double(even.2))
            let o = m.encode(r: Double(odd.0), g: Double(odd.1), b: Double(odd.2))
            // Byte order Cb Y0 Cr Y1; chroma cosited with the even pixel.
            assertNear(bytes[offset + 0], e.cb, "Cb", line: line)
            assertNear(bytes[offset + 1], e.y, "Y0", line: line)
            assertNear(bytes[offset + 2], e.cr, "Cr", line: line)
            assertNear(bytes[offset + 3], o.y, "Y1", line: line)
        }
        checkPair(0, even: red, odd: white)
        checkPair(4, even: mid, odd: blue)
        checkPair(8, even: blue, odd: red)
        checkPair(12, even: white, odd: mid)
        // The anchor triple, stated literally: 100 percent red is Y 81, Cb 90, Cr 240.
        assertNear(bytes[0], 90, "red Cb")
        assertNear(bytes[1], 81, "red Y")
        assertNear(bytes[2], 240, "red Cr")
        assertNear(bytes[3], 235, "white Y")
    }

    @MainActor
    func testKernelUsesTheMatrixItIsGiven() throws {
        let bytes = try convert([(1, 0, 0), (1, 0, 0)], width: 2, height: 1, format: .yuv422, matrix: .bt709)
        assertNear(bytes[0], 102, "709 red Cb")
        assertNear(bytes[1], 63, "709 red Y")
        assertNear(bytes[2], 240, "709 red Cr")
    }

    @MainActor
    func testKernelPacksBGRA() throws {
        let bytes = try convert([(1, 0.5, 0), (0, 0, 1)], width: 2, height: 1, format: .bgra)
        XCTAssertEqual(bytes, [0, 128, 255, 255, 255, 0, 0, 255])
    }
}

final class ExporterSettingsTests: XCTestCase {
    func testRotationFromPreferredTransform() {
        XCTAssertEqual(Exporter.rotationDegrees(of: .identity), 0)
        // iPhone portrait: a=0 b=1 c=-1 d=0.
        XCTAssertEqual(Exporter.rotationDegrees(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)), 90)
        XCTAssertEqual(Exporter.rotationDegrees(of: CGAffineTransform(rotationAngle: .pi)), 180)
        XCTAssertEqual(Exporter.rotationDegrees(of: CGAffineTransform(rotationAngle: -.pi / 2)), 270)
    }

    @MainActor
    func testVideoSettingsShow4x3() throws {
        let s = Exporter.videoSettings
        let par = try XCTUnwrap(s[AVVideoPixelAspectRatioKey] as? [String: Int])
        let clap = try XCTUnwrap(s[AVVideoCleanApertureKey] as? [String: Int])
        let width = Double(try XCTUnwrap(clap[AVVideoCleanApertureWidthKey]))
        let height = Double(try XCTUnwrap(clap[AVVideoCleanApertureHeightKey]))
        let h = Double(try XCTUnwrap(par[AVVideoPixelAspectRatioHorizontalSpacingKey]))
        let v = Double(try XCTUnwrap(par[AVVideoPixelAspectRatioVerticalSpacingKey]))
        XCTAssertEqual(width * h / v / height, 4.0 / 3.0, accuracy: 1e-9)
    }
}

final class RenderArgumentsTests: XCTestCase {
    func testFullInvocation() throws {
        let a = try RenderArguments.parse(["in.mov", "out.mov", "--frames", "30", "--layers", "none",
                                           "--set", "framing.mode=fullRaster", "--set", "framing.pan=-0.5"])
        XCTAssertEqual(a.input, "in.mov")
        XCTAssertEqual(a.output, "out.mov")
        XCTAssertEqual(a.frames, 30)
        XCTAssertEqual(a.layers, .none)
        XCTAssertEqual(a.settings, [.init(layer: "framing", parameter: "mode", value: "fullRaster"),
                                    .init(layer: "framing", parameter: "pan", value: "-0.5")])
        XCTAssertEqual(a.pixelFormat, .yuv422)
    }

    func testDefaultsAndInlineValues() throws {
        let a = try RenderArguments.parse(["--frames=5", "a.mp4", "b.mov", "--layers=luma, chroma", "--pixel-format",
                                           "bgra"])
        XCTAssertEqual(a.frames, 5)
        XCTAssertEqual(a.layers, .only(["luma", "chroma"]))
        XCTAssertEqual(a.pixelFormat, .bgra)
        let b = try RenderArguments.parse(["a.mp4", "b.mov"])
        XCTAssertEqual(b.layers, .standard)
        XCTAssertEqual(try RenderArguments.parse(["a.mp4", "b.mov", "--layers", "default"]).layers, .standard)
        XCTAssertNil(b.frames)
        XCTAssertTrue(b.settings.isEmpty)
    }

    func testValueMayContainEqualsAndDots() throws {
        let a = try RenderArguments.parse(["a", "b", "--set", "noise.seed.mode=x=1.5"])
        XCTAssertEqual(a.settings, [.init(layer: "noise", parameter: "seed.mode", value: "x=1.5")])
    }

    func testListLayersNeedsNoFiles() throws {
        XCTAssertTrue(try RenderArguments.parse(["--list-layers"]).listLayers)
    }

    func testErrors() {
        func err(_ args: [String]) -> RenderArguments.ParseError? {
            do { _ = try RenderArguments.parse(args); return nil } catch { return error as? RenderArguments.ParseError }
        }
        XCTAssertEqual(err(["in.mov"]), .missingPositional)
        XCTAssertEqual(err(["a", "b", "c"]), .extraPositional("c"))
        XCTAssertEqual(err(["a", "b", "--frames"]), .missingValue("--frames"))
        XCTAssertEqual(err(["a", "b", "--frames", "0"]), .badFrames("0"))
        XCTAssertEqual(err(["a", "b", "--frames", "x"]), .badFrames("x"))
        XCTAssertEqual(err(["a", "b", "--set", "framing=1"]), .badSetting("framing=1"))
        XCTAssertEqual(err(["a", "b", "--set", "framing.mode"]), .badSetting("framing.mode"))
        XCTAssertEqual(err(["a", "b", "--set", "framing.mode="]), .badSetting("framing.mode="))
        XCTAssertEqual(err(["a", "b", "--pixel-format", "v210"]), .badPixelFormat("v210"))
        XCTAssertEqual(err(["a", "b", "--bogus"]), .unknownOption("--bogus"))
    }

    @MainActor
    func testApplySelectsLayersByIdAndKeepsFraming() throws {
        let chain = SignalChain(effects: [RecordingLayer("luma"), RecordingLayer("chroma"), RecordingLayer("noise")])
        try RenderArguments(input: "a", output: "b", layers: .only(["chroma", "framing"])).apply(to: chain)
        XCTAssertEqual(chain.layers.map(\.enabled), [true, false, true, false])
        try RenderArguments(input: "a", output: "b", layers: .none).apply(to: chain)
        XCTAssertEqual(chain.layers.map(\.enabled), [true, false, false, false])
        try RenderArguments(input: "a", output: "b", layers: .all).apply(to: chain)
        XCTAssertEqual(chain.layers.map(\.enabled), [true, true, true, true])
        XCTAssertThrowsError(try RenderArguments(input: "a", output: "b", layers: .only(["tracking"])).apply(to: chain))
    }

    @MainActor
    func testApplySetsTypedParameters() throws {
        let chain = SignalChain()
        try RenderArguments(input: "a", output: "b",
                            settings: [.init(layer: "framing", parameter: "mode", value: "cropCenter"),
                                       .init(layer: "framing", parameter: "pan", value: "0.25")]).apply(to: chain)
        XCTAssertEqual(chain.framing.mode, .cropCenter)
        XCTAssertEqual(chain.framing.pan, 0.25)

        func applyError(_ s: RenderArguments.Setting) -> RenderArguments.ApplyError? {
            do {
                try RenderArguments(input: "a", output: "b", settings: [s]).apply(to: chain)
                return nil
            } catch {
                return error as? RenderArguments.ApplyError
            }
        }
        if case .unknownLayer("luma", _) = applyError(.init(layer: "luma", parameter: "x", value: "1")) {} else {
            XCTFail("unknown layer not reported")
        }
        if case .unknownParameter("tilt", "framing", _) = applyError(.init(layer: "framing", parameter: "tilt",
                                                                            value: "1")) {} else {
            XCTFail("unknown parameter not reported")
        }
        if case .badValue("wide", _, _) = applyError(.init(layer: "framing", parameter: "mode", value: "wide")) {} else {
            XCTFail("bad choice not reported")
        }
        if case .badValue("left", _, _) = applyError(.init(layer: "framing", parameter: "pan", value: "left")) {} else {
            XCTFail("bad number not reported")
        }
    }
}
