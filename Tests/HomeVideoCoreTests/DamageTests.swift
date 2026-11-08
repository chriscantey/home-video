import Metal
import XCTest
@testable import HomeVideoCore

/// The Damage pass: every layer off by default and in every clean Look (a built-in Look sets
/// Damage, the worn ones switching on their wear), off leaves the picture and the sound
/// unchanged, the seed decides the event times (same seed, same times, and another seed, other
/// times), the Rate sets the frequency and its default keeps the events of files saved before
/// Rate existed, the picture events run inside the chain, each picture layer changes an event frame, and each
/// audio event has its band and depth.
@MainActor
final class DamageTests: XCTestCase {
    static let rate = 48_000.0

    // MARK: Off by default, off in every clean Look

    func testEveryDamageLayerIsOffByDefaultAndInEveryLook() {
        let chain = SignalChain.standard()
        let vhs = chain.vhs!
        XCTAssertEqual(vhs.damage.all.map(\.id), ["damage-clog", "damage-crease", "damage-snow", "damage-tear"])
        XCTAssertEqual(chain.audio.damage.map(\.id), ["audio-damage-glide", "audio-damage-flutter",
                                                      "audio-damage-azimuth", "audio-damage-clog", "audio-damage-worn",
                                                      "audio-damage-crackle", "audio-damage-hifi", "audio-damage-mute"])
        // Every Look but the worn ones (LooksTests has those).
        for look in Looks.all where !Looks.worn.contains(look.id) {
            Presets(vhs: vhs, audio: chain.audio).setLook(look)
            XCTAssertTrue(vhs.damage.all.allSatisfy { !$0.enabled }, look.id)
            XCTAssertTrue(chain.audio.damage.allSatisfy { !$0.enabled }, look.id)
            let ref = Looks.reference(look)
            XCTAssertTrue(ref.vhs.damage.all.allSatisfy { !$0.enabled }, "\(look.id) ships with Damage off")
        }
    }

