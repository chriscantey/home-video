import AVFoundation
import SwiftUI

/// Home Video on the phone: one clip at a time, a Look, every stage's controls, an export to
/// Photos. The engine is HomeVideoCore, compiled into this target from `Sources/HomeVideoCore`
/// (see `ios/README.md`), so its types need no import.
@main
struct HomeVideoMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = MobileModel()

    init() {
        HomeVideoMobileApp.activateAudio()
    }

    /// Plays the clip's sound even with the ring switch on silent, as a video app does: the
    /// playback category, made active now rather than left for the player to activate.
    static func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            NSLog("Home Video: audio session not active: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            // The appearance follows the system. The picture's stage stays near black in both.
            ContentView(model: model)
                .task {
                    model.restoreSessionIfAny()
                    model.openTestClipIfAsked()
                }
                .tint(Self.pink)
        }
    }

    /// The Mac app's pink, so the two read as one product. A full screen cover does not inherit
    /// the window's tint, so it sets this again.
    static let pink = Color(.sRGB, red: 0xd6 / 255.0, green: 0x3a / 255.0, blue: 0x8c / 255.0)
}

/// Only for the orientations the app allows, which the camera narrows while it records.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// Holds the screen in the orientation it has while the camera records, so the recording and
/// the screen stay one way up. Every other time the app turns with the phone.
@MainActor
enum OrientationLock {
    static let all: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
    private(set) static var mask = all

    static func hold() {
        switch CameraModel.screenOrientation {
        case .landscapeLeft: set(.landscapeLeft)
        case .landscapeRight: set(.landscapeRight)
        default: set(.portrait)
        }
    }

    static func release() { if mask != all { set(all) } }

    private static func set(_ m: UIInterfaceOrientationMask) {
        mask = m
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        }
    }
}
