import AVFoundation
import Metal
import XCTest
@testable import HomeVideoCore

/// The Output size is the file's size whatever the stages do, the last stage's picture fitted
/// inside it whole. Auto is the last stage's size. Custom clamps to even numbers in range.
/// The Display's Detail never changes the file's size.
extension StageTests {
    private func pick(_ c: SignalChain, _ size: OutputSize, _ w: Double? = nil, _ h: Double? = nil) {
        let o = c.vhs!.output
        o.setParameter("size", to: .choice(size.rawValue))
        if let w { o.setParameter("width", to: .float(w)) }
        if let h { o.setParameter("height", to: .float(h)) }
    }

    /// Every option writes its size, through the real exporter, with the Tape on and with the
    /// Display on, from a 640 by 360 clip.
    func testEveryOutputSizeWritesItsSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mov")
        try await ClipListTests.writeMovie(to: src, width: 640, height: 360, frames: 2)
        let cases: [(OutputSize, Int, Int, Int, Int)] = [
            // size, Tape on (w, h), Display on (w, h)
            (.auto, 720, 480, 1440, 1080),
            (.source, 640, 360, 640, 360),
            (.sd, 720, 480, 720, 480),
            (.hd, 1920, 1080, 1920, 1080),
            (.uhd, 3840, 2160, 3840, 2160),
            (.phone, 1080, 1920, 1080, 1920),
            (.custom, 1000, 500, 1000, 500),
        ]
        for (size, tw, th, dw, dh) in cases {
            for display in [false, true] {
                let chain = SignalChain.standard()
                pick(chain, size, 1000, 500)
                if display { chain.vhs!.crt.beam.enabled = true }
                let out = dir.appendingPathComponent("\(size.rawValue)-\(display).mov")
                _ = try await Exporter(source: src, destination: out, chain: chain, settings: .master).run()
                let track = try await XCTUnwrapAsync(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
                let f = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
                let d = CMVideoFormatDescriptionGetDimensions(f)
                XCTAssertEqual(Int(d.width), display ? dw : tw, "\(size) display \(display) width")
                XCTAssertEqual(Int(d.height), display ? dh : th, "\(size) display \(display) height")
            }
        }
    }

    /// Auto is the last stage's picture itself on every combination: the same texture size and
    /// the same values as a chain whose Output size was never touched, and nothing in a file.
    func testAutoIsTheUntouchedSize() throws {
        let g = try GPUHarness()
        let src = try source(g)
        for s in Self.matrix where !s.recapture {
            let a = chain(s), b = chain(s)
            pick(b, .hd)
            pick(b, .auto)
            let x = try render(g, a, src, frame: 2), y = try render(g, b, src, frame: 2)
            XCTAssertEqual(x.width, y.width, "\(s)")
            XCTAssertTrue(x.values == y.values, "\(s): Auto changes nothing")
        }
        let c = SignalChain.standard()
        let before = ChainFingerprint.of(c)
        pick(c, .hd)
        XCTAssertNotEqual(ChainFingerprint.of(c), before)
        pick(c, .auto)
        XCTAssertEqual(ChainFingerprint.of(c), before, "the default chain hashes as if the size was never touched")
        XCTAssertNil(Sidecar.record(chain: c, name: "x", lookID: nil, rotation: 0)["output"])
    }

    /// Match source is the clip's own size before any export, on every stage combination, so the
    /// preview and the Look tab's caption never fall back to the tape's 720 by 480 while a stage
    /// is on.
    func testMatchSourceIsTheClipsSizeInThePreview() throws {
        let g = try GPUHarness()
        let src = try source(g, width: 640, height: 360)
        for s in Self.matrix where !s.recapture {
            let c = chain(s)
            pick(c, .source)
            let out = try render(g, c, src, frame: 1)
            XCTAssertEqual(c.outputSize.width, 640, "\(s): the caption's width")
            XCTAssertEqual(c.outputSize.height, 360, "\(s): the caption's height")
            XCTAssertEqual(out.width, 640, "\(s): the preview's width")
            XCTAssertEqual(out.height, 360, "\(s): the preview's height")
        }
    }

