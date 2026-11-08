import XCTest
@testable import HomeVideoCore

/// The release notes: every build from the first notes build has an entry, each entry
/// holds two to five short plain lines in the house style, and a build in testing is never shown.
/// The real entries are checked for coverage and style. The mechanism (folding, titles, the two
/// lines, the split) is checked on a made-up history passed through the `notes:` parameters.
final class ReleaseNotesTests: XCTestCase {
    /// `AppInfo.build`, read from the app's source since the test target only sees the core.
    private func appBuild() throws -> Int {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/HomeVideo/HomeVideoApp.swift"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"static let build = (\d+)"#)
        let m = try XCTUnwrap(re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        return try XCTUnwrap(Int(text[Range(m.range(at: 1), in: text)!]))
    }

    // MARK: A made-up history

    /// The builds of the made-up release, the made-up point release and the made-up beta after it.
    private static let releaseBuilds = 30...37
    private static let pointBuilds = 38...39
    private static let betaBuilds = 40...45
    private static let testBuild = 46

    /// A release, a point release, a beta of the next version, and a build in testing, newest first.
    private static let history: [ReleaseNote] = [
        ReleaseNote(build: testBuild, version: "1.1.0", date: "2026-12-10", status: .testing, items: ["Ahead one", "Ahead two"]),
        ReleaseNote(builds: betaBuilds, version: "1.1.0", label: "beta 1", date: "2026-12-01", items: ["Beta one", "Beta two"]),
        ReleaseNote(builds: pointBuilds, version: "1.0.1", label: nil, date: "2026-11-20", line: .release,
                    items: ["Point one", "Point two"]),
        ReleaseNote(builds: releaseBuilds, version: "1.0.0", label: "the first release", date: "2026-11-05", line: .release,
                    items: ["Release one", "Release two"]),
    ]

    private static func note(_ label: String) -> ReleaseNote { history.first { $0.label == label }! }

    // MARK: The real entries

    func testEveryBuildFromTheFirstNotesToTheAppsHasExactlyOneEntry() throws {
        let build = try appBuild()
        XCTAssertEqual(ReleaseNotes.firstBuild, 36)
        XCTAssertGreaterThanOrEqual(build, ReleaseNotes.firstBuild)
        for n in ReleaseNotes.firstBuild...build {
            XCTAssertEqual(ReleaseNotes.all.filter { $0.covers(n) }.count, 1, "build \(n)")
        }
    }

    func testRealEntriesAreNewestFirstWithNoGaps() {
        let all = ReleaseNotes.all
        XCTAssertEqual(all.last?.first, ReleaseNotes.firstBuild)
        for (a, b) in zip(all, all.dropFirst()) {
            XCTAssertEqual(a.first, b.build + 1, "\(a.title) follows \(b.title)")
        }
        XCTAssertNil(ReleaseNotes.entry(for: ReleaseNotes.firstBuild - 1))
        XCTAssertEqual(ReleaseNotes.entry(for: ReleaseNotes.firstBuild)?.title, "1.0, the first release")
    }

    func testRealVersionsAreThreePartAndNeverGoBackward() throws {
        let re = try NSRegularExpression(pattern: #"^\d+\.\d+\.\d+$"#)
        for entry in ReleaseNotes.all {
            XCTAssertNotNil(re.firstMatch(in: entry.version, range: NSRange(entry.version.startIndex..., in: entry.version)), entry.title)
        }
        for (a, b) in zip(ReleaseNotes.all, ReleaseNotes.all.dropFirst()) {
            XCTAssertNotEqual(a.version.compare(b.version, options: .numeric), .orderedAscending, a.title)
        }
    }

    func testOnlyRealBuildsAheadOfTheAppAreInTesting() throws {
        let build = try appBuild()
        for entry in ReleaseNotes.all where entry.build > build {
            XCTAssertEqual(entry.status, .testing, "\(entry.title) is ahead of the app's build \(build)")
        }
        // The builds in testing are the newest run: no posted build sits above one in testing.
        let posted = ReleaseNotes.all.drop { $0.status == .testing }
        for entry in posted {
            XCTAssertEqual(entry.status, .released, entry.title)
        }
    }

    func testRealDatesAreDays() throws {
        let re = try NSRegularExpression(pattern: #"^2026-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$"#)
        for entry in ReleaseNotes.all {
            XCTAssertNotNil(re.firstMatch(in: entry.date, range: NSRange(entry.date.startIndex..., in: entry.date)), entry.title)
        }
    }

    func testRealEntriesHoldTwoToFiveItems() {
        for entry in ReleaseNotes.all {
            XCTAssertTrue((2...5).contains(entry.items.count), "\(entry.title) has \(entry.items.count)")
            XCTAssertEqual(Set(entry.items).count, entry.items.count, entry.title)
        }
    }

    /// The house style of the real entries, one rule per check so a failure names it.
    func testRealEntriesKeepTheHouseStyle() throws {
        // Em and en dashes, double hyphens, semicolons, exclamation marks, ellipses.
        let characters = try NSRegularExpression(pattern: "[\u{2014}\u{2013};!\u{2026}]|--")
        let marketing = try NSRegularExpression(pattern: #"\b(amazing|powerful|seamless(ly)?|awesome|incredible|stunning|effortless(ly)?|revolutionary|blazing|magical|game.changing|best.in.class|cutting.edge)\b"#,
                                                options: .caseInsensitive)
        // What changed, never how it works: words a reader would have to look up.
        let jargon = try NSRegularExpression(pattern: #"\b(SplitMix\w*|seed(ed)?|kernel|shader|Metal|GPU|PSNR|sidecar|MTKView|notari[sz]\w*|codesign\w*|Developer ID|PCM|AAC|H\.?26[45]|HEVC|YIQ|chroma|luma|bundle id|refactor\w*|regression)\b"#,
                                             options: .caseInsensitive)
        let british = try NSRegularExpression(pattern: #"\b(colour\w*|favourite\w*|behaviour\w*|centre\w*|grey|optimis\w*|organis\w*|recognis\w*|realis\w*|licence|catalogue|analys(e|ed|ing))\b"#,
                                              options: .caseInsensitive)
        let banned: [(String, NSRegularExpression)] = [("character", characters), ("marketing", marketing),
                                                        ("jargon", jargon), ("British spelling", british)]
        let lines = ReleaseNotes.all.flatMap { [$0.title] + $0.items }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for (rule, re) in banned {
                XCTAssertNil(re.firstMatch(in: line, range: range), "\(rule): \(line)")
            }
        }
        for item in ReleaseNotes.all.flatMap(\.items) {
            XCTAssertLessThanOrEqual(item.count, 72, "short: \(item)")
            XCTAssertTrue(item.first?.isUppercase == true, "sentence case: \(item)")
            XCTAssertFalse(item.hasSuffix("."), "no closing period: \(item)")
            XCTAssertEqual(item, item.trimmingCharacters(in: .whitespaces), "no stray spaces: \(item)")
            XCTAssertFalse(item.contains("  "), "no double spaces: \(item)")
            // Title Case reads as a heading, not a line: every word capitalized fails.
            let words = item.split(separator: " ").filter { $0.first?.isLetter == true }
            XCTAssertFalse(words.count > 3 && words.allSatisfy { $0.first!.isUppercase }, "sentence case: \(item)")
        }
    }

    /// Only posted builds are listed. The window lists `split`, so no build a person could
    /// have, from before the notes to past the newest, sees a test build listed.
    func testNoRealTestingEntryIsEverShown() {
        XCTAssertTrue(ReleaseNotes.shown.allSatisfy { $0.status == .released })
        XCTAssertEqual(ReleaseNotes.shown.map(\.build), ReleaseNotes.all.filter { $0.status == .released }.map(\.build))
        let newest = ReleaseNotes.all[0].build
        for n in (ReleaseNotes.firstBuild - 2)...(newest + 2) {
            let s = ReleaseNotes.split(forBuild: n)
            let listed = s.newer + (s.yours.map { [$0] } ?? []) + s.older
            XCTAssertTrue(listed.allSatisfy { $0.status == .released }, "build \(n)")
            XCTAssertEqual(listed.count, ReleaseNotes.shown.count, "build \(n) lists every posted build once")
        }
    }

    /// A release build lists release entries only: no beta entry, no beta word, no build number.
    /// The app's own build sits in the newest release entry, and 1.0 is the oldest on that line.
    func testRealReleaseLineShowsReleaseEntriesOnly() throws {
        let build = try appBuild()
        let release = ReleaseNotes.shown(on: .release)
        XCTAssertFalse(release.isEmpty)
        XCTAssertTrue(release.allSatisfy { $0.line == .release && $0.status == .released })
        let s = ReleaseNotes.split(forBuild: build, notes: release)
        let listed = s.newer + (s.yours.map { [$0] } ?? []) + s.older
        XCTAssertEqual(s.yours?.line, .release, "the app's build \(build) is a release entry")
        let digit = try NSRegularExpression(pattern: #"\b\d{2,}\b"#)
        for note in listed {
            XCTAssertFalse(note.title.contains("beta"), note.title)
            XCTAssertFalse(note.title.contains("build"), note.title)
            XCTAssertNil(digit.firstMatch(in: note.title, range: NSRange(note.title.startIndex..., in: note.title)),
                         "no build number: \(note.title)")
            XCTAssertFalse(note.items.contains { $0.contains("beta") }, note.title)
        }
        let first = try XCTUnwrap(release.last)
        XCTAssertEqual(first.version, "1.0.0")
        XCTAssertEqual(first.title, "1.0, the first release")
        XCTAssertEqual(first.dateText, "November 5, 2026")
    }

    // MARK: Titles and dates

    func testTitleOfOneBuild() {
        let single = ReleaseNote(build: Self.testBuild, version: "1.0.1", date: "2026-11-20", items: ["A", "B"])
        XCTAssertEqual(single.title, "1.0.1, build \(Self.testBuild)")
        XCTAssertEqual(Self.history[0].title, "1.1, build \(Self.testBuild)")
    }

    func testTitleOfAFoldedBeta() {
        let beta = Self.note("beta 1")
        let r = Self.betaBuilds
        XCTAssertEqual(beta.title, "1.1, builds \(r.lowerBound) to \(r.upperBound), beta 1")
        let unlabeled = ReleaseNote(builds: r, version: "1.1.0", label: nil, date: "2026-12-01", items: ["A", "B"])
        XCTAssertEqual(unlabeled.title, "1.1, builds \(r.lowerBound) to \(r.upperBound)")
    }

    /// A release entry names its version alone, with or without a label, never a build.
    func testTitleOfARelease() {
        XCTAssertEqual(Self.note("the first release").title, "1.0, the first release")
        let point = Self.history.first { $0.version == "1.0.1" }!
        XCTAssertEqual(point.title, "1.0.1")
    }

    func testAFoldedEntryCoversItsWholeRangeOnly() {
        let beta = Self.note("beta 1")
        let r = Self.betaBuilds
        XCTAssertEqual(beta.first, r.lowerBound)
        XCTAssertEqual(beta.build, r.upperBound)
        XCTAssertEqual(beta.id, r.upperBound)
        for n in r { XCTAssertTrue(beta.covers(n), "build \(n)") }
        XCTAssertFalse(beta.covers(r.lowerBound - 1))
        XCTAssertFalse(beta.covers(r.upperBound + 1))
    }

    func testDateText() {
        XCTAssertEqual(Self.note("the first release").dateText, "November 5, 2026")
        XCTAssertEqual(Self.note("beta 1").dateText, "December 1, 2026")
        XCTAssertEqual(Self.history[0].dateText, "In testing")
    }

    // MARK: Shown and the two lines

    func testATestingEntryIsShownOnNeitherLine() {
        for line in [ReleaseNote.Line.beta, .release] {
            let shown = ReleaseNotes.shown(on: line, notes: Self.history)
            XCTAssertFalse(shown.contains { $0.build == Self.testBuild }, "\(line)")
            XCTAssertTrue(shown.allSatisfy { $0.status == .released }, "\(line)")
        }
    }

    func testReleaseLineShowsReleaseEntriesOnly() {
        let release = ReleaseNotes.shown(on: .release, notes: Self.history)
        XCTAssertEqual(release.map(\.build), [Self.pointBuilds.upperBound, Self.releaseBuilds.upperBound])
        XCTAssertTrue(release.allSatisfy { $0.line == .release })
    }

    /// A beta build keeps every posted entry, betas and releases alike, newest first.
    func testBetaLineShowsEveryPostedEntry() {
        let beta = ReleaseNotes.shown(on: .beta, notes: Self.history)
        XCTAssertEqual(beta.map(\.build), [Self.betaBuilds.upperBound, Self.pointBuilds.upperBound, Self.releaseBuilds.upperBound])
        // On the point release, a beta build's What's New lists the beta as newer.
        let s = ReleaseNotes.split(forBuild: Self.pointBuilds.lowerBound, notes: beta)
        XCTAssertEqual(s.newer.map(\.label), ["beta 1"])
        XCTAssertEqual(s.yours?.version, "1.0.1")
        XCTAssertEqual(s.older.map(\.version), ["1.0.0"])
    }

    /// The line comes from what the bundle script wrote: a feed and the beta word is the beta
    /// line, everything else is release.
    func testLineFromTheBundle() {
        XCTAssertEqual(ReleaseNotes.line(feedURL: "https://homevideo.app/updates/appcast.xml", shortVersion: "1.0.0"), .release)
        XCTAssertEqual(ReleaseNotes.line(feedURL: "https://example.invalid/beta.xml", shortVersion: "1.1.0 beta 1"), .beta)
        XCTAssertEqual(ReleaseNotes.line(feedURL: "https://example.invalid/beta.xml", shortVersion: "1.1.0"), .release,
                       "a feed without the beta word")
        XCTAssertEqual(ReleaseNotes.line(feedURL: nil, shortVersion: "1.1.0 beta 1"), .release, "a build from source has no feed")
        XCTAssertEqual(ReleaseNotes.line(feedURL: "", shortVersion: nil), .release, "a run with no bundle")
    }

    // MARK: The split

    func testSplitInsideAFoldedEntry() {
        let notes = ReleaseNotes.shown(on: .beta, notes: Self.history)
        let r = Self.betaBuilds
        for n in r {
            let s = ReleaseNotes.split(forBuild: n, notes: notes)
            XCTAssertEqual(s.yours?.label, "beta 1", "build \(n)")
            XCTAssertTrue(s.newer.isEmpty, "build \(n)")
            XCTAssertEqual(s.older.map(\.build), [Self.pointBuilds.upperBound, Self.releaseBuilds.upperBound], "build \(n)")
        }
    }

    func testSplitForABuildInTheOldestEntry() {
        let notes = ReleaseNotes.shown(on: .beta, notes: Self.history)
        let s = ReleaseNotes.split(forBuild: Self.releaseBuilds.lowerBound + 1, notes: notes)
        XCTAssertEqual(s.yours?.label, "the first release")
        XCTAssertEqual(s.newer.map(\.build), [Self.betaBuilds.upperBound, Self.pointBuilds.upperBound])
        XCTAssertTrue(s.older.isEmpty)
    }

    /// A test build ahead of every posted build lists them all as earlier and never its own notes.
    func testSplitOnATestBuildListsEveryPostedBuildAsEarlier() {
        let notes = ReleaseNotes.shown(on: .beta, notes: Self.history)
        let s = ReleaseNotes.split(forBuild: Self.testBuild, notes: notes)
        XCTAssertNil(s.yours)
        XCTAssertTrue(s.newer.isEmpty)
        XCTAssertEqual(s.older.map(\.build), notes.map(\.build))
        // The same on the real notes: one past the newest posted build, whatever that is today.
        let ahead = (ReleaseNotes.shown.first?.build ?? ReleaseNotes.firstBuild) + 1
        let real = ReleaseNotes.split(forBuild: ahead)
        XCTAssertNil(real.yours)
        XCTAssertTrue(real.newer.isEmpty)
        XCTAssertEqual(real.older.map(\.build), ReleaseNotes.shown.map(\.build))
    }

    func testSplitBeforeTheFirstNotes() {
        let notes = ReleaseNotes.shown(on: .beta, notes: Self.history)
        let s = ReleaseNotes.split(forBuild: Self.releaseBuilds.lowerBound - 1, notes: notes)
        XCTAssertNil(s.yours)
        XCTAssertEqual(s.newer.map(\.build), notes.map(\.build))
        XCTAssertTrue(s.older.isEmpty)
        let real = ReleaseNotes.split(forBuild: ReleaseNotes.firstBuild - 1)
        XCTAssertNil(real.yours)
        XCTAssertEqual(real.newer.map(\.build), ReleaseNotes.shown.map(\.build))
        XCTAssertEqual(real.newer.last?.first, ReleaseNotes.firstBuild)
        XCTAssertTrue(real.older.isEmpty)
    }
}
