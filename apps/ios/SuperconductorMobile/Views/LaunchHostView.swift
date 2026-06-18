import SwiftUI

/// Root content with consistent safe-area and scale (avoids launch-time layout jump).
struct LaunchHostView<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
    }
}