    func testCustomClampsToEvenSaneSizes() {
        let o = OutputSizeLayer()
        o.setParameter("width", to: .float(7))
        o.setParameter("height", to: .float(5))
        XCTAssertEqual(o.width, 128)
        XCTAssertEqual(o.height, 96)
        o.setParameter("width", to: .float(99999))
        o.setParameter("height", to: .float(99999))
        XCTAssertEqual(o.width, 7680)
        XCTAssertEqual(o.height, 4320)
        o.setParameter("width", to: .float(1001))
        o.setParameter("height", to: .float(333))
        XCTAssertEqual(o.width % 2, 0)
        XCTAssertEqual(o.height % 2, 0)
        XCTAssertEqual(o.width, 1002)
        XCTAssertEqual(o.height, 334)
        o.setParameter("width", to: .float(.nan))
        XCTAssertEqual(o.width, 128)
        XCTAssertEqual(OutputSize.allCases.map(\.label),
                       ["Auto", "Match source", "SD 720×480", "HD 1920×1080", "4K 3840×2160", "Phone 1080×1920", "Custom"])
    }

    /// HD with the Display on: the 4:3 tube pillarboxed in 1920 by 1080, black bars of 240 px
    /// each side, the picture whole between them. Never cropped: the tube's own edges are there.
    func testHDPillarboxesTheTube() throws {
        let g = try GPUHarness()
        let src = try source(g)
        let c = chain(Stages(tape: false, display: true))
        pick(c, .hd)
        XCTAssertEqual(c.output, .display, "square pixels with the raster's tags")
        let out = try render(g, c, src, frame: 1)
        XCTAssertEqual(out.width, 1920)
        XCTAssertEqual(out.height, 1080)
        func luma(_ x: Int, _ y: Int) -> Float {
            let i = (y * out.width + x) * 4
            return out.values[i] + out.values[i + 1] + out.values[i + 2]
        }
        var barPeak: Float = 0, picturePeak: Float = 0
        for y in stride(from: 0, to: 1080, by: 9) {
            for x in [0, 100, 236, 1683, 1800, 1919] { barPeak = max(barPeak, luma(x, y)) }
            for x in [400, 960, 1500] { picturePeak = max(picturePeak, luma(x, y)) }
        }
        XCTAssertEqual(barPeak, 0, "the bars are black")
        XCTAssertGreaterThan(picturePeak, 0.3, "the tube is between them")
        // SD writes the raster's own pixels and tags, any other picked size of the tape's
        // picture square pixels with the raster's tags.
        let t = chain(Stages())
        pick(t, .sd)
        XCTAssertEqual(t.output, .raster)
        pick(t, .hd)
        XCTAssertEqual(t.output, .display)
        let s = chain(Stages(tape: false))
        pick(s, .hd)
        XCTAssertEqual(s.output, .source, "the source keeps its 709")
    }

    /// The Display's Detail (Standard, High, Max) changes how fine the tube is drawn, never the
    /// file's size, and the picture differs between them.
    func testDisplayDetailNeverChangesTheFileSize() throws {
        let g = try GPUHarness()
        let src = try source(g)
        var pictures: [[Float]] = []
        for detail in DisplaySize.allCases {
            let c = chain(Stages(tape: false, display: true))
            c.vhs!.crt.display.setParameter("size", to: .choice(detail.rawValue))
            XCTAssertTrue(c.outputSize == (1440, 1080), "\(detail)")
            let out = try render(g, c, src, frame: 1)
            XCTAssertEqual(out.width, 1440, "\(detail)")
            XCTAssertEqual(out.height, 1080, "\(detail)")
            pictures.append(out.values)
        }
        XCTAssertTrue(pictures[0] != pictures[2], "the Detail reaches the picture")
        XCTAssertEqual(DisplaySize.allCases.map(\.label), ["Standard", "High", "Max"])
    }

    /// With every stage off, Crop to fill fills a picked size and Fit inside bars it.
    func testEveryStageOffFillsThePickedSize() throws {
        let g = try GPUHarness()
        let src = try source(g)
        let c = chain(Stages(tape: false))
        pick(c, .sd)
        let crop = try render(g, c, src, frame: 0)
        XCTAssertEqual(crop.width, 720)
        XCTAssertEqual(crop.height, 480)
        XCTAssertGreaterThan(crop.values[0] + crop.values[1] + crop.values[2], 0, "the corner is picture")
        c.framing.mode = .letterbox
        let fit = try render(g, c, src, frame: 0)
        XCTAssertEqual(fit.values[0] + fit.values[1] + fit.values[2], 0, "the corner is a bar")
    }

