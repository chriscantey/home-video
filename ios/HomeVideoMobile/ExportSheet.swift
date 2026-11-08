import SwiftUI

/// The export, as the Mac's sheet runs it, cut to what a phone needs: the size (SD by default,
/// HD and Phone, no 4K), the codec and its quality, the sound. Then the progress with Cancel,
/// then Saved to Photos with Share.
struct ExportSheet: View {
    let model: MobileModel
    @Environment(\.dismiss) private var dismiss
    /// The pinned Export to Photos bar's height, kept clear under the form's last row.
    @State private var barHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            Group {
                switch model.exportState {
                case .running(let p): progress(p)
                case .saved(let frames, let file): saved(frames: frames, file: file)
                default: form
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.isExporting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { close() }
                            .accessibilityIdentifier("exportClose")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isExporting)
        .sensoryFeedback(.success, trigger: model.exportsSaved)
    }

    private var title: String {
        switch model.exportState {
        case .running: "Exporting"
        case .saved: "Saved"
        default: "Export"
        }
    }

    private func close() {
        model.dismissExportResult()
        dismiss()
    }

    // MARK: The form

    private var form: some View {
        let output = model.chain.vhs?.output
        let s = model.exportSettings
        return Form {
            if let output {
                Section {
                    Picker(selection: Binding(get: { output.size }, set: {
                        output.setParameter("size", to: .choice($0.rawValue))
                    })) {
                        ForEach(MobileModel.outputSizes, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        Label("Size", systemImage: "rectangle.dashed")
                    }
                    .accessibilityIdentifier("exportSize")
                    if model.chain.fillApplies {
                        Picker(selection: Binding(get: { output.fill }, set: {
                            output.setParameter("fill", to: .bool($0))
                        })) {
                            Text("4:3 inside").tag(false)
                            Text("Fill the frame").tag(true)
                        } label: {
                            Label("Picture", systemImage: "aspectratio")
                        }
                    }
                } footer: {
                    Text(sizeCaption)
                }
            }
            Section {
                Picker(selection: Binding(get: { s.codec }, set: { c in
                    var n = model.exportSettings
                    n.setCodec(c)
                    n.container = c.containers[0]
                    model.exportSettings = n
                })) {
                    ForEach(MobileModel.codecs, id: \.self) { Text($0.name).tag($0) }
                } label: {
                    Label("Codec", systemImage: "film")
                }
                .accessibilityIdentifier("exportCodec")
                Picker(selection: Binding(get: { s.quality }, set: { model.exportSettings.quality = $0 })) {
                    ForEach(ExportQuality.allCases, id: \.self) { Text($0.name).tag($0) }
                } label: {
                    Label("Quality", systemImage: "dial.medium")
                }
            } footer: {
                Text(codecCaption(s.codec, s.quality))
                    .accessibilityIdentifier("codecCaption")
            }
            Section {
                let audio = model.chain.audio
                Picker(selection: Binding(get: { audio.track }, set: { audio.setTrack($0) })) {
                    ForEach(AudioTrack.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Label("Sound", systemImage: "waveform")
                }
                .disabled(!audio.tapeIsOn)
            } footer: {
                Text("The tape's sound track, as All Controls sets it under Audio.")
            }
        }
        // The Form does not take the pinned bar's inset at the sheet's medium height, so its
        // last rows would sit under the button. The bar's own height goes on as a bottom margin.
        .contentMargins(.bottom, barHeight, for: .scrollContent)
        // Pinned under the form, so it is in reach at the sheet's medium height too.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if case .failed(let why) = model.exportState {
                    Text("Export failed: \(why)").font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("exportStatus")
                } else if case .cancelled = model.exportState {
                    Text("Export canceled. Nothing was saved.").font(.footnote)
                        .accessibilityIdentifier("exportStatus")
                }
                Button {
                    model.export()
                } label: {
                    Label("Export to Photos", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.source == nil)
                .accessibilityIdentifier("exportStart")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            // A ground of its own, so rows that scroll under it do not show through.
            .background(.bar)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        }
    }

    /// The quality's data rate, or for ProRes the size warning: about how many gigabytes a
    /// minute of picture takes at the chosen size.
    private func codecCaption(_ codec: ExportCodec, _ quality: ExportQuality) -> String {
        let size = model.chain.outputSize
        guard codec.isProRes, let gb = MobileModel.proResGBPerMinute(codec, width: size.width, height: size.height) else {
            return quality.blurb(for: codec)
        }
        return "\(codec.blurb) About \(String(format: gb < 1 ? "%.1f" : "%.0f", gb)) GB a minute of picture at this size, in a QuickTime file. Check your free space."
    }

    private var sizeCaption: String {
        let size = model.chain.outputSize
        let s = ExportSettings(codec: model.exportSettings.codec, quality: model.exportSettings.quality,
                               container: model.exportSettings.codec.containers[0])
        var text = s.summary(size: size)
        if let trim = model.source?.trim {
            text += ", the trimmed \(TransportBar.clock(trim.length))"
        }
        return text + "."
    }

    // MARK: Progress and result

    private func progress(_ p: Double) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: p) {
                Text("Exporting")
            } currentValueLabel: {
                Text("\(Int(p * 100))%").monospacedDigit()
            }
            .accessibilityIdentifier("exportProgress")
            Text(model.chain.outputSize.width > 0 ? "\(model.chain.outputSize.width)×\(model.chain.outputSize.height)" : "")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { model.cancelExport() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityIdentifier("exportCancel")
            Spacer()
        }
        .padding(32)
    }

    private func saved(frames: Int, file: URL) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: model.exportsSaved)
                .accessibilityHidden(true)
            Text("Saved to Photos")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("exportStatus")
            Text("\(frames) frames, \(model.chain.outputSize.width)×\(model.chain.outputSize.height)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ShareLink(item: file) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("exportShare")
            Button("Done") { close() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityIdentifier("exportDone")
            Spacer()
        }
        .padding(32)
    }
}
