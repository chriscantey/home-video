import AppKit
import HomeVideoCore
import SwiftUI
import UniformTypeIdentifiers

/// One stage's preset menu, for the top of that stage's controls: the stage's built-ins,
/// then under a separator the user's own, then a row of Save, Rename, Delete, Import and Export
/// for that stage alone, drawn like the Look's picker and icon row (a 9 pt word under every
/// glyph, no tooltips). Choosing a preset changes its stage and nothing else.
/// The label reads the preset the stage matches now, else Custom.
struct StagePresetMenu: View {
    let stage: Stage
    let model: AppModel
    @State private var renaming: StagePreset?
    @State private var deleting: StagePreset?

    static let fileType = UTType(filenameExtension: StagePresets.fileExtension, conformingTo: .json) ?? .json

    var body: some View {
        let store = model.stagePresets
        let current = store.matching(stage, in: model.chain)
        let order = store.presets(for: stage)
        let mine = current.flatMap { $0.isBuiltIn ? nil : $0 }
        VStack(alignment: .leading, spacing: 8) {
            Picker("\(stage.title) preset", selection: Binding(get: { current?.id ?? "" }, set: { choose($0) })) {
                if current == nil { Text("Custom").tag("") }
                ForEach(order.builtIn) { Text($0.name).tag($0.id) }
                if !order.user.isEmpty {
                    Divider()
                    ForEach(order.user) { Text($0.name).tag($0.id) }
                }
            }
            .sidebarMenu()
            .labelsHidden()
            .accessibilityLabel("\(stage.title) preset")
            HStack(spacing: 4) {
                icon("plus", "Save \(stage.title) Preset", word: "Save") { save(current: mine) }
                icon("pencil", "Rename \(stage.title) Preset", word: "Rename", disabled: mine == nil) { renaming = mine }
                icon("trash", "Delete \(stage.title) Preset", word: "Delete", disabled: mine == nil) { deleting = mine }
                Spacer(minLength: 4)
                icon("square.and.arrow.down", "Import \(stage.title) Preset", word: "Import", width: 26) { importFile() }
                icon("square.and.arrow.up", "Export \(stage.title) Preset", word: "Export", width: 26) { export(current) }
            }
            .buttonStyle(.borderless)
            .tint(Color.secondary)
        }
        .sheet(item: $renaming) { p in
            RenameStagePresetSheet(preset: p) { rename(p, to: $0) }
        }
        .confirmationDialog("Delete the \(stage.title) preset “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { p in
            Button("Delete", role: .destructive) { delete(p) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("\(p.url?.lastPathComponent ?? p.name) is removed from the \(stage.title) presets. The \(stage.title) stage keeps its values.")
        }
    }

    /// One glyph with its word, the Look row's `icon` at the same sizes.
    private func icon(_ symbol: String, _ label: String, word: String, width: CGFloat = 22,
                      disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).frame(width: width, height: 18)
                Text(word)
                    .font(.system(size: 9))
                    .foregroundStyle(disabled ? HierarchicalShapeStyle.tertiary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .disabled(disabled)
    }

    // MARK: - Actions

    private func choose(_ id: String) {
        let order = model.stagePresets.presets(for: stage)
        guard let p = (order.builtIn + order.user).first(where: { $0.id == id }) else { return }
        do { try model.stagePresets.apply(p, to: model.chain) } catch { report(error) }
    }

    private func save(current: StagePreset?) {
        let alert = NSAlert()
        alert.messageText = "Save \(stage.title) Preset"
        alert.informativeText = "Saves the \(stage.title) stage alone as a preset in its menu. A preset of the same name is replaced."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        field.stringValue = current?.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try model.stagePresets.save(name: field.stringValue, stage: stage, chain: model.chain) } catch { report(error) }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a \(stage.title) preset to add to the \(stage.title) menu"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let p = try model.stagePresets.import(from: url, as: stage)
            try model.stagePresets.apply(p, to: model.chain)
        } catch {
            report(error)
        }
    }

    /// Writes the shown preset out (a user's file as it is, a built-in from its values), or the
    /// stage as it stands when it reads Custom.
    private func export(_ shown: StagePreset?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = (shown?.name ?? "Custom \(stage.title)") + "." + StagePresets.fileExtension
        panel.message = "Export the \(stage.title) preset to a file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let shown {
                try model.stagePresets.export(shown, to: url)
            } else {
                try model.stagePresets.write(name: url.deletingPathExtension().lastPathComponent, stage: stage,
                                             chain: model.chain, to: url)
            }
        } catch {
            report(error)
        }
    }

    private func rename(_ p: StagePreset, to name: String) {
        do {
            let renamed = try model.stagePresets.rename(p, to: name)
            if renamed.name != p.name { model.showToast("Renamed to \(renamed.name)") }
        } catch {
            model.showToast("Could not rename \(p.name): \(Self.shortReason(error))")
        }
    }

    private func delete(_ p: StagePreset) {
        do {
            try model.stagePresets.delete(p)
            model.showToast("Deleted \(p.name)")
        } catch {
            model.stagePresets.refresh()
            model.showToast("Could not delete \(p.name): \(Self.shortReason(error))")
        }
    }

    static func shortReason(_ error: Error) -> String {
        (error as? StagePresetError)?.description ?? AppModel.shortReason(error)
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The \(stage.title) preset could not be used"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}

/// The Rename sheet for a stage preset: the name field and Rename or Cancel.
struct RenameStagePresetSheet: View {
    let preset: StagePreset
    let rename: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(preset: StagePreset, rename: @escaping (String) -> Void) {
        self.preset = preset
        self.rename = rename
        _name = State(initialValue: preset.name)
    }

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(preset.stage.title) Preset").font(.headline)
            Text("Renames \(preset.name) and its file. A name already in use gets a number.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Preset name", text: $name)
                .onSubmit { if !trimmed.isEmpty { commit() } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commit() {
        rename(name)
        dismiss()
    }
}
