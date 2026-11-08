import HomeVideoCore
import SwiftUI

/// The transport under the picture: play and pause, the scrubber with its trim handles, the
/// clock and the Export button at the right end, then the source line and the last export's
/// outcome (the frame readout too when View > Performance Readout is on). Export runs what File > Export runs (the save panel, then the exporter with the
/// progress sheet and the outcome line), enabled when a clip is open and no export runs.
struct TransportView: View {
    let model: AppModel

    var body: some View {
        let source = model.source
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button {
                    source?.togglePlay()
                } label: {
                    Image(systemName: source?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 28, height: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(source == nil)
                .accessibilityLabel(source?.isPlaying == true ? "Pause" : "Play")

                TrimScrubber(model: model)
                    .disabled(source == nil)

                HStack(spacing: 0) {
                    Text(Self.clock(source?.currentTime ?? 0))
                    if let trim = source?.trim {
                        // The trimmed length beside the full one.
                        Text(" / \(Self.clock(trim.length))")
                            .foregroundStyle(Color.accentColor)
                            .help("The trimmed length, the part that plays and exports")
                        Text(" of \(Self.clock(source?.duration ?? 0))").foregroundStyle(.secondary)
                    } else {
                        Text(" / \(Self.clock(source?.duration ?? 0))").foregroundStyle(.secondary)
                    }
                }
                .font(.system(.body, design: .monospaced))

                Button("Export") { model.showExportPanel() }
                    .controlSize(.large)
                    .disabled(source == nil || model.isExporting)
                    .help("Export the shown clip, or the selected clips, through the VHS chain (File > Export)")
            }
            ViewerStatusBar(model: model)
        }
    }

    static func clock(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00.0" }
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }

    /// The source, then what the last stage writes: "720×480 raster" on the tape, else the Film
    /// scan's, the Display's, the camera's or the untouched source's size.
    static func describe(_ s: FrameSource, chain: SignalChain) -> String {
        var parts: [String] = []
        if s.naturalSize != .zero {
            parts.append("\(Int(s.naturalSize.width))×\(Int(s.naturalSize.height))")
        }
        if !s.codec.isEmpty { parts.append(s.codec) }
        if s.nominalFrameRate > 0 { parts.append(String(format: "%.2f fps source", s.nominalFrameRate)) }
        let size = chain.outputSize
        // A picked Output size is the file's size whatever the stages do, so name it the file
        // rather than the kind of picture, which could read "Display" with the Display off.
        let picked = !(chain.vhs?.output.isAuto ?? true)
        parts.append("\(size.width)×\(size.height) \(picked ? "file" : outputName(chain.output))")
        return parts.joined(separator: "  ·  ")
    }

    static func outputName(_ output: SignalChain.Output) -> String {
        switch output {
        case .raster: return "raster"
        case .scan: return "film scan"
        case .source: return "source"
        case .display: return "Display"
        case .camera: return "camera"
        }
    }
}

/// The scrubber with the trim: a track over the clip's duration, the playhead knob, and
/// two handles, in at the left and out at the right. Dragging the track seeks (inside the range,
/// `FrameSource.seek` snaps it in), dragging a handle moves that end.
///
/// The handles are brackets: a thin bar at each end of the range with a small foot at top and
/// bottom turned toward it, the
/// kept track a little brighter, the outside dimmed. Each bracket is drawn inside the handle
/// footprint (a handle's width outside each end of the range), which is where a press grabs it.
/// With no trim the brackets sit at the two ends in gray, so they stay findable.
struct TrimScrubber: View {
    let model: AppModel
    @Environment(\.isEnabled) private var isEnabled

    static let height: CGFloat = 22
    static let trackHeight: CGFloat = 6
    static let handleWidth: CGFloat = 8
    static let knob: CGFloat = 14

    /// Which part a drag started on, chosen once at the start of the drag.
    private enum Grab { case track, inHandle, outHandle }
    @State private var grab: Grab?

