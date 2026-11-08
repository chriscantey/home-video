import AppKit
import HomeVideoCore
import SwiftUI

/// Help > Export Log…: the last 24 hours of `~/Library/Logs/Home Video/export.log`,
/// newest at the top, in a monospaced read-only text that can be selected and copied, so
/// anyone reporting a problem can send what happened. The log is already a file, so the window shows it and
/// Reveal in Finder hands it over. Reloads on open, on Refresh and when an export queue ends.
struct ExportLogView: View {
    static let windowID = "export-log"
    static let hours = 24

    let model: AppModel
    @State private var lines: [ExportLog.Line] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // Empty, the text area itself says so, so the top line names only the span.
                Text(lines.isEmpty ? "Last \(Self.hours) hours" : ExportLog.summary(lines, hours: Self.hours))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", action: reload)
                    .keyboardShortcut("r")
                    .help("Read the log again")
            }
            if lines.isEmpty {
                Text("No exports in the last \(Self.hours) hours")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .border(Color(nsColor: .separatorColor))
            } else {
                // A few lines would sit in the middle of the scroll view, so the text is at least
                // the view's size and pinned to its top left.
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(8)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color(nsColor: .separatorColor))
            }
            HStack {
                Button("Reveal in Finder", action: reveal)
                    .help(ExportLog.shared.url.path)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(lines.isEmpty)
                .help("Copy these lines, to paste into a message")
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 300)
        .onAppear(perform: reload)
        .onChange(of: model.exportLogGeneration) { reload() }
    }

    private var text: String { lines.map(\.text).joined(separator: "\n") }

    private func reload() {
        lines = ExportLog.recent(hours: Double(Self.hours))
    }

    /// Selects the file in Finder, or opens its folder when no export has written it yet.
    private func reveal() {
        let url = ExportLog.shared.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

/// Help > Export Log…, beside the system's Help item.
/// Help > Acknowledgements: opens `Contents/Resources/Licenses` (the app's GPL-3 license and
/// Sparkle's, written there by tools/bundle-app.sh) in Finder. Absent on a run with no bundle.
struct AcknowledgementsCommand: View {
    static var folder: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var body: some View {
        if let folder = Self.folder {
            Button("Acknowledgements") { NSWorkspace.shared.open(folder) }
                .help("The licenses of Home Video and the open source code it ships with")
        }
    }
}

struct ExportLogCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Export Log…") { openWindow(id: ExportLogView.windowID) }
            .help("Show the last \(ExportLogView.hours) hours of export.log, to send with a problem report.")
    }
}
