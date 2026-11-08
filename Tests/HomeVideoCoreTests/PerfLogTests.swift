import CoreGraphics
import XCTest
@testable import HomeVideoCore

final class PerfLogTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-perf-\(UUID().uuidString)/perf.log")
    }

    func testLineCarriesEveryField() throws {
        let log = try XCTUnwrap(PerfLog(url: tempURL()))
        let e = PerfLog.Entry(date: Date(timeIntervalSince1970: 1_760_550_000), clipSize: CGSize(width: 1920, height: 1080),
                              codec: "avc1", sourceFPS: 29.97,
                              times: FrameTimes(decode: 3.14, chain: 4.8, present: 1.25),
                              fps: 30, drawRate: 60, cpuPercent: 38.24)
        let line = log.line(e)
        XCTAssertTrue(line.hasPrefix("2025-10-15T17:40:00Z chip=\""), line)
        for part in ["clip=1920x1080", "codec=avc1", "source_fps=29.97", "decode_ms=3.1", "chain_ms=4.8",
                     "present_ms=1.2", "fps=30.0", "draw_hz=60.0", "cpu=38.2", "macos="] {
            XCTAssertTrue(line.contains(part), "\(part) missing from \(line)")
        }
        XCTAssertFalse(log.chip.isEmpty)
        // The playback counters come last, in this order, after cpu.
        XCTAssertTrue(line.hasSuffix(" cpu=38.2 new_frames=0 draws=0 drawables=0 present_err=0 player_rate=0.00 player_status=? drift_ms=0 output_suspended=false audio=none tap=none chain=none"), line)
        log.write(e)
        log.write(e)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(text, line + "\n" + line + "\n")
    }

    func testCountersFillTheTail() throws {
        let log = try XCTUnwrap(PerfLog(url: tempURL()))
        var c = PreviewCounters()
        c.newFrames = 30
        c.draws = 60
        c.drawables = 59
        c.presentErrors = 1
        c.playerRate = 1
        c.playerStatus = "ready/playing"
        c.driftMs = 33.4
        c.outputSuspended = true
        c.audioTracks = "mp4a+apac"
        c.tapTrack = "mp4a"
        let e = PerfLog.Entry(date: Date(), clipSize: CGSize(width: 1080, height: 1920), codec: "avc1",
                              sourceFPS: 30, times: FrameTimes(), fps: 30, drawRate: 60, cpuPercent: 40,
                              presents: 58, counters: c, chain: "1a2b3c4d")
        let line = log.line(e)
        XCTAssertTrue(line.contains(" presents=58 "), line)
        XCTAssertTrue(line.hasSuffix(" new_frames=30 draws=60 drawables=59 present_err=1 player_rate=1.00 player_status=ready/playing drift_ms=33 output_suspended=true audio=mp4a+apac tap=mp4a chain=1a2b3c4d"), line)
    }

    /// The fingerprint moves with a parameter, a switch and the audio preset, and comes back
    /// when the value does.
    @MainActor
    func testChainFingerprintFollowsTheChain() throws {
        let chain = SignalChain.standard()
        let base = ChainFingerprint.of(chain)
        XCTAssertEqual(base.count, 8)
        XCTAssertEqual(ChainFingerprint.of(chain), base)
        let gen = try XCTUnwrap(chain.layers.first { $0.id == "generation" })
        let wasOn = gen.enabled
        gen.enabled = true
        let on = ChainFingerprint.of(chain)
        gen.setParameter("generation", to: .float(4))
        let four = ChainFingerprint.of(chain)
        XCTAssertNotEqual(on, four)
        gen.setParameter("generation", to: .float(2))
        XCTAssertEqual(ChainFingerprint.of(chain), on)
        gen.enabled = !wasOn
        XCTAssertNotEqual(ChainFingerprint.of(chain), wasOn ? on : base)
        gen.enabled = wasOn
        XCTAssertEqual(ChainFingerprint.of(chain), base)
        let preset = chain.audio.preset
        chain.audio.preset = preset == .linear ? .hifi : .linear
        XCTAssertNotEqual(ChainFingerprint.of(chain), base)
    }

    func testLogStaysUnderTheLimitAndKeepsWholeLines() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An old log past the limit is trimmed on launch to its newest half, at a line start.
        let old = (0..<30_000).map { String(format: "old line %05d padding padding padding", $0) }.joined(separator: "\n") + "\n"
        try Data(old.utf8).write(to: url)
        XCTAssertGreaterThan(old.utf8.count, PerfLog.limit)
        let log = try XCTUnwrap(PerfLog(url: url))
        let trimmed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(trimmed.utf8.count, PerfLog.limit / 2)
        XCTAssertTrue(trimmed.hasPrefix("old line "))
        XCTAssertTrue(trimmed.hasSuffix("old line 29999 padding padding padding\n"))
        // Writing past the limit trims again.
        let e = PerfLog.Entry(date: Date(), clipSize: .zero, codec: "", sourceFPS: 0, times: FrameTimes(),
                              fps: 0, drawRate: 0, cpuPercent: 0)
        for _ in 0..<5_000 { log.write(e) }
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, PerfLog.limit)
    }
}
