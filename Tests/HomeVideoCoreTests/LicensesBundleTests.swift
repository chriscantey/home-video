import XCTest

/// The notices that ship in the app: `tools/bundle-app.sh`, run with `HOMEVIDEO_LICENSES_ONLY`,
/// copies the app's GPL-3 LICENSE and Sparkle's MIT license (which also carries the notices of
/// what Sparkle bundles: bsdiff, sais, ed25519 and SUSignatureVerifier) into a Licenses folder,
/// the same step that fills `Contents/Resources/Licenses` in a real bundle.
final class LicensesBundleTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    func testTheBundleCarriesTheAppAndThirdPartyLicenses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hv-licenses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("tools/bundle-app.sh").path]
        var env = ProcessInfo.processInfo.environment
        env["HOMEVIDEO_LICENSES_ONLY"] = dir.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, out)

        let licenses = dir.appendingPathComponent("Licenses")
        let names = try FileManager.default.contentsOfDirectory(atPath: licenses.path).sorted()
        XCTAssertEqual(names, ["HomeVideo-LICENSE.txt", "sparkle-LICENSE.txt"])

        let app = try String(contentsOf: licenses.appendingPathComponent("HomeVideo-LICENSE.txt"), encoding: .utf8)
        XCTAssertTrue(app.contains("GNU GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(app.contains("Version 3, 29 June 2007"))

        let sparkle = try String(contentsOf: licenses.appendingPathComponent("sparkle-LICENSE.txt"), encoding: .utf8)
        for notice in ["Andy Matuschak", "Permission is hereby granted", "bsdiff", "sais", "Ed25519", "SUSignatureVerifier"] {
            XCTAssertTrue(sparkle.contains(notice), "Sparkle's license names \(notice)")
        }
    }
}
