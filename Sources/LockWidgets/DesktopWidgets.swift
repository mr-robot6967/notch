import AppKit
import Combine
import SwiftUI
import LockWidgetsCore

/// Optional widgets on the desktop (Settings › Desktop): each widget is its own small panel just above
/// the wallpaper and icons, draggable anywhere — or all of them in one row that moves as a unit.
@MainActor
final class DesktopWidgetsController {
    private let settings: AppSettings
    private let store: WidgetStore
    private var panels: [String: DesktopWidgetPanel] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, store: WidgetStore) {
        self.settings = settings
        self.store = store
        settings.$config
            // Sizes too: each panel holds a snapshot of its entry, so a Round/Wide change needs a rebuild.
            .map { "\($0.desktopWidgetsEnabled)|\($0.desktopLineMode)|\($0.widgets.filter(\.enabled).map { entry in "\(entry.kind.rawValue):\(entry.size)" })" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.positionAll() }
            .store(in: &cancellables)
    }

    private func rebuild() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        let cfg = settings.config
        guard cfg.desktopWidgetsEnabled else { return }
        if cfg.desktopLineMode {
            addPanel(id: "line", content: AnyView(WidgetStripView().fixedSize()))
        } else {
            for entry in cfg.widgets.filter(\.enabled) {
                addPanel(id: entry.kind.rawValue, content: AnyView(SingleWidgetView(entry: entry).fixedSize()))
            }
        }
        positionAll()
    }

    private func addPanel(id: String, content: AnyView) {
        let panel = DesktopWidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.widgetID = id
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let host = NSHostingController(rootView: content.environmentObject(settings).environmentObject(store))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        panel.onMoved = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.saveDrag(of: panel)
        }
        panel.onResized = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.position(panel)
        }
        panel.orderFrontRegardless()
        panels[id] = panel
    }

    private var screen: NSScreen? { NSScreen.screens.first }

    private func placement(for id: String) -> ScreenPlacement {
        let cfg = settings.config
        if id == "line" { return cfg.desktopLinePlacement }
        if let saved = cfg.desktopPlacements[id] { return saved }
        // Spread new widgets along the top area.
        let ids = cfg.widgets.filter(\.enabled).map(\.kind.rawValue)
        let index = Double(ids.firstIndex(of: id) ?? 0), count = Double(max(1, ids.count))
        return ScreenPlacement(x: 0.5 + (index - (count - 1) / 2) * 0.075, y: 0.22).clamped()
    }

    private func positionAll() {
        for panel in panels.values { position(panel) }
    }

    private func position(_ panel: DesktopWidgetPanel) {
        guard let frame = screen?.frame else { return }
        let size = panel.frame.size
        let origin = placement(for: panel.widgetID).origin(for: size, in: frame.size)
        let target = NSPoint(x: frame.minX + origin.x, y: frame.maxY - origin.y - size.height)
        if panel.frame.origin != target {
            panel.programmaticMove = true
            panel.setFrameOrigin(target)
            panel.programmaticMove = false
        }
    }

    /// Store where the user dropped a widget (or the row), as its centre in screen fractions.
    private func saveDrag(of panel: DesktopWidgetPanel) {
        guard let frame = screen?.frame else { return }
        let center = CGPoint(x: (panel.frame.midX - frame.minX) / frame.width, y: (frame.maxY - panel.frame.midY) / frame.height)
        let p = ScreenPlacement(x: center.x, y: center.y).clamped()
        if panel.widgetID == "line" {
            settings.config.desktopLinePlacement = p
        } else {
            settings.config.desktopPlacements[panel.widgetID] = p
        }
    }

    /// "Arrange in a line": gather every widget into one row centred where they were.
    func arrangeInLine() {
        settings.config.desktopLineMode = true
    }

    func resetPositions() {
        settings.config.desktopPlacements = [:]
        settings.config.desktopLinePlacement = ScreenPlacement(x: 0.5, y: 0.22)
        positionAll()
    }
}

final class DesktopWidgetPanel: NSPanel, NSWindowDelegate {
    var widgetID = ""
    var programmaticMove = false
    var onMoved: (() -> Void)?
    var onResized: (() -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        onMoved?()
    }

    func windowDidResize(_ notification: Notification) { onResized?() }
}
