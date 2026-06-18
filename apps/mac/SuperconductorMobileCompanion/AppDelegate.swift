import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        StatusBarController.shared.install()

        let config = CompanionConfigManager.loadOrCreate()
        DispatchQueue.main.async {
            BridgeProcessManager.shared.start(config: config)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BridgeProcessManager.shared.stop()
    }

    /// Finder / Spotlight reopen: show the pairing panel (standard menu-bar app behavior).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StatusBarController.shared.showPanel()
        return true
    }
}