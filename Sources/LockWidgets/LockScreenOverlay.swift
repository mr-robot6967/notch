import AppKit
import QuartzCore
import Combine
import OSLog
import SwiftUI

let lockLog = Logger(subsystem: "com.k2a.LockWidgets", category: "lockscreen")

/// Private SkyLight (window server) calls that let a window live in a system space above the
/// lock screen. Loaded with dlsym so a missing symbol just disables the feature.
@MainActor
final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsToSpace = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock
    private static let lockScreenLevel: Int32 = 400

    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var addWindows: AddWindowsToSpace?
    private var prepared = false
    private(set) var isAvailable = false

    private init() {}

    /// Creates the lock-screen space. Called at launch (creating it mid-lock is less reliable).
    func prepare() {
        guard !prepared else { return }
        prepared = true
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let mainSym = dlsym(handle, "SLSMainConnectionID"),
              let createSym = dlsym(handle, "SLSSpaceCreate"),
              let levelSym = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSym = dlsym(handle, "SLSShowSpaces"),
              let addSym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else {
            lockLog.error("SkyLight symbols not found")
            return
        }

        connection = unsafeBitCast(mainSym, to: MainConnectionID.self)()
        space = unsafeBitCast(createSym, to: SpaceCreate.self)(connection, 1, 0)
        guard space != 0 else {
            lockLog.error("SLSSpaceCreate returned 0")
            return
        }
        _ = unsafeBitCast(levelSym, to: SpaceSetAbsoluteLevel.self)(connection, space, Self.lockScreenLevel)
        _ = unsafeBitCast(showSym, to: ShowSpaces.self)(connection, [space] as CFArray)
        addWindows = unsafeBitCast(addSym, to: AddWindowsToSpace.self)
        isAvailable = true
        lockLog.notice("SkyLight lock-screen space ready: connection=\(self.connection) space=\(self.space)")
    }

    @discardableResult
    func moveToLockScreen(_ window: NSWindow) -> Bool {
        prepare()
        guard isAvailable, let addWindows else { return false }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        return true
    }
}

/// Shows the widgets on the real macOS lock screen: the windows appear when the screen locks
/// and disappear when it unlocks.
@MainActor
final class LockScreenOverlay: ObservableObject {
    /// Used only if Settings opens before the app finished launching.
    static let placeholder = LockScreenOverlay()

    @Published private(set) var isLocked = false
    @Published private(set) var isShowing = false
    @Published private(set) var lastProblem: String?
    @Published private(set) var lastShownAt: Date?

