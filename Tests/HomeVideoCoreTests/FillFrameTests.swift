import Metal
import XCTest
@testable import HomeVideoCore

/// The Picture choice under the Output size, for anyone who wants the whole stage at the frame's
/// shape (emulating only film and keeping the clip's aspect ratio, say). 4:3 inside the frame is
/// the default. Fill the frame has every stage work at the frame's
/// shape, so the picture fills it with no bars and Framing's zoom and pan span the whole frame.
extension StageTests {
    private func size(_ c: SignalChain, _ size: OutputSize, fill: Bool = false, _ w: Double? = nil, _ h: Double? = nil) {
        let o = c.vhs!.output
        o.setParameter("size", to: .choice(size.rawValue))
        if let w { o.setParameter("width", to: .float(w)) }
        if let h { o.setParameter("height", to: .float(h)) }
        o.setParameter("fill", to: .bool(fill))
    }

    /// The sum of a pixel's three channels.
    private func level(_ out: (width: Int, height: Int, values: [Float]), _ x: Int, _ y: Int) -> Float {
        let i = (y * out.width + x) * 4
        return out.values[i] + out.values[i + 1] + out.values[i + 2]
    }

    /// A column's mean level down the middle half of the frame (a mean, since the tape's
    /// sharpening rings below black beside an edge).
    private func columnFloor(_ out: (width: Int, height: Int, values: [Float]), _ x: Int) -> Float {
        let v = stride(from: out.height / 4, to: out.height * 3 / 4, by: 7).map { level(out, x, $0) }
        return v.reduce(0, +) / Float(max(v.count, 1))
    }

    /// True when a column is a bar: exactly black down the middle half, as the fit's bars are.
    /// The tape's own right edge rings below black, which is picture, not a bar.
    private func isBar(_ out: (width: Int, height: Int, values: [Float]), _ x: Int) -> Bool {
        stride(from: out.height / 4, to: out.height * 3 / 4, by: 7).allSatisfy { level(out, x, $0) == 0 }
    }

    /// The choice shows only for a picked size that is not 4:3: hidden at Auto, SD and a 4:3
    /// Custom, shown at HD, 4K, a wide Custom and Match source with a 16:9 clip. Where hidden it
    /// does nothing, even when the value is set.
    func testThePictureChoiceShowsOnlyForASizeThatIsNot43() throws {
        let c = SignalChain.standard()
        size(c, .auto, fill: true)
        XCTAssertFalse(c.fillApplies)
        XCTAssertNil(c.fillAspect, "Auto")
        size(c, .sd, fill: true)
        XCTAssertFalse(c.fillApplies)
        XCTAssertNil(c.fillAspect, "SD")
        size(c, .custom, fill: true, 800, 600)
        XCTAssertFalse(c.fillApplies, "a 4:3 Custom")
        XCTAssertNil(c.fillAspect)
        size(c, .custom, fill: true, 1000, 500)
        XCTAssertTrue(c.fillApplies)
        XCTAssertEqual(try XCTUnwrap(c.fillAspect), 2, accuracy: 1e-9)
        size(c, .hd)
        XCTAssertTrue(c.fillApplies)
        XCTAssertNil(c.fillAspect, "4:3 inside is the default")
        XCTAssertEqual(c.vhs!.output.fill, false)
        size(c, .uhd, fill: true)
        XCTAssertEqual(try XCTUnwrap(c.fillAspect), 16.0 / 9, accuracy: 1e-9)
        // Match source follows the clip: a 16:9 clip shows it.
        let g = try GPUHarness()
        let m = chain(Stages())
        size(m, .source, fill: true)
        _ = try render(g, m, try source(g), frame: 0)
        XCTAssertTrue(m.fillApplies)
        XCTAssertEqual(try XCTUnwrap(m.fillAspect), 16.0 / 9, accuracy: 1e-9)
        // The parameter is live only off Auto and SD.
        let o = OutputSizeLayer()
        XCTAssertFalse(o.parameters.first { $0.id == "fill" }!.isActive)
        o.size = .hd
        XCTAssertTrue(o.parameters.first { $0.id == "fill" }!.isActive)
    }

