import AVFoundation
import CoreVideo
import Metal
import XCTest
@testable import HomeVideoCore

/// The trim range keeps its ends in order and inside the clip, the sidecar round trips it
/// and leaves it out when unset, and an export of a trimmed clip writes only the range,
/// starting at time zero.
final class TrimRangeTests: XCTestCase {
    func testEndsAreOrdered() {
        let r = TrimRange(in: 8, out: 3)
        XCTAssertEqual(r.inPoint, 3)
        XCTAssertEqual(r.outPoint, 8)
        XCTAssertEqual(r.length, 5)
    }

    func testClampsToTheClip() {
        let r = TrimRange(in: -2, out: 40).clamped(to: 12)
        XCTAssertEqual(r, TrimRange(in: 0, out: 12))
        XCTAssertTrue(r.isWhole(of: 12))
        XCTAssertFalse(TrimRange(in: 5, out: 10).isWhole(of: 12))
    }

    func testNeverShorterThanTheMinimum() {
        let r = TrimRange(in: 5, out: 5).clamped(to: 12)
        XCTAssertEqual(r.length, TrimRange.minimumLength, accuracy: 1e-9)
        XCTAssertEqual(r.inPoint, 5)
        // At the end of the clip it grows backward.
        let end = TrimRange(in: 12, out: 12).clamped(to: 12)
        XCTAssertEqual(end.outPoint, 12)
        XCTAssertEqual(end.inPoint, 12 - TrimRange.minimumLength, accuracy: 1e-9)
    }

    func testSettingAnEndKeepsTheOther() {
        let r = TrimRange(in: 2, out: 9)
        XCTAssertEqual(r.settingIn(4, duration: 12), TrimRange(in: 4, out: 9))
        XCTAssertEqual(r.settingOut(7, duration: 12), TrimRange(in: 2, out: 7))
        // An in point dragged past the out point stops at it, with the minimum length kept.
        let pushed = r.settingIn(11, duration: 12)
        XCTAssertEqual(pushed.outPoint, 9, accuracy: 1e-9)
        XCTAssertEqual(pushed.length, TrimRange.minimumLength, accuracy: 1e-9)
    }

    func testClampMovesATimeInside() {
        let r = TrimRange(in: 5, out: 10)
        XCTAssertEqual(r.clamp(1), 5)
        XCTAssertEqual(r.clamp(7), 7)
        XCTAssertEqual(r.clamp(30), 10)
    }
}

@MainActor
final class TrimSidecarTests: XCTestCase {
    var folder: URL!
    var clip: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        clip = folder.appendingPathComponent("IMG_0001.MOV")
        try Data("not a movie".utf8).write(to: clip)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTrimRoundTrips() throws {
        let url = Sidecar.besideURL(for: clip)
        try Sidecar.write(chain: SignalChain.standard(), name: "x", lookID: nil,
                          trim: TrimRange(in: 5, out: 10), to: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let t = try XCTUnwrap(root["trim"] as? [String: Any])
        XCTAssertEqual(t["in"] as? Double, 5)
        XCTAssertEqual(t["out"] as? Double, 10)
        XCTAssertEqual(try Sidecar.read(url, into: SignalChain.standard()).trim, TrimRange(in: 5, out: 10))
        XCTAssertEqual(Sidecar.trim(at: url), TrimRange(in: 5, out: 10))
    }

    func testNoTrimLeavesTheKeyOut() throws {
        let url = Sidecar.besideURL(for: clip)
        try Sidecar.write(chain: SignalChain.standard(), name: "x", lookID: nil, to: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(root["trim"])
        XCTAssertNil(try Sidecar.read(url, into: SignalChain.standard()).trim)
        XCTAssertNil(Sidecar.trim(at: url))
    }

    func testMalformedTrimIsRejected() throws {
        let url = Sidecar.besideURL(for: clip)
        try Sidecar.write(chain: SignalChain.standard(), name: "x", lookID: nil, to: url)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["trim"] = ["in": "five", "out": 10]
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        XCTAssertThrowsError(try Sidecar.read(url, into: SignalChain.standard()))
    }

    func testSessionWritesTheTrimAndReadsItOnShow() throws {
        let chain = SignalChain.standard()
        let session = SidecarSession(chain: chain, fallbackFolder: folder.appendingPathComponent("Sidecars"))
        session.show(clip, currentLookID: nil)
        XCTAssertNil(session.trim)
        session.setTrim(TrimRange(in: 5, out: 10))
        session.debouncer.flush()
        XCTAssertEqual(Sidecar.trim(at: Sidecar.besideURL(for: clip)), TrimRange(in: 5, out: 10))

        session.show(nil, currentLookID: nil)
        session.show(clip, currentLookID: nil)
        XCTAssertEqual(session.trim, TrimRange(in: 5, out: 10))

        // Clearing writes a file without the key.
        session.setTrim(nil)
        session.debouncer.flush()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: Sidecar.besideURL(for: clip))) as? [String: Any])
        XCTAssertNil(root["trim"])
    }
}

@MainActor
final class TrimExportTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-trim-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 3 s, 30 fps, 160 by 120 ProRes movie whose frame `i` is a flat gray of `i`, at times i/30.
    func makeFixture() async throws -> URL {
        let url = folder.appendingPathComponent("fixture.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        ])
        input.mediaTimeScale = 30
        writer.movieTimeScale = 30
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(i * 2), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    /// Frame count, first frame time and duration of a movie's video track.
    func readBack(_ url: URL) async throws -> (frames: Int, first: Double, duration: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        var first = -1.0
        while let s = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(s) > 0 else { continue }
            if first < 0 { first = CMSampleBufferGetPresentationTimeStamp(s).seconds }
            frames += CMSampleBufferGetNumSamples(s)
        }
        let duration = try await asset.load(.duration).seconds
        return (frames, first, duration)
    }

    func testExportWritesOnlyTheRange() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let fixture = try await makeFixture()
        let whole = try await readBack(fixture)
        XCTAssertEqual(whole.frames, 90)

        let out = folder.appendingPathComponent("trimmed.mov")
        // The master (ProRes .mov): this test reads the trim's own timing. An H.264 file carries
        // the encoder's reorder delay as an edit list, and a plain track read puts its first
        // sample one frame in, which is the container, not the trim.
        let ex = Exporter(source: fixture, destination: out, chain: SignalChain.standard(), settings: .master)
        ex.trim = TrimRange(in: 1, out: 2)
        let result = try await ex.run()
        XCTAssertEqual(result.framesWritten, 30)
        let got = try await readBack(out)
        XCTAssertEqual(got.frames, 30)
        XCTAssertEqual(got.first, 0, accuracy: 1e-6, "the first written frame is at zero")
        XCTAssertEqual(got.duration, 1, accuracy: 1.0 / 30 + 1e-6)
    }

    func testUntrimmedExportKeepsEveryFrame() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let fixture = try await makeFixture()
        let out = folder.appendingPathComponent("whole.mov")
        let result = try await Exporter(source: fixture, destination: out, chain: SignalChain.standard()).run()
        XCTAssertEqual(result.framesWritten, 90)
        let got = try await readBack(out)
        XCTAssertEqual(got.frames, 90)
        XCTAssertEqual(got.duration, 3, accuracy: 1.0 / 30 + 1e-6)
    }
}
