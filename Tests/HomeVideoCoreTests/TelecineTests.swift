import Metal
import XCTest
@testable import HomeVideoCore

/// The Telecine stage. Unused it is the Film onto the Tape byte for byte (and the plain chain
/// with Film off), each layer alone changes the picture, the Pro cadences lay fields as
/// docs/TELECINE.md says, the
/// Home flicker beats at the blade and field arithmetic, the defaults are docs/TELECINE.md's,
/// a seed repeats, the tiers set the route, and sidecars and presets keep the section.
@MainActor
final class TelecineTests: XCTestCase {
    // MARK: Helpers

    func pattern(_ g: GPUHarness, shift: Int = 0) throws -> MTLTexture {
        try g.source { x, y in
            if x > 300 + shift && x < 420 + shift && y > 180 && y < 300 { return (255, 255, 255) }
            let v = UInt8(40 + (x * 180) / 720)
            return (x / 24) % 2 == 0 ? (v, v / 2, 60) : (60, v, v)
        }
    }

    func standardChain() -> (SignalChain, VHSLayers) {
        let chain = SignalChain.standard()
        chain.framing.mode = .fullRaster
        return (chain, chain.vhs!)
    }

    /// Film on into the Telecine, the route chosen, every Film layer off but the master.
    func telecine(_ vhs: VHSLayers, route: TelecineRoute) {
        vhs.film.source.enabled = true
        for l in vhs.film.all.dropFirst() { l.enabled = false }
        vhs.telecine.source.enabled = true
        vhs.telecine.source.setParameter("route", to: .choice(route.rawValue))
    }

    func render(_ g: GPUHarness, _ chain: SignalChain, _ src: MTLTexture, frame: UInt64) throws -> [UInt16] {
        try g.run(chain, src, frame: frame, raw: true).1
    }

    /// Frames 0 to n-1 of a source that moves 6 px a frame, concatenated.
    func sequence(_ g: GPUHarness, _ chain: SignalChain, frames: Int = 5) throws -> [UInt16] {
        chain.reset()
        var all: [UInt16] = []
        for k in 0..<frames {
            all += try render(g, chain, try pattern(g, shift: k * 6), frame: UInt64(k))
        }
        return all
    }

    // MARK: Unused

    /// With Telecine unused, Film onto the Tape with the Telecine's values moved and its switch
    /// off writes what Tape writes. With Film off, the Telecine moved but switched off is the
    /// plain chain, and switched on it transfers the clip itself. The stage's switch alone
    /// routes the film.
    func testUnusedIsFilmAndPlainChainByteForByte() throws {
        let g = try GPUHarness()
        let src = try pattern(g)
        // Film off: the plain chain with the Telecine moved and off, a transfer with it on.
        let main = SignalChain(framing: FramingLayer(mode: .fullRaster), effects: VHSLayers().all)
        let (chain, vhs) = standardChain()
        vhs.telecine.source.setParameter("quality", to: .choice("pro"))
        for frame: UInt64 in [0, 7] {
            XCTAssertEqual(try g.run(main, src, frame: frame, raw: true).1, try render(g, chain, src, frame: frame),
                           "Film off, Telecine off, frame \(frame)")
        }
        vhs.telecine.source.enabled = true
        XCTAssertTrue(vhs.telecineInUse)
        for frame: UInt64 in [0, 7] {
            XCTAssertNotEqual(try g.run(main, src, frame: frame, raw: true).1, try render(g, chain, src, frame: frame),
                              "Film off, Telecine on transfers the clip, frame \(frame)")
        }
        // Film on, Tape: the Film onto the Tape with no Telecine.
        func tape() -> SignalChain {
            let (c, v) = standardChain()
            v.film.source.enabled = true
            return c
        }
        let reference = tape()
        let moved = tape()
        moved.vhs!.telecine.camera.setParameter("lag", to: .float(1))
        moved.vhs!.telecine.source.setParameter("route", to: .choice("pro"))
        XCTAssertFalse(moved.vhs!.telecineInUse)
        for frame: UInt64 in [0, 3, 7] {
            let a = try render(g, reference, src, frame: frame)
            XCTAssertEqual(a, try render(g, moved, src, frame: frame), "Telecine moved but off, frame \(frame)")
        }
        // While unused the Telecine leaves the fingerprint alone and the files carry its records
        // only once moved. Every file carries the Display and Re-capture records.
        let fresh = tape()
        let base = fresh.vhs!.all.count + fresh.vhs!.crt.all.count + fresh.vhs!.recapture.all.count
        let before = ChainFingerprint.of(fresh)
        XCTAssertEqual(fresh.vhs!.savedLayers.count, base + 12)
        fresh.vhs!.telecine.gate.setParameter("seed", to: .float(9))
        XCTAssertEqual(ChainFingerprint.of(fresh), before, "Telecine values do not count while unused")
        XCTAssertEqual(fresh.vhs!.savedLayers.count, base + 12 + 9, "moved Telecine is saved")
        fresh.vhs!.telecine.source.enabled = true
        XCTAssertNotEqual(ChainFingerprint.of(fresh), before)
        XCTAssertEqual(SignalChain.standard().vhs!.savedLayers.count, base, "the default chain's files, and the Display's")
    }

