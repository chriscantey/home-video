import XCTest
@testable import HomeVideoCore

/// The status bar's readout holds one width whatever the numbers, and carries no error count.
final class StatusReadoutTests: XCTestCase {
    func testFrameCountIsGroupedAndPadded() {
        XCTAssertEqual(StatusReadout.grouped(4263), "4,263")
        XCTAssertEqual(StatusReadout.grouped(999), "999")
        XCTAssertEqual(StatusReadout.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(StatusReadout.frame(0).count, StatusReadout.frame(99_999).count)
        XCTAssertEqual(StatusReadout.frame(4263).count, "frame 00,000".count)
    }

    func testPerformanceWidthDoesNotMoveWithTheNumbers() {
        var small = PreviewCounters()
        small.newFrames = 0
        var big = PreviewCounters()
        big.newFrames = 120
        big.draws = 120
        big.drawables = 120
        big.presents = 120
        big.presentErrors = 57
        let a = StatusReadout.performance(times: FrameTimes(decode: 0.1, chain: 0, present: 0), fps: 0, counters: small)
        let b = StatusReadout.performance(times: FrameTimes(decode: 99.9, chain: 10.8, present: 138.0), fps: 30, counters: big)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(b, "d 99.9 · c 10.8 · p 138.0 ms · 30.0 fps · new 120 draw 120 drw 120 pres 120")
    }

    func testNoErrorCountInTheReadout() {
        var c = PreviewCounters()
        c.presentErrors = 3
        let line = StatusReadout.line(exportMessage: nil, crop: nil, frame: 1, times: FrameTimes(), fps: 30, counters: c)
        XCTAssertFalse(line.contains("err"))
    }

    func testCropWidthIsFixed() {
        XCTAssertEqual(StatusReadout.crop(zoom: 1, pan: 0, panY: 0).count,
                       StatusReadout.crop(zoom: 1.5, pan: -0.5, panY: -0.767).count)
        XCTAssertEqual(StatusReadout.crop(zoom: 1.5, pan: 0, panY: -0.767), "zoom 1.500 · pan X +0.000 · pan Y -0.767")
    }

    /// The readout names both pans the way the sidebar rows do.
    func testCropNamesPanXAndPanY() {
        XCTAssertEqual(StatusReadout.crop(zoom: 1, pan: 0.15, panY: -0.75), "zoom 1.000 · pan X +0.150 · pan Y -0.750")
    }

    /// The shorter forms drop fields from the right, one at a time, and keep the export outcome.
    func testLinesDropFieldsFromTheRight() {
        let lines = StatusReadout.lines(exportMessage: "Exported a.mov", crop: nil, frame: 4263,
                                        times: FrameTimes(decode: 0.2, chain: 10.3, present: 63.9),
                                        fps: 31, counters: PreviewCounters())
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(lines[0], StatusReadout.line(exportMessage: "Exported a.mov", crop: nil, frame: 4263,
                                                    times: FrameTimes(decode: 0.2, chain: 10.3, present: 63.9),
                                                    fps: 31, counters: PreviewCounters()))
        XCTAssertTrue(lines[0].hasSuffix(" fps · new \u{2007}\u{2007}0 draw \u{2007}\u{2007}0 drw \u{2007}\u{2007}0 pres \u{2007}\u{2007}0"))
        XCTAssertTrue(lines[1].hasSuffix("31.0 fps"))
        XCTAssertTrue(lines[2].hasSuffix("p \u{2007}63.9 ms"))
        XCTAssertEqual(lines[5], "Exported a.mov    frame \u{2007}4,263")
        XCTAssertEqual(lines[6], "Exported a.mov")
        for (longer, shorter) in zip(lines, lines.dropFirst()) {
            XCTAssertTrue(longer.hasPrefix(shorter))
            XCTAssertGreaterThan(longer.count, shorter.count)
        }
    }

    /// With the performance readout off (the default) the line is the export outcome and
    /// the crop only, and an empty line when neither is there.
    func testNumbersOffYieldsOutcomeAndCropOnly() {
        let crop = StatusReadout.crop(zoom: 1.5, pan: 0, panY: -0.767)
        let lines = StatusReadout.lines(exportMessage: "Exported 150 frames to a.mov", crop: crop, frame: 4263,
                                        times: FrameTimes(decode: 0.2, chain: 10.3, present: 63.9),
                                        fps: 31, counters: PreviewCounters(), performance: false)
        XCTAssertEqual(lines, ["Exported 150 frames to a.mov    " + crop, "Exported 150 frames to a.mov"])
        for line in lines {
            for word in ["frame \u{2007}", "fps", " ms", "new ", "draw", "pres"] { XCTAssertFalse(line.contains(word), line) }
        }
        let outcomeOnly = StatusReadout.lines(exportMessage: "Export cancelled", crop: nil, frame: 1,
                                              times: FrameTimes(), fps: 30, counters: PreviewCounters(),
                                              performance: false)
        XCTAssertEqual(outcomeOnly, ["Export cancelled"])
        XCTAssertEqual(StatusReadout.lines(exportMessage: nil, crop: nil, frame: 1, times: FrameTimes(), fps: 30,
                                           counters: PreviewCounters(), performance: false), [""])
    }

    func testPaddingUsesFigureSpaces() {
        XCTAssertEqual(StatusReadout.pad("7", to: 3), "\u{2007}\u{2007}7")
        XCTAssertEqual(StatusReadout.pad("1234", to: 3), "1234")
    }
}
