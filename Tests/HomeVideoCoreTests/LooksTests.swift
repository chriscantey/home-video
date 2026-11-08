import Metal
import XCTest
@testable import HomeVideoCore

/// Each Look sets the chain and reads itself back, any value it owns, moved, reads Custom, and
/// every Look runs clean on bars.
@MainActor
final class LooksTests: XCTestCase {
    func testLooksHaveUniqueIdsAndOneLineBlurbs() {
        XCTAssertGreaterThanOrEqual(Looks.all.count, 8)
        XCTAssertEqual(Set(Looks.all.map(\.id)).count, Looks.all.count)
        for look in Looks.all {
            XCTAssertFalse(look.blurb.contains("\n"), look.id)
            XCTAssertLessThanOrEqual(look.blurb.count, 110, look.id)
        }
    }

    /// The default picture is Fresh SP (id `clean-sp`).
    func testDefaultChainReadsBackAsFreshSP() {
        XCTAssertEqual(Looks.look(id: "clean-sp")?.name, "Fresh SP")
        XCTAssertEqual(Presets(vhs: VHSLayers(), audio: AudioChain()).look?.id, "clean-sp")
        XCTAssertEqual(Presets(vhs: VHSLayers()).look?.id, "clean-sp")
        XCTAssertEqual(SignalChain.standard().vhs.map { Presets(vhs: $0).look?.id }, "clean-sp")
    }

    /// The app opens on Fresh SP, sound included, with only Tape and Audio lit. The sound is
    /// Linear NR, the linear track with its noise reduction. A chain left on Hi-Fi or plain
    /// Linear is Custom.
    func testLaunchIsFreshSPWithOnlyTapeAndAudioOnTheLinearTrack() throws {
        let chain = SignalChain.standard()
        let p = Presets(vhs: try XCTUnwrap(chain.vhs), audio: chain.audio)
        XCTAssertEqual(p.look?.id, "clean-sp", "the launch chain reads Fresh SP with its sound")
        XCTAssertEqual(chain.audio.preset, .linearNR)
        XCTAssertEqual(chain.audio.summary, "Clean mic, Linear NR track")
        let stages = StageSwitches(chain: chain)
        XCTAssertEqual(ChainStage.allCases.filter { stages.isOn($0) }, [.tape, .audio])
        chain.audio.preset = .hifi
        XCTAssertNil(p.look, "the Hi-Fi track reads Custom")
        chain.audio.preset = .linear
        XCTAssertNil(p.look, "plain Linear reads Custom")
        p.setLook(try XCTUnwrap(Looks.look(id: "clean-sp")))
        XCTAssertEqual(chain.audio.preset, .linearNR, "choosing Fresh SP brings Linear NR back")
    }

