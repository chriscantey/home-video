import XCTest
@testable import HomeVideoCore

/// The sidecar is `<clip>.homevideo.json` and the format outlives versions: a newer file
/// loads what this version knows and keeps the rest, an older one migrates, a missing key takes
/// its default.
@MainActor
final class SidecarVersionTests: XCTestCase {
    var folder: URL!
    var support: URL!
    var clip: URL!
    var logged: [String] = []

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-sidecar-version-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("clips", isDirectory: true)
        support = root.appendingPathComponent("Sidecars", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        clip = folder.appendingPathComponent("IMG_5895.MOV")
        try Data("not a movie".utf8).write(to: clip)
        logged = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    func values(_ chain: SignalChain) -> [String] {
        var out: [String] = []
        for l in chain.layers {
            out.append("\(l.id) \(Looks.userSwitch(l).map(String.init) ?? "-")")
            out += l.parameters.map { "\(l.id).\($0.id)=\($0.value)" }
        }
        out.append("audio \(chain.audio.preset.rawValue)")
        for l in chain.audio.layers {
            out.append("\(l.id) \(l.enabled)")
            out += l.parameters.map { "\(l.id).\($0.id)=\($0.value)" }
        }
        return out
    }

    func rentalChain(cut: Double) -> SignalChain {
        let chain = SignalChain.standard()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(Looks.look(id: "rental")!)
        chain.vhs!.luma.setParameter("cut", to: .float(cut))
        chain.framing.mode = .cropCenter
        chain.framing.zoom = 1.37
        return chain
    }

    /// The current writer's dictionary for `chain`.
    func document(_ chain: SignalChain) throws -> [String: Any] {
        let data = try Sidecar.encode(chain: chain, name: clip.lastPathComponent, lookID: "rental")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func put(_ r: [String: Any], at url: URL) throws {
        try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    func root(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func canonical(_ r: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])
    }

    func session() -> SidecarSession {
        let s = SidecarSession(chain: SignalChain.standard(), fallbackFolder: support, delay: .milliseconds(10))
        s.log = { [unowned self] in self.logged.append($0) }
        return s
    }

    /// Sets `layer.parameter` in a file's dictionary, the way a change in the app would.
    func setting(_ r: [String: Any], layer: String, parameter: String, to value: Any) -> [String: Any] {
        var r = r
        var layers = r["layers"] as! [[String: Any]]
        let i = layers.firstIndex { $0["id"] as? String == layer }!
        var params = layers[i]["parameters"] as! [[String: Any]]
        let j = params.firstIndex { $0["id"] as? String == parameter }!
        params[j]["value"] = value
        layers[i]["parameters"] = params
        r["layers"] = layers
        return r
    }

    func testVersionAndMigrationList() {
        XCTAssertEqual(Sidecar.formatVersion, 2)
        XCTAssertEqual(Sidecar.kind, "homevideo-sidecar")
        XCTAssertEqual(Sidecar.suffix, ".homevideo.json")
        // Every step starts below this version, in order.
        let froms = Sidecar.migrations.map(\.from)
        XCTAssertEqual(froms, froms.sorted())
        XCTAssertTrue(froms.allSatisfy { $0 >= 1 && $0 < Sidecar.formatVersion })
    }

    func testFutureVersionLoadsAndKeepsWhatItDoesNotKnow() throws {
        let url = Sidecar.besideURL(for: clip)
        let source = rentalChain(cut: 2.137)
        var r = try document(source)
        r["formatVersion"] = 99
        r["futureKey"] = ["shape": "round", "count": 3] as [String: Any]
        r["trim"] = ["in": 5, "out": 10]
        var layers = r["layers"] as! [[String: Any]]
        let i = layers.firstIndex { $0["id"] as? String == "luma-bandwidth" }!
        var params = layers[i]["parameters"] as! [[String: Any]]
        params.append(["id": "future-knob", "value": 0.75])
        layers[i]["parameters"] = params
        layers[i]["futureLayerKey"] = "kept"
        layers.append(["id": "flux-capacitor", "enabled": true, "parameters": [["id": "gigawatts", "value": 1.21]]])
        r["layers"] = layers
        var framing = r["framing"] as! [String: Any]
        framing["tilt"] = 4
        r["framing"] = framing
        try put(r, at: url)
        let before = try Data(contentsOf: url)

        let s = session()
        XCTAssertNil(s.show(clip, currentLookID: nil), "a newer file loads")
        XCTAssertEqual(values(s.chain), values(source), "with what this version knows")
        XCTAssertEqual(s.trim, TrimRange(in: 5, out: 10))
        s.writeNow()
        XCTAssertEqual(try Data(contentsOf: url), before, "not rewritten without a change")

        s.chain.vhs!.luma.setParameter("cut", to: .float(2.5))
        s.changed(currentLookID: nil)
        s.debouncer.flush()

        let after = try root(at: url)
        XCTAssertEqual(after["formatVersion"] as? Int, 2, "written at this version")
        let future = after["futureKey"] as? [String: Any]
        XCTAssertEqual(future?["shape"] as? String, "round")
        XCTAssertEqual(future?["count"] as? Int, 3)
        XCTAssertEqual((after["framing"] as? [String: Any])?["tilt"] as? Int, 4)
        XCTAssertEqual(after["trim"] as? [String: Double], ["in": 5, "out": 10])
        let afterLayers = after["layers"] as! [[String: Any]]
        let luma = afterLayers.first { $0["id"] as? String == "luma-bandwidth" }!
        XCTAssertEqual(luma["futureLayerKey"] as? String, "kept")
        let lumaParams = luma["parameters"] as! [[String: Any]]
        XCTAssertEqual(lumaParams.first { $0["id"] as? String == "future-knob" }?["value"] as? Double, 0.75)
        XCTAssertEqual(lumaParams.first { $0["id"] as? String == "cut" }?["value"] as? Double, 2.5)
        let flux = afterLayers.first { $0["id"] as? String == "flux-capacitor" }
        XCTAssertNotNil(flux, "a layer this version does not have is kept")
        XCTAssertTrue(logged.contains { $0.contains("format version 99") }, "\(logged)")
    }

    func testVersion1LoadsAndWritesAsVersion2() throws {
        let url = Sidecar.besideURL(for: clip)
        let source = rentalChain(cut: 2.137)
        var v1 = try document(source)
        v1["formatVersion"] = nil
        v1["oldKey"] = "kept"
        try put(v1, at: url)

        let c = try Sidecar.read(url, into: SignalChain.standard())
        XCTAssertEqual(c.formatVersion, 1)

        let s = session()
        XCTAssertNil(s.show(clip, currentLookID: nil))
        XCTAssertEqual(values(s.chain), values(source))
        s.chain.vhs!.luma.setParameter("cut", to: .float(2.5))
        s.changed(currentLookID: nil)
        s.debouncer.flush()
        // The same file at version 2, with the one change.
        var expected = setting(v1, layer: "luma-bandwidth", parameter: "cut", to: 2.5)
        expected["formatVersion"] = 2
        XCTAssertEqual(try canonical(root(at: url)), try canonical(expected))
        XCTAssertTrue(logged.isEmpty, "\(logged)")
    }

    func testMissingKeysTakeTheDefaults() throws {
        let url = Sidecar.besideURL(for: clip)
        try put(["formatVersion": 2, "kind": "homevideo-sidecar"], at: url)
        let chain = rentalChain(cut: 2.137)
        let c = try Sidecar.read(url, into: chain)
        let defaults = SignalChain.standard()
        Presets(vhs: defaults.vhs!, audio: defaults.audio)
            .setLook(Look(id: "defaults", name: "Defaults", blurb: "", selection: PresetSelection(), overrides: []))
        XCTAssertEqual(values(chain), values(defaults))
        XCTAssertNil(c.lookID)
        XCTAssertNil(c.trim)
        let f = FramingLayer()
        XCTAssertEqual(c.framing, SidecarFraming(mode: f.mode, zoom: f.zoom, pan: f.pan, panY: f.panY, rotation: 0))
    }
}
