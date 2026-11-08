import AVFoundation
import Metal
import XCTest
@testable import HomeVideoCore

/// The Display stage. All six off is the raster byte for byte, each layer alone changes the
/// picture, every default and range is the one docs/CRT.md lists, a render repeats exactly, the
/// export is the Display size with a CRT layer on and 720 by 480 without, and a sidecar and a
/// preset carry the CRT layers.
@MainActor
final class CRTTests: XCTestCase {
    var gpu: GPUHarness!

    override func setUp() async throws {
        gpu = try GPUHarness()
    }

    /// Bars with a ramp below them and a white square, so every layer has something to act on.
    func source() throws -> MTLTexture {
        try gpu.source { x, y in
            if y < 240 {
                let bars: [(UInt8, UInt8, UInt8)] = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0),
                                                     (191, 0, 191), (191, 0, 0), (0, 0, 191), (16, 16, 16)]
                return bars[min(7, x * 8 / 720)]
            }
            if (300..<420).contains(y), (300..<420).contains(x) { return (255, 255, 255) }
            let v = UInt8(x * 255 / 719)
            return (v, v, v)
        }
    }

    /// The texture `encodeOutput` returns, its size and its raw half float bits.
    func output(_ chain: SignalChain, frame: UInt64 = 0) throws -> (width: Int, height: Int, bits: [UInt16]) {
        let src = try source()
        let cb = try XCTUnwrap(gpu.queue.makeCommandBuffer())
        let ctx = FrameContext(frameIndex: frame, time: Double(frame) / 29.97,
                               sourceSize: CGSize(width: 720, height: 480), rasterSize: .zero)
        // The tube's canvas at its Detail, before the Output size fits it into the file.
        let out = try chain.encodeLastStage(commandBuffer: cb, source: src, frame: ctx, device: gpu.device,
                                            library: gpu.library)
        return try read(out, cb)
    }

    func raster(_ chain: SignalChain) throws -> (width: Int, height: Int, bits: [UInt16]) {
        let src = try source()
        let cb = try XCTUnwrap(gpu.queue.makeCommandBuffer())
        let ctx = FrameContext(frameIndex: 0, time: 0, sourceSize: CGSize(width: 720, height: 480), rasterSize: .zero)
        let out = try chain.encode(commandBuffer: cb, source: src, frame: ctx, device: gpu.device, library: gpu.library)
        return try read(out, cb)
    }

    func read(_ t: MTLTexture, _ cb: MTLCommandBuffer) throws -> (width: Int, height: Int, bits: [UInt16]) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: t.width, height: t.height,
                                                         mipmapped: false)
        d.storageMode = .managed
        let readable = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: t, to: readable)
        blit.synchronize(resource: readable)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        var bits = [UInt16](repeating: 0, count: t.width * t.height * 4)
        readable.getBytes(&bits, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return (t.width, t.height, bits)
    }

    func crt(_ chain: SignalChain) throws -> CRTLayers { try XCTUnwrap(chain.vhs?.crt) }

    /// A chain at the small Display size, to keep the readbacks short.
    func smallChain() throws -> SignalChain {
        let c = SignalChain.standard()
        try crt(c).display.setParameter("size", to: .choice(DisplaySize.small.rawValue))
        return c
    }

    // MARK: All off

    func testAllOffIsTheRasterByteForByte() throws {
        let staged = SignalChain.standard()
        XCTAssertFalse(staged.displayIsOn)
        XCTAssertTrue(staged.outputSize == (720, 480))
        // The same chain with no Display stage at all: the VHS layers alone.
        let vhs = VHSLayers()
        let plain = SignalChain(effects: vhs.all)
        XCTAssertTrue(plain.displayLayers.isEmpty)
        let a = try output(staged), b = try raster(plain), c = try raster(SignalChain.standard())
        XCTAssertEqual(a.width, 720)
        XCTAssertEqual(a.height, 480)
        XCTAssertEqual(a.bits, b.bits, "all CRT layers off renders the main raster byte for byte")
        XCTAssertEqual(a.bits, c.bits)
        XCTAssertEqual(ChainFingerprint.of(staged), ChainFingerprint.of(plain), "the perf log's hash is unchanged")
    }

    // MARK: Each layer alone

    func testEachLayerAloneChangesThePicture() throws {
        // A neutral canvas: Glass on with every value 0 is the raster resampled and nothing else.
        let neutral = try smallChain()
        let g = try crt(neutral).glass
        g.enabled = true
        for p in ["tint", "reflection", "blackglow"] { g.setParameter(p, to: .float(0)) }
        let base = try output(neutral)
        XCTAssertEqual(base.width, 960)
        XCTAssertEqual(base.height, 720)
        var seen: [[UInt16]] = [base.bits]
        for i in 0..<6 {
            let c = try smallChain()
            let layer = try crt(c).layers[i]
            layer.enabled = true
            XCTAssertTrue(c.displayIsOn)
            let out = try output(c)
            let differing = zip(out.bits, base.bits).filter { $0 != $1 }.count
            XCTAssertGreaterThan(differing, out.bits.count / 100, "\(layer.id) alone changes the picture")
            XCTAssertFalse(seen.contains(out.bits), "\(layer.id) differs from the others")
            seen.append(out.bits)
        }
    }

    func testTheMaskPassesEachGunThroughItsOwnPhosphor() throws {
        // Gray through a full strength aperture grille: every canvas column is one
        // phosphor, lit in its own channel and dark in the other two.
        let c = try smallChain()
        let m = try crt(c).mask
        m.enabled = true
        m.setParameter("kind", to: .choice(CRTMaskLayer.Kind.apertureGrille.rawValue))
        m.setParameter("strength", to: .float(1))
        m.setParameter("triad", to: .float(3))
        let out = try output(c)
        let table = halfTable
        func px(_ x: Int, _ y: Int) -> [Float] { (0..<3).map { table[Int(out.bits[(y * out.width + x) * 4 + $0])] } }
        // Canvas row 600 is source row 400, in the gray ramp under the bars, and columns 300 to
        // 305 sit left of the white square, about a third up the ramp, so each has some light.
        let y = 600
        for x in 300..<306 {
            let p = px(x, y), lit = x % 3
            XCTAssertGreaterThan(p[lit], 0.05, "column \(x) lights its own phosphor")
            for ch in 0..<3 where ch != lit { XCTAssertEqual(p[ch], 0, accuracy: 1e-3, "column \(x) channel \(ch) dark") }
        }
    }

    // MARK: The doc

    func testDefaultsAndRangesMatchTheDoc() throws {
        let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/CRT.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let rows = text.split(separator: "\n").filter { $0.hasPrefix("| crt-") }.map {
            $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let layers = CRTLayers().all
        let expected = layers.reduce(0) { $0 + $1.parameters.count }
        XCTAssertEqual(rows.count, expected, "one row per CRT parameter")
        for r in rows {
            let (id, pid, def, lo, hi, ri) = (r[1], r[2], r[3], r[4], r[5], r[6])
            XCTAssertTrue(ri == "READ" || ri == "INFERRED", "\(id).\(pid) says READ or INFERRED")
            let layer = try XCTUnwrap(layers.first { $0.id == id }, id)
            let p = try XCTUnwrap(layer.parameters.first { $0.id == pid }, "\(id).\(pid)")
            switch p.value {
            case .float(let v):
                XCTAssertEqual(v, try XCTUnwrap(Double(def)), accuracy: 1e-9, "\(id).\(pid) default")
                XCTAssertEqual(p.range.lowerBound, try XCTUnwrap(Double(lo)), accuracy: 1e-9, "\(id).\(pid) min")
                XCTAssertEqual(p.range.upperBound, try XCTUnwrap(Double(hi)), accuracy: 1e-9, "\(id).\(pid) max")
            case .choice(let v):
                XCTAssertEqual(v, def, "\(id).\(pid) default")
                XCTAssertEqual(p.options.map(\.value).joined(separator: ", "), lo, "\(id).\(pid) options")
            case .bool:
                XCTFail("\(id).\(pid): no switches in the table")
            }
        }
        // Off by default, every one.
        XCTAssertFalse(CRTLayers().isOn)
        XCTAssertFalse(CRTLayers().layers.contains { $0.enabled })
    }

    func testNoLookTurnsACRTLayerOn() {
        // Only the Looks that film the screen turn the Display on, for the camera to film.
        for look in Looks.all where !look.filmsTheScreen {
            XCTAssertFalse(look.overrides.contains { $0.layer.hasPrefix("crt-") }, look.id)
            let vhs = VHSLayers()
            Presets(vhs: vhs).setLook(look)
            XCTAssertFalse(vhs.crt.isOn, look.id)
        }
    }

    func testABuiltInLookLeavesTheDisplayAlone() throws {
        let chain = SignalChain.standard()
        let vhs = try XCTUnwrap(chain.vhs)
        let presets = Presets(vhs: vhs, audio: chain.audio)
        vhs.crt.beam.enabled = true
        vhs.crt.beam.setParameter("dark", to: .float(0.2))
        presets.setLook(try XCTUnwrap(Looks.look(id: "dub-of-a-dub")))
        XCTAssertTrue(vhs.crt.beam.enabled)
        XCTAssertEqual(vhs.crt.beam.sigmaDark, 0.2)
        XCTAssertEqual(presets.look?.id, "dub-of-a-dub", "a CRT layer does not turn the picker to Custom")
    }

    // MARK: Repeats

    func testTwoRendersAreByteIdentical() throws {
        func allOn() throws -> SignalChain {
            let c = try smallChain()
            for l in try crt(c).layers { l.enabled = true }
            try crt(c).glow.setParameter("halation", to: .float(0.1))
            return c
        }
        let a = try output(try allOn(), frame: 7), b = try output(try allOn(), frame: 7)
        XCTAssertEqual(a.bits, b.bits, "same frame, same picture")
        let c = try allOn()
        _ = try output(c, frame: 7)
        XCTAssertEqual(try output(c, frame: 7).bits, a.bits, "a second draw of one chain too")
        XCTAssertNotEqual(try output(try allOn(), frame: 8).bits, a.bits, "the other field leads on the next frame")
    }

    // MARK: The export

    func testExportIsTheDisplaySizeWithACRTLayerOn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-crt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mov")
        try await ClipListTests.writeMovie(to: src, width: 720, height: 480, frames: 3)

        // The coded size (naturalSize applies the 720 by 480 file's 10:11 aperture).
        func size(_ chain: SignalChain, _ name: String) async throws -> CGSize {
            let out = dir.appendingPathComponent(name)
            _ = try await Exporter(source: src, destination: out, chain: chain, settings: .master).run()
            let track = try await XCTUnwrapAsync(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
            let f = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
            let d = CMVideoFormatDescriptionGetDimensions(f)
            return CGSize(width: Int(d.width), height: Int(d.height))
        }
        let on = SignalChain.standard()
        on.vhs?.crt.beam.enabled = true
        let crtSize = try await size(on, "on.mov")
        XCTAssertEqual(crtSize.width, 1440)
        XCTAssertEqual(crtSize.height, 1080)
        let offSize = try await size(SignalChain.standard(), "off.mov")
        XCTAssertEqual(offSize.width, 720)
        XCTAssertEqual(offSize.height, 480)
        let s = ExportSettings.master.videoSettings(display: (1440, 1080))
        XCTAssertNil(s[AVVideoCleanApertureKey], "the canvas is 4:3 already")
    }

    // MARK: Saved

    func customCRT(_ chain: SignalChain) throws {
        let c = try crt(chain)
        c.display.setParameter("size", to: .choice(DisplaySize.large.rawValue))
        c.beam.enabled = true
        c.beam.setParameter("bright", to: .float(0.4))
        c.mask.enabled = true
        c.mask.setParameter("kind", to: .choice(CRTMaskLayer.Kind.apertureGrille.rawValue))
        c.mask.setParameter("strength", to: .float(0.6))
        c.geometry.setParameter("overscan", to: .float(0.08))
    }

    func crtValues(_ chain: SignalChain) -> [String] {
        chain.displayLayers.flatMap { l in ["\(l.id) \(l.enabled)"] + l.parameters.map { "\(l.id).\($0.id)=\($0.value)" } }
    }

    func testASidecarCarriesTheCRTLayers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-crt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = SignalChain.standard()
        try customCRT(source)
        let url = dir.appendingPathComponent("clip.mov.homevideo.json")
        try Sidecar.write(chain: source, name: "clip.mov", lookID: nil, to: url)
        let target = SignalChain.standard()
        XCTAssertNotEqual(crtValues(target), crtValues(source))
        _ = try Sidecar.read(url, into: target)
        XCTAssertEqual(crtValues(target), crtValues(source))
        XCTAssertEqual(target.vhs?.crt.size, .large)
        XCTAssertTrue(target.outputSize == (1440, 1080), "the Detail is not the file's size")
    }

    func testAPresetAndTheClipboardCarryTheCRTLayers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-crt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = SignalChain.standard()
        try customCRT(source)
        let url = dir.appendingPathComponent("Tube.homevideopreset")
        try UserPresets.encode(name: "Tube", vhs: try XCTUnwrap(source.vhs), audio: source.audio).write(to: url)
        let target = SignalChain.standard()
        try UserPresets.apply(url, to: target)
        XCTAssertEqual(crtValues(target), crtValues(source))

        let pasted = SignalChain.standard()
        try SettingsClipboard.apply(SettingsClipboard.encode(source), to: pasted)
        XCTAssertEqual(crtValues(pasted), crtValues(source))
    }

    func testRenderArgumentsSetACRTLayer() throws {
        let chain = SignalChain.standard()
        let args = try RenderArguments.parse(["in.mov", "out.mov", "--set", "crt-beam.enabled=on",
                                              "--set", "crt-display.size=960x720", "--set", "crt-mask.triad=4"])
        try args.apply(to: chain)
        XCTAssertTrue(chain.vhs?.crt.beam.enabled == true)
        XCTAssertEqual(chain.vhs?.crt.size, .small)
        XCTAssertTrue(chain.outputSize == (1440, 1080), "the Detail is not the file's size")
        XCTAssertEqual(chain.vhs?.crt.mask.triad, 4)
    }

    // MARK: The pieces

    func testWhiteGains() {
        let d65 = CRTTransferLayer.whiteGains(kelvin: 6500)
        for g in [d65.x, d65.y, d65.z] { XCTAssertEqual(g, 1, accuracy: 0.01) }
        let blue = CRTTransferLayer.whiteGains(kelvin: 9300)
        XCTAssertEqual(blue.z, 1, accuracy: 1e-9, "the blue gun at full")
        XCTAssertLessThan(blue.x, blue.y, "red lowest")
        XCTAssertLessThan(blue.y, 1)
        XCTAssertGreaterThan(blue.x, 0.6)
    }

    func testDisplayZoomStaysOnTheCanvas() {
        var z = DisplayZoom()
        XCTAssertFalse(z.isZoomed)
        z.setZoom(100)
        XCTAssertEqual(z.zoom, 16)
        z.setZoom(4)
        z.pan(from: CGPoint(x: 0.5, y: 0.5), drag: CGVector(dx: 10, dy: -10))
        XCTAssertEqual(z.center.x, 0.125, accuracy: 1e-9)
        XCTAssertEqual(z.center.y, 0.875, accuracy: 1e-9)
        let w = z.window(canvasWidth: 1440, viewWidth: 1000)
        XCTAssertEqual(w[0], 0, accuracy: 1e-6)
        XCTAssertEqual(w[2], 0.25, accuracy: 1e-6)
        XCTAssertEqual(w[4], 1, "past 2 to 1 the pixels are squares")
        z.reset()
        XCTAssertFalse(z.isZoomed)
    }
}

/// XCTUnwrap for an async expression's result.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
