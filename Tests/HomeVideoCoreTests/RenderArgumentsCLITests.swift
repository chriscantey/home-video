import AVFoundation
import Metal
import XCTest
@testable import HomeVideoCore

/// The flags that reach the app's clip and file controls: the sidecar, Copy Settings JSON, user
/// stage presets, the Output size, the in and out points, and the Display and Audio switches.
/// Parse and apply here, renders in `RenderArgumentsRenderTests`.
@MainActor
final class RenderArgumentsCLITests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        Looks.user = []
    }

    func parse(_ extra: [String]) throws -> RenderArguments { try RenderArguments.parse(["in.mov", "out.mov"] + extra) }

    func parseError(_ extra: [String]) -> RenderArguments.ParseError? {
        do { _ = try parse(extra); return nil } catch { return error as? RenderArguments.ParseError }
    }

    // MARK: Parse

    func testNewFlagsParse() throws {
        let a = try parse(["--sidecar", "~/s.json", "--settings", "c.json", "--stage-file", "a.homevideostage",
                           "--stage", "film=Summer Reel", "--stage-file=b.homevideostage", "--size", "hd",
                           "--fit", "fill", "--in", "1.5", "--out", "1:02.25"])
        XCTAssertEqual(a.sidecar, "~/s.json")
        XCTAssertFalse(a.clipSidecar)
        XCTAssertEqual(a.settingsFile, "c.json")
        XCTAssertEqual(a.stageSteps, [.file("a.homevideostage"), .builtIn(.init(stage: .film, name: "Summer Reel")),
                                      .file("b.homevideostage")])
        XCTAssertEqual(a.stages.map(\.name), ["Summer Reel"], "stages keeps the built-in picks alone")
        XCTAssertEqual(a.size, .init(size: .hd))
        XCTAssertEqual(a.fill, true)
        XCTAssertEqual(a.inPoint, 1.5)
        XCTAssertEqual(a.outPoint, 62.25)
        XCTAssertTrue(try parse(["--clip-sidecar"]).clipSidecar)
        XCTAssertEqual(try parse(["--fit", "inside"]).fill, false)
        let plain = try parse([])
        XCTAssertNil(plain.sidecar)
        XCTAssertFalse(plain.clipSidecar, "no sidecar is read unless asked for")
        XCTAssertNil(plain.size)
        XCTAssertNil(plain.fill)
        XCTAssertNil(plain.inPoint)
        XCTAssertNil(plain.outPoint)
        XCTAssertNil(plain.settingsFile)
        XCTAssertTrue(plain.stageSteps.isEmpty)
    }

    func testSizeWords() throws {
        for size in OutputSize.allCases where size != .custom {
            XCTAssertEqual(try parse(["--size", size.rawValue]).size, .init(size: size))
        }
        XCTAssertEqual(try parse(["--size", "HD"]).size, .init(size: .hd))
        XCTAssertEqual(try parse(["--size", "1280x720"]).size, .init(size: .custom, width: 1280, height: 720))
        // Odd numbers go to the nearest even, as the app's fields do.
        XCTAssertEqual(try parse(["--size", "1281x721"]).size?.width.map { $0 % 2 }, 0)
        for bad in ["custom", "big", "1280", "1280x", "x720", "10x10", "99999x720", "1280x720x3"] {
            if case .badExport(bad, "--size", _) = parseError(["--size", bad]) {} else {
                XCTFail("--size \(bad) not refused")
            }
        }
    }

    func testTimes() {
        XCTAssertEqual(RenderArguments.parseTime("0"), 0)
        XCTAssertEqual(RenderArguments.parseTime("12.5"), 12.5)
        XCTAssertEqual(RenderArguments.parseTime("1:02.5"), 62.5)
        XCTAssertEqual(RenderArguments.parseTime("1:02:03"), 3723)
        for bad in ["", "-1", "a", "1:60", "1.5:00", "1:2:3:4", "inf", "nan", ":5"] {
            XCTAssertNil(RenderArguments.parseTime(bad), bad)
        }
        XCTAssertEqual(parseError(["--in", "x"]), .badTime("x", option: "--in"))
        XCTAssertEqual(parseError(["--out", "out.mov"]), .badTime("out.mov", option: "--out"))
        XCTAssertEqual(parseError(["--in", "5", "--out", "5"]), .badRange(inPoint: 5, outPoint: 5))
        XCTAssertEqual(parseError(["--in", "6", "--out", "5"]), .badRange(inPoint: 6, outPoint: 5))
    }

    func testOtherErrors() {
        XCTAssertEqual(parseError(["--sidecar", "a.json", "--clip-sidecar"]), .twoSidecars)
        XCTAssertEqual(parseError(["--fit", "stretch"]), .badExport("stretch", option: "--fit", expected: ["inside", "fill"]))
        XCTAssertEqual(parseError(["--stage-file"]), .missingValue("--stage-file"))
        XCTAssertEqual(parseError(["--settings"]), .missingValue("--settings"))
    }

    func testUsageNamesEveryNewFlagAndTheOrder() {
        for flag in ["--sidecar", "--clip-sidecar", "--settings", "--stage-file", "--size", "--fit", "--in", "--out",
                     "display=on", "audio=off", "The order every run applies them in"] {
            XCTAssertTrue(RenderArguments.usage.contains(flag), flag)
        }
        for codec in ExportCodec.allCases { XCTAssertTrue(RenderArguments.usage.contains(codec.rawValue), codec.rawValue) }
        for size in OutputSize.allCases where size != .custom {
            XCTAssertTrue(RenderArguments.usage.contains(size.rawValue), size.rawValue)
        }
    }

    // MARK: Apply

    func testSizeAndFitSetTheOutputLayerBeforeSet() throws {
        let chain = SignalChain.standard()
        try parse(["--size", "1000x500", "--fit", "fill"]).apply(to: chain)
        let o = chain.vhs!.output
        XCTAssertEqual(o.size, .custom)
        XCTAssertEqual(o.width, 1000)
        XCTAssertEqual(o.height, 500)
        XCTAssertTrue(o.fill)
        // --set comes after --size, so it wins.
        let c2 = SignalChain.standard()
        try parse(["--set", "output.size=uhd", "--size", "hd"]).apply(to: c2)
        XCTAssertEqual(c2.vhs!.output.size, .uhd)
        // The same value through --set as through --size.
        let c3 = SignalChain.standard(), c4 = SignalChain.standard()
        try parse(["--size", "phone", "--fit", "fill"]).apply(to: c3)
        try parse(["--set", "output.size=phone", "--set", "output.fill=on"]).apply(to: c4)
        XCTAssertEqual(SettingsClipboard.encode(c3), SettingsClipboard.encode(c4))
    }

    func testInAndOutMakeTheRange() throws {
        let chain = SignalChain.standard()
        XCTAssertNil(try parse([]).apply(to: chain).trim, "no flags, the whole clip")
        XCTAssertEqual(try parse(["--in", "2", "--out", "5"]).apply(to: chain).trim, TrimRange(in: 2, out: 5))
        let open = try parse(["--in", "2"]).apply(to: chain).trim
        XCTAssertEqual(open?.inPoint, 2)
        XCTAssertEqual(open?.clamped(to: 10), TrimRange(in: 2, out: 10), "no --out runs to the end")
        XCTAssertEqual(try parse(["--out", "3"]).apply(to: chain).trim, TrimRange(in: 0, out: 3))
    }

    /// A sidecar the app wrote: the chain, Framing, the Output size and its trim, read only when
    /// asked for, and --in and --out over its trim end by end.
    func testSidecarAppliesChainFramingSizeAndTrim() throws {
        let clip = folder.appendingPathComponent("clip.mov")
        try Data().write(to: clip)
        let saved = SignalChain.standard()
        Presets(vhs: saved.vhs!, audio: saved.audio).setLook(Looks.look(id: "rental")!)
        saved.framing.setParameter("mode", to: .choice(FramingMode.letterbox.rawValue))
        saved.framing.setParameter("zoom", to: .float(1.3))
        saved.vhs!.output.setParameter("size", to: .choice(OutputSize.hd.rawValue))
        saved.vhs!.dropouts.setParameter("rate", to: .float(33))
        let sidecar = Sidecar.besideURL(for: clip)
        try Sidecar.write(chain: saved, name: "clip.mov", lookID: "rental", trim: TrimRange(in: 1, out: 4), to: sidecar)

        // Not asked for: not read, though it sits beside the clip.
        let plain = SignalChain.standard()
        let none = try RenderArguments.parse([clip.path, "o.mov"]).apply(to: plain)
        XCTAssertNil(none.sidecar)
        XCTAssertNil(none.trim)
        XCTAssertEqual(SettingsClipboard.encode(plain), SettingsClipboard.encode(SignalChain.standard()))

        for flags in [["--clip-sidecar"], ["--sidecar", sidecar.path]] {
            let chain = SignalChain.standard()
            let r = try RenderArguments.parse([clip.path, "o.mov"] + flags).apply(to: chain)
            XCTAssertEqual(r.sidecar, sidecar.path, "\(flags)")
            XCTAssertEqual(r.trim, TrimRange(in: 1, out: 4), "\(flags)")
            XCTAssertEqual(SettingsClipboard.encode(chain), SettingsClipboard.encode(saved), "\(flags)")
            XCTAssertEqual(chain.framing.mode, .letterbox)
            XCTAssertEqual(chain.vhs!.output.size, .hd)
        }
        let over = try RenderArguments.parse([clip.path, "o.mov", "--clip-sidecar", "--out", "3"])
            .apply(to: SignalChain.standard())
        XCTAssertEqual(over.trim, TrimRange(in: 1, out: 3), "--out replaces the sidecar's out point, keeps its in")
        // Later steps still apply over it.
        let later = SignalChain.standard()
        try RenderArguments.parse([clip.path, "o.mov", "--clip-sidecar", "--size", "sd"]).apply(to: later)
        XCTAssertEqual(later.vhs!.output.size, .sd)
    }

    func testClipSidecarMissingIsNoErrorButSidecarMissingIs() throws {
        let clip = folder.appendingPathComponent("bare.mov")
        try Data().write(to: clip)
        // An empty fallback folder: a clip of this name may have one in the real one.
        XCTAssertNil(Sidecar.existing(for: clip, fallbackFolder: folder))
        if Sidecar.existing(for: clip) == nil {
            let r = try RenderArguments.parse([clip.path, "o.mov", "--clip-sidecar"]).apply(to: SignalChain.standard())
            XCTAssertNil(r.sidecar)
        }
        let missing = folder.appendingPathComponent("nope.homevideo.json").path
        XCTAssertThrowsError(try RenderArguments.parse([clip.path, "o.mov", "--sidecar", missing])
            .apply(to: SignalChain.standard())) { e in
            guard case .badFile(missing, "--sidecar", _) = e as? RenderArguments.ApplyError else {
                return XCTFail("\(e)")
            }
        }
        let junk = folder.appendingPathComponent("junk.json")
        try Data("{\"kind\":\"other\"}".utf8).write(to: junk)
        let before = SettingsClipboard.encode(SignalChain.standard())
        let chain = SignalChain.standard()
        XCTAssertThrowsError(try parse(["--sidecar", junk.path]).apply(to: chain))
        XCTAssertEqual(SettingsClipboard.encode(chain), before, "a bad sidecar changes nothing")
    }

    /// Copy Settings JSON gives the copied chain, Framing and the Output size included.
    func testSettingsFileIsPasteSettings() throws {
        let source = SignalChain.standard()
        Presets(vhs: source.vhs!, audio: source.audio).setLook(Looks.look(id: "attic-tape")!)
        source.framing.setParameter("zoom", to: .float(1.4))
        source.vhs!.output.setParameter("size", to: .choice(OutputSize.uhd.rawValue))
        source.audio.setWear(30)
        let file = folder.appendingPathComponent("settings.json")
        try SettingsClipboard.encode(source).write(to: file, atomically: true, encoding: .utf8)
        let chain = SignalChain.standard()
        try parse(["--settings", file.path]).apply(to: chain)
        XCTAssertEqual(SettingsClipboard.encode(chain), SettingsClipboard.encode(source))

        try Data("not json".utf8).write(to: file)
        XCTAssertThrowsError(try parse(["--settings", file.path]).apply(to: SignalChain.standard()))
        XCTAssertThrowsError(try parse(["--settings", folder.appendingPathComponent("none.json").path])
            .apply(to: SignalChain.standard()))
    }

    /// A stage preset the app saved applies that stage as the menu does, in order with --stage.
    func testStageFileAppliesTheSavedStage() throws {
        let store = StagePresets(folder: folder)
        let made = SignalChain.standard()
        try StagePresets(folder: folder).apply(try XCTUnwrap(StagePresets.builtIns(.film).last), to: made)
        made.vhs!.film.grain.setParameter("strength", to: .float(0.37))
        let saved = try store.save(name: "My Reel", stage: .film, chain: made)
        let url = try XCTUnwrap(saved.url)

        let viaFlag = SignalChain.standard(), viaMenu = SignalChain.standard()
        try parse(["--stage-file", url.path]).apply(to: viaFlag)
        try store.apply(try StagePresets.read(url), to: viaMenu)
        XCTAssertEqual(SettingsClipboard.encode(viaFlag), SettingsClipboard.encode(viaMenu))
        XCTAssertNotEqual(SettingsClipboard.encode(viaFlag), SettingsClipboard.encode(SignalChain.standard()))

        // In the order given: a built-in after the file wins.
        let first = try XCTUnwrap(StagePresets.builtIns(.film).first)
        let ordered = SignalChain.standard(), builtIn = SignalChain.standard()
        try parse(["--stage-file", url.path, "--stage", "film=\(first.name)"]).apply(to: ordered)
        try parse(["--stage", "film=\(first.name)"]).apply(to: builtIn)
        XCTAssertEqual(SettingsClipboard.encode(ordered), SettingsClipboard.encode(builtIn))

        XCTAssertThrowsError(try parse(["--stage-file", folder.appendingPathComponent("x.homevideostage").path])
            .apply(to: SignalChain.standard()))
    }

    /// The strip's Display and Audio switches, as `StageSwitches.set` sets them.
    func testDisplayAndAudioSwitches() throws {
        let viaFlag = SignalChain.standard(), viaStrip = SignalChain.standard()
        try parse(["--set", "display=on", "--set", "audio=off"]).apply(to: viaFlag)
        let switches = StageSwitches(chain: viaStrip)
        switches.set(.display, on: true)
        switches.set(.audio, on: false)
        XCTAssertTrue(viaFlag.vhs!.crt.layers.allSatisfy(\.enabled))
        XCTAssertFalse(viaFlag.audio.isOn)
        XCTAssertEqual(SettingsClipboard.encode(viaFlag), SettingsClipboard.encode(viaStrip))
        let off = SignalChain.standard()
        try parse(["--set", "display=on", "--set", "display.enabled=off"]).apply(to: off)
        XCTAssertFalse(off.vhs!.crt.isOn)
        XCTAssertThrowsError(try parse(["--set", "display=maybe"]).apply(to: SignalChain.standard()))
    }
}

