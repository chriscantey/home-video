import Metal
import XCTest
@testable import HomeVideoCore

/// Each preset sets exactly the parameter values it owns, and a picker reads back Custom (nil)
/// when a slider moves off a preset's value.
@MainActor
final class PresetsTests: XCTestCase {
    func testDefaultsReadBackAsSPSVideoCleanWeave() {
        let p = Presets(vhs: VHSLayers())
        XCTAssertEqual(p.tape, .sp)
        XCTAssertEqual(p.link, .svideo)
        XCTAssertEqual(p.deck, .clean)
        XCTAssertEqual(p.capture, .weave)
        XCTAssertFalse(p.osd)
    }

    func testTapePresetsSetLumaCutAndChromaCut() {
        // docs/SIGNAL-CHAIN.md: luma 2.4, 1.9, 1.4 MHz; chroma 320, 300, 280 kHz. The net chroma
        // delay belongs to the deck since the Y delay line (1 px at every speed).
        let expected: [(TapePreset, Double, Double)] = [(.sp, 2.4, 320), (.lp, 1.9, 300), (.ep, 1.4, 280)]
        for (t, luma, chroma) in expected {
            let vhs = VHSLayers()
            let p = Presets(vhs: vhs)
            p.setTape(t == .sp ? .ep : .sp)
            p.setTape(t)
            XCTAssertEqual(vhs.luma.cutMHz, luma, "\(t)")
            XCTAssertEqual(vhs.colorUnder.cutKHz, chroma, "\(t)")
            XCTAssertEqual(vhs.colorUnder.delay, 1, "\(t)")
            XCTAssertEqual(vhs.luma.speed, t)
            XCTAssertEqual(vhs.colorUnder.speed, t)
            XCTAssertEqual(p.tape, t)
            // The sliders read the same objects.
            XCTAssertEqual(vhs.luma.parameters.first { $0.id == "cut" }?.value, .float(luma))
        }
    }

    func testSVideoTurnsL2OffAtBothEnds() {
        let vhs = VHSLayers()
        let p = Presets(vhs: vhs)
        p.setLink(.composite)
        p.setLink(.svideo)
        XCTAssertFalse(vhs.compositeLink.enabled)
        XCTAssertFalse(vhs.capture.composite)
        XCTAssertEqual(p.link, .svideo)
    }

    func testCompositeTurnsL2OnAtBothEndsWithTheChosenSeparator() {
        for sep in Separator.allCases {
            let vhs = VHSLayers()
            let p = Presets(vhs: vhs)
            p.setLink(.composite, separator: sep)
            XCTAssertTrue(vhs.compositeLink.enabled)
            XCTAssertTrue(vhs.capture.composite)
            XCTAssertEqual(vhs.compositeLink.separator, sep)
            XCTAssertEqual(vhs.capture.separator, sep)
            XCTAssertEqual(p.link, .composite)
            XCTAssertEqual(p.separator, sep)
        }
    }

    func testWornDeckSetsItsValues() {
        let vhs = VHSLayers()
        let p = Presets(vhs: vhs)
        p.setDeck(.worn)
        XCTAssertEqual(vhs.noise.lumaSNR, 40)
        XCTAssertEqual(vhs.noise.chromaSNR, 38)
        XCTAssertEqual(vhs.timeBase.amplitude, 1.0)
        XCTAssertEqual(vhs.timeBase.flagAmplitude, 4.0)
        XCTAssertEqual(vhs.headSwitch.maxShift, 120)
        XCTAssertEqual(vhs.headSwitch.height - vhs.headSwitch.offset, 12, "12 visible lines per field")
        XCTAssertEqual(vhs.colorUnder.delay, 2)
        XCTAssertEqual(vhs.dropouts.ratePerMinute, 25)
        XCTAssertEqual(vhs.halo.peaking, 0.2)
        XCTAssertEqual(vhs.headSwitch.noise, 0, "Worn does not bring the tracking noise")
        XCTAssertEqual(p.deck, .worn)
        XCTAssertFalse(p.trackingNoise)

        p.setTrackingNoise(true)
        XCTAssertEqual(vhs.headSwitch.noise, trackingNoiseDefault)
        XCTAssertEqual(p.deck, .worn, "tracking noise on is still Worn")
        XCTAssertTrue(p.trackingNoise)
        p.setDeck(.clean)
        XCTAssertTrue(p.trackingNoise, "the deck leaves the switch alone")
        XCTAssertEqual(p.deck, .clean)
    }