    /// Where Fill cannot apply (Auto, SD) the picture is the same with it set, on every
    /// combination. A 4:3 inside chain hashes as it did before Fill existed, and Fill changes it.
    func testFillDoesNothingWhereItIsHidden() throws {
        let g = try GPUHarness()
        let src = try source(g)
        for s in Self.matrix where !s.recapture {
            for picked in [OutputSize.auto, .sd] {
                let a = chain(s), b = chain(s)
                size(a, picked)
                size(b, picked, fill: true)
                let x = try render(g, a, src, frame: 2), y = try render(g, b, src, frame: 2)
                XCTAssertEqual(x.width, y.width, "\(s) \(picked)")
                XCTAssertTrue(x.values == y.values, "\(s) \(picked): Fill changes nothing")
            }
        }
        let c = SignalChain.standard()
        let base = ChainFingerprint.of(c)
        size(c, .hd)
        let inside = ChainFingerprint.of(c)
        XCTAssertNotEqual(inside, base)
        size(c, .hd, fill: true)
        XCTAssertNotEqual(ChainFingerprint.of(c), inside, "Fill reaches the hash")
        size(c, .hd)
        XCTAssertEqual(ChainFingerprint.of(c), inside, "4:3 inside hashes as before Fill existed")
        size(c, .auto, fill: true)
        XCTAssertEqual(ChainFingerprint.of(c), base, "Fill at Auto hashes as the default")
    }

    /// Tape on, HD. 4:3 inside pillarboxes (black columns at both edges). Fill the frame fills
    /// 1920 by 1080 edge to edge at zoom 1 and at zoom 2, and the zoom spans the whole frame:
    /// zoom 2 shows the middle of the picture across the full width. The whole raster fills the
    /// frame, so its last columns are the tape's right blanking bar, as the last
    /// columns of the 4:3 picture are at 4:3 inside.
    func testFillWithTheTapeFillsHDAtEveryZoom() throws {
        let g = try GPUHarness()
        let src = try source(g)
        let inside = chain(Stages())
        size(inside, .hd)
        let bars = try render(g, inside, src, frame: 1)
        XCTAssertEqual(bars.width, 1920)
        XCTAssertTrue(isBar(bars, 4), "4:3 inside: the pillar is black")
        XCTAssertTrue(isBar(bars, 1915), "4:3 inside: the pillar is black")
        // The tape's raster has its own dark right edge in its blanking (the Frame layer's 17
        // sample bar), which the filled frame keeps, 17 / 720 of 1920 is 45 columns.
        let raster = try render(g, chain(Stages()), src, frame: 1)
        XCTAssertLessThan(columnFloor(raster, 719), 0.05, "the raster's own right edge")
        XCTAssertLessThan(columnFloor(bars, 1676), 0.05, "4:3 inside: the bar at the picture's right")
        var pictures: [[Float]] = []
        for zoom in [1.0, 2.0] {
            let c = chain(Stages())
            size(c, .hd, fill: true)
            c.framing.setParameter("zoom", to: .float(zoom))
            let out = try render(g, c, src, frame: 1)
            XCTAssertEqual(out.width, 1920, "zoom \(zoom)")
            XCTAssertEqual(out.height, 1080, "zoom \(zoom)")
            for x in [0, 1, 2, 4, 120, 960, 1800, 1850] {
                XCTAssertGreaterThan(columnFloor(out, x), 0.05, "zoom \(zoom): column \(x) is picture")
            }
            for x in [1890, 1915, 1918, 1919] {
                XCTAssertLessThan(columnFloor(out, x), 0.05, "zoom \(zoom): column \(x) is the tape's right bar")
            }
            for x in 0..<1920 { XCTAssertFalse(isBar(out, x), "zoom \(zoom): column \(x) is a fit's bar") }
            XCTAssertFalse(out.values.contains { $0.isNaN }, "zoom \(zoom)")
            pictures.append(out.values)
            // Framing's crop is the frame's shape: the whole 16:9 clip at zoom 1.
            XCTAssertEqual(c.framing.cropRect.width, 1 / zoom, accuracy: 1e-6, "zoom \(zoom)")
        }
        XCTAssertTrue(pictures[0] != pictures[1], "the zoom reaches the picture")
    }

    /// Film only (Tape off), Match source with a 16:9 clip: the scan canvas is the clip's shape
    /// at the scan's height, so Fit inside shows the whole clip with no bars at all, where 4:3
    /// inside letterboxes it in the 4:3 scan and then pillarboxes that.
    func testFillWithFilmOnlyKeepsTheClipsAspect() throws {
        let g = try GPUHarness()
        let src = try source(g)
        let inside = chain(Stages(film: true, tape: false))
        size(inside, .source)
        inside.framing.mode = .letterbox
        let barred = try render(g, inside, src, frame: 1)
        XCTAssertEqual(barred.width, 640)
        XCTAssertEqual(barred.height, 360)
        XCTAssertEqual(columnFloor(barred, 2), 0, "4:3 inside: a bar")
        let c = chain(Stages(film: true, tape: false))
        size(c, .source, fill: true)
        c.framing.mode = .letterbox
        let out = try render(g, c, src, frame: 1)
        XCTAssertEqual(out.width, 640)
        XCTAssertEqual(out.height, 360)
        XCTAssertTrue(c.naturalSize == (1920, 1080), "the Standard scan at the clip's shape")
        for x in [0, 2, 320, 637, 639] {
            XCTAssertGreaterThan(columnFloor(out, x), 0.02, "column \(x) is picture")
        }
        for y in [0, 1, 358, 359] {
            XCTAssertGreaterThan(level(out, 320, y), 0.02, "row \(y) is picture")
        }
    }

