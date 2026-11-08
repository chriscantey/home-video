import AppKit
import Observation
import XCTest
@testable import HomeVideoCore

/// Hold M (or the toolbar's Source button) to see and hear the source. The key's phase
/// rules, the tap in bypass handing back the source bit for bit under EP Linear, and the
/// bypass leaving the chain, its fingerprint and the sidecar alone.
final class SourceHoldTests: XCTestCase {
    func phase(_ type: NSEvent.EventType, repeat isRepeat: Bool = false, _ chars: String? = "m",
               _ mods: NSEvent.ModifierFlags = [], text: Bool = false, holding: Bool = false) -> SourceHold.Phase? {
        SourceHold.phase(type: type, isRepeat: isRepeat, characters: chars, modifiers: mods,
                         textFieldHasFocus: text, holding: holding)
    }

    func testPhaseActions() {
        XCTAssertEqual(SourceHold.action(.down), .show)
        XCTAssertEqual(SourceHold.action(.repeat), .swallow, "a held M is handled, so it never beeps")
        XCTAssertEqual(SourceHold.action(.up), .hide)
        XCTAssertEqual(SourceHold.action(nil), .notOurs)
    }

    func testBareMDownRepeatUp() {
        XCTAssertEqual(phase(.keyDown), .down)
        XCTAssertEqual(phase(.keyDown, repeat: true), .repeat)
        XCTAssertEqual(phase(.keyUp), .up)
        XCTAssertEqual(phase(.keyDown, "M", .shift), .down, "Shift M holds too")
    }

    func testNotOurs() {
        XCTAssertNil(phase(.keyDown, "n"), "another letter")
        XCTAssertNil(phase(.keyDown, nil), "no characters")
        XCTAssertNil(phase(.keyDown, "m", .command), "Command M is the menu's")
        XCTAssertNil(phase(.keyDown, "m", .option))
        XCTAssertNil(phase(.keyDown, "m", .control))
        XCTAssertNil(phase(.flagsChanged), "not a key event")
        XCTAssertNil(phase(.keyDown, text: true), "M typed in a text field")
        XCTAssertNil(phase(.keyDown, repeat: true, text: true))
        XCTAssertNil(phase(.keyUp, text: true), "a field's release, with no hold on")
    }

    func testReleaseWhileHoldingIsAlwaysOurs() {
        XCTAssertEqual(phase(.keyUp, text: true, holding: true), .up,
                       "focus moved into a field mid-hold: the release still ends the bypass")
    }

    /// A whole hold, as the monitor sees it: one show, repeats that change nothing, one hide.
    func testHoldSequence() {
        var on = false
        let events: [(NSEvent.EventType, Bool)] = [(.keyDown, false)] + Array(repeating: (.keyDown, true), count: 20)
            + [(.keyUp, false)]
        var shows = 0, hides = 0, swallowed = 0
        for (type, rep) in events {
            switch SourceHold.action(phase(type, repeat: rep, holding: on)) {
            case .show: on = true; shows += 1
            case .hide: on = false; hides += 1
            case .swallow: XCTAssertTrue(on); swallowed += 1
            case .notOurs: XCTFail("every event of the hold is ours")
            }
        }
        XCTAssertEqual([shows, swallowed, hides], [1, 20, 1])
        XCTAssertFalse(on)
    }
}

extension AudioTests {
    /// The tap in bypass with EP Linear on hands back exactly what it was given, planar and
    /// interleaved, and the call after the release is processed again, nothing rebuilt.
    func testBypassedTapIsIdentityUnderEPLinear() {
        let input = noise(seconds: 0.5)
        for interleaved in [false, true] {
            let feed = AudioPreviewFeed(spec: AudioChain(preset: .epLinear).spec)
            let tap = preparedTap(feed, interleaved: interleaved)
            let processed = renderTap(tap, input, interleaved: interleaved)
            XCTAssertNotEqual(processed, input, "EP Linear changes the sound (interleaved \(interleaved))")

            feed.bypass = true
            XCTAssertEqual(renderTap(tap, input, interleaved: interleaved), input,
                           "bypass is bit-exact source (interleaved \(interleaved))")

            // Released after the first block: that block is source, the rest is the chain again.
            let back = renderTap(tap, input, interleaved: interleaved, at: 0) { feed.bypass = false }
            XCTAssertEqual(Array(back[0][..<512]), Array(input[0][..<512]))
            XCTAssertNotEqual(Array(back[0][512...]), Array(input[0][512...]), "the chain is heard on the next call")
        }
    }

    /// A 12 kHz tone is cut more than 20 dB by EP Linear and comes through whole in bypass.
    func testBypassPassesWhatEPLinearCuts() {
        let tone = sine(12_000, amplitude: 0.25, seconds: 1)
        let feed = AudioPreviewFeed(spec: AudioChain(preset: .epLinear).spec)
        feed.bypass = true
        let held = renderTap(preparedTap(feed), tone)
        XCTAssertEqual(held, tone)
        feed.bypass = false
        let out = renderTap(preparedTap(feed), tone)
        XCTAssertLessThan(dB(bandAmplitude(out[0][24_000..<48_000], hz: 12_000) / 0.25), -20)
    }
}

@MainActor
final class SourceBypassStateTests: XCTestCase {
    var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-bypass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("clips"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The bypass lives on the renderer and the feed. Turning it on and off leaves the chain's
    /// fingerprint and sidecar snapshot as they were, fires no observation of the values a
    /// sidecar holds (which is what schedules a write in the app), and writes no sidecar.
    func testBypassLeavesFingerprintAndSidecarAlone() async throws {
        let chain = SignalChain.standard()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(Looks.look(id: "dub-of-a-dub")!)
        chain.audio.preset = .epLinear
        let renderer = PreviewRenderer(chain: chain)
        let feed = AudioPreviewFeed(spec: chain.audio.spec)
        let clip = root.appendingPathComponent("clips/clip.mov")
        try Data("not a movie".utf8).write(to: clip)
        let session = SidecarSession(chain: chain, fallbackFolder: root.appendingPathComponent("Sidecars"),
                                     delay: .milliseconds(50))
        var writes = 0
        session.onWrite = { _, _ in writes += 1 }
        session.show(clip, currentLookID: "dub-of-a-dub")

        let fingerprint = ChainFingerprint.of(chain)
        let snapshot = Sidecar.snapshot(of: chain, lookID: nil)
        let spec = feed.currentSpec
        final class Flag: @unchecked Sendable { var value = false }
        let observed = Flag()
        withObservationTracking {
            _ = Sidecar.snapshot(of: chain, lookID: nil)
            _ = ChainFingerprint.of(chain)
        } onChange: { observed.value = true }

        for on in [true, false, true, false] {
            renderer.bypass = on
            feed.bypass = on
            XCTAssertEqual(ChainFingerprint.of(chain), fingerprint, "bypass \(on)")
        }
        session.changed(currentLookID: "dub-of-a-dub")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(observed.value, "no value a sidecar holds was touched")
        XCTAssertEqual(Sidecar.snapshot(of: chain, lookID: nil), snapshot)
        XCTAssertEqual(feed.currentSpec, spec, "the audio chain's spec is unchanged")
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.besideURL(for: clip).path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sidecars").path)) ?? []
        XCTAssertEqual(leftovers, [])
    }
}
