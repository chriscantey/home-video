import AppKit
import HomeVideoCore
import SwiftUI

/// The export sheet, in front of every Export (File > Export, the transport, the title bar
/// and the panel's right-click): a header naming what is exported, a grouped form with one picker
/// per choice and an info icon per row, then Export
/// and Cancel. On Export the same sheet shows the progress (per clip and in total for
/// several), then a summary of the files written. The choices are stored as preferences
/// (`ExportSettings`, one `UserDefaults` key), never in a sidecar.
struct ExportSheet: View {
    let model: AppModel

    private var clips: [URL] { model.exportRequest?.clips ?? [] }
    private var queue: ExportQueue? { model.exportQueue }
    private var finished: Bool { queue?.isFinished ?? false }
    private var running: Bool { model.isExporting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if finished {
                summary
            } else if let queue, running {
                progress(queue)
            } else {
                form
            }
            Divider()
            buttons
        }
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(clips.count == 1 ? clips[0].lastPathComponent : "\(clips.count) clips")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(16)
    }

    private var title: String {
        if finished { return queue?.isCancelled == true ? "Export cancelled" : "Export finished" }
        return running ? "Exporting" : "Export"
    }

    // MARK: Settings

    private var codecBinding: Binding<ExportCodec> {
        Binding(get: { model.exportSettings.codec }, set: { c in
            model.exportSettings.setCodec(c)
            model.exportSettingsChanged()
        })
    }

    private var qualityBinding: Binding<ExportQuality> {
        Binding(get: { model.exportSettings.quality }, set: { model.exportSettings.quality = $0 })
    }

    private var containerBinding: Binding<ExportContainer> {
        Binding(get: { model.exportSettings.container }, set: { c in
            model.exportSettings.container = c
            model.exportSettingsChanged()
        })
    }

    private var unavailable: [ExportCodec] {
        ExportCodec.allCases.filter { !ExportCodecAvailability.available.contains($0) }
    }

    private var form: some View {
        let s = model.exportSettings
        return Form {
            Section {
                Picker(selection: codecBinding) {
                    ForEach(ExportCodec.allCases, id: \.self) { c in
                        let ok = ExportCodecAvailability.available.contains(c)
                        Text(ok ? c.name : "\(c.name) (not on this Mac)").tag(c).disabled(!ok)
                    }
                } label: {
                    Label { infoTitle("Codec", codecInfo) } icon: { Image(systemName: "film") }
                }
                // ProRes has one data rate per flavor, so its row shows that, grayed.
                Picker(selection: qualityBinding) {
                    if s.codec.hasQuality {
                        ForEach(ExportQuality.allCases, id: \.self) { q in Text(q.name).tag(q) }
                    } else {
                        Text("Set by the codec").tag(s.quality)
                    }
                } label: {
                    Label { infoTitle("Quality", s.quality.blurb(for: s.codec)) }
                        icon: { Image(systemName: "slider.horizontal.3") }
                }
                .disabled(!s.codec.hasQuality)
                Picker(selection: containerBinding) {
                    ForEach(s.codec.containers, id: \.self) { c in Text(c.name).tag(c) }
                } label: {
                    Label { infoTitle("Container", containerInfo) } icon: { Image(systemName: "shippingbox") }
                }
                .disabled(s.codec.containers.count == 1)
                // The size the file is written at, the last stage's: 720×480 on the tape.
                LabeledContent {
                    Text(pictureText).foregroundStyle(.secondary)
                } label: {
                    Label { infoTitle("Picture", ExportSheet.pictureInfo) } icon: { Image(systemName: "rectangle") }
                }
                // No Audio row: the sheet names no other stage's
                // settings, so the sound's would read as the only one. It follows the chain as the picture does.
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(destinationText)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .help(destinationHelp)
                        Button("Choose…") { model.chooseExportDestination() }
                    }
                } label: {
                    Label { infoTitle("To", namingInfo) } icon: { Image(systemName: "folder") }
                }
            } footer: {
                if let blocker = model.exportBlocker {
                    Text(blocker).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var codecInfo: String {
        var text = model.exportSettings.codec.blurb
        if !unavailable.isEmpty {
            text += " Grayed out: \(unavailable.map(\.name).joined(separator: ", ")). "
                + ExportCodecAvailability.unavailableNote
        }
        return text
    }

    private var containerInfo: String {
        model.exportSettings.codec.isProRes
            ? "ProRes is written only into a QuickTime movie."
            : "MPEG-4 plays on the most devices. QuickTime holds the same picture."
    }

    private var destinationText: String {
        if clips.count == 1 { return model.exportFile?.lastPathComponent ?? "Choose a file" }
        return model.exportFolder?.path ?? "Choose a folder"
    }

    private var destinationHelp: String {
        clips.count == 1 ? model.exportFile?.path ?? "" : model.exportFolder?.path ?? ""
    }

    private var namingInfo: String {
        let ext = model.exportSettings.container.fileExtension
        let rule = "Each file is named <clip> \(ExportSettings.nameWord) <date and time>.\(ext). "
            + "When that name is already in the folder a 2 or 3 is added, so nothing is replaced."
        guard let folder = model.exportFile?.deletingLastPathComponent() ?? model.exportFolder else { return rule }
        return rule + " Folder: \(folder.path)"
    }

    // MARK: Progress

    private func progress(_ q: ExportQueue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if q.items.count == 1 {
                Text(q.items[0].destination.lastPathComponent)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                ProgressView(value: q.itemProgress)
                Text("\(Int(q.itemProgress * 100))%  ·  \(model.exportSummary)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else {
                let i = q.currentIndex ?? q.settledCount
                Text(i < q.items.count ? q.items[i].source.lastPathComponent : "")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                ProgressView(value: q.itemProgress)
                Text("This clip \(Int(q.itemProgress * 100))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                ProgressView(value: q.totalProgress)
                Text("\(min(i + 1, q.items.count)) of \(q.items.count), \(Int(q.totalProgress * 100))%  ·  "
                     + model.exportSummary)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    // MARK: Summary

    private var summary: some View {
        Form {
            Section {
                if let q = queue {
                    ForEach(Array(q.items.enumerated()), id: \.offset) { i, item in
                        LabeledContent {
                            Text(outcomeText(q.outcomes[i]))
                                .foregroundStyle(isWritten(q.outcomes[i]) ? Color.secondary : Color.orange)
                                .monospacedDigit()
                        } label: {
                            Text(item.destination.lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                                .help(item.destination.path)
                        }
                    }
                    if let first = q.written.first {
                        LabeledContent("To") {
                            Text(first.item.destination.deletingLastPathComponent().path)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 320, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func isWritten(_ o: ExportQueue.Outcome) -> Bool {
        if case .written = o { return true }
        return false
    }

    private func outcomeText(_ o: ExportQueue.Outcome) -> String {
        switch o {
        case .written(let f): return "\(f) frames"
        case .failed(let e): return "Failed: \(e)"
        case .cancelled: return "Cancelled, removed"
        case .skipped: return "Not exported"
        case .pending, .running: return ""
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            if finished, let q = queue, !q.written.isEmpty {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(q.written.map(\.item.destination))
                }
            }
            Spacer()
            if finished {
                Button("Done") { model.closeExportSheet() }.keyboardShortcut(.defaultAction)
            } else if running {
                // The frame in flight finishes before the export stops, so the button says so.
                Button(queue?.isCancelled == true ? "Stopping…" : "Cancel") { model.cancelExport() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(queue?.isCancelled == true)
            } else {
                Button("Cancel", role: .cancel) { model.closeExportSheet() }.keyboardShortcut(.cancelAction)
                Button("Export") { model.startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.exportBlocker != nil)
            }
        }
        .padding(16)
    }

    // MARK: Info

    private var pictureText: String {
        let size = model.chain.outputSize
        return "\(size.width)×\(size.height) \(TransportView.outputName(model.chain.output))"
    }

    static let pictureInfo = "The file's size is the last stage's: the tape's 720×480 raster shown 4:3, a film scan, the Display's canvas, the camera's frame, or with every stage off the source's own size."

    private func infoTitle(_ title: String, _ info: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            InfoGlyph(text: info)
        }
    }
}

/// An info icon after a row's title: its text on hover, and in a popover on click.
private struct InfoGlyph: View {
    let text: String
    @State private var showsPopover = false

    var body: some View {
        Button { showsPopover.toggle() } label: {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel(text)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
    }
}
