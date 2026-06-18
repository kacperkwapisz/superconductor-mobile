import SwiftUI

enum GlassChrome {
    @ViewBuilder
    static func capsuleField<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder
    static func composerDock<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 0))
            }
    }

    @ViewBuilder
    static func sendButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .frame(width: 36, height: 36)
                .background {
                    if enabled {
                        Circle()
                            .fill(Color.accentColor)
                    } else {
                        Circle()
                            .fill(Color(uiColor: .tertiarySystemFill))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}