    /// The border and the tracking noise are switches of their own, off by default and
    /// owned by no Source or Deck choice.
    func testBorderAndTrackingNoiseAreTheirOwnSwitches() throws {
        let fresh = VHSLayers()
        XCTAssertEqual(fresh.frame.leftBar, 0)
        XCTAssertEqual(fresh.frame.topRows, 0)
        XCTAssertEqual(fresh.headSwitch.noise, 0)
        XCTAssertFalse(Presets(vhs: fresh).border)
        XCTAssertFalse(Presets(vhs: fresh).trackingNoise)

        for deck in DeckPreset.allCases {
            let vhs = VHSLayers()
            let p = Presets(vhs: vhs)
            p.apply(PresetSelection(deck: deck, trackingNoise: false, source: .camcorder, border: false))
            XCTAssertEqual(vhs.frame.leftBar, 0, "\(deck)")
            XCTAssertEqual(vhs.frame.topRows, 0, "\(deck)")
            XCTAssertEqual(vhs.headSwitch.noise, 0, "\(deck)")
            XCTAssertEqual(p.source, .camcorder)
            XCTAssertEqual(p.deck, deck)

            p.setBorder(true)
            XCTAssertEqual(vhs.frame.leftBar, 15)
            XCTAssertEqual(vhs.frame.topRows, 5)
            XCTAssertTrue(p.border)
            XCTAssertEqual(p.source, .camcorder, "the border is not the source's")
            p.setSource(.digital)
            XCTAssertTrue(p.border, "the source leaves the border alone")
            p.setBorder(false)
            XCTAssertFalse(p.border)
        }
        XCTAssertEqual(try PresetSelection.parse("border=on,tracking=off"), PresetSelection(trackingNoise: false, border: true))
    }

    func testCleanDeckRestoresSpecDefaults() {
        let vhs = VHSLayers()
        let p = Presets(vhs: vhs)
        p.setDeck(.worn)
        p.setDeck(.clean)
        let fresh = VHSLayers()
        XCTAssertEqual(vhs.noise.lumaSNR, fresh.noise.lumaSNR)
        XCTAssertEqual(vhs.noise.chromaSNR, fresh.noise.chromaSNR)
        XCTAssertEqual(vhs.timeBase.amplitude, fresh.timeBase.amplitude)
        XCTAssertEqual(vhs.timeBase.flagAmplitude, fresh.timeBase.flagAmplitude)
        XCTAssertEqual(vhs.headSwitch.maxShift, fresh.headSwitch.maxShift)
        XCTAssertEqual(vhs.halo.peaking, fresh.halo.peaking)
        XCTAssertEqual(vhs.headSwitch.noise, fresh.headSwitch.noise)
        XCTAssertEqual(DeckValues.clean.lumaSNR, fresh.noise.lumaSNR)
        XCTAssertEqual(p.deck, .clean)
    }

    func testAgedDeckFadesChromaAndLiftsBlack() {
        let vhs = VHSLayers()
        let p = Presets(vhs: vhs)
        p.setDeck(.aged)
        XCTAssertEqual(vhs.colorUnder.gain, 0.8)
        XCTAssertEqual(vhs.levels.blackIRE, 19.0 / 219 * 92.5, accuracy: 1e-9)
        XCTAssertEqual(vhs.noise.chromaSNR, 45)
        XCTAssertEqual(p.deck, .aged)
        p.setDeck(.clean)
        XCTAssertEqual(vhs.colorUnder.gain, 1)
        XCTAssertEqual(vhs.levels.blackIRE, 0)
        XCTAssertEqual(p.deck, .clean)
    }

