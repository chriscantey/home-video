import XCTest
@testable import HomeVideoCore

/// A promise as Photos makes one: it writes its file on the queue it is handed, then calls
/// the reader there. Records the queue it ran on.
private final class FakePromise: PromisedFile, @unchecked Sendable {
    let fileTypes: [String]
    let name: String
    let fails: Bool
    var ranOn: OperationQueue?
    var called = false

    init(name: String, type: String = "com.apple.quicktime-movie", fails: Bool = false) {
        self.name = name
        self.fileTypes = [type]
        self.fails = fails
    }

    func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any],
                              operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        called = true
        operationQueue.addOperation {
            self.ranOn = OperationQueue.current
            let url = destinationDir.appendingPathComponent(self.name)
            if self.fails {
                reader(url, CocoaError(.fileWriteUnknown))
                return
            }
            try? Data(self.name.utf8).write(to: url)
            reader(url, nil)
        }
    }
}

final class FilePromiseDropTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-imports-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func receive(urls: [URL] = [], _ promises: [PromisedFile], queue: OperationQueue) -> [URL] {
        let done = expectation(description: "completion")
        var got: [URL] = []
        FilePromiseDrop.receive(urls: urls, promises: promises, into: folder, queue: queue) { urls in
            XCTAssertTrue(Thread.isMainThread)
            got = urls
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return got
    }

    func testPromiseLandsInTheImportsFolderFromTheReceivingQueue() throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let promise = FakePromise(name: "IMG_5532.MOV")
        let got = receive([promise], queue: queue)
        XCTAssertTrue(promise.ranOn === queue)
        XCTAssertEqual(got, [folder.appendingPathComponent("IMG_5532.MOV")])
        XCTAssertEqual(try String(contentsOf: got[0], encoding: .utf8), "IMG_5532.MOV")
        // Only the file is left behind, no incoming folder.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["IMG_5532.MOV"])
    }

    func testSecondDropOfTheSameNameNeverOverwrites() {
        let first = receive([FakePromise(name: "clip.mov")], queue: FilePromiseDrop.queue)
        let second = receive([FakePromise(name: "clip.mov")], queue: FilePromiseDrop.queue)
        XCTAssertEqual(first.map(\.lastPathComponent), ["clip.mov"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["clip 2.mov"])
    }

    func testURLsFirstThenPromisesInOrderFailuresAndStillsLeftOut() {
        let finder = URL(fileURLWithPath: "/Volumes/x/finder.mov")
        let still = FakePromise(name: "IMG_1.HEIC", type: "public.heic")
        let got = receive(urls: [finder], [FakePromise(name: "b.mov"), FakePromise(name: "bad.mov", fails: true),
                                           still, FakePromise(name: "c.mp4", type: "public.mpeg-4")],
                          queue: FilePromiseDrop.queue)
        XCTAssertEqual(got.map(\.lastPathComponent), ["finder.mov", "b.mov", "c.mp4"])
        XCTAssertFalse(still.called)
    }

    func testURLsOnlyStillCompleteOnMain() {
        let finder = URL(fileURLWithPath: "/tmp/finder.mov")
        XCTAssertEqual(receive(urls: [finder], [], queue: FilePromiseDrop.queue), [finder])
    }

    func testImportsFolderIsUnderApplicationSupport() {
        XCTAssertTrue(FilePromiseDrop.importsFolder.path.hasSuffix("Library/Application Support/Home Video/Imports"))
    }
}
