import XCTest
@testable import HomeVideoCore

/// The Look menu in sections, Tape, Film, Telecine, Display, then the user's own as Custom.
/// Every built-in Look names its section, every Telecine Look has the Film on (a telecine is film
/// put onto video), and `Looks.grouped` lists every built-in once, the plainest first.
@MainActor
final class LookCategoryTests: XCTestCase {
    func testTheSectionsRunTapeFilmTelecineDisplayCustom() {
        XCTAssertEqual(LookCategory.allCases, [.tape, .film, .telecine, .display, .custom])
        XCTAssertEqual(LookCategory.allCases.map(\.title), ["Tape", "Film", "Telecine", "Display", "Custom"])
    }

    func testEveryBuiltInNamesASectionAndAFileIsCustom() throws {
        for look in Looks.all { XCTAssertNotEqual(look.category, .custom, look.id) }
        // A saved preset reads as a Look of its own, under Custom.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("looks-plus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UserPresets(folder: dir)
        let chain = SignalChain.standard()
        Presets(vhs: try XCTUnwrap(chain.vhs), audio: chain.audio).setLook(try XCTUnwrap(Looks.look(id: "rental")))
        let saved = try store.save(name: "Mine", chain: chain)
        XCTAssertEqual(saved.look.category, .custom)
        XCTAssertEqual(Look(id: "x", name: "x", blurb: "", selection: PresetSelection()).category, .custom)
    }

    /// The menu lists every built-in exactly once, in the sections' order, Fresh SP first.
    func testGroupedListsEveryBuiltInOnceInSectionOrder() {
        XCTAssertEqual(Looks.menuOrder.count, Set(Looks.menuOrder).count, "no id twice in the menu order")
        XCTAssertEqual(Set(Looks.menuOrder), Set(Looks.all.map(\.id)), "the menu order names every built-in")
        let grouped = Looks.grouped
        XCTAssertEqual(grouped.map(\.category), [.tape, .film, .telecine, .display])
        let flat = grouped.flatMap(\.looks).map(\.id)
        XCTAssertEqual(flat.count, Looks.all.count)
        XCTAssertEqual(Set(flat), Set(Looks.all.map(\.id)))
        XCTAssertEqual(flat, Looks.menuOrder, "each section in the menu order")
        XCTAssertEqual(grouped.first?.looks.first?.id, "clean-sp", "the default heads the menu")
        for (category, looks) in grouped {
            for look in looks { XCTAssertEqual(look.category, category, look.id) }
        }
    }

    /// Each section's Looks set the stages the section says: Film on for Film and Telecine (and
    /// every Telecine Look runs its film through the Telecine), the camera on the screen for
    /// Display, and a Tape Look none of Film, Telecine or the Display.
    func testEachSectionSetsItsStages() {
        var telecineLooks = 0
        for look in Looks.all {
            let ref = Looks.reference(look).vhs
            switch look.category {
            case .tape:
                XCTAssertFalse(ref.film.isOn, look.id)
                XCTAssertFalse(ref.telecine.isOn, look.id)
                XCTAssertFalse(look.setsDisplay, look.id)
                XCTAssertTrue(ref.tape.enabled, look.id)
            case .film:
                XCTAssertTrue(ref.film.isOn, look.id)
                XCTAssertFalse(ref.telecine.isOn, look.id)
                XCTAssertFalse(look.setsDisplay, look.id)
            case .telecine:
                telecineLooks += 1
                XCTAssertTrue(ref.film.isOn, "\(look.id): a Telecine Look has the Film on")
                XCTAssertTrue(ref.telecineInUse, look.id)
                XCTAssertFalse(look.setsDisplay, look.id)
            case .display:
                XCTAssertTrue(look.filmsTheScreen, look.id)
                XCTAssertFalse(ref.film.isOn, look.id)
            case .custom:
                XCTFail("\(look.id) is built in")
            }
            XCTAssertEqual(Looks.film.contains(look.id), ref.film.isOn, "\(look.id) in Looks.film exactly when its Film is on")
        }
        XCTAssertGreaterThan(telecineLooks, 0)
    }
}