    func testSourcePresetTurnsTheCameraOnWithItsValues() {
        let vhs = VHSLayers()
        let p = Presets(vhs: vhs)
        XCTAssertEqual(p.source, .digital)
        XCTAssertFalse(vhs.camera.enabled, "the camera is off by default")
        p.setSource(.camcorder)
        XCTAssertTrue(vhs.camera.enabled)
        XCTAssertEqual(vhs.frame.leftBar, 0, "no border: that is its own switch")
        XCTAssertEqual(vhs.frame.topRows, 0)
        XCTAssertEqual(vhs.levels.gain, 1.15)
        XCTAssertTrue(vhs.levels.clip)
        XCTAssertEqual(vhs.camera.cbCodes, -3)
        XCTAssertEqual(vhs.camera.crCodes, 5)
        XCTAssertEqual(vhs.camera.hueDegrees, -15)
        XCTAssertEqual(p.source, .camcorder)
        vhs.camera.setParameter("hue", to: .float(0))
        XCTAssertNil(p.source, "Source reads Custom")
        XCTAssertEqual(try PresetSelection.parse("source=camcorder,deck=aged"),
                       PresetSelection(deck: .aged, source: .camcorder))
        p.setSource(.digital)
        XCTAssertFalse(vhs.camera.enabled)
        XCTAssertEqual(p.source, .digital)
    }

    func testCapturePresetsSetDeinterlaceAndTemporalFields() {
        let vhs = VHSLayers()
        let p = Presets(vhs: vhs)
        p.setCapture(.bob)
        XCTAssertEqual(vhs.capture.deinterlace, .bob)
        XCTAssertEqual(p.capture, .bob)
        p.setCapture(.weave, temporalFields: true)
        XCTAssertEqual(vhs.capture.deinterlace, .weave)
        XCTAssertTrue(vhs.capture.temporalFields)
        XCTAssertTrue(p.temporalFields)
    }

    func testMovingASliderOffAPresetShowsCustom() {
        let vhs = VHSLayers()
        let p = Presets(vhs: vhs)
        p.setTape(.lp)
        p.setDeck(.worn)
        p.setLink(.composite, separator: .comb2)
        XCTAssertEqual(p.tape, .lp)
        // The same call the sidebar's slider makes.
        vhs.luma.setParameter("cut", to: .float(2.0))
        XCTAssertNil(p.tape, "Tape reads Custom")
        vhs.noise.setParameter("luma", to: .float(50))
        XCTAssertNil(p.deck, "Deck reads Custom")
        vhs.capture.setParameter("separator", to: .choice(Separator.notch.rawValue))
        XCTAssertNil(p.link, "Link reads Custom when the two ends disagree")
        // Picking a preset again leaves Custom.
        p.setTape(.lp)
        XCTAssertEqual(p.tape, .lp)
    }

    func testSelectionParsesAndApplies() throws {
        let s = try PresetSelection.parse("tape=EP,link=composite,deck=worn,capture=bob")
        XCTAssertEqual(s, PresetSelection(tape: .ep, link: .composite, deck: .worn, capture: .bob))
        XCTAssertEqual(try PresetSelection.parse("link=S-Video,separator=comb1,tracking=off,temporal=on,osd=on"),
                       PresetSelection(link: .svideo, separator: .comb1, trackingNoise: false, temporalFields: true, osd: true))
        XCTAssertThrowsError(try PresetSelection.parse("tape=vhs"))
        XCTAssertThrowsError(try PresetSelection.parse("speed=sp"))
        XCTAssertThrowsError(try PresetSelection.parse(""))

        let vhs = VHSLayers()
        Presets(vhs: vhs).apply(s)
        let p = Presets(vhs: vhs)
        XCTAssertEqual(p.tape, .ep)
        XCTAssertEqual(p.link, .composite)
        XCTAssertEqual(p.deck, .worn)
        XCTAssertEqual(p.capture, .bob)
    }

