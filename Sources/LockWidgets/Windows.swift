import AppKit
import SwiftUI

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let store: WidgetStore

    init(settings: AppSettings, store: WidgetStore) {
        self.settings = settings
        self.store = store
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(AppDelegate.shared?.lockOverlay ?? LockScreenOverlay.placeholder))
            let w = NSWindow(contentViewController: host)
            w.title = "Notch Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 780, height: 580))
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            window = w
        }
        // Open on the screen the mouse is on (center() can pick an off-screen display for menu-bar apps).
        if let window, !window.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
            if let vf = screen?.visibleFrame {
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
