import AVFoundation
import Foundation

/// The video encoders the export sheet offers: every ProRes flavor `AVAssetWriter` takes, then
/// H.264 and HEVC. All of them are macOS's own encoders through VideoToolbox, free on every Mac
/// the app runs on. Each one writes a 720 by 480 file on an Intel Mac with no Pro apps
/// installed. A Mac that refuses one at runtime grays it (`ExportCodecAvailability`).
public enum ExportCodec: String, CaseIterable, Codable, Sendable {
    case proRes422Proxy, proRes422LT, proRes422, proRes422HQ, proRes4444, proRes4444XQ, h264, hevc

    public var avCodec: AVVideoCodecType {
        switch self {
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes422LT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        case .proRes4444: return .proRes4444
        // No named constant in every SDK the app builds on, so the four character code.
        case .proRes4444XQ: return AVVideoCodecType(rawValue: "ap4x")
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    public var name: String {
        switch self {
        case .proRes422Proxy: return "ProRes 422 Proxy"
        case .proRes422LT: return "ProRes 422 LT"
        case .proRes422: return "ProRes 422"
        case .proRes422HQ: return "ProRes 422 HQ"
        case .proRes4444: return "ProRes 4444"
        case .proRes4444XQ: return "ProRes 4444 XQ"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    /// The sheet's info text for the codec.
    public var blurb: String {
        switch self {
        case .proRes422Proxy: return "ProRes 422 Proxy: the smallest ProRes, for offline editing."
        case .proRes422LT: return "ProRes 422 LT: lighter than 422, still an editing format."
        case .proRes422: return "ProRes 422: the master, edits and plays on every Mac."
        case .proRes422HQ: return "ProRes 422 HQ: a higher data rate master than 422."
        case .proRes4444: return "ProRes 4444: full chroma, larger. The tape picture is 4:2:2, so it adds little here."
        case .proRes4444XQ: return "ProRes 4444 XQ: the largest ProRes. Like 4444, it adds little to a 4:2:2 tape picture."
        case .h264: return "H.264: the default. Small files that play everywhere, for sharing."
        case .hevc: return "HEVC: smaller than H.264 at the same quality, plays on recent devices."
        }
    }

    public var isProRes: Bool { self != .h264 && self != .hevc }

    /// The containers the codec writes into, the preferred one first. ProRes goes only into
    /// QuickTime (`AVAssetWriter` refuses ProRes in .mp4), H.264 and HEVC prefer .mp4 and also
    /// take .mov.
    public var containers: [ExportContainer] { isProRes ? [.mov] : [.mp4, .mov] }

    /// Whether the sheet's Quality row has choices: ProRes has a fixed data rate per flavor.
    public var hasQuality: Bool { !isProRes }
}

public enum ExportContainer: String, CaseIterable, Codable, Sendable {
    case mov, mp4

    public var fileType: AVFileType { self == .mov ? .mov : .mp4 }
    public var fileExtension: String { rawValue }
    public var name: String { self == .mov ? "QuickTime (.mov)" : "MPEG-4 (.mp4)" }
}

/// The H.264 and HEVC quality presets, as average bitrate targets for the 720 by 480 picture.
///
/// Bitrate presets rather than a quality slider: a bitrate means the same thing to the Intel and
/// the Apple silicon encoders and gives a file size that can be said up front, where
/// `AVVideoQualityKey` is honored differently by each hardware encoder and the model's tape
/// noise makes a constant quality file grow without bound. The numbers, in megabits a second:
///
/// | Preset | H.264 | HEVC |
/// |---|---|---|
/// | Good   | 3 | 2 |
/// | Better | 6 | 4 |
/// | Best   | 10 | 7 |
///
/// For scale, a DVD's MPEG-2 peaks near 9.8 Mbps for the same raster. HEVC sits about a third
/// lower for the same look. Better is the default.
public enum ExportQuality: String, CaseIterable, Codable, Sendable {
    case good, better, best

    public var name: String {
        switch self {
        case .good: return "Good"
        case .better: return "Better"
        case .best: return "Best"
        }
    }

    /// Average bitrate in bits a second, nil for ProRes.
    public func bitrate(for codec: ExportCodec) -> Int? {
        switch (codec, self) {
        case (.h264, .good): return 3_000_000
        case (.h264, .better): return 6_000_000
        case (.h264, .best): return 10_000_000
        case (.hevc, .good): return 2_000_000
        case (.hevc, .better): return 4_000_000
        case (.hevc, .best): return 7_000_000
        default: return nil
        }
    }

    public func blurb(for codec: ExportCodec) -> String {
        guard let b = bitrate(for: codec) else { return "ProRes has one data rate per flavor." }
        let mbps = Double(b) / 1_000_000
        let text = mbps == mbps.rounded() ? "\(Int(mbps))" : String(format: "%.1f", mbps)
        let minute = Double(b) * 60 / 8 / 1_000_000
        return "\(name): \(text) Mbps, about \(Int(minute.rounded())) MB a minute of picture."
    }
}

/// The export sheet's choices: codec, quality and container. The picture is always the
/// chain's 720 by 480 raster shown 4:3, and the audio follows the chain's audio preset (AAC 48
/// kHz stereo, or the source's track copied when the preset is Off), so neither is here.
/// Stored in `UserDefaults` under one key as JSON.
public struct ExportSettings: Equatable, Codable, Sendable {
    public var codec: ExportCodec
    public var quality: ExportQuality
    public var container: ExportContainer

    public init(codec: ExportCodec = .h264, quality: ExportQuality = .better,
                container: ExportContainer? = nil) {
        self.codec = codec
        self.quality = quality
        self.container = container.flatMap { codec.containers.contains($0) ? $0 : nil } ?? codec.containers[0]
    }

    /// The export sheet's default: H.264 at Better (6 Mbps) in an MPEG-4 file rather than
    /// ProRes, since it plays everywhere a friend might send it.
    public static let `default` = ExportSettings()

    /// The master: ProRes 422 in a QuickTime movie, an earlier default and still what
    /// `homevideo-render` writes unless told otherwise, so measurements and the
    /// default-picture guard see no encoder loss.
    public static let master = ExportSettings(codec: .proRes422)

    /// The choices stored under the earlier default when the sheet was left alone.
    static let earlierDefault = ExportSettings(codec: .proRes422, quality: .better, container: .mov)

    /// The `UserDefaults` key the choices live under.
    public static let defaultsKey = "exportSettings"

    /// A change between ProRes and H.264 or HEVC takes the new codec's preferred container
    /// (.mov for ProRes, .mp4 for the others). A change within a family keeps the container
    /// picked, when the new codec takes it.
    public mutating func setCodec(_ c: ExportCodec) {
        let sameFamily = c.isProRes == codec.isProRes
        codec = c
        if !sameFamily || !c.containers.contains(container) { container = c.containers[0] }
    }

    /// The settings with a container the codec takes.
    public var normalized: ExportSettings { ExportSettings(codec: codec, quality: quality, container: container) }

    public var fileType: AVFileType { container.fileType }

    /// The words after the clip's name in every export, whatever the chain holds.
    public static let nameWord = "Home Video"

    /// `2026-10-18 15.24.07`: the date, then the time to the second with periods, since a Mac
    /// file name takes no colon.
    public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// `<source name> Home Video <stamp>.<ext>`, the extension the container's.
    public func fileName(for source: URL, at date: Date, timeZone: TimeZone = .current) -> String {
        source.deletingPathExtension().lastPathComponent + " " + Self.nameWord + " "
            + Self.stamp(date, timeZone: timeZone) + "." + container.fileExtension
    }

    /// `name` in `folder`, or the first of `<stem> 2.<ext>`, `<stem> 3.<ext>` and on that
    /// `isTaken` lets through, so an export never lands on a file already there.
    public static func freeURL(for name: String, in folder: URL, isTaken: (URL) -> Bool) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let candidate = folder.appendingPathComponent(n == 1 ? name : "\(stem) \(n).\(ext)")
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// True when a file or folder is at `url`.
    public static func onDisk(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// One line for the progress view and the log: "720×480 H.264 Better (6 Mbps), .mp4".
    public var summary: String { summary(size: (SignalChain.rasterWidth, SignalChain.rasterHeight)) }

    /// The line for a file of `size`, the last stage's: "1440×1080 H.264 Better (27
    /// Mbps), .mp4" for a Film scan, the bitrate scaled as the writer scales it.
    public func summary(size: (width: Int, height: Int)) -> String {
        var s = "\(size.width)×\(size.height) \(codec.name)"
        if let b = bitrate(size: size) { s += " \(quality.name) (\(b / 1_000_000) Mbps)" }
        return s + ", .\(container.fileExtension)"
    }

    /// The quality's bitrate for a picture of `size`: as set for the raster, scaled by the area
    /// over the raster's for a larger one. Nil for ProRes.
    func bitrate(size: (width: Int, height: Int)) -> Int? {
        guard let b = quality.bitrate(for: codec) else { return nil }
        let raster = SignalChain.rasterWidth * SignalChain.rasterHeight
        return size.width * size.height == raster ? b : b * (size.width * size.height) / raster
    }

    /// The writer's settings for the last stage's picture (`SignalChain.Output`): the
    /// raster's own, the Display canvas's and the camera's (square pixels, the raster's tags,
    /// the bitrate as set, as `crt` wrote them), or the Film scan's and the untouched source's
    /// (square pixels in 709, the bitrate scaled by area).
    /// A picked Output size (`picked`) scales the Display's and the camera's bitrate by
    /// area too, so an HD or 4K file is not starved. At Auto they keep the bitrate as set.
    public func videoSettings(for output: SignalChain.Output, size: (width: Int, height: Int),
                              picked: Bool = false) -> [String: Any] {
        switch output {
        case .raster: return videoSettings
        case .display, .camera:
            var s = videoSettings(display: size)
            if picked, let b = bitrate(size: size), var props = s[AVVideoCompressionPropertiesKey] as? [String: Any] {
                props[AVVideoAverageBitRateKey] = b
                s[AVVideoCompressionPropertiesKey] = props
            }
            return s
        case .scan, .source: return scanVideoSettings(width: size.width, height: size.height)
        }
    }

    // MARK: Writer settings

    public static let colorProperties: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
    ]

    /// The writer's video settings: the codec, 720 by 480, pixel aspect 10:11 with a 704 by 480
    /// clean aperture (shown 4:3), SMPTE-C primaries, 709 transfer, 601 matrix. H.264 and HEVC add
    /// the quality's average bitrate (H.264 at High profile). `master` gives the ProRes 422
    /// dictionary `homevideo-render` writes by default.
    public var videoSettings: [String: Any] {
        var s: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: SignalChain.rasterWidth,
            AVVideoHeightKey: SignalChain.rasterHeight,
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
            AVVideoColorPropertiesKey: ExportSettings.colorProperties,
        ]
        if let bitrate = quality.bitrate(for: codec) {
            var props: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
            if codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            s[AVVideoCompressionPropertiesKey] = props
        }
        return s
    }

    /// The writer's video settings for the Display canvas: the same codec, quality and
    /// color tags at the Display size, square pixels, no clean aperture (the canvas is 4:3).
    public func videoSettings(display size: (width: Int, height: Int)) -> [String: Any] {
        var s = videoSettings
        s[AVVideoWidthKey] = size.width
        s[AVVideoHeightKey] = size.height
        s[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: 1,
                                         AVVideoPixelAspectRatioVerticalSpacingKey: 1]
        s[AVVideoCleanApertureKey] = nil
        return s
    }

    /// The Film Scan's writer settings: the codec and quality as above at the scan's size,
    /// square pixels, 709 throughout.
    public func scanVideoSettings(width: Int, height: Int) -> [String: Any] {
        var s = videoSettings
        s[AVVideoWidthKey] = width
        s[AVVideoHeightKey] = height
        s[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: 1,
                                         AVVideoPixelAspectRatioVerticalSpacingKey: 1]
        s[AVVideoCleanApertureKey] = [AVVideoCleanApertureWidthKey: width, AVVideoCleanApertureHeightKey: height,
                                      AVVideoCleanApertureHorizontalOffsetKey: 0,
                                      AVVideoCleanApertureVerticalOffsetKey: 0]
        s[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        if let bitrate = quality.bitrate(for: codec), var props = s[AVVideoCompressionPropertiesKey] as? [String: Any] {
            // The bitrate scales with the area over the raster's.
            props[AVVideoAverageBitRateKey] = bitrate * (width * height) / (SignalChain.rasterWidth * SignalChain.rasterHeight)
            s[AVVideoCompressionPropertiesKey] = props
        }
        return s
    }

    // MARK: Stored

    /// Set once a stored earlier default has been moved to the current one.
    public static let migratedKey = "exportSettingsDefaultMovedToH264"

    /// The stored choices, else the default. A stored value equal to the earlier default
    /// (ProRes 422, Better, .mov) is what the sheet saved on every export when nobody touched it,
    /// so the first load moves it to the current default, once: a later deliberate pick of
    /// exactly that master is kept.
    public static func load(from defaults: UserDefaults = .standard) -> ExportSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return .default }
        if s.normalized == earlierDefault, !defaults.bool(forKey: migratedKey) {
            defaults.set(true, forKey: migratedKey)
            ExportSettings.default.save(to: defaults)
            return .default
        }
        return s.normalized
    }

    /// Stores the choices. A save under the current default is a deliberate pick, so it also
    /// marks the move done: a pick of exactly the old master is never moved off again.
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(normalized) { defaults.set(data, forKey: ExportSettings.defaultsKey) }
        defaults.set(true, forKey: ExportSettings.migratedKey)
    }
}

/// Which codecs this Mac's writer takes, asked once per launch with
/// `AVAssetWriter.canApply(outputSettings:forMediaType:)` on the real settings. On an Intel Mac
/// the answer matched a real write of each of the eight codecs. A codec this Mac refuses is
/// shown grayed with `unavailableNote`.
public enum ExportCodecAvailability {
    public static let unavailableNote = "This Mac's video encoders do not offer this format. Apple's free "
        + "Pro Video Formats package (support.apple.com/106396) or a Pro app such as Final Cut Pro or "
        + "Compressor adds professional codecs, then quit and reopen Home Video."