    func testEveryLookRoundTripsAndANudgeReadsCustom() throws {
        for look in Looks.all {
            let vhs = VHSLayers(), audio = AudioChain()
            let p = Presets(vhs: vhs, audio: audio)
            // Start somewhere else, with a slider moved, so the Look has to reset it.
            p.setLook(Looks.all.first { $0.id != look.id }!)
            vhs.timeBase.setParameter("amplitude", to: .float(3))
            p.setLook(look)
            XCTAssertEqual(p.look?.id, look.id, "\(look.id) reads back")
            XCTAssertEqual(audio.preset, look.selection.audio ?? .hifi, look.id)

            // Every picker the selection names reads back as named.
            let s = look.selection
            // A Look that sets its own luma cut (the clean Looks) reads the Tape picker Custom.
            if let t = s.tape, !look.overrides.contains(where: { $0.layer == "luma-bandwidth" && $0.parameter == "cut" }) {
                XCTAssertEqual(p.tape, t, look.id)
            }
            // A Look that sets the composite link itself (Off the TV) reads the Link picker Custom.
            if let l = s.link, !look.overrides.contains(where: { $0.layer == "composite-link" }) {
                XCTAssertEqual(p.link, l, look.id)
            }
            if let src = s.source, !look.overrides.contains(where: { $0.layer == "camera" }) {
                XCTAssertEqual(p.source, src, look.id)
            }
            if let b = s.border { XCTAssertEqual(p.border, b, look.id) }
            if let n = s.trackingNoise { XCTAssertEqual(p.trackingNoise, n, look.id) }
            for o in look.overrides {
                // `saved`, not `all`: the film Looks set the Film, the filmed Looks the Display
                // and the camera.
                let layer = vhs.saved.first { $0.id == o.layer }
                if o.parameter == "enabled", case .bool(let b) = o.value {
                    // A worn Look's audio Damage layers and Shoebox's camcorder mic live on the
                    // audio chain.
                    let enabled = layer?.enabled ?? audio.allLayers.first { $0.id == o.layer }?.enabled
                    XCTAssertEqual(enabled, b, "\(look.id) \(o.layer)")
                } else if let layer {
                    let v = layer.parameters.first { $0.id == o.parameter }?.value
                    XCTAssertTrue(v.map { Looks.same($0, o.value) } ?? false, "\(look.id) \(o.layer).\(o.parameter)")
                }
            }

            // A value the Look owns, moved: its first override, else the luma cut.
            let nudge = look.overrides.first { o in
                if case .float = o.value { return vhs.all.contains { $0.id == o.layer } }
                return false
            }
            if let o = nudge, case .float(let v) = o.value {
                // The generation count is whole, so it moves by one, up from 2, the range's floor.
                let step = o.parameter == "generation" ? (v > 2 ? -1 : 1) : 0.05
                vhs.all.first { $0.id == o.layer }!.setParameter(o.parameter, to: .float(v + step))
            } else {
                vhs.luma.setParameter("cut", to: .float(vhs.luma.cutMHz + 0.1))
            }
            XCTAssertNil(p.look, "\(look.id) reads Custom after a nudge")
            p.setLook(look)
            XCTAssertEqual(p.look?.id, look.id)

            // A switch it owns, flipped.
            p.setBorder(!p.border)
            XCTAssertNil(p.look, "\(look.id) reads Custom after the border flips")
            p.setLook(look)

            // An audio value, moved.
            if let a = audio.layers.first, let f = a.parameters.first(where: { $0.value.doubleValue != nil }) {
                a.setParameter(f.id, to: .float(f.value.doubleValue! == f.range.lowerBound ? f.range.upperBound : f.range.lowerBound))
                XCTAssertNil(p.look, "\(look.id) reads Custom after an audio slider")
            }
        }
    }

    /// The three cleaner Looks sit ahead of Fresh SP in `Looks.all`, and Fresh SP is the
    /// default.
    func testCleanerLooksAheadOfFreshSP() {
        XCTAssertEqual(Looks.all.count, 29)
        XCTAssertEqual(Looks.all.prefix(4).map(\.id), ["s-vhs", "good-deck", "off-the-tv", "clean-sp"])
        XCTAssertTrue(Looks.look(id: "clean-sp")!.blurb.contains("The default"))
        let vhs = VHSLayers()
        Presets(vhs: vhs).setLook(Looks.look(id: "s-vhs")!)
        XCTAssertEqual(vhs.luma.cutMHz, 5.0, "S-VHS reaches 5.0 MHz inside the raised range")
        XCTAssertEqual(vhs.colorUnder.cutKHz, TapeSpeed.sp.chromaCutKHz, "S-VHS chroma as VHS")
        XCTAssertEqual(vhs.timeBase.amplitude, 0, "line TBC")
        XCTAssertEqual(vhs.noise.lumaSNR, 48)
        let tv = Presets(vhs: VHSLayers())
        tv.setLook(Looks.look(id: "off-the-tv")!)
        XCTAssertTrue(tv.vhs.compositeLink.enabled, "the tuner's composite into the deck")
        XCTAssertEqual(tv.vhs.compositeLink.separator, .comb2)
        XCTAssertFalse(tv.vhs.capture.composite, "S-Video out to the card")
        XCTAssertNil(tv.link, "the Link picker reads Custom")
        XCTAssertEqual(tv.vhs.luma.moire, 0)
    }

