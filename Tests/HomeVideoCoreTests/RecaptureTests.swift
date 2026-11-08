import AVFoundation
import Metal
import XCTest
@testable import HomeVideoCore

/// Re-capture, a camera filming the Display. Unused, the picture is the Display stage's
/// (and the raster with the Display off) byte for byte. Each layer alone changes the picture, the
/// shutter bar drifts as docs/RECAPTURE.md's arithmetic says, measured on rendered
/// frames, the moire goes with the Mask, Tight shows no bezel, the defaults and ranges are
/// docs/RECAPTURE.md's, a seed repeats, the export is the camera's size, and a sidecar, a
/// preset and the clipboard carry the stage.
@MainActor
final class RecaptureTests: XCTestCase {
    var gpu: GPUHarness!

    override func setUp() async throws {
        gpu = try GPUHarness()
    }

    typealias Frame = (width: Int, height: Int, bits: [UInt16])

    /// Bars over a ramp with a white square, as CRTTests draws.
    func bars() throws -> MTLTexture {
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

    func flat(_ v: UInt8) throws -> MTLTexture { try gpu.source { _, _ in (v, v, v) } }

    func output(_ chain: SignalChain, frame: UInt64 = 0, source: MTLTexture? = nil) throws -> Frame {
        let src = try source ?? bars()
        let cb = try XCTUnwrap(gpu.queue.makeCommandBuffer())
        let ctx = FrameContext(frameIndex: frame, time: Double(frame) / 29.97,
                               sourceSize: CGSize(width: 720, height: 480), rasterSize: .zero)
        let out = try chain.encodeOutput(commandBuffer: cb, source: src, frame: ctx, device: gpu.device,
                                         library: gpu.library)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: out.width,
                                                         height: out.height, mipmapped: false)
        d.storageMode = .managed
        let readable = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: out, to: readable)
        blit.synchronize(resource: readable)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        var bits = [UInt16](repeating: 0, count: out.width * out.height * 4)
        readable.getBytes(&bits, bytesPerRow: out.width * 8, from: MTLRegionMake2D(0, 0, out.width, out.height),
                          mipmapLevel: 0)
        return (out.width, out.height, bits)
    }

    func px(_ f: Frame, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let t = halfTable, i = (y * f.width + x) * 4
        return SIMD3(t[Int(f.bits[i])], t[Int(f.bits[i + 1])], t[Int(f.bits[i + 2])])
    }

    func vhs(_ c: SignalChain) throws -> VHSLayers { try XCTUnwrap(c.vhs) }

    /// A Display that only resamples: Glass on with every value 0.
    func neutralDisplay(_ c: SignalChain) throws {
        let g = try vhs(c).crt.glass
        g.enabled = true
        for p in ["tint", "reflection", "blackglow"] { g.setParameter(p, to: .float(0)) }
    }

    /// The camera on with every layer off: the canvas resampled to the camera's frame.
    func bareCamera(_ c: SignalChain) throws -> RecaptureLayers {
        let rc = try vhs(c).recapture
        rc.stage.enabled = true
        for l in rc.layers { l.enabled = false }
        return rc
    }

    // MARK: Unused

    func testUnusedIsTheDisplayAndTheRasterByteForByte() throws {
        // The Display on, the camera's switch off: every camera value moved changes nothing.
        let plain = SignalChain.standard()
        try vhs(plain).crt.beam.enabled = true
        let moved = SignalChain.standard()
        try vhs(moved).crt.beam.enabled = true
        let rc = try vhs(moved).recapture
        rc.stage.setParameter("camera", to: .choice(RecaptureCamera.fourThree.rawValue))
        rc.shutter.setParameter("shutter", to: .float(300))
        rc.hand.setParameter("yaw", to: .float(-12))
        XCTAssertFalse(moved.recaptureIsOn)
        let a = try output(plain), b = try output(moved)
        XCTAssertEqual(a.width, 1440)
        XCTAssertEqual(a.height, 1080)
        XCTAssertEqual(a.bits, b.bits, "Re-capture unused leaves the Display's canvas byte for byte")
        XCTAssertEqual(ChainFingerprint.of(plain), ChainFingerprint.of(moved), "and the perf log's hash")

        // The camera's switch on with the Display off: it needs Display, so the raster goes out.
        let off = SignalChain.standard()
        try vhs(off).recapture.stage.enabled = true
        XCTAssertFalse(off.recaptureIsOn)
        XCTAssertTrue(off.outputSize == (720, 480))
        let main = SignalChain(effects: VHSLayers().all)
        let r = try output(off), m = try output(main)
        XCTAssertEqual(r.bits, m.bits, "with the Display off the raster is the plain chain's byte for byte")
        XCTAssertEqual(ChainFingerprint.of(SignalChain.standard()), ChainFingerprint.of(main))
    }

    // MARK: Each layer alone

    func testEachLayerAloneChangesThePicture() throws {
        let base = SignalChain.standard()
        try neutralDisplay(base)
        _ = try bareCamera(base)
        XCTAssertTrue(base.recaptureIsOn)
        let b = try output(base, frame: 3)
        XCTAssertEqual(b.width, 1920)
        XCTAssertEqual(b.height, 1080)
        var seen: [[UInt16]] = [b.bits]
        for i in 0..<7 {
            let c = SignalChain.standard()
            try neutralDisplay(c)
            let layer = try bareCamera(c).layers[i]
            layer.enabled = true
            let out = try output(c, frame: 3)
            let differing = zip(out.bits, b.bits).filter { $0 != $1 }.count
            XCTAssertGreaterThan(differing, out.bits.count / 100, "\(layer.id) alone changes the picture")
            XCTAssertFalse(seen.contains(out.bits), "\(layer.id) differs from the others")
            seen.append(out.bits)
        }
    }

    // MARK: The bar

    /// The bar's phase in screen heights, measured on a rendered frame: the whole screen in a
    /// 4:3 frame, a global shutter of 1/120 s (half the screen dark), a flat white picture. The
    /// rows inside the screen, each at its height on the glass, give the circular mean of the
    /// light's pattern, one period a screen height.
    func barPhase(fps: String, frame: UInt64) throws -> Double {
        let c = SignalChain.standard()
        try neutralDisplay(c)
        let rc = try bareCamera(c)
        rc.stage.setParameter("framing", to: .choice(RecaptureFraming.whole.rawValue))
        rc.stage.setParameter("camera", to: .choice(RecaptureCamera.fourThree.rawValue))
        let s = rc.shutter
        s.enabled = true
        s.setParameter("rate", to: .choice(fps))
        s.setParameter("kind", to: .choice(RecaptureShutterLayer.Kind.global.rawValue))
        s.setParameter("shutter", to: .float(120))
        s.setParameter("decay", to: .float(0.05))
        let f = try output(c, frame: frame, source: try flat(235))
        let h = Double(f.height), scale = 1 / RecaptureFraming.wholeHeight
        var re = 0.0, im = 0.0
        for y in 0..<f.height {
            let screenY = 0.5 + (Double(y) + 0.5 - h / 2) / h * scale
            guard screenY > 0, screenY < 1 else { continue }
            var sum = 0.0
            for x in stride(from: f.width / 3, to: 2 * f.width / 3, by: 4) { sum += Double(px(f, x, y).y) }
            re += sum * cos(2 * .pi * screenY)
            im += sum * sin(2 * .pi * screenY)
        }
        return atan2(im, re) / (2 * .pi)
    }

    func wrap(_ v: Double) -> Double { v - v.rounded() }

    func testTheBarDriftsAsTheArithmeticSays() throws {
        // docs/RECAPTURE.md: 25 fps moves the bar 0.398 of the screen a frame, 30 fps
        // minus 0.002 a frame (minus 0.2 over 100 frames), 60 fps minus 0.001 a frame.
        let doc: [(String, UInt64, Double)] = [("25", 1, 0.398), ("30", 100, -0.2), ("60", 100, -0.1)]
        for (fps, frames, expected) in doc {
            let a = try barPhase(fps: fps, frame: 0), b = try barPhase(fps: fps, frame: frames)
            let measured = wrap(b - a)
            XCTAssertEqual(measured, expected, accuracy: 0.01, "\(fps) fps over \(frames) frames")
        }
        // 29.97 fps is two fields a frame exactly: the bar stands still.
        XCTAssertEqual(wrap(try barPhase(fps: "29.97", frame: 60) - barPhase(fps: "29.97", frame: 0)), 0, accuracy: 0.002)
        // And a whole field's shutter has no bar to measure.
        XCTAssertEqual(RecaptureShutterLayer.barDrift(fps: 30), -0.001998, accuracy: 1e-6)
    }

    // MARK: The moire

    /// How much the color swings across the frame at moire scale: the red over green ratio,
    /// averaged down the middle rows and over 4 pixel steps (two Bayer tiles, past the triad),
    /// then its standard deviation.
    func colorSwing(maskOn: Bool) throws -> Double {
        let c = SignalChain.standard()
        // The tape's own chroma noise off, so only the camera can put color into the frame.
        try vhs(c).allOff()
        try neutralDisplay(c)
        let m = try vhs(c).crt.mask
        m.enabled = maskOn
        m.setParameter("strength", to: .float(1))
        let rc = try bareCamera(c)
        rc.sensor.enabled = true
        rc.sensor.setParameter("olpf", to: .float(0))
        rc.sensor.setParameter("noise", to: .float(0))
        let f = try output(c, source: try flat(160))
        var cols: [Double] = []
        for x in 0..<f.width {
            var r = 0.0, g = 0.0
            for y in stride(from: 400, to: 680, by: 2) {
                let p = px(f, x, y)
                r += Double(p.x)
                g += Double(p.y)
            }
            cols.append(r / max(g, 1e-6))
        }
        var smooth: [Double] = []
        for x in stride(from: 100, to: f.width - 104, by: 1) { smooth.append(cols[x..<x + 4].reduce(0, +) / 4) }
        let mean = smooth.reduce(0, +) / Double(smooth.count)
        return (smooth.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(smooth.count)).squareRoot()
    }

    func testTheMoireGoesWithTheMask() throws {
        let on = try colorSwing(maskOn: true), off = try colorSwing(maskOn: false)
        XCTAssertGreaterThan(on, 0.02, "the grille sampled through the Bayer mosaic beats into color bands")
        XCTAssertLessThan(off, 0.002, "with the Mask off there is no pattern to undersample")
    }

    // MARK: Framing

    func testTightShowsNoBezel() throws {
        func darkest(_ framing: RecaptureFraming, _ camera: RecaptureCamera = .phone) throws -> Float {
            let c = SignalChain.standard()
            let crt = try vhs(c).crt
            crt.geometry.enabled = true
            crt.geometry.setParameter("barrel", to: .float(0.1))
            crt.geometry.setParameter("falloff", to: .float(0))
            let rc = try bareCamera(c)
            rc.stage.setParameter("framing", to: .choice(framing.rawValue))
            rc.stage.setParameter("camera", to: .choice(camera.rawValue))
            let hand = rc.hand
            hand.enabled = true
            // The hand at its widest: the frame still stays on the picture.
            for (p, v) in [("drift", 3.0), ("shake", 4.0), ("yaw", 20.0), ("pitch", -15.0)] {
                hand.setParameter(p, to: .float(v))
            }
            var low: Float = 1
            for frame: UInt64 in [0, 17, 45] {
                let f = try output(c, frame: frame, source: try flat(235))
                for y in stride(from: 0, to: f.height, by: 3) {
                    for x in stride(from: 0, to: f.width, by: 3) { low = min(low, px(f, x, y).y) }
                }
            }
            return low
        }
        XCTAssertGreaterThan(try darkest(.tight), 0.5, "Tight: every pixel is lit picture, no bezel or corner")
        XCTAssertLessThan(try darkest(.whole), 0.2, "Whole: the bezel and the room show")
        // The upright phone, the same rule.
        XCTAssertGreaterThan(try darkest(.tight, .phoneUpright), 0.5, "upright Tight: no bezel or corner")
        XCTAssertLessThan(try darkest(.whole, .phoneUpright), 0.2, "upright Whole: the room shows")
    }

    /// Whole on the upright phone puts the whole 4:3 screen across the frame's width, 78
    /// percent of it, with the room above and below: the middle row's ends are the room and its
    /// middle is lit, and the middle column is lit through the screen's height and dark past it.
    func testWholeOnTheUprightPhoneGoesAcross() throws {
        let c = SignalChain.standard()
        try neutralDisplay(c)
        let rc = try bareCamera(c)
        rc.stage.setParameter("framing", to: .choice(RecaptureFraming.whole.rawValue))
        rc.stage.setParameter("camera", to: .choice(RecaptureCamera.phoneUpright.rawValue))
        let f = try output(c, frame: 0, source: try flat(235))
        XCTAssertEqual(f.width, 1080)
        XCTAssertEqual(f.height, 1920)
        let mid = f.height / 2
        XCTAssertLessThan(px(f, 20, mid).y, 0.2, "the room left of the screen")
        XCTAssertLessThan(px(f, f.width - 21, mid).y, 0.2, "the room right of the screen")
        XCTAssertGreaterThan(px(f, f.width / 2, mid).y, 0.5, "the screen")
        // The screen is 0.78 of 1080 wide, so 0.78 times 1080 times 3 over 4 tall, about 632 rows.
        let half = Int(0.78 * 1080 * 0.75 / 2)
        XCTAssertGreaterThan(px(f, f.width / 2, mid - half + 40).y, 0.5, "inside the top edge")
        XCTAssertLessThan(px(f, f.width / 2, mid - half - 80).y, 0.2, "the room above")
        XCTAssertLessThan(px(f, f.width / 2, mid + half + 80).y, 0.2, "the room below")
    }

    // MARK: The doc

    func testDefaultsAndRangesMatchTheDoc() throws {
        let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/RECAPTURE.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let rows = text.split(separator: "\n").filter { $0.hasPrefix("| recapture") }.map {
            $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let layers = RecaptureLayers().all
        XCTAssertEqual(rows.count, layers.reduce(0) { $0 + $1.parameters.count }, "one row per parameter")
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
        let rc = RecaptureLayers()
        XCTAssertFalse(rc.stage.enabled, "the stage's switch is off by default")
        XCTAssertTrue(rc.layers.allSatisfy(\.enabled), "its layers are on, ready when it is")
    }

    // MARK: The Looks

    func testOnlyTheFilmedLooksTurnTheCameraOn() throws {
        let filmed = Looks.all.filter(\.filmsTheScreen).map(\.id)
        XCTAssertEqual(filmed, ["filmed-tv", "phone-dub", "tripod-tv", "up-close"])
        for look in Looks.all {
            let chain = SignalChain.standard()
            let presets = Presets(vhs: try vhs(chain), audio: chain.audio)
            presets.setLook(look)
            XCTAssertEqual(chain.recaptureIsOn, look.filmsTheScreen, look.id)
            XCTAssertEqual(presets.look?.id, look.id, "\(look.id) reads back")
        }
        // A Look that does not film switches the camera off and leaves the Display on.
        let chain = SignalChain.standard()
        let presets = Presets(vhs: try vhs(chain), audio: chain.audio)
        presets.setLook(try XCTUnwrap(Looks.look(id: "phone-dub")))
        presets.setLook(try XCTUnwrap(Looks.look(id: "clean-sp")))
        XCTAssertFalse(chain.recaptureIsOn)
        XCTAssertTrue(chain.displayIsOn)
        XCTAssertEqual(presets.look?.id, "clean-sp")
        // The names stay short, so the Look menu keeps its width (no longer than Tape Transfer).
        for id in filmed { XCTAssertLessThanOrEqual(try XCTUnwrap(Looks.look(id: id)).name.count, 9) }
    }

    // MARK: Repeats

    func testTwoRendersWithOneSeedAreByteIdentical() throws {
        func filmed(seed: Double) throws -> SignalChain {
            let c = SignalChain.standard()
            let p = Presets(vhs: try vhs(c), audio: c.audio)
            p.setLook(try XCTUnwrap(Looks.look(id: "filmed-tv")))
            try vhs(c).recapture.stage.setParameter("seed", to: .float(seed))
            return c
        }
        let a = try output(try filmed(seed: 5), frame: 11), b = try output(try filmed(seed: 5), frame: 11)
        XCTAssertEqual(a.bits, b.bits, "same seed, same frame, same picture")
        XCTAssertNotEqual(try output(try filmed(seed: 6), frame: 11).bits, a.bits, "another seed, another take")
    }

    // MARK: The export

    func testTheExportIsTheCameraSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-rc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mov")
        try await ClipListTests.writeMovie(to: src, width: 720, height: 480, frames: 3)
        func size(_ camera: RecaptureCamera) async throws -> CGSize {
            let chain = SignalChain.standard()
            chain.vhs?.crt.beam.enabled = true
            chain.vhs?.recapture.stage.enabled = true
            chain.vhs?.recapture.stage.setParameter("camera", to: .choice(camera.rawValue))
            let out = dir.appendingPathComponent("\(camera.rawValue).mov")
            _ = try await Exporter(source: src, destination: out, chain: chain, settings: .master).run()
            let track = try await XCTUnwrapAsync(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
            let f = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
            let d = CMVideoFormatDescriptionGetDimensions(f)
            return CGSize(width: Int(d.width), height: Int(d.height))
        }
        let phone = try await size(.phone)
        XCTAssertEqual(phone.width, 1920)
        XCTAssertEqual(phone.height, 1080)
        let four = try await size(.fourThree)
        XCTAssertEqual(four.width, 1440)
        XCTAssertEqual(four.height, 1080)
        // The phone held upright, with no Output size picked.
        let upright = try await size(.phoneUpright)
        XCTAssertEqual(upright.width, 1080)
        XCTAssertEqual(upright.height, 1920)
    }

    /// Tight on the upright phone keeps the picture's height less the margin and crops its
    /// sides, by the same rule as on 16:9, and the hand's reach shrinks it as there.
    func testTightOnTheUprightPhoneKeepsTheHeight() {
        let aspect = 1080.0 / 1920
        let still = RecaptureLayers.tightScale(aspect: aspect, reach: 0, yaw: 0, pitch: 0)
        XCTAssertEqual(still, 1 - RecaptureFraming.tightMargin, accuracy: 1e-9, "height bound, not width")
        XCTAssertLessThan(aspect * still, 4.0 / 3, "the picture's sides fall outside the frame")
        let held = RecaptureLayers.tightScale(aspect: aspect, reach: 0.012, yaw: 4 * .pi / 180, pitch: -2 * .pi / 180)
        XCTAssertLessThan(held, still)
        XCTAssertGreaterThan(held, 0.8)
        XCTAssertEqual(RecaptureCamera.phoneUpright.width, 1080)
        XCTAssertEqual(RecaptureCamera.phoneUpright.height, 1920)
        XCTAssertTrue(RecaptureCamera.phoneUpright.readsAcross)
        XCTAssertFalse(RecaptureCamera.phone.readsAcross)
        XCTAssertFalse(RecaptureCamera.fourThree.readsAcross)
    }

    // MARK: Saved

    func custom(_ chain: SignalChain) throws {
        let v = try vhs(chain)
        v.crt.beam.enabled = true
        let rc = v.recapture
        rc.stage.enabled = true
        rc.stage.setParameter("framing", to: .choice(RecaptureFraming.whole.rawValue))
        rc.stage.setParameter("seed", to: .float(42))
        rc.shutter.setParameter("rate", to: .choice("25"))
        rc.shutter.setParameter("shutter", to: .float(250))
        rc.glare.enabled = false
        rc.processing.setParameter("bitrate", to: .float(8.5))
    }

    func values(_ chain: SignalChain) -> [String] {
        (chain.vhs?.recapture.all ?? []).flatMap { l in
            ["\(l.id) \(l.enabled)"] + l.parameters.map { "\(l.id).\($0.id)=\($0.value)" }
        }
    }

    func testASidecarAPresetAndTheClipboardCarryTheStage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-rc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = SignalChain.standard()
        try custom(source)
        XCTAssertNotEqual(values(SignalChain.standard()), values(source))

        let side = dir.appendingPathComponent("clip.mov.homevideo.json")
        try Sidecar.write(chain: source, name: "clip.mov", lookID: nil, to: side)
        let a = SignalChain.standard()
        _ = try Sidecar.read(side, into: a)
        XCTAssertEqual(values(a), values(source), "the sidecar")
        XCTAssertTrue(a.recaptureIsOn)

        let preset = dir.appendingPathComponent("Filmed.homevideopreset")
        try UserPresets.encode(name: "Filmed", vhs: try vhs(source), audio: source.audio).write(to: preset)
        let b = SignalChain.standard()
        try UserPresets.apply(preset, to: b)
        XCTAssertEqual(values(b), values(source), "the preset")

        let c = SignalChain.standard()
        try SettingsClipboard.apply(SettingsClipboard.encode(source), to: c)
        XCTAssertEqual(values(c), values(source), "the clipboard")
    }

    func testRenderArgumentsTurnTheCameraOn() throws {
        let chain = SignalChain.standard()
        let args = try RenderArguments.parse(["in.mov", "out.mov", "--set", "crt-beam.enabled=on",
                                              "--set", "recapture.enabled=on",
                                              "--set", "recapture.camera=camera-1440x1080",
                                              "--set", "recapture-shutter.rate=25"])
        try args.apply(to: chain)
        XCTAssertTrue(chain.recaptureIsOn)
        XCTAssertTrue(chain.outputSize == (1440, 1080))
        XCTAssertEqual(chain.vhs?.recapture.shutter.rate, .r25)
    }
}
