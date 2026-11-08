import XCTest
@testable import HomeVideoCore

/// Make a Look in the app, save it, render with it: a preset saved through the app's Save
/// (`UserPresets.save`) and loaded through `homevideo-render --preset-file` gives the chain
/// the app had, every video and audio layer's switch and parameter.
@MainActor
final class PresetToCLITests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-preset-cli-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        Looks.user = []
    }

    /// Every layer the preset carries, with its switch as the file saves it and every parameter,
    /// then the audio preset, wear, strength and every audio layer. Framing and the Output size
    /// belong to the clip, not the preset, so they are left out here and checked apart.
    func everyValue(_ chain: SignalChain) -> [String] {
        var out: [String] = []
        for l in chain.vhs!.savedLayers {
            out.append("\(l.id) on=\(Looks.userSwitch(l) ?? l.enabled)")
            out += l.parameters.map { "\(l.id).\($0.id)=\($0.value)" }
        }
        out.append("audio preset=\(chain.audio.preset.rawValue) mic=\(chain.audio.mic.rawValue) "
                   + "track=\(chain.audio.track.rawValue) wear=\(chain.audio.wear) strength=\(chain.audio.micStrength)")
        for l in chain.audio.allLayers {
            out.append("\(l.id) on=\(l.enabled)")
            out += l.parameters.map { "\(l.id).\($0.id)=\($0.value)" }
        }
        return out
    }

    /// A chain no Look has, touching every stage: a Look, a Film stage preset, a moved slider,
    /// a Damage layer with its seed, the Display on, the audio track, wear and mic.
    func madeInTheApp() throws -> SignalChain {
        let chain = SignalChain.standard()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(Looks.look(id: "rental")!)
        try StagePresets(folder: folder).apply(try XCTUnwrap(StagePresets.builtIns(.film).last), to: chain)
        try RenderArguments(input: "a", output: "b", settings: [
            .init(layer: "film", parameter: "enabled", value: "on"),
            .init(layer: "damage-snow", parameter: "enabled", value: "on"),
            .init(layer: "damage-snow", parameter: "seed", value: "42"),
            .init(layer: "display", parameter: "enabled", value: "on"),
            .init(layer: "luma-bandwidth", parameter: "cut", value: "2.137"),
        ]).apply(to: chain)
        chain.audio.mic = .camcorder
        chain.audio.setTrack(.worn)
        chain.audio.setWear(35)
        chain.audio.setMicStrength(60)
        return chain
    }

    func testSavedPresetRendersAsTheAppHadIt() throws {
        let chain = try madeInTheApp()
        let want = everyValue(chain)
        XCTAssertNotEqual(want, everyValue(SignalChain.standard()), "the made chain differs from the default")

        let store = UserPresets(folder: folder)
        let url = try store.save(name: "Made In The App", chain: chain).url

        let rendered = SignalChain.standard()
        let args = try RenderArguments.parse(["in.mov", "out.mov", "--preset-file", url.path])
        try args.apply(to: rendered)
        let got = everyValue(rendered)
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) where g != w { XCTFail("\(g) != \(w)") }
        XCTAssertEqual(got, want)
        // The fingerprint over every value agrees as well.
        XCTAssertEqual(ChainFingerprint.of(rendered), ChainFingerprint.of(chain))
    }

    /// What a preset leaves out (Framing, the Output size) stays at the tool's defaults, and the
    /// flags set it after the preset.
    func testWhatAPresetLeavesOutComesFromFlags() throws {
        let chain = try madeInTheApp()
        chain.framing.setParameter("zoom", to: .float(1.5))
        chain.vhs!.output.setParameter("size", to: .choice(OutputSize.hd.rawValue))
        let url = try UserPresets(folder: folder).save(name: "Framed", chain: chain).url

        let plain = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--preset-file", url.path]).apply(to: plain)
        XCTAssertEqual(plain.framing.zoom, SignalChain.standard().framing.zoom, "a preset carries no Framing")
        XCTAssertTrue(plain.vhs!.output.isAuto, "a preset carries no Output size")

        let flagged = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--preset-file", url.path, "--size", "hd",
                                   "--set", "framing.zoom=1.5"]).apply(to: flagged)
        XCTAssertEqual(flagged.framing.zoom, 1.5)
        XCTAssertEqual(flagged.vhs!.output.size, .hd)
        XCTAssertEqual(everyValue(flagged), everyValue(chain))
    }
}