    func testRenderArgumentsTakeAPresetBeforeSettings() throws {
        let a = try RenderArguments.parse(["in.mov", "out.mov", "--preset", "tape=EP,link=composite,deck=worn,capture=bob",
                                           "--set", "luma-bandwidth.cut=3"])
        XCTAssertEqual(a.preset, PresetSelection(tape: .ep, link: .composite, deck: .worn, capture: .bob))
        XCTAssertThrowsError(try RenderArguments.parse(["in.mov", "out.mov", "--preset", "tape=xp"])) {
            XCTAssertEqual($0 as? RenderArguments.ParseError, .badPreset("tape=xp"))
        }
        let chain = SignalChain.standard()
        try a.apply(to: chain)
        let vhs = try XCTUnwrap(chain.vhs)
        XCTAssertEqual(vhs.colorUnder.cutKHz, 280, "EP chroma cut from the preset")
        XCTAssertEqual(vhs.luma.cutMHz, 3, "--set wins over the preset")
        XCTAssertTrue(vhs.compositeLink.enabled)
        XCTAssertEqual(vhs.capture.deinterlace, .bob)
        XCTAssertEqual(vhs.headSwitch.maxShift, 120)
    }

    // MARK: VCR on-screen display

    func testOSDTextFollowsTransportAndTapeSpeed() {
        let vhs = VHSLayers()
        XCTAssertEqual(vhs.osd.text, "PLAY \u{25B6}  SP")
        Presets(vhs: vhs).setTape(.ep)
        vhs.osd.paused = true
        XCTAssertEqual(vhs.osd.text, "PAUSE \u{275A}\u{275A}  EP")
    }

