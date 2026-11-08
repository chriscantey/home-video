import XCTest

/// The bar (Choose Video and Camera on the left, All Controls, More and Export on the
/// right), the empty screen's two ways in, About, the upright sheet opening only from its
/// button, and the trim brackets outside the knob's travel. Screenshots go to `HV_SHOTS` as
/// the main test's do, landscape ones through the runner's `simctl io` (`<name>.take`).
final class HomeVideoMobileBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// No clip: the bar, the empty screen with Choose Video and Camera side by side, the menu
    /// with About, and the About sheet. Then the same bar and menu with a clip, and on its side
    /// the column's top.
    @MainActor
    func testBarEmptyAndAbout() throws {
        var app = launch()
        let choose = app.buttons["chooseVideo"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15), "no Choose Video on the empty screen")
        XCTAssertTrue(app.buttons["emptyCamera"].exists, "no Camera on the empty screen")
        XCTAssertTrue(app.buttons["camera"].exists, "no Camera in the bar")
        XCTAssertFalse(app.buttons["allControls"].exists, "All Controls in the bar with no clip")
        printFrames(app, "empty", ["chooseVideo", "emptyCamera", "pickClip", "camera", "more"])
        XCTAssertEqual(choose.frame.midY, app.buttons["emptyCamera"].frame.midY, accuracy: 1,
                       "Choose Video and Camera are not side by side")
        sleep(1)
        shoot(app, "bar-01-empty")

        openMenu(app, "bar-02-menu-no-clip")
        XCTAssertEqual(app.buttons.matching(identifier: "camera").count, 1, "Camera is still in the menu")
        app.buttons["about"].tap()
        let version = app.staticTexts["aboutVersion"]
        XCTAssertTrue(version.waitForExistence(timeout: 5), "About did not open")
        print("HVSTEP about version \(version.label)")
        XCTAssertNotNil(version.label.range(of: #"(^|, )1\.0 \(\d+\)$"#, options: .regularExpression),
                        "the version reads \(version.label)")
        XCTAssertTrue(app.staticTexts["Home Video"].exists)
        sleep(1)
        shoot(app, "bar-03-about")
        app.buttons["aboutDone"].tap()
        XCTAssertTrue(version.waitForNonExistence(timeout: 5), "About did not close")

        // The empty screen's Camera opens the camera.
        app.buttons["emptyCamera"].tap()
        XCTAssertTrue(app.buttons["cameraClose"].waitForExistence(timeout: 10), "the empty screen's Camera did not open it")
        app.buttons["cameraClose"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        app.terminate()

        app = launch(clip: true)
        waitForClip(app)
        sleep(2)
        printFrames(app, "clip", ["pickClip", "camera", "allControls", "more", "export"])
        for id in ["pickClip", "camera", "allControls", "more", "export"] {
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) is not on screen")
        }
        let f = { (id: String) in app.buttons[id].frame }
        if abs(f("pickClip").midY - f("export").midY) < 2 {
            // One row: Choose Video and Camera on the left, then All Controls, More, Export.
            XCTAssertLessThan(f("camera").maxX, f("allControls").minX - 40, "Camera and All Controls are not apart")
            XCTAssertLessThan(f("allControls").maxX, f("more").minX + 1)
            XCTAssertLessThan(f("more").maxX, f("export").minX + 1)
            XCTAssertLessThan(f("allControls").maxY, 140, "All Controls is not in the top bar")
        } else {
            // The iPhone Duo puts the bar's icon buttons in its side column, in the same order
            // top to bottom, with Export alone on top.
            for (a, b) in [("pickClip", "camera"), ("camera", "allControls"), ("allControls", "more")] {
                XCTAssertLessThan(f(a).midY, f(b).midY, "\(a) is not above \(b) in the side column")
            }
        }
        shoot(app, "bar-04-bar-clip")
        openMenu(app, "bar-05-menu-clip")
        XCTAssertTrue(app.buttons["Shuffle"].exists && app.buttons["Reset Everything"].exists)
        XCTAssertFalse(app.buttons["audioDiagnostics"].exists, "Audio Diagnostics is still in the menu")
        app.buttons["about"].tap()
        XCTAssertTrue(app.staticTexts["aboutVersion"].waitForExistence(timeout: 5), "About did not open with a clip")
        app.buttons["aboutDone"].tap()
        sleep(1)

        // On its side: Choose Video and Camera at the top of the column, then More and Export.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        let window = app.windows.firstMatch.frame
        guard window.width > window.height else {
            print("HVSTEP landscape skipped: the window stayed \(window) after rotating")
            return
        }
        printFrames(app, "column", ["pickClip", "camera", "more", "export"])
        XCTAssertTrue(app.buttons["camera"].isHittable, "no Camera at the top of the column")
        XCTAssertEqual(app.buttons["camera"].frame.midY, app.buttons["pickClip"].frame.midY, accuracy: 1)
        // Export on one line, not wrapped to "Ex-port" by Camera in the same row.
        XCTAssertLessThan(app.buttons["export"].frame.height, 60, "Export wrapped onto two lines")
        // The row inside the column's 16 pt margins.
        let column = (minX: window.width - app.windows.firstMatch.frame.minX - 62 - 340, maxX: window.width - 62)
        print("HVSTEP column row \(app.buttons["pickClip"].frame.minX - column.minX) pt in, \(column.maxX - app.buttons["export"].frame.maxX) pt in")
        shoot(app, "bar-06-landscape-column")
        app.buttons["camera"].tap()
        XCTAssertTrue(app.buttons["cameraClose"].waitForExistence(timeout: 10), "the column's Camera did not open it")
        app.buttons["cameraClose"].tap()
        sleep(1)
    }

    /// Upright, the All Controls sheet opens only from its button, never by itself after a pick
    /// or on turning the phone upright with All showing in the column.
    @MainActor
    func testSheetOnlyFromItsButton() throws {
        // All remembered: a launch and a pick show no sheet.
        var app = launch(extra: ["-showAllControls", "YES"], clip: true)
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 30), "the test clip never opened")
        sleep(3)
        shoot(app, "bar-10-picked-all-remembered")
        XCTAssertFalse(app.buttons["allControlsDone"].exists, "a pick with All remembered opened the sheet")
        app.terminate()

        app = launch(clip: true)
        waitForClip(app)
        // The sheet from its button, then the phone on its side and back: closed for good.
        app.buttons["allControls"].tap()
        XCTAssertTrue(app.buttons["allControlsDone"].waitForExistence(timeout: 10), "the bar's button did not open the sheet")
        sleep(1)
        shoot(app, "bar-11-sheet-from-button")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        let window = app.windows.firstMatch.frame
        guard window.width > window.height else {
            print("HVSTEP landscape skipped: the window stayed \(window) after rotating")
            app.buttons["allControlsDone"].tap()
            return
        }
        let modeSwitch = app.segmentedControls["controlsMode"]
        XCTAssertTrue(modeSwitch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["allControlsDone"].exists, "the sheet stayed up on its side")
        // All on its side, then upright: no sheet.
        modeSwitch.buttons["All"].tap()
        sleep(2)
        shoot(app, "bar-12-landscape-all")
        XCUIDevice.shared.orientation = .portrait
        sleep(3)
        shoot(app, "bar-13-upright-after-all")
        XCTAssertFalse(app.buttons["allControlsDone"].exists, "turning upright with All on its side opened the sheet")
        // And back to Simple for the next test.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        modeSwitch.buttons["Simple"].tap()
        sleep(1)
    }

    /// The playhead's knob stays between the in and out brackets. Paused, the in
    /// bracket dragged in and the out bracket dragged in, the knob seeks to each, and a shot of
    /// each for the crops. The frames are printed for measuring.
    @MainActor
    func testTrimKnobAtBrackets() throws {
        let app = launch(clip: true)
        waitForClip(app)
        let play = app.buttons["playPause"]
        if play.label == "Pause" { play.tap() }
        sleep(1)
        let scrubber = app.descendants(matching: .any)["scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let f = scrubber.frame
        print("HVSTEP scrubber \(f) scale \(UIScreen.main.scale)")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: f.minX + 8, dy: f.midY))
            .press(forDuration: 0.2, thenDragTo: origin.withOffset(CGVector(dx: f.minX + f.width * 0.3, dy: f.midY)))
        sleep(2)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Trimmed'")).firstMatch.exists,
                      "the in bracket drag did not trim")
        print("HVSTEP knob at in \(scrubber.value ?? "")")
        shoot(app, "bar-20-knob-at-in")
        origin.withOffset(CGVector(dx: f.maxX - 8, dy: f.midY))
            .press(forDuration: 0.2, thenDragTo: origin.withOffset(CGVector(dx: f.minX + f.width * 0.7, dy: f.midY)))
        sleep(2)
        print("HVSTEP knob at out \(scrubber.value ?? "")")
        shoot(app, "bar-21-knob-at-out")
        app.buttons["more"].tap()
        app.buttons["Clear Trim"].tap()
        sleep(1)
    }

    /// App Icon from the menu: the close-up is in use on a fresh install, the sleeve takes over
    /// once picked (the system's own alert answered), and picking the close-up brings it back.
    @MainActor
    func testAppIcon() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["more"].waitForExistence(timeout: 15))
        openMenu(app, "icon-01-menu")
        XCTAssertTrue(app.buttons["appIcon"].exists, "no App Icon in the menu")
        app.buttons["appIcon"].tap()
        let name = app.descendants(matching: .any)["appIconName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "App Icon did not open")
        XCTAssertEqual(name.label, "AppIcon", "a fresh install is not on the close-up")
        sleep(1)
        shoot(app, "icon-02-close-up")

        for (row, expected, shot) in [("appIcon-AppIconSleeve", "AppIconSleeve", "icon-03-sleeve"),
                                      ("appIcon-AppIcon", "AppIcon", "icon-04-back")] {
            app.buttons[row].tap()
            dismissIconAlert()
            let changed = NSPredicate(format: "label == %@", expected)
            expectation(for: changed, evaluatedWith: name)
            waitForExpectations(timeout: 10)
            print("HVSTEP app icon \(name.label)")
            sleep(1)
            shoot(app, shot)
        }
        app.buttons["appIconDone"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5), "App Icon did not close")
    }

    // MARK: Steps

    /// The system's "You have changed the icon" alert, from SpringBoard.
    @MainActor
    private func dismissIconAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let ok = springboard.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 5) { ok.tap() }
    }

    @MainActor
    private func openMenu(_ app: XCUIApplication, _ shot: String) {
        app.buttons["more"].tap()
        XCTAssertTrue(app.buttons["about"].waitForExistence(timeout: 5), "no About in the menu")
        XCTAssertEqual(app.buttons["about"].label, "About Home Video")
        sleep(1)
        shoot(app, shot)
    }

    @MainActor
    private func printFrames(_ app: XCUIApplication, _ tag: String, _ ids: [String]) {
        let line = ids.map { id -> String in
            let b = app.buttons[id]
            return b.exists ? "\(id) \(Int(b.frame.minX))..\(Int(b.frame.maxX)) y\(Int(b.frame.midY))" : "\(id) none"
        }
        print("HVSTEP frames \(tag) window \(app.windows.firstMatch.frame.size): " + line.joined(separator: ", "))
    }

    @MainActor
    private func waitForClip(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 30), "the test clip never opened")
        sleep(2)
    }

    @MainActor
    private func launch(extra: [String] = [], clip: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra
        if clip, let path = ProcessInfo.processInfo.environment["HV_TEST_CLIP"] {
            app.launchArguments += ["-homevideoTestClip", path]
        }
        if let path = ProcessInfo.processInfo.environment["HV_CAMERA_FIXTURE"] {
            app.launchArguments += ["-homevideoCameraFixture", path]
        }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        return app
    }

    static let shots = ProcessInfo.processInfo.environment["HV_SHOTS"]

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        if let dir = Self.shots, XCUIDevice.shared.orientation.isLandscape {
            // A landscape capture from inside the test comes back squeezed. The runner takes
            // it with `simctl io` when it sees `<name>.take`.
            let take = URL(fileURLWithPath: dir).appendingPathComponent("\(name).take")
            FileManager.default.createFile(atPath: take.path, contents: nil)
            for _ in 0..<40 where FileManager.default.fileExists(atPath: take.path) { usleep(250_000) }
        } else if let dir = Self.shots {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let cg = shot.image.cgImage, let png = UIImage(cgImage: cg).pngData() {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        print("HVSTEP \(name) \(Date().timeIntervalSince1970)")
    }
}
