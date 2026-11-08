import XCTest
@testable import HomeVideoCore

/// The About line, the sidebar's layer titles and which layers have nothing to open.
@MainActor
final class SidebarTitleTests: XCTestCase {
    func testTaglineText() {
        XCTAssertEqual(Tagline.text, "Puts your video on tape and back, virtually, from the physics.")
    }

    func testDisplayDropsTheStageNumberOnly() {
        XCTAssertEqual(LayerTitle.display("L1 Output card (RGB to YIQ)"), "Output card (RGB to YIQ)")
        XCTAssertEqual(LayerTitle.display("L9 Capture (YIQ to RGB, fields)"), "Capture (YIQ to RGB, fields)")
        XCTAssertEqual(LayerTitle.display("L12 Something"), "Something")
        // Names that only start with an L keep it.
        XCTAssertEqual(LayerTitle.display("Levels (black, gain, clip, drift)"), "Levels (black, gain, clip, drift)")
        XCTAssertEqual(LayerTitle.display("Line-rate whine"), "Line-rate whine")
        XCTAssertEqual(LayerTitle.display("L"), "L")
    }

    /// Every layer the sidebar lists, under every audio preset.
    private func everyLayer() -> [(id: String, name: String, parameters: Int)] {
        let chain = SignalChain.standard()
        var rows: [(String, String, Int)] = [(chain.framing.id, chain.framing.name, chain.framing.parameters.count)]
        rows += chain.effects.map { ($0.id, $0.name, $0.parameters.count) }
        rows += (chain.vhs?.damage.all ?? []).map { ($0.id, $0.name, $0.parameters.count) }
        for preset in AudioPreset.allCases {
            chain.audio.preset = preset
            rows += chain.audio.allLayers.map { ($0.id, $0.name, $0.parameters.count) }
        }
        return rows
    }

    func testNoDisplayedTitleStartsWithAStageNumber() {
        let rows = everyLayer()
        XCTAssertTrue(rows.contains { LayerTitle.hasStageNumber($0.name) }, "the names still carry the numbers for the docs")
        for row in rows {
            XCTAssertFalse(LayerTitle.hasStageNumber(LayerTitle.display(row.name)), "\(row.id): \(row.name)")
        }
    }

    /// The layers with no parameters: the output card, the audio's sum to mono and the on-screen
    /// display. Sum to mono gets a plain row with no chevron. The on-screen display is a Capture
    /// switch and never gets a group. The output card is not listed at all. Pinned so a
    /// new empty layer shows up here.
    func testLayersWithNothingToOpen() {
        let empty = Set(everyLayer().filter { $0.parameters == 0 }.map(\.id))
        XCTAssertEqual(empty, ["output-card", "audio-mono", "osd"])
    }

    /// A layer nobody can change is not listed, whether or not anything between it and
    /// Capture runs. Every other picture layer is, Capture with its "Always on" tag.
    func testOutputCardIsNotListed() {
        let chain = SignalChain.standard()
        let hidden = { Set(chain.effects.filter { !LayerTitle.isListed($0) }.map(\.id)) }
        XCTAssertEqual(hidden(), ["output-card"])
        let card = chain.effects.first { $0.id == "output-card" }!
        XCTAssertTrue(card.isRequired, "the standard chain runs layers between L1 and L9")
        for layer in chain.effects where layer.id != "output-card" && layer.id != "capture" && !layer.isRequired {
            layer.enabled = false
        }
        XCTAssertEqual(hidden(), ["output-card"], "still hidden with its switch unlocked")
        let capture = chain.effects.first { $0.id == "capture" }!
        XCTAssertTrue(capture.isRequired && LayerTitle.isListed(capture))
    }

    /// The title's trailing parenthetical becomes the second line.
    func testTitleParts() {
        func check(_ name: String, _ head: String, _ detail: String?, line: UInt = #line) {
            let p = LayerTitle.parts(name)
            XCTAssertEqual(p.name, head, line: line)
            XCTAssertEqual(p.detail, detail, line: line)
        }
        check("L3 Luma record (emphasis, clip, bandwidth)", "Luma record", "emphasis, clip, bandwidth")
        check("Camera (camcorder source)", "Camera", "camcorder source")
        check("Compressor 2:1 (record)", "Compressor 2:1", "record")
        check("L5 Tape noise", "Tape noise", nil)
        check("Head-switch click", "Head-switch click", nil)
        check("(odd)", "(odd)", nil)
        // Every listed name splits into a non-empty name, and a detail only from a parenthetical.
        for row in everyLayer() {
            let p = LayerTitle.parts(row.name)
            XCTAssertFalse(p.name.isEmpty, row.id)
            XCTAssertFalse(p.name.hasSuffix(")"), row.id)
        }
    }
}
