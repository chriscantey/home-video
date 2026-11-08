import XCTest
@testable import HomeVideoCore

/// Undo and redo over the chain's settings. Each test drives a real chain the way the app
/// does: a change, then `record` with the chain's settings (the app's settings observer), and an
/// undo or redo put back with `SettingsClipboard.apply`, then `settle`.
@MainActor
final class ChainHistoryTests: XCTestCase {
    private var chain: SignalChain!
    private var presets: Presets!
    private var history: ChainHistory<String>!

    override func setUp() async throws {
        chain = SignalChain.standard()
        presets = Presets(vhs: try XCTUnwrap(chain.vhs), audio: chain.audio)
        history = ChainHistory(settings)
    }

    private var settings: String { SettingsClipboard.encode(chain) }

    /// The settings equal `expected`, else the failure names the lines that differ.
    private func assertSettings(_ expected: String, _ message: String = "", file: StaticString = #filePath,
                                line: UInt = #line) {
        let a = settings.split(separator: "\n"), b = expected.split(separator: "\n")
        guard a != b else { return }
        // Each differing line with the layer id nearest after it ("enabled" sorts before "id").
        func layer(at i: Int) -> String {
            b[i...].first(where: { $0.contains("\"id\"") && $0.hasPrefix("      \"") })
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? "?"
        }
        let differ = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.prefix(6)
            .map { "line \($0.offset) (\(layer(at: $0.offset))): \($0.element.0) vs \($0.element.1)" }
        XCTFail("\(message) settings differ (\(a.count) vs \(b.count) lines): \(differ.joined(separator: " | "))",
                file: file, line: line)
    }

    /// What the app's settings observer does after a change.
    private func observed(press: Int? = nil) { history.record(settings, gesture: press) }

    private func undo() throws {
        let s = try XCTUnwrap(history.undo())
        try SettingsClipboard.apply(s, to: chain)
        history.settle(settings)
    }

    private func redo() throws {
        let s = try XCTUnwrap(history.redo())
        try SettingsClipboard.apply(s, to: chain)
        history.settle(settings)
    }

    func testALookThenUndoGivesThePreviousSettingsAndRedoGivesThemBack() throws {
        let fresh = settings
        XCTAssertFalse(history.canUndo)
        presets.setLook(try XCTUnwrap(Looks.look(id: "attic-tape")))
        observed()
        let attic = settings
        XCTAssertNotEqual(attic, fresh)
        XCTAssertTrue(history.canUndo)

        try undo()
        assertSettings(fresh)
        XCTAssertEqual(presets.look?.id, "clean-sp")
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
        // The observer seeing the put-back state records nothing.
        observed()
        XCTAssertTrue(history.canRedo)

        try redo()
        assertSettings(attic)
        XCTAssertEqual(presets.look?.id, "attic-tape")
        XCTAssertFalse(history.canRedo)
    }

    func testANewChangeAfterUndoDropsTheRedo() throws {
        presets.setLook(try XCTUnwrap(Looks.look(id: "attic-tape")))
        observed()
        try undo()
        chain.framing.setParameter("zoom", to: .float(1.5))
        observed()
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undoStack.count, 1)
    }

    func testADragUnderOnePressIsOneStepEndingAtMouseUp() throws {
        let before = settings
        for z in stride(from: 1.05, through: 1.6, by: 0.05) {
            chain.framing.setParameter("zoom", to: .float(z))
            observed(press: 7)
        }
        let atMouseUp = settings
        XCTAssertEqual(history.undoStack.count, 1, "the whole drag is one step")
        // A second drag is a new press, so a second step.
        chain.framing.setParameter("zoom", to: .float(1.2))
        observed(press: 8)
        chain.framing.setParameter("zoom", to: .float(1.1))
        observed(press: 8)
        XCTAssertEqual(history.undoStack.count, 2)

        try undo()
        assertSettings(atMouseUp)
        try undo()
        assertSettings(before)
        try redo()
        assertSettings(atMouseUp, "redo of a drag lands on the value at mouse up")
        // Changes with no press are a step each.
        chain.framing.setParameter("pan", to: .float(0.2))
        observed()
        chain.framing.setParameter("pan", to: .float(0.3))
        observed()
        XCTAssertEqual(history.undoStack.count, 3)
    }

    func testTheStackStopsAtItsDepth() throws {
        let depth = ChainHistory<String>.depth
        XCTAssertEqual(depth, 200)
        var states: [String] = [settings]
        for i in 0..<(depth + 25) {
            chain.framing.setParameter("pan", to: .float(Double(i % 2 == 0 ? i : -i) / Double(depth + 25)))
            observed()
            states.append(settings)
        }
        XCTAssertEqual(history.undoStack.count, depth)
        var steps = 0
        while history.canUndo { try undo(); steps += 1 }
        XCTAssertEqual(steps, depth)
        // The oldest 25 steps went first, so the furthest back is the 26th state.
        assertSettings(states[25])
    }

    func testUndoAfterResetPutsTheEditedChainBack() throws {
        presets.setLook(try XCTUnwrap(Looks.look(id: "attic-tape")))
        observed()
        let switches = StageSwitches(chain: chain)
        switches.set(.film, on: true)
        observed()
        chain.vhs?.output.size = .hd
        observed()
        let edited = settings
        FreshStart.reset(chain, switches: switches)
        observed()
        XCTAssertFalse(FreshStart.drifted(chain))

        try undo()
        assertSettings(edited)
        XCTAssertTrue(switches.isOn(.film))
        XCTAssertEqual(chain.vhs?.output.size, .hd)
        // Back through every step to the fresh chain.
        try undo(); try undo(); try undo()
        XCTAssertFalse(FreshStart.drifted(chain))
        XCTAssertFalse(history.canUndo)
    }

    func testShuffleAndAStagePresetAreStepsToo() throws {
        let fresh = settings
        _ = Shuffle.roll(presets, seed: 42)
        observed()
        let rolled = settings
        XCTAssertNotEqual(rolled, fresh)
        // A Tape preset that keeps the tape on and moves it from what the roll set.
        let vhs = try XCTUnwrap(chain.vhs)
        for tape in StagePresets.builtIns(.tape).reversed() where tape.name != "Off" {
            tape.stage.apply(tape.snapshot, vhs: vhs, audio: chain.audio)
            if settings != rolled { break }
        }
        observed()
        let picked = settings
        XCTAssertNotEqual(picked, rolled)
        XCTAssertTrue(vhs.tape.enabled)
        StageSwitches(chain: chain).set(.tape, on: false)
        observed()
        try undo()
        assertSettings(picked)
        try undo()
        assertSettings(rolled)
        try undo()
        assertSettings(fresh)
    }

    func testRebaseClearsBothWays() throws {
        presets.setLook(try XCTUnwrap(Looks.look(id: "attic-tape")))
        observed()
        try undo()
        history.rebase(settings)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }
}
