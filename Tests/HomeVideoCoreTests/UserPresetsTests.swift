import XCTest
@testable import HomeVideoCore

/// A user preset saves every layer value and the audio preset, loads them back exactly,
/// reads back as itself in the Look menu, and a malformed file changes nothing.
@MainActor
final class UserPresetsTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-presets-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        Looks.user = []
    }

    /// Every effect layer's switch and values, the audio preset and the audio layers' values.
    struct Snapshot: Equatable {
        var layers: [String]
        var values: [ParameterValue]
        var audio: AudioPreset
    }

    func snapshot(_ chain: SignalChain) -> Snapshot {
        var layers: [String] = [], values: [ParameterValue] = []
        for l in chain.effects {
            layers.append("\(l.id) \(Looks.userSwitch(l).map(String.init) ?? "-")")
            layers += l.parameters.map { "\(l.id).\($0.id)" }
            values += l.parameters.map(\.value)
        }
        for l in chain.audio.layers {
            layers.append("\(l.id) \(l.enabled)")
            layers += l.parameters.map { "\(l.id).\($0.id)" }
            values += l.parameters.map(\.value)
        }
        return Snapshot(layers: layers, values: values, audio: chain.audio.preset)
    }

    /// Rental with values no Look has: a moved slider, a switch, a choice and an audio slider.
    func customChain() -> SignalChain {
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        presets.setLook(Looks.look(id: "rental")!)
        chain.vhs!.luma.setParameter("cut", to: .float(2.137))
        chain.vhs!.generation.enabled = true
        chain.vhs!.capture.setParameter("deinterlace", to: .choice(Deinterlace.blend.rawValue))
        presets.setBorder(true)
        let audioLayer = chain.audio.layers.first!
        if let p = audioLayer.parameters.first(where: { $0.value.doubleValue != nil }) {
            audioLayer.setParameter(p.id, to: .float((p.range.lowerBound + p.range.upperBound) / 3))
        }
        XCTAssertNil(presets.look, "the custom chain must match no built-in Look")
        return chain
    }

    func testSaveResetLoadRestoresEveryValue() throws {
        let store = UserPresets(folder: folder)
        let chain = customChain()
        let saved = snapshot(chain)
        let preset = try store.save(name: "Warm Rental", chain: chain)
        XCTAssertEqual(preset.url.lastPathComponent, "Warm Rental.homevideopreset")
        XCTAssertEqual(store.presets.map(\.name), ["Warm Rental"])

        let fresh = SignalChain.standard()
        XCTAssertNotEqual(snapshot(fresh), saved)
        try store.load(preset.url, into: fresh)
        XCTAssertEqual(snapshot(fresh), saved)

        // The Look menu reads it back as the user preset, and a nudge turns it Custom.
        let presets = Presets(vhs: fresh.vhs!, audio: fresh.audio)
        XCTAssertEqual(presets.look?.id, "user:Warm Rental")
        XCTAssertEqual(presets.look?.name, "Warm Rental")
        fresh.vhs!.noise.setParameter("luma", to: .float(41.5))
        XCTAssertNil(presets.look)
        // Choosing it from the menu applies it as a Look.
        presets.setLook(try XCTUnwrap(Looks.anyLook(id: "user:Warm Rental")))
        XCTAssertEqual(snapshot(fresh), saved)
    }

    func testTheFileCarriesVersionNameAudioAndEveryParameter() throws {
        let store = UserPresets(folder: folder)
        let chain = customChain()
        let url = try store.save(name: "File Check", chain: chain).url
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["name"] as? String, "File Check")
        XCTAssertEqual(root["audio"] as? String, chain.audio.preset.rawValue)
        let layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
        // The file lists the VHS layers in their declared order (the chain runs Damage earlier),
        // the Tape, Film and Telecine only while moved (here unused), then the Display stage's.
        XCTAssertEqual(layers.map { $0["id"] as? String }, chain.vhs!.savedLayers.map(\.id))
        XCTAssertEqual(chain.vhs!.savedLayers.count,
                       chain.vhs!.all.count + chain.vhs!.crt.all.count + chain.vhs!.recapture.all.count)
        let luma = try XCTUnwrap(layers.first { $0["id"] as? String == "luma-bandwidth" })
        let params = try XCTUnwrap(luma["parameters"] as? [[String: Any]])
        XCTAssertEqual(params.first { $0["id"] as? String == "cut" }?["value"] as? Double, 2.137)
        XCTAssertFalse(layers.contains { $0["id"] as? String == "framing" }, "framing belongs to the clip")
    }

    func testASecondSaveWithTheSameNameOverwrites() throws {
        let store = UserPresets(folder: folder)
        let first = customChain()
        try store.save(name: "Mine", chain: first)
        let second = SignalChain.standard()
        Presets(vhs: second.vhs!, audio: second.audio).setLook(Looks.look(id: "attic-tape")!)
        second.vhs!.dropouts.setParameter("rate", to: .float(40))
        let url = try store.save(name: "Mine", chain: second).url
        XCTAssertEqual(store.presets.count, 1)
        let target = SignalChain.standard()
        try store.load(url, into: target)
        XCTAssertEqual(snapshot(target), snapshot(second))
        XCTAssertEqual(Presets(vhs: target.vhs!, audio: target.audio).look?.id, "user:Mine")
    }

    func testAMalformedFileIsRejectedWithoutChanges() throws {
        let store = UserPresets(folder: folder)
        let good = try store.save(name: "Good", chain: customChain()).url
        let text = try String(contentsOf: good, encoding: .utf8)
        let cases: [(String, String)] = [
            ("not json", "{ this is not json"),
            ("version 2", text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")),
            ("unknown layer", text.replacingOccurrences(of: "\"luma-bandwidth\"", with: "\"luma-bandwidthX\"")),
            ("string for a number", text.replacingOccurrences(of: "2.137", with: "\"wide\"")),
            ("bad choice", text.replacingOccurrences(of: "\"blend\"", with: "\"triple\"")),
            // The custom chain starts from Rental, whose audio is EP Linear.
            ("bad audio", text.replacingOccurrences(of: "\"audio\" : \"eplinear\"", with: "\"audio\" : \"cassette\"")),
        ]
        for (label, body) in cases {
            XCTAssertNotEqual(body, text, "\(label): the mutation must change the file")
            let url = folder.appendingPathComponent("\(label).homevideopreset")
            try body.write(to: url, atomically: true, encoding: .utf8)
            let chain = SignalChain.standard()
            let before = snapshot(chain)
            XCTAssertThrowsError(try store.load(url, into: chain), label)
            XCTAssertEqual(snapshot(chain), before, "\(label) changed the chain")
            XCTAssertThrowsError(try store.import(from: url), label)
        }
        store.refresh()
        XCTAssertEqual(store.presets.map(\.name), ["Good"], "malformed files are not listed")
    }

    func testExportAndImportCopyFilesOutAndIn() throws {
        let store = UserPresets(folder: folder)
        let chain = customChain()
        let preset = try store.save(name: "Travel", chain: chain)
        let outside = folder.deletingLastPathComponent().appendingPathComponent("homevideo-export-\(UUID().uuidString).homevideopreset")
        defer { try? FileManager.default.removeItem(at: outside) }
        try store.export(preset.url, to: outside)
        try store.delete(preset)
        XCTAssertTrue(store.presets.isEmpty)
        let imported = try store.import(from: outside)
        XCTAssertEqual(imported.name, "Travel")
        XCTAssertEqual(store.presets.map(\.name), ["Travel"])
        let target = SignalChain.standard()
        try store.load(imported.url, into: target)
        XCTAssertEqual(snapshot(target), snapshot(chain))
    }

    func testBadNamesAreRefused() {
        let store = UserPresets(folder: folder)
        for name in ["", "  ", ".hidden", "a/b", "a:b"] {
            XCTAssertThrowsError(try store.save(name: name, chain: SignalChain.standard()), name)
        }
    }

    func testRenderArgumentsTakeAPresetFile() throws {
        let store = UserPresets(folder: folder)
        let chain = customChain()
        let url = try store.save(name: "CLI", chain: chain).url
        let args = try RenderArguments.parse(["in.mov", "out.mov", "--preset-file", url.path])
        XCTAssertEqual(args.presetFile, url.path)
        let target = SignalChain.standard()
        try args.apply(to: target)
        XCTAssertEqual(snapshot(target), snapshot(chain))
    }
}
