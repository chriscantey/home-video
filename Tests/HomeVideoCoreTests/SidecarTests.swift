import XCTest
@testable import HomeVideoCore

/// A clip's settings persist beside it. Write then read gives every value back, a
/// malformed sidecar changes nothing, a burst of changes writes once, a removed clip reads as
/// missing and one on an unmounted volume as not mounted, and an outside edit reloads.
@MainActor
final class SidecarTests: XCTestCase {
    var folder: URL!
    var support: URL!
    var clip: URL!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-sidecar-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("clips", isDirectory: true)
        support = root.appendingPathComponent("Sidecars", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        clip = folder.appendingPathComponent("IMG_5895.MOV")
        try Data("not a movie".utf8).write(to: clip)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    /// Every layer's switch and values, the audio preset and layers, and the framing.
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

    /// Rental with values no Look has, cropped and turned.
    func customChain() -> SignalChain {
        let chain = SignalChain.standard()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(Looks.look(id: "rental")!)
        chain.vhs!.luma.setParameter("cut", to: .float(2.137))
        chain.vhs!.generation.enabled = true
        chain.vhs!.capture.setParameter("deinterlace", to: .choice(Deinterlace.blend.rawValue))
        chain.audio.preset = AudioPreset.allCases.last!
        if let a = chain.audio.layers.first, let p = a.parameters.first(where: { $0.value.doubleValue != nil }) {
            a.setParameter(p.id, to: .float((p.value.doubleValue ?? 0) * 0.5 + 0.01))
        }
        chain.framing.mode = .cropCenter
        chain.framing.zoom = 1.37
        chain.framing.pan = 0.25
        chain.framing.panY = -0.4
        chain.framing.rotation = 90
        return chain
    }

    func testFileNameIsBesideTheClip() {
        XCTAssertEqual(Sidecar.besideURL(for: clip).lastPathComponent, "IMG_5895.MOV.homevideo.json")
        XCTAssertEqual(Sidecar.besideURL(for: clip).deletingLastPathComponent().standardizedFileURL,
                       folder.standardizedFileURL)
        let fallback = Sidecar.fallbackURL(for: clip, folder: support)
        XCTAssertEqual(fallback.deletingLastPathComponent(), support)
        XCTAssertEqual(fallback.lastPathComponent.count, 64 + 5)
        XCTAssertEqual(fallback, Sidecar.fallbackURL(for: clip, folder: support), "stable")
    }

    func testWriteThenReadGivesEveryValueBack() throws {
        let source = customChain()
        let url = Sidecar.besideURL(for: clip)
        try Sidecar.write(chain: source, name: clip.lastPathComponent, lookID: "rental", to: url)

        let target = SignalChain.standard()
        XCTAssertNotEqual(values(target), values(source))
        let c = try Sidecar.read(url, into: target)
        XCTAssertEqual(values(target), values(source))
        XCTAssertEqual(c.name, "IMG_5895.MOV")
        XCTAssertEqual(c.lookID, "rental")
        XCTAssertEqual(c.framing, SidecarFraming(mode: .cropCenter, zoom: 1.37, pan: 0.25, panY: -0.4, rotation: 90))

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["kind"] as? String, "homevideo-sidecar")
        XCTAssertEqual(root["formatVersion"] as? Int, 2)
        XCTAssertEqual(root["version"] as? Int, 1)
        // The preset reader reads the same file, so one reader serves both.
        XCTAssertNoThrow(try UserPresets.read(url))
    }