    /// Display on (Tape off and on), HD: the tube is 16:9, the same height as the 4:3 tube, and
    /// fills the frame where 4:3 inside leaves 240 px bars.
    func testFillWithTheDisplayFillsTheFrame() throws {
        let g = try GPUHarness()
        let src = try source(g)
        for tape in [false, true] {
            let c = chain(Stages(tape: tape, display: true))
            size(c, .hd, fill: true)
            XCTAssertTrue(c.naturalSize == (1920, 1080), "tape \(tape): a 16:9 tube")
            let out = try render(g, c, src, frame: 1)
            XCTAssertEqual(out.width, 1920)
            XCTAssertEqual(out.height, 1080)
            for x in [60, 120, 236, 960, 1700, 1860] {
                XCTAssertGreaterThan(level(out, x, 540), 0.05, "tape \(tape): column \(x) is the tube")
            }
            XCTAssertFalse(out.values.contains { $0.isNaN })
        }
    }

    /// Every combination renders at the frame's size under Fill, nothing NaN, and with no Display
    /// (whose tube has its own curved edge) the left edge is picture, and the right edge is
    /// picture or, with the tape last, the tape's own right bar. Every stage off is
    /// already the frame's shape, so Fill changes nothing there.
    func testFillOnEveryCombination() throws {
        let g = try GPUHarness()
        let src = try source(g)
        for s in Self.matrix {
            let c = chain(s)
            size(c, .custom, fill: true, 1000, 500)
            let out = try render(g, c, src, frame: 2)
            XCTAssertEqual(out.width, 1000, "\(s)")
            XCTAssertEqual(out.height, 500, "\(s)")
            XCTAssertFalse(out.values.contains { $0.isNaN }, "\(s)")
            if !s.display {
                XCTAssertGreaterThan(columnFloor(out, 0), 0.01, "\(s): the left edge is picture")
                if s.tape {
                    XCTAssertLessThan(columnFloor(out, 999), 0.05, "\(s): the right edge is the tape's bar")
                    XCTAssertGreaterThan(columnFloor(out, 960), 0.01, "\(s): picture beside the bar")
                } else {
                    XCTAssertGreaterThan(columnFloor(out, 999), 0.01, "\(s): the right edge is picture")
                }
            }
        }
        let a = chain(Stages(tape: false)), b = chain(Stages(tape: false))
        size(a, .hd)
        size(b, .hd, fill: true)
        XCTAssertTrue(try render(g, a, src, frame: 0).values == render(g, b, src, frame: 0).values,
                      "every stage off: Fill changes nothing")
    }

    /// The mean level change between two renders over rows `rows`, every third column.
    private func rowChange(_ a: (width: Int, height: Int, values: [Float]), _ b: (width: Int, height: Int, values: [Float]),
                           _ rows: Range<Int>) -> Float {
        var sum: Float = 0, n: Float = 0
        for y in rows {
            for x in stride(from: 0, to: a.width, by: 3) {
                sum += abs(level(a, x, y) - level(b, x, y))
                n += 1
            }
        }
        return sum / max(n, 1)
    }

    /// The band is there when switching the head switch off changes the picture's last rows and
    /// leaves its middle rows nearly as they were. `top` and `height` are the picture's rows.
    /// Returns the band's height as a share of the picture's: the rows of its last tenth that
    /// the switch changes.
    @discardableResult
    private func bandShows(_ on: (width: Int, height: Int, values: [Float]), _ off: (width: Int, height: Int, values: [Float]),
                           top: Int, height: Int, _ note: String, file: StaticString = #filePath, line: UInt = #line) -> Double {
        let last = top + height
        let band = rowChange(on, off, (last - height / 100)..<(last - 1))
        let middle = rowChange(on, off, (top + height / 2)..<(top + height / 2 + height / 100))
        XCTAssertGreaterThan(band, 0.05, "\(note): the band's rows change", file: file, line: line)
        XCTAssertGreaterThan(band, 4 * middle, "\(note): more than the middle rows (\(middle))", file: file, line: line)
        let changed = ((last - height / 10)..<last).filter { rowChange(on, off, $0..<($0 + 1)) > 0.02 }
        return Double(changed.count) / Double(height)
    }

