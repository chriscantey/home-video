import XCTest

/// Loading a clip and what the app leaves behind: a long pick over an open clip shows its
/// progress with the old clip already gone, then the new clip plays. The camera's stills cost
/// is read off the DEBUG probes while it runs. `HV_LONG_CLIP` names the long fixture the
/// picker should take (it must be in the simulator's library).
final class HomeVideoMobileLoadUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// A clip open, the long fixture picked from the bar: the progress shows while the file
    /// comes in, no clip is open under it, then the long clip plays.
    @MainActor
    func testLongPickOverOpenClip() throws {
        // The local fixture is in hand in well under a second, so the load is held 3 s once the
        // file is in, for the progress to be seen. The timing leaves the hold out.
        // `HV_HOLD_LOAD=0` drops the hold, for timing runs (the progress asserts then fail).
        let hold = ProcessInfo.processInfo.environment["HV_HOLD_LOAD"] ?? "3"
        let app = launch(clip: true, extra: ["-homevideoHoldLoad", hold])
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 30), "the test clip never opened")
        let clipName = app.descendants(matching: .any)["clipName"].firstMatch
        let first = clipName.label
        print("HVSTEP open before the pick: \(first)")
        sleep(2)
        app.buttons["pickClip"].firstMatch.tap()
        pickLong(app)
        let progress = app.descendants(matching: .any)["loadProgress"].firstMatch
        var sawProgress = false
        var oldOpenDuringLoad = false
        var shot = false
        let wanted = ProcessInfo.processInfo.environment["HV_LONG_CLIP"] ?? "long-1080p-150s.mp4"
        let start = Date()
        while Date().timeIntervalSince(start) < 120 {
            if progress.exists {
                sawProgress = true
                let name = clipName.label
                if name != "none" { oldOpenDuringLoad = true }
                if !shot {
                    shoot(app, "load-01-progress-over-clip")
                    shot = true
                    print("HVSTEP progress \(progress.label) \(progress.value ?? "") clip \(name)")
                    // Again once the picker has slid away.
                    usleep(1_500_000)
                    if progress.exists { shoot(app, "load-01b-progress-over-clip") }
                }
            } else if clipName.label == wanted {
                break
            }
            usleep(100_000)
        }
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 30), "the long clip never opened")
        let timing = app.descendants(matching: .any)["loadTiming"].firstMatch
        for _ in 0..<100 where timing.label.isEmpty { usleep(200_000) }
        print("HVSTEP loadTiming \(timing.label)")
        sleep(2)
        shoot(app, "load-02-long-open")
        let preview = app.descendants(matching: .any)["preview"].firstMatch
        print("HVSTEP after: clip \(clipName.label) preview \(preview.value ?? "")")
        XCTAssertEqual(clipName.label, wanted)
        XCTAssertEqual(preview.value as? String, "Playing")
        XCTAssertTrue(sawProgress, "no progress showed while the clip loaded")
        XCTAssertFalse(oldOpenDuringLoad, "the old clip was still open during the load")
    }

    /// A pick whose file is held back, as a download from iCloud would be: the card reads
    /// "Opening video…" before the limit and "Downloading clip…" past it, the ring shows the
    /// percent, and the editor's controls under it are off the whole time. Then About: no last
    /// open line, and the Mac row asks to open the site. The limit is stretched to 3 s
    /// (`-homevideoLocalLimit`), since the picker takes most of a second to slide away and a 1 s
    /// window would race the first look at the card.
    @MainActor
    func testDownloadLine() throws {
        // A Progress at 42% stands in for the picker's, so the shots show the ring part way.
        // `-homevideoRecordOpen` keeps the Mac row's page for the test instead of opening it.
        let app = launch(clip: true, extra: ["-homevideoHoldArrival", "7", "-homevideoLocalLimit", "3",
                                             "-homevideoHoldLoad", "2", "-homevideoShowProgress", "0.42",
                                             "-homevideoRecordOpen", "YES"])
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 30), "the test clip never opened")
        let look = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'look-'")).firstMatch
        let slider = app.sliders.firstMatch
        XCTAssertTrue(look.waitForExistence(timeout: 10), "no Look card")
        XCTAssertTrue(look.isEnabled, "the Look row was off before the pick")
        sleep(2)
        let tapped = Date()
        app.buttons["pickClip"].firstMatch.tap()
        pickLong(app)
        let picked = Date()
        let line = app.staticTexts["loadLine"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "no line on the card")
        let early = line.label
        let earlyAt = Date().timeIntervalSince(picked)
        print("HVSTEP early line \(early) at \(earlyAt) s after the pick (\(picked.timeIntervalSince(tapped)) s in the picker)")
        shoot(app, "download-01-opening")
        XCTAssertLessThan(earlyAt, 3, "the first look at the card came past the limit")
        XCTAssertEqual(early, "Opening video…", "before the limit the card read \(early)")
        let percent = app.staticTexts["loadPercent"].firstMatch
        XCTAssertTrue(percent.waitForExistence(timeout: 2), "no percent in the ring")
        print("HVSTEP ring \(percent.label)")
        XCTAssertEqual(percent.label, "42%")
        // The controls under the card are off while it is up.
        print("HVSTEP during load: look \(look.identifier) enabled \(look.isEnabled) hittable \(look.isHittable), slider \(slider.identifier) enabled \(slider.isEnabled) hittable \(slider.exists && slider.isHittable)")
        // XCUITest's isHittable means only on screen and uncovered, true of a disabled control
        // too, so a tap on another Look card proves the row takes no press.
        XCTAssertFalse(look.isEnabled, "a Look card was live during the load")
        let shown = app.staticTexts["currentLook"].firstMatch
        let lookBefore = shown.label
        let other = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'look-'")).element(boundBy: 1)
        other.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        usleep(500_000)
        print("HVSTEP tapped \(other.identifier) during load: Look \(lookBefore) -> \(shown.label)")
        XCTAssertEqual(shown.label, lookBefore, "a Look card took a press during the load")
        XCTAssertTrue(slider.exists, "no slider on the editor")
        XCTAssertFalse(slider.isEnabled, "a slider was live during the load")
        XCTAssertFalse(app.buttons["pickClip"].firstMatch.isEnabled, "Choose Video was live during the load")
        XCTAssertTrue(app.buttons["loadCancel"].isEnabled, "Cancel was off")
        // Past the limit, with the file still held back.
        while Date().timeIntervalSince(picked) < 4.5 { usleep(100_000) }
        let late = line.label
        print("HVSTEP late line \(late) at \(Date().timeIntervalSince(picked)) s")
        shoot(app, "download-02-downloading")
        XCTAssertEqual(late, "Downloading clip…", "past the limit the card read \(late)")
        // The file in, the clip opens and the controls are back.
        XCTAssertTrue(look.waitForExistence(timeout: 30))
        let back = Date()
        while app.descendants(matching: .any)["loadProgress"].firstMatch.exists && Date().timeIntervalSince(back) < 30 {
            usleep(200_000)
        }
        XCTAssertTrue(look.isEnabled, "the Look row stayed off after the load")
        app.buttons["more"].firstMatch.tap()
        app.buttons["about"].firstMatch.tap()
        let mac = app.buttons["aboutMac"].firstMatch
        XCTAssertTrue(mac.waitForExistence(timeout: 5), "no Mac row in About")
        sleep(1)
        shoot(app, "download-03-about")
        XCTAssertFalse(app.descendants(matching: .any)["aboutLastOpen"].firstMatch.exists, "About still has a last open line")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Last open'")).firstMatch.exists,
                       "About still reads Last open")
        mac.tap()
        let opened = app.descendants(matching: .any)["aboutOpened"].firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "the Mac row asked to open nothing")
        print("HVSTEP about opened \(opened.label)")
        XCTAssertEqual(opened.label, "https://homevideo.app")
    }

    /// About links the privacy policy and the support page (App Review Guideline 5.1.1), each
    /// to its page on homevideo.app. `-homevideoRecordOpen` keeps the page a row asks for.
    @MainActor
    func testAboutShowsPrivacyAndSupportLinks() throws {
        let app = launch(clip: false, extra: ["-homevideoRecordOpen", "YES"])
        let more = app.buttons["more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "no ••• menu")
        more.tap()
        app.buttons["about"].firstMatch.tap()
        let privacy = app.buttons["aboutPrivacy"].firstMatch
        let support = app.buttons["aboutSupport"].firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), "no Privacy Policy row in About")
        XCTAssertTrue(support.exists, "no Support row in About")
        XCTAssertTrue(app.staticTexts["Puts your video on tape and back, virtually, from the physics."].exists,
                      "About does not carry the tagline")
        XCTAssertTrue(privacy.label.contains("Privacy Policy"), "privacy row reads \(privacy.label)")
        XCTAssertTrue(support.label.contains("Support"), "support row reads \(support.label)")
        XCTAssertTrue(privacy.isHittable && support.isHittable, "a link row is off screen in the sheet")
        sleep(1)
        shoot(app, "about-01-links")
        let opened = app.descendants(matching: .any)["aboutOpened"].firstMatch
        privacy.tap()
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "the Privacy Policy row asked to open nothing")
        XCTAssertEqual(opened.label, "https://homevideo.app/privacy/")
        support.tap()
        let deadline = Date().addingTimeInterval(5)
        while opened.label != "https://homevideo.app/support/" && Date() < deadline { usleep(200_000) }
        XCTAssertEqual(opened.label, "https://homevideo.app/support/")
    }

    /// The camera live for a while, then the carousel scrolled along: the stills probe gives
    /// each refresh's cost and what the stills hold, and every card scrolled into view gets a
    /// fresh still within one refresh.
    @MainActor
    func testCameraStillsCost() throws {
        let app = launch(clip: false)
        let entry = app.buttons["camera"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "no Camera")
        entry.tap()
        XCTAssertTrue(app.buttons["cameraRecord"].waitForExistence(timeout: 10), "the live camera screen did not show")
        let readout = app.descendants(matching: .any)["cameraReadout"].firstMatch
        let probe = app.descendants(matching: .any)["stillsTiming"].firstMatch
        sleep(14)
        print("HVSTEP live readout \(readout.label)")
        print("HVSTEP live stills \(probe.label)")
        let row = app.descendants(matching: .any)["looks"].firstMatch
        for _ in 0..<8 { row.swipeLeft() }
        sleep(1)
        let scrolled = probe.label
        sleep(4)
        let after = probe.label
        print("HVSTEP scrolled stills \(scrolled)")
        print("HVSTEP after scroll stills \(after)")
        print("HVSTEP after scroll readout \(readout.label)")
        shoot(app, "stills-01-scrolled-end")
        // The cards wholly inside the window now, every one of which the last refresh drew.
        let width = app.windows.firstMatch.frame.width
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'look-'")).allElementsBoundByIndex
        let onScreen = cards.filter { $0.frame.minX >= 0 && $0.frame.maxX <= width }
            .map { String($0.identifier.dropFirst("look-".count)) }
        let drawn = after.components(separatedBy: "drawn ").last?.components(separatedBy: ",") ?? []
        print("HVSTEP cards on screen \(onScreen.joined(separator: ","))")
        XCTAssertFalse(onScreen.isEmpty, "no Look card on screen")
        XCTAssertFalse(onScreen.contains("s-vhs"), "the row did not scroll")
        for id in onScreen {
            XCTAssertTrue(drawn.contains(id), "\(id) came into view and got no still")
        }
    }

    /// The progress over the empty screen, then Cancel: back to the empty screen with the
    /// canceled line, no clip open and nothing of the pick left in tmp.
    @MainActor
    func testProgressOnEmptyThenCancel() throws {
        let app = launch(clip: false, extra: ["-homevideoHoldLoad", "6"])
        let choose = app.buttons["chooseVideo"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15), "no Choose Video")
        choose.tap()
        pickLong(app)
        let progress = app.descendants(matching: .any)["loadProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10), "no progress over the empty screen")
        shoot(app, "load-00-progress-empty")
        app.buttons["loadCancel"].tap()
        let line = app.staticTexts["Opening the video was canceled."]
        XCTAssertTrue(line.waitForExistence(timeout: 5), "no canceled line")
        XCTAssertTrue(choose.waitForExistence(timeout: 5), "not back on the empty screen")
        shoot(app, "load-03-canceled")
        // Past the hold, the file that came in is dropped, never opened.
        sleep(8)
        let clipName = app.descendants(matching: .any)["clipName"].firstMatch
        let listing = app.descendants(matching: .any)["tmpListing"].firstMatch.label
        print("HVSTEP after cancel: clip \(clipName.label) tmp [\(listing)]")
        XCTAssertEqual(clipName.label, "none")
        XCTAssertFalse(listing.contains("tmp/Picked/"), "the canceled pick's file stayed")
        XCTAssertTrue(line.exists, "the canceled line went")
    }

    /// Leftovers planted as a crash would leave them, the open clip on a Look, then the app
    /// sent away and ended: the next launch has the clip back on its Look and only its file in
    /// tmp. An export adds its file, Close Clip takes both, and a camera recording's file goes
    /// once it is in Photos.
    @MainActor
    func testSessionAndLeftovers() throws {
        var app = launch(clip: true, extra: ["-homevideoRestoreSession", "YES", "-homevideoPlantLeftovers", "YES"])
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 30), "the test clip never opened")
        let clip = app.descendants(matching: .any)["clipName"].firstMatch.label
        let planted = listing(app)
        print("HVSTEP planted [\(planted.joined(separator: " "))]")
        XCTAssertEqual(planted.filter { $0.hasSuffix("leftover.mov") }.count, 4, "the leftovers were not planted")
        let card = app.buttons["look-good-deck"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        // Past the session's 2 s check, since the iPhone Duo stays active through Home.
        sleep(3)
        print("HVSTEP picked good-deck selected \(card.isSelected) frame \(card.frame)")
        XCTAssertTrue(card.isSelected, "the Look was not picked")
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()

        app = launch(clip: false, extra: ["-homevideoRestoreSession", "YES"])
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 30), "the clip did not come back")
        XCTAssertEqual(app.descendants(matching: .any)["clipName"].firstMatch.label, clip)
        XCTAssertTrue(app.buttons["look-good-deck"].waitForExistence(timeout: 5))
        let chosen = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'look-' AND selected == true"))
            .allElementsBoundByIndex.map(\.identifier)
        print("HVSTEP restored Look \(chosen)")
        XCTAssertTrue(app.buttons["look-good-deck"].isSelected, "the Look did not come back")
        sleep(1)
        shoot(app, "session-01-restored")
        let restored = listing(app)
        print("HVSTEP restored [\(restored.joined(separator: " "))]")
        XCTAssertEqual(restored.filter { $0.hasPrefix("tmp/") }, ["tmp/Picked/\(clip)"])
        XCTAssertTrue(restored.filter { $0.contains("leftover") }.isEmpty, "a leftover stayed")

        app.buttons["export"].tap()
        XCTAssertTrue(app.buttons["exportStart"].waitForExistence(timeout: 10), "the export sheet did not open")
        app.buttons["exportStart"].tap()
        let status = app.staticTexts["exportStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 300), "the export never finished")
        XCTAssertTrue(app.buttons["exportShare"].exists, "no Share on the saved export")
        app.buttons["exportDone"].tap()
        sleep(1)
        let exported = listing(app)
        print("HVSTEP after export [\(exported.joined(separator: " "))]")
        XCTAssertEqual(exported.filter { $0.hasPrefix("tmp/Exports/") }.count, 1, "the export is not kept for Share")

        app.buttons["more"].tap()
        XCTAssertTrue(app.buttons["closeClip"].waitForExistence(timeout: 5), "no Close Clip")
        app.buttons["closeClip"].tap()
        XCTAssertTrue(app.buttons["chooseVideo"].waitForExistence(timeout: 5), "not back on the empty screen")
        sleep(1)
        let closed = listing(app)
        print("HVSTEP after Close Clip [\(closed.joined(separator: " "))]")
        XCTAssertTrue(closed.filter { $0.hasPrefix("tmp/") }.isEmpty, "tmp is not empty after Close Clip")

        app.buttons["camera"].firstMatch.tap()
        let record = app.buttons["cameraRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "the live camera screen did not show")
        sleep(2)
        record.tap()
        sleep(3)
        record.tap()
        XCTAssertTrue(app.buttons["cameraSaved"].waitForExistence(timeout: 30), "the recording was not saved")
        app.buttons["cameraClose"].tap()
        XCTAssertTrue(app.buttons["chooseVideo"].waitForExistence(timeout: 10))
        sleep(1)
        let afterCamera = listing(app)
        print("HVSTEP after the camera [\(afterCamera.joined(separator: " "))]")
        XCTAssertTrue(afterCamera.filter { $0.hasPrefix("tmp/") }.isEmpty, "the recording stayed in tmp")
    }

    // MARK: Helpers

    /// The files under tmp and the caches folder, from the DEBUG probe.
    @MainActor
    private func listing(_ app: XCUIApplication) -> [String] {
        let probe = app.descendants(matching: .any)["tmpListing"].firstMatch
        usleep(700_000)
        return probe.label.split(separator: " ").map(String.init)
    }

    /// The picker open: the long fixture, the only clip over two minutes in the library.
    @MainActor
    private func pickLong(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Videos"].waitForExistence(timeout: 30), "the picker never opened")
        sleep(4)
        let long = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'two minutes' OR label CONTAINS[c] '2 minutes'")).firstMatch
        // Newer clips (the camera tests' recordings) push it down the grid, so the runner adds
        // it again just before this suite (`simctl addmedia`), which puts it first. The
        // picker's cells are out of process and never read as hittable, so none is asked.
        if !long.exists {
            shoot(app, "debug-picker")
            print("HVSTEP picker cells: " + app.images.debugDescription.prefix(3000))
        }
        XCTAssertTrue(long.exists, "the long fixture is not in the picker")
        long.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func launch(clip: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra
        if clip, let path = ProcessInfo.processInfo.environment["HV_TEST_CLIP"] {
            app.launchArguments += ["-homevideoTestClip", path]
        }
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

    static let shots = ProcessInfo.processInfo.environment["HV_SHOTS"]

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        if let dir = Self.shots {
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