    func testNoTwoLooksBuildTheSameChain() {
        for a in Looks.all {
            let p = Presets(vhs: VHSLayers(), audio: AudioChain())
            p.setLook(a)
            for b in Looks.all where b.id != a.id {
                XCTAssertFalse(p.matches(b), "\(a.id) also matches \(b.id)")
            }
        }
    }

    /// Inside the Looks, only Tape Transfer draws the border, and the clean Looks carry no
    /// tracking noise.
    func testBorderAndStaticOnlyWhereALookAsks() {
        for look in Looks.all {
            let vhs = VHSLayers()
            Presets(vhs: vhs).setLook(look)
            XCTAssertEqual(vhs.frame.leftBar, look.id == "transfer-1986" ? 15 : 0, look.id)
            XCTAssertEqual(vhs.frame.topRows, look.id == "transfer-1986" ? 5 : 0, look.id)
        }
        let vhs = VHSLayers()
        Presets(vhs: vhs).setLook(Looks.look(id: "home-movie-1986")!)
        XCTAssertEqual(vhs.headSwitch.noise, 0, "the 1986 trappings without the static")
        XCTAssertEqual(vhs.colorUnder.gain, 0.6)
        XCTAssertTrue(vhs.camera.enabled)
        Presets(vhs: vhs).setLook(Looks.look(id: "dub-of-a-dub")!)
        XCTAssertTrue(vhs.generation.enabled)
        XCTAssertEqual(vhs.generation.generation, 3)
    }

