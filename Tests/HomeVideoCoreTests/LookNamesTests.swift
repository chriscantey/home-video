import XCTest
@testable import HomeVideoCore

/// No Look name carries a year. The two Looks built on a 1986 home tape are Shoebox and
/// Tape Transfer, with their ids unchanged for scripts and saved settings.
final class LookNamesTests: XCTestCase {
    func testHomeLooksRenamedIdsKept() {
        XCTAssertEqual(Looks.look(id: "home-movie-1986")?.name, "Shoebox")
        XCTAssertEqual(Looks.look(id: "transfer-1986")?.name, "Tape Transfer")
    }

    func testNoYearInAnyLookName() {
        for look in Looks.all {
            XCTAssertNil(look.name.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression), look.name)
        }
    }

    /// The house style on the Looks too: no em-dash, no double hyphen, no semicolon.
    func testNoDashRunsOrSemicolonsInAnyNameOrBlurb() {
        for look in Looks.all {
            for text in [look.name, look.blurb] {
                XCTAssertFalse(text.contains("\u{2014}"), "\(look.id): \(text)")
                XCTAssertFalse(text.contains("--"), "\(look.id): \(text)")
                XCTAssertFalse(text.contains(";"), "\(look.id): \(text)")
            }
        }
    }

    /// The Look menu takes its width from its longest name. No name runs past Wedding Video's 13
    /// characters. Check the menu font's widths when a Look is added, since a narrow letter count
    /// can still draw wider.
    func testNoLookNameLongerThanWeddingVideo() {
        for look in Looks.all { XCTAssertLessThanOrEqual(look.name.count, "Wedding Video".count, look.name) }
    }

    func testTheTapeNamedOnceInTheBlurbs() {
        let mentions = Looks.all.filter { $0.blurb.contains("1986") }.map(\.id)
        XCTAssertEqual(mentions, ["home-movie-1986"])
    }
}
