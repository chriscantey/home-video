import Metal
import XCTest
@testable import HomeVideoCore

/// A seek in the preview clears the chain's frame history before the frame it lands on, as the exporter does
/// before frame 0. Each case plays one picture, seeks through the renderer's own path (a tick
/// still showing the old frame, then the first new frame), draws another picture, and compares
/// it with a fresh chain's draw of that frame.
extension FilmTests {
    /// A second picture, unlike `pattern`, so a history carried across the seek shows.
    private func otherPicture(_ g: GPUHarness) throws -> MTLTexture {
        try g.source { x, y in (UInt8((x * 7 + y) & 0xff), UInt8((y * 3) & 0xff), UInt8(255 - (x & 0xff))) }
    }

    private func lookChain(_ look: String) throws -> SignalChain {
        let (chain, _) = standardChain()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(try XCTUnwrap(Looks.look(id: look)))
        return chain
    }

    /// Plays `before` up to frame 40, seeks (or not), and draws `after` at frame 90.
    private func drawAfterSeek(_ look: String, seek: Bool, _ g: GPUHarness, before: MTLTexture,
                               after: MTLTexture) throws -> [UInt16] {
        let live = try lookChain(look)
        let renderer = PreviewRenderer(chain: live)
        for f in UInt64(30)...40 {
            renderer.prepareChain(newFrame: true)
            _ = try render(g, live, before, frame: f)
        }
        if seek { renderer.noteSeek() }
        // The tick after the seek still shows the frame from before it.
        renderer.prepareChain(newFrame: false)
        _ = try render(g, live, before, frame: 40)
        XCTAssertEqual(renderer.seekPending, seek, "a tick with no new frame keeps the reset for the new one")
        renderer.prepareChain(newFrame: true)
        XCTAssertFalse(renderer.seekPending)
        return try render(g, live, after, frame: 90).bits
    }

    func testASeekThenADrawIsAFreshChainsDrawOfThatFrame() throws {
        let g = try GPUHarness()
        let a = try pattern(g), b = try otherPicture(g)
        // Fresh SP (the tape's fields), a film Look (the hold and the last frame), and the
        // Telecine at Home (its cached frames and the camera's lag).
        for look in ["clean-sp", "regular8-summer", "home-movie-transfer"] {
            let fresh = try render(g, try lookChain(look), b, frame: 90).bits
            let seeked = try drawAfterSeek(look, seek: true, g, before: a, after: b)
            XCTAssertTrue(seeked == fresh, "\(look): the frame after a seek is a fresh chain's")
        }
        // Without the seek the Telecine's lag carries the first picture into the frame, so the
        // comparison above can fail.
        let fresh = try render(g, try lookChain("home-movie-transfer"), b, frame: 90).bits
        let carried = try drawAfterSeek("home-movie-transfer", seek: false, g, before: a, after: b)
        XCTAssertTrue(carried != fresh, "with no seek the history shows in the frame")
    }

    func testANewSourceIsANewRun() throws {
        let renderer = PreviewRenderer(chain: SignalChain.standard())
        renderer.prepareChain(newFrame: true)
        XCTAssertFalse(renderer.seekPending)
        renderer.source = nil
        XCTAssertTrue(renderer.seekPending)
    }
}
