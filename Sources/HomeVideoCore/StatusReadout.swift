import Foundation

/// The status bar's right-hand text, built so its width does not move with the numbers:
/// every field is padded to its widest expected value with figure spaces (U+2007, as wide as a
/// digit under `monospacedDigit`), so `frame 4,263` and `frame 12,345` take the same room and
/// the line never grows or shrinks as it ticks. The present error count is not shown here: it
/// stays in `perf.log`.
public enum StatusReadout {
    /// A digit-wide space. A plain space is narrower than a digit in a monospaced-digit font.
    public static let figureSpace: Character = "\u{2007}"
    static let separator = " · "

    /// Left-pads `s` with figure spaces to `width` characters. Longer strings pass unchanged.
    public static func pad(_ s: String, to width: Int) -> String {
        s.count >= width ? s : String(repeating: figureSpace, count: width - s.count) + s
    }

    /// A count with thousands separators: 4263 reads `4,263`.
    public static func grouped(_ n: UInt64) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return out
    }

    /// `zoom 1.500 · pan X -0.000 · pan Y -0.767`. Zoom is clamped to 1...2 and the pans carry
    /// their sign, so the fixed formats already hold one width.
    public static func crop(zoom: Double, pan: Double, panY: Double) -> String {
        String(format: "zoom %.3f", zoom)
            + separator + String(format: "pan X %+.3f", pan)
            + separator + String(format: "pan Y %+.3f", panY)
    }

    /// `frame 00,000`: the frame count padded to five digits and a comma.
    public static func frame(_ n: UInt64) -> String {
        "frame " + pad(grouped(n), to: 6)
    }

    /// `d 00.0 · c 00.0 · p 000.0 ms · 00.0 fps · new 000 draw 000 drw 000 pres 000`.
    public static func performance(times: FrameTimes, fps: Double, counters: PreviewCounters) -> String {
        func ms(_ v: Double, _ width: Int) -> String { pad(String(format: "%.1f", v), to: width) }
        func count(_ v: Int) -> String { pad(String(max(v, 0)), to: 3) }
        return "d " + ms(times.decode, 4)
            + separator + "c " + ms(times.chain, 4)
            + separator + "p " + ms(times.present, 5) + " ms"
            + separator + ms(fps, 4) + " fps"
            + separator + "new \(count(counters.newFrames)) draw \(count(counters.draws))"
            + " drw \(count(counters.drawables)) pres \(count(counters.presents))"
    }

    /// The whole right-hand line: the export outcome when there is one, the crop while it is
    /// moved off its default, then the frame count and the performance readout.
    public static func line(exportMessage: String?, crop: String?, frame: UInt64, times: FrameTimes,
                            fps: Double, counters: PreviewCounters) -> String {
        lines(exportMessage: exportMessage, crop: crop, frame: frame, times: times, fps: fps,
              counters: counters)[0]
    }

    /// The line at every length the status bar may show, longest first: the whole line,
    /// then the same line with one field dropped from its right end at a time, the counters
    /// first, then fps, the present, chain and decode times, the frame count and the crop, down
    /// to the first field alone. The bar shows the longest that fits the viewer column, so the
    /// readout never lays out past it, and the export outcome, the first field, goes last.
    ///
    /// With `performance` false (the default view: View > Performance Readout is off) the
    /// frame count, the times and the counters are left out, so the line is the export outcome
    /// and the crop only, or one empty string when neither is there.
    public static func lines(exportMessage: String?, crop: String?, frame: UInt64, times: FrameTimes,
                             fps: Double, counters: PreviewCounters, performance: Bool = true) -> [String] {
        let group = "    "
        func ms(_ v: Double, _ width: Int) -> String { pad(String(format: "%.1f", v), to: width) }
        func count(_ v: Int) -> String { pad(String(max(v, 0)), to: 3) }
        // Each field with the joiner that goes before it.
        var fields: [(joiner: String, text: String)] = []
        if let exportMessage { fields.append((group, exportMessage)) }
        if let crop { fields.append((group, crop)) }
        guard performance else {
            guard !fields.isEmpty else { return [""] }
            return (1...fields.count).reversed().map { n in
                fields.prefix(n).enumerated().map { i, f in i == 0 ? f.text : f.joiner + f.text }.joined()
            }
        }
        fields.append((group, Self.frame(frame)))
        fields.append((group, "d " + ms(times.decode, 4)))
        fields.append((separator, "c " + ms(times.chain, 4)))
        fields.append((separator, "p " + ms(times.present, 5) + " ms"))
        fields.append((separator, ms(fps, 4) + " fps"))
        fields.append((separator, "new \(count(counters.newFrames)) draw \(count(counters.draws))"
                       + " drw \(count(counters.drawables)) pres \(count(counters.presents))"))
        return (1...fields.count).reversed().map { n in
            fields.prefix(n).enumerated().map { i, f in i == 0 ? f.text : f.joiner + f.text }.joined()
        }
    }
}
