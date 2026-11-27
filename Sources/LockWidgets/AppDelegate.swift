import AppKit
import Combine
import ServiceManagement
import SwiftUI
import LockWidgetsCore

/// Menu-bar-only app (no Dock icon) that puts widgets on the macOS lock screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    let settings = AppSettings.shared
    let store = WidgetStore.shared
    private(set) var baker: WallpaperBaker?
    private(set) var lockOverlay: LockScreenOverlay?
    private(set) var notch: NotchController?
    private(set) var desktopWidgets: DesktopWidgetsController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN) // a closed pipe/socket must never kill the app
        if CommandLine.arguments.contains("--spotify-modes-test") {
            Task { @MainActor in
                await SpotifyClient.shared.modesTest()
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--spotify-selftest") {
            Task { @MainActor in
                await SpotifyClient.shared.selfTest()
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--test-notifications") {
            NotificationMirror.selfTest()
            NSApp.terminate(nil)
            return
        }
        if let dir = Snapshot.outputDirectory {
            Snapshot.run(into: dir, settings: settings, store: store)
            return
        }

        baker = WallpaperBaker(settings: settings, store: store)
        store.start()
        lockOverlay = LockScreenOverlay(settings: settings, store: store)
        MediaController.shared.start()
        NotificationMirror.shared.start()
        DiscordPresence.shared.start()
        SpotifyClient.shared.start()
        Extras.shared.start()
        notch = NotchController(settings: settings, store: store)
        desktopWidgets = DesktopWidgetsController(settings: settings, store: store)
        settingsWindow = SettingsWindowController(settings: settings, store: store)

        AppActions.shared.openSettings = { [weak self] in self?.settingsWindow?.show() }
        AppActions.shared.openSettingsPage = { [weak self] page in
            SettingsNavigation.shared.page = SettingsPage(rawValue: page)
            self?.settingsWindow?.show()
        }
        AppActions.shared.previewLockScreen = { [weak self] in self?.lockOverlay?.preview() }
        AppActions.shared.showLockPreview = { LockPreviewController.shared.show() }
        AppActions.shared.refreshAll = { WidgetStore.shared.refreshAll() }
        AppActions.shared.rebakeWallpaper = { [weak self] in self?.baker?.bake() }

        setUpStatusItem()
        settings.$config.map(\.showMenuBarIcon).removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] show in self?.statusItem?.isVisible = show }
            .store(in: &cancellables)

        if !settings.config.hasLaunchedBefore {
            settings.config.hasLaunchedBefore = true
            // On a fresh install the welcome opens instead; Settings behind it was a second window.
            if settings.config.onboardingDone { settingsWindow?.show() }
        }
        enableLaunchAtLoginOnce()

        if CommandLine.arguments.contains("--open-settings") { settingsWindow?.show() }
        // First launch (or --welcome): greeting, features, permissions.
        if !settings.config.onboardingDone || CommandLine.arguments.contains("--welcome") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { OnboardingController.shared.show() }
        }
        // `--show-island` switches the island back on (and opening the app again does the same).
        if CommandLine.arguments.contains("--show-island") { settings.config.notchEnabled = true }
        if let i = CommandLine.arguments.firstIndex(of: "--set-spotify-client"), i + 1 < CommandLine.arguments.count {
            settings.config.spotifyClientID = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SpotifyClient.shared.connect() }
        }
        // `--preview-lock`: show the lock-screen layer once (used for testing placement).
        if CommandLine.arguments.contains("--preview-lock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AppDelegate.shared?.lockOverlay?.preview() }
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows Settings, since there is no window otherwise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-opening Notch always brings the island back if it was switched off.
        if !settings.config.notchEnabled { settings.config.notchEnabled = true }
        settingsWindow?.show()
        return true
    }

    /// Runs quietly in the background from login, so it never needs to be opened by hand.
    /// Done once, and only for the copy in /Applications (so dev builds don't register).
    private func enableLaunchAtLoginOnce() {
        // Once only: removing Notch in System Settings › Login Items must stick (registering on every
        // launch re-added it; only the in-app toggle set userDisabledLaunchAtLogin).
        guard !settings.config.launchAtLoginConfigured, !settings.config.userDisabledLaunchAtLogin,
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        settings.config.launchAtLoginConfigured = true
        if SMAppService.mainApp.status != .enabled {
            do {
                try SMAppService.mainApp.register()
                lockLog.notice("Registered as login item")
            } catch {
                lockLog.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave a frozen snapshot on the lock screen once we're not running.
        if settings.config.wallpaperMode { baker?.restoreOriginals() }
    }

    // MARK: Menu bar

    private enum Tag: Int { case lockScreen = 1 }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.make()

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("Show Widgets on Lock Screen", #selector(toggleLockScreen), tag: .lockScreen))
        menu.addItem(menuItem("Preview on Lock Screen", #selector(previewLockScreen), key: "p"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Refresh Now", #selector(refresh), key: "r"))
        menu.addItem(menuItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", tag: Tag? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let tag { item.tag = tag.rawValue }
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: Tag.lockScreen.rawValue)?.state = settings.config.lockScreenWidgets ? .on : .off
    }

    @objc private func toggleLockScreen() { settings.config.lockScreenWidgets.toggle() }
    @objc private func previewLockScreen() { lockOverlay?.preview() }
    @objc private func refresh() { store.refreshAll(); baker?.bake() }
    @objc private func openSettings() { settingsWindow?.show() }
}

// MARK: - Snapshot mode (used for verification and artwork)

/// `Notch --snapshot <dir> [--city <name>] [--demo-devices]` renders PNGs of the widgets
/// and exits, without touching saved settings or the wallpaper. Without `--city` it uses the
/// Mac's real location; `--demo-devices` adds sample devices (snapshot only, never in the app).
@MainActor
enum Snapshot {
    static var outputDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(into dir: URL, settings: AppSettings, store: WidgetStore) {
        settings.persist = false
        let args = CommandLine.arguments
        var base = Config()
        base.onboardingDone = true // snapshots may use the real location (never persisted)
        if let i = args.firstIndex(of: "--city"), i + 1 < args.count {
            base.locationMode = .city
            base.city = args[i + 1]
        }
        base.widgets = base.widgets.map { var e = $0; if e.kind == .calendar { e.enabled = false }; return e }
        settings.config = base
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.start()
        if args.contains("--demo-devices") { store.injectDemoDevices() }

        Task { @MainActor in
            for _ in 0..<70 where store.weather == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(2))

            let screen = NSScreen.screens.first
            let key = screen.map(WallpaperBaker.key(for:))
            let size = CGSize(width: 1470, height: 956)
            let wallpaper = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap(WallpaperThumbnails.load)

            @MainActor func lockComposite(_ name: String, wallpaper: NSImage?) {
                let view = ZStack(alignment: .topLeading) {
                    WallpaperBackground(image: wallpaper, size: size)
                    FakeSystemLockScreen(size: size)
                    PlacedStrip(screenKey: key).frame(width: size.width, height: size.height)
                }
                .frame(width: size.width, height: size.height)
                write(view, to: dir.appendingPathComponent(name))
            }

            @MainActor func strip(_ name: String) {
                let view = WidgetStripView(screenKey: key)
                    .fixedSize()
                    .background(LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.30), Color(red: 0.42, green: 0.22, blue: 0.45)],
                                               startPoint: .leading, endPoint: .trailing))
                    .environment(\.isWidgetPreview, true)
                write(view, to: dir.appendingPathComponent(name))
            }

            let icon = MenuBarIcon.make(size: 72)
            if let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("menubar-icon.png"))
            }

            lockComposite("lock-round.png", wallpaper: wallpaper)
            lockComposite("lock-round-gradient.png", wallpaper: nil)
            strip("strip-round.png")

            settings.config.widgets = settings.config.widgets.map { var e = $0; e.size = .expanded; return e }
            strip("strip-wide.png")

            settings.config = base
            settings.config.visualStyle = .cards
            strip("strip-cards.png")

            settings.config = base
            settings.config.glyphTheme = .black
            lockComposite("lock-black-glyphs.png", wallpaper: nil)

            let summary = """
            mac: \(store.mac.map { "\($0.level)% charging=\($0.isCharging) plugged=\($0.isPluggedIn)" } ?? "none")
            peripherals: \(store.peripherals.map { "\($0.displayName)=\($0.level)%" })
            weather: \(store.weather.map { "\($0.locationName) \($0.temperature)\($0.unit.symbol) \($0.condition) H\($0.high) L\($0.low) aqi=\($0.airQuality.map(String.init) ?? "nil")" } ?? "none (\(store.weatherStatus ?? "-"))")
            theme: dark=\(store.isDarkMode) wallpaperLight=\(store.wallpaperIsLight)
            """
            print(summary)
            NSApp.terminate(nil)
        }
    }

    private static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view
            .environment(\.bakedRendering, true)
            .environmentObject(AppSettings.shared)
            .environmentObject(WidgetStore.shared))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("render failed: \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}