    var body: some View {
        let source = model.source
        let duration = max(source?.duration ?? 0, 0.001)
        let range = source?.trim ?? TrimRange(in: 0, out: duration)
        let now = source?.currentTime ?? 0
        GeometryReader { geo in
            // The handles stand outside the track's ends, so the track is inset by a handle.
            let inset = Self.handleWidth
            let width = max(geo.size.width - 2 * inset, 1)
            let x = { (t: Double) -> CGFloat in inset + CGFloat(min(max(t / duration, 0), 1)) * width }
            let mid = geo.size.height / 2
            let trimmed = source?.trim != nil
            let ends = Ends(lo: inset, hi: inset + width, inX: x(range.inPoint), outX: x(range.outPoint),
                            nowX: x(now), mid: mid, trimmed: trimmed)
            ZStack(alignment: .topLeading) {
                bracket(ends)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard let s = model.source, s.duration > 0 else { return }
                    let t = Double((v.location.x - inset) / width) * duration
                    if grab == nil {
                        // A press within a few points of a handle takes the handle, else the track.
                        let px = v.startLocation.x
                        let dIn = abs(px - (x(range.inPoint) - Self.handleWidth / 2))
                        let dOut = abs(px - (x(range.outPoint) + Self.handleWidth / 2))
                        if min(dIn, dOut) <= Self.handleWidth { grab = dIn <= dOut ? .inHandle : .outHandle } else { grab = .track }
                    }
                    switch grab {
                    case .inHandle:
                        model.setTrim(range.settingIn(t, duration: s.duration))
                        s.seek(to: s.playStart)
                    case .outHandle:
                        model.setTrim(range.settingOut(t, duration: s.duration))
                        s.seek(to: s.playEnd)
                    default:
                        s.seek(to: t)
                    }
                }
                .onEnded { _ in grab = nil })
        }
        .frame(height: Self.height)
        .frame(minWidth: 120)
        .accessibilityElement()
        .accessibilityLabel("Playhead and trim")
        .accessibilityValue("\(TransportView.clock(now)), in \(TransportView.clock(range.inPoint)), out \(TransportView.clock(range.outPoint))")
    }

    static func helpText(isIn: Bool) -> String {
        isIn ? "In point: drag, or press I at the playhead (Option-I clears)"
             : "Out point: drag, or press O at the playhead (Option-O clears)"
    }

    /// Where things fall on the x axis: the track's ends, the range's ends, the playhead, and the
    /// track's center line.
    private struct Ends {
        let lo, hi, inX, outX, nowX, mid: CGFloat
        let trimmed: Bool
    }

    /// A handle's color: accent once a trim is set, gray at the ends with none.
    private func handleColor(_ e: Ends) -> Color {
        e.trimmed ? Color.accentColor : Color.primary.opacity(0.35)
    }

    private func knob(at x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
            .frame(width: Self.knob, height: Self.knob)
            .position(x: x, y: y)
            .opacity(isEnabled ? 1 : 0.4)
    }

    /// The whole track dimmed, the kept part (the range that plays and exports) a little brighter,
    /// a thin bracket at each end of the range with its feet turned in.
    @ViewBuilder private func bracket(_ e: Ends) -> some View {
        let foot: CGFloat = 5
        Capsule()
            .fill(Color.primary.opacity(isEnabled ? 0.07 : 0.04))
            .frame(width: e.hi - e.lo, height: Self.trackHeight)
            .position(x: (e.lo + e.hi) / 2, y: e.mid)
        Rectangle()
            .fill(Color.primary.opacity(isEnabled ? (e.trimmed ? 0.30 : 0.20) : 0.10))
            .frame(width: max(e.outX - e.inX, 1), height: Self.trackHeight)
            .position(x: (e.inX + e.outX) / 2, y: e.mid)
        ForEach([true, false], id: \.self) { isIn in
            Bracket(isIn: isIn)
                .stroke(handleColor(e), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .opacity(isEnabled ? 1 : 0.4)
                .frame(width: foot, height: Self.height - 2)
                .contentShape(Rectangle())
                .help(Self.helpText(isIn: isIn))
                // The bar sits on the range's end, the feet reach into the range.
                .position(x: isIn ? e.inX - 1 + foot / 2 : e.outX + 1 - foot / 2, y: e.mid)
        }
        knob(at: e.nowX, y: e.mid)
    }

    /// The bracket's path: a bar down the side toward the outside, a foot at the top and the bottom.
    private struct Bracket: Shape {
        let isIn: Bool
        func path(in r: CGRect) -> Path {
            let bar = isIn ? r.minX + 1 : r.maxX - 1
            let tip = isIn ? r.maxX : r.minX
            var p = Path()
            p.move(to: CGPoint(x: tip, y: r.minY + 1))
            p.addLine(to: CGPoint(x: bar, y: r.minY + 1))
            p.addLine(to: CGPoint(x: bar, y: r.maxY - 1))
            p.addLine(to: CGPoint(x: tip, y: r.maxY - 1))
            return p
        }
    }
}
