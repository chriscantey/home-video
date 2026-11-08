import AVFoundation
import CoreVideo
import XCTest
@testable import HomeVideoCore

/// A stand-in decoder that counts how many are alive (made and not yet closed).
@MainActor
private final class FakeSource {
    static var alive = 0
    let url: URL
    var closed = false
    init(url: URL) {
        self.url = url
        FakeSource.alive += 1
    }
    func close() {
        closed = true
        FakeSource.alive -= 1
    }
}

@MainActor
final class ClipListTests: XCTestCase {
    private func makeList() -> ClipList<FakeSource> {
        FakeSource.alive = 0
        return ClipList(makeSource: { FakeSource(url: $0) },
                        closeSource: { $0.close() },
                        loadInfo: { _ in
                            let ctx = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8,
                                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                            return ClipInfo(duration: 2, poster: ctx.makeImage())
                        })
    }

    private let a = URL(fileURLWithPath: "/clips/a.mov")
    private let b = URL(fileURLWithPath: "/clips/b.mov")
    private let c = URL(fileURLWithPath: "/clips/c.mov")

    private func waitForPosters(_ list: ClipList<FakeSource>) async throws {
        for _ in 0..<100 where list.clips.contains(where: { $0.poster == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testThreeOpenOneSourceAlivePostersPresent() async throws {
        let list = makeList()
        list.open(a)
        list.open(b)
        list.open(c)
        XCTAssertEqual(list.clips.map(\.name), ["a.mov", "b.mov", "c.mov"])
        XCTAssertEqual(list.shownIndex, 2)
        XCTAssertEqual(FakeSource.alive, 1)
        XCTAssertEqual(list.source?.url, c)
        try await waitForPosters(list)
        XCTAssertTrue(list.clips.allSatisfy { $0.poster != nil && $0.duration == 2 })
    }

    func testReopeningSelectsTheExistingEntry() {
        let list = makeList()
        list.open(a)
        list.open(b)
        list.open(URL(fileURLWithPath: "/clips/../clips/a.mov"))
        XCTAssertEqual(list.clips.count, 2)
        XCTAssertEqual(list.shownIndex, 0)
        XCTAssertEqual(list.source?.url, a)
        XCTAssertEqual(FakeSource.alive, 1)
    }

    func testSwitchClosesTheOldSourceFirst() {
        let list = makeList()
        list.open(a)
        let first = list.source
        list.open(b)
        list.show(0)
        XCTAssertEqual(first?.closed, true)
        XCTAssertEqual(list.source?.url, a)
        XCTAssertFalse(list.source === first)
        XCTAssertEqual(FakeSource.alive, 1)
    }

    func testRemoveShownShowsItsNeighbor() {
        let list = makeList()
        list.open(a)
        list.open(b)
        list.open(c)
        list.show(1)
        list.remove(at: 1)
        XCTAssertEqual(list.clips.map(\.name), ["a.mov", "c.mov"])
        XCTAssertEqual(list.shown?.url, c)
        XCTAssertEqual(list.source?.url, c)
        XCTAssertEqual(FakeSource.alive, 1)
        // The last one shown and removed: the previous one shows.
        list.remove(at: 1)
        XCTAssertEqual(list.source?.url, a)
        list.remove(at: 0)
        XCTAssertNil(list.shownIndex)
        XCTAssertNil(list.source)
        XCTAssertEqual(FakeSource.alive, 0)
    }

    func testRemoveUnshownKeepsTheShownClip() {
        let list = makeList()
        list.open(a)
        list.open(b)
        list.open(c)
        list.remove(at: 0)
        XCTAssertEqual(list.shownIndex, 1)
        XCTAssertEqual(list.shown?.url, c)
        XCTAssertEqual(FakeSource.alive, 1)
    }

    func testPlainCommandAndShiftClicksSelect() {
        let list = makeList()
        list.open(a)
        list.open(b)
        list.open(c)
        XCTAssertEqual(list.selectedClips.map(\.url), [c], "opening selects the opened clip")
        list.click(0)
        XCTAssertEqual(list.selectedClips.map(\.url), [a])
        XCTAssertEqual(list.shown?.url, a)
        list.click(2, modifier: .command)
        XCTAssertEqual(list.selectedClips.map(\.url), [a, c])
        XCTAssertEqual(list.shown?.url, a, "the first selected clip stays shown")
        list.click(0, modifier: .command)
        XCTAssertEqual(list.selectedClips.map(\.url), [c])
        XCTAssertEqual(list.shown?.url, c, "the viewer follows the first selected clip")
        list.click(2, modifier: .command)
        XCTAssertEqual(list.selectedClips.map(\.url), [c], "the last selected clip stays selected")
        list.click(0, modifier: .shift)
        XCTAssertEqual(list.selectedClips.map(\.url), [a, b, c])
        XCTAssertEqual(list.shown?.url, a)
        XCTAssertEqual(FakeSource.alive, 1)
        list.click(1)
        XCTAssertEqual(list.selectedClips.map(\.url), [b])
    }

    func testRemovingKeepsTheRestOfTheSelection() {
        let list = makeList()
        list.open(a)
        list.open(b)
        list.open(c)
        list.click(0)
        list.click(2, modifier: .shift)
        list.remove(at: 0)
        XCTAssertEqual(list.selectedClips.map(\.url), [b, c])
        XCTAssertEqual(list.shown?.url, b)
        list.remove(at: 1)
        XCTAssertEqual(list.selectedClips.map(\.url), [b])
        list.remove(at: 0)
        XCTAssertTrue(list.selection.isEmpty)
    }

    func testOnShowReportsEveryChange() {
        let list = makeList()
        var shown: [URL?] = []
        list.onShow = { shown.append($0?.url) }
        list.open(a)
        list.open(b)
        list.remove(at: 1)
        list.remove(at: 0)
        XCTAssertEqual(shown, [a, b, a, nil])
    }

    /// The real poster path: a 320 by 240 movie gives a 160 px wide first frame.
    func testPosterIs160WideFromARealMovie() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-poster-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.writeMovie(to: url, width: 320, height: 240, frames: 10)
        let info = await ClipPoster.load(url)
        let poster = try XCTUnwrap(info.poster)
        XCTAssertEqual(poster.width, 160)
        XCTAssertEqual(poster.height, 120)
        XCTAssertEqual(info.duration, 10.0 / 30.0, accuracy: 0.02)
    }

    static func writeMovie(to url: URL, width: Int, height: Int, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            memset(CVPixelBufferGetBaseAddress(buf), Int32(i * 20), CVPixelBufferGetDataSize(buf))
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }
}
