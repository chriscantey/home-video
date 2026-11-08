import AppKit
import HomeVideoCore
import SwiftUI

/// The app menu's About item: the app icon, the display name, the version word
/// (`AppInfo.shortVersion`, "0.2.0 beta 1" on a beta build) and the build,
/// and the one line (`Tagline.text`), then on a build with an update feed
/// the privacy line (`Updates.privacyLine`).
/// Opened from the app menu in HomeVideoApp in place of the standard About panel.
struct AboutView: View {
    static let windowID = "about"

    var body: some View {
        VStack(spacing: 10) {
            // The bundled AppIcon.icns. A bare `swift run` has no bundle and shows the
            // generic app icon, which is fine for a debug run.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
            Text(AppInfo.displayName)
                .font(.system(size: 26, weight: .heavy))
            Text("Version \(AppInfo.shortVersion) (\(AppInfo.build))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(Tagline.text)
                .font(.body)
                .padding(.top, 4)
            // What the updater does, on a build that has one (Updates).
            if Updates.shared.updater != nil {
                Text(Updates.privacyLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .fixedSize()
        .preferredColorScheme(.dark)
    }
}
