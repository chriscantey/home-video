import Foundation

/// One build's notes: what a person can now do or what got better, in a few short plain lines.
/// An entry covers the builds `first` through `build`, so a run of builds can share one entry,
/// the way a beta folds every build since the one before it.
public struct ReleaseNote: Equatable, Sendable, Identifiable {
    /// `testing` is a build not yet posted: it stays in the source, shown nowhere, and flips to
    /// `released` the day it is posted.
    public enum Status: String, Sendable { case released, testing }
    /// Which update line handed the entry out. A release-line build lists release entries only,
    /// never the betas or a build number. A beta build lists every posted entry.
    public enum Line: String, Sendable { case beta, release }

    public let first: Int
    public let build: Int
    /// The marketing version the build shipped as, "1.1.0".
    public let version: String
    /// The day it shipped, `yyyy-MM-dd`, Pacific.
    public let date: String
    public let status: Status
    /// Names a folded entry ("beta 1"), nil for one build.
    public let label: String?
    public let line: Line
    public let items: [String]

    public var id: Int { build }

    public init(build: Int, version: String, date: String, status: Status = .released, line: Line = .beta,
                items: [String]) {
        self.init(builds: build...build, version: version, label: nil, date: date, status: status, line: line,
                  items: items)
    }

    public init(builds: ClosedRange<Int>, version: String, label: String?, date: String, status: Status = .released,
                line: Line = .beta, items: [String]) {
        first = builds.lowerBound
        build = builds.upperBound
        self.version = version
        self.date = date
        self.status = status
        self.label = label
        self.line = line
        self.items = items
    }

    public func covers(_ n: Int) -> Bool { (first...build).contains(n) }

    /// "1.1.0" reads "1.1", "1.0.1" stays whole.
    public var shortVersion: String { version.hasSuffix(".0") ? String(version.dropLast(2)) : version }

    /// "<version>, build <n>" for one build, or "<version>, builds <first> to <last>, <label>"
    /// for a folded entry.
    /// A release entry names its version alone, "1.0, the first release": no build number.
    public var title: String {
        if line == .release { return shortVersion + (label.map { ", \($0)" } ?? "") }
        if first == build { return "\(shortVersion), build \(build)" }
        return "\(shortVersion), builds \(first) to \(build)" + (label.map { ", \($0)" } ?? "")
    }

    /// "November 5, 2026", or "In testing" for a build not yet posted. Built by hand so the
    /// locale never changes the words.
    public var dateText: String {
        if status == .testing { return "In testing" }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return date }
        return "\(Self.months[parts[1] - 1]) \(parts[2]), \(parts[0])"
    }

    static let months = ["January", "February", "March", "April", "May", "June", "July",
                         "August", "September", "October", "November", "December"]
}

/// Every build's notes, newest first: the one source for the What's New window and the update
/// page's Release Notes (a script reads this file for the page, so keep one entry per
/// `ReleaseNote(` line and plain string literals). Every release adds its entry when it
/// ships, and a build in testing is written ahead as `.testing`. House style: two to five
/// items, one short line each, sentence case, what changed for the person and never how.
/// Posted entries are one per version handed out, so a reader sees what changed since the
/// version they had: the dev builds' `.testing` entries fold into one
/// `ReleaseNote(builds:label:)` when a beta is posted, a release folds every beta since the
/// last release into one entry, and nothing tried and removed in between is listed.
/// `ReleaseNotesTests` holds the rules.
public enum ReleaseNotes {
    public static let all: [ReleaseNote] = [
        ReleaseNote(builds: 38...38, version: "1.0.1", label: nil, date: "2026-11-08", status: .released, line: .release, items: ["Now inside the app: homevideo-render, for scripts and pipelines","From the command line: every setting, output size, trim and saved preset"]),
        ReleaseNote(builds: 36...37, version: "1.0.0", label: "the first release", date: "2026-11-05", status: .released, line: .release, items: [
            "The first release of Home Video",
            "New versions arrive through Check for Updates, if you let them",
        ]),
    ]

    /// The first build with notes. Every build from here to the app's has an entry.
    public static let firstBuild = 36

    /// What a person ever sees: posted builds only. The window and the page both read this.
    public static var shown: [ReleaseNote] { all.filter { $0.status == .released } }

    /// What a build on `line` lists: a release build sees release entries only, a beta build
    /// sees every posted entry.
    public static func shown(on line: ReleaseNote.Line, notes: [ReleaseNote] = all) -> [ReleaseNote] {
        let posted = notes.filter { $0.status == .released }
        return line == .release ? posted.filter { $0.line == .release } : posted
    }

    /// The line a bundle is on, from what tools/bundle-app.sh wrote into it. The beta line
    /// always carries the beta word in its version ("1.1.0 beta 1") and a feed. Everything
    /// else is the release line, including a build from source with no feed and a run with no
    /// bundle, so a build anyone makes from this repo lists release entries only.
    public static func line(feedURL: String?, shortVersion: String?) -> ReleaseNote.Line {
        guard let feedURL, !feedURL.isEmpty else { return .release }
        return (shortVersion ?? "").contains("beta") ? .beta : .release
    }

    /// The entry holding build `n`, if any, posted or not.
    public static func entry(for n: Int) -> ReleaseNote? { all.first { $0.covers(n) } }

    /// The What's New window's three parts for someone on build `n`: the entries after theirs,
    /// their own, and the ones before, each newest first.
    public struct Split: Equatable, Sendable {
        public let newer: [ReleaseNote]
        public let yours: ReleaseNote?
        public let older: [ReleaseNote]
    }

    public static func split(forBuild n: Int, notes: [ReleaseNote] = shown) -> Split {
        let yours = notes.first { $0.covers(n) }
        let first = yours?.first ?? n
        let last = yours?.build ?? n
        return Split(newer: notes.filter { $0.first > last },
                     yours: yours,
                     older: notes.filter { $0.build < first })
    }
}
