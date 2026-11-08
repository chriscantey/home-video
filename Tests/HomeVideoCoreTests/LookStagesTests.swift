import XCTest
@testable import HomeVideoCore

/// Choosing a Look lights exactly the stages it uses and unlights the rest. The stages in use after a
/// Look, as `StageSwitches` reads them for the strip, are the ones its section and its own
/// settings imply, and no others.
@MainActor
final class LookStagesTests: XCTestCase {
    /// The stages a Look uses, worked out from what it says rather than from the chain: its
    /// section, whether it switches the Tape off, and whether it carries any sound.
    static func implied(_ look: Look) -> Set<ChainStage> {
        var s: Set<ChainStage> = []
        let tapeOff = look.overrides.contains { $0.layer == "tape" && $0.parameter == "enabled" && $0.value == .bool(false) }
        if !tapeOff { s.insert(.tape) }
        switch look.category {
        case .tape, .custom: break
        case .film: s.insert(.film)
        case .telecine: s.formUnion([.film, .telecine])
        case .display: s.formUnion([.display, .recapture])
        }
        if (look.selection.audio ?? .hifi) != .off || Looks.motor.contains(look.id) { s.insert(.audio) }
        return s
    }

    func lit(_ chain: SignalChain) -> Set<ChainStage> {
        let stages = StageSwitches(chain: chain)
        return Set(ChainStage.allCases.filter { stages.isOn($0) })
    }

    /// From the launch chain, every Look lights exactly its stages.
    func testEveryLookLightsExactlyItsStagesFromLaunch() throws {
        for look in Looks.all {
            let chain = SignalChain.standard()
            Presets(vhs: try XCTUnwrap(chain.vhs), audio: chain.audio).setLook(look)
            XCTAssertEqual(lit(chain), Self.implied(look), look.id)
        }
    }

    /// From a chain with every stage lit (a filmed Look, then Film and Telecine switched on), a
    /// Look puts out every stage it does not use, except the Display: a Look that does not film
    /// the screen leaves the Display as it was and switches the camera off.
    func testEveryLookUnlightsWhatItDoesNotUse() throws {
        for look in Looks.all {
            let chain = SignalChain.standard()
            let vhs = try XCTUnwrap(chain.vhs)
            let p = Presets(vhs: vhs, audio: chain.audio)
            p.setLook(try XCTUnwrap(Looks.look(id: "phone-dub")))
            vhs.film.source.enabled = true
            vhs.telecine.source.enabled = true
            XCTAssertEqual(lit(chain), Set(ChainStage.allCases), "every stage lit before \(look.id)")
            p.setLook(look)
            var want = Self.implied(look)
            if look.category != .display { want.insert(.display) }
            XCTAssertEqual(lit(chain), want, look.id)
            XCTAssertEqual(p.look?.id, look.id, "\(look.id) reads back")
        }
    }

    /// Each section lights its own stage on top of the Tape: no Tape Look lights Film,
    /// Telecine or the Display, every Film and Telecine Look lights the Film.
    func testTheSectionsLightTheirStages() throws {
        for look in Looks.all {
            let chain = SignalChain.standard()
            Presets(vhs: try XCTUnwrap(chain.vhs), audio: chain.audio).setLook(look)
            let on = lit(chain)
            switch look.category {
            case .tape: XCTAssertTrue(on.isDisjoint(with: [.film, .telecine, .display, .recapture]), look.id)
            case .film: XCTAssertEqual(on.intersection([.film, .telecine, .display]), [.film], look.id)
            case .telecine: XCTAssertTrue(on.isSuperset(of: [.film, .telecine]), look.id)
            case .display: XCTAssertTrue(on.isSuperset(of: [.tape, .display, .recapture]), look.id)
            case .custom: XCTFail(look.id)
            }
        }
    }
}