/// Renders through the real exporter with the new flags: the range and the size land in the file.
@MainActor
final class RenderArgumentsRenderTests: XCTestCase {
    func testInOutAndSizeReachTheFile() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let trims = TrimExportTests()
        try await trims.setUp()
        let fixture = try await trims.makeFixture()
        defer { Task { try? await trims.tearDown() } }

        let out = fixture.deletingLastPathComponent().appendingPathComponent("cli.mov")
        let args = try RenderArguments.parse([fixture.path, out.path, "--in", "1", "--out", "2", "--size", "hd"])
        let chain = SignalChain.standard()
        let applied = try args.apply(to: chain)
        let ex = Exporter(source: fixture, destination: out, chain: chain, maxFrames: args.frames,
                          pixelFormat: args.pixelFormat, settings: args.export)
        ex.trim = applied.trim
        let result = try await ex.run()
        XCTAssertEqual(result.framesWritten, 30, "1 s of a 30 fps clip")
        let got = try await trims.readBack(out)
        XCTAssertEqual(got.frames, 30)
        XCTAssertEqual(got.first, 0, accuracy: 1e-6, "the file starts at zero")
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let f = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
        let d = CMVideoFormatDescriptionGetDimensions(f)
        XCTAssertEqual(Int(d.width), 1920)
        XCTAssertEqual(Int(d.height), 1080)
    }
}
