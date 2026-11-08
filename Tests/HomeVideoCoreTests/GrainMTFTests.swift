import Accelerate
import Metal
import XCTest
@testable import HomeVideoCore

/// The grain under the scan's MTF, as 8 measured public domain film scans show it: the grain
/// goes through the scan and not the lens, so a flat gray scan's grain is about twice as fine as an
/// edge in the
/// same scan and never finer than the scan. The probe: render a flat 50 percent gray and a
/// sharp low contrast vertical edge through each scan Look, take the grain's radial amplitude
/// spectrum (the frame minus its mean) and the picture's MTF (the edge spread function, its
/// derivative, its spectrum), and find where each falls to half (-6 dB).
@MainActor
final class GrainMTFTests: XCTestCase {
    static let w = 1440, h = 1080

    /// A 1440 by 1080 source, so Framing maps it 1:1 onto the Standard scan: a 720 by 480 edge
    /// would arrive already softened by the upscale, a softness of the clip and not of the film.
    func source(_ device: MTLDevice, _ pixel: (Int) -> UInt8) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.w, height: Self.h,
                                                         mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        let t = try XCTUnwrap(device.makeTexture(descriptor: d))
        var bytes = [UInt8](repeating: 255, count: Self.w * Self.h * 4)
        for y in 0..<Self.h {
            for x in 0..<Self.w {
                let v = pixel(x), i = (y * Self.w + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        t.replace(region: MTLRegionMake2D(0, 0, Self.w, Self.h), mipmapLevel: 0, withBytes: bytes,
                  bytesPerRow: Self.w * 4)
        return t
    }

    /// The scan's luminance (Rec. 709 weights on the display values), row major, or one
    /// channel's values.
    func render(_ g: GPUHarness, _ chain: SignalChain, _ src: MTLTexture, channel: Int? = nil) throws -> [Double] {
        let cb = try XCTUnwrap(g.queue.makeCommandBuffer())
        let ctx = FrameContext(frameIndex: 3, time: 0.1, sourceSize: CGSize(width: Self.w, height: Self.h),
                               rasterSize: .zero)
        let out = try chain.encode(commandBuffer: cb, source: src, frame: ctx, device: g.device, library: g.library)
        XCTAssertEqual(out.width, Self.w)
        XCTAssertEqual(out.height, Self.h)
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
        let t = halfTable
        if let channel { return (0..<(out.width * out.height)).map { Double(t[Int(bits[$0 * 4 + channel])]) } }
        return (0..<(out.width * out.height)).map { (i: Int) -> Double in
            let r: Double = 0.2126 * Double(t[Int(bits[i * 4])])
            let g: Double = 0.7152 * Double(t[Int(bits[i * 4 + 1])])
            let b: Double = 0.0722 * Double(t[Int(bits[i * 4 + 2])])
            return r + g + b
        }
    }

    /// The chain for a Look as a scan, Damage off (dust is not grain) and Framing 1:1.
    func chain(_ look: Look, grain: Bool) -> SignalChain {
        let chain = SignalChain.standard()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(look)
        chain.framing.mode = .fullRaster
        chain.vhs!.film.damage.enabled = false
        chain.vhs!.film.grain.enabled = grain
        return chain
    }

    /// Where an amplitude curve sampled at `f` first falls to `level`, linearly interpolated,
    /// searched above `from`. Infinity when it never does below Nyquist.
    static func radius(_ f: [Double], _ a: [Double], level: Double = 0.5, from: Double = 0.02) -> Double {
        for k in 1..<a.count where f[k] > from && a[k] <= level {
            let t = (a[k - 1] - level) / max(a[k - 1] - a[k], 1e-12)
            return f[k - 1] + t * (f[k] - f[k - 1])
        }
        return .infinity
    }

    /// The grain's radial amplitude spectrum: a 1024 square from the middle of the frame less
    /// its mean, its 2D power spectrum averaged in rings 1/256 cycle per px wide, the square
    /// root of each ring over the rings from 0.01 to 0.03 cycles per px.
    static func grainSpectrum(_ y: [Double], width: Int, height: Int) -> (f: [Double], a: [Double]) {
        let n = 1024, log2n = vDSP_Length(10)
        let x0 = (width - n) / 2, y0 = (height - n) / 2
        var re = [Double](repeating: 0, count: n * n), im = [Double](repeating: 0, count: n * n)
        var mean = 0.0
        for j in 0..<n { for i in 0..<n { mean += y[(y0 + j) * width + x0 + i] } }
        mean /= Double(n * n)
        for j in 0..<n { for i in 0..<n { re[j * n + i] = y[(y0 + j) * width + x0 + i] - mean } }
        let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetupD(setup) }
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { m in
                var s = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                vDSP_fft2d_zipD(setup, &s, 1, 0, log2n, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        let bins = 128
        var sum = [Double](repeating: 0, count: bins), count = [Double](repeating: 0, count: bins)
        for j in 0..<n {
            let fy = Double(j < n / 2 ? j : j - n) / Double(n)
            for i in 0..<n {
                let fx = Double(i < n / 2 ? i : i - n) / Double(n)
                let r = (fx * fx + fy * fy).squareRoot()
                let b = Int(r * 256)
                guard b < bins, r > 0 else { continue }
                sum[b] += re[j * n + i] * re[j * n + i] + im[j * n + i] * im[j * n + i]
                count[b] += 1
            }
        }
        let f = (0..<bins).map { (Double($0) + 0.5) / 256 }
        let p = (0..<bins).map { count[$0] > 0 ? sum[$0] / count[$0] : 0 }
        let ref = zip(f, p).filter { $0.0 >= 0.01 && $0.0 <= 0.03 }.map(\.1)
        let r = ref.reduce(0, +) / Double(ref.count)
        return (f, p.map { ($0 / r).squareRoot() })
    }

    /// The picture's MTF across a vertical edge: the rows averaged (the edge spread function),
    /// its derivative over 128 px each side under a Hann window, the magnitude of its spectrum
    /// at 1/512 cycle per px steps over its value at 0.
    static func edgeMTF(_ y: [Double], width: Int, height: Int, edge: Int) -> (f: [Double], a: [Double]) {
        var esf = [Double](repeating: 0, count: width)
        let rows = (height / 4)..<(3 * height / 4)
        for j in rows { for i in 0..<width { esf[i] += y[j * width + i] } }
        let half = 128
        let lsf = (0..<(2 * half)).map { k -> Double in
            let i = edge - half + k
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * (Double(k) + 0.5) / Double(2 * half))
            return (esf[i + 1] - esf[i]) * hann
        }
        let f = (0...256).map { Double($0) / 512 }
        let m = f.map { fr -> Double in
            var c = 0.0, s = 0.0
            for (k, v) in lsf.enumerated() {
                c += v * cos(2 * Double.pi * fr * Double(k))
                s += v * sin(2 * Double.pi * fr * Double(k))
            }
            return (c * c + s * s).squareRoot()
        }
        return (f, m.map { $0 / m[0] })
    }

    /// The RMS of the frame over the middle 1024 square, clear of the gate's edges the weave
    /// reveals.
    static func rms(_ y: [Double], width: Int, height: Int) -> Double {
        let n = 1024, x0 = (width - n) / 2, y0 = (height - n) / 2
        var s = 0.0, s2 = 0.0
        for j in 0..<n { for i in 0..<n { let v = y[(y0 + j) * width + x0 + i]; s += v; s2 += v * v } }
        let m = s / Double(n * n)
        return (s2 / Double(n * n) - m * m).squareRoot()
    }

    /// The two -6 dB radii for one Look, in cycles per px of the scan, and the grain's RMS.
    func radii(_ g: GPUHarness, _ look: Look) throws -> (grain: Double, picture: Double, rms: Double) {
        let edge = Self.w / 2
        let gray = try source(g.device) { _ in 128 }
        let step = try source(g.device) { $0 < edge ? 89 : 166 }
        let flat = try render(g, chain(look, grain: true), gray)
        let spec = Self.grainSpectrum(flat, width: Self.w, height: Self.h)
        let rms = Self.rms(flat, width: Self.w, height: Self.h)
        let pic = try render(g, chain(look, grain: false), step)
        let mtf = Self.edgeMTF(pic, width: Self.w, height: Self.h, edge: edge)
        return (Self.radius(spec.f, spec.a), Self.radius(mtf.f, mtf.a), rms)
    }

    /// Where a whole px kernel's amplitude response first falls to half, in cycles per px, or
    /// infinity when it stays above half to Nyquist.
    static func kernelRadius(_ h: (weights: [Double], offset: Int)) -> Double {
        let f = (0...1000).map { Double($0) / 2000 }
        let a = f.map { fr -> Double in
            var c = 0.0, s = 0.0
            for (k, w) in h.weights.enumerated() {
                c += w * cos(2 * Double.pi * fr * Double(k - h.offset))
                s += w * sin(2 * Double.pi * fr * Double(k - h.offset))
            }
            return (c * c + s * s).squareRoot()
        }
        return radius(f, a, from: 0)
    }

    /// The measured criterion, from 8 public domain scans: the grain goes through the scan and
    /// not the lens or the emulsion's scatter, so on every
    /// scan Look its -6 dB radius is at or under the scan kernel's own (never sharper than the
    /// scan), and 1.5 to 2.5 times the picture's MTF50 with the Optics softness at the Look's own
    /// default (the reels read 1.68 to 2.13). A radius past Nyquist reads infinite: there the grain
    /// must be past it too, and the ratio has no reading.
    func testGrainIsSharperThanThePictureButNotTheScan() throws {
        let g = try GPUHarness()
        let looks = Looks.all.filter { $0.category == .film }
        XCTAssertGreaterThanOrEqual(looks.count, 6)
        let f = FilmLayers.FilmFrame(width: Self.w, height: Self.h, film: 3, time: 0.1)
        for look in looks {
            let film = chain(look, grain: true).vhs!.film
            let scan = Self.kernelRadius(FilmLayers.grainKernel(film.grainSoftening(f), scale: 1))
            let whole = Self.kernelRadius(FilmLayers.grainKernel([.init(
                sigma: film.floats(for: film.format, frame: f)[0])], scale: 1))
            let r = try radii(g, look)
            print(String(format: "grain %@: grain -6 dB %.4f, scan kernel %.4f, format kernel %.4f, picture MTF50 %.4f cycles/px, ratio %.2f, grain rms %.5f, optics softness %.2f",
                         look.id, r.grain, scan, whole, r.picture, r.grain / r.picture, r.rms,
                         film.optics.float("softness")))
            XCTAssertTrue(r.picture.isFinite, "\(look.id) picture radius")
            if r.grain.isFinite {
                XCTAssertLessThanOrEqual(r.grain, scan, "\(look.id): the grain is sharper than the scan")
                XCTAssertGreaterThanOrEqual(r.grain / r.picture, 1.5, "\(look.id): the grain is too soft")
                XCTAssertLessThanOrEqual(r.grain / r.picture, 2.5, "\(look.id): the grain is too sharp")
            } else {
                XCTAssertFalse(scan.isFinite, "\(look.id): the grain reaches Nyquist and the scan does not")
                XCTAssertGreaterThanOrEqual(0.5 / r.picture, 1.4, "\(look.id): the picture is too sharp to read the ratio")
            }
        }
    }

    /// The softening keeps the grain's strength: its RMS on flat gray within 10 percent of the
    /// same Look with the lens and the format's blur off (the field unsoftened).
    /// The weave is off on both sides: its linear resample takes up to half the variance of an
    /// unsoftened field and little of a softened one, so it would measure the weave instead.
    func testSofteningKeepsTheGrainStrength() throws {
        let g = try GPUHarness()
        let gray = try source(g.device) { _ in 128 }
        for id in ["super8-kodachrome", "sixteen-news", "thirtyfive-vision"] {
            let look = try XCTUnwrap(Looks.look(id: id))
            let softened = chain(look, grain: true)
            softened.vhs!.film.weave.enabled = false
            let soft = Self.rms(try render(g, softened, gray), width: Self.w, height: Self.h)
            let bare = chain(look, grain: true)
            bare.vhs!.film.weave.enabled = false
            bare.vhs!.film.optics.enabled = false
            bare.vhs!.film.format.enabled = false
            let sharp = Self.rms(try render(g, bare, gray), width: Self.w, height: Self.h)
            print(String(format: "grain-mtf %@: rms softened %.5f, unsoftened %.5f", id, soft, sharp))
            XCTAssertEqual(soft / sharp, 1, accuracy: 0.1, id)
        }
    }

    /// The stock's curve reaches the picture through the parameter buffer: with only the grain
    /// on, the grain's RMS on flat patches at encoded 0.25 and 0.75 stands in the ratio of the
    /// table's points there, and the measured polarity holds (a reversal loses its grain toward
    /// the highlights, to under 0.6 of mid gray at 0.75, and a negative stays within 0.12 of
    /// mid gray from 0.25 to 1, 500T's 1.1 in the shadows included).
    func testGrainCurveFollowsTheStock() throws {
        let g = try GPUHarness()
        for stock in FilmStock.allCases {
            let k = stock.grainCurve
            XCTAssertEqual(k.count, 5, stock.rawValue)
            XCTAssertEqual(k[2], 1, stock.rawValue)
            if stock.isNegative {
                for v in k[1...] { XCTAssertEqual(v, 1, accuracy: 0.12, "\(stock.rawValue): a negative is flat") }
            } else {
                XCTAssertLessThan(k[3], 0.6, "\(stock.rawValue): a reversal's highlights are clean")
                XCTAssertLessThan(k[4], k[3], stock.rawValue)
            }
        }
        for stock in [FilmStock.kodachrome40, .vision500T] {
            var r: [Double] = []
            for v in [UInt8(64), UInt8(191)] {
                let chain = SignalChain.standard()
                chain.framing.mode = .fullRaster
                let film = chain.vhs!.film
                film.source.enabled = true
                chain.vhs!.tape.enabled = false
                for l in film.all.dropFirst() { l.enabled = false }
                film.grain.enabled = true
                film.stock.setParameter("stock", to: .choice(stock.rawValue))
                r.append(Self.rms(try render(g, chain, try source(g.device) { _ in v }), width: Self.w, height: Self.h))
            }
            let k = stock.grainCurve
            // 64 and 191 of 255 are 0.251 and 0.749, a hair off the table's points.
            let want = (k[1] + 0.004 * (k[2] - k[1]) * 4) / (k[3] - 0.004 * (k[3] - k[2]) * 4)
            print(String(format: "grain-mtf curve %@: rms at 0.25 %.5f, at 0.75 %.5f, ratio %.3f, table %.3f",
                         stock.rawValue, r[0], r[1], r[0] / r[1], want))
            XCTAssertEqual(r[0] / r[1], want, accuracy: 0.08 * want, stock.rawValue)
        }
    }

    /// Each dye layer's grain by its own amount (the measured tables): blue the grainiest
    /// and coarsest layer on every stock, the amounts' luminance weighted mean 1 so the luminance
    /// grain is the stock's own, and on a flat gray 16mm News scan (Vision3 500T, Kodak's R 6.6,
    /// G 8.2, B 20.7) the blue layer far the grainiest, then green, then red.
    func testGrainPerDyeLayer() throws {
        let g = try GPUHarness()
        for stock in FilmStock.allCases {
            let p = stock.grainPerChannel
            XCTAssertTrue(p.amount.z > p.amount.y && p.amount.z > p.amount.x, stock.rawValue)
            XCTAssertTrue(p.size.z >= p.size.y && p.size.z >= p.size.x, stock.rawValue)
            XCTAssertEqual((p.amount * FilmStock.lumaWeights).sum(), 1, accuracy: 1e-9, stock.rawValue)
        }
        let gray = try source(g.device) { _ in 128 }
        for id in ["super8-kodachrome", "sixteen-news"] {
            let look = try XCTUnwrap(Looks.look(id: id))
            let rms = try (0..<3).map { Self.rms(try render(g, chain(look, grain: true), gray, channel: $0),
                                                width: Self.w, height: Self.h) }
            print(String(format: "grain layers %@: rms r %.5f, g %.5f, b %.5f", id, rms[0], rms[1], rms[2]))
            XCTAssertGreaterThan(rms[2], rms[1], id)
            if id == "sixteen-news" {
                XCTAssertGreaterThan(rms[2], 1.5 * rms[1], id)
                XCTAssertGreaterThan(rms[1], rms[0], id)
            }
        }
    }

    /// The CPU's variance model of the softening (`grainGains`) is the tent's own: no softening
    /// is a gain of 1, and a wider blur takes more of the field.
    func testGrainGainsFollowTheBlur() {
        let film = FilmLayers()
        let f = FilmLayers.FilmFrame(width: 1440, height: 1080, film: 0, time: 0)
        XCTAssertEqual(film.grainSoftening(f), [.init(sigma: film.floats(for: film.format, frame: f)[0]
            * FilmLayers.grainScanShare)], "the scan's part of the format, not the lens")
        let one = film.grainGains(f, softening: [])
        XCTAssertEqual(one.common, 1)
        let base = film.grainGains(f, softening: film.grainSoftening(f)).common
        film.format.setParameter("blur", to: .float(3))
        let wide = film.grainGains(f, softening: film.grainSoftening(f)).common
        XCTAssertGreaterThan(base, 1)
        XCTAssertGreaterThan(wide, base)
        XCTAssertEqual(FilmLayers.tentCorrelation(0), 1, accuracy: 1e-12)
        XCTAssertEqual(FilmLayers.tentCorrelation(2), 0)
    }
}
