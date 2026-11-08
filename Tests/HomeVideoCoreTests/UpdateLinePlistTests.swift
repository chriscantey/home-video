import XCTest

/// The update keys by line: `tools/bundle-app.sh`, run with
/// `HOMEVIDEO_PLIST_ONLY`, writes the Info.plist each line asks for, read back with `plutil`.
/// release and beta carry exactly the five Sparkle keys with their own feed, none carries no
/// Sparkle key at all, and nothing ever turns on automatic checks or system profiling. The beta
/// line also needs `HOMEVIDEO_BETA` and writes "<version> beta <n>", the others refuse it.
final class UpdateLinePlistTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private let publicKey = "5DEOh6AC+kCk0wZDOBlfbBtr4MsIzieG1VrKttvitXM="
    /// The beta feed is unlisted and never lives in the repo, so the test hands the script a
    /// stand-in through `HV_BETA_FEED_URL`.
    private static let placeholderBetaFeed = "https://example.com/homevideo/beta.xml"

    private struct Run {
        let status: Int32
        let output: String
        let plist: [String: Any]
    }

    /// Runs the script's plist step for one line in a scratch folder and reads the plist back.
    private func run(line: String?, beta: String? = nil, betaFeed: String? = UpdateLinePlistTests.placeholderBetaFeed) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hv-plist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plistURL = dir.appendingPathComponent("Info.plist")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("tools/bundle-app.sh").path]
        var env = ProcessInfo.processInfo.environment
        env["HOMEVIDEO_PLIST_ONLY"] = plistURL.path
        env.removeValue(forKey: "HOMEVIDEO_UPDATE_LINE")
        if let line { env["HOMEVIDEO_UPDATE_LINE"] = line }
        env.removeValue(forKey: "HOMEVIDEO_BETA")
        if let beta { env["HOMEVIDEO_BETA"] = beta }
        env.removeValue(forKey: "HV_BETA_FEED_URL")
        if let betaFeed { env["HV_BETA_FEED_URL"] = betaFeed }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return Run(status: p.terminationStatus, output: out, plist: [:]) }

        let read = Process()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        read.arguments = ["-convert", "xml1", "-o", "-", plistURL.path]
        let readPipe = Pipe()
        read.standardOutput = readPipe
        try read.run()
        let data = readPipe.fileHandleForReading.readDataToEndOfFile()
        read.waitUntilExit()
        XCTAssertEqual(read.terminationStatus, 0, "plutil read")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return Run(status: 0, output: out, plist: plist)
    }

    private func sparkleKeys(_ plist: [String: Any]) -> Set<String> {
        Set(plist.keys.filter { $0.hasPrefix("SU") })
    }

    /// AppInfo.version and AppInfo.build, read from the app's source since the test target only
    /// sees the core.
    private func appInfo() throws -> (version: String, build: Int) {
        let text = try String(contentsOf: root.appendingPathComponent("Sources/HomeVideo/HomeVideoApp.swift"), encoding: .utf8)
        func capture(_ pattern: String) throws -> String {
            let re = try NSRegularExpression(pattern: pattern)
            let m = try XCTUnwrap(re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), pattern)
            return String(text[try XCTUnwrap(Range(m.range(at: 1), in: text))])
        }
        return (try capture(#"static let version = "([^"]+)""#), try XCTUnwrap(Int(try capture(#"static let build = (\d+)"#))))
    }

    private func assertFeedLine(_ line: String, feed: String, beta: String? = nil) throws {
        let r = try run(line: line, beta: beta)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(sparkleKeys(r.plist), ["SUFeedURL", "SUPublicEDKey", "SUScheduledCheckInterval", "SURequireSignedFeed",
                                              "SUVerifyUpdateBeforeExtraction"])
        XCTAssertEqual(r.plist["SUFeedURL"] as? String, feed)
        XCTAssertEqual(r.plist["SUPublicEDKey"] as? String, publicKey)
        XCTAssertEqual(r.plist["SUScheduledCheckInterval"] as? Int, 86400)
        XCTAssertEqual(r.plist["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(r.plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertTrue(r.output.contains("updates:    \(line) \(feed)"), r.output)
        XCTAssertEqual(r.plist["CFBundleExecutable"] as? String, "HomeVideo")
    }

    func testReleaseLineWritesTheSiteFeed() throws {
        try assertFeedLine("release", feed: "https://homevideo.app/updates/appcast.xml")
    }

    func testBetaLineWritesTheFeedFromTheEnvironment() throws {
        try assertFeedLine("beta", feed: Self.placeholderBetaFeed, beta: "1")
    }

    func testBetaLineWithoutAFeedStops() throws {
        let r = try run(line: "beta", beta: "1", betaFeed: nil)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("FATAL: HOMEVIDEO_UPDATE_LINE=beta needs HV_BETA_FEED_URL"), r.output)
    }

    // The word on the box by line: "0.2.0 beta 1" on beta, the version alone on
    // release and none, and the build number unchanged on every line.

    func testBetaLineWritesTheBetaWord() throws {
        let app = try appInfo()
        let r = try run(line: "beta", beta: "1")
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(r.plist["CFBundleShortVersionString"] as? String, "\(app.version) beta 1")
        XCTAssertEqual(r.plist["CFBundleVersion"] as? String, "\(app.build)")
        XCTAssertTrue(r.output.contains("version:    \(app.version) beta 1 (\(app.build))"), r.output)
    }

    func testBetaLineWithoutABetaNumberStops() throws {
        let r = try run(line: "beta")
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("FATAL: HOMEVIDEO_UPDATE_LINE=beta needs HOMEVIDEO_BETA"), r.output)
    }

    func testBetaLineRefusesANumberThatIsNotOne() throws {
        for bad in ["0", "x", "1.5", "-1"] {
            let r = try run(line: "beta", beta: bad)
            XCTAssertNotEqual(r.status, 0, bad)
            XCTAssertTrue(r.output.contains("FATAL: HOMEVIDEO_BETA must be a whole number"), r.output)
        }
    }

    func testReleaseAndNoneWriteTheVersionAlone() throws {
        let app = try appInfo()
        for line in ["release", "none"] {
            let r = try run(line: line)
            XCTAssertEqual(r.status, 0, r.output)
            XCTAssertEqual(r.plist["CFBundleShortVersionString"] as? String, app.version, line)
            XCTAssertEqual(r.plist["CFBundleVersion"] as? String, "\(app.build)", line)
            XCTAssertTrue(r.output.contains("version:    \(app.version) (\(app.build))"), r.output)
        }
    }

    func testReleaseAndNoneRefuseABetaNumber() throws {
        for line in ["release", "none"] {
            let r = try run(line: line, beta: "1")
            XCTAssertNotEqual(r.status, 0, line)
            XCTAssertTrue(r.output.contains("FATAL: HOMEVIDEO_BETA is for the beta line only"), r.output)
        }
    }

    func testNoneLineWritesNoUpdateKey() throws {
        let r = try run(line: "none")
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(sparkleKeys(r.plist), [])
        XCTAssertTrue(r.output.contains("updates:    none none"), r.output)
    }

    func testTheDefaultLineIsNone() throws {
        let r = try run(line: nil)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(sparkleKeys(r.plist), [])
        XCTAssertTrue(r.output.contains("updates:    none none"), r.output)
    }

    func testAnUnknownLineStops() throws {
        let r = try run(line: "dev")
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("FATAL: HOMEVIDEO_UPDATE_LINE"), r.output)
    }
}
