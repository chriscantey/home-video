import Foundation
@testable import HomeVideoCore
import XCTest

/// The stage UI. The Tape switch carries the sound track, so Tape
/// off plays the mic alone wherever the switch is set from.
@MainActor
final class StageLiveTests: XCTestCase {
    /// The Tape switch moves the audio chain's `tapeIsOn` both ways, and Tape off leaves only the
    /// mic in the audio spec.
    func testTapeSwitchCarriesTheTrack() {
        let chain = SignalChain.standard()
        chain.audio.preset = .camcorder
        XCTAssertTrue(chain.audio.tapeIsOn)
        let withTape = chain.audio.spec
        chain.vhs!.tape.enabled = false
        XCTAssertFalse(chain.audio.tapeIsOn)
        XCTAssertEqual(chain.audio.spec.layers.map(\.kind), [.camcorderMic])
        XCTAssertNotEqual(chain.audio.spec, withTape)
        chain.vhs!.tape.enabled = true
        XCTAssertTrue(chain.audio.tapeIsOn)
        XCTAssertEqual(chain.audio.spec, withTape)
    }

    /// The Tape switch set by `--set tape=off`, a Look, or a sidecar reaches the sound too.
    func testEveryRouteToTapeOffDropsTheTrack() throws {
        let set = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--set", "tape=off"]).apply(to: set)
        XCTAssertFalse(set.audio.tapeIsOn)

        let look = SignalChain.standard()
        let presets = Presets(vhs: look.vhs!, audio: look.audio)
        presets.setLook(Looks.look(id: "super8-kodachrome")!)
        XCTAssertFalse(look.vhs!.tape.enabled)
        XCTAssertFalse(look.audio.tapeIsOn, "the film Looks set the Tape off, so their sound is the mic alone")
        presets.setLook(Looks.look(id: "clean-sp")!)
        XCTAssertTrue(look.audio.tapeIsOn)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.homevideo.json")
        let a = SignalChain.standard()
        a.vhs!.tape.enabled = false
        try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, to: url)
        let b = SignalChain.standard()
        _ = try Sidecar.read(url, into: b)
        XCTAssertFalse(b.audio.tapeIsOn)
    }

    // MARK: Rooms and switches

    /// A click opens a room, never turns it on: every tab chosen in turn leaves the chain
    /// exactly as it was, a stage switched on stays on while another room shows, and switching
    /// a stage off leaves its room showing.
    func testAClickOpensARoomAndNeverTurnsItOn() {
        let chain = SignalChain.standard()
        let stages = StageSwitches(chain: chain)
        let rooms = StageRooms()
        XCTAssertEqual(rooms.selected, .look, "the Look tab shows at launch")
        let print = ChainFingerprint.of(chain)
        for tab in SidebarTab.all {
            rooms.choose(tab)
            XCTAssertEqual(rooms.selected, tab)
            XCTAssertEqual(ChainFingerprint.of(chain), print, "opening \(tab.title) changes nothing")
        }
        XCTAssertFalse(stages.isOn(.film))
        XCTAssertFalse(stages.isOn(.display))
        XCTAssertFalse(stages.switchIsOn(.telecine))
        // The room's switch is what turns it on.
        rooms.choose(.stage(.film))
        stages.toggle(.film)
        XCTAssertTrue(stages.isOn(.film))
        rooms.choose(.stage(.tape))
        XCTAssertTrue(stages.isOn(.film), "another room keeps the stage on")
        rooms.choose(.stage(.audio))
        stages.set(.audio, on: false)
        // Off takes the tab away, so the Look tab opens.
        rooms.follow(SidebarTab.visible(stages))
        XCTAssertEqual(rooms.selected, .look, "an off stage's room gives way to the Look tab")
    }

    /// The tabs in flow order: the Look tab, then Film, Telecine, Tape, Display, Audio.
    func testTheTabOrder() {
        XCTAssertEqual(SidebarTab.all.map(\.title), ["Look", "Film", "Telecine", "Tape", "Display", "Audio"])
        XCTAssertEqual(SidebarTab.all.compactMap(\.stage), ChainStage.strip, "the tabs and the stage list agree")
        XCTAssertEqual(SidebarTab(word: "display"), .stage(.display))
        XCTAssertEqual(SidebarTab(word: "look"), .look)
        XCTAssertNil(SidebarTab(word: "recapture"), "Re-capture lives inside the Display")
    }

    // MARK: The visible tabs

    /// At launch the strip shows Look, Tape and Audio, and nothing else.
    func testLaunchShowsLookTapeAudio() {
        let stages = StageSwitches(chain: SignalChain.standard())
        XCTAssertEqual(SidebarTab.visible(stages), [.look, .stage(.tape), .stage(.audio)])
    }

    /// Every one of the 32 combinations of the five strip stages: the Look tab always, then
    /// exactly the stages that are on, in flow order.
    func testVisibleTabsForEveryStageCombination() {
        for mask in 0..<(1 << ChainStage.strip.count) {
            let stages = StageSwitches(chain: SignalChain.standard())
            for (i, stage) in ChainStage.strip.enumerated() { stages.set(stage, on: mask & (1 << i) != 0) }
            let on = ChainStage.strip.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            XCTAssertEqual(SidebarTab.visible(stages), [.look] + on.map { .stage($0) }, "mask \(mask)")
        }
    }

    /// The stage list and the room's header draw the same switch over the same model, so a stage
    /// turned on from either one is on in both and its tab shows, and off takes the tab away
    /// and opens the Look tab if that room was open. Other rooms stay open.
    func testListAndRoomSwitchStayInStep() {
        let stages = StageSwitches(chain: SignalChain.standard())
        let rooms = StageRooms()
        for stage in ChainStage.strip {
            let wasOn = stages.switchIsOn(stage)
            stages.toggle(stage)
            XCTAssertNotEqual(stages.switchIsOn(stage), wasOn, stage.rawValue)
            XCTAssertEqual(SidebarTab.visible(stages).contains(.stage(stage)), !wasOn, stage.rawValue)
            stages.toggle(stage)
            XCTAssertEqual(SidebarTab.visible(stages).contains(.stage(stage)), wasOn, "\(stage.rawValue) back")
        }
        stages.set(.film, on: true)
        rooms.choose(.stage(.film))
        rooms.follow(SidebarTab.visible(stages))
        XCTAssertEqual(rooms.selected, .stage(.film), "an on stage keeps its room")
        stages.set(.display, on: true)
        stages.set(.display, on: false)
        rooms.follow(SidebarTab.visible(stages))
        XCTAssertEqual(rooms.selected, .stage(.film), "another stage going off leaves the open room alone")
        stages.set(.film, on: false)
        rooms.follow(SidebarTab.visible(stages))
        XCTAssertEqual(rooms.selected, .look)
    }

    /// A Look shows the tabs of the stages it turns on and hides those it turns off: Pro Scan
    /// shows Film and Telecine (a Telecine Look turns the Film on too), a film Look hides the
    /// Tape, Fresh SP hides Film and Telecine again, and a Look that does not film the screen
    /// leaves the Display tab as it was.
    func testALookShowsItsTabs() throws {
        let chain = SignalChain.standard()
        let stages = StageSwitches(chain: chain)
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        presets.setLook(try XCTUnwrap(Looks.look(id: "pro-scan")))
        let pro = SidebarTab.visible(stages)
        XCTAssertTrue(pro.contains(.stage(.film)))
        XCTAssertTrue(pro.contains(.stage(.telecine)))
        presets.setLook(try XCTUnwrap(Looks.look(id: "super8-kodachrome")))
        XCTAssertFalse(SidebarTab.visible(stages).contains(.stage(.tape)))
        presets.setLook(try XCTUnwrap(Looks.look(id: "clean-sp")))
        XCTAssertEqual(SidebarTab.visible(stages), [.look, .stage(.tape), .stage(.audio)])
        stages.set(.display, on: true)
        presets.setLook(try XCTUnwrap(Looks.look(id: "s-vhs")))
        XCTAssertEqual(SidebarTab.visible(stages), [.look, .stage(.tape), .stage(.display), .stage(.audio)])
    }

    // MARK: The stage switches

    /// Every stage switch the sidebar draws changes the chain fingerprint (the hash the preview
    /// draws with), and back off returns it. Telecine is switched with the Film on and
    /// Re-capture with the Display on, since each needs the other.
    func testEveryStageSwitchChangesTheFingerprint() {
        for stage in ChainStage.allCases {
            let chain = SignalChain.standard()
            let stages = StageSwitches(chain: chain)
            if stage == .telecine { stages.set(.film, on: true) }
            if stage == .recapture { stages.set(.display, on: true) }
            let before = ChainFingerprint.of(chain)
            let wasOn = stages.isOn(stage)
            stages.toggle(stage)
            XCTAssertNotEqual(stages.isOn(stage), wasOn, stage.rawValue)
            XCTAssertNotEqual(ChainFingerprint.of(chain), before, stage.rawValue)
            stages.toggle(stage)
            XCTAssertEqual(ChainFingerprint.of(chain), before, "\(stage.rawValue) back")
        }
    }

    /// Tape and Audio are lit at launch, the rest dark, and the "needs" notes name what each
    /// waits for.
    func testDefaultsLightTapeAndAudio() {
        let stages = StageSwitches(chain: SignalChain.standard())
        XCTAssertEqual(ChainStage.strip.filter(stages.isOn), [.tape, .audio])
        XCTAssertNil(stages.need(.telecine), "Telecine works without the Film")
        XCTAssertEqual(stages.need(.recapture), "needs Display")
        stages.set(.film, on: true)
        stages.set(.display, on: true)
        XCTAssertNil(stages.need(.telecine))
        XCTAssertNil(stages.need(.recapture))
        // Telecine switched on while the Film is off is lit: it transfers the clip itself.
        let t = StageSwitches(chain: SignalChain.standard())
        t.set(.telecine, on: true)
        XCTAssertTrue(t.switchIsOn(.telecine))
        XCTAssertTrue(t.isOn(.telecine))
    }

    /// Tape off from the sidebar is `--set tape=off`: the same fingerprint, picture output,
    /// audio spec and sidecar.
    func testTapeOffFromTheSidebarEqualsSetTapeOff() throws {
        let ui = SignalChain.standard()
        StageSwitches(chain: ui).set(.tape, on: false)
        let cli = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--set", "tape=off"]).apply(to: cli)
        XCTAssertEqual(ChainFingerprint.of(ui), ChainFingerprint.of(cli))
        XCTAssertEqual(ui.output, cli.output)
        XCTAssertEqual(ui.audio.spec, cli.audio.spec)
        XCTAssertFalse(ui.audio.tapeIsOn)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("ui.json"), b = dir.appendingPathComponent("cli.json")
        try Sidecar.write(chain: ui, name: "clip.mov", lookID: nil, to: a)
        try Sidecar.write(chain: cli, name: "clip.mov", lookID: nil, to: b)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
    }

    /// The Display switch turns every CRT layer on the first time, as the filmed Looks do, and
    /// gives back the layers that were on after an off.
    func testDisplaySwitchHoldsItsLayers() {
        let chain = SignalChain.standard()
        let stages = StageSwitches(chain: chain)
        let crt = chain.vhs!.crt
        stages.set(.display, on: true)
        XCTAssertTrue(crt.layers.allSatisfy(\.enabled))
        crt.mask.enabled = false
        crt.glow.enabled = false
        stages.set(.display, on: false)
        XCTAssertFalse(crt.isOn)
        stages.set(.display, on: true)
        XCTAssertEqual(crt.layers.filter(\.enabled).map(\.id), ["crt-transfer", "crt-beam", "crt-geometry", "crt-glass"])
    }

    /// The Audio switch off plays the clip's own sound (an empty spec), and on gives back the
    /// mic, its Strength and the track with a moved layer value, sample for sample.
    func testAudioSwitchHoldsTheSound() {
        let chain = SignalChain.standard()
        let audio = chain.audio
        audio.preset = .camcorder
        audio.setMicStrength(40)
        audio.setTrack(.worn)
        let moved = audio.layers.first { $0 !== audio.micLayer && !$0.parameters.isEmpty }!
        let p = moved.parameters.first { $0.value.doubleValue != nil }!
        moved.setParameter(p.id, to: .float(p.range.lowerBound))
        let before = audio.spec
        let print = ChainFingerprint.of(chain)
        let stages = StageSwitches(chain: chain)
        stages.set(.audio, on: false)
        XCTAssertFalse(stages.isOn(.audio))
        XCTAssertTrue(audio.isPassthrough, "off is the clip's own sound")
        stages.set(.audio, on: true)
        XCTAssertEqual(audio.spec, before)
        XCTAssertEqual(ChainFingerprint.of(chain), print)
        // Never held (a chain on Off): on is the default track, Linear NR.
        let off = SignalChain.standard()
        off.audio.preset = .off
        StageSwitches(chain: off).set(.audio, on: true)
        XCTAssertEqual(off.audio.track, .linearNR)
    }

    /// A Look that turns stages on lights them: the filmed Looks light the Display and
    /// Re-capture, the film Looks light the Film and darken the Tape.
    func testLooksLightTheirStages() {
        let chain = SignalChain.standard()
        let stages = StageSwitches(chain: chain)
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        presets.setLook(Looks.look(id: "filmed-tv")!)
        XCTAssertTrue(stages.isOn(.display))
        XCTAssertTrue(stages.isOn(.recapture))
        presets.setLook(Looks.look(id: "super8-kodachrome")!)
        XCTAssertTrue(stages.isOn(.film))
        XCTAssertFalse(stages.isOn(.tape))
        // A Look that does not film the screen leaves the Display as it is and switches
        // the camera off.
        presets.setLook(Looks.look(id: "clean-sp")!)
        XCTAssertEqual(ChainStage.allCases.filter(stages.isOn), [.tape, .display, .audio])
    }
}
