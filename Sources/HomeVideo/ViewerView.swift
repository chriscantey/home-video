import AppKit
import HomeVideoCore
import SwiftUI

/// The picture: the 4:3 monitor on its surround (ContentView lays the panel's movie drop
/// overlay on it, which passes the mouse through), and under Center crop the
/// drag to pan, the pinch to zoom and the double-click that resets both. Its right-click menu
/// copies and pastes the chain's settings.
struct ViewerView: View {
    let model: AppModel

    /// Pan, panY and the crop window when the drag began, so the picture follows the cursor.
    @State private var dragStart: (pan: Double, panY: Double, crop: CGRect)?
    @State private var zoomStart: Double?
    /// A short line over the picture after a paste that failed or a copy, cleared after a moment.
    @State private var note: String?

    /// The Display zoom's center when the drag began, and its zoom when the pinch began.
    @State private var displayDragStart: CGPoint?
    @State private var displayZoomStart: Double?

    private var framing: FramingLayer { model.chain.framing }
    private var canMove: Bool { model.source != nil && framing.mode.movesWindow }
    /// With a CRT layer on the pinch and drag move the preview's window over the Display canvas
    /// (up close is where the tube shows), not the framing crop.
    private var movesDisplay: Bool { model.source != nil && model.chain.displayIsOn }

    /// The file's shape as shown: the raster's 10:11 pixels are 4:3, the rest square.
    private var outputAspect: CGFloat {
        let chain = model.chain
        return SignalChain.displayAspect(chain.output, chain.outputSize)
    }

    var body: some View {
        ZStack {
            ContentView.surround
            // The picture as a monitor, at the output's shape (4:3 for the raster, 16:9 for an
            // HD Output size): a hairline edge and a soft shadow on the near black surround.
            PreviewView(renderer: model.renderer)
                .aspectRatio(outputAspect, contentMode: .fit)
                .overlay { GeometryReader { geo in gestureSurface(size: geo.size) } }
                .overlay(Rectangle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.9), radius: 20, y: 6)
                .padding(24)
            if model.source == nil {
                Text("Drop a movie here, or choose File > Open")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let err = model.renderer.errorText ?? model.source?.loadError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if let note {
                Text(note)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 36)
            }
        }
        .contextMenu {
            Button("Copy Settings") { copySettings() }
            Button("Paste Settings") { pasteSettings() }
                .disabled(!ViewerView.pasteboardHasSettings())
        }
    }

    /// A clear layer over the picture that takes the gestures (the MTKView under it would
    /// otherwise take the mouse).
    private func gestureSurface(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(count: 2) {
                if movesDisplay { model.renderer.displayZoom.reset() } else if canMove { framing.resetCrop() }
            }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if movesDisplay {
                    guard size.width > 0, size.height > 0 else { return }
                    if displayDragStart == nil {
                        displayDragStart = model.renderer.displayZoom.center
                        NSCursor.closedHand.push()
                    }
                    guard let start = displayDragStart else { return }
                    model.renderer.displayZoom.pan(from: start, drag: CGVector(dx: v.translation.width / size.width,
                                                                               dy: v.translation.height / size.height))
                    return
                }
                guard canMove, size.width > 0, size.height > 0 else { return }
                if dragStart == nil {
                    dragStart = (framing.pan, framing.panY, framing.cropRect)
                    NSCursor.closedHand.push()
                }
                guard let start = dragStart else { return }
                let d = FramingMath.panDelta(drag: CGVector(dx: v.translation.width / size.width,
                                                            dy: v.translation.height / size.height),
                                             crop: start.crop)
                framing.setParameter("pan", to: .float(start.pan + Double(d.dx)))
                framing.setParameter("panY", to: .float(start.panY + Double(d.dy)))
            }
            .onEnded { _ in
                if dragStart != nil || displayDragStart != nil { NSCursor.pop() }
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

    static func pasteboardHasSettings() -> Bool { PasteboardSettingsClipboard().canPaste }

    private func copySettings() {
        PasteboardSettingsClipboard().copy(from: model.chain)
        show("Settings copied")
    }

    private func pasteSettings() {
        do {
            try PasteboardSettingsClipboard().pasteOrThrow(into: model.chain)
            show("Settings pasted")
        } catch {
            show("\(error)")
        }
    }

    private func show(_ text: String) {
        note = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if note == text { note = nil }
        }
    }
}

/// The general pasteboard behind Copy and Paste Settings, for the viewer's menu and the panel's
/// clip menu (`AppModel.settingsClipboard`): `SettingsClipboard`'s JSON as
/// `co.wonders.homevideo.settings`, with the same text as plain text beside it.
struct PasteboardSettingsClipboard: SettingsClipboarding {
    static let type = NSPasteboard.PasteboardType(SettingsClipboard.typeIdentifier)

    enum PasteError: Error, CustomStringConvertible {
        case empty
        var description: String { "Nothing to paste" }
    }

    func copy(from chain: SignalChain) {
        let json = SettingsClipboard.encode(chain)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: Self.type)
        pb.setString(json, forType: .string)
    }

    /// The custom type first, then plain text. A bad string throws and leaves the chain as it
    /// was.
    func pasteOrThrow(into chain: SignalChain) throws {
        let pb = NSPasteboard.general
        guard let json = [Self.type, .string].lazy
                .compactMap({ pb.string(forType: $0) }).first else {
            throw PasteError.empty
        }
        try SettingsClipboard.apply(json, to: chain)
    }

    func paste(into chain: SignalChain) {
        try? pasteOrThrow(into: chain)
    }

    var canPaste: Bool { NSPasteboard.general.availableType(from: [Self.type, .string]) != nil }
}

/// The line under the transport: the source on the left, then on the right the export outcome
/// and the live crop while it is moved. The frame count and the performance readout follow
/// only when View > Performance Readout is on, off by default. One line
/// of fixed height that never wraps: the right side is one `StatusReadout` string whose fields
/// are padded to their widest value, so it does not change width as the numbers tick, and it
/// truncates at its end when the window is too narrow. The source line has the higher layout
/// priority and keeps its place. The present error count lives in `perf.log` only.
struct ViewerStatusBar: View {
    let model: AppModel

    /// Taller than a caption line, so the row is the same height with or without text in it.
    static let height: CGFloat = 16

    var body: some View {
        let framing = model.chain.framing
        let renderer = model.renderer
        let crop = framing.mode.movesWindow && !framing.isCropAtDefault
            ? StatusReadout.crop(zoom: framing.zoom, pan: framing.pan, panY: framing.panY) : nil
        HStack(spacing: 16) {
            if let source = model.source {
                Text(TransportView.describe(source, chain: model.chain))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            // The longest form of the readout that fits beside the source line: fields
            // drop from the right as the column narrows, and the first field alone truncates.
            let lines = StatusReadout.lines(exportMessage: model.exportMessage, crop: crop,
                                            frame: renderer.presentedFrames, times: renderer.times,
                                            fps: renderer.fps, counters: renderer.counters,
                                            performance: model.showPerformanceReadout)
            ViewThatFits(in: .horizontal) {
                ForEach(lines, id: \.self) { Text($0).lineLimit(1).fixedSize() }
                Text(lines[lines.count - 1]).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
    }
}