    /// The sidecar carries a picked size beside Framing, and Auto leaves the file.
    func testTheSidecarCarriesTheOutputSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov.homevideo.json")
        let a = SignalChain.standard()
        pick(a, .custom, 800, 600)
        let written = try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, to: url)
        let b = SignalChain.standard()
        _ = try Sidecar.read(url, into: b)
        XCTAssertEqual(b.vhs!.output.size, .custom)
        XCTAssertTrue(b.outputSize == (800, 600))
        pick(a, .auto)
        let again = try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, preserving: written, to: url)
        XCTAssertNil(again["output"], "back at Auto the file has no Output size")
        let c = SignalChain.standard()
        pick(c, .hd)
        _ = try Sidecar.read(url, into: c)
        XCTAssertEqual(c.vhs!.output.size, .auto)
    }

    /// Phone is a fixed 1080 by 1920 between 4K and Custom. It resolves to its size whatever the stages make,
    /// hides Custom's fields, shows the Picture choice at 4:3 inside, and goes through the sidecar,
    /// `--set` and the clipboard as `"phone"`. No Look sets it.
    func testPhoneIsAFixedPortraitSize() throws {
        XCTAssertEqual(OutputSize.allCases.suffix(3), [.uhd, .phone, .custom])
        XCTAssertEqual(OutputSize.phone.rawValue, "phone")
        XCTAssertTrue(OutputSize.phone.fixed! == (1080, 1920))
        let o = OutputSizeLayer()
        o.setParameter("size", to: .choice("phone"))
        XCTAssertEqual(o.size, .phone)
        XCTAssertTrue(o.resolve(natural: (720, 480), source: (1920, 1080)) == (1080, 1920))
        XCTAssertTrue(o.resolve(natural: (1440, 1080), source: (0, 0)) == (1080, 1920))
        let active = Dictionary(uniqueKeysWithValues: o.parameters.map { ($0.id, $0.isActive) })
        XCTAssertEqual(active["width"], false, "Custom's width is hidden")
        XCTAssertEqual(active["height"], false, "Custom's height is hidden")
        XCTAssertEqual(active["fill"], true)

        let c = SignalChain.standard()
        pick(c, .phone)
        XCTAssertTrue(c.outputSize == (1080, 1920))
        XCTAssertTrue(c.fillApplies, "the Picture choice shows")
        XCTAssertNil(c.fillAspect, "4:3 inside is the default")
        c.vhs!.output.fill = true
        XCTAssertEqual(try XCTUnwrap(c.fillAspect), 9.0 / 16, accuracy: 1e-9)
        c.vhs!.output.fill = false

        // The sidecar writes "phone" and reads it back.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-phone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov.homevideo.json")
        let written = try Sidecar.write(chain: c, name: "clip.mov", lookID: nil, to: url)
        XCTAssertEqual((written["output"] as? [String: Any])?["size"] as? String, "phone")
        let b = SignalChain.standard()
        _ = try Sidecar.read(url, into: b)
        XCTAssertEqual(b.vhs!.output.size, .phone)
        XCTAssertFalse(b.vhs!.output.fill)

        // `--set` and the clipboard.
        let s = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--set", "output.size=phone"]).apply(to: s)
        XCTAssertEqual(s.vhs!.output.size, .phone)
        XCTAssertTrue(s.outputSize == (1080, 1920))
        let d = SignalChain.standard()
        try SettingsClipboard.apply(SettingsClipboard.encode(s), to: d)
        XCTAssertEqual(d.vhs!.output.size, .phone)

        // No Look moves the Output size.
        for look in Looks.all {
            let l = SignalChain.standard()
            Presets(vhs: l.vhs!, audio: l.audio).setLook(look)
            XCTAssertEqual(l.vhs!.output.size, .auto, look.id)
        }
    }
}
