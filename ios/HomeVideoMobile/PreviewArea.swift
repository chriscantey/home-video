import MetalKit
import SwiftUI

/// The renderer's MTKView inside SwiftUI.
/// Each new surface takes the renderer's drawing. The editing screen's is kept on the model so
/// the drawing can come back to it when the full-screen cover over it closes.
struct PreviewSurface: UIViewRepresentable {
    let model: MobileModel
    var isMain = true

    func makeUIView(context: Context) -> MTKView {
        let v = model.renderer.makeView()
        if isMain {
            model.mainPreview = v
            // A new editor view (the layout changing as the phone turns) takes the drawing in
            // `makeView`. While full screen is up it gives it straight back.
            if let full = model.fullScreenPreview { model.renderer.attach(to: full) }
        } else {
            model.fullScreenPreview = v
        }
        return v
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}

/// The picture at the file's shape, with the Mac viewer's gestures done the iOS way: tap to
/// play or pause, drag to pan and pinch to zoom the Framing crop (or with the Display on, to
/// look up close at the tube), double tap to reset, touch and hold to see the source.
struct PreviewArea: View {
    let model: MobileModel
    /// Shows the button that opens the picture full screen.
    var enterFullScreen: (() -> Void)? = nil

    @State private var dragStart: (pan: Double, panY: Double, crop: CGRect)?
    @State private var zoomStart: Double?
    @State private var displayDragStart: CGPoint?
    @State private var displayZoomStart: Double?
    @State private var playFlash = false

    private var framing: FramingLayer { model.chain.framing }
    private var canMove: Bool { model.source != nil && framing.mode.movesWindow }
    private var movesDisplay: Bool { model.source != nil && model.chain.displayIsOn }

    /// The file's shape as shown: the raster's 10:11 pixels are 4:3, the rest square.
    private var aspect: CGFloat {
        SignalChain.displayAspect(model.chain.output, model.chain.outputSize)
    }

    var body: some View {
        PreviewSurface(model: model)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { GeometryReader { geo in gestureSurface(size: geo.size) } }
            .overlay(alignment: .bottomTrailing) {
                if let enterFullScreen {
                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: enterFullScreen)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .padding(10)
                        .accessibilityIdentifier("fullScreen")
                }
            }
            .overlay(alignment: .topLeading) {
                if model.bypass {
                    Label("Source", systemImage: "eye")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                        .padding(10)
                        .transition(.opacity)
                }
            }
            .overlay {
                if playFlash, let s = model.source {
                    Image(systemName: s.isPlaying ? "play.fill" : "pause.fill")
                        .font(.largeTitle)
                        .padding(22)
                        .glassEffect(.regular, in: Circle())
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.bypass)
            .accessibilityElement()
            .accessibilityLabel("Preview")
            .accessibilityValue(model.source?.isPlaying == true ? "Playing" : "Paused")
            .accessibilityHint("Tap to play or pause. Touch and hold to see the source.")
            .accessibilityAddTraits(.startsMediaSession)
            .accessibilityAction { togglePlay() }
            .accessibilityIdentifier("preview")
    }

    private func togglePlay() {
        guard let s = model.source else { return }
        s.togglePlay()
        withAnimation(.easeOut(duration: 0.15)) { playFlash = true }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeIn(duration: 0.25)) { playFlash = false }
        }
    }

    /// A clear layer over the picture that takes the gestures (the MTKView passes them through).
    private func gestureSurface(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(count: 2) {
                if movesDisplay { model.renderer.displayZoom.reset() } else if canMove { framing.resetCrop() }
            }
            .onTapGesture { togglePlay() }
            .onLongPressGesture(minimumDuration: 0.35) {
                model.bypass = true
            } onPressingChanged: { pressing in
                if !pressing { model.bypass = false }
            }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard size.width > 0, size.height > 0 else { return }
                let drag = CGVector(dx: v.translation.width / size.width, dy: v.translation.height / size.height)
                if movesDisplay {
                    if displayDragStart == nil { displayDragStart = model.renderer.displayZoom.center }
                    if let start = displayDragStart { model.renderer.displayZoom.pan(from: start, drag: drag) }
                    return
                }
                guard canMove else { return }
                if dragStart == nil { dragStart = (framing.pan, framing.panY, framing.cropRect) }
                guard let start = dragStart else { return }
                let d = FramingMath.panDelta(drag: drag, crop: start.crop)
                framing.setParameter("pan", to: .float(start.pan + Double(d.dx)))
                framing.setParameter("panY", to: .float(start.panY + Double(d.dy)))
            }
            .onEnded { _ in
                dragStart = nil
                displayDragStart = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if movesDisplay {
                    if displayZoomStart == nil { displayZoomStart = model.renderer.displayZoom.zoom }
                    model.renderer.displayZoom.setZoom((displayZoomStart ?? 1) * Double(v.magnification))
                    return
                }
                guard canMove else { return }
                if zoomStart == nil { zoomStart = framing.zoom }
                framing.setParameter("zoom", to: .float((zoomStart ?? 1) * Double(v.magnification)))
            }
            .onEnded { _ in
                zoomStart = nil
                displayZoomStart = nil
            }
    }
}

/// Under the picture: play and pause, the scrubber with its trim handles, and the time.
struct TransportBar: View {
    let model: MobileModel

