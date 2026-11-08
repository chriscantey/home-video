#if os(macOS)
import AppKit
import Foundation

/// `homevideo-render --preview-check <clip>`: plays a clip for a few seconds through the app's own
/// preview path (`FrameSource`, the audio tap, `PreviewRenderer` in an MTKView) and prints the
/// per second counters with a one line verdict, so a slow Mac can be read from one pasted block.
///
/// The window is small and on screen: a display link ticks only for a view on a display
/// (NSView.displayLink: "If the view is hidden, or not on any display, the callback will not be
/// invoked"), so a truly off screen run would not exercise the present path at all.
@MainActor
public enum PreviewCheck {
    /// Call from the main thread outside any dispatch main queue job (homevideo-render's top level,
    /// before `dispatchMain()`): it pumps the main run loop, which then also drains the main
    /// queue that the player and the async property load need.
    public static func run(url: URL, seconds: Int = 5) -> String {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let chain = SignalChain.standard()
        let renderer = PreviewRenderer(chain: chain)
        renderer.perfLog = nil
        let source = FrameSource(url: url)
        source.loops = true
        let feed = AudioPreviewFeed(spec: chain.audio.spec)
        source.attachAudio(feed)
        renderer.source = source

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Home Video preview check"
        window.isReleasedWhenClosed = false
        window.contentView = renderer.makeView()
        window.orderFrontRegardless()
        source.play()

        // One warm up second, then one row per second as the renderer closes each one.
        var rows: [PreviewCounters] = []
        var last = renderer.counters
        let end = Date().addingTimeInterval(Double(seconds) + 1.5)
        var warm = true
        while Date() < end, rows.count < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            guard renderer.counters != last else { continue }
            last = renderer.counters
            if warm { warm = false } else { rows.append(last) }
        }
        source.close()
        renderer.detach()
        window.orderOut(nil)

        var out = String(format: "preview check: %@ %dx%d %@ %.2f fps, %@, macOS %@\n",
                         url.lastPathComponent, Int(source.naturalSize.width), Int(source.naturalSize.height),
                         source.codec, source.nominalFrameRate, PerfLog.sysctlString("machdep.cpu.brand_string") ?? "?",
                         ProcessInfo.processInfo.operatingSystemVersionString)
        out += "sec new_frames draws drawables presents present_err rate status drift_ms suspended audio tap\n"
        for (i, c) in rows.enumerated() {
            out += String(format: "%3d %10d %5d %9d %8d %11d %4.2f %@ %8.0f %@ %@ %@\n", i + 1, c.newFrames, c.draws,
                          c.drawables, c.presents, c.presentErrors, c.playerRate, c.playerStatus, c.driftMs,
                          c.outputSuspended ? "yes" : "no", c.audioTracks, c.tapTrack.isEmpty ? "none" : c.tapTrack)
        }
        out += "verdict: " + verdict(rows, sourceFPS: source.nominalFrameRate) + "\n"
        return out
    }

    /// The first fault the counters show, in the order the present path, the frame pull and the
    /// player would cause it.
    public static func verdict(_ rows: [PreviewCounters], sourceFPS: Double) -> String {
        guard !rows.isEmpty else { return "no counters: the display link never ticked (window not on a display?)" }
        func mean(_ f: (PreviewCounters) -> Int) -> Double { Double(rows.map(f).reduce(0, +)) / Double(rows.count) }
        let draws = mean(\.draws), drawables = mean(\.drawables), presents = mean(\.presents)
        let newFrames = mean(\.newFrames), errors = mean(\.presentErrors)
        if draws < 1 { return "no draws: the chain never ran" }
        if drawables < draws - 1 { return "stale drawable: draws reuse one drawable (present path)" }
        if presents < draws - 1 { return String(format: "presents short of draws (%.0f of %.0f a second): present path", presents, draws) }
        if errors > 2 { return String(format: "%.0f present errors a second: no drawable, dropped or late presents", errors) }
        if let bad = rows.first(where: { !$0.playerStatus.hasSuffix("playing") || $0.playerRate == 0 }) {
            return "player not playing (\(bad.playerStatus), rate \(bad.playerRate)): player or audio"
        }
        if sourceFPS > 0, newFrames < sourceFPS * 0.8 {
            return String(format: "frames short: %.1f new frames a second against %.2f (frame pull)", newFrames, sourceFPS)
        }
        return String(format: "ok: %.1f new frames, %.0f draws, %.0f presents a second", newFrames, draws, presents)
    }
}
#endif
