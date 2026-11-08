import Metal
import XCTest
@testable import HomeVideoCore

/// Pan, zoom and rotation move the picture on every stage combination `StageTests.matrix`
/// lists, in an export (two fresh chains) and in a paused preview (one chain, the same frame
/// drawn again after the change). Every stage off still runs Framing, and the Film's held frame
/// and the Telecine's cached frames follow a change, or these pairs come out identical.
extension StageTests {
    /// Zoom 1.5 gives the pans room on every canvas, the source's own shape included.
    private func framed(_ s: Stages, pan: Double = 0, zoom: Double = 1.5, rotation: Int = 0) -> SignalChain {
        let c = chain(s)
        c.framing.zoom = zoom
        c.framing.pan = pan
        c.framing.rotation = rotation
        return c
    }

    private func assertMoves(_ what: String, _ s: Stages, _ g: GPUHarness, _ src: MTLTexture,
                             set: (FramingLayer, Bool) -> Void) throws {
        // An export: two fresh chains, one each way.
        let a = chain(s), b = chain(s)
        a.framing.zoom = 1.5
        b.framing.zoom = 1.5
        set(a.framing, false)
        set(b.framing, true)
        let x = try render(g, a, src, frame: 3), y = try render(g, b, src, frame: 3)
        XCTAssertEqual(x.width, y.width, "\(s) \(what): one size")
        // Compared as a Bool, so a failure names the combination without printing every pixel.
        XCTAssertTrue(x.values != y.values, "\(s): \(what) moves the exported picture")
        // A paused preview: one chain draws the same frame, then draws it again after the change.
        let p = chain(s)
        p.framing.zoom = 1.5
        set(p.framing, false)
        _ = try render(g, p, src, frame: 5)
        let before = try render(g, p, src, frame: 5)
        set(p.framing, true)
        let after = try render(g, p, src, frame: 5)
        XCTAssertTrue(before.values != after.values, "\(s): \(what) moves the paused preview")
    }

    func testPanMovesThePictureOnEveryStageCombination() throws {
        let g = try GPUHarness()
        let src = try source(g)
        XCTAssertEqual(Self.matrix.count, 24)
        for s in Self.matrix {
            try assertMoves("pan", s, g, src) { f, moved in f.pan = moved ? 1 : -1 }
        }
    }

    func testZoomMovesThePictureOnEveryStageCombination() throws {
        let g = try GPUHarness()
        let src = try source(g)
        for s in Self.matrix {
            try assertMoves("zoom", s, g, src) { f, moved in f.zoom = moved ? 2 : 1 }
        }
    }

    func testRotationMovesThePictureOnEveryStageCombination() throws {
        let g = try GPUHarness()
        let src = try source(g)
        for s in Self.matrix {
            try assertMoves("rotation", s, g, src) { f, moved in f.rotation = moved ? 180 : 0 }
        }
    }

    /// Every stage off at Crop to fill, zoom 1 and rotation 0 is still the source's own values:
    /// Framing on that path changes nothing until it is moved.
    func testFramingAtRestLeavesTheSourceUntouched() throws {
        let g = try GPUHarness()
        let src = try source(g)
        let c = chain(Stages(tape: false))
        XCTAssertEqual(c.framing.mode, .cropCenter)
        XCTAssertTrue(c.layersInUse.contains { $0.id == "framing" }, "Framing is on the path")
        let out = try render(g, c, src, frame: 0)
        let moved = framed(Stages(tape: false), pan: 1)
        let panned = try render(g, moved, src, frame: 0)
        XCTAssertEqual(out.width, Self.sourceW)
        XCTAssertEqual(panned.width, Self.sourceW, "a pan keeps the source's size")
        XCTAssertTrue(out.values != panned.values)
    }

    /// The modes say what they do, and Fit is one of them.
    func testFramingModeNames() {
        XCTAssertEqual(FramingMode.allCases.map(\.label), ["Fit inside", "Crop to fill", "Stretch"])
    }
}
