import SwiftUI

/// About Home Video, from the bottom of the "..." menu, as a grouped list like Settings: the tape
/// sleeve, the name and a line on what it does, then the version and the Mac version, which
/// opens the app's page in the browser, then the privacy policy and support pages.
struct AboutView: View {
    /// The app's page, where the Mac version is.
    static let siteURL = URL(string: "https://homevideo.app")!
    /// The privacy policy (App Review Guideline 5.1.1) and the support page.
    static let privacyURL = URL(string: "https://homevideo.app/privacy/")!
    static let supportURL = URL(string: "https://homevideo.app/support/")!

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    #if DEBUG
    /// Test builds with `-homevideoRecordOpen YES`: the page the Mac row asked for, kept here
    /// for a test to read instead of opened.
    @State private var askedToOpen: URL?
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        sleeve
                        Text("Home Video")
                            .font(.title3.weight(.semibold))
                        Text(Tagline.text)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("Version") {
                        Text(Self.version)
                            .monospacedDigit()
                            .accessibilityIdentifier("aboutVersion")
                    }
                    Button { open(Self.siteURL) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Home Video for Mac")
                                    .foregroundStyle(.primary)
                                Text("4K, batches of clips, and your own saved presets.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    // A row like Settings' own links, in the text color rather than the pink.
                    .tint(.primary)
                    .accessibilityIdentifier("aboutMac")
                }
                Section {
                    linkRow("Privacy Policy", systemImage: "hand.raised", url: Self.privacyURL, id: "aboutPrivacy")
                    linkRow("Support", systemImage: "questionmark.circle", url: Self.supportURL, id: "aboutSupport")
                }
            }
            #if DEBUG
            .overlay {
                if let askedToOpen {
                    ProbeLabel(id: "aboutOpened", text: askedToOpen.absoluteString)
                }
            }
            #endif
            .listSectionSpacing(12)
            .contentMargins(.top, 0, for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("aboutDone")
                }
            }
        }
        .accessibilityIdentifier("aboutSheet")
    }

    /// A row that opens one of the site's pages, in the text color like Settings' own links.
    private func linkRow(_ title: String, systemImage: String, url: URL, id: String) -> some View {
        Button { open(url) } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier(id)
    }

    /// A row's page in the system browser.
    private func open(_ url: URL) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "homevideoRecordOpen") {
            askedToOpen = url
            return
        }
        #endif
        openURL(url)
    }

    /// The tape sleeve from the icon, on its own without the icon's frame, a little tilted
    /// with a soft shadow under it. `AboutSleeve` is a copy of the icon's `sleeve.png` layer,
    /// since an .icon bundle's layers can't be loaded at runtime.
    private var sleeve: some View {
        Image("AboutSleeve")
            .resizable()
            .scaledToFit()
            .frame(height: 96)
            .rotationEffect(.degrees(-4))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
            .accessibilityHidden(true)
    }

    /// `1.0 (N)`, from the bundle.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
