import XCTest

/// Drives the phone app end to end in the Simulator: pick the one clip in the library through
/// the system picker, choose a Look, change Framing, open All Controls and turn a stage on and
/// move one of its layer's values, export at the default size to Photos. Every screen and sheet
/// is attached as a screenshot (`xcresulttool export attachments` takes them out).
final class HomeVideoMobileUITests: XCTestCase {
    /// The Look the test chooses: a hard one, so the screenshots show the chain at work.
    static let lookID = "dub-of-a-dub"
    static let hold: UInt32 = 3

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPickLookFramingAllControlsExport() throws {
        // The clip opens by the test-only argument. `testPicker` covers the system picker.
        let app = launch(clip: true)
        waitForClip(app)
        sleep(Self.hold)
        shoot(app, "02-simple-fresh-sp")

        // A Look that films the screen first, so the next one has a Display to take away.
        let filmed = app.buttons["look-filmed-tv"]
        XCTAssertTrue(filmed.waitForExistence(timeout: 10))
        bringIntoRow(app, filmed, row: app.scrollViews["looks"])
        filmed.tap()
        sleep(Self.hold)
        shoot(app, "03a-look-filmed-tv")

        // A tape Look from the carousel.
        let look = app.buttons["look-\(Self.lookID)"]
        XCTAssertTrue(look.waitForExistence(timeout: 10))
        bringIntoRow(app, look, row: app.scrollViews["looks"])
        look.tap()
        let shown = app.staticTexts["currentLook"]
        XCTAssertTrue(shown.waitForExistence(timeout: 5))
        XCTAssertEqual(shown.label, "Dub of a Dub", "the Look did not change")
        sleep(Self.hold)
        shoot(app, "03-look-dub-of-a-dub")

        // Full screen from the preview's button, closed by a swipe down.
        app.buttons["fullScreen"].tap()
        let player = app.descendants(matching: .any)["fullScreenPlayer"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 5), "full screen did not open")
        sleep(Self.hold)
        shoot(app, "03b-fullscreen-portrait")
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertTrue(player.waitForNonExistence(timeout: 5), "a swipe down did not close full screen")
        sleep(1)

