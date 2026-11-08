import Metal
import XCTest
@testable import HomeVideoCore

/// One path, Film (the source), Telecine, Tape, Display, Re-capture, each a switch the chain
/// asks "is it on". Every combination that can exist renders at the last stage's size, not black,
/// no NaN, the same twice with one seed. Every stage off is the source frame. Tape off with the
/// Display is the framed source on the tube. The default chain is the plain VHS chain byte for
/// byte. An old
/// Film Scan file loads as Tape off, and `--set tape=off` reaches the switch.
@MainActor
final class StageTests: XCTestCase {
    /// Which stages are on.
    struct Stages: CustomStringConvertible {
        var film = false, telecine = false, tape = true, display = false, recapture = false

        var description: String {
            let on = [("film", film), ("telecine", telecine), ("tape", tape), ("display", display),
                      ("recapture", recapture)].filter(\.1).map(\.0)
            return on.isEmpty ? "all off" : on.joined(separator: "+")
        }
    }

    /// Every combination that can exist: 24 of the 32. The 8 with Re-capture on and the Display
    /// off cannot (the camera films the tube, its switch does nothing alone). Telecine on with
    /// Film off can: it transfers the framed source.
    static var matrix: [Stages] {
        var all: [Stages] = []
        for film in [false, true] {
            for telecine in [false, true] {
                for tape in [false, true] {
                    for display in [false, true] {
                        for recapture in display ? [false, true] : [false] {
                            all.append(Stages(film: film, telecine: telecine, tape: tape, display: display,
                                              recapture: recapture))
                        }
                    }
                }
            }
        }
        return all
    }

    /// The source is not the raster's size, so "its own size" can be told apart: 640 by 360.
    static let sourceW = 640, sourceH = 360

