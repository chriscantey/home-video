import XCTest
@testable import HomeVideoCore

@MainActor
final class SettingsClipboardTests: XCTestCase {
    /// Every value of every video and audio layer, keyed `layer.parameter`, plus switches.
    func snapshot(_ chain: SignalChain) -> [String: ParameterValue] {
        var s: [String: ParameterValue] = ["audio.preset": .choice(chain.audio.preset.rawValue)]
        for l in chain.layers {
            s["\(l.id).enabled"] = .bool(l.enabled)
            for p in l.parameters { s["\(l.id).\(p.id)"] = p.value }
        }
        for l in chain.audio.layers {
            s["audio.\(l.id).enabled"] = .bool(l.enabled)
            for p in l.parameters { s["audio.\(l.id).\(p.id)"] = p.value }
        }
        return s
    }

    /// A chain far from the defaults: a damaged Look, a moved crop, the linear audio track with
    /// a slider moved, and a layer switched off.
    func customized() throws -> SignalChain {
        let chain = SignalChain.standard()
        let look = try XCTUnwrap(Looks.look(id: "dub-of-a-dub"))
        Presets(vhs: try XCTUnwrap(chain.vhs), audio: chain.audio).setLook(look)
        chain.framing.setParameter("mode", to: .choice("cropCenter"))
        chain.framing.setParameter("zoom", to: .float(1.37))
        chain.framing.setParameter("pan", to: .float(-0.31))
        chain.framing.setParameter("panY", to: .float(0.62))
        chain.audio.preset = .linear
        let a = try XCTUnwrap(chain.audio.layers.first { l in l.parameters.contains { $0.value.doubleValue != nil } })
        let p = try XCTUnwrap(a.parameters.first { $0.value.doubleValue != nil })
        a.setParameter(p.id, to: .float((p.range.lowerBound + p.range.upperBound) / 2 + 0.123))
        chain.audio.layers.last?.enabled.toggle()
        chain.effects.first?.enabled.toggle()
        return chain
    }

    func testPasteOntoAResetChainMatchesEveryValue() throws {
        let source = try customized()
        let json = SettingsClipboard.encode(source)
        let target = SignalChain.standard()
        XCTAssertNotEqual(snapshot(target), snapshot(source), "the test chain must differ from the defaults")
        try SettingsClipboard.apply(json, to: target)
        XCTAssertEqual(snapshot(target), snapshot(source))
        XCTAssertEqual(SettingsClipboard.encode(target), json)
        // The pasted chain reads back as the same Look, or Custom, as the copied one.
        XCTAssertEqual(Presets(vhs: try XCTUnwrap(target.vhs), audio: target.audio).look?.id,
                       Presets(vhs: try XCTUnwrap(source.vhs), audio: source.audio).look?.id)
    }

    func testRotationIsNotCopied() throws {
        let source = try customized()
        source.framing.rotation = 90
        let json = SettingsClipboard.encode(source)
        XCTAssertFalse(json.contains("rotation"))
        let target = SignalChain.standard()
        target.framing.rotation = 180
        try SettingsClipboard.apply(json, to: target)
        XCTAssertEqual(target.framing.rotation, 180)
    }

    func testMalformedSettingsAreRejectedWithoutChanges() throws {
        let good = SettingsClipboard.encode(try customized())
        let wrongType = good.replacingOccurrences(of: "\"cropCenter\"", with: "42")
        let badChoice = good.replacingOccurrences(of: "\"cropCenter\"", with: "\"sideways\"")
        let unknownLayer = good.replacingOccurrences(of: "\"framing\"", with: "\"warp-drive\"")
        let notOurs = good.replacingOccurrences(of: "\"homevideo-settings\"", with: "\"other-app-settings\"")
        // A bad audio preset, checked after every video layer: those must stay untouched too.
        let lateBad = good.replacingOccurrences(of: "\"linear\"", with: "\"stereo8\"")
        for text in ["", "{", "[]", "hello", "{\"format\": \"homevideo-settings\"}", wrongType, badChoice,
                     unknownLayer, notOurs, lateBad] {
            XCTAssertNotEqual(text, good)
            let chain = SignalChain.standard()
            let before = snapshot(chain)
            XCTAssertThrowsError(try SettingsClipboard.apply(text, to: chain), String(text.prefix(40)))
            XCTAssertEqual(snapshot(chain), before, String(text.prefix(40)))
        }
    }
}
