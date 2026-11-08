import AppKit
import HomeVideoCore
import SwiftUI

/// The left panel: every open clip as its poster with the name under it, the shown one
/// highlighted. Click shows a clip, right-click does the disk tasks and the settings
/// clipboard, a drop opens movies as the viewer does. A small heading, plain rows, one flat
/// menu with SF Symbols.
struct LibraryPanel: View {
    let model: AppModel

    static let width: CGFloat = 180
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clips")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            if model.clips.clips.isEmpty {
                Text("Drop movies here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.clips.clips.enumerated()), id: \.element.id) { i, clip in
                            ClipCell(clip: clip, isShown: i == model.clips.shownIndex,
                                     isSelected: model.clips.selection.contains(clip.id))
                                .contentShape(Rectangle())
                                // Command adds or removes a clip, Shift selects a run, as in Finder.
                                .onTapGesture { model.select(i, modifier: LibraryPanel.clickModifier()) }
                                .contextMenu { ClipMenu(model: model, clip: clip) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(MovieDropOverlay(isTargeted: $dropTargeted) { urls in urls.forEach(model.open) })
    }

    /// The modifier held during the click that is being handled, read from the click event
    /// itself (the keyboard's state now may already have changed).
    static func clickModifier() -> ClipList<FrameSource>.ClickModifier {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command) { return .command }
        if flags.contains(.shift) { return .shift }
        return .none
    }
}

/// One clip: its poster (or a placeholder while it loads) and its name.
private struct ClipCell: View {
    let clip: OpenClip
    let isShown: Bool
    /// In the panel's selection. The shown clip is always selected, and is the one with the
    /// accent border.
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                if let poster = clip.poster {
                    Image(decorative: poster, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 90)
            .opacity(clip.presence == .present ? 1 : 0.35)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isShown ? Color.accentColor : .white.opacity(0.1), lineWidth: isShown ? 2 : 1))
            .overlay(alignment: .bottom) {
                if let badge = clip.presence.badge {
                    Label(badge, systemImage: clip.presence == .missing ? "questionmark.folder" : "externaldrive.badge.xmark")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                        .padding(.bottom, 6)
                }
            }
            HStack(spacing: 4) {
                if clip.sidecar != nil {
                    // Edited: the clip has its own settings in a sidecar.
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                Text(clip.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The clip's path, then where its settings are kept.
    private var tooltip: String {
        var lines = [clip.url.path]
        if let badge = clip.presence.badge { lines.append("The file is \(badge == "missing" ? "missing" : "on a volume that is not mounted"). Its settings are kept.") }
        if let sidecar = clip.sidecar {
            lines.append(clip.sidecarIsFallback
                ? "Settings kept in Application Support, since the clip's folder is read only: \(sidecar.path)"
                : "Settings: \(sidecar.path)")
        }
        return lines.joined(separator: "\n")
    }

    private var accessibilityName: String {
        var parts = [clip.name]
        if clip.sidecar != nil { parts.append("edited") }
        if let badge = clip.presence.badge { parts.append(badge) }
        return parts.joined(separator: ", ")
    }
}

/// The right-click menu for one clip. Remove takes it out of the list, never off the disk.
private struct ClipMenu: View {
    let model: AppModel
    let clip: OpenClip

    var body: some View {
        Button("Reveal in Finder", systemImage: "folder") { model.revealInFinder(clip.url) }
            .disabled(clip.presence != .present)
        Button("Reveal Sidecar in Finder", systemImage: "doc.text.magnifyingglass") { model.revealSidecar(clip) }
            .disabled(clip.sidecar == nil)
        // With several clips selected and this one among them, Export takes them all.
        let count = model.exportTargets(clicked: clip.url).count
        Button(count > 1 ? "Export \(count) Clips…" : "Export…", systemImage: "square.and.arrow.up") {
            model.showExportPanel(for: clip.url)
        }
        .disabled(model.isExporting || clip.presence != .present)
        Divider()
        // Settings belong to the session, so Copy reads the chain whichever clip was clicked.
        Button("Copy Settings", systemImage: "doc.on.doc") { model.copySettings() }
        Button("Paste Settings", systemImage: "doc.on.clipboard") { model.pasteSettings() }
            .disabled(!model.canPasteSettings)
        Button("Forget Settings…", systemImage: "arrow.counterclockwise") { model.forgetSettings(clip) }
            .disabled(clip.sidecar == nil)
        Divider()
        Button("Remove from List", systemImage: "minus.circle") {
            if let i = model.clips.index(of: clip.url) { model.removeClip(at: i) }
        }
        .help("Close the clip in \(AppInfo.displayName). The file stays where it is.")
    }
}

/// A drop target for movies, laid over a SwiftUI view: Finder's file URLs and Photos' file
/// promises (`FilePromiseDrop`). It passes clicks through, so only drags reach it.
struct MovieDropOverlay: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.overlay = self
        return v
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.overlay = self
    }

    final class DropView: NSView {
        var overlay: MovieDropOverlay?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes(FilePromiseDrop.draggedTypes)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // Clicks, scrolls and right-clicks go to the views under it. Drags still find it,
        // since AppKit picks a drag destination by registered types, not by hitTest.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let ok = FilePromiseDrop.canAccept(sender.draggingPasteboard)
            overlay?.isTargeted = ok
            return ok ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            FilePromiseDrop.canAccept(sender.draggingPasteboard) ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            overlay?.isTargeted = false
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            overlay?.isTargeted = false
            let onDrop = overlay?.onDrop
            do {
                try FileManager.default.createDirectory(at: FilePromiseDrop.importsFolder,
                                                        withIntermediateDirectories: true)
            } catch {
                NSLog("Home Video: cannot create the imports folder: \(error)")
            }
            FilePromiseDrop.receive(from: sender.draggingPasteboard) { urls in
                guard !urls.isEmpty else { return }
                onDrop?(urls)
            }
            return true
        }
    }
}
