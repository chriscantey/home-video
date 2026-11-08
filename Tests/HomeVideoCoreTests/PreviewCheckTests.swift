import XCTest
@testable import HomeVideoCore

final class PreviewCheckTests: XCTestCase {
    func row(new: Int = 30, draws: Int = 60, drawables: Int = 60, presents: Int = 60, errors: Int = 0,
             status: String = "ready/playing", rate: Double = 1) -> PreviewCounters {
        var c = PreviewCounters()
        c.newFrames = new
        c.draws = draws
        c.drawables = drawables
        c.presents = presents
        c.presentErrors = errors
        c.playerStatus = status
        c.playerRate = rate
        return c
    }

    @MainActor
    func testVerdictNamesEachFault() {
        let v = { (r: PreviewCounters) in PreviewCheck.verdict([r, r, r], sourceFPS: 30) }
        XCTAssertTrue(v(row()).hasPrefix("ok:"), v(row()))
        // One drawable for the life of the view, no presented handler.
        XCTAssertTrue(v(row(drawables: 0, presents: 0)).hasPrefix("stale drawable"))
        XCTAssertTrue(v(row(presents: 0)).hasPrefix("presents short"))
        XCTAssertTrue(v(row(errors: 10)).contains("present errors"))
        XCTAssertTrue(v(row(status: "ready/waiting")).hasPrefix("player not playing"))
        XCTAssertTrue(v(row(new: 1)).hasPrefix("frames short"))
        XCTAssertTrue(PreviewCheck.verdict([], sourceFPS: 30).hasPrefix("no counters"))
    }
}
