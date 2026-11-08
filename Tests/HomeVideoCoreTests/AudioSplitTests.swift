import XCTest
@testable import HomeVideoCore

/// The audio split by where the sound happens, a mic (Clean or Camcorder, with a
/// Strength) and a tape track (Hi-Fi, Linear, Worn, EP, Off) that follows Tape. Every old preset,
/// the default, every Look, an old sidecar and an old saved preset of each kind and Shuffle are
/// held to the pre-split chain's own samples: `AudioSplitGoldens` holds what that chain rendered
/// for the same input, hashed bit for bit, and the files it wrote.
@MainActor
final class AudioSplitTests: XCTestCase {
    static let rate = 48_000.0

    /// Two seconds of stereo: tones with a little seeded noise and a silent gap from 0.8 to 1.4 s,
    /// so the camcorder AGC lifts the bed in the gap. The same input the goldens were made on.
    static func input() -> [[Float]] {
        let n = Int(2 * rate)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        var s: UInt64 = 0x1234_5678
        for i in 0..<n {
            let t = Double(i) / rate
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Double(s >> 40) / Double(1 << 24) - 0.5) * 0.05
            let gap = t > 0.8 && t < 1.4
            l[i] = gap ? 0 : Float(0.3 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 3_000 * t)) + noise
            r[i] = gap ? 0 : Float(0.25 * sin(2 * .pi * 660 * t)) - noise
        }
        return [l, r]
    }

    /// The spec run in 512 frame blocks, the way the tap and the exporter feed it.
    static func render(_ spec: AudioChainSpec) -> [[Float]] {
        let p = AudioChainProcessor(spec: spec, sampleRate: rate, channels: 2)
        var buffers = input()
        let n = buffers[0].count
        var start = 0
        while start < n {
            let count = min(512, n - start)
            AudioBlock.withPlanar(&buffers, range: start..<(start + count)) { p.process($0) }
            start += count
        }
        return buffers
    }

    /// FNV-1a 64 over every sample's bits.
    static func sampleHash(_ b: [[Float]]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for ch in b { for v in ch { h = (h ^ UInt64(v.bitPattern)) &* 0x100_0000_01b3 } }
        return String(h, radix: 16)
    }

    static func textHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    /// The audio chain's state as the Shuffle golden prints it.
    static func state(_ a: AudioChain) -> String {
        (["\(a.preset.rawValue) wear \(a.wear)"]
            + a.allLayers.map { "\($0.id) \($0.enabled) \($0.parameters.map { "\($0.id)=\($0.value)" })" })
            .joined(separator: "\n")
    }

    func hash(_ a: AudioChain) -> String { Self.sampleHash(Self.render(a.spec)) }

    func golden(_ key: String) throws -> String { try XCTUnwrap(AudioSplitGoldens.samples[key], key) }

    /// Linear NR has no pre-split golden: its own is held on each arch
    /// (`AudioSplitGoldensLinearNR.swift`).
    func linearNRGolden(_ key: String) throws -> String { try XCTUnwrap(AudioSplitGoldens.linearNR[key], key) }

    func rms(_ a: [[Float]], minus b: [[Float]]) -> Double {
        var sum = 0.0, n = 0
        for c in a.indices {
            for i in a[c].indices {
                let d = Double(a[c][i] - b[c][i])
                sum += d * d
                n += 1
            }
        }
        return (sum / Double(n)).squareRoot()
    }

    // MARK: The mapping

    static let mapping: [(AudioPreset, AudioMic, AudioTrack)] = [
        (.hifi, .clean, .hifi), (.camcorder, .camcorder, .hifi), (.linear, .clean, .linear),
        (.wornLinear, .clean, .worn), (.epLinear, .clean, .ep), (.off, .clean, .off),
    ]

    func testEveryOldPresetMapsToItsMicAndTrackAndBack() {
        // The six pre-split presets, and Linear NR (held in its own tests below).
        XCTAssertEqual(Self.mapping.count + 1, AudioPreset.allCases.count)
        for (preset, mic, track) in Self.mapping {
            XCTAssertEqual(preset.mic, mic, preset.rawValue)
            XCTAssertEqual(preset.track, track, preset.rawValue)
            XCTAssertEqual(AudioPreset(mic: mic, track: track), preset, preset.rawValue)
            let chain = AudioChain(preset: preset)
            XCTAssertEqual(chain.mic, mic, preset.rawValue)
            XCTAssertEqual(chain.track, track, preset.rawValue)
            XCTAssertEqual(chain.preset, preset, preset.rawValue)
            XCTAssertEqual(chain.micStrength, 100)
            XCTAssertTrue(chain.tapeIsOn)
        }
        XCTAssertNil(AudioPreset(mic: .camcorder, track: .linear), "the old menu had no camcorder mic on Linear")
        XCTAssertEqual(AudioChain(mic: .camcorder, track: .linear).preset, .linear,
                       "it reads Linear with the mic layer on, as the Shoebox Look always did")
    }

    // MARK: Samples against the goldens

    func testEveryOldPresetRendersTheGoldenSamples() throws {
        for (preset, mic, track) in Self.mapping {
            let want = try golden("preset.\(preset.rawValue)")
            XCTAssertEqual(hash(AudioChain(preset: preset)), want, "\(preset.rawValue) through the old name")
            XCTAssertEqual(hash(AudioChain(mic: mic, track: track)), want, "\(preset.rawValue) as \(mic) plus \(track)")
            let set = AudioChain(preset: .off)
            set.mic = mic
            set.setTrack(track)
            XCTAssertEqual(hash(set), want, "\(preset.rawValue) set through the section's controls")
        }
    }

    func testEveryOldPresetAtWearSixtyRendersTheGoldenSamples() throws {
        for (preset, mic, track) in Self.mapping {
            let a = AudioChain(mic: mic, track: track)
            a.setWear(60)
            XCTAssertEqual(hash(a), try golden("wear60.\(preset.rawValue)"), preset.rawValue)
        }
    }

    /// Every audio Damage layer on. The pre-split chain left the Hi-Fi dropout burst out on
    /// Camcorder (its check read `preset == .hifi`), so the split, which plays it on the Hi-Fi
    /// track with either mic, matches the golden there once that one layer is off.
    func testEveryOldPresetWithAllDamageRendersTheGoldenSamples() throws {
        for (preset, mic, track) in Self.mapping {
            let a = AudioChain(mic: mic, track: track)
            for l in a.damage { l.enabled = true }
            if preset == .camcorder {
                XCTAssertTrue(a.spec.layers.contains { $0.kind == .hifiDropoutBurst }, "Camcorder plays the Hi-Fi dropout burst")
                a.damage.first { $0.kind == .hifiDropoutBurst }!.enabled = false
            }
            XCTAssertEqual(hash(a), try golden("damage.\(preset.rawValue)"), preset.rawValue)
        }
    }

    /// The default sound is Linear NR, held to its own golden, and differs from the earlier
    /// Linear and Hi-Fi defaults (Hi-Fi is the "default" golden).
    func testTheDefaultIsLinearNR() throws {
        let chain = SignalChain.standard()
        XCTAssertEqual(chain.audio.mic, .clean)
        XCTAssertEqual(chain.audio.track, .linearNR)
        XCTAssertEqual(hash(chain.audio), try linearNRGolden("preset.linearnr"))
        XCTAssertNotEqual(hash(chain.audio), try golden("preset.linear"), "no longer the earlier Linear default")
        XCTAssertNotEqual(hash(chain.audio), try golden("default"), "no longer the earlier Hi-Fi default")
    }

    /// Linear NR maps to the clean mic on its track and back, and renders its own golden through
    /// each way in, at wear 60 and with every Damage layer on.
    func testLinearNRMapsAndRendersItsGolden() throws {
        XCTAssertEqual(AudioPreset.linearNR.mic, .clean)
        XCTAssertEqual(AudioPreset.linearNR.track, .linearNR)
        XCTAssertEqual(AudioPreset(mic: .clean, track: .linearNR), .linearNR)
        XCTAssertNil(AudioPreset(mic: .camcorder, track: .linearNR), "the old menu had no camcorder mic on it")
        XCTAssertEqual(AudioChain(mic: .camcorder, track: .linearNR).preset, .linearNR)
        let want = try linearNRGolden("preset.linearnr")
        XCTAssertEqual(hash(AudioChain(preset: .linearNR)), want)
        XCTAssertEqual(hash(AudioChain(mic: .clean, track: .linearNR)), want)
        let set = AudioChain(preset: .off)
        set.setTrack(.linearNR)
        XCTAssertEqual(hash(set), want, "set through the section's controls")
        let worn = AudioChain(preset: .linearNR)
        worn.setWear(60)
        XCTAssertEqual(hash(worn), try linearNRGolden("wear60.linearnr"))
        let damaged = AudioChain(preset: .linearNR)
        for l in damaged.damage { l.enabled = true }
        XCTAssertEqual(hash(damaged), try linearNRGolden("damage.linearnr"))
    }

    func testEveryLookRendersTheGoldenSamples() throws {
        for look in Looks.all {
            let chain = SignalChain.standard()
            Presets(vhs: chain.vhs!, audio: chain.audio).setLook(look)
            // The film and filmed Looks have no pre-split golden and no audio override, so each
            // is held to its preset's golden. A Look that sets the Tape off plays the clean mic
            // alone, which is the old Off sample for sample. Fresh SP plays Linear NR, so it and
            // the Display Looks that film its tape are held to Linear NR's own golden.
            let moved: Set<String> = ["clean-sp"]
            let key = AudioSplitGoldens.samples["look.\(look.id)"] != nil && !moved.contains(look.id) ? "look.\(look.id)"
                : chain.audio.tapeIsOn ? "preset.\((look.selection.audio ?? .hifi).rawValue)" : "preset.off"
            let want = look.selection.audio == .linearNR && chain.audio.tapeIsOn
                ? try linearNRGolden("preset.linearnr") : try golden(key)
            XCTAssertEqual(hash(chain.audio), want, look.id)
        }
        let shoebox = SignalChain.standard()
        Presets(vhs: shoebox.vhs!, audio: shoebox.audio).setLook(Looks.look(id: "home-movie-1986")!)
        XCTAssertEqual(shoebox.audio.mic, .camcorder, "Shoebox is the camcorder mic")
        XCTAssertEqual(shoebox.audio.track, .linear, "on the linear track")
    }

    // MARK: Strength and Tape

    func testStrengthZeroWithCamcorderIsTheCleanMic() throws {
        for track in AudioTrack.allCases {
            let a = AudioChain(mic: .camcorder, track: track)
            a.setMicStrength(0)
            XCTAssertEqual(hash(a), hash(AudioChain(mic: .clean, track: track)), track.rawValue)
            XCTAssertFalse(a.spec.layers.contains { $0.kind == .camcorderMic }, track.rawValue)
        }
    }

    func testStrengthMixesTheMicIntoTheScene() {
        let clean = Self.render(AudioChain(mic: .clean, track: .off).spec)
        let full = Self.render(AudioChain(mic: .camcorder, track: .off).spec)
        let halfChain = AudioChain(mic: .camcorder, track: .off)
        halfChain.setMicStrength(50)
        let half = Self.render(halfChain.spec)
        let whole = rms(full, minus: clean)
        XCTAssertGreaterThan(whole, 0.001, "the camcorder mic changes the sound")
        XCTAssertEqual(rms(half, minus: clean) / whole, 0.5, accuracy: 0.01, "Strength 50 is half the mic's change")
        let over = AudioChain(mic: .camcorder, track: .off)
        over.setMicStrength(150)
        XCTAssertEqual(over.micStrength, 100, "Strength clamps to 100")
        XCTAssertEqual(Self.sampleHash(Self.render(over.spec)), Self.sampleHash(full), "Strength 100 is the mic as modeled")
    }

    func testTapeOffPlaysTheMicAloneOnEveryTrack() {
        let micAlone = hash(AudioChain(mic: .camcorder, track: .off))
        let dry = Self.sampleHash(Self.input())
        for track in AudioTrack.allCases {
            for mic in AudioMic.allCases {
                let a = AudioChain(mic: mic, track: track)
                a.setWear(70)
                for l in a.damage { l.enabled = true }
                a.tapeIsOn = false
                XCTAssertEqual(hash(a), mic == .camcorder ? micAlone : dry, "\(mic) on \(track) with Tape off")
                XCTAssertEqual(a.spec.layers.map(\.kind), mic == .camcorder ? [.camcorderMic] : [], "\(track)")
                // With Tape on, a track plays on top (Off has none, so it stays the mic alone).
                a.tapeIsOn = true
                if track != .off {
                    XCTAssertNotEqual(hash(a), mic == .camcorder ? micAlone : dry, "\(mic) on \(track) with Tape on")
                }
            }
        }
    }

    func testTheCamcorderMicPlaysWithNoTrack() {
        let a = AudioChain(mic: .camcorder, track: .off)
        XCTAssertEqual(a.layers.map(\.id), ["audio-camcorder"])
        XCTAssertEqual(a.spec.layers.map(\.kind), [.camcorderMic])
        XCTAssertFalse(a.isPassthrough)
        XCTAssertTrue(AudioChain(mic: .clean, track: .off).isPassthrough, "the clean mic with no track is the source")
    }

    func testTheTrackKeepsTheMicAndThePresetResetsIt() {
        let a = AudioChain(preset: .camcorder)
        a.micLayer.setParameter("level", to: .float(-38))
        a.setMicStrength(40)
        a.setTrack(.worn)
        XCTAssertEqual(a.mic, .camcorder)
        XCTAssertEqual(a.micLayer.value("level"), .float(-38))
        XCTAssertEqual(a.micStrength, 40)
        XCTAssertEqual(a.layers.first?.id, "audio-camcorder")
        XCTAssertEqual(a.layers.map(\.id), AudioChain(preset: .wornLinear).layers.map(\.id))
        a.preset = .hifi
        XCTAssertEqual(a.mic, .clean, "the old menu's Hi-Fi is the clean mic")
        XCTAssertEqual(a.micLayer.value("level"), .float(CamcorderMic.defaultLevel))
        XCTAssertEqual(a.micStrength, 100)
    }

    func testSummaryReadsTheSplit() {
        // The default chain plays Linear NR.
        XCTAssertEqual(AudioChain().summary, "Clean mic, Linear NR track")
        XCTAssertEqual(AudioChain(preset: .linear).summary, "Clean mic, Linear track")
        XCTAssertEqual(AudioChain(preset: .hifi).summary, "Clean mic, Hi-Fi track")
        XCTAssertEqual(AudioChain(preset: .camcorder).summary, "Camcorder mic, Hi-Fi track")
        let a = AudioChain(mic: .camcorder, track: .off)
        XCTAssertEqual(a.summary, "Camcorder mic, no track")
        a.setMicStrength(40)
        a.tapeIsOn = false
        XCTAssertEqual(a.summary, "Camcorder mic at 40, Tape off")
    }

    // MARK: Old files

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A sidecar written at the earlier default (Fresh SP on the plain linear track) names its
    /// track, so it reads back as Linear, the golden's samples, not as the Linear NR default.
    /// The sidecar writer has not changed since that default, so this is the file it wrote.
    func testAnEarlierDefaultSidecarStillReadsLinear() throws {
        let old = SignalChain.standard()
        old.audio.preset = .linear
        let url = try scratch().appendingPathComponent("clip.mov.homevideo.json")
        try Sidecar.write(chain: old, name: "clip.mov", lookID: "clean-sp", to: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["audio"] as? String, "linear", "the file names its track")
        let back = SignalChain.standard()
        XCTAssertEqual(back.audio.track, .linearNR, "a new chain starts on the new default")
        _ = try Sidecar.read(url, into: back)
        XCTAssertEqual(back.audio.track, .linear)
        XCTAssertEqual(hash(back.audio), try golden("preset.linear"))
    }

    /// What each golden file should load as: the old preset's pair, or the tuned ones'.
    static let fileKinds: [String: (AudioMic, AudioTrack)] = [
        "hifi": (.clean, .hifi), "camcorder": (.camcorder, .hifi), "linear": (.clean, .linear),
        "wornlinear": (.clean, .worn), "eplinear": (.clean, .ep), "off": (.clean, .off),
        "camcorder-tuned": (.camcorder, .hifi), "shoebox": (.camcorder, .linear),
    ]

    func testEveryOldSidecarLoadsIntoTheSplitAndRoundTrips() throws {
        let dir = try scratch()
        XCTAssertEqual(Set(AudioSplitGoldens.sidecars.keys), Set(Self.fileKinds.keys))
        for (key, text) in AudioSplitGoldens.sidecars {
            let url = dir.appendingPathComponent("\(key).homevideo.json")
            try text.write(to: url, atomically: true, encoding: .utf8)
            let chain = SignalChain.standard()
            try Sidecar.read(url, into: chain)
            let (mic, track) = try XCTUnwrap(Self.fileKinds[key])
            XCTAssertEqual(chain.audio.mic, mic, key)
            XCTAssertEqual(chain.audio.track, track, key)
            let want = try golden("file.\(key)")
            XCTAssertEqual(hash(chain.audio), want, "\(key) sounds as the golden file saved it")

            let again = dir.appendingPathComponent("\(key)-again.homevideo.json")
            try Sidecar.write(chain: chain, name: key, lookID: nil, to: again)
            let back = SignalChain.standard()
            try Sidecar.read(again, into: back)
            XCTAssertEqual(Self.state(back.audio), Self.state(chain.audio), key)
            XCTAssertEqual(hash(back.audio), want, "\(key) after a round trip")
        }
    }

    func testEveryOldSavedPresetLoadsIntoTheSplitAndRoundTrips() throws {
        let dir = try scratch()
        XCTAssertEqual(Set(AudioSplitGoldens.presets.keys), Set(Self.fileKinds.keys))
        for (key, text) in AudioSplitGoldens.presets {
            let url = dir.appendingPathComponent("\(key).homevideopreset")
            try text.write(to: url, atomically: true, encoding: .utf8)
            let chain = SignalChain.standard()
            Presets(vhs: chain.vhs!, audio: chain.audio).setLook(try UserPresets.read(url).look)
            let (mic, track) = try XCTUnwrap(Self.fileKinds[key])
            XCTAssertEqual(chain.audio.mic, mic, key)
            XCTAssertEqual(chain.audio.track, track, key)
            let want = try golden("file.\(key)")
            XCTAssertEqual(hash(chain.audio), want, "\(key) sounds as the golden file saved it")

            let again = dir.appendingPathComponent("\(key)-again.homevideopreset")
            try UserPresets.encode(name: key, vhs: chain.vhs!, audio: chain.audio).write(to: again)
            let back = SignalChain.standard()
            Presets(vhs: back.vhs!, audio: back.audio).setLook(try UserPresets.read(again).look)
            XCTAssertEqual(Self.state(back.audio), Self.state(chain.audio), key)
            XCTAssertEqual(hash(back.audio), want, "\(key) after a round trip")
        }
    }

    /// A pair the old menu never had, with a Strength, through a sidecar, a saved preset and the
    /// clipboard. Strength is stored only below 100, so a file at 100 has no new key.
    func testTheNewPairAndStrengthRoundTripEveryFile() throws {
        let dir = try scratch()
        func tuned() -> SignalChain {
            let chain = SignalChain.standard()
            chain.audio.mic = .camcorder
            chain.audio.setTrack(.ep)
            chain.audio.setWear(20)
            chain.audio.setMicStrength(40)
            return chain
        }
        let want = hash(tuned().audio)
        func check(_ chain: SignalChain, _ how: String) {
            XCTAssertEqual(chain.audio.mic, .camcorder, how)
            XCTAssertEqual(chain.audio.track, .ep, how)
            XCTAssertEqual(chain.audio.micStrength, 40, how)
            XCTAssertEqual(chain.audio.wear, 20, how)
            XCTAssertEqual(hash(chain.audio), want, how)
        }

        let sidecar = dir.appendingPathComponent("tuned.homevideo.json")
        let doc = try Sidecar.write(chain: tuned(), name: "tuned", lookID: nil, to: sidecar)
        XCTAssertEqual(doc[AudioChain.strengthID] as? Double, 40)
        XCTAssertEqual(doc["audio"] as? String, "eplinear", "an older build still reads the track")
        let a = SignalChain.standard()
        try Sidecar.read(sidecar, into: a)
        check(a, "sidecar")

        let preset = dir.appendingPathComponent("tuned.homevideopreset")
        try UserPresets.encode(name: "tuned", vhs: tuned().vhs!, audio: tuned().audio).write(to: preset)
        let b = SignalChain.standard()
        Presets(vhs: b.vhs!, audio: b.audio).setLook(try UserPresets.read(preset).look)
        check(b, "saved preset")

        let c = SignalChain.standard()
        try SettingsClipboard.apply(SettingsClipboard.encode(tuned()), to: c)
        check(c, "clipboard")

        let plain = dir.appendingPathComponent("plain.homevideo.json")
        let plainDoc = try Sidecar.write(chain: SignalChain.standard(), name: "plain", lookID: nil, to: plain)
        XCTAssertNil(plainDoc[AudioChain.strengthID], "Strength 100 writes nothing new")
        let pasted = try JSONSerialization.jsonObject(with: Data(SettingsClipboard.encode(SignalChain.standard()).utf8))
        let audio = try XCTUnwrap((pasted as? [String: Any])?["audio"] as? [String: Any])
        XCTAssertNil(audio["strength"], "Strength 100 copies nothing new")
    }

    func testStrengthMovesTheLookToCustomAndResetPutsItBack() throws {
        let chain = SignalChain.standard()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        let camcorder = try XCTUnwrap(Looks.look(id: "camcorder"))
        presets.setLook(camcorder)
        XCTAssertEqual(presets.look?.id, "camcorder")
        chain.audio.setMicStrength(60)
        XCTAssertNil(presets.look, "a moved Strength is Custom")
        XCTAssertTrue(LookReset.drifted(presets, from: camcorder))
        presets.setLook(camcorder)
        XCTAssertEqual(chain.audio.micStrength, 100)
        XCTAssertEqual(presets.look?.id, "camcorder")
    }

    // MARK: Arguments

    func testOldAndNewArgumentsLoadIntoTheSplit() throws {
        for (preset, mic, track) in Self.mapping {
            let chain = SignalChain.standard()
            try RenderArguments.parse(["in.mov", "out.mov", "--preset", "audio=\(preset.rawValue)"]).apply(to: chain)
            XCTAssertEqual(chain.audio.mic, mic, preset.rawValue)
            XCTAssertEqual(chain.audio.track, track, preset.rawValue)
        }
        let chain = SignalChain.standard()
        try RenderArguments.parse(["in.mov", "out.mov", "--audio-mic", "camcorder", "--audio-track", "worn",
                                   "--mic-strength", "50", "--audio-tape", "off"]).apply(to: chain)
        XCTAssertEqual(chain.audio.mic, .camcorder)
        XCTAssertEqual(chain.audio.track, .worn)
        XCTAssertEqual(chain.audio.micStrength, 50)
        XCTAssertFalse(chain.audio.tapeIsOn)
        XCTAssertThrowsError(try RenderArguments.parse(["in.mov", "out.mov", "--audio-track", "dolby"]))
        XCTAssertThrowsError(try RenderArguments.parse(["in.mov", "out.mov", "--mic-strength", "101"]))
    }

    // MARK: Shuffle

    /// One seed rolls the same audio as the pre-split chain: the same layer switches and values
    /// and the same samples (the seven in ten keep rule holds over the pair the preset names). The
    /// old label can differ where the roll flipped the camcorder mic layer's switch, since that
    /// switch is the mic: the old chain read Hi-Fi with the mic layer on as "hifi", the split
    /// reads Camcorder.
    func testShuffleRollsTheGoldenAudioForEachSeed() throws {
        XCTAssertEqual(AudioSplitGoldens.shuffle.count, 30)
        var relabeled: [UInt64] = []
        for seed in UInt64(1)...30 {
            let presets = Presets(vhs: VHSLayers(), audio: AudioChain())
            Shuffle.roll(presets, seed: seed)
            let a = presets.audio!
            // Seed 20 rolls on Fresh SP and keeps its sound, which is Linear NR (with the mic
            // layer flipped on: the camcorder mic over Linear NR). Pinned to its own golden, so
            // the seed still rolls one sound.
            if seed == 20 {
                XCTAssertEqual(a.preset, .linearNR, "seed 20")
                XCTAssertEqual(a.mic, .camcorder, "seed 20")
                XCTAssertEqual(Self.textHash(Self.state(a)), try linearNRGolden("shuffle20.state"),
                               "seed 20: the layers and values")
                XCTAssertEqual(hash(a), try linearNRGolden("shuffle20.samples"), "seed 20: the samples")
                continue
            }
            let want = try XCTUnwrap(AudioSplitGoldens.shuffle["\(seed)"])
            let mainPreset = try XCTUnwrap(AudioPreset(rawValue: want[0]))
            var mine = Self.state(a)
            mine = mainPreset.rawValue + mine.dropFirst(a.preset.rawValue.count)
            XCTAssertEqual(Self.textHash(mine), want[1], "seed \(seed): the layers and values")
            XCTAssertEqual(hash(a), want[2], "seed \(seed): the samples")
            XCTAssertEqual(a.track, mainPreset.track, "seed \(seed)")
            if a.preset != mainPreset {
                relabeled.append(seed)
                XCTAssertEqual(a.mic, mainPreset.mic == .camcorder ? .clean : .camcorder, "seed \(seed)")
            }
        }
        // The pre-split rolls that flip the mic layer are 12 and 20. Seed 20 is pinned above.
        XCTAssertEqual(relabeled, [12], "the roll that flips the mic layer on the pre-split sound")
    }
}