    func testNoLookWritesNull() throws {
        let url = Sidecar.besideURL(for: clip)
        try Sidecar.write(chain: customChain(), name: "x", lookID: nil, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"look\" : null"), text)
        XCTAssertNil(try Sidecar.read(url, into: SignalChain.standard()).lookID)
    }

    func testMalformedSidecarIsRejectedWithoutChanges() throws {
        let url = Sidecar.besideURL(for: clip)
        try Sidecar.write(chain: customChain(), name: clip.lastPathComponent, lookID: nil, to: url)
        let good = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])

        var cases: [(String, Data)] = [("not json", Data("{ nope".utf8)), ("array", Data("[1]".utf8))]
        func variant(_ name: String, _ edit: (inout [String: Any]) -> Void) throws {
            var r = good
            edit(&r)
            cases.append((name, try JSONSerialization.data(withJSONObject: r)))
        }
        // A missing key takes its default, an unknown layer is kept and ignored and a newer
        // version loads (SidecarVersionTests covers those). A wrong type is malformed.
        try variant("no kind") { $0["kind"] = nil }
        try variant("another kind") { $0["kind"] = "some-other-sidecar" }
        try variant("formatVersion a string") { $0["formatVersion"] = "2" }
        try variant("formatVersion 0") { $0["formatVersion"] = 0 }
        try variant("framing a string") { $0["framing"] = "wide" }
        try variant("bad mode") { r in var f = r["framing"] as! [String: Any]; f["mode"] = "sideways"; r["framing"] = f }
        try variant("zoom a string") { r in var f = r["framing"] as! [String: Any]; f["zoom"] = "big"; r["framing"] = f }
        try variant("look a number") { $0["look"] = 3 }
        try variant("bad value in a known layer") { r in
            var l = r["layers"] as! [[String: Any]]
            let i = l.firstIndex { !(($0["parameters"] as? [Any]) ?? []).isEmpty }!
            var p = l[i]["parameters"] as! [[String: Any]]
            p[0]["value"] = ["not": "a value"]
            l[i]["parameters"] = p
            r["layers"] = l
        }
        try variant("bad audio") { $0["audio"] = "wax-cylinder" }

        for (name, data) in cases {
            try data.write(to: url)
            let chain = SignalChain.standard()
            let before = values(chain)
            XCTAssertThrowsError(try Sidecar.read(url, into: chain), name)
            XCTAssertEqual(values(chain), before, "\(name) changed the chain")
        }
    }

    func testDebounceBurstWritesOnce() async throws {
        let chain = SignalChain.standard()
        let session = SidecarSession(chain: chain, fallbackFolder: support, delay: .milliseconds(150))
        var writes = 0
        session.onWrite = { _, _ in writes += 1 }
        session.show(clip, currentLookID: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.besideURL(for: clip).path),
                       "a clip opened without a sidecar gets none until something changes")

        for i in 0..<12 {
            chain.vhs!.luma.setParameter("cut", to: .float(2.0 + Double(i) * 0.01))
            session.changed(currentLookID: nil)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(writes, 0, "nothing lands inside the burst")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(session.sidecarURL, Sidecar.besideURL(for: clip))

        // A notification that changed nothing writes nothing.
        session.changed(currentLookID: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(writes, 1)

        let back = SignalChain.standard()
        try Sidecar.read(Sidecar.besideURL(for: clip), into: back)
        XCTAssertEqual(values(back), values(chain))
    }

    func testSwitchingClipsFlushesAndLoadsEachClipsOwn() throws {
        let other = folder.appendingPathComponent("IMG_0001.MOV")
        try Data("x".utf8).write(to: other)
        let chain = SignalChain.standard()
        let session = SidecarSession(chain: chain, fallbackFolder: support, delay: .seconds(60))
        session.show(clip, currentLookID: nil)
        chain.vhs!.luma.setParameter("cut", to: .float(2.25))
        session.changed(currentLookID: nil)
        // Switching inside the quiet period writes the first clip's values to the first clip.
        session.show(other, currentLookID: nil)
        chain.vhs!.luma.setParameter("cut", to: .float(1.75))
        session.changed(currentLookID: nil)
        session.writeNow()
        session.show(clip, currentLookID: nil)
        XCTAssertEqual(chain.vhs!.luma.parameters.first { $0.id == "cut" }?.value, .float(2.25))
        session.show(other, currentLookID: nil)
        XCTAssertEqual(chain.vhs!.luma.parameters.first { $0.id == "cut" }?.value, .float(1.75))
    }

    func testReadOnlyFolderFallsBackToSupport() throws {
        let chain = SignalChain.standard()
        let session = SidecarSession(chain: chain, fallbackFolder: support)
        session.isWritable = { _ in false }
        session.show(clip, currentLookID: nil)
        chain.framing.zoom = 1.5
        chain.framing.mode = .cropCenter
        session.changed(currentLookID: nil)
        session.writeNow()
        let expected = Sidecar.fallbackURL(for: clip, folder: support)
        XCTAssertEqual(session.sidecarURL, expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.besideURL(for: clip).path))
        XCTAssertEqual(Sidecar.existing(for: clip, fallbackFolder: support), expected)
        var shown = OpenClip(url: clip)
        shown.sidecar = expected
        XCTAssertTrue(shown.sidecarIsFallback)
    }

    func testRealReadOnlyFolderFallsBackToSupport() throws {
        let chain = SignalChain.standard()
        let session = SidecarSession(chain: chain, fallbackFolder: support)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        session.show(clip, currentLookID: nil)
        chain.framing.mode = .fullRaster
        session.changed(currentLookID: nil)
        session.writeNow()
        XCTAssertEqual(session.sidecarURL, Sidecar.fallbackURL(for: clip, folder: support))
    }

    func testExternalEditIsDetectedByDate() throws {
        let chain = SignalChain.standard()
        let session = SidecarSession(chain: chain, fallbackFolder: support)
        session.show(clip, currentLookID: nil)
        chain.vhs!.luma.setParameter("cut", to: .float(2.2))
        session.changed(currentLookID: nil)
        session.writeNow()
        XCTAssertFalse(session.reloadIfEditedOutside(), "our own write is no outside edit")

        // Another copy of the app (or a text editor) writes a different value, later.
        let url = Sidecar.besideURL(for: clip)
        let edited = SignalChain.standard()
        edited.vhs!.luma.setParameter("cut", to: .float(1.6))
        try Sidecar.write(chain: edited, name: clip.lastPathComponent, lookID: nil, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        XCTAssertTrue(session.reloadIfEditedOutside())
        XCTAssertEqual(chain.vhs!.luma.parameters.first { $0.id == "cut" }?.value, .float(1.6))
        XCTAssertFalse(session.reloadIfEditedOutside(), "once per edit")
    }

    func testForgetDeletesAndGoesBackToTheLook() throws {
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        let rental = Looks.look(id: "rental")!
        presets.setLook(rental)
        let session = SidecarSession(chain: chain, fallbackFolder: support)
        session.show(clip, currentLookID: "rental")
        chain.vhs!.luma.setParameter("cut", to: .float(2.4))
        session.changed(currentLookID: presets.look?.id)
        session.writeNow()
        XCTAssertNotNil(Sidecar.existing(for: clip, fallbackFolder: support))
        XCTAssertEqual(session.lookID, "rental")

        session.forget(clip, look: Looks.anyLook(id: session.lookID ?? ""))
        XCTAssertNil(Sidecar.existing(for: clip, fallbackFolder: support))
        XCTAssertEqual(presets.look?.id, "rental")
        session.changed(currentLookID: presets.look?.id)
        XCTAssertFalse(session.debouncer.isPending, "forgetting writes no new sidecar")
    }

    // MARK: presence

    func testRemovedFileReadsAsMissing() throws {
        XCTAssertEqual(ClipOnDisk.presence(of: clip), .present)
        let away = folder.appendingPathComponent("moved.MOV")
        try FileManager.default.moveItem(at: clip, to: away)
        XCTAssertEqual(ClipOnDisk.presence(of: clip), .missing)
        XCTAssertEqual(ClipPresenceState.missing.badge, "missing")
        try FileManager.default.moveItem(at: away, to: clip)
        XCTAssertEqual(ClipOnDisk.presence(of: clip), .present)
        XCTAssertNil(ClipPresenceState.present.badge)
    }

    func testUnmountedVolumeReadsAsNotMounted() {
        let url = URL(fileURLWithPath: "/Volumes/HomeVideoNoSuchDrive-\(UUID().uuidString)/clips/IMG_5895.MOV")
        XCTAssertEqual(ClipOnDisk.presence(of: url), .volumeNotMounted)
        XCTAssertEqual(ClipPresenceState.volumeNotMounted.badge, "volume not mounted")
        XCTAssertEqual(ClipOnDisk.expectedVolumeRoot(forPath: url.path),
                       "/Volumes/" + url.pathComponents[2])
    }

    func testMountedVolumeWithoutTheFileReadsAsMissing() {
        let p = "/Volumes/Drive/clips/a.mov"
        XCTAssertEqual(ClipOnDisk.presence(ofPath: p, exists: { _ in false }, mountedVolumePaths: { ["/Volumes/Drive/"] }),
                       .missing)
        XCTAssertEqual(ClipOnDisk.presence(ofPath: p, exists: { _ in false }, mountedVolumePaths: { [] }),
                       .volumeNotMounted)
        // A link in the home folder to an ejected drive is not mounted, not missing.
        XCTAssertEqual(ClipOnDisk.presence(ofPath: "/Users/Shared/Movies/a.mov", exists: { _ in false },
                                           symlinkTarget: { $0 == "/Users/Shared/Movies/a.mov" ? p : nil },
                                           mountedVolumePaths: { [] }),
                       .volumeNotMounted)
    }

    func testWatcherFiresOnAFolderChange() async throws {
        var checks = 0
        let presence = ClipPresence(interval: 60) { checks += 1 }
        presence.watch(folders: [folder])
        XCTAssertEqual(presence.watchedPaths, [folder.standardizedFileURL.path])
        try FileManager.default.moveItem(at: clip, to: folder.appendingPathComponent("moved.MOV"))
        for _ in 0..<40 where checks == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(checks, 0)
        presence.stop()
        XCTAssertTrue(presence.watchedPaths.isEmpty)
    }

    func testClipListKeepsPresenceAndSidecar() {
        final class Fake {}
        let list = ClipList<Fake>(makeSource: { _ in Fake() }, closeSource: { _ in },
                                  loadInfo: { _ in ClipInfo(duration: 0, poster: nil) })
        var hidden: [URL] = []
        list.onWillHide = { hidden.append($0.url) }
        let other = folder.appendingPathComponent("b.mov")
        list.open(clip)
        list.open(other)
        XCTAssertEqual(hidden, [clip])
        list.setPresence(.missing, for: clip)
        list.setSidecar(Sidecar.besideURL(for: clip), for: clip)
        XCTAssertEqual(list.clips[0].presence, .missing)
        XCTAssertEqual(list.clips[0].sidecar, Sidecar.besideURL(for: clip))
        XCTAssertFalse(list.clips[0].sidecarIsFallback)
        list.remove(at: 1)
        XCTAssertEqual(hidden, [clip, other])
    }
}
