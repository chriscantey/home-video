import XCTest
@testable import HomeVideoCore

/// A preset menu for every stage beside the global Look. A stage preset changes its own
/// stage and nothing else, round trips through its file, imports on a fresh install, refuses to
/// import as another stage, and leaves the global presets and the Looks as they were.
@MainActor
final class StagePresetsTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-stage-presets-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        Looks.user = []
    }

    func store(_ name: String = "a") -> StagePresets {
        StagePresets(folder: folder.appendingPathComponent(name, isDirectory: true))
    }

    /// Every stage as the bytes of its file, so "unchanged" means byte-identical.
    func bytes(_ chain: SignalChain) throws -> [Stage: Data] {
        var out: [Stage: Data] = [:]
        for stage in Stage.allCases {
            out[stage] = try StagePresets.encode(name: "x", stage: stage,
                                                 snapshot: stage.snapshot(vhs: chain.vhs!, audio: chain.audio))
        }
        return out
    }

    func snapshot(_ stage: Stage, _ chain: SignalChain) -> StageSnapshot {
        stage.snapshot(vhs: chain.vhs!, audio: chain.audio)
    }

    /// A chain with every stage moved off its default: Phone Dub's tape and filmed TV, the film on
    /// a 500T stock, a Pro telecine, and the audio on a worn track with the camcorder mic part
    /// way, its wear and a damage layer.
    func busyChain() -> SignalChain {
        let chain = SignalChain.standard()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(Looks.look(id: "phone-dub")!)
        let vhs = chain.vhs!
        vhs.film.source.enabled = true
        vhs.film.stock.setParameter("stock", to: .choice(FilmStock.vision500T.rawValue))
        vhs.telecine.source.enabled = true
        vhs.telecine.source.setParameter("route", to: .choice(TelecineRoute.pro.rawValue))
        vhs.crt.mask.setParameter("triad", to: .float(4.4))
        chain.audio.setTrack(.worn)
        chain.audio.mic = .camcorder
        chain.audio.setMicStrength(55)
        chain.audio.setWear(40)
        chain.audio.damage.first!.enabled = true
        chain.framing.setParameter("mode", to: .choice("letterbox"))
        return chain
    }

    // MARK: - The stages and the built-ins

    func testEveryStageOwnsItsLayersAndNoLayerIsOwnedTwice() {
        let vhs = VHSLayers()
        let ids = Stage.allCases.flatMap { $0.layers(in: vhs).map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count, "a layer in two stages")
        // Every layer a file can name belongs to a stage.
        XCTAssertEqual(Set(ids), Set(vhs.saved.map(\.id)))
        XCTAssertTrue(Stage.tape.layers(in: vhs).contains { $0.id == "tape" })
        XCTAssertTrue(Stage.display.layers(in: vhs).contains { $0.id == "recapture" })
        XCTAssertTrue(Stage.display.layers(in: vhs).contains { $0.id == "crt-display" })
        XCTAssertTrue(Stage.audio.layers(in: vhs).isEmpty, "the audio is the chain's, not a picture layer")
    }

    func testBuiltInsPerStageInOrderWithShortUniqueNames() {
        let names = Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, StagePresets.builtIns($0).map(\.name)) })
        // The film Looks join in the Look menu's order, then the Telecine Looks' film (8mm to
        // Tape's is Super 8 Kodachrome's twin). The Telecine Looks are each a tier at its own
        // values, so the Telecine list keeps its four.
        XCTAssertEqual(names[.film], ["Off", "Super 8 Kodachrome", "16mm Faded", "Summer Reel", "Cinema 35", "16mm News",
                                      "Living Room", "Estate Sale", "Pro Scan", "Mall Transfer", "Ektachrome 160", "Fuji R25N",
                                      "Vision3 50D", "Vision3 500T"])
        XCTAssertEqual(names[.telecine], ["Off", "Mall transfer", "Mid-grade", "Pro telecine"])
        XCTAssertEqual(names[.display], ["Off", "Tube TV", "Close-up Mask", "Filmed TV", "Phone Dub", "Tripod TV", "Up Close"])
        // Audio: the tracks, then the sounds of the Looks that add damage or the motor to one
        // in the Look list's order. Every other Look's sound is a track's twin. Linear NR, the
        // default sound, is with the tracks.
        XCTAssertEqual(names[.audio], ["Clean Hi-Fi", "Camcorder", "Linear NR", "Linear", "Worn Linear", "EP Linear",
                                       "Linear and Motor", "Hi-Fi Dropouts", "Sagging Linear", "Stretched Hi-Fi",
                                       "Shedding Hi-Fi"])
        // Tape: each built-in Look's tape in the Look menu's order, a Look whose tape is another's
        // left out (Filmed TV's is Fresh SP's), the film Looks' Tape off as Off at the end.
        let tape = names[.tape]!
        XCTAssertEqual(tape.first, "S-VHS")
        XCTAssertEqual(tape.last, "Off")
        for name in ["Fresh SP", "Good Deck", "Dub of a Dub", "Rental", "Attic Tape", "Shoebox", "Phone Dub", "8mm to Tape"] {
            XCTAssertTrue(tape.contains(name), name)
        }
        XCTAssertFalse(tape.contains("Filmed TV"))
        XCTAssertFalse(tape.contains("Super 8"))
        for (stage, list) in names {
            XCTAssertEqual(list.count, Set(list).count, "\(stage) has a name twice")
            // Short enough for a 248 pt menu: none longer than the longest stock name.
            for n in list { XCTAssertLessThanOrEqual(n.count, 18, n) }
            // No two built-ins of a stage set the same values.
            let presets = StagePresets.builtIns(stage)
            for (i, a) in presets.enumerated() {
                for b in presets[(i + 1)...] { XCTAssertFalse(a.snapshot.matches(b.snapshot), "\(a.name) = \(b.name)") }
            }
        }
    }

    func testTheDefaultChainReadsAsEachStagesDefault() {
        let chain = SignalChain.standard()
        let s = store()
        XCTAssertEqual(s.matching(.film, in: chain)?.name, "Off")
        XCTAssertEqual(s.matching(.telecine, in: chain)?.name, "Off")
        XCTAssertEqual(s.matching(.tape, in: chain)?.name, "Fresh SP")
        XCTAssertEqual(s.matching(.display, in: chain)?.name, "Off")
        // The default sound is Linear NR, named at launch, not Custom.
        XCTAssertEqual(s.matching(.audio, in: chain)?.name, "Linear NR")
        // A nudge reads Custom.
        chain.vhs!.noise.setParameter("luma", to: .float(41.5))
        XCTAssertNil(s.matching(.tape, in: chain))
        XCTAssertEqual(s.matching(.display, in: chain)?.name, "Off")
    }

    /// Each built-in Look's stages read back as the built-ins drawn from it.
    func testALooksStagesReadAsTheirBuiltIns() {
        let s = store()
        let cases: [(String, Stage, String)] = [
            ("rental", .tape, "Rental"), ("rental", .audio, "EP Linear"), ("dub-of-a-dub", .tape, "Dub of a Dub"),
            ("camcorder", .audio, "Camcorder"), ("filmed-tv", .display, "Filmed TV"), ("filmed-tv", .tape, "Fresh SP"),
            ("phone-dub", .display, "Phone Dub"), ("super8-kodachrome", .film, "Super 8 Kodachrome"),
            ("super8-kodachrome", .tape, "Off"), ("sixteen-ektachrome-faded", .film, "16mm Faded"),
            ("home-movie-transfer", .telecine, "Mall transfer"),
            ("regular8-summer", .film, "Summer Reel"), ("super8-estate-sale", .film, "Estate Sale"),
            ("mall-transfer", .telecine, "Mid-grade"), ("pro-scan", .telecine, "Pro telecine"),
            ("pro-scan", .tape, "Off"), ("tripod-tv", .display, "Tripod TV"), ("up-close", .display, "Up Close"),
            ("tripod-tv", .tape, "Fresh SP"),
            // The Looks that add damage or the motor to a track.
            ("home-movie-1986", .audio, "Linear and Motor"), ("dub-of-a-dub", .audio, "Hi-Fi Dropouts"),
            ("attic-tape", .audio, "Sagging Linear"), ("hot-car", .audio, "Stretched Hi-Fi"),
            ("sticky-shed", .audio, "Shedding Hi-Fi"),
            // Fresh SP and the Display Looks that film its tape play Linear NR, and the
            // Looks that name Linear keep it.
            ("clean-sp", .audio, "Linear NR"), ("filmed-tv", .audio, "Linear NR"), ("transfer-1986", .audio, "Linear"),
        ]
        for (id, stage, name) in cases {
            let chain = SignalChain.standard()
            Presets(vhs: chain.vhs!, audio: chain.audio).setLook(Looks.look(id: id)!)
            XCTAssertEqual(s.matching(stage, in: chain)?.name, name, "\(id) \(stage)")
        }
        // Every stage of every built-in Look reads as a named built-in, never Custom.
        for look in Looks.all {
            let chain = SignalChain.standard()
            Presets(vhs: chain.vhs!, audio: chain.audio).setLook(look)
            for stage in Stage.allCases {
                XCTAssertNotNil(s.matching(stage, in: chain), "\(look.id) \(stage) reads Custom")
            }
        }
    }

    /// The caption under the Look picker: the stages that are on, in flow order, with
    /// the names their rooms' menus read, Custom once a stage moves off every preset.
    func testTheLookCaptionReadsTheRooms() throws {
        let s = store()
        let chain = SignalChain.standard()
        let switches = StageSwitches(chain: chain)
        XCTAssertEqual(s.readback(chain, switches: switches), "Tape Fresh SP, Audio Linear NR")
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(try XCTUnwrap(Looks.look(id: "pro-scan")))
        let pro = s.readback(chain, switches: switches)
        XCTAssertTrue(pro.hasPrefix("Film "), pro)
        XCTAssertTrue(pro.contains("Telecine Pro telecine"), pro)
        XCTAssertFalse(pro.contains("Tape "), "Pro Scan leaves the Tape off: \(pro)")
        // Each named stage reads exactly what its room's menu shows.
        for stage in Stage.allCases where switches.switchIsOn(ChainStage(rawValue: stage.rawValue)!) {
            XCTAssertTrue(pro.contains("\(stage.title) \(s.matching(stage, in: chain)?.name ?? "Custom")"), "\(stage)")
        }
        let moved = SignalChain.standard()
        let m = StageSwitches(chain: moved)
        moved.vhs!.noise.setParameter("luma", to: .float(41.5))
        XCTAssertEqual(s.readback(moved, switches: m), "Tape Custom, Audio Linear NR")
    }

    // MARK: - Only its stage

    func testEveryBuiltInChangesOnlyItsStage() throws {
        let s = store()
        for start in ["default", "busy"] {
            for stage in Stage.allCases {
                for preset in StagePresets.builtIns(stage) {
                    let chain = start == "busy" ? busyChain() : SignalChain.standard()
                    let before = try bytes(chain)
                    let spec = chain.audio.spec
                    let framing = chain.framing.parameters
                    try s.apply(preset, to: chain)
                    let after = try bytes(chain)
                    let label = "\(start) \(stage) \(preset.name)"
                    for other in Stage.allCases where other != stage {
                        XCTAssertEqual(after[other], before[other], "\(label) moved \(other)")
                    }
                    // The Tape switch carries the sound track, so a Tape preset that switches
                    // the Tape moves the sound exactly as the switch alone does, and no further.
                    var sound = spec
                    if stage == .tape {
                        let ref = start == "busy" ? busyChain() : SignalChain.standard()
                        ref.vhs!.tape.enabled = chain.vhs!.tape.enabled
                        sound = ref.audio.spec
                    }
                    if stage != .audio { XCTAssertEqual(chain.audio.spec, sound, "\(label) moved the sound") }
                    XCTAssertEqual(chain.framing.parameters.map(\.value), framing.map(\.value), "\(label) moved Framing")
                    XCTAssertTrue(snapshot(stage, chain).matches(preset.snapshot), label)
                    XCTAssertEqual(s.matching(stage, in: chain)?.id, preset.id, label)
                }
            }
        }
    }

    /// The global Look reads Custom once a stage it owns moves off it, and comes back when the
    /// stage does.
    func testTheLookReadsCustomUnlessEveryStageMatches() throws {
        let s = store()
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        XCTAssertEqual(presets.look?.id, "clean-sp")
        func pick(_ stage: Stage, _ name: String) throws {
            try s.apply(XCTUnwrap(StagePresets.builtIns(stage).first { $0.name == name }), to: chain)
        }
        try pick(.tape, "Rental")
        XCTAssertNil(presets.look)
        try pick(.tape, "Fresh SP")
        XCTAssertEqual(presets.look?.id, "clean-sp")
        // Fresh SP's sound is Linear NR, so Hi-Fi and Linear both move it off.
        try pick(.audio, "Clean Hi-Fi")
        XCTAssertNil(presets.look)
        try pick(.audio, "Linear")
        XCTAssertNil(presets.look)
        try pick(.audio, "Linear NR")
        XCTAssertEqual(presets.look?.id, "clean-sp")
        try pick(.film, "Vision3 50D")
        XCTAssertNil(presets.look)
        try pick(.film, "Off")
        XCTAssertEqual(presets.look?.id, "clean-sp")
        // The camera filming the screen is part of every Look: Fresh SP's tape with Filmed TV's
        // screen and camera is the Filmed TV Look. A tube with no camera is left to the Display,
        // as a Look leaves it.
        try pick(.display, "Filmed TV")
        XCTAssertEqual(presets.look?.id, "filmed-tv")
        try pick(.display, "Phone Dub")
        XCTAssertNil(presets.look)
        try pick(.display, "Tube TV")
        XCTAssertEqual(presets.look?.id, "clean-sp")
        try pick(.display, "Off")
        XCTAssertEqual(presets.look?.id, "clean-sp")
        // Rental's tape and Rental's sound make Rental.
        try pick(.tape, "Rental")
        try pick(.audio, "EP Linear")
        XCTAssertEqual(presets.look?.id, "rental")
    }

    // MARK: - The user's own

    func testASavedStagePresetRoundTripsItsStageAlone() throws {
        let s = store()
        for stage in Stage.allCases {
            let source = busyChain()
            let want = snapshot(stage, source)
            let preset = try s.save(name: "Mine \(stage.title)", stage: stage, chain: source)
            XCTAssertEqual(preset.url?.lastPathComponent, "Mine \(stage.title).homevideostage")
            XCTAssertEqual(preset.url?.deletingLastPathComponent().lastPathComponent, stage.title)
            XCTAssertEqual(s.presets(for: stage).user.map(\.name), ["Mine \(stage.title)"])
            XCTAssertTrue(preset.snapshot.matches(want), "\(stage) saved")

            let target = SignalChain.standard()
            Presets(vhs: target.vhs!, audio: target.audio).setLook(Looks.look(id: "attic-tape")!)
            let before = try bytes(target)
            try s.apply(preset, to: target)
            let after = try bytes(target)
            XCTAssertEqual(after[stage], try bytes(source)[stage], "\(stage) loads as saved")
            for other in Stage.allCases where other != stage { XCTAssertEqual(after[other], before[other], "\(stage) moved \(other)") }
            // The menu reads it as itself, or as a built-in first when the values are one's
            // (the busy chain's film is the Vision3 500T stock, its tape Phone Dub's).
            let shown = try XCTUnwrap(s.matching(stage, in: target), "\(stage)")
            XCTAssertTrue(shown.snapshot.matches(preset.snapshot))
            XCTAssertTrue(shown.id == preset.id || shown.isBuiltIn, "\(stage) read as \(shown.id)")
            // The busy display (triad 4.4) is no built-in's, so it reads as the user's own, and a
            // nudge reads Custom.
            if stage == .display {
                XCTAssertEqual(shown.id, preset.id)
                target.vhs!.crt.mask.setParameter("triad", to: .float(2.5))
                XCTAssertNil(s.matching(stage, in: target))
            }
        }
    }

    func testTheFileNamesItsStageAndCarriesOnlyItsLayers() throws {
        let s = store()
        let preset = try s.save(name: "Tube", stage: .display, chain: busyChain())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: preset.url!)) as? [String: Any])
        XCTAssertEqual(root["format"] as? String, "homevideo-stage-preset")
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["stage"] as? String, "display")
        XCTAssertEqual(root["name"] as? String, "Tube")
        let ids = (root["layers"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, Stage.display.layers(in: VHSLayers()).map(\.id))
        XCTAssertNil(root["track"], "only Audio carries a track")

        let audio = try s.save(name: "Worn", stage: .audio, chain: busyChain())
        let a = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: audio.url!)) as? [String: Any])
        XCTAssertEqual(a["track"] as? String, "worn")
        XCTAssertEqual(a[AudioWear.id] as? Double, 40)
        XCTAssertEqual(a[AudioChain.strengthID] as? Double, 55)
        XCTAssertEqual(StagePresets.typeIdentifier, "co.wonders.homevideo.stage-preset")
    }

    func testAnExportedFileImportsOnAFreshInstall() throws {
        let mine = store("mine")
        let saved = try mine.save(name: "Phone Night", stage: .display, chain: busyChain())
        let out = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("Phone Night.homevideostage")
        try mine.export(saved, to: file)
        // A built-in exports from its values.
        let builtInFile = out.appendingPathComponent("Rental.homevideostage")
        let rental = try XCTUnwrap(StagePresets.builtIns(.tape).first { $0.name == "Rental" })
        try mine.export(rental, to: builtInFile)

        let theirs = store("fresh-install")
        XCTAssertTrue(theirs.presets(for: .display).user.isEmpty)
        let imported = try theirs.import(from: file, as: .display)
        XCTAssertEqual(imported.name, "Phone Night")
        XCTAssertEqual(theirs.presets(for: .display).user.map(\.name), ["Phone Night"])
        XCTAssertTrue(imported.snapshot.matches(saved.snapshot))
        let chain = SignalChain.standard()
        try theirs.apply(imported, to: chain)
        XCTAssertTrue(snapshot(.display, chain).matches(saved.snapshot))

        let tape = try theirs.import(from: builtInFile, as: .tape)
        XCTAssertTrue(tape.snapshot.matches(rental.snapshot))
        // Imported as a user's own, it reads as the built-in first in the menu.
        let c2 = SignalChain.standard()
        try theirs.apply(tape, to: c2)
        XCTAssertEqual(theirs.matching(.tape, in: c2)?.id, rental.id)
    }

    func testAFileForOneStageRefusesToImportAsAnother() throws {
        let s = store()
        let tape = try s.save(name: "Worn Deck", stage: .tape, chain: busyChain())
        for other in Stage.allCases where other != .tape {
            XCTAssertThrowsError(try s.import(from: tape.url!, as: other)) { error in
                XCTAssertEqual(error as? StagePresetError,
                               .wrongStage("Worn Deck.homevideostage", found: .tape, wanted: other))
            }
            XCTAssertTrue(s.presets(for: other).user.isEmpty, "\(other) took the file")
        }
        // A file that says display but carries a tape layer is malformed.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: tape.url!)) as? [String: Any])
        root["stage"] = "display"
        let forged = folder.appendingPathComponent("forged.homevideostage")
        try JSONSerialization.data(withJSONObject: root).write(to: forged)
        XCTAssertThrowsError(try s.import(from: forged, as: .display)) { error in
            guard case .malformed(_, let reason) = error as? StagePresetError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("not a Display layer"), reason)
        }
        // A whole-chain preset is not a stage preset.
        let look = folder.appendingPathComponent("look.homevideopreset")
        try UserPresets(folder: folder.appendingPathComponent("p")).write(name: "All", chain: busyChain(), to: look)
        XCTAssertThrowsError(try s.import(from: look, as: .tape))
        XCTAssertTrue(s.presets(for: .display).user.isEmpty)
    }

    func testAFileLeavingOutALayerLoadsItAtItsDefault() throws {
        let file = folder.appendingPathComponent("short.homevideostage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root: [String: Any] = ["format": "homevideo-stage-preset", "version": 1, "stage": "display", "name": "Short",
                                   "layers": [["id": "crt-mask", "enabled": true,
                                               "parameters": [["id": "triad", "value": 99.0]]]]]
        try JSONSerialization.data(withJSONObject: root).write(to: file)
        let p = try StagePresets.read(file)
        let fresh = VHSLayers()
        fresh.crt.mask.enabled = true
        fresh.crt.mask.setParameter("triad", to: .float(99))
        XCTAssertTrue(p.snapshot.matches(Stage.display.snapshot(vhs: fresh, audio: AudioChain())))
        XCTAssertEqual(fresh.crt.mask.triad, CRTMaskLayer.triadRange.upperBound, "clamped as the slider clamps")
    }

    func testRenameAndDeleteTheUsersOwnNeverABuiltIn() throws {
        let s = store()
        let a = try s.save(name: "One", stage: .film, chain: busyChain())
        _ = try s.save(name: "Two", stage: .film, chain: SignalChain.standard())
        let renamed = try s.rename(a, to: "Two")
        XCTAssertEqual(renamed.name, "Two 2")
        XCTAssertEqual(s.presets(for: .film).user.map(\.name), ["Two", "Two 2"])
        let cased = try s.rename(renamed, to: "two 2")
        XCTAssertEqual(cased.url?.lastPathComponent, "two 2.homevideostage")
        try s.delete(cased)
        XCTAssertEqual(s.presets(for: .film).user.map(\.name), ["Two"])
        let off = StagePresets.builtIns(.film)[0]
        XCTAssertThrowsError(try s.delete(off)) { XCTAssertEqual($0 as? StagePresetError, .builtIn("Off")) }
        XCTAssertThrowsError(try s.rename(off, to: "Mine")) { XCTAssertEqual($0 as? StagePresetError, .builtIn("Off")) }
        XCTAssertThrowsError(try s.save(name: " ", stage: .film, chain: busyChain()))
        XCTAssertThrowsError(try s.save(name: "a/b", stage: .film, chain: busyChain()))
    }

    // MARK: - The global preset and the Looks stay as they were

    func testTheGlobalUserPresetStillSavesAndLoadsEveryStage() throws {
        let presets = UserPresets(folder: folder.appendingPathComponent("Presets"))
        let source = busyChain()
        let p = try presets.save(name: "Everything", chain: source)
        let target = SignalChain.standard()
        try presets.load(p.url, into: target)
        XCTAssertEqual(try bytes(target), try bytes(source))
    }

    /// Building the built-ins reads the Looks' reference chains and never moves them.
    func testBuildingTheBuiltInsLeavesEveryLookAsItWas() {
        StagePresets.builtInCache = [:]
        let before = Looks.all.map { UserPresets.fingerprint(Looks.reference($0)) }
        let beforeDisplay = Looks.all.map { look -> [StageSnapshot] in
            let r = Looks.reference(look)
            return Stage.allCases.map { $0.snapshot(vhs: r.vhs, audio: r.audio) }
        }
        for stage in Stage.allCases { _ = StagePresets.builtIns(stage) }
        XCTAssertEqual(Looks.all.map { UserPresets.fingerprint(Looks.reference($0)) }, before)
        let afterDisplay = Looks.all.map { look -> [StageSnapshot] in
            let r = Looks.reference(look)
            return Stage.allCases.map { $0.snapshot(vhs: r.vhs, audio: r.audio) }
        }
        XCTAssertEqual(afterDisplay, beforeDisplay)
        // And the default chain still reads Fresh SP.
        let chain = SignalChain.standard()
        XCTAssertEqual(Presets(vhs: chain.vhs!, audio: chain.audio).look?.id, "clean-sp")
    }
}
