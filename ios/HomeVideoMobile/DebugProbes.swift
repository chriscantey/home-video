import SwiftUI

#if DEBUG
/// Test builds only: a one point element that carries a line of numbers for a UI test to read
/// by its identifier. Nothing shows on screen.
struct ProbeLabel: View {
    let id: String
    let text: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(text)
            .accessibilityIdentifier(id)
            .allowsHitTesting(false)
    }
}
#endif
