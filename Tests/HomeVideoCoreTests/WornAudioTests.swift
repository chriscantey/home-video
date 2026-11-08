import XCTest
@testable import HomeVideoCore

/// Worn Linear and EP Linear, the two audio presets worse than Linear, and the Looks that take
/// them.
extension AudioTests {
    func value(_ chain: AudioChain, _ layer: String, _ parameter: String) -> ParameterValue? {
        chain.layers.first { $0.id == layer }?.value(parameter)
    }

    func testWornAndEPLinearAreLinearWithTheirStages() {
        let linear = AudioChain(preset: .linear).layers.map(\.id)
        XCTAssertEqual(AudioChain(preset: .wornLinear).layers.map(\.id), linear + ["audio-mute"])
        var ep = linear
        ep.insert("audio-azimuth", at: ep.firstIndex(of: "audio-band")! + 1)
        XCTAssertEqual(AudioChain(preset: .epLinear).layers.map(\.id), ep)
        XCTAssertEqual(AudioPreset.wornLinear.label, "Worn Linear")
        XCTAssertEqual(AudioPreset.epLinear.label, "EP Linear")
    }

    func testWornLinearValues() {
        let worn = AudioChain(preset: .wornLinear)
        XCTAssertEqual(value(worn, "audio-wow", "depth"), .float(0.4), "twice line 17's 0.2%")
        XCTAssertEqual(value(worn, "audio-hiss", "level"), .float(-36), "6 dB over line 19's -42")
        XCTAssertEqual(value(worn, "audio-bump", "gain"), .float(3), "the top of line 22's +2 to +3 dB")
        XCTAssertEqual(value(worn, "audio-band", "lowpass"), .float(10_000), "SP band kept")
        XCTAssertEqual(value(worn, "audio-mute", "rate"), .float(3))
        XCTAssertEqual(value(worn, "audio-mute", "shortest"), .float(5))
        XCTAssertEqual(value(worn, "audio-mute", "longest"), .float(30))
        // Linear itself is untouched.
        let linear = AudioChain(preset: .linear)
        XCTAssertEqual(value(linear, "audio-wow", "depth"), .float(0.2))
        XCTAssertEqual(value(linear, "audio-hiss", "level"), .float(-42))
        XCTAssertEqual(value(linear, "audio-bump", "gain"), .float(2))
    }

    func testEPLinearValues() {
        let ep = AudioChain(preset: .epLinear)
        XCTAssertEqual(value(ep, "audio-band", "speed"), .choice(TapeSpeed.ep.rawValue))
        XCTAssertEqual(value(ep, "audio-band", "lowpass"), .float(6_000), "line 11's EP sweep, before azimuth")
        XCTAssertEqual(value(ep, "audio-band", "highpass"), .float(100))
        XCTAssertEqual(value(ep, "audio-wow", "depth"), .float(0.3))
        XCTAssertEqual(value(ep, "audio-wow", "flutter"), .float(0.5))
        XCTAssertEqual(value(ep, "audio-azimuth", "gain"), .float(-3))
        XCTAssertEqual(AudioChainSpec.defaults(.epLinear), AudioChain(preset: .epLinear).spec,
                       "the spec defaults carry the preset's values")
    }

