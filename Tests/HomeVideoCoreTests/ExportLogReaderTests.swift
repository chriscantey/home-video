import XCTest
@testable import HomeVideoCore

/// `ExportLog.recent(hours:)`, the Export Log window's reader.
final class ExportLogReaderTests: XCTestCase {
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_792_100_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportLogReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("export.log") }

    /// A line as the writer stamps it, `hoursAgo` before `now`.
    private func line(_ hoursAgo: Double, _ rest: String) -> String {
        let t = ISO8601DateFormatter.string(from: now.addingTimeInterval(-hoursAgo * 3600), timeZone: .current,
                                            formatOptions: [.withInternetDateTime])
        return "\(t) \(rest)"
    }

    private func writeLog(_ lines: [String], to file: URL? = nil) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: file ?? url, atomically: true, encoding: .utf8)
    }

    func testTwentyFourHourWindow() throws {
        try writeLog([line(25, "start clip=old.mov"), line(23, "start clip=kept.mov")])
        let got = ExportLog(url: url).recent(hours: 24, now: now)
        XCTAssertEqual(got.map(\.text), [line(23, "start clip=kept.mov")], "23 h stays, 25 h goes")
    }

    func testNewestFirst() throws {
        try writeLog([line(3, "start clip=a.mov"), line(2, "progress clip=a.mov percent=50"),
                      line(1, "done clip=a.mov frames=10")])
        let got = ExportLog(url: url).recent(hours: 24, now: now)
        XCTAssertEqual(got.map(\.event), ["done", "progress", "start"])
        XCTAssertEqual(ExportLog.summary(got), "1 export, 3 lines, last 24 hours, newest first")
    }

    func testEmptyFile() throws {
        try Data().write(to: url)
        let got = ExportLog(url: url).recent(hours: 24, now: now)
        XCTAssertEqual(got, [])
        XCTAssertEqual(ExportLog.summary(got), "No exports in the last 24 hours")
    }

    func testMissingFileReadsEmpty() {
        XCTAssertEqual(ExportLog(url: url).recent(hours: 24, now: now), [])
    }

    func testMalformedLineKeptAsText() throws {
        try writeLog(["not a time at all", line(2, "start clip=a.mov"), "garbage \u{1}\u{2} line",
                      line(1, "done clip=a.mov")])
        let got = ExportLog(url: url).recent(hours: 24, now: now)
        XCTAssertEqual(got.map(\.text), [line(1, "done clip=a.mov"), "garbage \u{1}\u{2} line",
                                         line(2, "start clip=a.mov"), "not a time at all"],
                       "an undated line stays beside the line before it, a leading one at the oldest end")
        XCTAssertNil(got[1].date)
        XCTAssertNil(got[1].event)
    }

    func testMalformedLineAfterAnOldLineGoesWithIt() throws {
        try writeLog([line(30, "fail clip=a.mov"), "  continuation of the error", line(1, "start clip=b.mov")])
        let got = ExportLog(url: url).recent(hours: 24, now: now)
        XCTAssertEqual(got.map(\.text), [line(1, "start clip=b.mov")])
    }

    func testRotatedLogReadBeforeLive() throws {
        try writeLog([line(30, "start clip=gone.mov"), line(5, "done clip=rotated.mov")],
                     to: dir.appendingPathComponent("export.log.1"))
        try writeLog([line(1, "start clip=live.mov")])
        let got = ExportLog(url: url).recent(hours: 24, now: now)
        XCTAssertEqual(got.map(\.text), [line(1, "start clip=live.mov"), line(5, "done clip=rotated.mov")])
    }

    func testRotatedWithLiveMissing() throws {
        try writeLog([line(2, "start clip=a.mov")], to: dir.appendingPathComponent("export.log.1"))
        XCTAssertEqual(ExportLog(url: url).recent(hours: 24, now: now).count, 1)
    }

    func testReadsWhatTheWriterWrites() throws {
        let log = ExportLog(url: url)
        log.write("start", [("clip", "My Clip.mov"), ("codec", "h264")])
        log.write("done", [("clip", "My Clip.mov"), ("frames", "12")])
        let got = log.recent(hours: 24)
        XCTAssertEqual(got.map(\.event), ["done", "start"])
        XCTAssertTrue(got.allSatisfy { $0.date != nil }, "every written line carries a time the reader parses")
        XCTAssertTrue(got[1].text.contains("clip=\"My Clip.mov\""))
    }

    func testFractionalSecondsParse() {
        XCTAssertNotNil(ExportLog.date(of: "2026-10-15T16:47:18.250-07:00 start"))
        XCTAssertNotNil(ExportLog.date(of: "2026-10-15T23:47:18Z start"))
        XCTAssertNil(ExportLog.date(of: "yesterday start"))
        XCTAssertNil(ExportLog.date(of: ""))
    }
}