    func testDamageSitsOnTopOfABuiltInLookAndAUserPresetCarriesIt() throws {
        let chain = SignalChain.standard()
        let vhs = chain.vhs!
        let presets = Presets(vhs: vhs, audio: chain.audio)
        presets.setLook(Looks.look(id: "clean-sp")!)
        vhs.damage.snow.enabled = true
        vhs.damage.snow.setParameter("strength", to: .float(0.7))
        chain.audio.damage[1].enabled = true
        XCTAssertEqual(presets.look?.id, "clean-sp", "a Damage layer does not turn the Look to Custom")
        // A built-in Look sets Damage, a clean one switching it off.
        presets.setLook(Looks.look(id: "good-deck")!)
        XCTAssertFalse(vhs.damage.snow.enabled, "a clean Look switches Damage off")
        XCTAssertFalse(chain.audio.damage[1].enabled)
        presets.setLook(Looks.look(id: "clean-sp")!)
        vhs.damage.snow.enabled = true
        vhs.damage.snow.setParameter("strength", to: .float(0.7))
        chain.audio.damage[1].enabled = true

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-damage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder); Looks.user = [] }
        let store = UserPresets(folder: folder)
        vhs.damage.snow.setParameter("seed", to: .float(42))
        let saved = try store.save(name: "Snowy", chain: chain)

        let fresh = SignalChain.standard()
        try store.load(saved.url, into: fresh)
        XCTAssertTrue(fresh.vhs!.damage.snow.enabled)
        XCTAssertEqual(fresh.vhs!.damage.snow.strength, 0.7, accuracy: 1e-9)
        XCTAssertEqual(fresh.vhs!.damage.snow.seed, 42)
        XCTAssertTrue(fresh.audio.damage[1].enabled, "the audio Damage layers round trip too")

        // The sidecar's record carries them as well.
        let url = folder.appendingPathComponent("clip.homevideo.json")
        try Sidecar.write(chain: chain, name: "clip", lookID: nil, to: url)
        let back = SignalChain.standard()
        try Sidecar.read(url, into: back)
        XCTAssertTrue(back.vhs!.damage.snow.enabled)
        XCTAssertEqual(back.vhs!.damage.snow.seed, 42)
        XCTAssertTrue(back.audio.damage[1].enabled)

        // And the settings clipboard.
        let json = SettingsClipboard.encode(chain)
        let pasted = SignalChain.standard()
        try SettingsClipboard.apply(json, to: pasted)
        XCTAssertTrue(pasted.vhs!.damage.snow.enabled)
        XCTAssertTrue(pasted.audio.damage[1].enabled)
    }

    /// Files saved before Rate existed write the crease as `period` (s). A user preset file or
    /// clipboard text like that still loads through the strict reads, and the crease's Rate is
    /// 60 over it.
    func testAnOldPeriodLoadsAsRateInAPresetFileAndTheClipboard() throws {
        // The crease's parameters in such a file: `period`, no `rate`.
        func asBeforeRate(_ root: inout [String: Any]) {
            var layers = root["layers"] as! [[String: Any]]
            let i = layers.firstIndex { $0["id"] as? String == "damage-crease" }!
            var params = (layers[i]["parameters"] as! [[String: Any]]).filter { $0["id"] as? String != "rate" }
            params.append(["id": "period", "value": 20.0]) // 3 a minute, off the default 5
            layers[i]["parameters"] = params
            layers[i]["enabled"] = true
            root["layers"] = layers
        }
        let chain = SignalChain.standard()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-period-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder); Looks.user = [] }
        let store = UserPresets(folder: folder)
        let saved = try store.save(name: "Folded", chain: chain)
        var file = try JSONSerialization.jsonObject(with: Data(contentsOf: saved.url)) as! [String: Any]
        asBeforeRate(&file)
        try JSONSerialization.data(withJSONObject: file).write(to: saved.url)
        let fresh = SignalChain.standard()
        try store.load(saved.url, into: fresh)
        XCTAssertTrue(fresh.vhs!.damage.crease.enabled)
        XCTAssertEqual(fresh.vhs!.damage.crease.rate, 60 / 20, accuracy: 1e-9, "a preset's period becomes 60 over it")

        var text = try JSONSerialization.jsonObject(with: Data(SettingsClipboard.encode(chain).utf8)) as! [String: Any]
        asBeforeRate(&text)
        let pasted = SignalChain.standard()
        try SettingsClipboard.apply(String(decoding: JSONSerialization.data(withJSONObject: text), as: UTF8.self), to: pasted)
        XCTAssertTrue(pasted.vhs!.damage.crease.enabled)
        XCTAssertEqual(pasted.vhs!.damage.crease.rate, 60 / 20, accuracy: 1e-9, "the clipboard's period becomes 60 over it")
    }

    /// The sidebar's readout: a Rate and a seed read whole, other floats with two decimals.
    func testRateAndSeedReadWholeAndOtherFloatsTwoDecimals() {
        let crease = VHSLayers().damage.crease
        func readout(_ id: String) -> String {
            let p = crease.parameters.first { $0.id == id }!
            guard case .float(let v) = p.value else { return "" }
            return p.readout(v)
        }
        XCTAssertEqual(readout("rate"), "5")
        XCTAssertEqual(readout("seed"), String(format: "%.0f", crease.seed))
        XCTAssertEqual(readout("strength"), String(format: "%.2f", crease.strength))
        let dropouts = VHSLayers().dropouts.parameters.first { $0.id == "rate" }!
        XCTAssertFalse(dropouts.readout(12000).contains("."), "the dropout Rate reads whole too")
    }

    func testRenderArgumentsAddressDamageAndTheFingerprintMoves() throws {
        let chain = SignalChain.standard()
        let before = ChainFingerprint.of(chain)
        try RenderArguments(input: "a", output: "b", layers: .all).apply(to: chain)
        XCTAssertFalse(chain.vhs!.damage.all.contains { $0.enabled }, "--layers all leaves Damage off")
        let all = ChainFingerprint.of(chain)
        try RenderArguments(input: "a", output: "b",
                            settings: [.init(layer: "damage-tear", parameter: "enabled", value: "on"),
                                       .init(layer: "damage-tear", parameter: "strength", value: "0.7"),
                                       .init(layer: "damage-tear", parameter: "seed", value: "17"),
                                       .init(layer: "audio-damage-hifi", parameter: "enabled", value: "on"),
                                       .init(layer: "audio-damage-hifi", parameter: "offset", value: "5")])
            .apply(to: chain)
        XCTAssertTrue(chain.vhs!.damage.tear.enabled)
        XCTAssertEqual(chain.vhs!.damage.tear.strength, 0.7, accuracy: 1e-9)
        XCTAssertEqual(chain.vhs!.damage.tear.seed, 17)
        XCTAssertEqual(chain.audio.damage.first { $0.id == "audio-damage-hifi" }?.value("offset")?.doubleValue, 5)
        XCTAssertNotEqual(ChainFingerprint.of(chain), all, "switching a Damage layer on moves the fingerprint")
        XCTAssertNotEqual(before, all)
        try RenderArguments(input: "a", output: "b", layers: .only(["damage-crease"])).apply(to: chain)
        XCTAssertTrue(chain.vhs!.damage.crease.enabled)
        XCTAssertTrue(chain.vhs!.outputCard.enabled, "a Damage layer needs L1, like any middle layer")
    }

    func testTheDefaultFingerprintIgnoresDamageThatIsOff() {
        let chain = SignalChain.standard()
        let a = ChainFingerprint.of(chain)
        chain.vhs!.damage.snow.setParameter("seed", to: .float(5))
        XCTAssertEqual(ChainFingerprint.of(chain), a, "an off layer's values do not count")
        chain.vhs!.damage.snow.enabled = true
        XCTAssertNotEqual(ChainFingerprint.of(chain), a)
    }

    // MARK: Timing

    func testTheSameSeedGivesTheSameEventsAndAnotherSeedOthers() {
        let a = DamageSchedule(salt: 1, seed: 7, ratePerSecond: 0.2, shortest: 0.1, longest: 0.5).starts(from: 0, to: 600)
        let b = DamageSchedule(salt: 1, seed: 7, ratePerSecond: 0.2, shortest: 0.1, longest: 0.5).starts(from: 0, to: 600)
        let c = DamageSchedule(salt: 1, seed: 8, ratePerSecond: 0.2, shortest: 0.1, longest: 0.5).starts(from: 0, to: 600)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.map(\.start), c.map(\.start))
        // Any window asks the same question: the events of [0, 600) are those of its halves.
        let s = DamageSchedule(salt: 1, seed: 7, ratePerSecond: 0.2, shortest: 0.1, longest: 0.5)
        XCTAssertEqual(s.starts(from: 0, to: 300) + s.starts(from: 300, to: 600), a)

        let tear = TrackingTearLayer()
        tear.setParameter("strength", to: .float(1))
        let t1 = tear.schedule.starts(from: 0, to: 600).map(\.start)
        tear.setParameter("seed", to: .float(1))
        XCTAssertNotEqual(tear.schedule.starts(from: 0, to: 600).map(\.start), t1)
        tear.setParameter("seed", to: .float(0))
        XCTAssertEqual(tear.schedule.starts(from: 0, to: 600).map(\.start), t1)
    }

    func testTheRateSetsTheFrequencyAndTheStrengthDoesNot() {
        func count(_ r: Double, _ make: (Double) -> DamageSchedule) -> Int { make(r).starts(from: 0, to: 36_000).count }
        let tear = { (r: Double) -> DamageSchedule in
            let l = TrackingTearLayer(); l.setParameter("rate", to: .float(r)); return l.schedule
        }
        let clog = { (r: Double) in HeadClogTiming.schedule(perMinute: r, seed: 3) }
        let crease = { (r: Double) -> DamageSchedule in
            let l = CreaseLayer(); l.setParameter("rate", to: .float(r)); return l.schedule
        }
        // Below the slot's ceiling the count is proportional to the Rate.
        for make in [tear, clog] {
            let full = count(1.5, make), quarter = count(0.375, make)
            XCTAssertEqual(Double(full) / Double(quarter), 4, accuracy: 0.6, "\(full) against \(quarter)")
        }
        XCTAssertEqual(count(6, tear), 3_600, accuracy: 400, "6 a minute over 10 h")
        XCTAssertEqual(count(0, tear), 0)
        // Higher up, at most one event starts per slot (an event's longest length), so the
        // count is the Rate thinned: 1 - exp(-rate w slot) a slot, over the stretch weights.
        for (r, make, slot) in [(40.0, tear, TrackingTearLayer.longest), (10.0, clog, HeadClogTiming.longest)] {
            let s = make(r)
            let expected = (0..<Int(36_000 / slot)).reduce(0.0) { n, k in
                n + 1 - exp(-r / 60 * s.weight(at: Double(k) * slot) * slot)
            }
            XCTAssertEqual(Double(count(r, make)), expected, accuracy: expected * 0.03, "rate \(r)")
        }
        XCTAssertGreaterThan(count(40, tear), 4 * count(6, tear))
        XCTAssertGreaterThan(count(20, crease), 2 * count(5, crease))

        // Strength leaves the times alone.
        let a = TrackingTearLayer(), b = TrackingTearLayer()
        a.setParameter("strength", to: .float(0.1))
        b.setParameter("strength", to: .float(1))
        XCTAssertEqual(a.schedule.starts(from: 0, to: 3_600), b.schedule.starts(from: 0, to: 3_600))

        // Snow: streaks per second follow the rate, times the stretch's weight.
        let snow = SnowLayer()
        func streaks(_ r: Double) -> Int {
            snow.setParameter("rate", to: .float(r))
            return (0..<300).reduce(0) { n, f in n + snow.lines(time: 30 + Double(f) / 29.97).filter { $0.kind != .none }.count }
        }
        // Low enough that no dropout spills onto a second line, so lines count dropouts.
        snow.setParameter("strength", to: .float(0.1))
        let w = DamageSchedule.weight(salt: SnowLayer.salt, seed: DamageSchedule.mix(0), at: 30)
        let full = streaks(260), quarter = streaks(65)
        XCTAssertGreaterThan(w, 0.2, "this stretch is not a quiet one")
        XCTAssertEqual(Double(full) / 10.01, 260 * w, accuracy: 260 * w * 0.15)
        XCTAssertEqual(Double(full) / Double(quarter), 4, accuracy: 0.6)

        // Every audio event has its Rate too.
        for kind in AudioLayerKind.damage {
            XCTAssertNotNil(AudioLayer(kind: kind).parameters.first { $0.id == "rate" }, "\(kind)")
        }
    }

    /// The default Rate is the frequency the default Strength gave when Strength set the rate,
    /// so a file written before Rate existed plays the same events.
    func testTheDefaultRateIsTheOldStrengthFrequency() {
        let d = DamageLayers()
        func old(_ salt: UInt32, _ perSecond: Double, _ a: Double, _ b: Double) -> [DamageSchedule.Event] {
            DamageSchedule(salt: salt, seed: 0, ratePerSecond: perSecond, shortest: a, longest: b).starts(from: 0, to: 3_600)
        }
        XCTAssertEqual(d.tear.schedule.starts(from: 0, to: 3_600), old(0xDA01, 0.5 * 6 / 60, 0.1, 0.5))
        XCTAssertEqual(d.clog.schedule.starts(from: 0, to: 3_600), old(0xDA03, 0.5 * 2 / 60, 1.5, 6))
        let pass = CreaseLayer.passSeconds(.sp)
        XCTAssertEqual(d.crease.schedule.starts(from: 0, to: 3_600), old(0xDA04, 1 / 12.0, pass, pass))
        XCTAssertEqual(d.snow.ratePerSecond, 0.3 * 260)
        // An Average gap (`period`), read from an old file, gives the same passes.
        let c = CreaseLayer()
        c.setParameter("period", to: .float(20))
        XCTAssertEqual(c.schedule.starts(from: 0, to: 3_600), old(0xDA04, 1 / 20.0, pass, pass))

        // Audio: each processor at its defaults keeps the older schedule (Strength 0.5 x max).
        func spec(_ k: AudioLayerKind) -> AudioLayerSpec { AudioLayerSpec.defaults(k) }
        let r = Self.rate
        XCTAssertEqual(FlutterBurst(spec: spec(.flutterBurst), sampleRate: r, channels: 1).schedule,
                       DamageSchedule(salt: 0xDA11, seed: 0, ratePerSecond: 0.5 * 4 / 60, shortest: 0.5, longest: 3))
        XCTAssertEqual(AzimuthWander(spec: spec(.azimuthWander), sampleRate: r, channels: 1).schedule,
                       DamageSchedule(salt: 0xDA12, seed: 0, ratePerSecond: 0.5 * 4 / 60, shortest: 2, longest: 8))
        XCTAssertEqual(HiFiDropoutBurst(spec: spec(.hifiDropoutBurst), sampleRate: r, channels: 1).bursts,
                       DamageSchedule(salt: 0xDA14, seed: 0, ratePerSecond: 0.5 * 6 / 60, shortest: 0.5, longest: 4))
        XCTAssertEqual(HiFiDropoutBurst(spec: spec(.hifiDropoutBurst), sampleRate: r, channels: 1).solidShare, 0.4)
        XCTAssertEqual(WowGlide(spec: spec(.wowGlide), sampleRate: r, channels: 1).schedule,
                       DamageSchedule(salt: 0xDA15, seed: 0, ratePerSecond: 0.5 * 4 / 60, shortest: 0.4, longest: 1.5))
        XCTAssertEqual(WornStretch(spec: spec(.wornStretch), sampleRate: r, channels: 1).schedule,
                       DamageSchedule(salt: 0xDA16, seed: 0, ratePerSecond: 0.5 * 3 / 60, shortest: 2, longest: 10))
        XCTAssertEqual(WornStretch(spec: spec(.wornStretch), sampleRate: r, channels: 1).drop, 3)
        XCTAssertEqual(CrackleBurst(spec: spec(.crackleBurst), sampleRate: r, channels: 1).schedule,
                       DamageSchedule(salt: 0xDA17, seed: 0, ratePerSecond: 0.5 * 8 / 60, shortest: 0.2, longest: 1.5))
        XCTAssertEqual(CrackleBurst(spec: spec(.crackleBurst), sampleRate: r, channels: 1).density, 300)
        XCTAssertEqual(MuteDrop(spec: spec(.muteDrop), sampleRate: r, channels: 1).schedule,
                       DamageSchedule(salt: 0xDA18, seed: 0, ratePerSecond: 0.5 * 6 / 60, shortest: 0.05, longest: 0.4))
        var clogOld = DamageSchedule(salt: 0xDA03, seed: 0, ratePerSecond: 0.5 * 2 / 60, shortest: 1.5, longest: 6)
        clogOld.salt = ClogMuffle.salt
        XCTAssertEqual(ClogMuffle(spec: spec(.clogMuffle), sampleRate: r, channels: 1).schedule, clogOld)
    }

    /// A sidecar written before Rate existed (no `rate` anywhere) reads to the same chain as
    /// one carrying the default Rate, and so renders the same bytes.
    func testAnOldSidecarWithoutRateReadsAsTheDefaultRate() throws {
        let chain = SignalChain.standard()
        let d = chain.vhs!.damage
        for l in d.all { l.enabled = true; l.setParameter("strength", to: .float(0.8)); l.setParameter("seed", to: .float(9)) }
        for l in chain.audio.damage { l.enabled = true }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-rate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clip.homevideo.json")
        try Sidecar.write(chain: chain, name: "clip", lookID: nil, to: url)

        // Strip every `rate`, as a file from before Rate has none.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var stripped = 0
        for key in ["layers", "audioLayers"] {
            guard let records = root[key] as? [[String: Any]] else { continue }
            root[key] = records.map { r -> [String: Any] in
                var r = r
                // Only the Damage layers' Rate is new. The preset's own mutes and dropouts had one.
                if (r["id"] as? String)?.contains("damage") == true, let ps = r["parameters"] as? [[String: Any]] {
                    let kept = ps.filter { ($0["id"] as? String) != "rate" }
                    stripped += ps.count - kept.count
                    r["parameters"] = kept
                }
                return r
            }
        }
        XCTAssertEqual(stripped, 12, "four picture and eight audio layers carried a rate")
        let old = folder.appendingPathComponent("old.homevideo.json")
        try JSONSerialization.data(withJSONObject: root).write(to: old)

        let a = SignalChain.standard(), b = SignalChain.standard()
        try Sidecar.read(url, into: a)
        try Sidecar.read(old, into: b)
        for (x, y) in zip(a.layers, b.layers) { XCTAssertEqual(x.parameters, y.parameters, x.id) }
        for (x, y) in zip(a.audio.allLayers, b.audio.allLayers) { XCTAssertEqual(x.parameters, y.parameters, x.id) }
        XCTAssertEqual(a.audio.spec, b.audio.spec)
        XCTAssertEqual(ChainFingerprint.of(a), ChainFingerprint.of(b))

        // And on the GPU, at an event frame of each layer, the two chains write the same bits.
        let g = try GPUHarness()
        let src = try g.source { x, y in (UInt8((x * 255) / 719), UInt8((y * 255) / 479), 128) }
        let ca = Self.chainLike(a.vhs!), cb = Self.chainLike(b.vhs!)
        for frame in Self.eventFrames(a.vhs!.damage) {
            XCTAssertEqual(try g.run(ca, src, frame: frame, raw: true).1, try g.run(cb, src, frame: frame, raw: true).1, "frame \(frame)")
        }
    }

    /// The standard chain's order: the picture events sit inside the chain, before the
    /// luma bandwidth and every later playback stage.
    func testThePictureEventsRunBeforeThePlaybackStages() {
        let chain = SignalChain.standard()
        let ids = chain.effects.map(\.id)
        let vhs = chain.vhs!
        let firstDamage = ids.firstIndex(of: "damage-clog")!
        let playback: [any Layer] = [vhs.luma, vhs.colorUnder, vhs.noise, vhs.dropouts, vhs.halo, vhs.headSwitch, vhs.timeBase]
        for later in playback {
            XCTAssertLessThan(firstDamage, ids.firstIndex(of: later.id)!, later.id)
        }
        XCTAssertLessThan(ids.firstIndex(of: vhs.compositeLink.id)!, firstDamage, "after the link into the deck")
        XCTAssertEqual(Set(ids), Set(vhs.all.map(\.id)), "the same layers, only the order moves")
        XCTAssertEqual(ids.count, vhs.all.count)
    }

    /// A chain over `vhs` in the standard order, framing the full raster (the GPU harness's).
    static func chainLike(_ vhs: VHSLayers) -> SignalChain {
        SignalChain(framing: FramingLayer(mode: .fullRaster), effects: vhs.all)
    }

    /// A frame inside an event of each picture layer, at its current Rate and seed.
    static func eventFrames(_ d: DamageLayers) -> [UInt64] {
        [30,
         (0..<UInt64(200_000)).first { d.tear.schedule.active(at: Double($0) / 29.97, ramp: 0.06).level > 0.5 } ?? 0,
         (0..<UInt64(200_000)).first { d.clog.gap(at: Double($0) / 29.97) > 0.4 * d.clog.strength } ?? 0,
         (0..<UInt64(20_000)).first { d.crease.position(at: Double($0) / 29.97).map { $0 > 0.2 && $0 < 0.8 } ?? false } ?? 0]
    }

    func testFullStrengthHitsFarHarder() {
        let tear = TrackingTearLayer(), crease = CreaseLayer(), snow = SnowLayer()
        // The clog's gap at full loses more than twice what a 0.5 um gap does.
        XCTAssertGreaterThan(HeadClogLayer.lossDB(gap: HeadClogLayer.maxGap), 2 * HeadClogLayer.lossDB(gap: 0.5))
        // The crease: full Strength folds many lines a field, not one.
        crease.setParameter("strength", to: .float(1))
        let t = crease.schedule.starts(from: 0, to: 600).first!.start + 1.4
        let creased = crease.lines(time: t).filter { $0.kind != .none }.count
        XCTAssertGreaterThan(creased, 8, "a fold several lines thick, \(creased) lines")
        // The tear: full Strength skews four times what Strength 0.25 does.
        func maxShift(_ s: Double) -> Float {
            tear.setParameter("strength", to: .float(s))
            let f = (0..<UInt64(200_000)).first { tear.schedule.active(at: Double($0) / 29.97, ramp: 0.06).level > 0.99 }!
            return tear.lines(time: Double(f) / 29.97).map { abs($0.shift) }.max()!
        }
        XCTAssertGreaterThan(maxShift(1), 3 * maxShift(0.25))
        // Snow: full Strength runs streaks past half a line.
        snow.setParameter("strength", to: .float(1))
        let longest = (0..<60).flatMap { snow.lines(time: 30 + Double($0) / 29.97) }.map { $0.end - $0.start }.max()!
        XCTAssertGreaterThan(longest, 360)
    }

    func testEventsAreSporadicNotSteady() {
        // Per 15 s stretch, a steady Poisson process at this rate would have a variance equal to
        // its mean. The clustering weight makes some stretches quiet and others bad.
        let s = DamageSchedule(salt: 9, seed: 5, ratePerSecond: 1, shortest: 0.05, longest: 0.2)
        let counts = (0..<400).map { Double(s.starts(from: Double($0) * 15, to: Double($0 + 1) * 15).count) }
        let mean = counts.reduce(0, +) / Double(counts.count)
        let variance = counts.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(counts.count)
        // 75 slots of 0.2 s, each 1 - exp(-0.2 w): about 12 a stretch after the thinning.
        XCTAssertEqual(mean, 12.2, accuracy: 1.5, "the long run rate holds")
        XCTAssertGreaterThan(variance, 4 * mean, "bursty: far more spread than a steady rate")
        XCTAssertGreaterThan(counts.filter { $0 <= 1 }.count, 40, "some stretches are nearly clean")
        // The weight's mean is 1.
        let ws = (0..<20_000).map { DamageSchedule.weight(salt: 3, seed: 1, at: Double($0) * 15) }
        XCTAssertEqual(ws.reduce(0, +) / Double(ws.count), 1, accuracy: 0.05)
    }

    func testAPausedFrameIsStable() {
        let d = DamageLayers()
        for l in d.all { l.setParameter("strength", to: .float(1)) }
        for t in [0.0, 3.3, 47.1] {
            XCTAssertEqual(d.snow.lines(time: t).map(\.floats), d.snow.lines(time: t).map(\.floats))
            XCTAssertEqual(d.tear.lines(time: t).map(\.floats), d.tear.lines(time: t).map(\.floats))
            XCTAssertEqual(d.crease.lines(time: t).map(\.floats), d.crease.lines(time: t).map(\.floats))
            XCTAssertEqual(d.clog.lines(time: t).map(\.floats), d.clog.lines(time: t).map(\.floats))
        }
    }

    func testTheCreaseScrollsDownAtTheTapesSpeed() {
        XCTAssertEqual(CreaseLayer.passSeconds(.sp), 2.90, accuracy: 0.01)
        XCTAssertEqual(CreaseLayer.passSeconds(.ep), 8.70, accuracy: 0.02)
        let c = CreaseLayer()
        let t0 = c.schedule.starts(from: 0, to: 600).first!.start
        let a = c.position(at: t0 + 0.5)!, b = c.position(at: t0 + 1.0)!
        XCTAssertGreaterThan(b, a, "down the picture")
        XCTAssertEqual((b - a) / 0.5, 1 / CreaseLayer.passSeconds(.sp), accuracy: 0.01)
    }

    func testClogLossIsWallace() {
        XCTAssertEqual(VHSGeometry.carrierWavelength, 1.487, accuracy: 0.001)
        XCTAssertEqual(HeadClogLayer.lossDB(gap: 0.5), 18.36, accuracy: 0.05)
    }

    // MARK: Picture on the GPU

    func testEachPictureLayerOffLeavesTheFrameAndOnChangesAnEventFrame() throws {
        let g = try GPUHarness()
        let src = try g.source { x, y in (UInt8((x * 255) / 719), UInt8((y * 255) / 479), 128) }
        let vhs = VHSLayers()
        let withDamage = Self.chainLike(vhs)
        let without = SignalChain(framing: FramingLayer(mode: .fullRaster),
                                  effects: vhs.all.filter { !($0 is any DamageLayer) })
        // Static where it can be, so two runs of one frame compare exactly.
        let (offBits, plainBits) = (try g.run(withDamage, src, frame: 30, raw: true).1,
                                    try g.run(without, src, frame: 30, raw: true).1)
        XCTAssertEqual(offBits, plainBits, "every Damage layer off: the frame is bit identical")

        let d = vhs.damage
        for l in d.all { l.setParameter("strength", to: .float(1)) }
        // A Rate far from the default, so the determinism check covers it.
        d.tear.setParameter("rate", to: .float(40))
        d.clog.setParameter("rate", to: .float(12))
        d.crease.setParameter("rate", to: .float(20))
        d.snow.setParameter("rate", to: .float(900))
        let events: [(any Layer, UInt64)] = [
            (d.snow, 30),
            (d.tear, try XCTUnwrap((0..<UInt64(200_000)).first { d.tear.schedule.active(at: Double($0) / 29.97, ramp: 0.06).level > 0.5 })),
            (d.clog, try XCTUnwrap((0..<UInt64(200_000)).first { d.clog.gap(at: Double($0) / 29.97) > 0.2 })),
            (d.crease, try XCTUnwrap((0..<UInt64(20_000)).first { d.crease.position(at: Double($0) / 29.97).map { $0 > 0.2 && $0 < 0.8 } ?? false })),
        ]
        for (layer, frame) in events {
            let plain = try g.run(without, src, frame: frame, raw: true).1
            layer.enabled = true
            let on = try g.run(withDamage, src, frame: frame, raw: true).1
            let again = try g.run(withDamage, src, frame: frame, raw: true).1
            layer.enabled = false
            let changed = zip(on, plain).filter { $0 != $1 }.count
            XCTAssertGreaterThan(changed, 2_000, "\(layer.id) at frame \(frame) changed \(changed) values")
            XCTAssertEqual(on, again, "\(layer.id): the same frame renders the same")
        }
    }

    // MARK: Audio

    func tone(_ hz: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        (0..<Int(seconds * Self.rate)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / Self.rate)) }
    }

    func run(_ p: AudioChainProcessor, _ x: [Float]) -> [Float] {
        var b = [x]
        var start = 0
        while start < x.count {
            let n = min(512, x.count - start)
            AudioBlock.withPlanar(&b, range: start..<(start + n)) { p.process($0) }
            start += n
        }
        return b[0]
    }

    /// The tone's amplitude in `x` over [t, t + 0.05) s (single bin, Hann window).
    func amplitude(_ x: [Float], hz: Double, at t: Double) -> Double {
        let a = Int(t * Self.rate), n = Int(0.05 * Self.rate)
        var re = 0.0, im = 0.0, wsum = 0.0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
            let ph = 2 * .pi * hz * Double(a + i) / Self.rate
            re += Double(x[a + i]) * w * cos(ph)
            im += Double(x[a + i]) * w * sin(ph)
            wsum += w
        }
        return 2 * (re * re + im * im).squareRoot() / wsum
    }

    func spec(_ kind: AudioLayerKind, _ values: [String: ParameterValue]) -> AudioChainSpec {
        var s = AudioLayerSpec.defaults(kind)
        for (k, v) in values { s.values[k] = v }
        return AudioChainSpec(layers: [s])
    }

    func testAudioDamageOffLeavesTheSoundByteIdentical() {
        // Hi-Fi named: the default chain plays a linear track, and this holds Hi-Fi to its defaults.
        let chain = AudioChain(preset: .hifi)
        XCTAssertEqual(chain.spec, AudioChainSpec.defaults(.hifi), "the spec is Hi-Fi's defaults with every Damage layer off")
        let x = tone(1_000, seconds: 1)
        XCTAssertEqual(run(chain.makeProcessor(sampleRate: Self.rate, channels: 1), x),
                       run(AudioChainProcessor(spec: .defaults(.hifi), sampleRate: Self.rate, channels: 1), x))
        func layer(_ id: String) -> AudioLayer { chain.damage.first { $0.id == id }! }
        chain.preset = .off
        layer("audio-damage-flutter").enabled = true
        XCTAssertTrue(chain.isPassthrough, "Off stays untouched even with Damage on")
        chain.preset = .linear
        layer("audio-damage-hifi").enabled = true
        XCTAssertFalse(chain.spec.layers.contains { $0.kind == .hifiDropoutBurst }, "the Hi-Fi dropout runs only on Hi-Fi")
        XCTAssertTrue(chain.spec.layers.contains { $0.kind == .flutterBurst })
    }

    func testAzimuthLossFollowsTheSincAtTheEventsPeak() {
        // The standard formula: 30 arcmin on a 1 mm track at 33.34 mm/s nulls at 3.8 kHz.
        let dt = AzimuthWander.boxcar(arcmin: 30, speed: 33.34)
        XCTAssertEqual(1 / dt, 3_820, accuracy: 20)
        XCTAssertLessThan(AzimuthWander.lossDB(hz: 3_000, arcmin: 30, speed: 33.34), -10)
        XCTAssertEqual(AzimuthWander.lossDB(hz: 1_000, arcmin: 2, speed: 33.34), 0, accuracy: 0.01, "McKnight's wander alone")

        let s = spec(.azimuthWander, ["strength": .float(1), "seed": .float(4)])
        let p = AzimuthWander(spec: s.layers[0], sampleRate: Self.rate, channels: 1)
        let e = try! XCTUnwrap(p.schedule.starts(from: 0, to: 600).first)
        let mid = e.start + e.length / 2
        let seconds = mid + 0.2
        let hz = 3_000.0
        let out = run(AudioChainProcessor(spec: s, sampleRate: Self.rate, channels: 1), tone(hz, seconds: seconds))
        let err = p.error(at: mid + 0.025, events: [e])
        let expected = AzimuthWander.lossDB(hz: hz, arcmin: err, speed: 33.34)
        let measured = 20 * log10(amplitude(out, hz: hz, at: mid) / 0.5)
        XCTAssertLessThan(expected, -4, "the peak takes the highs down")
        XCTAssertEqual(measured, expected, accuracy: 1.0, "error \(err) arcmin")
        XCTAssertEqual(20 * log10(amplitude(out, hz: hz, at: max(0.1, e.start - 1)) / 0.5), 0, accuracy: 0.5,
                       "outside the episode the highs are back")
    }

    func testClogMufflesByWallace() {
        XCTAssertEqual(ClogMuffle.lossDB(hz: 10_000, gap: 2, speed: 33.34), 32.75, accuracy: 0.05)
        let s = spec(.clogMuffle, ["strength": .float(1), "seed": .float(2), "follow": .bool(false)])
        let p = ClogMuffle(spec: s.layers[0], sampleRate: Self.rate, channels: 1)
        let e = try! XCTUnwrap(p.schedule.starts(from: 0, to: 900).first)
        let mid = e.start + e.length / 2
        let out = run(AudioChainProcessor(spec: s, sampleRate: Self.rate, channels: 1), tone(2_000, seconds: mid + 0.2))
        let gap = p.schedule.active(at: mid, ramp: HeadClogTiming.ramp).level * 2
        let expected = -ClogMuffle.lossDB(hz: 2_000, gap: gap, speed: 33.34)
        XCTAssertEqual(20 * log10(amplitude(out, hz: 2_000, at: mid) / 0.5), expected, accuracy: 1.0)
        XCTAssertEqual(20 * log10(amplitude(out, hz: 2_000, at: max(0.1, e.start - 1)) / 0.5), 0, accuracy: 0.3)
    }

    func testHiFiDropoutFallsToTheLinearBand() {
        let s = spec(.hifiDropoutBurst, ["strength": .float(1), "seed": .float(1)])
        let p = HiFiDropoutBurst(spec: s.layers[0], sampleRate: Self.rate, channels: 1)
        let bursts = p.bursts.starts(from: 0, to: 1_200)
        // 19 kHz is past the linear track's 10 kHz lowpass (4th order, -22 dB there): inside a
        // drop it is gone.
        let hz = 19_000.0
        // A chattering burst: inside one of its drops.
        let chatter = try! XCTUnwrap(bursts.first { $0.u >= HiFiDropoutBurst.solidShare })
        let drop = try! XCTUnwrap(p.drops.events(from: chatter.start, to: chatter.end)
            .first { $0.start > chatter.start && $0.end < chatter.end && $0.length > 0.07 })
        // A solid burst: held on linear for its whole length, seconds of it.
        let solid = try! XCTUnwrap(bursts.first { $0.u < HiFiDropoutBurst.solidShare && $0.length > 1 })
        let out = run(AudioChainProcessor(spec: s, sampleRate: Self.rate, channels: 1),
                      tone(hz, seconds: max(drop.end, solid.end) + 0.5))
        let first = min(chatter.start, solid.start)
        XCTAssertEqual(20 * log10(amplitude(out, hz: hz, at: max(0.1, first - 1)) / 0.5), 0, accuracy: 0.3)
        XCTAssertLessThan(20 * log10(amplitude(out, hz: hz, at: drop.start + 0.01) / 0.5), -15,
                          "the linear track has no 19 kHz")
        for x in [0.2, 0.5, 0.8] {
            XCTAssertLessThan(20 * log10(amplitude(out, hz: hz, at: solid.start + x * (solid.length - 0.05)) / 0.5), -15,
                              "a solid burst stays on linear")
        }
    }

    func testWowGlideSagsThenCatchesUpAndEndsInPhase() {
        let s = spec(.wowGlide, ["strength": .float(1), "seed": .float(2)])
        let p = WowGlide(spec: s.layers[0], sampleRate: Self.rate, channels: 1)
        let e = try! XCTUnwrap(p.schedule.starts(from: 0, to: 600).first)
        let x = tone(1_000, seconds: e.end + 0.5)
        let out = run(AudioChainProcessor(spec: s, sampleRate: Self.rate, channels: 1), x)
        /// Mean zero crossing period in [a, b), relative to 1 ms, percent.
        func deviation(_ a: Double, _ b: Double) -> Double {
            var ts: [Double] = []
            for i in Int(a * Self.rate)..<Int(b * Self.rate) where out[i - 1] < 0 && out[i] >= 0 {
                ts.append(Double(i - 1) + Double(-out[i - 1] / (out[i] - out[i - 1])))
            }
            return ((ts.last! - ts.first!) / Double(ts.count - 1) / Self.rate - 0.001) / 0.001 * 100
        }
        let q = e.length / 4
        XCTAssertGreaterThan(deviation(e.start + q - 0.02, e.start + q + 0.02), 2, "the pitch sags first (a longer period)")
        XCTAssertLessThan(deviation(e.end - q - 0.02, e.end - q + 0.02), -2, "then the servo catches up")
        // In phase again: after the glide the output is the input, sample for sample.
        let a = Int((e.end + 0.01) * Self.rate)
        XCTAssertEqual(Array(out[a..<(a + 4_800)]), Array(x[a..<(a + 4_800)]))
    }

    func testWornStretchJumpsTheHissFloor() {
        let s = spec(.wornStretch, ["strength": .float(1), "seed": .float(1)])
        let p = WornStretch(spec: s.layers[0], sampleRate: Self.rate, channels: 1)
        let e = try! XCTUnwrap(p.schedule.starts(from: 2, to: 900).first {
            $0.length > 3 && $0.start - quietBefore(p.schedule, $0) > 1 })
        let out = run(AudioChainProcessor(spec: s, sampleRate: Self.rate, channels: 1),
                      [Float](repeating: 0, count: Int((e.end + 0.5) * Self.rate)))
        func rmsDB(_ t: Double) -> Double {
            let a = Int(t * Self.rate), n = Int(0.5 * Self.rate)
            let ms = out[a..<(a + n)].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(n)
            return 10 * log10(ms + 1e-30)
        }
        // Strength 1 is twice the jump of Strength 0.5.
        XCTAssertEqual(rmsDB(e.start + e.length / 2 - 0.25), WornStretch.floorDB + 2 * WornStretch.jumpDB, accuracy: 1)
        let quiet = quietBefore(p.schedule, e)
        XCTAssertLessThan(rmsDB(quiet + (e.start - quiet) / 2 - 0.25), -200, "silence outside the stretch")
    }

    /// The end of the last event before `e` (0 when none): from there to `e.start` is quiet.
    func quietBefore(_ s: DamageSchedule, _ e: DamageSchedule.Event) -> Double {
        max(0, s.events(from: 0, to: e.start).filter { $0.index != e.index }.map(\.end).max() ?? 0)
    }

    func testCrackleAndMuteLandInsideTheirEventsOnly() {
        let c = spec(.crackleBurst, ["strength": .float(1), "seed": .float(3)])
        let pc = CrackleBurst(spec: c.layers[0], sampleRate: Self.rate, channels: 1)
        let e = try! XCTUnwrap(pc.schedule.starts(from: 1, to: 600).first { $0.start - quietBefore(pc.schedule, $0) > 0.5 })
        let out = run(AudioChainProcessor(spec: c, sampleRate: Self.rate, channels: 1),
                      [Float](repeating: 0, count: Int((e.end + 0.5) * Self.rate)))
        let inside = out[Int(e.start * Self.rate)..<Int(e.end * Self.rate)]
        XCTAssertGreaterThan(inside.map(abs).max()!, Float(pow(10, -36.0 / 20)), "pops inside the burst")
        XCTAssertGreaterThan(inside.filter { abs($0) > 1e-3 }.count, 30)
        let q = quietBefore(pc.schedule, e)
        XCTAssertTrue(out[Int((q + 0.1) * Self.rate)..<Int((e.start - 0.01) * Self.rate)].allSatisfy { $0 == 0 },
                      "nothing between bursts")

        let m = spec(.muteDrop, ["strength": .float(1), "seed": .float(4)])
        let pm = MuteDrop(spec: m.layers[0], sampleRate: Self.rate, channels: 1)
        let d = try! XCTUnwrap(pm.schedule.starts(from: 1, to: 600).first { $0.start - quietBefore(pm.schedule, $0) > 0.6 })
        let x = tone(500, seconds: d.end + 0.5)
        let muted = run(AudioChainProcessor(spec: m, sampleRate: Self.rate, channels: 1), x)
        let mid = Int((d.start + d.length / 2) * Self.rate)
        XCTAssertTrue(muted[(mid - 100)..<(mid + 100)].allSatisfy { $0 == 0 }, "silence in the middle of the dropout")
        let b = Int((d.start - 0.5) * Self.rate)
        XCTAssertEqual(Array(muted[b..<(b + 4_800)]), Array(x[b..<(b + 4_800)]), "untouched before it")
    }

    func testEveryAudioLayerIsDeterministicAndBlocksDoNotMatter() {
        // Every Damage layer on at Strength 1: two runs, and a run cut into other block sizes,
        // give the same samples (the preview's tap and the export cut audio differently).
        let chain = AudioChain()
        for l in chain.damage {
            l.enabled = true
            l.setParameter("strength", to: .float(1))
            l.setParameter("seed", to: .float(11))
        }
        let x = tone(1_000, seconds: 12)
        func render(block: Int) -> [Float] {
            let p = chain.makeProcessor(sampleRate: Self.rate, channels: 1)
            var b = [x]
            var start = 0
            while start < x.count {
                let n = min(block, x.count - start)
                AudioBlock.withPlanar(&b, range: start..<(start + n)) { p.process($0) }
                start += n
            }
            return b[0]
        }
        let a = render(block: 512)
        XCTAssertNotEqual(a, x, "the layers did something")
        XCTAssertEqual(a, render(block: 512), "the same seed and strength: the same samples")
        XCTAssertEqual(a, render(block: 333), "and the block size does not matter")
    }

    func testFlutterBurstDeviatesThePitch() {
        let s = spec(.flutterBurst, ["strength": .float(1), "seed": .float(3)])
        let p = FlutterBurst(spec: s.layers[0], sampleRate: Self.rate, channels: 1)
        let e = try! XCTUnwrap(p.schedule.starts(from: 2, to: 600).first)
        let out = run(AudioChainProcessor(spec: s, sampleRate: Self.rate, channels: 1),
                      tone(1_000, seconds: e.end + 0.5))
        /// Peak deviation of the zero crossing period from 1 ms over [a, b), percent.
        func deviation(_ a: Double, _ b: Double) -> Double {
            var last: Double?, worst = 0.0
            for i in Int(a * Self.rate)..<Int(b * Self.rate) where out[i - 1] < 0 && out[i] >= 0 {
                let t = Double(i - 1) + Double(-out[i - 1] / (out[i] - out[i - 1]))
                if let l = last { worst = max(worst, abs((t - l) / Self.rate - 0.001) / 0.001 * 100) }
                last = t
            }
            return worst
        }
        let mid = e.start + e.length / 2
        let before = p.schedule.events(from: 0, to: e.start).last?.end ?? 0
        let inside = deviation(mid - 0.1, mid + 0.1)
        let outside = deviation(max(0.05, before + 0.1), max(before + 0.4, e.start - 0.05))
        XCTAssertGreaterThan(inside, 0.5, "a burst at Strength 1 flutters past half a percent")
        XCTAssertLessThan(inside, FlutterBurst.maxDepthPercent * 2)
        XCTAssertLessThan(outside, 0.05, "and the tone is steady outside it")
    }
}