    /// A 1080 by 1920 clip under a worn Look (Rental), Fit inside, at Match source, at Custom
    /// 1080 by 1920 and at Phone. Fill keeps the head switching band at the
    /// bottom and the tape's dark right edge, the way the 4:3 picture has them at 4:3 inside, at
    /// zoom 1 and 2, with no fit's bar anywhere, and Zoom and Pan Y move the window.
    func testFillOnAPortraitClipKeepsTheBandAndTheEdges() throws {
        let g = try GPUHarness()
        let src = try source(g, width: 1080, height: 1920)
        let rental = try XCTUnwrap(Looks.look(id: "rental"))
        func rented(_ picked: OutputSize, fill: Bool, zoom: Double = 1, panY: Double = 0, band: Bool = true) throws
            -> (width: Int, height: Int, values: [Float]) {
            let c = chain(Stages())
            Presets(vhs: c.vhs!, audio: c.audio).setLook(rental)
            if picked == .custom { size(c, .custom, fill: fill, 1080, 1920) } else { size(c, picked, fill: fill) }
            c.framing.mode = .letterbox
            c.framing.setParameter("zoom", to: .float(zoom))
            c.framing.setParameter("panY", to: .float(panY))
            c.vhs!.headSwitch.enabled = band
            _ = try render(g, c, src, frame: 3)
            XCTAssertEqual(c.fillAspect != nil, fill)
            XCTAssertTrue(c.framing.parameters.first { $0.id == "zoom" }!.isActive, "Zoom is live under Fit inside")
            return try render(g, c, src, frame: 4)
        }
        // 4:3 inside: the 4:3 picture is 1080 by 810, rows 555 to 1364, with the band at its
        // bottom and the bar at its right.
        let inside = try rented(.custom, fill: false)
        XCTAssertEqual(inside.width, 1080)
        XCTAssertEqual(inside.height, 1920)
        let share = bandShows(inside, try rented(.custom, fill: false, band: false), top: 555, height: 810, "4:3 inside")
        XCTAssertGreaterThan(share, 0.02, "4:3 inside: the band is about 15 of 480 lines")
        XCTAssertLessThan(columnFloor(inside, 1078), 0.05, "4:3 inside: the dark right edge")
        // The Phone size is the same 1080 by 1920 frame, so it runs the same probe.
        for picked in [OutputSize.source, .custom, .phone] {
            var pictures: [[Float]] = []
            for (zoom, panY) in [(1.0, 0.0), (2.0, -1.0), (2.0, 1.0)] {
                let note = "\(picked) zoom \(zoom) panY \(panY)"
                let out = try rented(picked, fill: true, zoom: zoom, panY: panY)
                XCTAssertEqual(out.width, 1080, note)
                XCTAssertEqual(out.height, 1920, note)
                XCTAssertFalse(out.values.contains { $0.isNaN }, note)
                // The whole band: the same share of the picture's height as at 4:3 inside
                // (measured 0.048 against 0.047).
                let filled = bandShows(out, try rented(picked, fill: true, zoom: zoom, panY: panY, band: false),
                                       top: 0, height: 1920, note)
                XCTAssertEqual(filled, share, accuracy: share * 0.1, "\(note): the whole band")
                // 17 / 720 of 1080 is 25 columns of the tape's bar.
                for x in [1065, 1075, 1079] {
                    XCTAssertLessThan(columnFloor(out, x), 0.05, "\(note): column \(x) is the tape's right bar")
                }
                for x in [0, 2, 540, 1000] {
                    XCTAssertGreaterThan(columnFloor(out, x), 0.05, "\(note): column \(x) is picture")
                }
                for y in [0, 2, 960, 1700] {
                    XCTAssertFalse((0..<1000).allSatisfy { level(out, $0, y) == 0 }, "\(note): row \(y) is a fit's bar")
                }
                pictures.append(out.values)
            }
            XCTAssertTrue(pictures[0] != pictures[1], "\(picked): the zoom reaches the picture")
            XCTAssertTrue(pictures[1] != pictures[2], "\(picked): Pan Y moves the window")
        }
    }

