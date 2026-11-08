import XCTest

/// The camera screen in the Simulator, which has no camera: the bar's button, the "No camera
/// available" state, and the live path fed by a fixture through the same callbacks the camera
/// uses (`HV_CAMERA_FIXTURE`, DEBUG builds only). The fixture plays a sensor: it turns its
/// frames by the Simulator's rotation and by the app's capture angle, so a wrong angle shows
/// as a turned picture. Screenshots go to `HV_SHOTS` as the main test's do, landscape ones
/// through the runner's `simctl io` (`<name>.take`).
final class HomeVideoMobileCameraUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// The bar's button opens the camera screen with no clip open, and the Simulator shows its state.
    @MainActor
    func testCameraNoCamera() throws {
        let app = launch(fixture: false)
        openCamera(app)
        let none = app.staticTexts["No camera available"]
        XCTAssertTrue(none.waitForExistence(timeout: 10), "the no camera state did not show")
        sleep(1)
        shoot(app, "camera-02-no-camera")
        app.buttons["cameraClose"].tap()
        XCTAssertTrue(app.buttons["more"].waitForExistence(timeout: 5), "closing did not return to the editor")
    }

    /// The fixture plays as the camera, with the editor's controls: a Look from the carousel,
    /// All Controls in a low sheet with a value changed, the lens buttons and a pinch, a tap
    /// to focus, Framing's crop, then 4 seconds recorded and saved to Photos.
    @MainActor
    func testCameraFixtureRecord() throws {
        let app = launch(fixture: true)
        openCamera(app)
        let record = app.buttons["cameraRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "the live camera screen did not show")
        sleep(3)
        shoot(app, "camera-03-live-fixture")

        // A Look from the carousel, as in the editor.
        let card = app.buttons["look-good-deck"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no Look carousel on the camera")
        card.tap()
        sleep(1)
        XCTAssertTrue(card.isSelected, "the carousel did not take the Look")

        // All Controls, low, with the picture above it.
        app.buttons["cameraAllControls"].tap()
        XCTAssertTrue(app.buttons["allControlsDone"].waitForExistence(timeout: 10), "All Controls did not open")
        sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["cameraSurface"].firstMatch.isHittable,
                      "the picture is hidden under All Controls")
        // No clip is open, and the sheet's Shuffle still works: the camera is the picture.
        let sheetShuffle = app.buttons.matching(NSPredicate(format: "label == 'Shuffle' AND identifier == ''")).firstMatch
        XCTAssertTrue(sheetShuffle.waitForExistence(timeout: 5) && sheetShuffle.isEnabled, "the sheet's Shuffle is off on the camera")
        shoot(app, "camera-06-all-controls")
        // The sheet to its large detent, as a person drags it, so the Framing rows are drawn
        // without a scroll (a scroll on a 17 Pro puts the slider under the pinned chips).
        let bar = app.navigationBars["All Controls"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.05)))
        sleep(1)
        let zoom = app.sliders["param-framing.zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5), "no Framing zoom in All Controls")
        let before = zoom.value as? String
        zoom.adjust(toNormalizedSliderPosition: 0.5)
        sleep(1)
        print("HVSTEP all-controls framing zoom \(before ?? "") -> \(zoom.value ?? "")")
        XCTAssertNotEqual(before, zoom.value as? String, "the value did not move")
        shoot(app, "camera-06b-all-controls-large")
        app.buttons["allControlsDone"].tap()
        XCTAssertTrue(app.buttons["allControlsDone"].waitForNonExistence(timeout: 10), "All Controls did not close")

        // The lens: a button, then a pinch.
        let readout = app.descendants(matching: .any)["cameraReadout"].firstMatch
        XCTAssertTrue(app.buttons["zoom-0.5"].exists && app.buttons["zoom-1"].exists
                      && app.buttons["zoom-2"].exists && app.buttons["zoom-5"].exists, "lens buttons missing")
        app.buttons["zoom-2"].tap()
        sleep(1)
        XCTAssertTrue(app.buttons["zoom-2"].isSelected, "the 2x button did not take")
        XCTAssertTrue(readout.label.contains("zoom 2.0×"), "readout: \(readout.label)")
        shoot(app, "camera-07-zoom-2x")
        let surface = app.descendants(matching: .any)["cameraSurface"].firstMatch
        surface.pinch(withScale: 0.6, velocity: -1)
        sleep(1)
        print("HVSTEP after pinch \(readout.label)")
        XCTAssertFalse(readout.label.contains("zoom 2.0×"), "the pinch did not zoom: \(readout.label)")
        app.buttons["zoom-1"].tap()
        sleep(1)

        // Tap to focus: the square shows (the Simulator has no lens to focus).
        surface.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cameraFocus"].firstMatch.waitForExistence(timeout: 2),
                      "no focus square")
        shoot(app, "camera-08-focus")
        sleep(2)

        // Framing's crop on the picture.
        app.buttons["cameraCrop"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["cropHint"].firstMatch.waitForExistence(timeout: 2), "no crop mode")
        surface.swipeLeft()
        sleep(1)
        shoot(app, "camera-09-crop")
        app.buttons["cameraCrop"].tap()

        record.tap()
        XCTAssertTrue(app.staticTexts["cameraClock"].waitForExistence(timeout: 5), "recording did not start")
        sleep(4)
        shoot(app, "camera-04-recording")
        record.tap()
        let saved = app.buttons["cameraSaved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "the recording was not saved")
        print("HVSTEP saved \(saved.label)")
        print("HVSTEP readout \(readout.label)")
        shoot(app, "camera-05-saved")
    }

    /// The camera turned with the phone: upright, then on each side, a recording in each. The
    /// files are checked outside the test (`ffprobe`, and the fixture's red band above its blue
    /// one).
    @MainActor
    func testCameraRotation() throws {
        let app = launch(fixture: true)
        openCamera(app)
        let record = app.buttons["cameraRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "the live camera screen did not show")
        sleep(3)
        shoot(app, "rot-01-portrait")
        recordClip(app, "portrait")
        for (o, name) in [(UIDeviceOrientation.landscapeLeft, "landscape-left"), (.landscapeRight, "landscape-right")] {
            XCUIDevice.shared.orientation = o
            sleep(3)
            shoot(app, "rot-02-\(name)")
            recordClip(app, name)
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shoot(app, "rot-03-portrait-again")
    }

    /// The editor's All Controls and the camera's open at the same detent with the same stage
    /// chips and the same Look rows, then the camera on its side shows the editor's Simple panel
    /// and All in the column.
    @MainActor
    func testCameraSheetParity() throws {
        let app = launch(fixture: true, clip: true)
        let allControls = app.buttons["allControls"]
        XCTAssertTrue(allControls.waitForExistence(timeout: 20), "the test clip did not open")
        sleep(2)
        allControls.tap()
        let editor = sheetPrint(app)
        shoot(app, "parity-01-editor-sheet")
        app.buttons["allControlsDone"].tap()
        XCTAssertTrue(app.buttons["allControlsDone"].waitForNonExistence(timeout: 10), "All Controls did not close")

        openCamera(app)
        XCTAssertTrue(app.buttons["cameraRecord"].waitForExistence(timeout: 10), "the live camera screen did not show")
        sleep(2)
        XCTAssertTrue(app.staticTexts["currentLook"].exists && app.buttons["shuffle"].exists,
                      "no Look header with Shuffle on the camera")
        app.buttons["cameraAllControls"].tap()
        let camera = sheetPrint(app)
        shoot(app, "parity-02-camera-sheet")
        XCTAssertEqual(editor.chips, camera.chips, "the stage chips differ")
        XCTAssertEqual(editor.rows, camera.rows, "the Look rows differ")
        XCTAssertEqual(editor.top, camera.top, accuracy: 2, "the sheets open at different detents")
        app.buttons["allControlsDone"].tap()
        XCTAssertTrue(app.buttons["allControlsDone"].waitForNonExistence(timeout: 10), "All Controls did not close")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        let window = app.windows.firstMatch.frame
        guard window.width > window.height else {
            print("HVSTEP camera landscape skipped: the window stayed \(window) after rotating")
            return
        }
        XCTAssertTrue(app.buttons["allControls"].waitForExistence(timeout: 5), "no Simple panel in the camera's column")
        XCTAssertTrue(app.buttons["param-framing.mode"].exists, "no Framing in the camera's Simple panel")
        shoot(app, "parity-03-camera-landscape-simple")
        app.segmentedControls["cameraControlsMode"].buttons["All"].tap()
        XCTAssertTrue(app.buttons["chip-tape"].waitForExistence(timeout: 5), "All did not show in the camera's column")
        sleep(1)
        shoot(app, "parity-04-camera-landscape-all")
        app.segmentedControls["cameraControlsMode"].buttons["Simple"].tap()
        sleep(1)
    }

    /// An open All Controls sheet read the same way on either screen: the chips in order, the
    /// Look section's rows, and the top of its bar.
    @MainActor
    private func sheetPrint(_ app: XCUIApplication) -> (chips: [String], rows: [String], top: CGFloat) {
        let bar = app.navigationBars["All Controls"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "All Controls did not open")
        sleep(2)
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chip-'"))
            .allElementsBoundByIndex.map(\.identifier)
        let rows = ["lookMenu", "Shuffle", "Reset Everything"].filter { app.buttons[$0].exists }
        print("HVSTEP sheet top \(bar.frame.minY) chips \(chips) rows \(rows)")
        return (chips, rows, bar.frame.minY)
    }

    // MARK: Steps

    @MainActor
    private func recordClip(_ app: XCUIApplication, _ name: String) {
        let record = app.buttons["cameraRecord"]
        if app.buttons["cameraSaved"].exists { app.buttons["cameraSaved"].tap() }
        record.tap()
        XCTAssertTrue(app.staticTexts["cameraClock"].waitForExistence(timeout: 5), "recording did not start (\(name))")
        sleep(3)
        shoot(app, "rot-rec-\(name)")
        record.tap()
        let saved = app.buttons["cameraSaved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "the \(name) recording was not saved")
        print("HVSTEP saved \(name) \(saved.label)")
    }

    @MainActor
    private func launch(fixture: Bool, clip: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if fixture, let path = ProcessInfo.processInfo.environment["HV_CAMERA_FIXTURE"] {
            app.launchArguments += ["-homevideoCameraFixture", path]
        }
        if clip, let path = ProcessInfo.processInfo.environment["HV_TEST_CLIP"] {
            app.launchArguments += ["-homevideoTestClip", path]
        }
        // `HV_EXTRA_ARGS`, such as the negative control's `-homevideoCameraAngleError 90`.
        if let extra = ProcessInfo.processInfo.environment["HV_EXTRA_ARGS"], !extra.isEmpty {
            app.launchArguments += extra.split(separator: " ").map(String.init)
        }
        addUIInterruptionMonitor(withDescription: "Photos") { alert in
            for title in ["Allow", "Allow Full Access", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        return app
    }

    /// Opens the camera from its own button in the bar, beside Choose Video.
    @MainActor
    private func openCamera(_ app: XCUIApplication) {
        let entry = app.buttons["camera"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "no Camera button in the bar")
        XCTAssertEqual(entry.label, "Camera")
        shoot(app, "camera-01-bar")
        entry.tap()
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
