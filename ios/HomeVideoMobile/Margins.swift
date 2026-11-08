import SwiftUI

/// The one horizontal margin rule, so no control runs off screen or sits far from the right
/// edge. Every row sits inside the safe area, then `side` in from it on both sides, which is
/// the system's layout margin on an iPhone (a plain `.padding(.horizontal)`, and a Form's own
/// row inset). A horizontal scroller (the Look carousel, the stage chips) starts on the same
/// leading line, and runs on past the trailing margin to the safe area's edge, so its fade sits
/// in the gutter and not on a card. It is cut there, never under the Dynamic Island, the Duo's
/// side status column or the screen's edge.
enum Margins {
    static let side: CGFloat = 16
    /// The fade at a scroller's trailing edge that says more is there: the trailing gutter.
    static let fade: CGFloat = side
}

extension View {
    /// A horizontal scroller on the margin rule: its frame inset by `Margins.side` on the
    /// leading side and running to the safe area's edge on the trailing side, cut at that frame
    /// (a scroll view otherwise draws on into the safe area), with the fade in the trailing
    /// gutter. Its content takes no horizontal padding of its own.
    func insideMargins() -> some View {
        mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Margins.fade)
            }
        }
        .padding(.leading, Margins.side)
    }
}