    /// The codecs a writer takes, in `ExportCodec.allCases` order.
    public static let available: Set<ExportCodec> = probe()

    public static func probe() -> Set<ExportCodec> {
        var ok = Set<ExportCodec>()
        let dir = FileManager.default.temporaryDirectory
        for codec in ExportCodec.allCases {
            let s = ExportSettings(codec: codec)
            // No file is made until `startWriting`, which is never called here.
            let url = dir.appendingPathComponent("homevideo-probe-\(UUID().uuidString).\(s.container.fileExtension)")
            guard let w = try? AVAssetWriter(outputURL: url, fileType: s.fileType) else { continue }
            if w.canApply(outputSettings: s.videoSettings, forMediaType: .video) { ok.insert(codec) }
        }
        return ok
    }
}

/// The export log, `~/Library/Logs/Home Video/export.log` beside `perf.log`: one line per event
/// (start, progress every 10 percent, done, cancel, failure), each led by an ISO 8601 time.
public final class ExportLog: @unchecked Sendable {
    public static let shared = ExportLog(url: AppFolders.logs.appendingPathComponent("export.log"))

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// Appends `<time> <event> <fields>`. A failure to write is ignored: the log never stops
    /// an export.
    public func write(_ event: String, _ fields: [(String, String)] = []) {
        let time = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                               formatOptions: [.withInternetDateTime])
        var line = "\(time) \(event)"
        for (k, v) in fields { line += " \(k)=\(ExportLog.quote(v))" }
        line += "\n"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }

