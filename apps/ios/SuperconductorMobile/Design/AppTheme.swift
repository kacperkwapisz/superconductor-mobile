import SwiftUI

enum AppTheme {
    static let terminalFont = Font.system(.caption, design: .monospaced)
    static let terminalLineSpacing: CGFloat = 3

    static var screenBackground: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemBackground),
                Color(uiColor: .secondarySystemBackground).opacity(0.5),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    static func providerSymbol(_ key: String) -> String {
        switch key.lowercased() {
        case "pi": return "sparkles"
        case "terminal": return "terminal"
        case "codex", "claude": return "brain.head.profile"
        default: return "cpu"
        }
    }

    static func providerTint(_ key: String) -> Color {
        switch key.lowercased() {
        case "pi": return .orange
        case "terminal": return .secondary
        default: return .accentColor
        }
    }
}