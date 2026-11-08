import AppKit
import HomeVideoCore
import SwiftUI
import UniformTypeIdentifiers

/// The Look menu's preset commands: Save Preset asks a name and saves the chain to the presets
/// folder, Import copies a file in, Export writes the shown preset out, and Manage Presets lists
/// them with a Delete button. Rename and Delete for the shown preset also sit under the sidebar's
/// Look picker, since a SwiftUI menu item takes no right-click.
extension AppModel {
    static let presetType = UTType(filenameExtension: UserPresets.fileExtension) ?? .json

    /// The user preset the chain reads back as, if any.
    var shownUserPreset: UserPreset? {
        guard let id = presets.look?.id else { return nil }
        return userPresets.presets.first { $0.id == id }
    }

    /// Applies a built-in Look or a user preset by its menu id.
    func chooseLook(id: String) {
        if let look = Looks.anyLook(id: id) {
            presets.setLook(look)
            lookPicked = true
        }
    }

    func showSavePresetPanel() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Saves every layer and the audio as a preset in the Look menu. A preset of the same name is replaced."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        field.stringValue = shownUserPreset?.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try userPresets.save(name: field.stringValue, chain: chain)
        } catch {
            showPresetError(error)
        }
    }

    func showImportPresetPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AppModel.presetType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a \(AppInfo.displayName) preset to add to the Look menu"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let p = try userPresets.import(from: url)
            presets.setLook(p.look)
        } catch {
            showPresetError(error)
        }
    }

    /// Writes the shown user preset's file out, or the current chain as a new preset file
    /// when a built-in Look or Custom is shown.
    func showExportPresetPanel() {
        let shown = shownUserPreset
        let panel = NSSavePanel()
        panel.allowedContentTypes = [AppModel.presetType]
        panel.nameFieldStringValue = (shown?.name ?? presets.look?.name ?? "Custom") + "." + UserPresets.fileExtension
        panel.message = "Export the preset to a file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let shown {
                try userPresets.export(shown.url, to: url)
            } else {
                try userPresets.write(name: url.deletingPathExtension().lastPathComponent, chain: chain, to: url)
            }
        } catch {
            showPresetError(error)
        }
    }

    /// Deletes a preset's file. When it was the shown Look, the picture falls back to the
    /// built-in Look it was built on (`UserPresets.baseLook`, Fresh SP on a tie). A file that
    /// cannot be removed is reported in the status line and the preset stays.
    func deletePreset(_ preset: UserPreset) {
        let wasShown = shownUserPreset?.id == preset.id
        let base = UserPresets.baseLook(of: preset)
        do {
            try userPresets.delete(preset)
            if wasShown { presets.setLook(base) }
            showToast("Deleted \(preset.name)")
        } catch {
            userPresets.refresh()
            showToast("Could not delete \(preset.name): \(Self.shortReason(error))")
        }
    }

    /// Renames a preset and its file. The shown preset stays chosen under its new name.
    /// A file that cannot be renamed is reported in the status line and keeps its name.
    func renamePreset(_ preset: UserPreset, to name: String) {
        let wasShown = shownUserPreset?.id == preset.id
        do {
            let renamed = try userPresets.rename(preset, to: name)
            if wasShown { presets.setLook(renamed.look) }
            if renamed.name != preset.name { showToast("Renamed to \(renamed.name)") }
        } catch {
            showToast("Could not rename \(preset.name): \(Self.shortReason(error))")
        }
    }

    /// An error as a few words for the status line.
    static func shortReason(_ error: Error) -> String {
        if let e = error as? UserPresetError { return e.description }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code))).lowercased()
        }
        return ns.localizedDescription
    }

    private func showPresetError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The preset could not be used"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}

/// Look > Manage Presets: the saved presets with Reveal in Finder and Delete.
struct ManagePresetsView: View {
    static let windowID = "manage-presets"
    let model: AppModel
    @State private var selection: UserPreset.ID?

    var body: some View {
        let list = model.userPresets.presets
        VStack(alignment: .leading, spacing: 12) {
            Text("Presets").font(.headline)
            if list.isEmpty {
                Text("No saved presets yet. Look > Save Preset saves the current chain.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(list, selection: $selection) { p in
                    Text(p.name).tag(p.id)
                }
            }
            HStack {
                Button("Reveal in Finder") {
                    if let p = list.first(where: { $0.id == selection }) {
                        NSWorkspace.shared.activateFileViewerSelecting([p.url])
                    } else {
                        try? FileManager.default.createDirectory(at: model.userPresets.folder,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.userPresets.folder)
                    }
                }
                Spacer()
                Button("Delete", role: .destructive) {
                    if let p = list.first(where: { $0.id == selection }) {
                        model.deletePreset(p)
                        selection = nil
                    }
                }
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 300)
        .onAppear { model.userPresets.refresh() }
    }
}