    /// Only the Telecine Looks turn Telecine on (8mm to Tape, Mall Transfer and Pro Scan), and
    /// every Look reads back. 8mm to Tape is Home at Mall.
    func testOnlyTheTelecineLooksTurnTelecineOn() {
        let vhs = VHSLayers(), audio = AudioChain()
        let p = Presets(vhs: vhs, audio: audio)
        let id = "home-movie-transfer"
        XCTAssertEqual(Set(Looks.all.filter { $0.category == .telecine }.map(\.id)),
                       ["home-movie-transfer", "mall-transfer", "pro-scan"])
        for look in Looks.all {
            p.setLook(Looks.look(id: id)!)
            p.setLook(look)
            XCTAssertEqual(vhs.telecineInUse, look.category == .telecine, look.id)
            XCTAssertEqual(p.look?.id, look.id, "\(look.id) reads back")
        }
        p.setLook(Looks.look(id: id)!)
        XCTAssertEqual(vhs.telecine.route, .home)
        XCTAssertEqual(vhs.telecine.quality, .mall)
        XCTAssertEqual(vhs.film.stockChoice, .kodachrome40)
        XCTAssertEqual(vhs.film.formatChoice, .super8)
        XCTAssertTrue(Looks.film.contains(id), "Shuffle never rolls it")
        vhs.telecine.camera.setParameter("lag", to: .float(0.9))
        XCTAssertNil(p.look, "a Telecine slider moved reads Custom")
    }

    // MARK: Layers

    /// Each layer alone, on either route, changes the picture over five frames of motion.
    func testEachLayerAloneChangesThePicture() throws {
        let g = try GPUHarness()
        for route in TelecineRoute.allCases {
            let (chain, vhs) = standardChain()
            telecine(vhs, route: route)
            let t = vhs.telecine
            // The Grade at its defaults is neutral: give it a value to show.
            t.grade.setParameter("gainR", to: .float(1.2))
            for l in t.all.dropFirst() { l.enabled = false }
            let plain = try sequence(g, chain)
            for layer in t.layers(for: route) {
                layer.enabled = true
                XCTAssertNotEqual(try sequence(g, chain), plain, "\(route) \(layer.id) alone changes the picture")
                layer.enabled = false
            }
        }
    }

    /// The Pro pulldowns, as docs/TELECINE.md gives them: 2:3 lays 4 film frames over 10 fields as
    /// A-A-B-B-B-C-C-D-D-D, 3:3:4 lays 3 frames over 10 at 18 fps, 3:4:4:4 lays 4 over 15.
    func testProCadenceFieldPatterns() {
        func fields(_ speed: Int, _ n: Int) -> [Int64] {
            (0..<n).map { TelecineLayers.cadenceFrame(field: Int64($0), pulldown: TelecineLayers.pulldown(speed: speed)) }
        }
        XCTAssertEqual(fields(24, 10), [0, 0, 1, 1, 1, 2, 2, 3, 3, 3])
        XCTAssertEqual(fields(24, 20).last, 7)
        XCTAssertEqual(fields(18, 10), [0, 0, 0, 1, 1, 1, 2, 2, 2, 2])
        XCTAssertEqual(fields(16, 15), [0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3])
    }

