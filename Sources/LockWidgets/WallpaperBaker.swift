import AppKit
import Combine
import SwiftUI

/// macOS does not let third-party apps draw on the lock screen. The lock screen does show
/// the desktop picture, so this (opt-in) feature renders the widgets into a copy of the
/// user's wallpaper and sets that as the desktop picture. The original is remembered and
/// restored when the feature is turned off or the app quits.
@MainActor
final class WallpaperBaker {
    private let settings: AppSettings
    private let store: WidgetStore
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lockObserver: NSObjectProtocol?
    private(set) var lastError: String?

    let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LockWidgets/Wallpapers", isDirectory: true)
    }()

    init(settings: AppSettings, store: WidgetStore) {
        self.settings = settings
        self.store = store

        settings.$config
            .map(\.wallpaperMode)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in on ? self?.enable() : self?.disable() }
            .store(in: &cancellables)

        // Re-render when the look or data changes (debounced so slider drags don't thrash).
        settings.$config
            .map { cfg -> String in
                var look = cfg
                look.originalWallpapers = [:]
                let data = try? JSONEncoder().encode(look)
                return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.bake() }
            .store(in: &cancellables)

        Publishers.Merge(
            store.$weather.map { _ in () }.eraseToAnyPublisher(),
            store.$peripherals.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(2)
        .debounce(for: .seconds(5), scheduler: RunLoop.main)
        .sink { [weak self] in self?.bake() }
        .store(in: &cancellables)

        // A display connected, removed or changed resolution kept the old render (wrong size, or none
        // for the new screen, so its lock screen showed no widgets) until the 5-minute timer.
        // bake() records new displays' originals and does nothing when the mode is off.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.bake() }
            .store(in: &cancellables)
    }

    static func key(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "display-\($0.uint32Value)" } ?? screen.localizedName
    }

    /// The user's real wallpaper for a screen (not our rendered copy).
    func originalWallpaper(for screen: NSScreen) -> URL? {
        if let path = settings.config.originalWallpapers[Self.key(for: screen)] {
            return URL(fileURLWithPath: path)
        }
        guard let current = NSWorkspace.shared.desktopImageURL(for: screen), !isOurs(current) else { return nil }
        return current
    }

    private func isOurs(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
    }

    private func enable() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var originals = settings.config.originalWallpapers
        for screen in NSScreen.screens {
            let key = Self.key(for: screen)
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen), !isOurs(url) else { continue }
            originals[key] = url.path
        }
        if originals != settings.config.originalWallpapers {
            settings.config.originalWallpapers = originals
        }

        bake()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in AppDelegate.shared?.baker?.bake() }
        }
        if lockObserver == nil {
            lockObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { _ in
                Task { @MainActor in AppDelegate.shared?.baker?.bake() }
            }
        }
    }

    private func disable() {
        timer?.invalidate()
        timer = nil
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
            self.lockObserver = nil
        }
        restoreOriginals()
        if !settings.config.originalWallpapers.isEmpty {
            settings.config.originalWallpapers = [:]
        }
    }

    /// Put the user's wallpapers back and delete our rendered images — except any image a
    /// display is still showing because we had no original to restore for it.
    func restoreOriginals() {
        var stillInUse = Set<String>()
        for screen in NSScreen.screens {
            // Only displays still showing our render need restoring; one where the user picked a
            // new picture in the meantime keeps it.
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen), isOurs(current) else { continue }
            var restored = false
            if let path = settings.config.originalWallpapers[Self.key(for: screen)],
               FileManager.default.fileExists(atPath: path) {
                restored = (try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])) != nil
            }
            // If the original is gone (or macOS refused it), deleting the render would leave the
            // display on a missing file; keep it until the user picks a new wallpaper.
            if !restored { stillInUse.insert(current.standardizedFileURL.path) }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where !stillInUse.contains(file.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private var retryScheduled = false

    func bake() {
        guard settings.config.wallpaperMode else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lastError = nil

        // Remember the real wallpaper of displays connected after the mode was turned on, and pick
        // up a picture the user chose since (anything showing that isn't our render is the real one),
        // so it is neither overwritten with the old original nor lost on restore.
        var originals = settings.config.originalWallpapers
        for screen in NSScreen.screens {
            let key = Self.key(for: screen)
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), !isOurs(url) {
                originals[key] = url.path
            }
        }
        if originals != settings.config.originalWallpapers { settings.config.originalWallpapers = originals }

        for screen in NSScreen.screens {
            let key = Self.key(for: screen)
            let original = originals[key].map { URL(fileURLWithPath: $0) }
            let background = WallpaperThumbnails.shared.image(for: original)
            if let original, background == nil, !WallpaperThumbnails.shared.hasFailed(original) {
                // Still loading in the background (never block on a privacy prompt): one retry later.
                if !retryScheduled {
                    retryScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.retryScheduled = false
                        self?.bake()
                    }
                }
                continue
            }

            // Render on the main thread (SwiftUI), encode + write in the background.
            guard let image = Self.renderImage(size: screen.frame.size, scale: screen.backingScaleFactor,
                                               background: background, screenKey: key,
                                               settings: settings, store: store) else {
                lastError = "Couldn't render wallpaper"
                continue
            }
            // A new file name each time, otherwise macOS keeps showing its cached copy.
            let url = directory.appendingPathComponent("\(key)-\(Int(Date().timeIntervalSince1970)).jpg")
            let directory = self.directory
            DispatchQueue.global(qos: .utility).async {
                guard let data = NSBitmapImageRep(cgImage: image)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.92]),
                      (try? data.write(to: url, options: .atomic)) != nil else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard AppSettings.shared.config.wallpaperMode,
                              let screen = NSScreen.screens.first(where: { Self.key(for: $0) == key }) else {
                            try? FileManager.default.removeItem(at: url)
                            return
                        }
                        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                            .allowClipping: true,
                        ])
                        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                            for file in files where file.lastPathComponent.hasPrefix("\(key)-") && file != url {
                                try? FileManager.default.removeItem(at: file)
                            }
                        }
                    }
                }
            }
        }
    }

    static func renderImage(size: CGSize, scale: CGFloat, background: NSImage?, screenKey: String?,
                            settings: AppSettings, store: WidgetStore) -> CGImage? {
        let view = BakedWallpaperView(background: background, size: size, screenKey: screenKey)
            .environmentObject(settings)
            .environmentObject(store)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    static func render(size: CGSize, scale: CGFloat, background: NSImage?, screenKey: String?,
                       settings: AppSettings, store: WidgetStore) -> Data? {
        guard let cg = renderImage(size: size, scale: scale, background: background, screenKey: screenKey,
                                   settings: settings, store: store) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }
}