    /// A value with a space, a quote or an equals sign is quoted, so a line splits on spaces.
    static func quote(_ v: String) -> String {
        guard v.isEmpty || v.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Reading

    /// One line of the log as read back. `date` is nil when the line does not start with a time
    /// the reader understands. Such a line is kept as it is, beside the line before it.
    public struct Line: Equatable, Sendable {
        public let date: Date?
        public let text: String

        public init(date: Date?, text: String) {
            self.date = date
            self.text = text
        }

        /// The event word after the time: start, progress, done, cancel, fail.
        public var event: String? {
            guard date != nil else { return nil }
            let words = text.split(separator: " ", maxSplits: 2)
            return words.count > 1 ? String(words[1]) : nil
        }
    }

    /// The most the reader takes from one file, from its end. Each export writes about ten
    /// lines of 200 bytes, so this holds thousands of exports.
    static let readLimit = 4 << 20

    /// The shared log's lines from the last `hours`, newest first.
    public static func recent(hours: Double = 24, now: Date = Date()) -> [Line] {
        shared.recent(hours: hours, now: now)
    }

    /// This log's lines from the last `hours`, newest first. A missing file reads as empty. A
    /// line with no time stays next to the line before it, and leads the oldest end when nothing
    /// comes before it. A rotated log (`export.log.1` beside it, from an outside rotation) is
    /// read before the live file, so its newer lines still show.
    public func recent(hours: Double = 24, now: Date = Date()) -> [Line] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let rotated = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
        let lines = ExportLog.readLines(rotated) + ExportLog.readLines(url)

        // Each dated line starts a group, undated lines join the group before them.
        var groups: [(date: Date?, lines: [Line])] = []
        for text in lines {
            let date = ExportLog.date(of: text)
            if date != nil || groups.isEmpty {
                groups.append((date, [Line(date: date, text: text)]))
            } else {
                groups[groups.count - 1].lines.append(Line(date: nil, text: text))
            }
        }
        // Undated lines with nothing dated before them have no time to test, so they stay.
        let kept = groups.filter { $0.date.map { $0 >= cutoff } ?? true }
        // Newest first, a stable sort so lines of the same second keep their written order
        // reversed. A group with no time sorts as the oldest.
        let ordered = kept.enumerated().sorted { a, b in
            let da = a.element.date ?? .distantPast, db = b.element.date ?? .distantPast
            return da != db ? da > db : a.offset > b.offset
        }
        return ordered.flatMap { $0.element.lines.reversed() }
    }

    /// The file's lines in written order, empty when it is missing or unreadable. Only the last
    /// `readLimit` bytes are read, starting at a whole line.
    static func readLines(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(readLimit) ? size - UInt64(readLimit) : 0
        guard (try? h.seek(toOffset: start)) != nil, let data = try? h.readToEnd() else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The ISO 8601 time that leads a written line, with or without fractional seconds.
    static func date(of line: String) -> Date? {
        guard let first = line.split(separator: " ", maxSplits: 1).first else { return nil }
        let token = String(first)
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: token) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: token)
    }

    /// The window's top line: "2 exports, 12 lines, last 24 hours, newest first".
    public static func summary(_ lines: [Line], hours: Int = 24) -> String {
        guard !lines.isEmpty else { return "No exports in the last \(hours) hours" }
        let exports = lines.filter { $0.event == "start" }.count
        let e = exports == 1 ? "1 export" : "\(exports) exports"
        let l = lines.count == 1 ? "1 line" : "\(lines.count) lines"
        return "\(e), \(l), last \(hours) hours, newest first"
    }
}