    /// The same patterns on the picture: a source that changes every frame, the Telecine's Pro
    /// route with only its Cadence, read back field by field (odd rows the first field).
    func testProCadenceOnThePicture() throws {
        let g = try GPUHarness()
        func labels(_ speed: String) throws -> [Int] {
            let (chain, vhs) = standardChain()
            vhs.allOff()
            telecine(vhs, route: .pro)
            for l in vhs.telecine.all.dropFirst() { l.enabled = false }
            vhs.telecine.cadence.enabled = true
            vhs.telecine.cadence.setParameter("speed", to: .choice(speed))
            var seen: [UInt16] = [], out: [Int] = []
            for k in 0..<5 {
                let v = UInt8(20 + k * 40)
                let bits = try render(g, chain, try g.source { _, _ in (v, v, v) }, frame: UInt64(k))
                // Row 1 holds the first field, row 0 the second.
                for row in [1, 0] {
                    let b = bits[(row * GPUHarness.w + 100) * 4]
                    if !seen.contains(b) { seen.append(b) }
                    out.append(seen.firstIndex(of: b)!)
                }
            }
            return out
        }
        XCTAssertEqual(try labels("24"), [0, 0, 1, 1, 1, 2, 2, 3, 3, 3], "2:3, A-A-B-B-B-C-C-D-D-D")
        XCTAssertEqual(try labels("18"), [0, 0, 0, 1, 1, 1, 2, 2, 2, 2], "3:3:4, 3 frames over 10 fields")
    }

    /// The Home flicker at 18 fps with 3 blades: 54 flashes against 59.94 fields beat at about
    /// 6 Hz (docs/TELECINE.md's arithmetic). The field exposures, measured, peak there.
    func testHomeFlickerBeatMatchesTheArithmetic() {
        let beat = TelecineLayers.beat(rate: 18, blades: 3)
        XCTAssertEqual(beat, 59.94 - 54, accuracy: 0.01)
        XCTAssertLessThan(TelecineLayers.beat(rate: 20, blades: 3), 0.1, "the 20 fps fix (READ)")
        for tube in [false, true] {
            let n = 1200
            let series = (0..<n).map { f -> Double in
                let e = TelecineLayers.exposure(fieldTime: Double(f) / TelecineLayers.fieldRate, row: 0.5, rate: 18,
                                                blades: 3, tube: tube, shutter: 60)
                return e.a + e.b
            }
            let mean = series.reduce(0, +) / Double(n)
            XCTAssertEqual(mean, 1, accuracy: 0.05, "the iris sees the average")
            var best = (hz: 0.0, power: 0.0)
            for i in 10...1490 {
                let hz = Double(i) * 0.02
                var re = 0.0, im = 0.0
                for (f, v) in series.enumerated() {
                    let a = 2 * .pi * hz * Double(f) / TelecineLayers.fieldRate
                    re += (v - mean) * cos(a); im += (v - mean) * sin(a)
                }
                if re * re + im * im > best.power { best = (hz, re * re + im * im) }
            }
            XCTAssertEqual(best.hz, beat, accuracy: 0.1, "the measured beat, tube \(tube)")
        }
    }

    /// The Pro grade's fade correction on a faded reel (16mm Faded, Ektachrome 35 years)
    /// leaves every tone gray, white and black included, as `tc_grade` applies it (each channel
    /// to the power e, times g). The fade (`film_fade`, t to the power k per channel) leaves
    /// white and black neutral, so a gain that pins mid gray alone tints white the other way.
    /// At amount 0 it does nothing.
    func testFadeCorrectionKeepsEveryToneGray() {
        let vhs = VHSLayers()
        vhs.film.source.enabled = true
        vhs.film.stock.setParameter("stock", to: .choice(FilmStock.ektachrome160.rawValue))
        vhs.film.fade.setParameter("years", to: .float(35))
        let tau = vhs.film.stockChoice.fadeYears
        let k = [exp(-35 / tau.x), exp(-35 / tau.y), exp(-35 / tau.z)]
        for amount in [0.0, 0.5, 1.0] {
            vhs.telecine.grade.setParameter("fade", to: .float(amount))
            let p = vhs.telecine.gradeValues(film: vhs.film)
            for t in [0.002, 0.05, 0.18, 0.6, 1.0] {
                let out = (0..<3).map { c in pow(pow(t, k[c]), p[9 + c]) * p[12 + c] }
                if amount == 0 {
                    for c in 0..<3 { XCTAssertEqual(out[c], pow(t, k[c]), accuracy: 1e-9, "amount 0 is no change") }
                } else if amount == 1 {
                    let mid = out.reduce(0, +) / 3
                    XCTAssertLessThan(out.map { abs($0 - mid) }.max()! / max(mid, 1e-6), 0.02,
                                      "tone \(t) comes out gray, got \(out)")
                }
                XCTAssertLessThanOrEqual(out.max()!, 1 + 1e-9, "tone \(t), amount \(amount): nothing past white")
            }
        }
    }

