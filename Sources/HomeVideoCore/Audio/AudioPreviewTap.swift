import AVFoundation
import MediaToolbox
import os

/// Carries the audio chain from the main actor to the preview's render thread. Processors are
/// built off the render thread (in the tap's prepare, and on the caller's thread in `update`)
/// and handed over under a lock, and the render callback only swaps one in, so it never stalls on
/// filter design or noise calibration. A swap restarts the filters, which is inaudible while
/// dragging a slider at preview quality.
public final class AudioPreviewFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var spec: AudioChainSpec
    private var contexts: [WeakTapContext] = []
    /// The diagnostic dump, nil in normal use.
    public let dump: AudioTapDump?
    /// Live readings for a diagnostics panel, nil unless asked for (the Mac never asks).
    public let meter: AudioTapMeter?
    /// The source bypass, read by the render thread on every buffer. An unfair lock held
    /// for one load or store, never across any work.
    private let bypassFlag = OSAllocatedUnfairLock(initialState: false)

    /// While on, every tap hands back the source untouched, the same early return Off takes,
    /// so the sound is bit-exact source. The processors stay built and the spec stays as it
    /// was, so turning it off is heard on the next buffer with nothing rebuilt.
    public var bypass: Bool {
        get { bypassFlag.withLock { $0 } }
        set { bypassFlag.withLock { $0 = newValue } }
    }

    public init(spec: AudioChainSpec, dump: AudioTapDump? = nil, meter: AudioTapMeter? = nil) {
        self.spec = spec
        self.dump = dump
        self.meter = meter
        _ = NoiseSource.pinkRMS  // calibrate once, here, not on a render thread
    }

    /// Builds a processor for every live tap at its format and queues it for the next buffer.
    public func update(_ spec: AudioChainSpec) {
        lock.lock()
        self.spec = spec
        contexts.removeAll { $0.value == nil }
        let live = contexts.compactMap(\.value)
        lock.unlock()
        for c in live { c.offer(spec) }
    }

    var currentSpec: AudioChainSpec {
        lock.lock(); defer { lock.unlock() }
        return spec
    }

    func register(_ c: AudioTapContext) {
        lock.lock()
        contexts.append(WeakTapContext(value: c))
        lock.unlock()
    }

    /// An audio mix whose tap runs the chain on `track`, for an `AVPlayerItem` (or an
    /// `AVAssetReaderAudioMixOutput`, which is how the tests drive it). Every track in
    /// `silencing` gets volume 0, so a second audio track the player might also play stays
    /// silent and only the tapped one is heard.
    public func makeAudioMix(for track: AVAssetTrack, silencing: [AVAssetTrack] = []) -> AVAudioMix? {
        let context = AudioTapContext(feed: self)
        register(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(format.pointee)
            },
            unprepare: { tap in
                Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .unprepare()
            },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                // The source time of the buffer (`AudioBlock.time`).
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut)
                guard status == noErr else {
                    Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                        .feed.meter?.sourceError(status)
                    return
                }
                Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(bufferList, frames: framesOut.pointee,
                             time: range.start.isNumeric ? range.start.seconds : nil)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(context).release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let muted = silencing.map { t -> AVMutableAudioMixInputParameters in
            let p = AVMutableAudioMixInputParameters(track: t)
            p.setVolume(0, at: .zero)
            return p
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params] + muted
        return mix
    }
}

private struct WeakTapContext {
    weak var value: AudioTapContext?
}

/// One tap's state, owned by the tap (retained in its storage, released in finalize).
final class AudioTapContext: @unchecked Sendable {
    let feed: AudioPreviewFeed
    private let lock = NSLock()
    /// Guarded by `lock`: the stream format once prepared, and a processor waiting to go in.
    private var format: (sampleRate: Double, channels: Int)?
    private var pending: AudioChainProcessor?
    private var pendingLabel = ""
    /// Render thread only.
    private var processor: AudioChainProcessor?
    private var supported = false
    private var interleaved = false
    private var scratch: [UnsafeMutablePointer<Float>] = []
    private var capacity = 0
    /// Frames seen since prepare, for the dump's log.
    private var framesSeen = 0
    /// The bypass as the last buffer saw it, so the dump logs each change once. Render thread only.
    private var wasBypassed = false

