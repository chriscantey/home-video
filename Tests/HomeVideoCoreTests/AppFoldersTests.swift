import XCTest
@testable import HomeVideoCore

final class AppFoldersTests: XCTestCase {
    func testFoldersAreNamedForTheApp() {
        XCTAssertEqual(AppFolders.name, "Home Video")
        XCTAssertTrue(UserPresets.defaultFolder.path.hasSuffix("Library/Application Support/Home Video/Presets"))
        XCTAssertTrue(Sidecar.fallbackFolder.path.hasSuffix("Library/Application Support/Home Video/Sidecars"))
        XCTAssertTrue(PerfLog.defaultURL.path.hasSuffix("Library/Logs/Home Video/perf.log"))
    }

    func testPasteboardType() {
        XCTAssertEqual(SettingsClipboard.typeIdentifier, "co.wonders.homevideo.settings")
    }
}
