import Metal
import XCTest
@testable import HomeVideoCore

/// Every Film built-in against every Telecine built-in, Off included, the Tape on and off,
/// as the stage menus apply them and `encodeOutput` draws them (the app's and the exporter's
/// path). Each pairing gives finite values, a picture that is not one solid color, black or
/// blown, the picture where the same Film with the Telecine off puts it at about its size, and
/// no flashing: the two fields of a frame and consecutive frames stay within a few percent.
@MainActor
final class StagePairSweepTests: XCTestCase {
    static let sourceW = 320, sourceH = 240
    static let frames = 3

    /// A dark ramp with a white square in the middle, 320 by 240, so the square says where the
    /// picture sits and how big it is.
    func source(_ g: GPUHarness) throws -> MTLTexture {
        let w = Self.sourceW, h = Self.sourceH
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        let t = try XCTUnwrap(g.device.makeTexture(descriptor: d))
        var b = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let square = abs(x - w / 2) < 40 && abs(y - h / 2) < 40
                let v = square ? 255 : UInt8(20 + (x * 50) / w + (y / 8) % 2 * 10)
                b[i] = v; b[i + 1] = v; b[i + 2] = v
            }
        }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: b, bytesPerRow: w * 4)
        return t
    }

    /// What one frame of a pairing reads.
    struct Reading {
        var finite = true
        var mean = 0.0, spread = 0.0
        /// The two fields' means over the middle of the picture, odd rows and even rows.
        var odd = 0.0, even = 0.0
        /// The bright square's center and size, as shares of the picture.
        var center = SIMD2<Double>(0, 0), size = SIMD2<Double>(0, 0)
    }

    func read(_ g: GPUHarness, _ chain: SignalChain, _ src: MTLTexture, frame: UInt64) throws -> Reading {
        let cb = try XCTUnwrap(g.queue.makeCommandBuffer())
        let ctx = FrameContext(frameIndex: frame, time: Double(frame) / 29.97,
                               sourceSize: CGSize(width: src.width, height: src.height), rasterSize: .zero)
        let out = try chain.encodeOutput(commandBuffer: cb, source: src, frame: ctx, device: g.device, library: g.library)
        XCTAssertEqual(out.pixelFormat, .rgba16Float)
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
        let w = out.width, h = out.height
        var bits = [UInt16](repeating: 0, count: w * h * 4)
        readable.getBytes(&bits, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let table = halfTable
        var y = [Double](repeating: 0, count: w * h)
        var r = Reading()
        for i in 0..<(w * h) {
            let c = (Double(table[Int(bits[4 * i])]), Double(table[Int(bits[4 * i + 1])]), Double(table[Int(bits[4 * i + 2])]))
            if !c.0.isFinite || !c.1.isFinite || !c.2.isFinite { r.finite = false; return r }
            y[i] = 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
        }
        r.mean = y.reduce(0, +) / Double(y.count)
        r.spread = sqrt(y.reduce(0) { $0 + ($1 - r.mean) * ($1 - r.mean) } / Double(y.count))
        var odd = 0.0, even = 0.0, n = 0.0
        for row in (h / 4)..<(3 * h / 4) {
            var s = 0.0
            for x in (w / 4)..<(3 * w / 4) { s += y[row * w + x] }
            if row % 2 == 0 { even += s } else { odd += s }
            n += Double(w / 2)
        }
        r.odd = odd / (n / 2); r.even = even / (n / 2)
        // The square: every block of 8 by 8 within a third of the way down from the brightest
        // block, the blocks so the grain does not count.
        let bw = w / 8, bh = h / 8
        var blocks = [Double](repeating: 0, count: bw * bh)
        for by in 0..<bh {
            for bx in 0..<bw {
                var s = 0.0
                for row in (by * 8)..<(by * 8 + 8) { for x in (bx * 8)..<(bx * 8 + 8) { s += y[row * w + x] } }
                blocks[by * bw + bx] = s / 64
            }
        }
        let top = blocks.max()!
        let cut = top - (top - r.mean) / 3
        var sx = 0.0, sy = 0.0, count = 0.0
        var lo = SIMD2<Double>(1, 1), hi = SIMD2<Double>(0, 0)
        for by in 0..<bh {
            for bx in 0..<bw where blocks[by * bw + bx] > cut {
                let p = SIMD2((Double(bx) + 0.5) / Double(bw), (Double(by) + 0.5) / Double(bh))
                sx += p.x; sy += p.y; count += 1
                lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p)
            }
        }
        if count > 0 { r.center = SIMD2(sx / count, sy / count); r.size = hi - lo }
        return r
    }

    /// The pairing on a fresh chain, as the menus set it: the Film's preset, then the Telecine's.
    func chain(film: StagePreset, telecine: StagePreset, tape: Bool) -> SignalChain {
        let chain = SignalChain.standard()
        let vhs = chain.vhs!
        Stage.film.apply(film.snapshot, vhs: vhs, audio: chain.audio)
        Stage.telecine.apply(telecine.snapshot, vhs: vhs, audio: chain.audio)
        vhs.tape.enabled = tape
        return chain
    }

    func testEveryFilmUnderEveryTelecineDrawsWhole() throws {
        let g = try GPUHarness()
        let src = try source(g)
        let films = StagePresets.builtIns(.film), telecines = StagePresets.builtIns(.telecine)
        XCTAssertGreaterThanOrEqual(films.count, 10)
        XCTAssertEqual(telecines.map(\.name), ["Off", "Mall transfer", "Mid-grade", "Pro telecine"])
        for tape in [true, false] {
            for film in films {
                var reference: Reading?
                for telecine in telecines {
                    let what = "Film \(film.name), Telecine \(telecine.name), Tape \(tape ? "on" : "off")"
                    let chain = chain(film: film, telecine: telecine, tape: tape)
                    let interlaced = chain.vhs!.telecineInUse
                    var readings: [Reading] = []
                    for f in 0..<UInt64(Self.frames) {
                        let r = try read(g, chain, src, frame: f)
                        XCTAssertTrue(r.finite, "\(what), frame \(f): NaN or infinity")
                        guard r.finite else { break }
                        XCTAssertGreaterThan(r.spread, 0.03, "\(what), frame \(f): one solid color")
                        XCTAssertGreaterThan(r.mean, 0.03, "\(what), frame \(f): black")
                        XCTAssertLessThan(r.mean, 0.95, "\(what), frame \(f): blown")
                        if interlaced {
                            XCTAssertLessThan(abs(r.odd - r.even) / max(r.odd + r.even, 1e-3) * 2, 0.08,
                                              "\(what), frame \(f): the fields flash against each other")
                        }
                        readings.append(r)
                    }
                    guard readings.count == Self.frames else { continue }
                    for (a, b) in zip(readings, readings.dropFirst()) {
                        XCTAssertLessThan(abs(b.mean - a.mean) / max(a.mean, 1e-3), 0.1, "\(what): a frame flashes")
                    }
                    let r = readings[Self.frames - 1]
                    if telecine.name == "Off" {
                        reference = r
                        continue
                    }
                    // With the Film off the Telecine transfers the clip itself, against the clip
                    // with the Telecine off.
                    guard let reference else { continue }
                    let moved = max(abs(r.center.x - reference.center.x), abs(r.center.y - reference.center.y))
                    XCTAssertLessThan(moved, 0.06, "\(what): the picture moved \(moved) against the Telecine off, "
                                      + "center \(r.center) against \(reference.center), size \(r.size) against \(reference.size)")
                    for k in 0..<2 where reference.size[k] > 0 {
                        let ratio = r.size[k] / reference.size[k]
                        XCTAssertTrue((0.75...1.35).contains(ratio),
                                      "\(what): the picture's size went \(ratio) of the Telecine off's on axis \(k)")
                    }
                }
            }
        }
    }

    /// `homevideo-render --stage` names a built-in by its menu name, and a wrong name is an error.
    func testRenderArgumentsStagePicksABuiltIn() throws {
        let args = try RenderArguments.parse(["in.mov", "out.mov", "--stage", "film=Summer Reel",
                                              "--stage", "telecine=Mid-grade"])
        XCTAssertEqual(args.stages.map(\.name), ["Summer Reel", "Mid-grade"])
        let chain = SignalChain.standard()
        try args.apply(to: chain)
        XCTAssertTrue(chain.vhs!.telecineInUse)
        XCTAssertEqual(chain.vhs!.telecine.quality, .mid)
        XCTAssertEqual(chain.vhs!.film.format.choice("format"), FilmFormat.regular8.rawValue)
        let bad = try RenderArguments.parse(["in.mov", "out.mov", "--stage", "telecine=Nope"])
        XCTAssertThrowsError(try bad.apply(to: SignalChain.standard()))
        XCTAssertThrowsError(try RenderArguments.parse(["in.mov", "out.mov", "--stage", "audio=Linear"]))
    }
}
