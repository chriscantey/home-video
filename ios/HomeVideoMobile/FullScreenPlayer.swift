import SwiftUI

/// The picture alone, for checking the work: the whole screen black around it, the chrome
/// hidden, and only play, the scrubber and the time on a glass bar. A tap on the picture, a swipe
/// down or the X closes it. Opened only from the preview's button, in either orientation, since
/// turning the phone shows the landscape editor, not a full screen.
///
/// Alignment: the picture is centered on the screen itself, not on the safe area, which is wider
/// on the side away from the Dynamic Island. The bar is centered on the same line and
/// is as wide as the picture, less the side margins when the picture fills the width, so the
/// bar's edges sit an equal distance inside the picture's. The X stays inside the safe area,
/// clear of the island.
struct FullScreenPlayer: View {
    let model: MobileModel
    let exit: () -> Void
    @State private var drop: CGFloat = 0

    private var aspect: CGFloat {
        SignalChain.displayAspect(model.chain.output, model.chain.outputSize)
    }

    var body: some View {
        GeometryReader { safe in
            let insets = safe.safeAreaInsets
            GeometryReader { screen in
                layout(screen: screen.size, insets: insets)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .tint(HomeVideoMobileApp.pink)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private func layout(screen: CGSize, insets: EdgeInsets) -> some View {
        let picture = Self.fit(aspect, in: screen)
        let side = max(insets.leading, insets.trailing)
        let bar = Self.barWidth(picture: picture.width, screen: screen.width, sideInset: side)
        return ZStack {
            Color.black
            PreviewSurface(model: model, isMain: false)
                .frame(width: picture.width, height: picture.height)
                .offset(y: drop)
                .accessibilityElement()
                .accessibilityLabel("Preview, full screen")
                .accessibilityHint("Tap to close")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { exit() }
                .accessibilityIdentifier("fullScreenPlayer")
        }
        .frame(width: screen.width, height: screen.height)
        .contentShape(Rectangle())
        .onTapGesture { exit() }
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { v in drop = max(v.translation.height, 0) }
            .onEnded { v in
                if v.translation.height > 90 { exit() }
                withAnimation(.easeOut(duration: 0.2)) { drop = 0 }
            })
        .overlay(alignment: .bottom) {
            TransportBar(model: model)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Darkened, so the time reads over a bright picture (landscape lays the bar on it).
                .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .frame(width: bar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fullScreenBar")
                .padding(.bottom, max(insets.bottom, Margins.side))
        }
        .overlay(alignment: .topLeading) {
            Button("Close Full Screen", systemImage: "xmark", action: exit)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(.leading, insets.leading + Margins.side)
                .padding(.top, max(insets.top, Margins.side))
                .accessibilityIdentifier("exitFullScreen")
        }
    }

    /// The largest size of `aspect` (width over height) inside `box`.
    static func fit(_ aspect: CGFloat, in box: CGSize) -> CGSize {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        return box.width / box.height > aspect
            ? CGSize(width: box.height * aspect, height: box.height)
            : CGSize(width: box.width, height: box.width / aspect)
    }

    /// The transport's width under or over a picture `picture` wide on a screen `screen` wide:
    /// the picture's width, kept inside the side margins (and the wider safe inset, so it is the
    /// same on both sides and stays centered).
    static func barWidth(picture: CGFloat, screen: CGFloat, sideInset: CGFloat) -> CGFloat {
        max(min(picture, screen - 2 * (sideInset + Margins.side)), 120)
    }
}