    /// Every Look runs on color bars and gives finite values near range, two frames apart.
    func testEveryLookRunsCleanOnBars() throws {
        let g = try GPUHarness()
        let bars: [(UInt8, UInt8, UInt8)] = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0),
                                              (191, 0, 191), (191, 0, 0), (0, 0, 191)]
        let src = try g.source { x, y in y < 360 ? bars[min(6, x * 7 / 720)] : (x < 360 ? (16, 16, 16) : (235, 235, 235)) }
        for look in Looks.all {
            let vhs = VHSLayers()
            Presets(vhs: vhs).setLook(look)
            let chain = SignalChain(framing: FramingLayer(mode: .fullRaster), effects: vhs.all)
            for frame: UInt64 in [0, 1, 59] {
                let out = try g.run(chain, src, frame: frame)
                XCTAssertTrue(out.data.allSatisfy { $0.isFinite && $0 >= -0.75 && $0 <= 1.75 },
                              "\(look.id) frame \(frame): range \(out.data.min()!) to \(out.data.max()!)")
            }
        }
    }

    /// homevideo-render: --look first, then --preset, then --set; --list-looks needs no files.
    func testRenderArgumentsTakeALookBeforePresetAndSet() throws {
        let a = try RenderArguments.parse(["in.mov", "out.mov", "--set", "luma-bandwidth.cut=3", "--preset", "deck=clean",
                                           "--look", "rental"])
        XCTAssertEqual(a.look?.id, "rental")
        let chain = SignalChain.standard()
        try a.apply(to: chain)
        let p = Presets(vhs: try XCTUnwrap(chain.vhs), audio: chain.audio)
        XCTAssertEqual(chain.vhs?.colorUnder.cutKHz, 280, "the Look's EP chroma cut")
        XCTAssertEqual(p.deck, .clean, "--preset after the Look")
        XCTAssertNil(p.look, "Rental with a clean deck is Custom")
        XCTAssertEqual(chain.vhs?.noise.lumaSNR, 45, "--preset after the Look")
        XCTAssertEqual(chain.vhs?.luma.cutMHz, 3, "--set last")
        XCTAssertEqual(chain.audio.preset, .epLinear, "Rental's EP tape plays EP Linear")

        let list = try RenderArguments.parse(["--list-looks"])
        XCTAssertTrue(list.listLooks)
        XCTAssertThrowsError(try RenderArguments.parse(["in.mov", "out.mov", "--look", "vhs"])) {
            XCTAssertEqual($0 as? RenderArguments.ParseError, .badLook("vhs"))
        }
    }

    // MARK: Wear

    /// Every Look, in `Looks.all` order (the menu has its own, `Looks.menuOrder`).
    func testEveryLookInListOrder() {
        XCTAssertEqual(Looks.all.map(\.id), [
            "s-vhs", "good-deck", "off-the-tv", "clean-sp", "camcorder", "home-movie-1986", "transfer-1986",
            "rental", "dub-of-a-dub", "attic-tape", "off-air",
            "wedding-video", "six-hour-tape", "hot-car", "sticky-shed",
            "super8-kodachrome", "sixteen-ektachrome-faded", "home-movie-transfer",
            // The two that film the screen.
            "filmed-tv", "phone-dub",
            // Five film, two Telecine, two Display.
            "regular8-summer", "super8-living-room", "super8-estate-sale", "sixteen-news", "thirtyfive-vision",
            "mall-transfer", "pro-scan", "tripod-tv", "up-close",
        ])
    }

    /// Exactly the worn Looks carry Damage, each the layers named here, and every other Look
    /// has every Damage layer, picture and sound, off. Choosing a Look sets them.
    func testExactlyTheWornLooksCarryDamage() {
        let expected: [String: Set<String>] = [
            "rental": ["damage-tear", "damage-snow"],
            "dub-of-a-dub": ["damage-snow", "audio-damage-hifi"],
            "attic-tape": ["damage-crease", "damage-clog", "audio-damage-glide"],
            "hot-car": ["damage-crease", "damage-tear", "audio-damage-glide"],
            "sticky-shed": ["damage-clog", "damage-snow", "audio-damage-flutter", "audio-damage-clog"],
        ]
        XCTAssertEqual(Looks.worn, Set(expected.keys))
        let chain = SignalChain.standard()
        let vhs = chain.vhs!
        let p = Presets(vhs: vhs, audio: chain.audio)
        for look in Looks.all {
            // From a worn Look to this one, so a clean Look has to switch the wear off.
            p.setLook(Looks.look(id: "sticky-shed")!)
            p.setLook(look)
            let on = Set(vhs.damage.all.filter(\.enabled).map(\.id) + chain.audio.damage.filter(\.enabled).map(\.id))
            XCTAssertEqual(on, expected[look.id] ?? [], look.id)
            XCTAssertEqual(p.look?.id, look.id, "\(look.id) reads back with its wear")
        }
        // A Damage slider moved on a worn Look keeps the Look's name: the sliders are for tweaking.
        p.setLook(Looks.look(id: "rental")!)
        vhs.damage.tear.setParameter("strength", to: .float(0.9))
        vhs.damage.snow.enabled = false
        XCTAssertEqual(p.look?.id, "rental")
    }

    /// Every Damage value a Look sets sits inside its layer's range, and every Strength and
    /// Rate sits off the ends, so the sliders have room both ways.
    func testEveryLooksDamageValuesSitInsideTheirRanges() {
        let fresh = SignalChain.standard()
        var params: [String: [LayerParameter]] = [:]
        for l in fresh.vhs!.damage.all { params[l.id] = l.parameters }
        for l in fresh.audio.damage { params[l.id] = l.parameters }
        var checked = 0
        for look in Looks.all {
            for o in look.overrides where params[o.layer] != nil && o.parameter != "enabled" {
                let p = params[o.layer]!.first { $0.id == o.parameter }
                XCTAssertNotNil(p, "\(look.id) \(o.layer).\(o.parameter) is a real parameter")
                guard let p, case .float(let v) = o.value else { continue }
                XCTAssertTrue(p.range.contains(v), "\(look.id) \(o.layer).\(o.parameter) \(v) in \(p.range)")
                if o.parameter == "strength" {
                    XCTAssertTrue((0.25...0.75).contains(v), "\(look.id) \(o.layer) Strength \(v) sits mid range")
                }
                if o.parameter == "rate" {
                    XCTAssertTrue(v > p.range.lowerBound && v < p.range.upperBound / 2,
                                  "\(look.id) \(o.layer) Rate \(v) off the ends of \(p.range)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 30)
        // And the chain a worn Look builds holds those values (no clamping moved them).
        let chain = SignalChain.standard()
        for id in Looks.worn {
            let look = Looks.look(id: id)!
            Presets(vhs: chain.vhs!, audio: chain.audio).setLook(look)
            for o in look.overrides where params[o.layer] != nil {
                let layer: [LayerParameter]? = chain.vhs!.damage.all.first { $0.id == o.layer }?.parameters
                    ?? chain.audio.damage.first { $0.id == o.layer }?.parameters
                if o.parameter == "enabled" { continue }
                let v = layer?.first { $0.id == o.parameter }?.value
                XCTAssertTrue(v.map { Looks.same($0, o.value) } ?? false, "\(id) \(o.layer).\(o.parameter)")
            }
        }
    }

    /// Two renders of a worn Look are bit identical, picture at an event frame of each of its
    /// layers and sound over 12 s: the Look's seeds fix the takes.
    func testAWornLookRendersTheSameBytesTwice() throws {
        let g = try GPUHarness()
        let src = try g.source { x, y in (UInt8((x * 255) / 719), UInt8((y * 255) / 479), 128) }
        for id in ["rental", "hot-car"] {
            let vhs = VHSLayers(), audio = AudioChain()
            Presets(vhs: vhs, audio: audio).setLook(Looks.look(id: id)!)
            let chain = DamageTests.chainLike(vhs)
            let frames = Set(DamageTests.eventFrames(vhs.damage)).sorted()
            let plain = VHSLayers()
            Presets(vhs: plain).setLook(Looks.look(id: id)!)
            for l in plain.damage.all { l.enabled = false }
            let without = DamageTests.chainLike(plain)
            var changedSomewhere = false
            for frame in frames {
                let a = try g.run(chain, src, frame: frame, raw: true).1
                let b = try g.run(chain, src, frame: frame, raw: true).1
                XCTAssertEqual(a, b, "\(id) frame \(frame): the same bytes twice")
                if a != (try g.run(without, src, frame: frame, raw: true).1) { changedSomewhere = true }
            }
            XCTAssertTrue(changedSomewhere, "\(id): its wear shows on an event frame")

            let x = (0..<Int(12 * 48_000.0)).map { Float(0.5 * sin(2 * .pi * 1_000 * Double($0) / 48_000)) }
            func render() -> [Float] {
                let p = audio.makeProcessor(sampleRate: 48_000, channels: 1)
                var buf = [x]
                var start = 0
                while start < x.count {
                    let n = min(512, x.count - start)
                    AudioBlock.withPlanar(&buf, range: start..<(start + n)) { p.process($0) }
                    start += n
                }
                return buf[0]
            }
            XCTAssertEqual(render(), render(), "\(id): the same samples twice")
        }
    }

    func testDubOfADubRunsTheDeckTwiceMore() throws {
        let g = try GPUHarness()
        let src = try g.source { x, _ in x < 360 ? (0, 0, 0) : (255, 255, 255) }
        var edges: [Double] = []
        for gen in [2.0, 3.0] {
            let vhs = VHSLayers()
            vhs.generation.enabled = true
            vhs.generation.setParameter("generation", to: .float(gen))
            let chain = SignalChain(framing: FramingLayer(mode: .fullRaster), effects: vhs.all)
            edges.append(crossing(try g.run(chain, src).row(200) { $0.x }, lo: 0, hi: 1, from: 300))
        }
        XCTAssertGreaterThan(edges[1], edges[0] + 0.5, "a third generation's lowpass delays the edge again")
    }

    /// The Camcorder Look takes the Camcorder audio preset, Shoebox keeps Linear with the
    /// camcorder mic on, and every other Look's audio is its preset with the mic off.
    func testCamcorderAndShoeboxCarryTheMotorAndNoOtherLookDoes() {
        let audioPreset: [String: AudioPreset] = [
            // Fresh SP plays the default sound, Linear NR.
            "s-vhs": .hifi, "good-deck": .hifi, "off-the-tv": .hifi, "clean-sp": .linearNR, "camcorder": .camcorder,
            "home-movie-1986": .linear, "transfer-1986": .linear, "rental": .epLinear, "dub-of-a-dub": .hifi,
            "attic-tape": .wornLinear, "off-air": .hifi, "wedding-video": .hifi, "six-hour-tape": .epLinear,
            "hot-car": .hifi, "sticky-shed": .hifi, "super8-kodachrome": .hifi, "sixteen-ektachrome-faded": .hifi,
            "home-movie-transfer": .linear,
            // The filmed Looks: the tape's sound, the phone's mic not modeled.
            // Filmed TV follows Fresh SP's sound, Phone Dub keeps its own. Tripod TV and Up
            // Close film the same tape.
            "filmed-tv": .linearNR, "phone-dub": .hifi,
            // The scans keep the clean Looks' Hi-Fi (the Tape is off, so no track plays),
            // Mall Transfer's SP plays Linear as 8mm to Tape's does.
            "regular8-summer": .hifi, "super8-living-room": .hifi, "super8-estate-sale": .hifi, "sixteen-news": .hifi,
            "thirtyfive-vision": .hifi, "mall-transfer": .linear, "pro-scan": .hifi, "tripod-tv": .linearNR,
            "up-close": .linearNR,
        ]
        XCTAssertEqual(Set(audioPreset.keys), Set(Looks.all.map(\.id)))
        XCTAssertEqual(Looks.motor, ["camcorder", "home-movie-1986"])
        for look in Looks.all {
            let vhs = VHSLayers(), audio = AudioChain()
            Presets(vhs: vhs, audio: audio).setLook(look)
            XCTAssertEqual(audio.preset, audioPreset[look.id], look.id)
            let mic = audio.layers.first { $0.id == "audio-camcorder" }
            XCTAssertEqual(mic?.enabled, Looks.motor.contains(look.id), look.id)
            XCTAssertEqual(audio.spec.layers.contains { $0.kind == .camcorderMic }, Looks.motor.contains(look.id), look.id)
            if !Looks.motor.contains(look.id) {
                // The spec without Damage is the preset's own.
                let steady = AudioChainSpec(layers: audio.spec.layers.filter { !$0.kind.isDamage })
                if look.overrides.allSatisfy({ !$0.layer.hasPrefix("audio-") || $0.layer.hasPrefix("audio-damage") }) {
                    XCTAssertEqual(steady, AudioChainSpec.defaults(audio.preset), look.id)
                }
            }
            XCTAssertEqual(Presets(vhs: vhs, audio: audio).look?.id, look.id, "\(look.id) reads back")
        }
        // Switching the mic off on Shoebox reads Custom.
        let vhs = VHSLayers(), audio = AudioChain()
        let p = Presets(vhs: vhs, audio: audio)
        p.setLook(Looks.look(id: "home-movie-1986")!)
        audio.layers.first { $0.id == "audio-camcorder" }!.enabled = false
        XCTAssertNil(p.look)
    }
}
