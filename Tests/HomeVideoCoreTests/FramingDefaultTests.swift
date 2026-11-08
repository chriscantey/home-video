import XCTest
@testable import HomeVideoCore

/// Framing defaults to center crop, with Pan X and Pan Y as the labels.
@MainActor
final class FramingDefaultTests: XCTestCase {
    func testDefaultModeIsCenterCrop() {
        XCTAssertEqual(FramingLayer().mode, .cropCenter)
        XCTAssertEqual(SignalChain().framing.mode, .cropCenter)
        XCTAssertEqual(SignalChain.standard().framing.mode, .cropCenter)
        let mode = FramingLayer().parameters.first { $0.id == "mode" }
        XCTAssertEqual(mode?.value, .choice("cropCenter"))
        XCTAssertEqual(mode?.options.first { $0.value == "cropCenter" }?.label, "Crop to fill", "the label reads Crop to fill")
    }

    func testPanRowsReadPanXAndPanYWithTheOldIds() {
        let names = Dictionary(uniqueKeysWithValues: FramingLayer().parameters.map { ($0.id, $0.name) })
        XCTAssertEqual(names["pan"], "Pan X")
        XCTAssertEqual(names["panY"], "Pan Y")
        // The default is Center crop, so both pans are live before the first frame.
        let active = FramingLayer().parameters.filter { $0.id.hasPrefix("pan") }.map(\.isActive)
        XCTAssertEqual(active, [true, true])
    }

    /// homevideo-render with no framing flag renders Center crop, and the flag still gives letterbox.
    func testRenderArgumentsDefaultAndLetterboxFlag() throws {
        let plain = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov"]).apply(to: plain)
        XCTAssertEqual(plain.framing.mode, .cropCenter)
        let old = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--set", "framing.mode=letterbox"]).apply(to: old)
        XCTAssertEqual(old.framing.mode, .letterbox)
    }

    /// No Look sets framing: every Look leaves the mode and the crop where they were.
    func testLooksDoNotTouchFraming() {
        for start in [FramingMode.cropCenter, .letterbox] {
            let chain = SignalChain.standard()
            chain.framing.mode = start
            chain.framing.setParameter("pan", to: .float(0.3))
            let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
            for look in Looks.all {
                presets.setLook(look)
                XCTAssertEqual(chain.framing.mode, start, look.id)
                XCTAssertEqual(chain.framing.pan, 0.3, look.id)
            }
        }
    }

    /// A sidecar's own mode wins over the default.
    func testSidecarModeKeepsItsMode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("framing-default-\(UUID().uuidString).homevideo.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let written = SignalChain.standard()
        written.framing.mode = .letterbox
        try Sidecar.write(chain: written, name: "clip.mov", lookID: nil, to: url)
        let read = SignalChain.standard()
        XCTAssertEqual(read.framing.mode, .cropCenter)
        _ = try Sidecar.read(url, into: read)
        XCTAssertEqual(read.framing.mode, .letterbox)
    }
}
