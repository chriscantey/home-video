import SwiftUI
import UIKit

/// App Icon, from the "..." menu, a grouped list like About: the close-up of the sleeve that
/// fills the square (the default, `AppIcon`) or the whole case on black, the Mac's icon
/// (`AppIconSleeve`). Both carry the tape glyph that the tinted and clear home screens draw. The
/// choice lives with the system (`alternateIconName`), so the app keeps nothing of its own.
struct AppIconView: View {
    /// One icon: its alternate name (nil is the primary), its name here, and the preview from
    /// `AboutAssets`, since an .icon bundle can't be loaded at runtime.
    struct Choice: Identifiable {
        let iconName: String?
        let title: String
        let detail: String
        let preview: String
        var id: String { iconName ?? "AppIcon" }
    }

    static let choices = [
        Choice(iconName: nil, title: "Close-Up", detail: "The sleeve, filling the frame.", preview: "IconFullFrame"),
        Choice(iconName: "AppIconSleeve", title: "Sleeve", detail: "The whole case on black, as on the Mac.",
               preview: "IconSleeve"),
    ]

    @Environment(\.dismiss) private var dismiss
    @State private var current = UIApplication.shared.alternateIconName
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.choices) { choice in
                        Button { pick(choice) } label: { row(choice) }
                            .tint(.primary)
                            .accessibilityIdentifier("appIcon-\(choice.id)")
                            .accessibilityAddTraits(choice.iconName == current ? .isSelected : [])
                    }
                } footer: {
                    Text("Tinted and clear home screens show the tape glyph with either one.")
                }
            }
            #if DEBUG
            .overlay { ProbeLabel(id: "appIconName", text: current ?? "AppIcon") }
            #endif
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("appIconDone")
                }
            }
            .alert("Couldn't change the icon", isPresented: Binding(get: { failure != nil },
                                                                   set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
        .accessibilityIdentifier("appIconSheet")
    }

    /// The preview at home screen size, its name and a line, and a check on the one in use.
    private func row(_ choice: Choice) -> some View {
        HStack(spacing: 14) {
            Image(choice.preview)
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .clipShape(.rect(cornerRadius: 13.5, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                Text(choice.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if choice.iconName == current {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
    }

    /// Asks the system for the icon. It shows its own alert saying the icon changed.
    private func pick(_ choice: Choice) {
        guard choice.iconName != current, UIApplication.shared.supportsAlternateIcons else { return }
        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(choice.iconName)
                current = UIApplication.shared.alternateIconName
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
