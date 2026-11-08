import XCTest
@testable import HomeVideoCore

/// Shuffle rolls a random tape on a built-in Look, inside every range, the same chain for
/// the same seed, framing untouched, the Looks themselves never moved, and Reset's way back.
@MainActor
final class ShuffleTests: XCTestCase {
    /// Every layer's switch and parameters, picture then audio, with the audio preset.
    struct Snapshot: Equatable {
        var layers: [String]
        var switches: [Bool?]
        var parameters: [[LayerParameter]]
        var preset: AudioPreset?
    }

    func snapshot(_ vhs: VHSLayers, _ audio: AudioChain?) -> Snapshot {
        var s = Snapshot(layers: [], switches: [], parameters: [], preset: audio?.preset)
        for l in vhs.all {
            s.layers.append(l.id); s.switches.append(Looks.userSwitch(l)); s.parameters.append(l.parameters)
        }
        for l in audio?.allLayers ?? [] {
            s.layers.append(l.id); s.switches.append(l.enabled); s.parameters.append(l.parameters)
        }
        return s
    }

    func fresh() -> Presets { Presets(vhs: VHSLayers(), audio: AudioChain()) }

    func testFiftyRollsStayInRangeAndDrift() {
        var drifted = 0
        var bases = Set<String>()
        for seed in UInt64(1)...50 {
            let presets = fresh()
            let basis = Shuffle.roll(presets, seed: seed)
            bases.insert(basis.id)
            XCTAssertNotNil(Looks.look(id: basis.id), "seed \(seed): the basis is a built-in Look")
            let params = presets.vhs.all.flatMap { l in l.parameters.map { (l.id, $0) } }
                + presets.audio!.allLayers.flatMap { l in l.parameters.map { (l.id, $0) } }
            for (layer, p) in params {
                switch p.value {
                case .float(let v):
                    XCTAssertTrue(p.range.contains(v), "seed \(seed): \(layer).\(p.id) \(v) outside \(p.range)")
                case .choice(let c):
                    XCTAssertTrue(p.options.contains { $0.value == c }, "seed \(seed): \(layer).\(p.id) \(c)")
                case .bool:
                    break
                }
            }
            XCTAssertNotEqual(presets.audio!.preset, .off, "seed \(seed)")
            if LookReset.drifted(presets, from: basis) { drifted += 1 }
        }
        XCTAssertGreaterThanOrEqual(drifted, 45)
        XCTAssertGreaterThan(bases.count, 1, "the basis Look varies with the seed")
    }

    func testSameSeedSameChainDifferentSeedsDiffer() {
        let a = fresh(), b = fresh(), c = fresh()
        // A chain moved first still rolls the same: the roll starts from the basis Look.
        b.vhs.noise.setParameter("luma", to: .float(41.5))
        b.vhs.damage.snow.enabled = true
        Shuffle.roll(a, seed: 7)
        Shuffle.roll(b, seed: 7)
        XCTAssertEqual(snapshot(a.vhs, a.audio), snapshot(b.vhs, b.audio))

        let one = fresh(), two = fresh()
        Shuffle.roll(one, seed: 1)
        Shuffle.roll(two, seed: 2)
        XCTAssertNotEqual(snapshot(one.vhs, one.audio), snapshot(two.vhs, two.audio))
        Shuffle.roll(c, seed: 2)
        XCTAssertEqual(snapshot(c.vhs, c.audio), snapshot(two.vhs, two.audio))
    }

    func testFramingIsNeverTouched() {
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        chain.framing.mode = .letterbox
        chain.framing.pan = 0.3
        chain.framing.panY = -0.2
        chain.framing.zoom = 1.4
        chain.framing.rotation = 90
        let before = chain.framing.parameters
        for seed in UInt64(1)...20 { Shuffle.roll(presets, seed: seed) }
        XCTAssertEqual(chain.framing.parameters, before)
        XCTAssertEqual(chain.framing.mode, .letterbox)
        XCTAssertEqual(chain.framing.zoom, 1.4)
        XCTAssertEqual(chain.framing.rotation, 90)
    }

    /// The rolls move the chain they are handed, never a Look's reference chain.
    func testLooksAreNeverMutated() {
        for seed in UInt64(1)...50 { Shuffle.roll(fresh(), seed: seed) }
        for look in Looks.all {
            let cached = Looks.reference(look)
            let was = snapshot(cached.vhs, cached.audio)
            Looks.references[look.id] = nil
            let rebuilt = Looks.reference(look)
            XCTAssertEqual(was, snapshot(rebuilt.vhs, rebuilt.audio), look.id)
        }
    }

    /// After a roll the picker reads Custom (in practice: the drift is on a listed slider or a
    /// switch, not Damage alone) and Reset with the basis behind it puts the Look back.
    func testResetGoesBackToTheBasis() {
        var custom = 0
        for seed in UInt64(1)...50 {
            let presets = fresh()
            let basis = Shuffle.roll(presets, seed: seed)
            if presets.look == nil {
                custom += 1
                XCTAssertEqual(LookReset.target(presets, behindID: basis.id)?.id, basis.id, "seed \(seed)")
            }
            LookReset.reset(presets, to: basis)
            XCTAssertFalse(LookReset.drifted(presets, from: basis), "seed \(seed)")
            // The picker reads a Look again (an earlier Look that differs only in Damage reads first).
            XCTAssertNotNil(presets.look, "seed \(seed)")
        }
        XCTAssertGreaterThanOrEqual(custom, 45)
    }

    /// A Damage layer the roll switches on sits mid range with a whole Seed.
    func testDamageComesOnMidRange() {
        var on = 0
        for seed in UInt64(1)...50 {
            let presets = fresh()
            let basis = Shuffle.roll(presets, seed: seed)
            let ref = Looks.reference(basis)
            for (l, r) in zip(presets.vhs.damage.all, ref.vhs.damage.all) where l.enabled && !r.enabled {
                on += 1
                let s = l.parameters.first { $0.id == "strength" }!.value.doubleValue!
                XCTAssertTrue((0.3 - 1e-9)...(0.6 + 1e-9) ~= s, "seed \(seed): \(l.id) strength \(s)")
                let sd = l.parameters.first { $0.id == "seed" }!.value.doubleValue!
                XCTAssertEqual(sd, sd.rounded())
            }
            for (l, r) in zip(presets.audio!.damage, ref.audio.damage) where l.enabled && !r.enabled {
                on += 1
                let s = l.value("strength")!.doubleValue!
                XCTAssertTrue((0.3 - 1e-9)...(0.6 + 1e-9) ~= s, "seed \(seed): \(l.id) strength \(s)")
            }
        }
        XCTAssertGreaterThan(on, 0, "some rolls switch Damage on")
    }

    func testGeneratorAndHelp() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42), c = SplitMix64(seed: 43)
        let x = (0..<8).map { _ in a.next() }
        XCTAssertEqual(x, (0..<8).map { _ in b.next() })
        XCTAssertNotEqual(x, (0..<8).map { _ in c.next() })
        XCTAssertEqual(Shuffle.help, "Shuffle: roll a random tape")
        let dash = String(UnicodeScalar(0x2014)!)
        XCTAssertFalse(Shuffle.help.contains(dash))
        XCTAssertNotEqual(Shuffle.freshSeed(), Shuffle.freshSeed())
    }
}