    func testOSDBitmapHasWhiteTextAndADarkEdge() {
        let (px, w, h) = OSDLayer.makeBitmap(text: "PLAY \u{25B6}  SP")
        XCTAssertGreaterThan(w, 40)
        XCTAssertGreaterThan(h, 10)
        var white = 0, dark = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] == 255 {
            if px[i] == 255 { white += 1 } else if px[i] == 0 { dark += 1 }
        }
        XCTAssertGreaterThan(white, 50)
        XCTAssertGreaterThan(dark, 50)
    }

    /// The OSD goes through the chain like picture content: white letters at the top left of
    /// the raster after L9, the rest of the picture untouched.
    func testOSDDrawsIntoTheRasterBeforeCapture() throws {
        let g = try GPUHarness()
        let (chain, vhs) = g.vhsChain()
        vhs.osd.enabled = true
        let src = try g.source { _, _ in (128, 128, 128) }
        let r = try g.run(chain, src)
        let o = OSDLayer.origin
        var maxY: Float = 0, minY: Float = 1
        for y in Int(o.y)..<Int(o.y) + 30 {
            for x in Int(o.x)..<Int(o.x) + 120 {
                let v = r.rgb(x, y).x
                maxY = max(maxY, v)
                minY = min(minY, v)
            }
        }
        XCTAssertGreaterThan(maxY, 0.95, "white letters")
        XCTAssertLessThan(minY, 0.1, "dark edge")
        XCTAssertEqual(r.rgb(600, 400).x, 128.0 / 255, accuracy: 0.01, "picture outside the OSD")
    }

    // MARK: Camcorder audio and Audio wear

    func testCamcorderAudioIsSecondInTheMenuAndHiFiWithTheMicOn() throws {
        // Linear NR sits between Camcorder and Linear.
        XCTAssertEqual(AudioPreset.allCases.map(\.label),
                       ["Hi-Fi", "Camcorder", "Linear NR", "Linear", "Worn Linear", "EP Linear", "Off"])
        XCTAssertEqual(AudioPreset.camcorder.rawValue, "camcorder")
        let cam = AudioChain(preset: .camcorder), hifi = AudioChain(preset: .hifi)
        XCTAssertEqual(cam.layers.map(\.id), hifi.layers.map(\.id))
        XCTAssertTrue(cam.layers.first { $0.id == "audio-camcorder" }!.enabled)
        XCTAssertFalse(hifi.layers.first { $0.id == "audio-camcorder" }!.enabled)
        XCTAssertEqual(cam.spec.layers.map(\.kind), [.camcorderMic] + hifi.spec.layers.map(\.kind))
        XCTAssertEqual(AudioChainSpec.defaults(.camcorder), cam.spec)

        XCTAssertEqual(try PresetSelection.parse("audio=camcorder"), PresetSelection(audio: .camcorder))
        let a = try RenderArguments.parse(["in.mov", "out.mov", "--preset", "audio=camcorder", "--audio-wear", "40",
                                           "--set", "audio-camcorder.whine=2000"])
        let chain = SignalChain.standard()
        try a.apply(to: chain)
        XCTAssertEqual(chain.audio.preset, .camcorder)
        XCTAssertEqual(chain.audio.wear, 40)
        XCTAssertEqual(chain.audio.layers.first!.value("whine"), .float(2_000))
        XCTAssertThrowsError(try RenderArguments.parse(["in.mov", "out.mov", "--audio-wear", "120"])) {
            XCTAssertEqual($0 as? RenderArguments.ParseError, .badWear("120"))
        }
        for help in [RenderArguments.usage, PresetSelection.ParseError(text: "x").description] {
            XCTAssertTrue(help.contains("audio=hifi|camcorder|linear"), help)
        }
    }

    /// A chain on the Camcorder preset with the wear moved and one mic value nudged after it.
    func wornCamcorder() -> SignalChain {
        let chain = SignalChain.standard()
        chain.audio.preset = .camcorder
        chain.audio.setWear(65)
        chain.audio.layers.first!.setParameter("lift", to: .float(9))
        return chain
    }

    func audioState(_ chain: SignalChain) -> [String] {
        ["\(chain.audio.preset.rawValue) wear \(chain.audio.wear)"]
            + chain.audio.allLayers.map { "\($0.id) \($0.enabled) \($0.parameters.map { "\($0.id)=\($0.value)" })" }
    }

    func testCamcorderAndWearRoundTripThroughPresetSidecarAndClipboard() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-cam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = wornCamcorder()
        let want = audioState(source)
        XCTAssertTrue(want[0].hasPrefix("camcorder wear 65"))

        // A saved preset.
        let store = UserPresets(folder: folder)
        let saved = try store.save(name: "Worn Cam", chain: source)
        let fromPreset = SignalChain.standard()
        try store.load(saved.url, into: fromPreset)
        XCTAssertEqual(audioState(fromPreset), want)
        XCTAssertEqual(Presets(vhs: fromPreset.vhs!, audio: fromPreset.audio).look?.id, "user:Worn Cam")

        // A sidecar.
        let url = folder.appendingPathComponent("clip.MOV.homevideo.json")
        try Sidecar.write(chain: source, name: "clip.MOV", lookID: nil, to: url)
        let fromSidecar = SignalChain.standard()
        _ = try Sidecar.read(url, into: fromSidecar)
        XCTAssertEqual(audioState(fromSidecar), want)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["audio"] as? String, "camcorder")
        XCTAssertEqual(root["audioWear"] as? Double, 65)

        // The clipboard, onto a chain that had its own wear.
        let fromClipboard = SignalChain.standard()
        fromClipboard.audio.setWear(10)
        try SettingsClipboard.apply(SettingsClipboard.encode(source), to: fromClipboard)
        XCTAssertEqual(audioState(fromClipboard), want)

        // A file at wear 0 writes no wear key, the same as a file saved before the key existed.
        let plain = folder.appendingPathComponent("plain.homevideo.json")
        try Sidecar.write(chain: SignalChain.standard(), name: "plain", lookID: "clean-sp", to: plain)
        XCTAssertFalse(try String(contentsOf: plain, encoding: .utf8).contains("audioWear"))
        let back = SignalChain.standard()
        back.audio.setWear(30)
        try SettingsClipboard.apply(SettingsClipboard.encode(SignalChain.standard()), to: back)
        XCTAssertEqual(back.audio.wear, 0)
    }

    func testResetPutsTheWearBack() {
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        presets.setLook(Looks.look(id: "camcorder")!)
        chain.audio.setWear(70)
        XCTAssertNil(presets.look, "worn audio is off the Look")
        XCTAssertTrue(LookReset.drifted(presets, from: Looks.look(id: "camcorder")!))
        LookReset.reset(presets, to: Looks.look(id: "camcorder")!)
        XCTAssertEqual(chain.audio.wear, 0)
        XCTAssertEqual(presets.look?.id, "camcorder")
    }
}