        // Framing: the mode, then the zoom slider and a pinch on the picture.
        let mode = app.buttons["param-framing.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        let fit = app.buttons["Fit inside"].firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 5), "the Mode menu did not open")
        shoot(app, "04-framing-mode-menu")
        fit.tap()
        XCTAssertTrue(mode.label.contains("Fit inside") || (mode.value as? String) == "Fit inside",
                      "mode reads \(mode.label) \(String(describing: mode.value))")
        sleep(1)
        mode.tap()
        app.buttons["Crop to fill"].firstMatch.tap()
        let zoom = app.sliders["param-framing.zoom"]
        scrollIntoView(app, zoom)
        zoom.adjust(toNormalizedSliderPosition: 0.6)
        app.descendants(matching: .any)["preview"].firstMatch.pinch(withScale: 1.3, velocity: 1)
        let pan = app.sliders["param-framing.pan"]
        scrollIntoView(app, pan)
        pan.adjust(toNormalizedSliderPosition: 0.8)
        print("HVSTEP zoom \(zoom.value ?? "") pan \(pan.value ?? "")")
        sleep(Self.hold)
        shoot(app, "05-framing-zoomed")

        // All Controls: the Display on, then one of its layers' values.
        let all = app.buttons["allControls"]
        scrollIntoView(app, all)
        all.tap()
        XCTAssertTrue(app.buttons["allControlsDone"].waitForExistence(timeout: 10), "All Controls did not open")
        sleep(1)
        shoot(app, "06-all-controls-medium")
        // The sheet to its large detent, as a person drags it.
        let bar = app.navigationBars["All Controls"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.05)))
        sleep(1)
        shoot(app, "07-all-controls-large")
        app.buttons["chip-display"].tap()
        sleep(1)
        let display = app.switches["stage-display"]
        scrollIntoView(app, display)
        // Filmed TV then a tape Look: the tape Look takes the screen away.
        XCTAssertEqual(display.value as? String, "0", "the tape Look left the Display on")
        flip(display)
        XCTAssertEqual(display.value as? String, "1", "the Display stage did not turn on")
        let group = app.buttons["group-crt-transfer"]
        scrollIntoView(app, group)
        group.tap()
        let gamma = app.sliders["param-crt-transfer.gamma"]
        scrollIntoView(app, gamma)
        let before = gamma.value as? String
        gamma.adjust(toNormalizedSliderPosition: 0.9)
        print("HVSTEP gamma \(before ?? "") -> \(gamma.value ?? "") enabled \(gamma.isEnabled) hittable \(gamma.isHittable) at \(gamma.frame)")
        shoot(app, "08-all-controls-display-on")
        XCTAssertNotEqual(before, gamma.value as? String, "the layer's value did not move")
        scrollIntoView(app, app.switches["stage-audio"])
        sleep(1)
        shoot(app, "09-all-controls-audio")
        app.buttons["allControlsDone"].tap()
        XCTAssertTrue(app.buttons["allControlsDone"].waitForNonExistence(timeout: 10), "All Controls did not close")
        sleep(1)

        // Export at the default size.
        let export = app.buttons["export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        if !app.buttons["exportStart"].waitForExistence(timeout: 5) {
            shoot(app, "debug-export-not-open")
            print("HVSTEP export button enabled \(export.isEnabled) hittable \(export.isHittable)")
            export.tap()
        }
        let start = app.buttons["exportStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the export sheet did not open")
        sleep(1)
        shoot(app, "10-export-sheet")
        start.tap()
        let status = app.staticTexts["exportStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 300), "the export never finished")
        shoot(app, "11-saved")
        XCTAssertEqual(status.label, "Saved to Photos", status.label)
        app.buttons["exportDone"].tap()
        sleep(1)

        // Landscape: the editor with its side column, Simple then All. Turning the phone shows
        // the editor, full screen only from its button.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let window = app.windows.firstMatch.frame
        guard window.width > window.height else {
            // The iPhone Duo simulator (iOS 27.1) keeps its window at 466 by 678 after the
            // rotation, so there is no landscape to test on it.
            print("HVSTEP landscape skipped: the window stayed \(window) after rotating")
            XCUIDevice.shared.orientation = .portrait
            return
        }
        XCTAssertFalse(player.exists, "turning the phone opened full screen")
        sleep(Self.hold)
        shoot(app, "13-landscape-simple")
        let modeSwitch = app.segmentedControls["controlsMode"]
        if modeSwitch.waitForExistence(timeout: 5) {
            modeSwitch.buttons["All"].tap()
            sleep(Self.hold)
            shoot(app, "14-landscape-all")
            modeSwitch.buttons["Simple"].tap()
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    /// The same screens at the Dynamic Type size XL, for the screenshots.
    @MainActor
    func testDynamicTypeXL() throws {
        let xl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"]
        var app = launch(extra: xl)
        XCTAssertTrue(app.buttons["chooseVideo"].waitForExistence(timeout: 15))
        shoot(app, "xl-01-empty")
        // A tap on the empty screen, not the button, opens the picker.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(app.buttons["Videos"].waitForExistence(timeout: 30), "a tap on the empty screen did not open the picker")
        sleep(2)
        shoot(app, "xl-01b-picker-from-empty-tap")
        app.terminate()
        app = launch(extra: xl, clip: true)
        waitForClip(app)
        sleep(Self.hold)
        shoot(app, "xl-02-simple")
        let all = app.buttons["allControls"]
        scrollIntoView(app, all)
        all.tap()
        XCTAssertTrue(app.buttons["allControlsDone"].waitForExistence(timeout: 10))
        sleep(1)
        shoot(app, "xl-03-all-controls")
        app.buttons["allControlsDone"].tap()
        app.buttons["export"].tap()
        XCTAssertTrue(app.buttons["exportStart"].waitForExistence(timeout: 10))
        sleep(1)
        shoot(app, "xl-04-export-sheet")
    }

    // MARK: Steps

    @MainActor
    private func launch(extra: [String] = [], clip: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // No `-showAllControls` here: the argument domain would outrank the app's own writes.
        // Each test ends on Simple, so the next starts there.
        app.launchArguments = extra
        // The fixture, opened as if picked (DEBUG builds only, `MobileModel.openTestClipIfAsked`).
        if clip, let path = ProcessInfo.processInfo.environment["HV_TEST_CLIP"] {
            app.launchArguments += ["-homevideoTestClip", path]
        }
        // The preview tap's dump, for reading the sound the tap hears.
        if let dump = ProcessInfo.processInfo.environment["HV_AUDIO_DUMP"] {
            app.launchEnvironment["HOMEVIDEO_AUDIO_DUMP"] = dump + (extra.isEmpty ? "-main" : "-xl")
        }
        // A Photos prompt, if the grant made before the run did not take, is answered here.
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

    /// The preview plays the clip's sound: a few seconds of play, then the preview tap's dump
    /// (`HV_AUDIO_DUMP`) is read here, and what the player handed the tap, before the chain
    /// (`in.wav`, whose hiss would sit on a silent clip), is checked for sound. `HV_EXTRA_ARGS`
    /// passes launch arguments.
    @MainActor
    func testPlaysClipAudio() throws {
        let dump = ProcessInfo.processInfo.environment["HV_AUDIO_DUMP"]
        try XCTSkipIf(dump == nil, "needs HV_AUDIO_DUMP, the folder the preview tap writes to")
        let extra = ProcessInfo.processInfo.environment["HV_EXTRA_ARGS"]?.split(separator: " ").map(String.init) ?? []
        // The folder `launch` hands the app.
        let folder = URL(fileURLWithPath: dump! + (extra.isEmpty ? "-main" : "-xl"))
        try? FileManager.default.removeItem(at: folder)
        let app = launch(extra: extra, clip: true)
        waitForClip(app)
        sleep(8)
        shoot(app, "audio-playing")
        // The file is Float32, its 44 byte header patched after every write.
        let data = try Data(contentsOf: folder.appendingPathComponent("in.wav"))
        XCTAssertGreaterThan(data.count, 44 + 4 * 48_000, "the preview tap heard under a second of play")
        let samples: [Float] = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let ms = samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))
        let dB = 10 * log10(max(ms, 1e-12))
        print("HVSTEP preview audio \(samples.count) samples, \(String(format: "%.1f", dB)) dBFS")
        XCTAssertGreaterThan(dB, -40, "the preview played no sound")
    }

    /// Turning the phone shows the landscape editor (full screen only from its button), the full
    /// screen X closes in one tap with the preview showing, and a trim handle drag trims. Also
    /// full screen opened upright and the phone then turned.
    /// Runs on to the end after a failure, so one run shows every step.
    @MainActor
    func testRotationFullScreenTrim() throws {
        continueAfterFailure = true
        let app = launch(clip: true)
        waitForClip(app)
        sleep(Self.hold)
        shoot(app, "p01-simple")

        // Trim: the in handle dragged a third of the way in.
        let scrubber = app.descendants(matching: .any)["scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let f = scrubber.frame
        print("HVSTEP scrubber \(f)")
        let grab = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.minX + 9, dy: f.midY))
        grab.press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: f.minX + f.width * 0.35, dy: f.midY)))
        sleep(1)
        let trimmed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Trimmed'")).firstMatch
        XCTAssertTrue(trimmed.waitForExistence(timeout: 3), "the in handle drag did not trim")
        print("HVSTEP trim \(trimmed.exists ? trimmed.label : "none")")
        shoot(app, "p02-trimmed")

        // Full screen upright, closed by one tap on the X.
        openAndCloseFullScreen(app, "p03")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let window = app.windows.firstMatch.frame
        guard window.width > window.height else {
            print("HVSTEP landscape skipped: the window stayed \(window) after rotating")
            XCUIDevice.shared.orientation = .portrait
            return
        }
        sleep(Self.hold)
        shoot(app, "l01-rotated")
        let player = app.descendants(matching: .any)["fullScreenPlayer"].firstMatch
        XCTAssertFalse(player.exists, "turning the phone opened full screen")
        XCTAssertTrue(app.segmentedControls["controlsMode"].waitForExistence(timeout: 5), "turning the phone did not show the landscape editor")
        if player.exists {
            app.buttons["exitFullScreen"].tap()
            sleep(2)
        }
        let modeSwitch = app.segmentedControls["controlsMode"]
        if modeSwitch.waitForExistence(timeout: 5) {
            modeSwitch.buttons["All"].tap()
            sleep(Self.hold)
            shoot(app, "l01b-landscape-all")
            modeSwitch.buttons["Simple"].tap()
            sleep(1)
        }

        // Full screen in landscape from its button, closed by one tap.
        openAndCloseFullScreen(app, "l02")

        // Full screen opened upright, then the phone turned.
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        app.buttons["fullScreen"].tap()
        XCTAssertTrue(player.waitForExistence(timeout: 5), "full screen did not open")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(Self.hold)
        shoot(app, "l03-fullscreen-turned")
        app.buttons["exitFullScreen"].tap()
        XCTAssertTrue(player.waitForNonExistence(timeout: 3), "one tap on the X did not close full screen (opened upright, then turned)")
        sleep(2)
        shoot(app, "l04-after-one-tap")
        assertPreviewShowing(app, "after one tap, turned")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    /// Opens full screen by its button, records where the picture and the bar sit, closes it by
    /// one tap on the X, and checks the editor's preview is back with a picture in it.
    @MainActor
    private func openAndCloseFullScreen(_ app: XCUIApplication, _ tag: String) {
        app.buttons["fullScreen"].tap()
        let player = app.descendants(matching: .any)["fullScreenPlayer"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 5), "full screen did not open (\(tag))")
        sleep(Self.hold)
        shoot(app, "\(tag)-fullscreen")
        let bar = app.descendants(matching: .any)["fullScreenBar"].firstMatch
        let close = app.buttons["exitFullScreen"]
        print("HVSTEP \(tag) window \(app.windows.firstMatch.frame) picture \(player.frame) bar \(bar.exists ? bar.frame : .zero) close \(close.frame)")
        close.tap()
        XCTAssertTrue(player.waitForNonExistence(timeout: 3), "one tap on the X did not close full screen (\(tag))")
        sleep(2)
        shoot(app, "\(tag)-after-one-tap")
        assertPreviewShowing(app, tag)
    }

    /// The editor's preview is on screen with a picture in it, not a black surface.
    @MainActor
    private func assertPreviewShowing(_ app: XCUIApplication, _ tag: String) {
        let preview = app.descendants(matching: .any)["preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 3) && preview.isHittable, "no editor preview (\(tag))")
        guard preview.exists, let cg = preview.screenshot().image.cgImage else { return }
        let w = 16, h = 16
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for i in stride(from: 0, to: px.count, by: 4) { sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
        let mean = Double(sum) / Double(w * h * 3) / 255
        print("HVSTEP \(tag) preview mean \(String(format: "%.3f", mean))")
        XCTAssertGreaterThan(mean, 0.05, "the editor's preview is blank (\(tag))")
    }

    /// The system picker on its own: the button opens it and the clip, tapped by its label, opens.
    @MainActor
    func testPicker() throws {
        let app = launch()
        shoot(app, "picker-01-empty")
        pickClip(app)
        shoot(app, "picker-02-opened")
    }

    /// Waits for a clip opened by the launch argument, closing All Controls if a run left it open.
    @MainActor
    private func waitForClip(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 30), "the test clip never opened")
        let done = app.buttons["allControlsDone"]
        if done.waitForExistence(timeout: 2) {
            done.tap()
            sleep(1)
        }
    }

    @MainActor
    private func pickClip(_ app: XCUIApplication, byTappingEmptyArea: Bool = false) {
        let choose = app.buttons["chooseVideo"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15), "no Choose a Video button")
        if byTappingEmptyArea {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        } else {
            choose.tap()
        }
        // The picker runs out of process and shows in the app's tree. Its first image is the
        // Photos icon on the "Private Access to Photos" banner, so the clip is found by its label.
        XCTAssertTrue(app.buttons["Videos"].waitForExistence(timeout: 30), "the picker never opened")
        sleep(2)
        shoot(app, "picker")
        // A fresh library is still making its grid for a moment.
        sleep(3)
        let clip = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'video'")).firstMatch
        for attempt in 0..<2 {
            if clip.exists {
                clip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.165, dy: 0.42)).tap()
            }
            if app.buttons["playPause"].waitForExistence(timeout: 8) || !app.buttons["Videos"].exists { break }
            print("HVSTEP pick attempt \(attempt) did not take")
            sleep(2)
        }
        if !app.buttons["playPause"].waitForExistence(timeout: 10) { shoot(app, "debug-after-pick") }
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 20), "the clip never opened")
        // The app remembers All Controls, so a run that stopped with it open starts with it open.
        let done = app.buttons["allControlsDone"]
        if done.waitForExistence(timeout: 2) {
            done.tap()
            sleep(1)
        }
    }

    /// A card off the edge of the row has no hit point, so the row is dragged by its own frame
    /// until the card sits inside the window.
    @MainActor
    private func bringIntoRow(_ app: XCUIApplication, _ e: XCUIElement, row: XCUIElement) {
        let width = app.windows.firstMatch.frame.width
        var swipes = 0
        while (e.frame.maxX > width - 8 || e.frame.minX < 8) && swipes < 20 {
            // Drag from whichever card sits mid screen, which is surely inside the carousel.
            let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'look-'"))
            let visible = cards.allElementsBoundByIndex.first { $0.frame.minX > width * 0.3 && $0.frame.maxX < width * 0.9 }
            guard let anchor = visible else { break }
            let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let dx: CGFloat = e.frame.minX > width / 2 ? -width * 0.45 : width * 0.45
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
            sleep(1)
            swipes += 1
        }
        print("HVSTEP card at \(e.frame) after \(swipes) swipes")
    }

    /// Swipes the scrolling content up until `e` is on screen and can be tapped.
    @MainActor
    private func scrollIntoView(_ app: XCUIApplication, _ e: XCUIElement) {
        var tries = 0
        while !(e.exists && e.isHittable) && tries < 12 {
            let window = app.windows.firstMatch
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            from.press(forDuration: 0.05, thenDragTo: to)
            tries += 1
        }
        XCTAssertTrue(e.exists, "\(e) never came into view")
    }

    /// Taps a switch's own knob (a tap on a Form row's label does not flip it).
    @MainActor
    private func flip(_ s: XCUIElement) {
        let knob = s.switches.firstMatch.exists ? s.switches.firstMatch : s
        knob.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        sleep(1)
    }

    /// The folder on the host the screenshots are written to (`TEST_RUNNER_HV_SHOTS` on the
    /// xcodebuild line), since a run cut short by the watchdog leaves no result bundle.
    static let shots = ProcessInfo.processInfo.environment["HV_SHOTS"]

    /// Set (`TEST_RUNNER_HV_PRIVATE=1`) when the clip is a private one: no screenshot is taken
    /// or attached, so nothing of the clip leaves the run but numbers.
    static let isPrivate = ProcessInfo.processInfo.environment["HV_PRIVATE"] == "1"

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        guard !Self.isPrivate else {
            print("HVSTEP \(name) (private clip, no screenshot)")
            return
        }
        let shot = app.screenshot()
        if let dir = Self.shots, XCUIDevice.shared.orientation.isLandscape {
            // A landscape capture from inside the test comes back as the portrait framebuffer
            // squeezed into a landscape frame. The runner takes it with `simctl io` instead:
            // it watches for `<name>.take`, writes `<name>.png`, and removes the request.
            let take = URL(fileURLWithPath: dir).appendingPathComponent("\(name).take")
            FileManager.default.createFile(atPath: take.path, contents: nil)
            for _ in 0..<40 where FileManager.default.fileExists(atPath: take.path) { usleep(250_000) }
        } else if let dir = Self.shots {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // The bitmap as captured: `pngRepresentation` and a redraw by the image's size both
            // turn a landscape shot inside its frame.
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