    /// Edges, a ramp and color bands at 640 by 360.
    func source(_ g: GPUHarness, width: Int = sourceW, height: Int = sourceH) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        let t = try XCTUnwrap(g.device.makeTexture(descriptor: d))
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                  withBytes: Self.bytes(width: width, height: height), bytesPerRow: width * 4)
        return t
    }

    /// The source's BGRA bytes.
    static func bytes(width: Int, height: Int) -> [UInt8] {
        var b = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let v = UInt8(30 + (x * 200) / width)
                let band = (x / 40) % 3
                b[i] = band == 0 ? v : 60
                b[i + 1] = band == 1 ? v : UInt8(40 + (y * 150) / height)
                b[i + 2] = band == 2 ? v : 90
            }
        }
        return b
    }

    func chain(_ s: Stages) -> SignalChain {
        let chain = SignalChain.standard()
        let vhs = chain.vhs!
        vhs.film.source.enabled = s.film
        vhs.telecine.source.enabled = s.telecine
        vhs.tape.enabled = s.tape
        for l in vhs.crt.layers { l.enabled = s.display }
        vhs.recapture.stage.enabled = s.recapture
        return chain
    }

    /// The size the last stage gives, by the table in docs/SIGNAL-CHAIN.md.
    func expectedSize(_ s: Stages) -> (Int, Int) {
        if s.recapture { return (1920, 1080) }
        if s.display { return (1440, 1080) }
        if s.tape || s.telecine { return (720, 480) }
        if s.film { return (1440, 1080) }
        return (Self.sourceW, Self.sourceH)
    }

    /// The picture `encodeOutput` returns for frame `frame`, as floats.
    func render(_ g: GPUHarness, _ chain: SignalChain, _ src: MTLTexture, frame: UInt64)
        throws -> (width: Int, height: Int, values: [Float]) {
        let cb = try XCTUnwrap(g.queue.makeCommandBuffer())
        let ctx = FrameContext(frameIndex: frame, time: Double(frame) / 30,
                               sourceSize: CGSize(width: src.width, height: src.height), rasterSize: .zero)
        let out = try chain.encodeOutput(commandBuffer: cb, source: src, frame: ctx, device: g.device,
                                         library: g.library)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: out.pixelFormat, width: out.width,
                                                         height: out.height, mipmapped: false)
        d.storageMode = .managed
        let readable = try XCTUnwrap(g.device.makeTexture(descriptor: d))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: out, to: readable)
        blit.synchronize(resource: readable)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        let region = MTLRegionMake2D(0, 0, out.width, out.height)
        switch out.pixelFormat {
        case .rgba16Float:
            var bits = [UInt16](repeating: 0, count: out.width * out.height * 4)
            readable.getBytes(&bits, bytesPerRow: out.width * 8, from: region, mipmapLevel: 0)
            let table = halfTable
            return (out.width, out.height, bits.map { table[Int($0)] })
        case .rgba32Float:
            var f = [Float](repeating: 0, count: out.width * out.height * 4)
            readable.getBytes(&f, bytesPerRow: out.width * 16, from: region, mipmapLevel: 0)
            return (out.width, out.height, f)
        default:
            var b = [UInt8](repeating: 0, count: out.width * out.height * 4)
            readable.getBytes(&b, bytesPerRow: out.width * 4, from: region, mipmapLevel: 0)
            return (out.width, out.height, b.map { Float($0) / 255 })
        }
    }

    // MARK: The matrix

    /// Every combination that can exist: the last stage's size (and `outputSize` says it), not
    /// black, no NaN or infinity, and two fresh chains with one seed give the same picture.
    func testEveryStageCombinationRendersAtItsSize() throws {
        let g = try GPUHarness()
        let src = try source(g)
        XCTAssertEqual(Self.matrix.count, 24)
        for s in Self.matrix {
            let a = chain(s)
            let (w, h) = expectedSize(s)
            let out = try render(g, a, src, frame: 3)
            XCTAssertEqual(out.width, w, "\(s) width")
            XCTAssertEqual(out.height, h, "\(s) height")
            XCTAssertEqual(a.outputSize.width, w, "\(s) outputSize says the width")
            XCTAssertEqual(a.outputSize.height, h, "\(s) outputSize says the height")
            XCTAssertTrue(out.values.allSatisfy(\.isFinite), "\(s) has no NaN")
            var sum: Float = 0, peak: Float = 0
            for i in stride(from: 0, to: out.values.count, by: 4) {
                let y = 0.299 * out.values[i] + 0.587 * out.values[i + 1] + 0.114 * out.values[i + 2]
                sum += y
                peak = max(peak, y)
            }
            let mean = sum / Float(out.width * out.height)
            XCTAssertGreaterThan(mean, 0.03, "\(s) is not black (mean \(mean))")
            XCTAssertGreaterThan(peak, 0.15, "\(s) is not black (peak \(peak))")
            let again = try render(g, chain(s), src, frame: 3)
            XCTAssertEqual(again.values, out.values, "\(s) is the same twice with one seed")
        }
    }

    /// The last stage is what `output` names, which sets the writer's tags.
    func testOutputNamesTheLastStage() {
        func output(_ s: Stages) -> SignalChain.Output { chain(s).output }
        XCTAssertEqual(output(Stages()), .raster)
        XCTAssertEqual(output(Stages(tape: false)), .source)
        XCTAssertEqual(output(Stages(film: true, tape: false)), .scan)
        XCTAssertEqual(output(Stages(film: true)), .raster)
        XCTAssertEqual(output(Stages(film: true, telecine: true, tape: false)), .raster, "the transfer as digital video")
        XCTAssertEqual(output(Stages(telecine: true, tape: false)), .raster, "the clip's transfer, no Film")
        XCTAssertEqual(output(Stages(tape: false, display: true)), .display)
        XCTAssertEqual(output(Stages(tape: false, display: true, recapture: true)), .camera)
        XCTAssertTrue(SignalChain.Output.scan.isHD && SignalChain.Output.source.isHD)
        XCTAssertFalse(SignalChain.Output.raster.isSquare)
    }

    // MARK: The ends of the path

    /// Every stage off writes the source untouched: its own size, its own values.
    func testEveryStageOffIsTheSourceFrame() throws {
        let g = try GPUHarness()
        let src = try source(g)
        let c = chain(Stages(tape: false))
        let out = try render(g, c, src, frame: 0)
        XCTAssertEqual(out.width, Self.sourceW)
        XCTAssertEqual(out.height, Self.sourceH)
        let bytes = Self.bytes(width: Self.sourceW, height: Self.sourceH)
        var worst: Float = 0
        for p in 0..<(Self.sourceW * Self.sourceH) {
            for (o, b) in [(0, 2), (1, 1), (2, 0)] {
                worst = max(worst, abs(out.values[p * 4 + o] - Float(bytes[p * 4 + b]) / 255))
            }
        }
        // Half floats hold 8 bit values to within half a code.
        XCTAssertLessThan(worst, 0.5 / 255, "the source's own values (worst \(worst * 255) codes)")
        // Upright: a clip whose track turns it 90 degrees comes out turned, 360 by 640.
        c.framing.rotation = 90
        let turned = try render(g, c, src, frame: 1)
        XCTAssertEqual(turned.width, Self.sourceH)
        XCTAssertEqual(turned.height, Self.sourceW)
        XCTAssertEqual(c.outputSize.width, Self.sourceH)
    }

    /// Tape off plus the Display is the framed source on the tube: exactly what the Display draws
    /// from a chain whose every VHS layer is off (Framing alone).
    func testTapeOffIntoTheDisplayIsTheFramedSourceOnTheTube() throws {
        let g = try GPUHarness()
        let src = try source(g)
        let a = chain(Stages(tape: false, display: true))
        let b = chain(Stages(display: true))
        b.vhs!.allOff()
        let x = try render(g, a, src, frame: 2), y = try render(g, b, src, frame: 2)
        XCTAssertEqual(x.width, 1440)
        XCTAssertEqual(x.values, y.values)
        // And it is not the tape's picture.
        let taped = try render(g, chain(Stages(display: true)), src, frame: 2)
        XCTAssertNotEqual(x.values, taped.values)
    }

    /// The default chain (Tape on, every other stage off) is a chain without any stage plumbing,
    /// byte for byte, at frames 0 and 7, so the stages leave the default picture alone.
    func testTheDefaultChainIsThePlainChainByteForByte() throws {
        let g = try GPUHarness()
        let src = try g.source { x, y in (UInt8((x * 255) / 720), UInt8((y * 255) / 480), UInt8((x / 30) % 2 * 200)) }
        let plain = SignalChain(effects: VHSLayers().all)
        XCTAssertNil(plain.vhs)
        let staged = SignalChain.standard()
        XCTAssertTrue(staged.vhs!.tape.enabled)
        XCTAssertEqual(staged.output, .raster)
        for frame: UInt64 in [0, 7] {
            let a = try render(g, plain, src, frame: frame), b = try render(g, staged, src, frame: frame)
            XCTAssertEqual(b.width, 720)
            XCTAssertEqual(a.values, b.values, "frame \(frame)")
        }
        // With the Tape on, the files name no tape, and switching it off moves the fingerprint.
        XCTAssertFalse(staged.vhs!.savedLayers.contains { $0.id == "tape" })
        let before = ChainFingerprint.of(staged)
        staged.vhs!.tape.enabled = false
        XCTAssertNotEqual(ChainFingerprint.of(staged), before)
        XCTAssertTrue(staged.vhs!.savedLayers.contains { $0.id == "tape" })
    }

    // MARK: Files and settings

    /// An older sidecar, Film on with its output Scan, loads as Tape off. Output
    /// Tape loads with the Tape on, and Scan with the Film off changes nothing.
    func testAnOldFilmScanSidecarLoadsAsTapeOff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func oldSidecar(filmOn: Bool, output: String) throws -> URL {
            let a = SignalChain.standard()
            a.vhs!.film.source.enabled = filmOn
            a.vhs!.film.stock.setParameter("stock", to: .choice(FilmStock.ektachrome160.rawValue))
            let url = folder.appendingPathComponent("\(filmOn)-\(output).mov.homevideo.json")
            try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, to: url)
            // Put the output row back in the Film record, as an older file has it.
            var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
            XCTAssertFalse(layers.contains { $0["id"] as? String == "tape" }, "a file with the Tape on names no tape")
            let i = try XCTUnwrap(layers.firstIndex { $0["id"] as? String == "film" })
            var params = try XCTUnwrap(layers[i]["parameters"] as? [[String: Any]])
            params.insert(["id": "output", "value": output], at: 0)
            layers[i]["parameters"] = params
            root["layers"] = layers
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            return url
        }
        let scan = SignalChain.standard()
        try Sidecar.read(try oldSidecar(filmOn: true, output: "scan"), into: scan)
        XCTAssertTrue(scan.vhs!.film.isOn)
        XCTAssertFalse(scan.vhs!.tape.enabled, "Film output Scan loads as Tape off")
        XCTAssertEqual(scan.output, .scan)
        XCTAssertEqual(scan.vhs!.film.stockChoice, .ektachrome160)

        let tape = SignalChain.standard()
        try Sidecar.read(try oldSidecar(filmOn: true, output: "tape"), into: tape)
        XCTAssertTrue(tape.vhs!.film.isOn)
        XCTAssertTrue(tape.vhs!.tape.enabled, "Film output Tape goes onto the tape")

        let off = SignalChain.standard()
        try Sidecar.read(try oldSidecar(filmOn: false, output: "scan"), into: off)
        XCTAssertFalse(off.vhs!.film.isOn)
        XCTAssertTrue(off.vhs!.tape.enabled, "with the Film off the old choice did nothing")

        // A file written with the Tape off reads back with it off.
        let a = SignalChain.standard()
        a.vhs!.tape.enabled = false
        let url = folder.appendingPathComponent("tape-off.mov.homevideo.json")
        try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, to: url)
        let b = SignalChain.standard()
        try Sidecar.read(url, into: b)
        XCTAssertFalse(b.vhs!.tape.enabled)
    }

    /// `--set tape=off` and `--set tape.enabled=off` reach the switch, and the old
    /// `--set film.output=scan` folds into it.
    func testSetReachesTheTapeSwitch() throws {
        for set in ["tape=off", "tape.enabled=off"] {
            let c = SignalChain.standard()
            try RenderArguments.parse(["in.mov", "out.mov", "--set", set]).apply(to: c)
            XCTAssertFalse(c.vhs!.tape.enabled, set)
            XCTAssertEqual(c.output, .source, set)
        }
        let c = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--set", "film=on", "--set", "film.output=scan"]).apply(to: c)
        XCTAssertTrue(c.vhs!.film.isOn)
        XCTAssertFalse(c.vhs!.tape.enabled)
        XCTAssertEqual(c.output, .scan)
        XCTAssertThrowsError(try RenderArguments.parse(["in.mov", "out.mov", "--set", "luma=off"]),
                             "a short form is for the stage switches only")
    }

    /// The film Looks are scans (Tape off), 8mm to Tape goes through the Telecine onto the tape,
    /// and every other Look has the Tape on. Choosing a tape Look after a film Look turns it back on.
    func testTheLooksSetTheTape() {
        let chain = SignalChain.standard()
        let p = Presets(vhs: chain.vhs!, audio: chain.audio)
        for look in Looks.all {
            p.setLook(Looks.look(id: "super8-kodachrome")!)
            p.setLook(look)
            // Every film Look is a scan, and so is Pro Scan, straight off the scanner.
            let scan = look.category == .film || look.id == "pro-scan"
            XCTAssertEqual(chain.vhs!.tape.enabled, !scan, look.id)
            XCTAssertEqual(p.look?.id, look.id, "\(look.id) reads back")
        }
        p.setLook(Looks.look(id: "home-movie-transfer")!)
        XCTAssertTrue(chain.vhs!.telecineInUse)
        XCTAssertTrue(chain.vhs!.tape.enabled)
        chain.vhs!.tape.enabled = false
        XCTAssertNil(p.look, "the Tape switched off reads Custom")
    }
}
