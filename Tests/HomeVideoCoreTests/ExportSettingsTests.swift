import AVFoundation
import XCTest
@testable import HomeVideoCore

final class ExportSettingsTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        let name = "ExportSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testRoundTripThroughUserDefaults() {
        let d = scratchDefaults()
        XCTAssertEqual(ExportSettings.load(from: d), .default, "nothing stored reads the default")
        for codec in ExportCodec.allCases {
            for quality in ExportQuality.allCases {
                for container in codec.containers {
                    let s = ExportSettings(codec: codec, quality: quality, container: container)
                    s.save(to: d)
                    XCTAssertEqual(ExportSettings.load(from: d), s)
                }
            }
        }
        // One key holds everything.
        XCTAssertNotNil(d.data(forKey: ExportSettings.defaultsKey))
    }

    /// The sheet's default is H.264 Better in an .mp4, the master is ProRes 422 .mov, and a
    /// stored earlier default (ProRes 422 .mov) moves to the new one exactly once.
    func testDefaultIsH264Mp4AndTheMasterIsProRes() {
        XCTAssertEqual(ExportSettings.default, ExportSettings(codec: .h264, quality: .better, container: .mp4))
        XCTAssertEqual(ExportSettings.default.summary, "720×480 H.264 Better (6 Mbps), .mp4")
        XCTAssertEqual(ExportSettings.master, ExportSettings(codec: .proRes422, quality: .better, container: .mov))
        let d = scratchDefaults()
        // The earlier default, stored on every export nobody tuned.
        d.set(Data("{\"codec\":\"proRes422\",\"quality\":\"better\",\"container\":\"mov\"}".utf8),
              forKey: ExportSettings.defaultsKey)
        XCTAssertEqual(ExportSettings.load(from: d), .default, "the old default moves to the new one")
        XCTAssertTrue(d.bool(forKey: ExportSettings.migratedKey))
        // A later deliberate pick of the master is kept.
        ExportSettings.master.save(to: d)
        XCTAssertEqual(ExportSettings.load(from: d), .master)
        // Any other stored choice is untouched by the move, and a save marks the move done.
        let e = scratchDefaults()
        ExportSettings(codec: .proRes422HQ).save(to: e)
        XCTAssertEqual(ExportSettings.load(from: e).codec, .proRes422HQ)
        XCTAssertTrue(e.bool(forKey: ExportSettings.migratedKey))
        // A new user who picks the master keeps it across loads.
        let f = scratchDefaults()
        ExportSettings.master.save(to: f)
        XCTAssertEqual(ExportSettings.load(from: f), .master)
        XCTAssertEqual(ExportSettings.load(from: f), .master)
    }

    func testBadStoredValueReadsDefault() {
        let d = scratchDefaults()
        d.set(Data("{\"codec\":\"vp9\"}".utf8), forKey: ExportSettings.defaultsKey)
        XCTAssertEqual(ExportSettings.load(from: d), .default)
        // A stored ProRes .mp4 (never written by the app) is put back in a .mov.
        d.set(Data("{\"codec\":\"proRes422HQ\",\"quality\":\"best\",\"container\":\"mp4\"}".utf8),
              forKey: ExportSettings.defaultsKey)
        XCTAssertEqual(ExportSettings.load(from: d).container, .mov)
    }

    func testContainerByCodec() {
        for codec in ExportCodec.allCases where codec.isProRes {
            XCTAssertEqual(codec.containers, [.mov], codec.name)
            XCTAssertEqual(ExportSettings(codec: codec, container: .mp4).container, .mov, codec.name)
            XCTAssertFalse(codec.hasQuality)
        }
        for codec in [ExportCodec.h264, .hevc] {
            XCTAssertEqual(codec.containers, [.mp4, .mov])
            XCTAssertEqual(ExportSettings(codec: codec).container, .mp4)
            XCTAssertEqual(ExportSettings(codec: codec, container: .mov).container, .mov)
            XCTAssertTrue(codec.hasQuality)
        }
        var s = ExportSettings(codec: .h264, container: .mov)
        s.setCodec(.hevc)
        XCTAssertEqual(s.container, .mov, "H.264 to HEVC keeps the container picked")
        s.setCodec(.proRes422)
        XCTAssertEqual(s.container, .mov)
        s.setCodec(.h264)
        XCTAssertEqual(s.container, .mp4, "ProRes to H.264 takes H.264's .mp4")
        var t = ExportSettings(codec: .h264)
        t.setCodec(.proRes4444)
        XCTAssertEqual(t.container, .mov, "ProRes never stays in .mp4")
    }

    /// 2026-10-18 15:24:07 in Los Angeles.
    private let askTime = Date(timeIntervalSince1970: 1_792_362_247)
    private let la = TimeZone(identifier: "America/Los_Angeles")!

    func testFileNameIsTheClipHomeVideoAndTheDateAndTime() {
        let src = URL(fileURLWithPath: "/clips/IMG_0001.MOV")
        XCTAssertEqual(ExportSettings.stamp(askTime, timeZone: la), "2026-10-18 15.24.07")
        XCTAssertEqual(ExportSettings.default.fileName(for: src, at: askTime, timeZone: la),
                       "IMG_0001 Home Video 2026-10-18 15.24.07.mp4")
        // The extension follows the codec's container.
        XCTAssertEqual(ExportSettings.master.fileName(for: src, at: askTime, timeZone: la),
                       "IMG_0001 Home Video 2026-10-18 15.24.07.mov")
        XCTAssertEqual(ExportSettings(codec: .h264).fileName(for: src, at: askTime, timeZone: la),
                       "IMG_0001 Home Video 2026-10-18 15.24.07.mp4")
        XCTAssertEqual(ExportSettings(codec: .hevc, container: .mov).fileName(for: src, at: askTime, timeZone: la),
                       "IMG_0001 Home Video 2026-10-18 15.24.07.mov")
        // A clip name with spaces and periods keeps them, only its own extension goes.
        XCTAssertEqual(ExportSettings.master.fileName(for: URL(fileURLWithPath: "/c/Trip 1.2.mov"), at: askTime,
                                                      timeZone: la),
                       "Trip 1.2 Home Video 2026-10-18 15.24.07.mov")
        // Single digits are padded and the time never carries a colon.
        let morning = Date(timeIntervalSince1970: 1_767_276_305)  // 2026-01-01 06:05:05 in Los Angeles
        XCTAssertEqual(ExportSettings.stamp(morning, timeZone: la), "2026-01-01 06.05.05")
        XCTAssertFalse(ExportSettings.default.fileName(for: src, at: Date()).contains(":"))
        XCTAssertFalse(ExportSettings.default.fileName(for: src, at: Date()).contains("VHS"))
    }

    @MainActor
    func testAnExportNeverReplacesAFileAlreadyThere() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = URL(fileURLWithPath: "/clips/IMG_0001.MOV")
        let s = ExportSettings.master
        func next() -> URL {
            ExportQueue.destinations(for: [src], in: dir, settings: s, at: askTime, timeZone: la)[0]
        }
        // Three exports in the same second: the name, then 2, then 3, each a new file.
        var written: [String] = []
        for _ in 0..<3 {
            let url = next()
            try Data("x".utf8).write(to: url, options: .withoutOverwriting)
            written.append(url.lastPathComponent)
        }
        XCTAssertEqual(written, ["IMG_0001 Home Video 2026-10-18 15.24.07.mov",
                                 "IMG_0001 Home Video 2026-10-18 15.24.07 2.mov",
                                 "IMG_0001 Home Video 2026-10-18 15.24.07 3.mov"])
        // A second later is a new name with no counter.
        XCTAssertEqual(ExportQueue.destinations(for: [src], in: dir, settings: s, at: askTime + 1, timeZone: la)[0]
            .lastPathComponent, "IMG_0001 Home Video 2026-10-18 15.24.08.mov")
        // The counter is per extension: the .mp4 of the same moment is still free.
        XCTAssertEqual(ExportQueue.destinations(for: [src], in: dir, settings: .default, at: askTime, timeZone: la)[0]
            .lastPathComponent, "IMG_0001 Home Video 2026-10-18 15.24.07.mp4")
    }

    /// The master's video settings in full, which `Exporter.videoSettings` also writes.
    private var masterVideoSettings: [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: 720,
            AVVideoHeightKey: 480,
            AVVideoPixelAspectRatioKey: [
                AVVideoPixelAspectRatioHorizontalSpacingKey: 10,
                AVVideoPixelAspectRatioVerticalSpacingKey: 11,
            ],
            AVVideoCleanApertureKey: [
                AVVideoCleanApertureWidthKey: 704,
                AVVideoCleanApertureHeightKey: 480,
                AVVideoCleanApertureHorizontalOffsetKey: 0,
                AVVideoCleanApertureVerticalOffsetKey: 0,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
            ],
        ]
    }

    @MainActor
    func testMasterWritesTheMasterVideoSettings() {
        XCTAssertEqual(ExportSettings.master.codec, .proRes422)
        XCTAssertEqual(ExportSettings.master.container, .mov)
        XCTAssertEqual(ExportSettings.master.fileType, .mov)
        XCTAssertTrue(NSDictionary(dictionary: ExportSettings.master.videoSettings)
            .isEqual(to: masterVideoSettings))
        XCTAssertTrue(NSDictionary(dictionary: Exporter.videoSettings).isEqual(to: masterVideoSettings))
        XCTAssertEqual(Exporter.fileType, .mov)
    }

    func testEveryCodecKeepsTheRasterAndTags() {
        for codec in ExportCodec.allCases {
            let s = ExportSettings(codec: codec).videoSettings
            XCTAssertEqual(s[AVVideoCodecKey] as? AVVideoCodecType, codec.avCodec)
            for key in [AVVideoWidthKey, AVVideoHeightKey, AVVideoPixelAspectRatioKey, AVVideoCleanApertureKey,
                        AVVideoColorPropertiesKey] {
                XCTAssertTrue((s[key] as AnyObject).isEqual(masterVideoSettings[key]), "\(codec.name) \(key)")
            }
            let props = s[AVVideoCompressionPropertiesKey] as? [String: Any]
            XCTAssertEqual(props == nil, codec.isProRes, codec.name)
        }
    }

    func testBitratePresets() {
        let table: [(ExportCodec, ExportQuality, Int)] = [
            (.h264, .good, 3_000_000), (.h264, .better, 6_000_000), (.h264, .best, 10_000_000),
            (.hevc, .good, 2_000_000), (.hevc, .better, 4_000_000), (.hevc, .best, 7_000_000),
        ]
        for (codec, quality, bitrate) in table {
            let props = ExportSettings(codec: codec, quality: quality).videoSettings[AVVideoCompressionPropertiesKey]
                as? [String: Any]
            XCTAssertEqual(props?[AVVideoAverageBitRateKey] as? Int, bitrate, "\(codec) \(quality)")
        }
        XCTAssertNil(ExportQuality.best.bitrate(for: .proRes422HQ))
        XCTAssertEqual(ExportSettings(codec: .h264).summary, "720×480 H.264 Better (6 Mbps), .mp4")
        XCTAssertEqual(ExportSettings.master.summary, "720×480 ProRes 422, .mov")
    }

    func testRenderArgumentsTakeExportChoices() throws {
        XCTAssertEqual(try RenderArguments.parse(["a.mov", "b.mov"]).export, .master)
        let a = try RenderArguments.parse(["a.mov", "b.mp4", "--codec", "hevc", "--quality=best"])
        XCTAssertEqual(a.export, ExportSettings(codec: .hevc, quality: .best, container: .mp4))
        XCTAssertThrowsError(try RenderArguments.parse(["a.mov", "b.mp4", "--codec", "proRes422", "--container", "mp4"]))
        XCTAssertThrowsError(try RenderArguments.parse(["a.mov", "b.mp4", "--codec", "vp9"]))
    }

    func testExportLogLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exportlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ExportLog(url: dir.appendingPathComponent("export.log"))
        log.write("start", [("clip", "My Clip.mov"), ("codec", "h264")])
        log.write("done", [("frames", "45")])
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" start clip=\"My Clip.mov\" codec=h264"), String(lines[0]))
        XCTAssertTrue(lines[1].hasSuffix(" done frames=45"))
    }
}
