import MetalKit
import SwiftUI

/// The camera screen, full screen from the editor's "..." menu: the camera through the current
/// Look with the editor's own controls (the Look carousel and All Controls), the lens the iOS
/// Camera way (the device's lens buttons, pinch to zoom, tap to focus and expose), Framing's
/// crop on the picture and a record button. Debug builds add readouts for the frame rate, the
/// chain's time per frame, the camera to screen lag and the frames dropped, so a test screenshot
/// carries the numbers. Release builds never show them.
/// Upright, the controls sit under the picture and All Controls opens as the editor's own sheet,
/// with the picture still in view. On its side, they fill the editor's column beside the picture,
/// Simple or All.
struct CameraView: View {
    let model: MobileModel
    /// The editor's appearance, for the All Controls sheet. The camera itself is always dark.
    var sheetScheme: ColorScheme? = nil
    let close: () -> Void
    @State private var camera: CameraModel?
    @State private var showAll = false
    /// Drag and pinch move Framing's crop instead of the lens.
    @State private var cropMode = false
    @State private var focusPoint: CGPoint?
    @State private var focusShown = 0
    @State private var pinchStart: CGFloat?
    @State private var dragStart: (pan: Double, panY: Double, crop: CGRect)?
    @State private var framingZoomStart: Double?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let camera {
                content(camera)
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        // A full screen cover does not inherit the window's tint.
        .tint(HomeVideoMobileApp.pink)
        .task {
            let c = CameraModel(model: model)
            camera = c
            await c.open()
        }
        .onDisappear { camera?.close() }
        .sensoryFeedback(.start, trigger: camera?.isRecording == true)
        // A turn from one landscape to the other keeps the size, so the turn itself is watched
        // too. The interface follows the device a moment later, so it is read twice.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            screenMayHaveTurned()
        }
    }

    private func screenMayHaveTurned() {
        camera?.screenTurned()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            camera?.screenTurned()
        }
    }

    @ViewBuilder private func content(_ camera: CameraModel) -> some View {
        switch camera.state {
        case .noCamera:
            message("No camera available", "video.slash",
                    "This device has no camera Home Video can use. The Simulator has none.")
        case .denied(let text):
            message("Camera Not Allowed", "video.slash", text)
        case .failed(let text):
            message("The Camera Stopped", "exclamationmark.triangle", text)
        default:
            live(camera)
        }
    }

    private func message(_ title: String, _ symbol: String, _ text: String) -> some View {
        VStack {
            HStack {
                closeButton(nil)
                Spacer()
            }
            .padding(.horizontal, Margins.side)
            ContentUnavailableView(title, systemImage: symbol, description: Text(text))
                .foregroundStyle(.white)
                .accessibilityIdentifier("cameraMessage")
            Spacer()
        }
    }

    // MARK: Layouts

    private func live(_ camera: CameraModel) -> some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.1
            Group {
                if wide { wideLayout(camera) } else { tallLayout(camera) }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { _ in
                screenMayHaveTurned()
            }
            .sheet(isPresented: Binding(get: { showAll && !wide }, set: { if !$0 { showAll = false } })) {
                AllControlsSheet(model: model, scheme: sheetScheme, canShuffle: !camera.isRecording)
            }
        }
    }

    /// Upright: the readouts, the picture, then the editor's Look header and carousel, and the
    /// buttons under it.
    private func tallLayout(_ camera: CameraModel) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                closeButton(camera)
                Spacer()
                #if DEBUG
                readout(camera)
                #endif
            }
            .padding(.horizontal, Margins.side)
            .padding(.bottom, 8)
            picture(camera)
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    LookHeader(model: model, canShuffle: !camera.isRecording)
                    LookCarousel(model: model, carousel: LookStills.camera)
                        .disabled(camera.isRecording)
                }
                status(camera)
                buttons(camera, allControls: true)
                    .padding(.horizontal, Margins.side)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    /// On its side: the picture, and the editor's column with Simple (the editor's panel, its
    /// Framing on the live crop) or All (every control inline), the record button always at its
    /// foot.
    private func wideLayout(_ camera: CameraModel) -> some View {
        HStack(spacing: 0) {
            picture(camera)
                .overlay(alignment: .topLeading) {
                    HStack(alignment: .top) {
                        closeButton(camera)
                        #if DEBUG
                        readout(camera)
                        #endif
                    }
                    .padding(10)
                }
            VStack(spacing: 0) {
                Picker("Controls", selection: $showAll) {
                    Text("Simple").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Margins.side)
                .padding(.vertical, 8)
                .accessibilityIdentifier("cameraControlsMode")
                if showAll {
                    AllControlsView(model: model, inSheet: false, canShuffle: !camera.isRecording)
                        .disabled(camera.isRecording)
                } else {
                    ScrollView {
                        SimplePanel(model: model, canShuffle: !camera.isRecording, carousel: LookStills.camera) { showAll = true }
                            .disabled(camera.isRecording)
                    }
                }
                status(camera)
                    .padding(.top, 6)
                buttons(camera, allControls: false)
                    .padding(.horizontal, Margins.side)
                    .padding(.vertical, 8)
            }
            .frame(width: ContentView.columnWidth)
            .background(Color(white: 0.11))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cameraColumn")
        }
    }

    // MARK: The picture

    /// The live picture with its gestures: tap to focus and expose, pinch to zoom the lens, and
    /// in crop mode drag and pinch to move Framing's crop (double tap resets it). The lens
    /// buttons sit on the picture's foot, as in the iOS Camera.
    private func picture(_ camera: CameraModel) -> some View {
        GeometryReader { geo in
            CameraPreview(camera: camera)
                .accessibilityIdentifier("cameraPreview")
                .overlay { gestureSurface(camera, size: geo.size) }
                .overlay {
                    if let p = focusPoint {
                        FocusSquare()
                            .position(p)
                            .id(focusShown)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    if cropMode {
                        Label("Drag and pinch to frame", systemImage: "crop")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .glassEffect(.regular, in: Capsule())
                            .padding(.top, 8)
                            .accessibilityIdentifier("cropHint")
                    }
                }
                .overlay(alignment: .bottom) {
                    if let lens = camera.lens, !cropMode {
                        LensButtons(lens: lens, zoom: camera.zoom) { camera.setZoom($0, animated: true) }
                            .padding(.bottom, 10)
                    }
                }
        }
    }

    private func pictureRect(_ size: CGSize) -> CGRect {
        let chain = model.chain
        let aspect = chain.output.isSquare
            ? CGFloat(chain.outputSize.width) / CGFloat(chain.outputSize.height) : FramingMath.rasterDisplayAspect
        return FramingMath.fit(aspect: aspect, in: size)
    }

    private func gestureSurface(_ camera: CameraModel, size: CGSize) -> some View {
        let framing = model.chain.framing
        return Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        guard cropMode, framing.mode.movesWindow else { return }
                        let r = pictureRect(size)
                        guard r.width > 0, r.height > 0 else { return }
                        if dragStart == nil { dragStart = (framing.pan, framing.panY, framing.cropRect) }
                        guard let start = dragStart else { return }
                        let drag = CGVector(dx: v.translation.width / r.width, dy: v.translation.height / r.height)
                        let d = FramingMath.panDelta(drag: drag, crop: start.crop)
                        framing.setParameter("pan", to: .float(start.pan + Double(d.dx)))
                        framing.setParameter("panY", to: .float(start.panY + Double(d.dy)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if cropMode {
                            guard framing.mode.movesWindow else { return }
                            if framingZoomStart == nil { framingZoomStart = framing.zoom }
                            let z = min(max((framingZoomStart ?? 1) * v.magnification, 1), 2)
                            framing.setParameter("zoom", to: .float(z))
                        } else {
                            if pinchStart == nil { pinchStart = camera.zoom }
                            camera.setZoom((pinchStart ?? 1) * v.magnification, animated: false)
                        }
                    }
                    .onEnded { _ in
                        pinchStart = nil
                        framingZoomStart = nil
                    }
            )
            .onTapGesture(count: 2) { if cropMode { framing.resetCrop() } }
            .onTapGesture { location in
                guard !cropMode else { return }
                _ = camera.focus(at: location, in: size)
                focusPoint = location
                focusShown += 1
                let shown = focusShown
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if focusShown == shown { focusPoint = nil }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Camera picture")
            .accessibilityHint("Tap to focus. Pinch to zoom.")
            .accessibilityIdentifier("cameraSurface")
    }

    // MARK: Bars

    private func closeButton(_ camera: CameraModel?) -> some View {
        Button("Close", systemImage: "xmark") {
            camera?.close()
            close()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .disabled(camera?.isRecording == true || camera?.state == .saving)
        .accessibilityIdentifier("cameraClose")
    }

    #if DEBUG
    /// Test builds only: the numbers, for the UI tests and their screenshots.
    private func readout(_ camera: CameraModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(camera.readout)
            // The zoom always with one decimal, so the line keeps its width as it changes.
            Text("heat \(camera.thermalText) · zoom \(String(format: "%.1f", camera.zoom * (camera.lens?.displayMultiplier ?? 1)))×"
                 + (camera.usingFixture ? " · test feed" : ""))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5), in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cameraReadout")
        .overlay(alignment: .topLeading) { ProbeLabel(id: "stillsTiming", text: model.stills.debugTiming) }
    }
    #endif

    /// The recording clock, the saved message, or the format the camera records in.
    @ViewBuilder private func status(_ camera: CameraModel) -> some View {
        switch camera.state {
        case .recording:
            Text(Self.clock(camera.recordSeconds))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.red, in: .capsule)
                .accessibilityIdentifier("cameraClock")
        case .saving:
            Text("Saving…").foregroundStyle(.white)
        case .saved(let frames, let dropped):
            Button {
                camera.dismissResult()
            } label: {
                #if DEBUG
                Text("Saved to Photos · \(frames) frames, \(dropped) dropped")
                    .font(.footnote)
                #else
                Text("Saved to Photos")
                    .font(.footnote)
                #endif
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("cameraSaved")
        default:
            Text("\(model.exportSettings.codec.name) · \(Self.sizeText(model.chain.outputSize))")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Crop on the left, the record button in the middle, All Controls on the right (upright).
    private func buttons(_ camera: CameraModel, allControls: Bool) -> some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { cropMode.toggle() }
            } label: {
                Label("Crop", systemImage: "crop")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(cropMode ? HomeVideoMobileApp.pink : nil)
            .accessibilityValue(cropMode ? "On" : "Off")
            .accessibilityIdentifier("cameraCrop")
            Spacer()
            Button {
                if camera.isRecording { camera.stopRecording() } else { camera.startRecording() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                    if camera.isRecording {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 28, height: 28)
                    } else {
                        Circle().fill(.red).frame(width: 58, height: 58)
                    }
                }
            }
            .disabled(camera.state == .saving || camera.state == .starting)
            .accessibilityLabel(camera.isRecording ? "Stop Recording" : "Record")
            .accessibilityIdentifier("cameraRecord")
            Spacer()
            if allControls {
                Button("All Controls", systemImage: "slider.horizontal.3") { showAll = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(camera.isRecording)
                    .accessibilityIdentifier("cameraAllControls")
            } else {
                // Keeps the record button centered.
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func sizeText(_ s: (width: Int, height: Int)) -> String { "\(s.width) × \(s.height)" }
}

/// The lens buttons, as the iOS Camera shows them: one per stop the device offers, labeled by
/// the factor the Camera app uses (0.5, 1, 2, 5). The one in use shows the zoom now.
private struct LensButtons: View {
    let lens: CameraLens
    let zoom: CGFloat
    let choose: (CGFloat) -> Void

    var body: some View {
        let stops = lens.stops
        let active = stops.lastIndex { $0 <= zoom + 0.01 } ?? 0
        HStack(spacing: 4) {
            ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                let name = Self.text(stop * lens.displayMultiplier)
                Button {
                    choose(stop)
                } label: {
                    // A fixed size: the active button reads the zoom as it changes ("1.4×"), and
                    // a growing button would move its row on a pinch.
                    Text(i == active ? Self.text(zoom * lens.displayMultiplier) + "×" : name)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(i == active ? Color.yellow : .white)
                        .frame(width: 38, height: 34)
                        .background(.black.opacity(i == active ? 0.6 : 0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(name)")
                .accessibilityAddTraits(i == active ? .isSelected : [])
                .accessibilityIdentifier("zoom-\(name)")
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: Capsule())
    }

    /// 0.5, 1, 2, 5, or one decimal off a stop (1.4).
    static func text(_ x: CGFloat) -> String {
        let r = (x * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}

/// The square where a tap set focus and exposure.
private struct FocusSquare: View {
    @State private var settled = false

    var body: some View {
        Rectangle()
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? 1 : 1.4)
            .opacity(settled ? 1 : 0.4)
            .onAppear { withAnimation(.easeOut(duration: 0.25)) { settled = true } }
            .accessibilityElement()
            .accessibilityLabel("Focus")
            .accessibilityIdentifier("cameraFocus")
    }
}

/// The MTKView the camera draws into. Its draw runs the waiting frame (explicit drawing: the
/// camera's frame arrival, not a display link, decides when a picture is drawn).
private struct CameraPreview: UIViewRepresentable {
    let camera: CameraModel

    final class View: MTKView {
        var onDraw: (() -> Void)?
        override func draw(_ rect: CGRect) { onDraw?() }
    }

    func makeUIView(context: Context) -> View {
        let v = View(frame: .zero, device: camera.model.renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.clearColor = PreviewRenderer.surround
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        v.presentsWithTransaction = false
        v.autoResizeDrawable = true
        (v.layer as? CAMetalLayer)?.maximumDrawableCount = 3
        let c = camera
        v.onDraw = { [weak c] in c?.drawFromView() }
        camera.view = v
        return v
    }

    func updateUIView(_ uiView: View, context: Context) {}
}
