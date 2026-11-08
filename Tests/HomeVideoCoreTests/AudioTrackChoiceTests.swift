import AVFoundation
import XCTest
@testable import HomeVideoCore

/// On a clip with two audio tracks in one alternate group, where the item's default is
/// the track the tap does not sit on (an iPhone clip's APAC beside AAC), the preview plays the
/// tapped track and only it. APAC cannot be encoded here, so the stand-in is two AAC tracks
/// told apart by language and tone: the first (`eng`, 440 Hz, the one `pickAudioTrack` takes)
/// is not the group's default, the second (`fra`, 1 kHz) is.
@MainActor
final class AudioTrackChoiceTests: XCTestCase {
    static let rate = 48_000.0

    /// Writes one AAC .m4a of a stereo sine.
    func writeTone(_ hz: Double, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-tone-\(UUID().uuidString).m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let n = AVAudioFrameCount(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buffer.frameLength = n
        for c in 0..<2 {
            for i in 0..<Int(n) { buffer.floatChannelData![c][i] = Float(0.25 * sin(2 * .pi * hz * Double(i) / Self.rate)) }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    /// Muxes the two tones into one .mov as an alternate group whose default is the second.
    func makeTwoTrackClip() async throws -> URL {
        let first = try writeTone(440, seconds: 3), second = try writeTone(1_000, seconds: 3)
        defer { for u in [first, second] { try? FileManager.default.removeItem(at: u) } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homevideo-two-audio-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var pairs: [(AVAssetWriterInput, AVAssetReaderTrackOutput, AVAssetReader)] = []
        for (src, language) in [(first, "eng"), (second, "fra")] {
            let asset = AVURLAsset(url: src)
            let track = try await asset.loadTracks(withMediaType: .audio).first!
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.languageCode = language
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            pairs.append((input, output, reader))
        }
        let group = AVAssetWriterInputGroup(inputs: pairs.map(\.0), defaultInput: pairs[1].0)
        XCTAssertTrue(writer.canAdd(group))
        writer.add(group)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // Round robin, so the writer's interleaving never waits on an input that is not fed.
        var done = [false, false]
        while done.contains(false) {
            var moved = false
            for (i, (input, output, _)) in pairs.enumerated() where !done[i] && input.isReadyForMoreMediaData {
                if let s = output.copyNextSampleBuffer() {
                    input.append(s)
                } else {
                    input.markAsFinished()
                    done[i] = true
                }
                moved = true
            }
            if !moved { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error.map { "\($0)" } ?? "")
        return url
    }

    func testPreviewPlaysTheTappedTrackWhenTheDefaultIsAnother() async throws {
        let url = try await makeTwoTrackClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)
        // The fixture reproduces the iPhone case: the player's default is not the tapped track.
        let maybePicked = await Exporter.pickAudioTrack(tracks)
        let picked = try XCTUnwrap(maybePicked)
        XCTAssertEqual(picked.trackID, tracks[0].trackID, "pickAudioTrack keeps taking the first AAC track")
        let enabledByDefault = try await tracks[0].load(.isEnabled)
        XCTAssertFalse(enabledByDefault, "the fixture's first track should not be the default")

        let source = FrameSource(url: url)
        defer { source.close() }
        source.attachAudio(AudioPreviewFeed(spec: AudioChain(preset: .linear).spec))
        for _ in 0..<200 where source.enabledAudioTrackIDs != [picked.trackID] {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(source.tapTrackID, picked.trackID)
        XCTAssertEqual(source.enabledAudioTrackIDs, [picked.trackID], "the player plays the tapped track and only it")
        XCTAssertEqual(source.audioTracks, source.tapTrackCodec, "audio= and tap= read the same track")
        print("Track choice: tap \(source.tapTrackID), enabled \(source.enabledAudioTrackIDs), audio=\(source.audioTracks)")
    }

    /// The mix the preview hands the player, rendered headless over both tracks: the tapped
    /// track's 440 Hz comes through, the other track's 1 kHz is silenced.
    func testMixSilencesTheUntappedTrack() async throws {
        let url = try await makeTwoTrackClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let feed = AudioPreviewFeed(spec: AudioChain(preset: .off).spec)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
        ])
        output.audioMix = try XCTUnwrap(feed.makeAudioMix(for: tracks[0], silencing: [tracks[1]]))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var left: [Float] = []
        while let s = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(s) {
            let count = CMBlockBufferGetDataLength(block) / 4
            var data = [Float](repeating: 0, count: count)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4,
                                                                          destination: $0.baseAddress!) }
            for i in stride(from: 0, to: count - 1, by: 2) { left.append(data[i]) }
        }
        XCTAssertGreaterThan(left.count, 96_000)
        let slice = left[48_000..<72_000]
        let a440 = tone(slice, hz: 440), a1k = tone(slice, hz: 1_000)
        XCTAssertEqual(a440, 0.25, accuracy: 0.05, "the tapped track is heard")
        XCTAssertLessThan(a1k, 0.25 * 0.01, "the other track is silent (40 dB down)")
        print("Track choice mix: 440 Hz \(a440), 1 kHz \(a1k)")
    }

    /// Amplitude of one tone by a single DFT bin over a Hann window.
    func tone(_ x: ArraySlice<Float>, hz: Double) -> Double {
        var re = 0.0, im = 0.0, wsum = 0.0
        for (i, v) in x.enumerated() {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(x.count - 1))
            let p = 2 * .pi * hz * Double(i) / Self.rate
            re += Double(v) * w * cos(p)
            im += Double(v) * w * sin(p)
            wsum += w
        }
        return 2 * (re * re + im * im).squareRoot() / wsum
    }
}
