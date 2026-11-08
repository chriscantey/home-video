import AVFoundation
import Metal
import XCTest
@testable import HomeVideoCore

/// The Film source. Film off is the chain without it byte for byte, each layer alone changes the picture,
/// dust follows the stock's polarity, the defaults are docs/FILM.md's, a seed repeats, Scan
/// writes 1440 by 1080, the Shutter holds 18 fps, and sidecars and presets keep the section.
@MainActor
final class FilmTests: XCTestCase {
    // MARK: Helpers

    /// Edges, a white patch for halation and a gray ramp, on the 720 by 480 harness source.
    func pattern(_ g: GPUHarness) throws -> MTLTexture {
        try g.source { x, y in
            if x > 300 && x < 420 && y > 180 && y < 300 { return (255, 255, 255) }
            let v = UInt8(40 + (x * 180) / 720)
            return (x / 24) % 2 == 0 ? (v, v / 2, 60) : (60, v, v)
        }
    }

    /// The standard chain with full raster framing, and its Film.
    func standardChain() -> (SignalChain, FilmLayers) {
        let chain = SignalChain.standard()
        chain.framing.mode = .fullRaster
        return (chain, chain.vhs!.film)
    }

    /// Runs the chain on one frame and returns the picture's size and raw half float bits.
    func render(_ g: GPUHarness, _ chain: SignalChain, _ src: MTLTexture, frame: UInt64, fps: Double = 30)
        throws -> (width: Int, height: Int, bits: [UInt16]) {
        let cb = try XCTUnwrap(g.queue.makeCommandBuffer())
        let ctx = FrameContext(frameIndex: frame, time: Double(frame) / fps,
                               sourceSize: CGSize(width: GPUHarness.w, height: GPUHarness.h), rasterSize: .zero)
        let out = try chain.encode(commandBuffer: cb, source: src, frame: ctx, device: g.device, library: g.library)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: out.width,
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
        var bits = [UInt16](repeating: 0, count: out.width * out.height * 4)
        readable.getBytes(&bits, bytesPerRow: out.width * 8, from: MTLRegionMake2D(0, 0, out.width, out.height),
                          mipmapLevel: 0)
        return (out.width, out.height, bits)
    }

    /// Film on, every Film layer off but the master, the Tape off: the plain scan.
    func bareFilm(_ chain: SignalChain) {
        let film = chain.vhs!.film
        film.source.enabled = true
        chain.vhs!.tape.enabled = false
        for l in film.all.dropFirst() { l.enabled = false }
    }

    /// The layers every file writes with Film unused: the VHS layers, then the Display and Re-capture's.
    func unusedFileLayers(_ vhs: VHSLayers) -> Int { vhs.all.count + vhs.crt.all.count + vhs.recapture.all.count }

    // MARK: Film off

    /// With Film unused (and even with its values moved but its switch off) the chain writes
    /// exactly what a chain without the Film plumbing writes.
    func testFilmOffIsThePlainChainByteForByte() throws {
        let g = try GPUHarness()
        let src = try pattern(g)
        let vhs = VHSLayers()
        let main = SignalChain(framing: FramingLayer(mode: .fullRaster), effects: vhs.all)
        XCTAssertNil(main.vhs, "no Film plumbing at all")
        let (chain, film) = standardChain()
        XCTAssertFalse(film.isOn)
        XCTAssertTrue(film.isAtDefault)
        for frame: UInt64 in [0, 7] {
            let a = try g.run(main, src, frame: frame, raw: true).1
            let b = try render(g, chain, src, frame: frame)
            XCTAssertEqual(b.width, 720)
            XCTAssertEqual(a, b.bits, "frame \(frame)")
        }
        film.stock.setParameter("stock", to: .choice(FilmStock.vision500T.rawValue))
        film.damage.enabled = true
        film.source.setParameter("scan", to: .choice("2880"))
        XCTAssertEqual(try g.run(main, src, frame: 3, raw: true).1, try render(g, chain, src, frame: 3).bits,
                       "values moved, switch off")
        XCTAssertEqual(chain.outputSize.width, 720)
    }

    /// The fingerprint, the sidecar layer list and the Look read back are unchanged while Film is unused.
    func testFilmUnusedLeavesFingerprintAndFilesAlone() {
        let chain = SignalChain.standard()
        let before = ChainFingerprint.of(chain)
        XCTAssertEqual(chain.vhs!.savedLayers.count, unusedFileLayers(chain.vhs!))
        chain.vhs!.film.grain.setParameter("seed", to: .float(5))
        XCTAssertEqual(ChainFingerprint.of(chain), before, "Film values do not count while it is off")
        XCTAssertEqual(chain.vhs!.savedLayers.count, unusedFileLayers(chain.vhs!) + 12, "moved Film is saved")
        chain.vhs!.film.source.enabled = true
        XCTAssertNotEqual(ChainFingerprint.of(chain), before)
        XCTAssertEqual(Presets(vhs: VHSLayers()).look?.id, "clean-sp")
    }