    var body: some View {
        let s = model.source
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Button {
                    s?.togglePlay()
                } label: {
                    Image(systemName: s?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(s?.isPlaying == true ? "Pause" : "Play")
                .accessibilityIdentifier("playPause")
                TrimScrubber(model: model)
            }
            HStack {
                Text(Self.clock(s?.currentTime ?? 0))
                Spacer()
                if let trim = s?.trim {
                    Text("Trimmed \(Self.clock(trim.length)) of \(Self.clock(s?.duration ?? 0))")
                        .foregroundStyle(.tint)
                } else {
                    Text(Self.clock(s?.duration ?? 0))
                }
            }
            // One line on the narrowest bar (the Duo's full screen).
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 56)
        }
        .disabled(s == nil)
    }

    static func clock(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00.0" }
        let m = Int(t) / 60
        return String(format: "%d:%04.1f", m, t - Double(m * 60))
    }
}

/// The Mac's trim scrubber (`Sources/HomeVideo/TransportView.swift`) for a finger, drawn the
/// Mac's way: the whole track square ended and dimmed, the kept range brighter, and a thin
/// bracket at each end of the range with its feet turned in, so the handle and the track meet
/// with no rounded end beside it. Each bracket stands just outside its end, half a knob out, and
/// the track and the range run on to it, so the playhead's knob stops at the brackets' inner
/// edges and never shows past them. The playhead is a white knob, apart from the brackets in
/// shape and color. Drag the track to seek, drag a handle to trim.
/// The same view runs under the editor's picture and on full screen's bar.
struct TrimScrubber: View {
    let model: MobileModel
    @Environment(\.isEnabled) private var isEnabled

    private enum Grab { case track, inHandle, outHandle }
    @State private var grab: Grab?

    static let trackHeight: CGFloat = 6
    static let knob: CGFloat = 18
    static let bracketHeight: CGFloat = 28
    static let foot: CGFloat = 7
    /// The bracket's bar, as stroked.
    static let bar: CGFloat = 3
    /// How far from a bracket a press still takes it, a fingertip's reach.
    static let reach: CGFloat = 22

    var body: some View {
        let s = model.source
        let duration = max(s?.duration ?? 0, 0.001)
        let range = s?.trim ?? TrimRange(in: 0, out: duration)
        let now = s?.currentTime ?? 0
        GeometryReader { geo in
            // `x` is the knob's center. Room for half the knob and a bracket's bar at each end.
            let half = Self.knob / 2
            let inset = half + Self.bar
            let width = max(geo.size.width - 2 * inset, 1)
            let x = { (t: Double) -> CGFloat in inset + CGFloat(min(max(t / duration, 0), 1)) * width }
            let mid = geo.size.height / 2
            let trimmed = s?.trim != nil
            let inX = x(range.inPoint), outX = x(range.outPoint)
            // The brackets' centers: each bar's inner edge half a knob outside its end.
            let inBracket = inX - half - Self.bar + Self.foot / 2
            let outBracket = outX + half + Self.bar - Self.foot / 2
            ZStack(alignment: .topLeading) {
                // The whole clip, dimmed: what lies outside the range reads as cut. It runs as
                // far as the knob reaches, to the brackets' bars at the clip's ends.
                Rectangle()
                    .fill(Color.primary.opacity(isEnabled ? 0.10 : 0.05))
                    .frame(width: width + Self.knob, height: Self.trackHeight)
                    .position(x: inset + width / 2, y: mid)
                // The kept range, the part that plays and exports, from bracket to bracket.
                Rectangle()
                    .fill(Color.primary.opacity(isEnabled ? (trimmed ? 0.38 : 0.26) : 0.12))
                    .frame(width: max(outX - inX + Self.knob, 1), height: Self.trackHeight)
                    .position(x: (inX + outX) / 2, y: mid)
                ForEach([true, false], id: \.self) { isIn in
                    TrimBracket(isIn: isIn)
                        // `.tint`, not `Color.accentColor`, which a full screen cover reads as
                        // the system blue.
                        .stroke(trimmed ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.45)),
                                style: StrokeStyle(lineWidth: Self.bar, lineCap: .square, lineJoin: .miter))
                        .frame(width: Self.foot, height: Self.bracketHeight)
                        // The bar stands outside the range's end, the feet reach in over the
                        // track, above and below the knob.
                        .position(x: isIn ? inBracket : outBracket, y: mid)
                        .accessibilityHidden(true)
                }
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .frame(width: Self.knob, height: Self.knob)
                    .position(x: x(now), y: mid)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard let s = model.source, s.duration > 0 else { return }
                    let t = Double((v.location.x - inset) / width) * duration
                    if grab == nil {
                        // A press within a fingertip of a bracket takes the nearer one, else the
                        // track (the Mac's rule, at a finger's reach).
                        let px = v.startLocation.x
                        let dIn = abs(px - inBracket)
                        let dOut = abs(px - outBracket)
                        if min(dIn, dOut) <= Self.reach { grab = dIn <= dOut ? .inHandle : .outHandle } else { grab = .track }
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
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(TransportBar.clock(now)) of \(TransportBar.clock(duration))")
        .accessibilityAdjustableAction { direction in
            guard let s = model.source else { return }
            s.seek(to: now + (direction == .increment ? 1 : -1))
        }
        .accessibilityIdentifier("scrubber")
    }
}

/// A trim handle, the Mac's `Bracket`: a bar down the side toward the outside of the range and a
/// foot at the top and the bottom pointing in.
struct TrimBracket: Shape {
    let isIn: Bool
    func path(in r: CGRect) -> Path {
        let bar = isIn ? r.minX + 1.5 : r.maxX - 1.5
        let tip = isIn ? r.maxX : r.minX
        var p = Path()
        p.move(to: CGPoint(x: tip, y: r.minY + 1.5))
        p.addLine(to: CGPoint(x: bar, y: r.minY + 1.5))
        p.addLine(to: CGPoint(x: bar, y: r.maxY - 1.5))
        p.addLine(to: CGPoint(x: tip, y: r.maxY - 1.5))
        return p
    }
}