    /// The band narrows in order: at 3.5 kHz Linear is near flat and EP Linear is down, at
    /// 8 kHz EP Linear is far below Linear, and EP Linear's -3 dB point sits between 4 and
    /// 5 kHz, near the 4 kHz usually given for the EP linear track. Wow and hiss off so the tone
    /// reads cleanly.
    func testEPLinearBandIsNarrowerThanLinear() {
        func gain(_ preset: AudioPreset, _ hz: Double) -> Double {
            let chain = AudioChain(preset: preset)
            for l in chain.layers where ["audio-wow", "audio-hiss", "audio-whine", "audio-saturation", "audio-mute"]
                .contains(l.id) { l.enabled = false }
            let out = run(chain.makeProcessor(sampleRate: Self.rate, channels: 2), sine(hz, amplitude: 0.1, seconds: 0.5))
            return dB(bandAmplitude(out[0][12_000..<24_000], hz: hz, halfWidth: 40) / 0.1)
        }
        let lin35 = gain(.linear, 3_500), ep35 = gain(.epLinear, 3_500)
        let lin8 = gain(.linear, 8_000), ep8 = gain(.epLinear, 8_000)
        let ep4 = gain(.epLinear, 4_000), ep5 = gain(.epLinear, 5_000)
        XCTAssertEqual(lin35, 0, accuracy: 1.5)
        XCTAssertLessThan(ep35, -1.5, "EP Linear at 3.5 kHz: \(ep35) dB")
        XCTAssertGreaterThan(ep4, -3, "EP Linear is above -3 dB at 4 kHz: \(ep4) dB")
        XCTAssertLessThan(ep5, -3, "EP Linear is below -3 dB at 5 kHz: \(ep5) dB")
        XCTAssertLessThan(ep8, lin8 - 10, "8 kHz: Linear \(lin8) dB, EP Linear \(ep8) dB")
        print("EP band: 3.5 kHz Linear \(lin35) EP \(ep35); EP 4 kHz \(ep4), 5 kHz \(ep5); 8 kHz Linear \(lin8) EP \(ep8)")
    }

    /// The mute dropouts: on a steady signal, every mute lasts 5 to 30 ms (less the 1 ms ramps
    /// at each edge, measured below half gain), and the default rate gives a few a minute.
    func testMuteDropoutsLastFiveToThirtyMs() {
        func mutes(rate: Double, seconds: Double) -> [Double] {
            let spec = AudioChainSpec(layers: [AudioLayerSpec(kind: .mute, values: [
                "rate": .float(rate), "shortest": .float(5), "longest": .float(30)])])
            let p = AudioChainProcessor(spec: spec, sampleRate: Self.rate, channels: 1)
            var lengths: [Double] = []
            var run = 0
            let block = 4_800
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: block)
            defer { buf.deallocate() }
            for _ in 0..<Int(seconds * Self.rate) / block {
                buf.initialize(repeating: 1, count: block)
                p.process(AudioBlock(channels: [buf], frames: block))
                for i in 0..<block {
                    if buf[i] < 0.5 { run += 1 } else if run > 0 { lengths.append(Double(run) / Self.rate * 1_000); run = 0 }
                }
            }
            return lengths
        }
        let busy = mutes(rate: 30, seconds: 60)
        XCTAssertGreaterThan(busy.count, 15)
        XCTAssertLessThan(busy.count, 50)
        for ms in busy { XCTAssertTrue((3.9...29.1).contains(ms), "a mute of \(ms) ms") }
        let calm = mutes(rate: 3, seconds: 60)
        XCTAssertTrue((1...8).contains(calm.count), "\(calm.count) mutes in a minute at the default rate")
        print("Mutes: \(busy.count) at 30/min, \(String(format: "%.1f", busy.min() ?? 0)) to "
              + "\(String(format: "%.1f", busy.max() ?? 0)) ms; \(calm.count) at the default 3/min")
    }

    /// Rental (an EP tape) takes EP Linear, Attic Tape (SP, a worn deck) takes Worn Linear,
    /// and each reads back as itself from another Look.
    func testRentalAndAtticTapeTakeTheWorsePresets() throws {
        let rental = try XCTUnwrap(Looks.look(id: "rental")), attic = try XCTUnwrap(Looks.look(id: "attic-tape"))
        XCTAssertEqual(rental.selection.audio, .epLinear)
        XCTAssertEqual(attic.selection.audio, .wornLinear)
        for look in [rental, attic] {
            let vhs = VHSLayers(), audio = AudioChain()
            let p = Presets(vhs: vhs, audio: audio)
            p.setLook(try XCTUnwrap(Looks.look(id: "clean-sp")))
            p.setLook(look)
            XCTAssertEqual(audio.preset, look.selection.audio)
            XCTAssertEqual(p.look?.id, look.id)
            audio.layers.first { $0.id == "audio-wow" }?.setParameter("depth", to: .float(0.25))
            XCTAssertNil(p.look, "\(look.id): a moved audio value reads Custom")
        }
        XCTAssertEqual(try PresetSelection.parse("audio=worn-linear").audio, .wornLinear)
        XCTAssertEqual(try PresetSelection.parse("audio=ep-linear").audio, .epLinear)
    }
}
