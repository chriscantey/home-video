import MetalKit
import HomeVideoCore
import SwiftUI

struct ContentView: View {
    let model: AppModel

    /// The video surround, the same near black the renderer clears to.
    static let surround = Color(.sRGB, red: 0.02, green: 0.02, blue: 0.025)

    @State private var viewerDropTargeted = false

    /// The narrowest the viewer column gets beside the sidebar, the transport's controls side by
    /// side in it without overlapping.
    static let minViewerWidth: CGFloat = 480
    /// The window's minimum content size: the left panel, the viewer column at its minimum and
    /// the sidebar with their two dividers is 958 pt, held up to 960 for the picture's margins.
    static let minWidth: CGFloat = max(960, LibraryPanel.width + 1 + minViewerWidth + 1 + ChainSidebar.width)
    static let minHeight: CGFloat = 600

    var body: some View {
        HStack(spacing: 0) {
            if model.libraryOpen {
                LibraryPanel(model: model)
                    .transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 0) {
                ViewerView(model: model)
                    // Finder URLs and Photos file promises, the same as the left panel.
                    .overlay(MovieDropOverlay(isTargeted: $viewerDropTargeted) { urls in urls.forEach(model.open) })
                Divider()
                TransportView(model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            Divider()
            ChainSidebar(model: model)
                .frame(width: ChainSidebar.width)
        }
        // For the left panel's slide in and out only: every column lays out inside its own
        // width, so nothing else is cut here.
        .clipped()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.libraryOpen.toggle() }
                } label: {
                    Label("Clips", systemImage: "sidebar.left")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Show or hide the open clips (Shift-Command-L)")
            }
            // Source, then Export, at the title bar's trailing end. Press and hold, not a toggle:
            // the chain comes back the
            // moment the mouse goes up, so it is a comparison rather than a mode left on. A drag
            // of zero distance rather than the button's action, which only reports a completed
            // click. Shown pressed while the source is up by either route, the M key included:
            // a button-style toggle whose binding only reads, so its own click changes nothing.
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { model.bypass }, set: { _ in })) {
                    Label("Source", systemImage: "rectangle.lefthalf.inset.filled")
                }
                    .toggleStyle(.button)
                    .disabled(model.source == nil)
                    .help("Hold to see and hear the source (M)")
                    .simultaneousGesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if model.source != nil, !model.bypass { model.bypass = true } }
                        .onEnded { _ in model.bypass = false })
            }
            // Export at the title bar's trailing end, beside the transport's button. Same action.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showExportPanel()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.source == nil || model.isExporting)
                .help("Export the shown clip, or the selected clips, through the VHS chain (Shift-Command-E)")
            }
        }
        .navigationTitle(model.source?.url.lastPathComponent ?? AppInfo.displayName)
        .sheet(item: Binding(get: { model.exportRequest }, set: { model.exportRequest = $0 })) { _ in
            ExportSheet(model: model)
        }
    }
}

/// Hosts the renderer's MTKView.
struct PreviewView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeNSView(context: Context) -> MTKView { renderer.makeView() }
    func updateNSView(_ nsView: MTKView, context: Context) {}
    static func dismantleNSView(_ nsView: MTKView, coordinator: ()) {}
}
