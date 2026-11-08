import XCTest
@testable import HomeVideoCore

/// A stand-in export: records its start in the shared log, reports two progress steps, and
/// either finishes, fails, or waits until cancelled.
@MainActor
private final class FakeJob: ExportJob {
    enum Mode { case finish, fail, waitForCancel }
    let name: String
    let mode: Mode
    var log: [String]
    private(set) var cancelled = false
    private let record: (String) -> Void

    init(name: String, mode: Mode, record: @escaping (String) -> Void) {
        self.name = name
        self.mode = mode
        self.log = []
        self.record = record
    }

    func run(progress: @escaping (Double) -> Void) async throws -> Int {
        record("start \(name)")
        progress(0.5)
        switch mode {
        case .finish:
            progress(1)
            record("end \(name)")
            return 10
        case .fail:
            record("fail \(name)")
            throw ExportError.writer("disk full")
        case .waitForCancel:
            while !cancelled { try await Task.sleep(for: .milliseconds(5)) }
            record("cancelled \(name)")
            throw ExportError.cancelled
        }
    }

    func cancel() { cancelled = true }
}

@MainActor
final class ExportQueueTests: XCTestCase {
    private func items(_ names: [String]) -> [ExportQueue.Item] {
        names.map { ExportQueue.Item(source: URL(fileURLWithPath: "/clips/\($0).mov"),
                                     destination: URL(fileURLWithPath: "/out/\($0) VHS.mov")) }
    }

    func testRunsInOrderOneAtATime() async {
        var events: [String] = []
        let q = ExportQueue(items: items(["a", "b", "c"])) { item in
            FakeJob(name: item.source.deletingPathExtension().lastPathComponent, mode: .finish) { events.append($0) }
        }
        q.willRun = { events.append("prepare \($0.source.deletingPathExtension().lastPathComponent)") }
        XCTAssertEqual(q.totalProgress, 0)
        await q.run()
        XCTAssertEqual(events, ["prepare a", "start a", "end a", "prepare b", "start b", "end b",
                                "prepare c", "start c", "end c"])
        XCTAssertEqual(q.outcomes, [.written(frames: 10), .written(frames: 10), .written(frames: 10)])
        XCTAssertEqual(q.written.map(\.item.source.lastPathComponent), ["a.mov", "b.mov", "c.mov"])
        XCTAssertTrue(q.isFinished)
        XCTAssertEqual(q.totalProgress, 1)
        XCTAssertNil(q.currentIndex)
    }

    func testAFailureIsRecordedAndTheQueueGoesOn() async {
        var events: [String] = []
        let q = ExportQueue(items: items(["a", "b", "c"])) { item in
            let n = item.source.deletingPathExtension().lastPathComponent
            return FakeJob(name: n, mode: n == "b" ? .fail : .finish) { events.append($0) }
        }
        q.willRun = { if $0.source.lastPathComponent == "c.mov" { throw SidecarError.malformed("c.mov.homevideo.json", reason: "bad") } }
        await q.run()
        XCTAssertEqual(q.outcomes[0], .written(frames: 10))
        guard case .failed(let e) = q.outcomes[1] else { return XCTFail("b should fail") }
        XCTAssertTrue(e.contains("disk full"))
        guard case .failed = q.outcomes[2] else { return XCTFail("c's sidecar should fail it") }
        XCTAssertFalse(events.contains("start c"), "a clip whose settings fail to load is never exported")
    }

    func testCancelStopsTheRunningClipAndSkipsTheRest() async throws {
        var events: [String] = []
        let q = ExportQueue(items: items(["a", "b", "c"])) { item in
            let n = item.source.deletingPathExtension().lastPathComponent
            return FakeJob(name: n, mode: n == "b" ? .waitForCancel : .finish) { events.append($0) }
        }
        let run = Task { await q.run() }
        while q.currentIndex != 1 || q.itemProgress < 0.5 { try await Task.sleep(for: .milliseconds(5)) }
        // Total: a done, b halfway, of three.
        XCTAssertEqual(q.totalProgress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(q.settledCount, 1)
        q.cancel()
        await run.value
        XCTAssertEqual(q.outcomes, [.written(frames: 10), .cancelled, .skipped])
        XCTAssertEqual(events, ["start a", "end a", "start b", "cancelled b"])
        XCTAssertTrue(q.isCancelled)
        XCTAssertTrue(q.isFinished)
    }

    func testDestinationsNameEachClipOnceAndNeverASource() {
        let folder = URL(fileURLWithPath: "/out")
        let srcs = [URL(fileURLWithPath: "/a/IMG_1.mov"), URL(fileURLWithPath: "/b/IMG_1.mov"),
                    URL(fileURLWithPath: "/a/IMG_2.MOV")]
        let at = Date(timeIntervalSince1970: 1_792_362_247)
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let none: (URL) -> Bool = { _ in false }
        let d = ExportQueue.destinations(for: srcs, in: folder, settings: ExportSettings(codec: .h264), at: at,
                                         timeZone: la, exists: none)
        let s = "Home Video 2026-10-18 15.24.07"
        XCTAssertEqual(d.map(\.lastPathComponent), ["IMG_1 \(s).mp4", "IMG_1 \(s) 2.mp4", "IMG_2 \(s).mp4"])
        // A source that already carries the export's name is never overwritten. The master's .mov
        // is the extension that can collide with these sources (the default is .mp4).
        let tricky = [URL(fileURLWithPath: "/out/x.mov"), URL(fileURLWithPath: "/out/x \(s).mov")]
        let t = ExportQueue.destinations(for: tricky, in: folder, settings: .master, at: at, timeZone: la,
                                         exists: none)
        XCTAssertEqual(t.map(\.lastPathComponent), ["x \(s) 2.mov", "x \(s) \(s).mov"])
        // A file already in the folder is passed over too.
        let onDisk = ExportQueue.destinations(for: [srcs[2]], in: folder, settings: .master, at: at, timeZone: la,
                                              exists: { $0.lastPathComponent == "IMG_2 \(s).mov" })
        XCTAssertEqual(onDisk.map(\.lastPathComponent), ["IMG_2 \(s) 2.mov"])
    }

    func testChainSnapshotPutsTheShownClipsSettingsBack() throws {
        let chain = SignalChain.standard()
        let vhs = try XCTUnwrap(chain.vhs)
        let presets = Presets(vhs: vhs, audio: chain.audio)
        presets.setLook(try XCTUnwrap(Looks.look(id: "attic-tape")))
        chain.framing.rotation = 90
        let before = Sidecar.snapshot(of: chain, lookID: nil)
        let saved = ChainSnapshot(chain)

        // Another clip's sidecar is read into the chain for its run.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = SignalChain.standard()
        Presets(vhs: try XCTUnwrap(other.vhs), audio: other.audio).setLook(try XCTUnwrap(Looks.look(id: "s-vhs")))
        let sidecar = dir.appendingPathComponent("other.mov.homevideo.json")
        try Sidecar.write(chain: other, name: "other.mov", lookID: "s-vhs", to: sidecar)
        try Sidecar.read(sidecar, into: chain)
        chain.framing.rotation = 0
        XCTAssertNotEqual(Sidecar.snapshot(of: chain, lookID: nil), before)

        saved.restore(into: chain)
        XCTAssertEqual(Sidecar.snapshot(of: chain, lookID: nil), before)
        XCTAssertEqual(chain.framing.rotation, 90)
        XCTAssertEqual(chain.audio.preset, .wornLinear)
    }
}