    /// Exactly the Looks in `Looks.film` turn Film on, and every Look reads back.
    func testOnlyTheFilmLooksTurnFilmOn() {
        let vhs = VHSLayers(), audio = AudioChain()
        let p = Presets(vhs: vhs, audio: audio)
        for look in Looks.all {
            p.setLook(Looks.look(id: "sixteen-ektachrome-faded")!)
            p.setLook(look)
            XCTAssertEqual(vhs.film.isOn, Looks.film.contains(look.id), look.id)
            XCTAssertEqual(p.look?.id, look.id, "\(look.id) reads back")
        }
        p.setLook(Looks.look(id: "sixteen-ektachrome-faded")!)
        XCTAssertEqual(vhs.film.formatChoice, .sixteen)
        XCTAssertEqual(vhs.film.stockChoice, .ektachrome160)
        XCTAssertEqual(vhs.film.fade.float("years"), 35)
        vhs.film.grain.setParameter("strength", to: .float(0.9))
        XCTAssertNil(p.look, "a Film slider moved reads Custom")
    }

    // MARK: Layers

    /// Each layer alone, on the plain scan, changes the picture.
    func testEachLayerAloneChangesThePicture() throws {
        let g = try GPUHarness()
        let src = try pattern(g)
        let (chain, film) = standardChain()
        bareFilm(chain)
        film.fade.setParameter("years", to: .float(20))
        film.damage.setParameter("fog", to: .float(0.6))
        film.damage.setParameter("frameLine", to: .float(0.5))
        let plain = try render(g, chain, src, frame: 5)
        XCTAssertEqual(plain.width, 1440)
        for layer in film.all.dropFirst() {
            chain.reset()
            layer.enabled = true
            let out = try render(g, chain, src, frame: 5)
            XCTAssertNotEqual(out.bits, plain.bits, "\(layer.id) alone changes the picture")
            layer.enabled = false
        }
    }

    /// Dust blocks light: a dark speck on a reversal original, a light one on a negative's scan.
    func testDustPolarityFollowsTheStock() throws {
        let g = try GPUHarness()
        let src = try g.source { _, _ in (128, 128, 128) }
        for stock in [FilmStock.kodachrome40, .vision50D] {
            let (chain, film) = standardChain()
            bareFilm(chain)
            film.stock.setParameter("stock", to: .choice(stock.rawValue))
            film.damage.enabled = true
            for (id, v) in [("dust", 1.0), ("hair", 0), ("scratches", 0), ("splices", 0)] {
                film.damage.setParameter(id, to: .float(v))
            }
            var found = false
            for frame: UInt64 in 0..<8 {
                chain.reset()
                let out = try render(g, chain, src, frame: frame)
                let gray = halfTable[Int(out.bits[0])]
                let values = stride(from: 0, to: out.bits.count, by: 4).map { halfTable[Int(out.bits[$0])] }
                let lo = values.min()!, hi = values.max()!
                guard hi - lo > 0.2 else { continue }
                found = true
                if stock.isNegative {
                    XCTAssertGreaterThan(hi, gray + 0.2, "a light speck on \(stock.label)")
                    XCTAssertGreaterThan(lo, gray - 0.02, "nothing dark on \(stock.label)")
                } else {
                    XCTAssertLessThan(lo, gray - 0.2, "a dark speck on \(stock.label)")
                    XCTAssertLessThan(hi, gray + 0.02, "nothing light on \(stock.label)")
                }
                break
            }
            XCTAssertTrue(found, "dust landed on \(stock.label) within 8 frames")
        }
    }

