import SwiftUI

@main
struct SuperconductorMobileApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            LaunchHostView {
                RootView()
            }
            .environment(session)
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        // Support superconductor-mobile://pair?... and also raw JSON passed via URL if ever needed
        if session.applyPairingString(url.absoluteString) {
            return
        }
        // Also try the query portion or whole thing as potential JSON payload
        if session.applyPairingString(url.query ?? "") { return }

        // Fallback: if someone pastes a full JSON into a link somehow
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let fragment = components.fragment,
           session.applyPairingString(fragment) { return }
    }
}