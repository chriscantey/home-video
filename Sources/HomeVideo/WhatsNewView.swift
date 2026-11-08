import AppKit
import HomeVideoCore
import SwiftUI

/// Help > What's New in Home Video: which build you have, the builds after yours if the
/// notes know of any, your own build, then the older ones, each a date and a few plain lines
/// from `ReleaseNotes.shown`, posted builds only. The latest build reads without scrolling.
///
/// On the release line (`ReleaseNotes.line`) the window lists release entries only and speaks of
/// versions, never builds. Only the beta line lists the betas and their build numbers.
///
/// Launch arguments for screen checks: `-homevideoWhatsNew on` opens the window at launch, and
/// `-homevideoWhatsNewBuild <n>` shows it as someone on build n would see it.
struct WhatsNewView: View {
    static let windowID = "whats-new"
    static let accent = Color(.sRGB, red: 0xd6 / 255.0, green: 0x3a / 255.0, blue: 0x8c / 255.0)

    /// The build the window speaks for: the app's, unless a screen check names another.
    static var build: Int {
        let n = UserDefaults.standard.integer(forKey: "homevideoWhatsNewBuild")
        return n > 0 ? n : AppInfo.build
    }

    /// The bundle's line, read from what tools/bundle-app.sh wrote (feed and version word).
    static var line: ReleaseNote.Line {
        ReleaseNotes.line(feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                          shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    private let build = WhatsNewView.build
    private let line = WhatsNewView.line

    /// "build" on the beta line, "version" on the release line.
    private var unit: String { line == .release ? "version" : "build" }

    var body: some View {
        let split = ReleaseNotes.split(forBuild: build, notes: ReleaseNotes.shown(on: line))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(split)
                if !split.newer.isEmpty {
                    section("Since your \(unit)", split.newer, yours: false)
                }
                if let yours = split.yours {
                    section(split.newer.isEmpty ? "In your \(unit)" : "Your \(unit)", [yours], yours: true)
                }
                if !split.older.isEmpty {
                    section("Earlier \(unit)s", split.older, yours: false)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private func header(_ split: ReleaseNotes.Split) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                // The version word from the bundle (AppInfo.shortVersion), "0.2.0 beta 1" on a beta.
                Text("What's New in \(AppInfo.shortVersion)")
                    .font(.system(size: 22, weight: .heavy))
                Text(youHave(split))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "You have build n", plus how many posted builds are newer, or that yours is a test build.
    /// A test build's own notes are never listed, only named here.
    /// On the release line: "You have version 1.0", and no build number anywhere.
    private func youHave(_ split: ReleaseNotes.Split) -> String {
        var text = line == .release ? "You have version \(AppInfo.shortVersion)" : "You have build \(build)"
        if line != .release, ReleaseNotes.entry(for: build)?.status == .testing { text += ", a test build" }
        let newer = split.newer.count
        if newer == 1 { text += ". One newer \(unit) is out" }
        if newer > 1 { text += ". \(newer) newer \(unit)s are out" }
        return text
    }

    private func section(_ heading: String, _ notes: [ReleaseNote], yours: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            ForEach(notes) { note in
                entry(note, yours: yours)
            }
        }
    }

    private func entry(_ note: ReleaseNote, yours: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                Text(note.dateText)
                    .font(.system(size: 11, weight: note.status == .testing ? .semibold : .regular))
                    .foregroundStyle(note.status == .testing ? Self.accent : .secondary)
            }
            ForEach(note.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(yours ? Self.accent : Color.secondary.opacity(0.6))
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(item)
                        .font(.system(size: 13))
                        .foregroundStyle(yours ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(yours ? 0.06 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(yours ? Self.accent.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// Help > What's New in Home Video.
struct WhatsNewCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("What's New in \(AppInfo.displayName)") { openWindow(id: WhatsNewView.windowID) }
    }
}

/// Opens the window once at launch when `-homevideoWhatsNew on` is passed, for screen checks.
struct WhatsNewLaunchOpener: View {
    @Environment(\.openWindow) private var openWindow
    @State private var opened = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard !opened, UserDefaults.standard.string(forKey: "homevideoWhatsNew") == "on" else { return }
                opened = true
                openWindow(id: WhatsNewView.windowID)
            }
    }
}