    init(feed: AudioPreviewFeed) { self.feed = feed }

    deinit { for p in scratch { p.deallocate() } }

    /// Builds a processor for `spec` at the prepared format, on the caller's thread.
    func offer(_ spec: AudioChainSpec) {
        lock.lock()
        let f = format
        lock.unlock()
        guard let f else { return }
        let p = AudioChainProcessor(spec: spec, sampleRate: f.sampleRate, channels: f.channels)
        lock.lock()
        pending = p
        pendingLabel = AudioTapDump.label(spec)
        lock.unlock()
    }

    func prepare(_ asbd: AudioStreamBasicDescription) {
        let channels = Int(asbd.mChannelsPerFrame)
        supported = asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mBitsPerChannel == 32 && channels > 0
        interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let spec = feed.currentSpec
        processor = AudioChainProcessor(spec: spec, sampleRate: asbd.mSampleRate, channels: channels)
        framesSeen = 0
        lock.lock()
        format = (asbd.mSampleRate, channels)
        pending = nil
        lock.unlock()
        feed.dump?.prepare(self, sampleRate: asbd.mSampleRate, channels: channels, supported: supported,
                           interleaved: interleaved, chain: AudioTapDump.label(spec))
        feed.meter?.prepare(sampleRate: asbd.mSampleRate, channels: channels, float32: supported, interleaved: interleaved)
    }

    func unprepare() {
        lock.lock()
        format = nil
        pending = nil
        lock.unlock()
        processor = nil
        feed.meter?.unprepare()
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount, time: Double? = nil) {
        guard supported, frames > 0 else { return }
        if lock.try() {
            if let p = pending {
                processor = p
                pending = nil
                feed.dump?.note(self, "chain frame=\(framesSeen) \(pendingLabel)")
            }
            lock.unlock()
        }
        let dump = feed.dump
        let bypassed = feed.bypass
        if bypassed != wasBypassed {
            wasBypassed = bypassed
            dump?.note(self, "bypass \(bypassed ? "on" : "off") frame=\(framesSeen)")
        }
        dump?.write(self, list, frames: Int(frames), interleaved: interleaved, output: false)
        let meter = feed.meter
        meter?.record(list, frames: Int(frames), output: false)
        defer {
            dump?.write(self, list, frames: Int(frames), interleaved: interleaved, output: true)
            meter?.record(list, frames: Int(frames), output: true)
            framesSeen += Int(frames)
        }
        guard !bypassed, let processor, !processor.isPassthrough else { return }
        let n = Int(frames)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = processor.channelCount

        if !interleaved {
            // One buffer per channel: process in place.
            let ptrs = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            guard ptrs.count == channels else { return }
            processor.process(AudioBlock(channels: ptrs, frames: n, time: time))
            return
        }
        // One interleaved buffer: deinterleave into scratch, process, write back.
        guard let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        if capacity < n || scratch.count != channels {
            for p in scratch { p.deallocate() }
            capacity = max(n, 4_096)
            scratch = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
        }
        for c in 0..<channels { for i in 0..<n { scratch[c][i] = data[i * channels + c] } }
        processor.process(AudioBlock(channels: scratch, frames: n, time: time))
        for c in 0..<channels { for i in 0..<n { data[i * channels + c] = scratch[c][i] } }
    }
}

// MARK: - Dump

/// A diagnostic: what the preview's tap receives and what it hands back, as two Float32 WAV
/// files in `folder` (`in.wav`, `out.wav`, interleaved, at the tap's own rate and channel
/// count), plus `dump.log` with the tap's format and every chain swap with the frame it landed
/// on. Turned on by `HOMEVIDEO_AUDIO_DUMP=<folder>` or `-homevideoAudioDump <folder>` at launch, off
/// otherwise. The render thread copies each buffer and a serial queue writes it, so the files
/// stay valid (sizes patched after every write) even when the app is killed mid-play. Only
/// the first tap to prepare is dumped. A later one is named in the log and skipped.
public final class AudioTapDump: @unchecked Sendable {
    public let folder: URL
    private let queue = DispatchQueue(label: "homevideo.audio-dump")
    private let lock = NSLock()
    /// Guarded by `lock`: the tap being dumped.
    private weak var owner: AudioTapContext?
    /// Queue only.
    private var inFile: WAVFloatWriter?
    private var outFile: WAVFloatWriter?
    private var log: FileHandle?
    private let start = Date()

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("dump.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        log = try? FileHandle(forWritingTo: url)
    }

