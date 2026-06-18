import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    private let panelSize = NSSize(width: 280, height: 520)

    private override init() {
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.isVisible = true

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Superconductor Mobile"

        button.image = menuBarImage()
        button.imagePosition = .imageOnly
    }

    func showPanel() {
        guard let button = statusItem?.button else { return }
        if panel?.isVisible == true { return }
        openPanel(anchoredTo: button)
    }

    func closePanel() {
        panel?.orderOut(nil)
        stopOutsideMonitors()
    }

    var isPanelVisible: Bool {
        panel?.isVisible == true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu(on: sender)
            return
        }
        if isPanelVisible {
            closePanel()
        } else {
            openPanel(anchoredTo: sender)
        }
    }

    private func openPanel(anchoredTo button: NSStatusBarButton) {
        ensurePanel()
        guard let panel else { return }

        let origin = panelOrigin(anchoredTo: button, panelSize: panelSize)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        panel.orderFrontRegardless()
        startOutsideMonitors(panel: panel)
    }

    /// Screen-space anchor under the status item (works when the button lives in Control Center hosting).
    private func panelOrigin(anchoredTo button: NSStatusBarButton, panelSize: NSSize) -> NSPoint {
        let screenRect: NSRect
        if let window = button.window {
            let inWindow = button.convert(button.bounds, to: nil)
            screenRect = window.convertToScreen(inWindow)
        } else {
            let mouse = NSEvent.mouseLocation
            screenRect = NSRect(x: mouse.x - 12, y: mouse.y - 2, width: 24, height: 22)
        }

        var x = screenRect.midX - panelSize.width / 2
        var y = screenRect.minY - panelSize.height - 6

        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: screenRect.midX, y: screenRect.midY)) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - panelSize.width - 8)
            y = min(max(y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        }

        return NSPoint(x: x, y: y)
    }

    private func showContextMenu(on button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Pairing Panel", action: #selector(menuOpenPanel), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Superconductor Mobile", action: #selector(menuQuit), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
        }

        let point = NSPoint(x: button.bounds.midX, y: button.bounds.minY - 2)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    @objc private func menuOpenPanel() {
        showPanel()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true

        let root = AnyView(
            PairingPopoverView()
                .environmentObject(BridgeProcessManager.shared)
        )
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentViewController = host
        hostingController = host
        self.panel = panel
    }

    private func menuBarImage() -> NSImage {
        let sym = NSImage(systemSymbolName: "iphone.gen2", accessibilityDescription: "Superconductor Mobile")!
        sym.isTemplate = true
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return sym.withSymbolConfiguration(config) ?? sym
    }

    private func startOutsideMonitors(panel: NSPanel) {
        stopOutsideMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isPanelVisible else { return event }
            if event.window !== panel {
                self.closePanel()
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func stopOutsideMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}