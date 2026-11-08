import SwiftUI

/// A pick on its way in, over the empty screen or the editor's empty preview: a ring with the
/// percent inside, what is happening under it, and Cancel under that. The line reads "Opening
/// video…" for the first second and once the file is in, and "Downloading clip…" while a file
/// that is a second late is still on its way. It never names iCloud, since the picker never
/// says where a file comes from. The ring spins when the picker doesn't say how much is coming.
struct LoadingCard: View {
    let loading: MobileModel.Loading
    let cancel: () -> Void

    var body: some View {
        // Progress is not observable by SwiftUI, so it is read a few times a second.
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let state = LoadState(loading, at: context.date)
            VStack(spacing: 0) {
                ZStack {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 6)
                    if let f = state.fraction {
                        Circle()
                            .trim(from: 0, to: f)
                            .stroke(HomeVideoMobileApp.pink, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(state.percent ?? "")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .accessibilityIdentifier("loadPercent")
                    } else {
                        SpinningArc()
                    }
                }
                .frame(width: 92, height: 92)
                Text(state.title)
                    .font(.headline)
                    .padding(.top, 20)
                    .accessibilityIdentifier("loadLine")
                Button(role: .cancel, action: cancel) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.top, 24)
                .accessibilityIdentifier("loadCancel")
            }
            .frame(width: 220)
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .environment(\.colorScheme, .dark)
            .tint(HomeVideoMobileApp.pink)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loadProgress")
    }
}

/// The ring when nothing says how much is coming: a quarter arc that goes around once a second.
private struct SpinningArc: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(HomeVideoMobileApp.pink, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .accessibilityHidden(true)
    }
}

/// What the card shows at one moment, read off the picker's Progress.
struct LoadState {
    let title: String
    /// 0 to 1 while the file is on its way and the picker says how much is coming.
    let fraction: Double?

    init(_ loading: MobileModel.Loading, at now: Date) {
        let p = loading.display
        title = loading.downloading(at: now) ? "Downloading clip…" : "Opening video…"
        let known = loading.arrived == nil && !p.isIndeterminate && p.totalUnitCount > 0
        fraction = known ? min(max(p.fractionCompleted, 0), 1) : nil
    }

    var percent: String? { fraction.map { "\(Int($0 * 100))%" } }
}

extension View {
    /// The editor's controls while a pick comes in: there is no clip under them yet, so they
    /// are off and dimmed. The card's Cancel stays live.
    func idleWhile(loading: Bool) -> some View {
        disabled(loading).opacity(loading ? 0.4 : 1)
    }
}