    /// From the environment (`HOMEVIDEO_AUDIO_DUMP`) or the defaults (`-homevideoAudioDump`), else nil.
    public static func fromLaunch(_ env: [String: String] = ProcessInfo.processInfo.environment,
                                  defaults: UserDefaults = .standard) -> AudioTapDump? {
        guard let path = env["HOMEVIDEO_AUDIO_DUMP"] ?? defaults.string(forKey: "homevideoAudioDump"), !path.isEmpty else { return nil }
        return AudioTapDump(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
    }

    /// The chain a spec runs, as layer ids (`off` for none), for the log.
    static func label(_ spec: AudioChainSpec) -> String {
        spec.layers.isEmpty ? "off" : spec.layers.map(\.kind.rawValue).joined(separator: ",")
    }

    private func isOwner(_ c: AudioTapContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return owner === c
    }

    func prepare(_ c: AudioTapContext, sampleRate: Double, channels: Int, supported: Bool, interleaved: Bool,
                 chain: String) {
        lock.lock()
        let first = owner == nil
        if first { owner = c }
        let mine = owner === c
        lock.unlock()
        let line = "prepare rate=\(sampleRate) channels=\(channels) float32=\(supported) interleaved=\(interleaved)"
            + " chain \(chain)" + (mine ? "" : " (another tap, not dumped)")
        queue.async { [self] in
            if first {
                inFile = WAVFloatWriter(url: folder.appendingPathComponent("in.wav"), sampleRate: sampleRate, channels: channels)
                outFile = WAVFloatWriter(url: folder.appendingPathComponent("out.wav"), sampleRate: sampleRate, channels: channels)
            }
            writeLine(line)
        }
    }

    func note(_ c: AudioTapContext, _ text: String) {
        guard isOwner(c) else { return }
        queue.async { [self] in writeLine(text) }
    }

    /// Copies the buffer list as interleaved Float32 and queues it for `in.wav` or `out.wav`.
    func write(_ c: AudioTapContext, _ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, interleaved: Bool,
               output: Bool) {
        guard frames > 0, isOwner(c) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var samples: [Float]
        if interleaved {
            guard let b = buffers.first, let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let count = min(Int(b.mDataByteSize) / 4, frames * Int(b.mNumberChannels))
            samples = Array(UnsafeBufferPointer(start: d, count: count))
        } else {
            let ptrs = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            let ch = ptrs.count
            samples = [Float](repeating: 0, count: frames * ch)
            for (k, p) in ptrs.enumerated() { for i in 0..<frames { samples[i * ch + k] = p[i] } }
        }
        queue.async { [self] in (output ? outFile : inFile)?.append(samples) }
    }

    private func writeLine(_ text: String) {
        let t = String(format: "%.3f", Date().timeIntervalSince(start))
        log?.write(Data("\(t) \(text)\n".utf8))
    }

    /// Waits for every queued write (tests).
    public func flush() { queue.sync {} }
}

/// A Float32 WAV file (format 3, IEEE float) written as it grows, its sizes patched after
/// every append.
final class WAVFloatWriter {
    private let handle: FileHandle
    private let channels: Int
    private var dataBytes: UInt32 = 0

    init?(url: URL, sampleRate: Double, channels: Int) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        self.channels = max(1, channels)
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate.rounded())
        header.append(contentsOf: Array("RIFF".utf8)); u32(36)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(3); u16(UInt16(self.channels)); u32(rate); u32(rate * UInt32(self.channels) * 4)
        u16(UInt16(self.channels * 4)); u16(32)
        header.append(contentsOf: Array("data".utf8)); u32(0)
        handle.write(header)
    }

    deinit { try? handle.close() }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        handle.seekToEndOfFile()
        samples.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
        dataBytes &+= UInt32(samples.count * 4)
        handle.seek(toFileOffset: 4)
        withUnsafeBytes(of: (dataBytes &+ 36).littleEndian) { handle.write(Data($0)) }
        handle.seek(toFileOffset: 40)
        withUnsafeBytes(of: dataBytes.littleEndian) { handle.write(Data($0)) }
    }
}