    /// Zoom and Pan are live under Fit inside as under Crop to fill, and off under Stretch.
    /// At zoom 1 the pans have no room under Fit inside, so they stay off. Fit inside at zoom 1
    /// renders the same picture whatever the pans say (FramingMathTests holds its rects to the
    /// bit).
    func testZoomAndPanAreLiveUnderFitInside() throws {
        func active(_ f: FramingLayer) -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: f.parameters.filter { ["zoom", "pan", "panY"].contains($0.id) }
                .map { ($0.id, $0.isActive) })
        }
        let f = FramingLayer(mode: .letterbox)
        XCTAssertEqual(active(f), ["zoom": true, "pan": false, "panY": false], "before a frame, zoom 1")
        f.zoom = 1.5
        XCTAssertEqual(active(f), ["zoom": true, "pan": true, "panY": true], "before a frame, zoomed")
        f.mode = .fullRaster
        XCTAssertEqual(active(f), ["zoom": false, "pan": false, "panY": false], "Stretch")
        let g = try GPUHarness()
        let src = try source(g)
        for picked in [OutputSize.auto, .hd] {
            let a = chain(Stages()), b = chain(Stages())
            for c in [a, b] {
                size(c, picked)
                c.framing.mode = .letterbox
            }
            b.framing.pan = 0.7
            b.framing.panY = -0.4
            let x = try render(g, a, src, frame: 2), y = try render(g, b, src, frame: 2)
            XCTAssertTrue(x.values == y.values, "\(picked): Fit inside at zoom 1 ignores the pans")
            // A 16:9 clip in the 4:3 picture: the pan across has room once zoomed, up and down none
            // until the zoom passes 4:3 over 16:9.
            a.framing.zoom = 1.2
            XCTAssertEqual(active(a.framing), ["zoom": true, "pan": true, "panY": false], "\(picked) zoom 1.2")
            a.framing.zoom = 2
            XCTAssertEqual(active(a.framing), ["zoom": true, "pan": true, "panY": true], "\(picked) zoom 2")
            let z = try render(g, a, src, frame: 2)
            XCTAssertTrue(z.values != x.values, "\(picked): the zoom reaches the picture")
        }
    }

    /// A sidecar saved before the Picture choice has no fill key and reads as 4:3 inside. Fill is
    /// written only
    /// when picked, round trips, and leaves the file when set back.
    func testTheSidecarCarriesFill() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-fill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov.homevideo.json")
        let old: [String: Any] = ["formatVersion": 2, "kind": "homevideo-sidecar", "name": "clip.mov",
                                  "output": ["size": "hd", "width": 1280, "height": 720]]
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let r = SignalChain.standard()
        r.vhs!.output.fill = true
        _ = try Sidecar.read(url, into: r)
        XCTAssertEqual(r.vhs!.output.size, .hd)
        XCTAssertFalse(r.vhs!.output.fill, "an older file reads as 4:3 inside")
        let a = SignalChain.standard()
        size(a, .hd)
        XCTAssertNil((Sidecar.record(chain: a, name: "x", lookID: nil, rotation: 0)["output"] as? [String: Any])?["fill"],
                     "4:3 inside writes no fill key")
        size(a, .hd, fill: true)
        let written = try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, to: url)
        let b = SignalChain.standard()
        _ = try Sidecar.read(url, into: b)
        XCTAssertTrue(b.vhs!.output.fill)
        XCTAssertNotNil(b.fillAspect)
        size(a, .hd)
        let again = try Sidecar.write(chain: a, name: "clip.mov", lookID: nil, preserving: written, to: url)
        XCTAssertNil((again["output"] as? [String: Any])?["fill"], "set back, the key leaves the file")
        let c = SignalChain.standard()
        c.vhs!.output.fill = true
        _ = try Sidecar.read(url, into: c)
        XCTAssertFalse(c.vhs!.output.fill)
    }

    /// `--set output.fill=on` reaches the layer, and the clipboard carries it with the size.
    func testFillGoesThroughSetAndTheClipboard() throws {
        let c = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--set", "output.size=hd", "--set", "output.fill=on"])
            .apply(to: c)
        XCTAssertEqual(c.vhs!.output.size, .hd)
        XCTAssertTrue(c.vhs!.output.fill)
        XCTAssertNotNil(c.fillAspect)
        let d = SignalChain.standard()
        try SettingsClipboard.apply(SettingsClipboard.encode(c), to: d)
        XCTAssertEqual(d.vhs!.output.size, .hd)
        XCTAssertTrue(d.vhs!.output.fill, "the clipboard carries Fill")
        try RenderArguments.parse(["in.mov", "out.mov", "--set", "output.fill=off"]).apply(to: c)
        XCTAssertFalse(c.vhs!.output.fill)
        XCTAssertNil(c.fillAspect)
    }
}
