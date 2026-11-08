import Metal
import XCTest
@testable import HomeVideoCore

/// A paused preview draws the same frame again after each change, so the Film's held frame and
/// the Telecine's cached film frames must follow the settings, or a film Look or a film slider
/// changed while paused shows the old picture until play moves the time on. Each case renders one
/// frame on one chain, makes
/// the change, renders the same frame again, and compares it with a fresh chain's render.
extension FilmTests {
    /// The paused frame: 2.0 s at 30 fps.
    private static let paused: UInt64 = 60

    private func lookChain(_ id: String) throws -> SignalChain {
        let (chain, _) = standardChain()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(try XCTUnwrap(Looks.look(id: id)))
        return chain
    }

    /// Plays up to the paused frame, draws it, makes the change, and draws the same frame
    /// again. The second picture is the changed chain's own, and differs from the first.
    /// `steady`: the same frame drawn twice with nothing changed is the same picture. Not so
    /// under the Telecine at Home, whose camera's lag goes on adding the last picture.
    private func assertRedraws(_ what: String, from first: String, steady: Bool = true,
                               _ change: (SignalChain) throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let g = try GPUHarness()
        let src = try pattern(g)
        let n = Self.paused
        let live = try lookChain(first)
        _ = try render(g, live, src, frame: n - 1)
        let before = try render(g, live, src, frame: n).bits
        if steady {
            XCTAssertTrue(before == (try render(g, live, src, frame: n).bits),
                          "\(what): the same frame twice with nothing changed is the same picture",
                          file: file, line: line)
        }
        try change(live)
        let after = try render(g, live, src, frame: n).bits
        let fresh = try lookChain(first)
        try change(fresh)
        let expected = try render(g, fresh, src, frame: n).bits
        // Compared as a Bool, so a failure names the case without printing every pixel.
        XCTAssertTrue(after != before, "\(what): the paused frame changes", file: file, line: line)
        XCTAssertTrue(after == expected, "\(what): the paused frame is a fresh chain's", file: file, line: line)
    }

    private func setLook(_ id: String) -> (SignalChain) throws -> Void {
        { chain in Presets(vhs: chain.vhs!, audio: chain.audio).setLook(try XCTUnwrap(Looks.look(id: id))) }
    }

    func testFilmLookChangeRedrawsThePausedFrame() throws {
        try assertRedraws("Summer Reel to 16mm Faded", from: "regular8-summer", setLook("sixteen-ektachrome-faded"))
        try assertRedraws("16mm Faded to Super 8", from: "sixteen-ektachrome-faded", setLook("super8-kodachrome"))
    }

    func testFilmSliderChangeRedrawsThePausedFrame() throws {
        try assertRedraws("the stock", from: "regular8-summer") {
            $0.vhs!.film.stock.setParameter("stock", to: .choice(FilmStock.ektachrome160.rawValue))
        }
        try assertRedraws("the fade years", from: "regular8-summer") {
            $0.vhs!.film.fade.setParameter("years", to: .float(30))
        }
        try assertRedraws("the grain switch", from: "regular8-summer") { $0.vhs!.film.grain.enabled.toggle() }
    }

    func testTelecineLookChangeRedrawsThePausedFrame() throws {
        try assertRedraws("Mall Transfer to 8mm to Tape", from: "mall-transfer", steady: false,
                          setLook("home-movie-transfer"))
        try assertRedraws("8mm to Tape to Pro Scan", from: "home-movie-transfer", steady: false, setLook("pro-scan"))
        try assertRedraws("Pro Scan to Mall Transfer", from: "pro-scan", setLook("mall-transfer"))
        try assertRedraws("the Telecine gate", from: "mall-transfer", steady: false) {
            $0.vhs!.telecine.gate.enabled.toggle()
        }
        try assertRedraws("a film slider under the Telecine", from: "mall-transfer", steady: false) {
            $0.vhs!.film.fade.setParameter("years", to: .float(30))
        }
    }
}
