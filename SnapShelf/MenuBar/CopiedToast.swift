import SwiftUI

/// A brief "Copied" confirmation shown over the grid after copying a screenshot to the pasteboard.
struct CopiedToast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .accessibilityHidden(true)
    }
}
