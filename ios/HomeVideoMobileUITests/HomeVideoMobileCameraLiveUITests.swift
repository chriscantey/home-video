import XCTest

/// On its side, a zoom on the camera keeps the column's shape, and the carousel's stills follow
/// the picture, so a hand over the lens at the start does not stay on the cards. The fixture
/// plays as the camera (`HV_CAMERA_FIXTURE`).
final class HomeVideoMobileCameraLiveUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// On its side, the column's frame, its controls' frames, the readout and the lens buttons
    /// before a zoom change, right after the lens button (the zoom still ramping), after it,
    /// and after a pinch: equal.
    @MainActor
    func testCameraZoomKeepsColumn() throws {
        let app = launch()
        openCamera(app)
        XCTAssertTrue(app.buttons["cameraRecord"].waitForExistence(timeout: 10), "the live camera screen did not show")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        let window = app.windows.firstMatch.frame
        guard window.width > window.height else {
            print("HVSTEP camera landscape skipped: the window stayed \(window) after rotating")
            return
        }
        let before = frames(app, "before")
        shoot(app, "zoom-01-before")
        app.buttons["zoom-2"].tap()
        let during = frames(app, "during")
        sleep(2)
        let after = frames(app, "after-button")
        shoot(app, "zoom-02-after-button")
        app.descendants(matching: .any)["cameraSurface"].firstMatch.pinch(withScale: 0.75, velocity: -1)
        let pinched = frames(app, "after-pinch")
        sleep(1)
        let settled = frames(app, "settled")
        shoot(app, "zoom-03-after-pinch")
        for (name, f) in [("during", during), ("after the button", after), ("after the pinch", pinched), ("settled", settled)] {
            XCTAssertEqual(f, before, "the column moved \(name)")
        }
        app.buttons["zoom-1"].tap()
        sleep(1)
    }

    /// The stills follow the picture: a card's image changes between two looks 4 s apart while
    /// the camera runs, and stays as it was through a recording. The readout's frame rate and
    /// dropped count are printed at the start and the end, for the cost.
    @MainActor
    func testCameraStillsRefresh() throws {
        let app = launch()
        openCamera(app)
        let record = app.buttons["cameraRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "the live camera screen did not show")
        let readout = app.descendants(matching: .any)["cameraReadout"].firstMatch
        sleep(4)
        print("HVSTEP readout start \(readout.label)")
        let card = app.buttons["look-good-deck"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let a = pixels(card)
        sleep(4)
        let b = pixels(card)
        let live = difference(a, b)
        print("HVSTEP stills change while live \(String(format: "%.4f", live))")
        shoot(app, "stills-01-live")

        record.tap()
        XCTAssertTrue(app.staticTexts["cameraClock"].waitForExistence(timeout: 5), "recording did not start")
        sleep(1)
        let c = pixels(card)
        sleep(4)
        let d = pixels(card)
        let recording = difference(c, d)
        print("HVSTEP stills change while recording \(String(format: "%.4f", recording))")
        record.tap()
        XCTAssertTrue(app.buttons["cameraSaved"].waitForExistence(timeout: 30), "the recording was not saved")
        print("HVSTEP saved \(app.buttons["cameraSaved"].label)")
        sleep(8)
        print("HVSTEP readout end \(readout.label)")
        XCTAssertGreaterThan(live, 0.002, "the stills did not refresh while the camera ran")
        XCTAssertLessThan(recording, 0.002, "the stills changed while recording")
    }

    // MARK: Steps

    /// The column and the controls in it, rounded to a tenth of a point.
    @MainActor
    private func frames(_ app: XCUIApplication, _ tag: String) -> [String] {
        let items: [(String, XCUIElement)] = [
            ("column", app.descendants(matching: .any)["cameraColumn"].firstMatch),
            ("mode", app.segmentedControls["cameraControlsMode"]),
            ("record", app.buttons["cameraRecord"]),
            ("crop", app.buttons["cameraCrop"]),
            ("looks", app.scrollViews["looks"]),
            ("framing", app.buttons["param-framing.mode"]),
            ("surface", app.descendants(matching: .any)["cameraSurface"].firstMatch),
            ("lens-1", app.buttons["zoom-1"]),
            ("lens-2", app.buttons["zoom-2"]),
        ]
        let out = items.map { name, e -> String in
            guard e.exists else { return "\(name) none" }
            let f = e.frame
            let r = { (v: CGFloat) in String(format: "%.1f", v) }
            return "\(name) \(r(f.minX)),\(r(f.minY)) \(r(f.width))x\(r(f.height))"
        }
        // The readout over the picture, printed only: its first line's numbers change on their own.
        let readout = app.descendants(matching: .any)["cameraReadout"].firstMatch
        print("HVSTEP frames \(tag): " + out.joined(separator: " | ") + " || readout \(readout.frame) \(readout.label)")
        return out
    }

    /// A small gray copy of the element's pixels.
    @MainActor
    private func pixels(_ e: XCUIElement) -> [UInt8] {
        guard let cg = e.screenshot().image.cgImage else { return [] }
        let w = 32, h = 24
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    /// The mean absolute difference of two copies, 0 to 1.
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let sum = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(sum) / Double(a.count) / 255
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["HV_CAMERA_FIXTURE"] {
            app.launchArguments += ["-homevideoCameraFixture", path]
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

    /// The bar's Camera button, or the More menu's entry where the bar has none.
    @MainActor
    private func openCamera(_ app: XCUIApplication) {
        let entry = app.buttons["camera"]
        if !entry.waitForExistence(timeout: 10) {
            app.buttons["more"].tap()
            XCTAssertTrue(entry.waitForExistence(timeout: 5), "no Camera")
        }
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