    /// Two renders with one seed are byte identical, and another grain seed is another take.
    func testOneSeedRepeatsExactly() throws {
        let g = try GPUHarness()
        let src = try pattern(g)
        func take(_ seed: Double) throws -> [UInt16] {
            let (chain, film) = standardChain()
            film.source.enabled = true
            chain.vhs!.tape.enabled = false
            film.damage.enabled = true
            film.grain.setParameter("seed", to: .float(seed))
            film.damage.setParameter("seed", to: .float(seed))
            return try render(g, chain, src, frame: 9).bits
        }
        let a = try take(3), b = try take(3)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, try take(4))
    }

    /// The Shutter layer holds frames to 18 fps: one second of a 30 fps source shows 18 pictures.
    func testShutterHoldsEighteenFramesASecond() throws {
        let g = try GPUHarness()
        let (chain, film) = standardChain()
        bareFilm(chain)
        film.shutter.enabled = true
        film.shutter.setParameter("flicker", to: .float(0))
        var distinct = 0
        var last: [UInt16] = []
        for frame: UInt64 in 0..<30 {
            // A different source picture every frame, so only a hold repeats one.
            let v = UInt8(frame * 8)
            let src = try g.source { _, _ in (v, v, v) }
            let out = try render(g, chain, src, frame: frame).bits
            if out != last { distinct += 1 }
            last = out
        }
        XCTAssertEqual(distinct, 18)
        XCTAssertEqual(film.filmFrame(time: 29.0 / 30, frameIndex: 29), 17)
        film.shutter.setParameter("fps", to: .choice("24"))
        XCTAssertEqual(film.filmFrame(time: 29.0 / 30, frameIndex: 29), 23)
    }

    /// Tape on (the default): the film picture goes on through the VHS chain at the
    /// raster, without the Camera.
    func testTapeRunsTheChainAtTheRaster() throws {
        let g = try GPUHarness()
        let src = try pattern(g)
        let (chain, film) = standardChain()
        film.source.enabled = true
        XCTAssertTrue(chain.vhs!.tape.enabled)
        chain.vhs!.camera.enabled = true
        let out = try render(g, chain, src, frame: 2)
        XCTAssertEqual(out.width, 720)
        XCTAssertEqual(out.height, 480)
        chain.vhs!.camera.enabled = false
        chain.reset()
        XCTAssertEqual(try render(g, chain, src, frame: 2).bits, out.bits, "the Camera does not run under Film")
        film.source.enabled = false
        chain.reset()
        XCTAssertNotEqual(try render(g, chain, src, frame: 2).bits, out.bits)
    }

    // MARK: Defaults

    /// Every Film parameter's default and range is the row in docs/FILM.md.
    func testDefaultsAndRangesMatchTheDoc() throws {
        let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/FILM.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        var rows: [String: [String]] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| film") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5 else { continue }
            rows["\(cells[0]).\(cells[1])"] = cells
        }
        let film = FilmLayers()
        var checked = 0
        for layer in film.all {
            let sw = try XCTUnwrap(rows["\(layer.id).enabled"], "\(layer.id).enabled in the doc")
            XCTAssertEqual(sw[2], layer.enabled ? "on" : "off", "\(layer.id) switch")
            for p in layer.parameters {
                let row = try XCTUnwrap(rows["\(layer.id).\(p.id)"], "\(layer.id).\(p.id) in the doc")
                switch p.value {
                case .float(let v):
                    XCTAssertEqual(Double(row[2]) ?? .nan, v, accuracy: 1e-9, "\(layer.id).\(p.id) default")
                    let r = row[3].components(separatedBy: " to ")
                    XCTAssertEqual(r.count, 2, "\(layer.id).\(p.id) range")
                    XCTAssertEqual(Double(r.first ?? "") ?? .nan, p.range.lowerBound, "\(layer.id).\(p.id) low")
                    XCTAssertEqual(Double(r.last ?? "") ?? .nan, p.range.upperBound, "\(layer.id).\(p.id) high")
                case .choice(let c):
                    XCTAssertEqual(row[2], c, "\(layer.id).\(p.id) default")
                    XCTAssertEqual(row[3], p.options.map(\.value).joined(separator: ", "), "\(layer.id).\(p.id) options")
                case .bool:
                    XCTFail("no bool parameters in Film")
                }
                XCTAssertTrue(["READ", "INFERRED"].contains(row[4]), "\(layer.id).\(p.id) READ or INFERRED")
                checked += 1
            }
        }
        // 33 on `film`, less the output choice folded into the Tape switch.
        XCTAssertEqual(checked, 32)
        // The doc's damage stays off by default, and Film itself.
        XCTAssertFalse(film.damage.enabled)
        XCTAssertFalse(film.source.enabled)
    }

    // MARK: Files

    /// A sidecar and a saved preset keep the Film section, and a file without one turns Film off.
    func testSidecarAndPresetRoundTripTheFilmSection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("film-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func set(_ chain: SignalChain) {
            let film = chain.vhs!.film
            film.source.enabled = true
            film.format.setParameter("format", to: .choice(FilmFormat.regular8.rawValue))
            film.stock.setParameter("stock", to: .choice(FilmStock.fujiR25N.rawValue))
            film.tone.setParameter("contrast", to: .float(2.1))
            film.halation.enabled = false
            film.damage.enabled = true
            film.damage.setParameter("seed", to: .float(42))
        }
        func check(_ chain: SignalChain, _ what: String) {
            let film = chain.vhs!.film
            XCTAssertTrue(film.isOn, what)
            XCTAssertTrue(chain.vhs!.tape.enabled, "onto the tape, \(what)")
            XCTAssertEqual(film.formatChoice, .regular8, what)
            XCTAssertEqual(film.stockChoice, .fujiR25N, what)
            XCTAssertEqual(film.stock.float("saturation"), FilmStock.fujiR25N.saturation, what)
            XCTAssertEqual(film.tone.float("contrast"), 2.1, what)
            XCTAssertFalse(film.halation.enabled, what)
            XCTAssertTrue(film.damage.enabled, what)
            XCTAssertEqual(film.damage.float("seed"), 42, what)
        }
        let a = SignalChain.standard()
        set(a)
        let side = folder.appendingPathComponent("clip.mov.homevideo.json")
        try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, to: side)
        let b = SignalChain.standard()
        try Sidecar.read(side, into: b)
        check(b, "sidecar")

        let store = UserPresets(folder: folder.appendingPathComponent("presets"))
        let saved = try store.save(name: "Film test", chain: a)
        let c = SignalChain.standard()
        Presets(vhs: c.vhs!, audio: c.audio).setLook(saved.look)
        check(c, "preset")

        // A sidecar written with Film unused carries no Film records, and reading it puts Film off.
        let plain = folder.appendingPathComponent("plain.mov.homevideo.json")
        try Sidecar.write(chain: SignalChain.standard(), name: "plain.mov", lookID: "clean-sp", to: plain)
        let text = try String(contentsOf: plain, encoding: .utf8)
        XCTAssertFalse(text.contains("film"), "no Film records while unused")
        try Sidecar.read(plain, into: b)
        XCTAssertFalse(b.vhs!.film.isOn)
        XCTAssertTrue(b.vhs!.film.isAtDefault)
    }

    /// Scan (Film on, Tape off) writes 1440 by 1080 square pixels, the frames held.
    func testScanWrites1440x1080() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("film-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let src = folder.appendingPathComponent("src.mov"), out = folder.appendingPathComponent("scan.mov")
        try await ClipListTests.writeMovie(to: src, width: 640, height: 480, frames: 12)
        let chain = SignalChain.standard()
        chain.vhs!.film.source.enabled = true
        XCTAssertEqual(chain.outputSize.width, 720, "onto the tape with it on")
        chain.vhs!.tape.enabled = false
        XCTAssertEqual(chain.output, .scan)
        XCTAssertEqual(chain.outputSize.width, 1440)
        let result = try await Exporter(source: src, destination: out, chain: chain, settings: .master).run()
        XCTAssertEqual(result.framesWritten, 12)
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 1440)
        XCTAssertEqual(size.height, 1080)
    }

    /// The Scan detail is how fine the film is scanned, never the file's size: at Auto
    /// every detail writes the Standard scan's 1440 by 1080 through the real exporter, and the
    /// picture differs between them.
    func testEveryScanDetailWritesTheSameAutoSize() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("film-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let src = folder.appendingPathComponent("src.mov")
        try await ClipListTests.writeMovie(to: src, width: 640, height: 480, frames: 6)
        let details = FilmLayers().source.parameters.first { $0.id == "scan" }!.options
        XCTAssertEqual(details.map(\.label), ["Standard", "Fine"])
        var pictures: [Data] = []
        for detail in details {
            let chain = SignalChain.standard()
            chain.vhs!.film.source.enabled = true
            chain.vhs!.tape.enabled = false
            chain.vhs!.film.source.setParameter("scan", to: .choice(detail.value))
            XCTAssertTrue(chain.outputSize == (1440, 1080), detail.label)
            let out = folder.appendingPathComponent("scan-\(detail.value).mov")
            let result = try await Exporter(source: src, destination: out, chain: chain, settings: .master).run()
            XCTAssertEqual(result.framesWritten, 6, detail.label)
            let asset = AVURLAsset(url: out)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(size.width, 1440, detail.label)
            XCTAssertEqual(size.height, 1080, detail.label)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            // Frame 4, mid gray (the fixture's frame 0 is black, where the grain has nothing to show).
            for _ in 0..<4 { _ = output.copyNextSampleBuffer() }
            let sample = try XCTUnwrap(output.copyNextSampleBuffer())
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            pictures.append(Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                                 count: CVPixelBufferGetDataSize(buffer)))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            reader.cancelReading()
        }
        XCTAssertNotEqual(pictures[0], pictures[1], "the Scan detail reaches the picture")
    }
}
