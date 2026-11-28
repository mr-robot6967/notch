import AppKit

/// The island's window lives in a SkyLight space above the lock screen, and macOS doesn't route
/// drag-and-drop to windows there. While something is dragged over the island, this plain,
/// almost-transparent window sits over it in the normal spaces, catches the drop and hands the
/// items to the File Shelf.
@MainActor
final class DropCatcher {
    static let shared = DropCatcher()
    private var panel: NSPanel?

    var isShowing: Bool { panel?.isVisible ?? false }

    func show(over rect: NSRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != rect { panel.setFrame(rect, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
        if NotchModel.shared.dropTargeted { NotchModel.shared.dropTargeted = false }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        // Fully clear pixels are click- and drop-through; a barely-there fill keeps it a target.
        panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        // macOS doesn't deliver drags to windows at the island's shielding level, so this sits just
        // above the menu bar (the island lets mouse events through while a drag is on).
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
        NotchModel.shared.dropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        shelfOn ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        NotchModel.shared.dropTargeted = false
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
        DropCatcher.shared.hide()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        DropCatcher.shared.hide()
    }
}