    private var settings: AppSettings?
    private var store: WidgetStore?
    /// One window per display, created once and moved into the lock-screen space once.
    private var windows: [String: NSWindow] = [:]
    private var lockPoll: Timer?
    fileprivate var pollMismatches = 0
    private var previewHide: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    init(settings: AppSettings, store: WidgetStore) {
        self.settings = settings
        self.store = store

        SkyLight.shared.prepare()
        if !SkyLight.shared.isAvailable {
            lastProblem = "This macOS version doesn't allow the lock-screen layer. Turn on the wallpaper fallback instead."
        }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.didLock(source: "notification") }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.didUnlock(source: "notification") }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { overlay in
            if !Self.sessionIsLocked() { overlay.didUnlock(source: "session active") }
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification.rawValue) { overlay in
            overlay.rebuildWindows()
        }
        // Locking by closing the lid / sleeping creates the windows while the display is off; when it
        // wakes on the lock screen, show them again (re-joining the lock space, fully visible).
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification.rawValue) { $0.reshowAfterWake() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification.rawValue) { $0.reshowAfterWake() }

        // Backup in case a lock notification is missed: a cheap session check every few seconds.
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let overlay = AppDelegate.shared?.lockOverlay else { return }
                // Act only when two checks in a row disagree with our state, so a session flag
                // that updates a moment after the notification can't flicker the widgets.
                let locked = Self.sessionIsLocked()
                if locked != overlay.isLocked {
                    overlay.pollMismatches += 1
                    if overlay.pollMismatches >= 2 {
                        overlay.pollMismatches = 0
                        locked ? overlay.didLock(source: "poll") : overlay.didUnlock(source: "poll")
                    }
                } else {
                    overlay.pollMismatches = 0
                }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        lockPoll = timer

        // Hide straight away if the feature is turned off, or if the wallpaper fallback takes over.
        settings.$config
            .map { $0.lockScreenWidgets && !$0.wallpaperMode }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled { self.hide() } else if self.isLocked { self.show() }
            }
            .store(in: &cancellables)

        settings.$config
            .map { "\($0.allDisplays)|\($0.freeLayout)" }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildWindows() }
            .store(in: &cancellables)

        settings.$config
            .map { "\($0.lockScreenPlacement)|\(String(describing: $0.playerPlacement))" }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.repositionAll() } }
            .store(in: &cancellables)
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ handler: @escaping (LockScreenOverlay) -> Void) {
        let token = center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    static func sessionIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private var enabled: Bool {
        guard let cfg = settings?.config else { return false }
        return cfg.lockScreenWidgets && !cfg.wallpaperMode
    }

    private func didLock(source: String) {
        guard !isLocked else { return }
        isLocked = true
        withAnimation(IslandMotion.activity) { NotchModel.shared.locked = true }
        NotchModel.shared.hidePrivateTransient()
        AppDelegate.shared?.notch?.collapse()
        lockLog.notice("Locked (\(source, privacy: .public)); widgets enabled=\(self.enabled)")
        store?.refreshForLock()
        if let cfg = settings?.config, cfg.lockSounds { SystemSounds.play(cfg.lockSoundName, customPath: cfg.customLockSoundPath) }
        previewHide?.cancel()
        if enabled { show() } else { hide() }
    }

    private func didUnlock(source: String) {
        guard isLocked else { return }
        isLocked = false
        withAnimation(IslandMotion.activity) { NotchModel.shared.locked = false }
        lockLog.notice("Unlocked (\(source, privacy: .public))")
        hide()
        if let cfg = settings?.config, cfg.lockSounds { SystemSounds.play(cfg.unlockSoundName, customPath: cfg.customUnlockSoundPath) }
        NotchModel.shared.flash(.unlocked, seconds: 2)
    }

    /// Shows the lock-screen layer for a few seconds without locking, to check placement.
    func preview(seconds: Double = 6) {
        previewHide?.cancel()
        show()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isLocked else { return }
            self.hide()
        }
        previewHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private var targetScreens: [NSScreen] {
        let all = NSScreen.screens
        if settings?.config.allDisplays == true { return all }
        return Array(all.prefix(1)) // the primary display (the one with the menu bar)
    }

    /// Creates any missing windows: one for the widgets and one for the player per display, each sized
    /// to its content (so the player's buttons work without covering the login field). Each window joins
    /// the lock-screen space before it is ever shown.
    private func ensureWindows() {
        guard let settings, let store else { return }
        for screen in targetScreens {
            let key = WallpaperBaker.key(for: screen)
            for role in [LockPanel.Role.widgets, .player] {
                let id = role == .widgets ? key : key + "#player"
                if let existing = windows[id] {
                    position(existing, on: screen)
                    continue
                }
                let window = LockPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.role = role
                window.screenKey = key
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.isReleasedWhenClosed = false
                window.canBecomeVisibleWithoutLogin = true
                window.animationBehavior = .none
                window.becomesKeyOnlyIfNeeded = true
                window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                let free = settings.config.freeLayout
                let root: AnyView
                if role == .widgets && free {
                    // Each widget at its own spot on a full-screen, click-through canvas.
                    root = AnyView(FreeWidgetsView(screenKey: key).frame(width: screen.frame.width, height: screen.frame.height))
                    window.ignoresMouseEvents = true
                } else if role == .widgets {
                    root = AnyView(WidgetStripView(screenKey: key).fixedSize())
                } else {
                    root = AnyView(LockPlayerSection(screenKey: key).fixedSize())
                }
                let host = NSHostingController(rootView: root.environmentObject(settings).environmentObject(store))
                host.sizingOptions = (role == .widgets && free) ? [] : .preferredContentSize
                window.contentViewController = host
                if role == .widgets && free { window.setFrame(screen.frame, display: false) }
                window.onResize = { [weak self, weak window] in
                    guard let self, let window,
                          let screen = NSScreen.screens.first(where: { WallpaperBaker.key(for: $0) == key }) else { return }
                    self.position(window, on: screen)
                    if role == .widgets, let player = self.windows[key + "#player"] { self.position(player, on: screen) }
                }
                position(window, on: screen)
                let moved = SkyLight.shared.moveToLockScreen(window)
                lockLog.notice("Created lock \(role == .widgets ? "widgets" : "player", privacy: .public) window for \(key, privacy: .public), moved: \(moved)")
                windows[id] = window
            }
        }
    }

    /// Widgets: centred on their placement. Player: its own placement, or centred under the widgets.
    private func position(_ window: NSWindow, on screen: NSScreen) {
        guard let cfg = settings?.config else { return }
        let size = window.frame.size
        var frame: NSRect
        let panel = window as? LockPanel
        if panel?.role == .widgets, cfg.freeLayout {
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            return
        }
        if panel?.role == .player, cfg.freeLayout {
            let placement = cfg.playerPlacement ?? settings!.defaultFreePlayerPlacement
            let origin = placement.origin(for: size, in: screen.frame.size)
            frame = NSRect(x: screen.frame.minX + origin.x, y: screen.frame.maxY - origin.y - size.height,
                           width: size.width, height: size.height)
        } else if panel?.role == .player, cfg.playerPlacement == nil,
           let widgets = windows[WallpaperBaker.key(for: screen)] {
            let w = widgets.frame
            frame = NSRect(x: w.midX - size.width / 2, y: w.minY - size.height, width: size.width, height: size.height)
            frame.origin.x = min(max(screen.frame.minX, frame.origin.x), screen.frame.maxX - size.width)
            frame.origin.y = max(screen.frame.minY, frame.origin.y)
        } else {
            let placement = panel?.role == .player ? (cfg.playerPlacement ?? cfg.lockScreenPlacement) : cfg.lockScreenPlacement
            let origin = placement.origin(for: size, in: screen.frame.size)
            frame = NSRect(x: screen.frame.minX + origin.x, y: screen.frame.maxY - origin.y - size.height,
                           width: size.width, height: size.height)
        }
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    func repositionAll() {
        // Widgets first, so an auto-placed player can follow them.
        let ordered = windows.values.sorted { ($0 as? LockPanel)?.role == .widgets && ($1 as? LockPanel)?.role != .widgets }
        for window in ordered {
            guard let key = (window as? LockPanel)?.screenKey,
                  let screen = NSScreen.screens.first(where: { WallpaperBaker.key(for: $0) == key }) else { continue }
            position(window, on: screen)
        }
    }

    private func show() {
        ensureWindows()
        for window in windows.values {
            // orderOut can drop a window back into the normal desktop spaces, so re-join the
            // lock-screen space every time before showing (move, then show).
            SkyLight.shared.moveToLockScreen(window)
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            for window in windows.values { window.animator().alphaValue = 1 }
        }
        // The fade doesn't run while the display is asleep, which left the widgets stuck invisible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.isShowing else { return }
            for window in self.windows.values where window.alphaValue < 1 { window.alphaValue = 1 }
        }
        isShowing = !windows.isEmpty
        lastShownAt = Date()
        lockLog.notice("Showing \(self.windows.count) lock window(s)")
    }

    private func reshowAfterWake() {
        guard isLocked || Self.sessionIsLocked() else { return }
        for delay in [0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let sessionLocked = Self.sessionIsLocked()
                if !self.isLocked, sessionLocked { self.didLock(source: "wake"); return }
                // Waking with Touch ID / Apple Watch can unlock before (or without) an unlock
                // notification reaching us. Re-showing just because `isLocked` was still true put the
                // lock-screen widgets back over the desktop. The session flag can lag a moment after
                // wake, so only the later check unlocks; neither check re-shows.
                if self.isLocked, !sessionLocked {
                    if delay >= 1.5 { self.didUnlock(source: "wake") }
                    return
                }
                guard self.isLocked, self.enabled else { return }
                self.show()
            }
        }
    }

    private func hide() {
        for window in windows.values { window.orderOut(nil) }
        isShowing = false
    }

    private func rebuildWindows() {
        let wasShowing = isShowing
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
        if wasShowing { show() }
    }
}

/// Content-sized panel on the lock-screen layer; reports resizes so it can stay on its placement.
final class LockPanel: NSPanel, NSWindowDelegate {
    enum Role { case widgets, player }
    var role: Role = .widgets
    var screenKey = ""
    var onResize: (() -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        delegate = self
    }

    override var canBecomeKey: Bool { true }

    func windowDidResize(_ notification: Notification) { onResize?() }
}