    /// With the Film off there is no Film frame rate, so Pro's "As shot" is 24 fps (2:3) and
    /// Home's projector runs at its own speed. With the Film on, As shot is the
    /// Film's rate.
    func testTelecineWithoutFilmAssumesItsOwnRate() {
        let vhs = VHSLayers()
        vhs.telecine.source.enabled = true
        vhs.telecine.source.setParameter("route", to: .choice("pro"))
        XCTAssertFalse(vhs.film.isOn)
        XCTAssertTrue(vhs.telecineInUse)
        XCTAssertEqual(vhs.telecine.proSpeed(film: vhs.film), 24)
        XCTAssertEqual(vhs.telecine.transferRate(film: vhs.film), 24 * 1000 / 1001, accuracy: 1e-9)
        vhs.film.source.enabled = true
        vhs.film.shutter.setParameter("fps", to: .choice("18"))
        XCTAssertEqual(vhs.telecine.proSpeed(film: vhs.film), 18, "As shot reads the Film's rate")
        vhs.film.source.enabled = false
        vhs.telecine.source.setParameter("route", to: .choice("home"))
        XCTAssertEqual(vhs.telecine.transferRate(film: vhs.film), vhs.telecine.cadence.float("projector"))
    }

    /// The Home tiers' flicker reads as the tier table in docs/TELECINE.md, strong at Mall, reduced
    /// at Mid-grade, none at Pro. A flash rate beating near the field rate alternates the fields
    /// bright and dark (18 fps by 5 blades is 90 flashes, 29.9 Hz against 59.94 fields, the
    /// fields at 0.67 and 1.33 of the light, a flashing picture), so each tier's beat stays
    /// slow and each tier's swing, field to field and over a second, stays under the last.
    func testHomeTierFlickerFollowsTheTierTable() {
        func swing(_ q: TelecineQuality) -> (beat: Double, step: Double, range: Double) {
            var p: [String: ParameterValue] = [:]
            for (l, k, v) in TelecineLayers.tier(q, route: .home) where l == "telecine-flicker" || l == "telecine-cadence" {
                p[k] = v
            }
            guard case .float(let rate) = p["projector"]!, case .choice(let b) = p["blades"]!,
                  case .choice(let cam) = p["camera"]!, case .float(let shutter) = p["shutter"]! else { return (0, 9, 9) }
            let blades = Int(b)!
            // The whole field's light, the rows averaged, over two seconds of fields.
            let series = (0..<120).map { f -> Double in
                let rows = stride(from: 0.05, to: 1, by: 0.1).map { row -> Double in
                    let e = TelecineLayers.exposure(fieldTime: Double(f) / TelecineLayers.fieldRate, row: row, rate: rate,
                                                    blades: blades, tube: cam == "tube", shutter: shutter)
                    return e.a + e.b
                }
                return rows.reduce(0, +) / Double(rows.count)
            }
            let step = zip(series, series.dropFirst()).map { abs($1 - $0) }.max()!
            return (TelecineLayers.beat(rate: rate, blades: blades), step, series.max()! - series.min()!)
        }
        let mall = swing(.mall), mid = swing(.mid), pro = swing(.pro)
        for (q, s) in [("mall", mall), ("mid", mid), ("pro", pro)] {
            XCTAssertLessThan(s.beat, 10, "\(q): the beat stays slow, never near the field rate")
            XCTAssertLessThan(s.step, 0.05, "\(q): no field flashes against the one before it")
        }
        XCTAssertLessThan(mid.range, mall.range, "Mid-grade's flicker is reduced against Mall's")
        XCTAssertLessThan(pro.range, 0.02, "Pro has none")
    }

    // MARK: Tiers

    /// A tier sets its route's layers to the tier table, the sliders stay free after it, and
    /// a new route takes the tier as it stands.
    func testTiersSetTheRoute() {
        let t = TelecineLayers()
        for route in TelecineRoute.allCases {
            t.source.setParameter("route", to: .choice(route.rawValue))
            for q in TelecineQuality.allCases {
                t.source.setParameter("quality", to: .choice(q.rawValue))
                for (l, p, v) in TelecineLayers.tier(q, route: route) {
                    let layer = t.all.first { $0.id == l }!
                    XCTAssertEqual(layer.values[p], v, "\(route) \(q) \(l).\(p)")
                }
            }
        }
        t.camera.setParameter("lag", to: .float(0.77))
        XCTAssertEqual(t.camera.float("lag"), 0.77)
        // The defaults are the Mall tier of each route.
        let fresh = TelecineLayers()
        for route in TelecineRoute.allCases {
            for (l, p, v) in TelecineLayers.tier(.mall, route: route) {
                XCTAssertEqual(fresh.all.first { $0.id == l }!.values[p], v, "default \(l).\(p)")
            }
        }
    }

