import AppKit

/// Temporary drag diagnostics (drag events only) for testing on the user's Mac.


/// Drag-and-drop onto the island. The island's own window lives in a SkyLight space above the lock
/// screen at the shielding level, and macOS doesn't deliver drags to it. So a plain, almost-clear
/// window always sits over the physical notch (nothing is underneath it to block). When a drag
/// reaches it, it opens the File Shelf, grows to cover the open island, takes the drop, and then
/// shrinks back to the notch.
@MainActor
final class DropCatcher {
    static let shared = DropCatcher()
    private var panel: NSPanel?
    /// A drag is over the catcher (or just left it): it covers the whole open island meanwhile.
    var dragActive = false {
        didSet { if dragActive != oldValue { dragActive ? startWatchdog() : stopWatchdog() } }
    }
    /// The mouse-up that ends a drag doesn't always reach us; never stay enlarged after release.
    private var watchdog: Timer?
    private var releasedSince: Date?

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let catcher = DropCatcher.shared
                if NSEvent.pressedMouseButtons & 1 != 0 { catcher.releasedSince = nil; return }
                let since = catcher.releasedSince ?? Date()
                catcher.releasedSince = since
                // Give macOS time to deliver a drop after the button comes up.
                if Date().timeIntervalSince(since) > 0.6 { catcher.endDrag() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        releasedSince = nil
    }
    fileprivate var exitWork: DispatchWorkItem?

    var isShowing: Bool { panel?.isVisible ?? false }

    func show(over rect: NSRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != rect { panel.setFrame(rect, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        exitWork?.cancel()
        exitWork = nil
        dragActive = false
        panel?.orderOut(nil)
        if NotchModel.shared.dropTargeted { NotchModel.shared.dropTargeted = false }
    }

    /// The drag finished or left for good: go back to covering just the notch.
    func endDrag() {
        exitWork?.cancel()
        exitWork = nil
        dragActive = false
        if NotchModel.shared.dropTargeted { NotchModel.shared.dropTargeted = false }
        AppDelegate.shared?.notch?.syncDropCatcher()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        // Fully clear: with ignoresMouseEvents explicitly false the window still takes drags.
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        // A normal level just above the menu bar: drags are delivered here (not at shielding level).
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = DropCatcherView(frame: .zero)
        return panel
    }
}

private final class DropCatcherView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, NSPasteboard.PasteboardType("public.item")])
    }

    required init?(coder: NSCoder) { nil }

    private var shelfOn: Bool {
        AppSettings.shared.config.notchPages.contains(NotchPage.shelf.rawValue)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard shelfOn else { return [] }
        let catcher = DropCatcher.shared
        catcher.exitWork?.cancel()
        catcher.exitWork = nil
        NotchModel.shared.dropTargeted = true
        if !catcher.dragActive {
            catcher.dragActive = true
            AppDelegate.shared?.notch?.dropDragEntered()
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return shelfOn ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        NotchModel.shared.dropTargeted = false
        // Growing to the open island can briefly read as an exit; only give up if it stays gone.
        let work = DispatchWorkItem { DropCatcher.shared.endDrag() }
        DropCatcher.shared.exitWork?.cancel()
        DropCatcher.shared.exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        NotchModel.shared.dropTargeted = false
        guard shelfOn else { return false }
        let pb = sender.draggingPasteboard
        var providers: [NSItemProvider] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            providers += urls.map { NSItemProvider(object: $0 as NSURL) }
        }
        if providers.isEmpty, let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            providers += images.map { NSItemProvider(object: $0) }
        }
        if providers.isEmpty, let text = pb.string(forType: .string), !text.isEmpty {
            providers.append(NSItemProvider(object: text as NSString))
        }
        guard !providers.isEmpty else { return false }
        ShelfModel.shared.accept(providers)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        DropCatcher.shared.endDrag()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        DropCatcher.shared.endDrag()
    }
}
