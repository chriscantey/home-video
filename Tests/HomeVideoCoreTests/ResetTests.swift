import XCTest
@testable import HomeVideoCore

/// Reset puts every layer, Damage included, back to the shown Look (a built-in Look or a
/// saved preset), the chain reads back as that Look, and the button lights only on drift.
@MainActor
final class ResetTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-reset-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        Looks.user = []
    }

    /// Every switch and every parameter of every video, audio and Damage layer equals the Look's
    /// reference chain.
    func assertEveryLayerMatches(_ chain: SignalChain, _ look: Look, file: StaticString = #filePath, line: UInt = #line) {
        let ref = Looks.reference(look)
        let vhs = chain.vhs!
        XCTAssertEqual(vhs.all.count, ref.vhs.all.count, file: file, line: line)
        for (a, b) in zip(vhs.all, ref.vhs.all) {
            XCTAssertEqual(Looks.userSwitch(a), Looks.userSwitch(b), a.id, file: file, line: line)
            XCTAssertEqual(a.parameters.map(\.id), b.parameters.map(\.id), a.id, file: file, line: line)
            for (p, q) in zip(a.parameters, b.parameters) {
                XCTAssertTrue(Looks.same(p.value, q.value), "\(a.id).\(p.id) \(p.value) vs \(q.value)", file: file, line: line)
            }
        }
        XCTAssertEqual(chain.audio.preset, ref.audio.preset, file: file, line: line)
        XCTAssertEqual(chain.audio.allLayers.count, ref.audio.allLayers.count, file: file, line: line)
        for (a, b) in zip(chain.audio.allLayers, ref.audio.allLayers) {
            XCTAssertEqual(a.enabled, b.enabled, a.id, file: file, line: line)
            for (p, q) in zip(a.parameters, b.parameters) {
                XCTAssertTrue(Looks.same(p.value, q.value), "\(a.id).\(p.id) \(p.value) vs \(q.value)", file: file, line: line)
            }
        }
    }

    /// A Tune slider nudged, a picture Damage layer and an audio Damage layer switched on.
    func drift(_ chain: SignalChain) {
        chain.vhs!.noise.setParameter("luma", to: .float(41.5))
        chain.vhs!.damage.snow.enabled = true
        chain.audio.damage.first!.enabled = true
    }

    func testResetBringsABuiltInLookBackDamageIncluded() throws {
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        let look = try XCTUnwrap(Looks.look(id: "s-vhs"))
        presets.setLook(look)
        XCTAssertFalse(LookReset.drifted(presets, from: look))

        drift(chain)
        XCTAssertTrue(LookReset.drifted(presets, from: look))
        // While the picker reads Custom, the Look behind the chain is still the target.
        XCTAssertEqual(LookReset.target(presets, behindID: "s-vhs")?.id, "s-vhs")

        LookReset.reset(presets, to: look)
        assertEveryLayerMatches(chain, look)
        XCTAssertFalse(chain.vhs!.damage.snow.enabled)
        XCTAssertFalse(chain.audio.damage.first!.enabled)
        XCTAssertEqual(presets.look?.id, "s-vhs")
        XCTAssertFalse(LookReset.drifted(presets, from: look))
    }

    /// Damage set before a Look change goes too.
    func testResetClearsDamageThatRodeIn() throws {
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        drift(chain)
        let look = try XCTUnwrap(Looks.look(id: "s-vhs"))
        presets.setLook(look)
        LookReset.reset(presets, to: look)
        assertEveryLayerMatches(chain, look)
        XCTAssertEqual(presets.look?.id, "s-vhs")
    }

    func testResetBringsAUserPresetBack() throws {
        let store = UserPresets(folder: folder)
        let source = SignalChain.standard()
        let sp = Presets(vhs: source.vhs!, audio: source.audio)
        sp.setLook(Looks.look(id: "rental")!)
        source.vhs!.luma.setParameter("cut", to: .float(2.137))
        source.vhs!.damage.clog.enabled = true
        let preset = try store.save(name: "Clogged Rental", chain: source)
        let look = try XCTUnwrap(Looks.anyLook(id: preset.id))

        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        presets.setLook(look)
        XCTAssertEqual(presets.look?.id, preset.id)
        drift(chain)
        chain.vhs!.damage.clog.enabled = false
        XCTAssertNil(presets.look)
        XCTAssertTrue(LookReset.drifted(presets, from: look))
        XCTAssertEqual(LookReset.target(presets, behindID: preset.id)?.id, preset.id)

        LookReset.reset(presets, to: look)
        assertEveryLayerMatches(chain, look)
        XCTAssertTrue(chain.vhs!.damage.clog.enabled)
        XCTAssertEqual(presets.look?.id, preset.id)
    }

    /// The button's rule, pure: lit only with a Look behind the chain and drift.
    func testEnabledRule() {
        XCTAssertTrue(LookReset.isEnabled(hasLook: true, drifted: true))
        XCTAssertFalse(LookReset.isEnabled(hasLook: true, drifted: false))
        XCTAssertFalse(LookReset.isEnabled(hasLook: false, drifted: true))
        XCTAssertFalse(LookReset.isEnabled(hasLook: false, drifted: false))

        // Custom with no Look behind it has no target, so the button stays off.
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        chain.vhs!.noise.setParameter("luma", to: .float(41.5))
        XCTAssertNil(presets.look)
        XCTAssertNil(LookReset.target(presets, behindID: nil))
        XCTAssertNil(LookReset.target(presets, behindID: "no-such-look"))
        XCTAssertEqual(LookReset.help(nil), "Reset to Look: choose a Look first")
        XCTAssertEqual(LookReset.help(Looks.look(id: "s-vhs")), "Back to S-VHS")
    }

    // MARK: Fresh start

    /// Every stage on, every settings layer's first slider at its top, Framing and the Output
    /// size moved, a Look picked, Damage on, the sound changed: everything a person can touch.
    func moveEverything(_ chain: SignalChain, _ stages: StageSwitches) {
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        presets.setLook(Looks.look(id: "pro-scan")!)
        for stage in ChainStage.allCases { stages.set(stage, on: true) }
        for layer in chain.settingsLayers {
            if let p = layer.parameters.first(where: { $0.value.doubleValue != nil }) {
                layer.setParameter(p.id, to: .float(p.range.upperBound))
            }
        }
        chain.vhs!.output.setParameter("size", to: .choice(OutputSize.custom.rawValue))
        chain.vhs!.damage.snow.enabled = true
        chain.audio.preset = .hifi
        chain.audio.damage.first!.enabled = true
        chain.audio.setMicStrength(0.5)
    }

    /// Reset from a chain with every stage on and moved gives a chain identical to a fresh
    /// launch: the same fingerprint, the same settings in every layer a setting can name (the
    /// hidden stages included), Fresh SP, only Tape and Audio on, so only their tabs show.
    func testFreshStartFromEverythingMoved() {
        let fresh = SignalChain.standard()
        let chain = SignalChain.standard()
        let stages = StageSwitches(chain: chain)
        XCTAssertFalse(FreshStart.drifted(chain), "a fresh launch has nothing to reset")
        moveEverything(chain, stages)
        XCTAssertNotEqual(ChainFingerprint.of(chain), ChainFingerprint.of(fresh))
        XCTAssertEqual(ChainStage.strip.filter(stages.switchIsOn), ChainStage.strip, "every stage on before")
        XCTAssertTrue(FreshStart.drifted(chain))

        FreshStart.reset(chain, switches: stages)
        XCTAssertEqual(ChainFingerprint.of(chain), ChainFingerprint.of(fresh))
        XCTAssertEqual(SettingsClipboard.encode(chain), SettingsClipboard.encode(fresh))
        XCTAssertEqual(Sidecar.snapshot(of: chain, lookID: nil), Sidecar.snapshot(of: fresh, lookID: nil))
        XCTAssertFalse(FreshStart.drifted(chain))
        XCTAssertEqual(Presets(vhs: chain.vhs!, audio: chain.audio).look?.id, "clean-sp")
        XCTAssertEqual(ChainStage.allCases.filter(stages.switchIsOn), [.tape, .audio])
        XCTAssertEqual(SidebarTab.visible(stages), [.look, .stage(.tape), .stage(.audio)])
        XCTAssertTrue(chain.vhs!.output.isAuto)
    }

    /// What the Display and Audio switches held is dropped: after Reset, the Display on gives
    /// every CRT layer and the Audio on gives the default track, as after a fresh launch.
    func testFreshStartForgetsWhatTheSwitchesHeld() {
        let chain = SignalChain.standard()
        let stages = StageSwitches(chain: chain)
        stages.set(.display, on: true)
        chain.vhs!.crt.layers.first!.enabled = false
        stages.set(.display, on: false)
        chain.audio.preset = .hifi
        stages.set(.audio, on: false)

        FreshStart.reset(chain, switches: stages)
        let fresh = SignalChain.standard()
        let freshStages = StageSwitches(chain: fresh)
        for s in [stages, freshStages] {
            s.set(.display, on: true)
            s.set(.audio, on: false)
            s.set(.audio, on: true)
        }
        XCTAssertTrue(chain.vhs!.crt.layers.allSatisfy(\.enabled), "every CRT layer, nothing held")
        XCTAssertEqual(ChainFingerprint.of(chain), ChainFingerprint.of(fresh))
    }

    /// The clip's rotation comes from its track, so Reset leaves it.
    func testFreshStartKeepsTheClipsRotation() {
        let chain = SignalChain.standard()
        chain.framing.rotation = 90
        FreshStart.reset(chain, switches: StageSwitches(chain: chain))
        XCTAssertEqual(chain.framing.rotation, 90)
    }
}