    // MARK: Defaults

    /// Every Telecine parameter's default and range is the row in docs/TELECINE.md.
    func testDefaultsAndRangesMatchTheDoc() throws {
        let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/TELECINE.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        var rows: [String: [String]] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| telecine") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5 else { continue }
            rows["\(cells[0]).\(cells[1])"] = cells
        }
        let t = TelecineLayers()
        var checked = 0
        for layer in t.all {
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
                    XCTFail("no bool parameters in Telecine")
                }
                XCTAssertTrue(["READ", "INFERRED"].contains(row[4]), "\(layer.id).\(p.id) READ or INFERRED")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 37)
        XCTAssertFalse(t.source.enabled, "off by default")
    }

    // MARK: Seeds and files

    /// Two renders with one seed are byte identical, and another seed is another take.
    func testOneSeedRepeatsExactly() throws {
        let g = try GPUHarness()
        func take(_ route: TelecineRoute, _ seed: Double) throws -> [UInt16] {
            let (chain, vhs) = standardChain()
            vhs.film.source.enabled = true
            vhs.telecine.source.enabled = true
            vhs.telecine.source.setParameter("route", to: .choice(route.rawValue))
            for l in vhs.telecine.all where l.parameters.contains(where: { $0.id == "seed" }) {
                l.setParameter("seed", to: .float(seed))
            }
            return try sequence(g, chain, frames: 4)
        }
        for route in TelecineRoute.allCases {
            let a = try take(route, 3)
            XCTAssertEqual(a, try take(route, 3), "\(route)")
            XCTAssertNotEqual(a, try take(route, 4), "\(route)")
        }
    }

    /// A sidecar and a saved preset keep the Telecine section, and a file without it turns it off.
    func testSidecarAndPresetRoundTripTheTelecineSection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("telecine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func set(_ chain: SignalChain) {
            let v = chain.vhs!
            v.film.source.enabled = true
            v.telecine.source.enabled = true
            v.telecine.source.setParameter("route", to: .choice("pro"))
            v.telecine.source.setParameter("quality", to: .choice("mid"))
            v.telecine.grade.setParameter("gammaB", to: .float(1.3))
            v.telecine.cadence.setParameter("speed", to: .choice("16"))
            v.telecine.scanner.enabled = false
        }
        func check(_ chain: SignalChain, _ what: String) {
            let v = chain.vhs!
            XCTAssertTrue(v.telecineInUse, what)
            XCTAssertEqual(v.telecine.route, .pro, what)
            XCTAssertEqual(v.telecine.quality, .mid, what)
            XCTAssertEqual(v.telecine.grade.float("gammaB"), 1.3, what)
            XCTAssertEqual(v.telecine.grade.float("fade"), 0.5, what)
            XCTAssertEqual(v.telecine.cadence.choice("speed"), "16", what)
            XCTAssertFalse(v.telecine.scanner.enabled, what)
        }
        let a = SignalChain.standard()
        set(a)
        let side = folder.appendingPathComponent("clip.mov.homevideo.json")
        try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, to: side)
        let b = SignalChain.standard()
        try Sidecar.read(side, into: b)
        check(b, "sidecar")

        let store = UserPresets(folder: folder.appendingPathComponent("presets"))
        let saved = try store.save(name: "Telecine test", chain: a)
        let c = SignalChain.standard()
        Presets(vhs: c.vhs!, audio: c.audio).setLook(saved.look)
        check(c, "preset")

        // A sidecar written with Film on and Telecine unused carries no Telecine records.
        let filmOnly = SignalChain.standard()
        filmOnly.vhs!.film.source.enabled = true
        let plain = folder.appendingPathComponent("plain.mov.homevideo.json")
        try Sidecar.write(chain: filmOnly, name: "plain.mov", lookID: nil, to: plain)
        let text = try String(contentsOf: plain, encoding: .utf8)
        XCTAssertFalse(text.contains("telecine"), "no Telecine records while unused")
        try Sidecar.read(plain, into: b)
        XCTAssertFalse(b.vhs!.telecine.isOn)
        XCTAssertTrue(b.vhs!.telecine.isAtDefault)
    }
}
