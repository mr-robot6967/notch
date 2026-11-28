import AppKit
import ApplicationServices
import Combine
import CoreAudio
import IOBluetooth
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import LockWidgetsCore

// MARK: - State

/// Short-lived events shown in the notch.
enum LiveActivity: Equatable {
    case charging(level: Int, state: ChargeState)
    case lowBattery(level: Int)
    case device(name: String, symbol: String, level: Int?)
    case volume(level: Float, muted: Bool)
    case brightness(level: Float)
    case unlocked
    case timerDone
    case notification(MirroredNotification)
    case event(title: String, minutes: Int, colorHex: String?)
    case lowPower(Bool)
    case focus(Bool)
    case songChange(title: String, artist: String)

    /// Key used by Settings › Activities to turn each kind on or off.
    var settingKey: String {
        switch self {
        case .charging: return "charging"
        case .lowBattery: return "lowBattery"
        case .device: return "devices"
        case .volume: return "volume"
        case .brightness: return "brightness"
        case .unlocked: return "unlock"
        case .timerDone: return "timer"
        case .notification: return "notifications"
        case .event: return "calendar"
        case .lowPower: return "lowPower"
        case .focus: return "focus"
        case .songChange: return "songChange"
        }
    }
}

enum HUDKind: Equatable { case volume, brightness }

/// Pages of the expanded notch (swipe vertically to change).
enum NotchPage: String, CaseIterable, Identifiable, Codable {
    case nowPlaying, notifications, calendar, widgets, shelf, timer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .notifications: return "Notifications"
        case .calendar: return "Calendar"
        case .widgets: return "Widgets (weather, batteries, calendar)"
        case .shelf: return "File Shelf"
        case .timer: return "Timer"
        }
    }
}

/// One set of springs for the whole island so every change morphs the same, smooth way.
enum IslandMotion {
    // Measured from the reference: open overshoots ~7 % and settles in ~450 ms; close is a
    // critically damped ~200 ms; activities overshoot slightly and settle in ~330 ms.
    static let open = Animation.spring(response: 0.34, dampingFraction: 0.62)
    static let close = Animation.spring(response: 0.22, dampingFraction: 1.0)
    static let activity = Animation.spring(response: 0.3, dampingFraction: 0.68)
    static let hover = Animation.spring(response: 0.34, dampingFraction: 0.72)
    static let page = Animation.spring(response: 0.4, dampingFraction: 0.86)
    /// Now Playing / Now Watching retracting into the notch: slow, soft, no overshoot (~0.6 s).
    static let retract = Animation.spring(response: 0.6, dampingFraction: 1.0)
}

@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    /// Horizontal nudge of the whole island when a song is skipped (points; springs back to 0).
    @Published var nudge: CGFloat = 0

    /// One big jiggle in `direction` (-1 left, +1 right): lurch, then a wobbly spring back.
    func jiggle(_ direction: CGFloat) {
        let cfg = AppSettings.shared.config
        guard cfg.skipJiggle else { return }
        withAnimation(.easeOut(duration: 0.09)) { nudge = CGFloat(cfg.skipJiggleAmount) * direction }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.32)) { self.nudge = 0 }
        }
    }

    @Published var expanded = false
    @Published var hovering = false
    @Published var locked = false
    @Published private(set) var transient: LiveActivity?
    @Published var page: NotchPage = .nowPlaying
    @Published var dropTargeted = false
    /// -1...1: where the pointer is across the open island, for the subtle 3D tilt.
    @Published var pointerX: CGFloat = 0

    private var clearWork: DispatchWorkItem?
    /// When the current transient appeared (statuses are protected briefly from automatic pop-ups).
    private(set) var transientSince = Date.distantPast
    /// A song-change peek that arrived while a status was showing; played when it ends.
    private var pendingPeek: (activity: LiveActivity, at: Date)?

    /// Status-type activities that automatic changes (volume after a device switch, song peeks)
    /// must not cut off.
    static func isStatus(_ a: LiveActivity?) -> Bool {
        switch a {
        case .charging, .lowBattery, .device, .unlocked, .focus, .lowPower, .timerDone: return true
        default: return false
        }
    }

    /// True while a status appeared less than `window` seconds ago.
    func statusIsFresh(_ window: TimeInterval = 1.5) -> Bool {
        Self.isStatus(transient) && Date().timeIntervalSince(transientSince) < window
    }

    /// A page shown for this opening only (replying to a banner when the Notifications page is off).
    @Published var forcedPage: NotchPage?

    var availablePages: [NotchPage] {
        let enabled = Set(AppSettings.shared.config.notchPages)
        let pages = NotchPage.allCases.filter { enabled.contains($0.rawValue) || $0 == forcedPage }
        return pages.isEmpty ? [.nowPlaying] : pages
    }

    // Why the page is what it is. `page` used to persist forever, so a page switched to for one
    // task (the shelf while dragging a file, Notifications for a reply) was still what the island
    // opened on much later, e.g. the shelf instead of the song that's now playing.
    /// When the user last picked a page themselves (swipe, page dot).
    private(set) var pageChosenByUserAt: Date?
    /// The current page was switched to automatically for a task, not chosen by the user.
    private(set) var autoPage = false
    /// A manual choice is kept for openings within this long; after that context decides again.
    static let manualPageMemory: TimeInterval = 120

    /// The user picked a page.
    func choosePage(_ newPage: NotchPage) {
        page = newPage
        pageChosenByUserAt = Date()
        autoPage = false
    }

    /// A page switched to automatically for a task (drop on the shelf, reply, a page turned off).
    func showPageAutomatically(_ newPage: NotchPage) {
        page = newPage
        autoPage = true
    }

    /// The page an opening should show: a recent manual choice is kept; otherwise what's going on
    /// decides (music playing → Now Playing, a running timer → Timer, else the first page).
    func pickPageForOpening() {
        let pages = availablePages
        if let forcedPage, pages.contains(forcedPage) { page = forcedPage; return }
        let recentChoice = !autoPage && pageChosenByUserAt.map { Date().timeIntervalSince($0) < Self.manualPageMemory } == true
        if recentChoice, pages.contains(page) { return }
        let contextual: NotchPage
        if MediaController.shared.info?.isPlaying == true, pages.contains(.nowPlaying) {
            contextual = .nowPlaying
        } else if NotchTimer.shared.isRunning, pages.contains(.timer) {
            contextual = .timer
        } else {
            contextual = pages[0]
        }
        page = contextual
        autoPage = true // chosen by context, so the next opening re-evaluates too
    }

    func cyclePage(forward: Bool) {
        let pages = availablePages
        guard let index = pages.firstIndex(of: page) else { choosePage(pages[0]); return }
        let next = (index + (forward ? 1 : -1) + pages.count) % pages.count
        withAnimation(IslandMotion.page) { choosePage(pages[next]) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Shows a live activity for a few seconds (if that kind is enabled in Settings).
    func dismissTransient() {
        clearWork?.cancel()
        // A song peek queued behind the dismissed status is stale now; never replay it later.
        pendingPeek = nil
        withAnimation(IslandMotion.activity) { transient = nil }
    }

    /// Called when the Mac locks: a message, event or song peek that was already up must not stay
    /// readable on the lock screen until its timer runs out.
    func hidePrivateTransient() {
        switch transient {
        case .notification, .event, .songChange: dismissTransient()
        default: break
        }
    }

    /// Returns false when the activity was held back (turned off, Focus, locked).
    @discardableResult
    func flash(_ activity: LiveActivity, seconds: Double = 3) -> Bool {
        let cfg = AppSettings.shared.config
        guard cfg.notchEnabled, !cfg.disabledActivities.contains(activity.settingKey) else { return false }
        // Respect Do Not Disturb / Focus (Settings › Focus).
        switch activity {
        case .notification: if FocusWatcher.shared.holds(.notification) { return false }
        case .event, .songChange: if FocusWatcher.shared.holds(.peek) { return false }
        default: break
        }
        // Never show message or event text on the lock screen.
        if locked {
            switch activity {
            case .notification, .event, .songChange: return false
            default: break
            }
        }
        // A song peek never cuts off a status that is still on screen; it plays right after.
        if case .songChange = activity, Self.isStatus(transient) {
            pendingPeek = (activity, Date())
            return true
        }
        withAnimation(IslandMotion.activity) { transient = activity }
        transientSince = Date()
        var seconds = seconds
        if case .notification = activity {
            seconds = cfg.notificationSeconds
        } else {
            let group = AppSettings.durationGroup(for: activity.settingKey)
            if let custom = cfg.activityDurations[group] ?? AppSettings.defaultDurations[group] { seconds = custom }
        }
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(IslandMotion.activity) { self.transient = nil }
            if let pending = self.pendingPeek {
                self.pendingPeek = nil
                if Date().timeIntervalSince(pending.at) < 6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.flash(pending.activity) }
                }
            }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return true
    }
}

@MainActor
final class NotchTimer: ObservableObject {
    static let shared = NotchTimer()
    @Published private(set) var endDate: Date?
    @Published private(set) var total: TimeInterval = 0
    private var ticker: Timer?

    var isRunning: Bool { endDate != nil }

    func start(minutes: Int) {
        total = TimeInterval(minutes * 60)
        endDate = Date().addingTimeInterval(total)
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { NotchTimer.shared.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    private func tick() {
        guard remaining() <= 0 else { return }
        cancel()
        NSSound(named: "Glass")?.play()
        NotchModel.shared.flash(.timerDone, seconds: 6)
    }
}

/// Things dropped on the notch, kept between launches. Files and folders are kept by path; dragged
/// content that isn't a file (an image from a browser, text, a link) is saved as a file in the
/// app's cache folder first, so every item can be dragged back out.
@MainActor
final class ShelfModel: ObservableObject {
    static let shared = ShelfModel()
    static let capacity = 10
    /// Anything can be dropped; `load` decides how to keep it.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .url, .text, .item]

    /// Oldest first, newest last.
    @Published private(set) var items: [URL] = []
    /// A short message shown on the shelf (e.g. when the oldest items made room for new ones).
    @Published private(set) var notice: String?
    /// Quick Look thumbnails by item (the Finder icon is shown until one arrives).
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    private var noticeWork: DispatchWorkItem?

    nonisolated static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notch", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
    }

    private init() {
        // Saved items whose files are gone (moved, deleted, cache cleared) are dropped.
        let saved = AppSettings.shared.config.shelfItems
        let existing = saved.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        items = Array(existing.suffix(Self.capacity))
        if items.map(\.path) != saved { save() }
        sweepCache()
    }

    /// Deletes files in our cache folder that no shelf item points to. Removing/evicting an item
    /// deletes its file, but files could still be orphaned (a crash between writing a drop and
    /// saving the list, saved items trimmed above, a failed write), and nothing else would ever
    /// delete them, so the cache could grow forever. Runs once at launch, before any drop is
    /// in flight, so it can't race a file that's being written.
    private func sweepCache() {
        let fm = FileManager.default
        let dir = Self.cacheDir.standardizedFileURL
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let kept = Set(items.map { $0.standardizedFileURL.path })
        for file in files where !kept.contains(file.standardizedFileURL.path) {
            try? fm.removeItem(at: file)
        }
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var list = items
        for url in urls {
            let url = url.standardizedFileURL
            // The same file again moves it to the newest spot instead of showing it twice.
            list.removeAll { $0.standardizedFileURL == url }
            list.append(url)
        }
        if list.count > Self.capacity {
            let dropped = list.prefix(list.count - Self.capacity)
            list.removeFirst(list.count - Self.capacity)
            dropped.forEach(deleteIfCached)
            showNotice("Shelf holds \(Self.capacity) items")
        }
        items = list
        save()
        list.forEach(loadThumbnail)
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        deleteIfCached(url)
        save()
    }

    func clear() {
        items.forEach(deleteIfCached)
        items.removeAll()
        save()
    }

    private func save() { AppSettings.shared.config.shelfItems = items.map(\.path) }

    private func showNotice(_ text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { ShelfModel.shared.notice = nil } }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Files we created for non-file drops are ours to delete; the user's own files never are.
    private func deleteIfCached(_ url: URL) {
        thumbnails[url] = nil
        guard url.standardizedFileURL.path.hasPrefix(Self.cacheDir.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func loadThumbnail(_ url: URL) {
        guard thumbnails[url] == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 44, height: 44), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let cg = rep?.cgImage else { return }
            let size = NSSize(width: cg.width, height: cg.height)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shelf = ShelfModel.shared
                    guard shelf.items.contains(url) else { return }
                    shelf.thumbnails[url] = NSImage(cgImage: cg, size: size)
                }
            }
        }
    }

    /// Collects one result per dragged item, then adds them in drag order. Main-actor isolated, so
    /// the loaders' callbacks can hold it and hop back to main to fill it in.
    @MainActor private final class DropBatch {
        var results: [URL?]
        var remaining: Int
        init(count: Int) { results = Array(repeating: nil, count: count); remaining = count }
    }

    /// Loads every item of a drop (not just the first), then adds them and opens the shelf.
    func accept(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let dir = Self.cacheDir
        let box = DropBatch(count: providers.count)
        for (index, provider) in providers.enumerated() {
            Self.load(provider, into: dir) { url in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        box.results[index] = url
                        box.remaining -= 1
                        guard box.remaining == 0 else { return }
                        ShelfModel.shared.finishDrop(box.results.compactMap { $0 })
                    }
                }
            }
        }
    }

    private func finishDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        add(urls)
        guard !NotchModel.shared.locked, AppSettings.shared.config.notchExpandMode != .never else { return }
        AppDelegate.shared?.notch?.expand(on: .shelf)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Turns one dragged item into a file URL: files/folders as they are; images, links, text and
    /// other data written to the cache folder.
    nonisolated private static func load(_ provider: NSItemProvider, into dir: URL, done: @escaping @Sendable (URL?) -> Void) {
        let name = provider.suggestedName
        func has(_ type: UTType) -> Bool { provider.hasItemConformingToTypeIdentifier(type.identifier) }
        if has(.fileURL) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done(url?.isFileURL == true ? url : nil) }
        } else if has(.image) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { done(nil); return }
                done(write(png, name: name ?? "Image", ext: "png", in: dir))
            }
        } else if has(.url) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { done(nil); return }
                let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                done(plist.flatMap { write($0, name: name ?? url.host ?? "Link", ext: "webloc", in: dir) })
            }
        } else if has(.text) {
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? NSString, text.length > 0 else { done(nil); return }
                done(write(Data((text as String).utf8), name: name ?? "Text", ext: "txt", in: dir))
            }
        } else if let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: { $0.conforms(to: .data) }) {
            // Other data (e.g. a file promise's contents): copy the temporary file it's handed in.
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { tmp, _ in
                guard let tmp, let data = try? Data(contentsOf: tmp) else { done(nil); return }
                let base = name ?? tmp.deletingPathExtension().lastPathComponent
                done(write(data, name: base, ext: tmp.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "data") : tmp.pathExtension, in: dir))
            }
        } else {
            done(nil)
        }
    }

    /// Writes `data` as "<name>.<ext>" in `dir`, never overwriting an earlier drop.
    nonisolated private static func write(_ data: Data, name: String, ext: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Item" }
        if base.lowercased().hasSuffix("." + ext) { base = String(base.dropLast(ext.count + 1)) }
        base = String(base.prefix(80))
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}

// MARK: - System monitors

/// Watches the default output device's volume/mute through CoreAudio (no polling).
@MainActor
final class VolumeMonitor {
    var onChange: ((Float, Bool) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var registered: [AudioObjectPropertyAddress] = []
    private var lastVolume: Float = -1
    private var lastMuted = false
    private var attachedAt = Date()
    private lazy var deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.changed() }
    }
    private lazy var defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.attach() }
    }

    /// Headphones in/out of the jack switch the built-in device's data source (same device ID), and
    /// the new route reports its own volume: re-baseline instead of treating it as a user change.
    private lazy var sourceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.attach() }
    }
    private var wakeObserver: NSObjectProtocol?

    func start() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultBlock)
        attach()
        // After sleep the audio devices are re-enumerated and report their volume again (and a
        // device can come back with a new ID); re-attach so that is a baseline, not a pop-up.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    private func attach() {
        for var address in registered {
            let block = address.mSelector == kAudioDevicePropertyDataSource ? sourceBlock : deviceBlock
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
        registered.removeAll()
        // Until the new device is known, swallow changes (a failed lookup below used to leave the
        // monitor detached for good; now the next default-device/wake callback re-attaches).
        attachedAt = Date()

        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return }
        device = id

        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element in [kAudioObjectPropertyElementMain, 1] {
                var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                if AudioObjectHasProperty(device, &a) {
                    AudioObjectAddPropertyListenerBlock(device, &a, .main, deviceBlock)
                    registered.append(a)
                    break
                }
            }
        }
        var source = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &source) {
            AudioObjectAddPropertyListenerBlock(device, &source, .main, sourceBlock)
            registered.append(source)
        }
        // Baseline, so switching devices doesn't pop the HUD.
        (lastVolume, lastMuted) = read()
        attachedAt = Date()
    }

    private func read() -> (Float, Bool) {
        var volume: Float32 = 0
        var muted: UInt32 = 0
        for element in [kAudioObjectPropertyElementMain, 1] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                               mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &volume) == noErr { break }
        }
        var m = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &m) { _ = AudioObjectGetPropertyData(device, &m, 0, nil, &size, &muted) }
        return (volume, muted != 0)
    }

    private func changed() {
        let (volume, muted) = read()
        guard abs(volume - lastVolume) > 0.001 || muted != lastMuted else { return }
        lastVolume = volume
        lastMuted = muted
        // A new output (AirPods, headphones) reports its own volume a moment after switching; that
        // isn't the user changing the volume, so no pop-up for it.
        guard Date().timeIntervalSince(attachedAt) > 2.5 else { return }
        onChange?(volume, muted)
    }
}

/// Fires when a Bluetooth device (AirPods, keyboard, mouse…) connects.
final class BluetoothConnectMonitor: NSObject {
    var onConnect: ((String) -> Void)?
    private var notification: IOBluetoothUserNotification?
    private var startedAt = Date()

    private var wakeObserver: NSObjectProtocol?

    func start() {
        startedAt = Date()
        notification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                  selector: #selector(connected(_:device:)))
        // Keyboards, mice and trackpads reconnect by themselves after sleep; that isn't the user
        // connecting something, so the same "already connected" grace applies after wake.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.startedAt = Date()
            }
        }
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // The first callbacks list devices that were already connected — ignore those.
        guard Date().timeIntervalSince(startedAt) > 5 else { return }
        let name = device.name ?? "Bluetooth device"
        DispatchQueue.main.async { self.onConnect?(name) }
    }
}

// MARK: - Window

/// The Dynamic-Island-style panel over the MacBook notch. It lives on the same system layer as the
/// lock-screen widgets, so it stays put when you switch Spaces and also shows on the lock screen.
@MainActor
final class NotchController {
    static let panelSize = CGSize(width: 760, height: 300)

    private let panel: NSPanel
    private let model = NotchModel.shared
    private let settings: AppSettings
    private let store: WidgetStore
    private let volume = VolumeMonitor()
    private let bluetooth = BluetoothConnectMonitor()
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var lastPluggedIn: Bool?
    private var lastChargeState: ChargeState?
    private var lastStateFlash = Date.distantPast
    private var warnedLowAt: Int?
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var lastGesture = Date.distantPast
    private var lastScrollEvent = Date.distantPast
    private var gestureConsumed = false
    private var lastInZone = false
    private(set) var geometry = NotchGeometry.current()

    init(settings: AppSettings, store: WidgetStore) {
        self.settings = settings
        self.store = store
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.canBecomeVisibleWithoutLogin = true
        panel.animationBehavior = .none
        panel.level = Self.islandLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // A window over the notch gets a "safe area" the height of the notch, and SwiftUI would push
        // the island down by that much. The island must start at the very top edge, so opt out.
        let host = NSHostingView(rootView: NotchRootView(controller: self)
            .environmentObject(settings)
            .environmentObject(store)
            .environmentObject(model))
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        panel.contentView = host

        if CommandLine.arguments.contains("--flash-test") {
            // Plays the widest status pop-ups in turn (to check nothing wraps).
            let samples: [LiveActivity] = [.volume(level: 0.62, muted: false), .brightness(level: 0.35),
                                           .charging(level: 80, state: .onHold), .charging(level: 100, state: .charged),
                                           .charging(level: 100, state: .onBattery),
                                           .lowPower(true), .focus(true)]
            for (i, sample) in samples.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 2.5) { NotchModel.shared.flash(sample, seconds: 2.3) }
            }
        }

        settings.$config
            .map { "\($0.notchEnabled)|\($0.notchWidthAdjust)|\($0.notchHeightAdjust)" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setVisible(AppSettings.shared.config.notchEnabled) }
            .store(in: &cancellables)

        // Re-check fullscreen hiding when its setting or the lock state changes.
        settings.$config.map(\.notchHideInFullscreen).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateFullscreenHiding() }
            .store(in: &cancellables)
        // The Mission Control check polls ~8×/s, so run it only while that (opt-in) setting is on.
        settings.$config.map { $0.notchEnabled && $0.notchHideInMissionControl }.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.startMissionControlWatch() } else { self.stopMissionControlWatch() }
            }
            .store(in: &cancellables)
        model.$locked.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateFullscreenHiding() } }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)

        // Charging + low battery
        store.$mac
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] info in self?.batteryChanged(info) }
            .store(in: &cancellables)

        volume.onChange = { level, muted in
            // Not from the keys and a status just appeared (e.g. AirPods connecting): don't cover it.
            // (3 s: AirPods report their own volume a couple of seconds after the "connected" status.)
            if Date().timeIntervalSince(MediaKeyTap.lastVolumeKeyAt) > 0.6, NotchModel.shared.statusIsFresh(3) { return }
            NotchModel.shared.flash(.volume(level: level, muted: muted), seconds: 1.6)
            if AppSettings.shared.config.notchHaptics && (level <= 0.001 || level >= 0.999 || muted) {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
        volume.start()
        AudioDevices.shared.start()
        BrightnessWatcher.shared.start()

        bluetooth.onConnect = { name in
            MainActor.assumeIsolated { AppDelegate.shared?.notch?.deviceConnected(name) }
        }
        // Registering for Bluetooth connections shows the system Bluetooth prompt; on a fresh
        // install wait until the welcome window is done instead of prompting behind it.
        settings.$config.map(\.onboardingDone).removeDuplicates().filter { $0 }.first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.bluetooth.start() }
            .store(in: &cancellables)

        settings.$config
            .map { $0.replaceSystemHUD && $0.notchEnabled }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { enabled in
                if enabled { MediaKeyTap.shared.start() } else { MediaKeyTap.shared.stop() }
            }
            .store(in: &cancellables)
        // Pick up an Accessibility grant as soon as the user comes back from System Settings.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .receive(on: RunLoop.main)
            .sink { _ in
                let cfg = AppSettings.shared.config
                if cfg.replaceSystemHUD && cfg.notchEnabled && !MediaKeyTap.shared.isRunning { MediaKeyTap.shared.start() }
            }
            .store(in: &cancellables)

        // Settings that change what the open island may show take effect right away: "Compact only"
        // closes it, and a page that was just turned off is replaced by one that's still on.
        settings.$config
            .map { "\($0.notchExpandMode.rawValue)|\($0.notchPages)" }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settings.config.notchExpandMode == .never, self.model.expanded { self.collapse() }
                let pages = self.model.availablePages
                if !pages.contains(self.model.page) { self.model.showPageAutomatically(pages[0]) }
            }
            .store(in: &cancellables)

        settings.$config
            .map(\.notchHideFromCapture)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hide in self?.panel.sharingType = hide ? .none : .readOnly }
            .store(in: &cancellables)

        // Hide over fullscreen apps (videos, games); checked when apps or Spaces change.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .delay(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFullscreenHiding()
                withAnimation(IslandMotion.activity) { self?.model.objectWillChange.send() }
            }
            .store(in: &cancellables)

        // Going to sleep with the island open (or hovered) left it stuck that way after wake: the
        // collapse only runs on the next mouse move. Reset the transient UI state on sleep.
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.screensDidSleepNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hoverWork?.cancel(); self.hoverWork = nil
                self.collapseWork?.cancel(); self.collapseWork = nil
                if self.model.expanded { self.collapse() }
                if self.model.hovering { self.model.hovering = false }
                self.resetScroll()
            }
            .store(in: &cancellables)
        // Re-check fullscreen/Mission Control hiding and geometry after wake (displays may have changed).
        workspace.publisher(for: NSWorkspace.screensDidWakeNotification)
            .delay(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.reposition()
                self?.updateFullscreenHiding()
            }
            .store(in: &cancellables)

        installEventMonitors()
        reposition()

        // A video's own fullscreen button (Netflix/YouTube going fullscreen inside the browser)
        // changes neither the Space nor the frontmost app, so the observers above miss it and the
        // island would sit over the video. While media is playing (or while already hidden for
        // fullscreen, to catch the exit), re-check once a second. Honours "Hide in fullscreen apps".
        // The timer only exists while it's needed, so an idle Mac isn't woken every second.
        MediaController.shared.$info.map { $0?.isPlaying == true }.removeDuplicates()
            .combineLatest(settings.$config.map { $0.notchEnabled && $0.notchHideInFullscreen }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateFullscreenPolling() }
            .store(in: &cancellables)
    }

    /// Starts the 1 s fullscreen re-check while media plays or the island is hidden, stops it otherwise.
    private func updateFullscreenPolling() {
        let needed = settings.config.notchEnabled && settings.config.notchHideInFullscreen
            && (MediaController.shared.info?.isPlaying == true || hiddenForFullscreen)
        if !needed {
            fullscreenPollTimer?.invalidate()
            fullscreenPollTimer = nil
            return
        }
        guard fullscreenPollTimer == nil else { return }
        let fsTimer = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let self = AppDelegate.shared?.notch else { return }
                self.updateFullscreenPolling()
                if self.fullscreenPollTimer != nil { self.updateFullscreenHiding() }
            }
        }
        fsTimer.tolerance = 0.3
        RunLoop.main.add(fsTimer, forMode: .common)
        fullscreenPollTimer = fsTimer
    }

    private(set) var hiddenForFullscreen = false

    /// Above everything, including the lock screen.
    static let islandLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 3)
    private var missionControlOpen = false
    private var missionControlTimer: Timer?
    private var fullscreenPollTimer: Timer?

    /// Mission Control has no public notification; while it's open the Dock shows a full-screen
    /// window on layer 20. A cheap check a few times a second; the island hides while it's there.
    private func startMissionControlWatch() {
        missionControlTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let self = AppDelegate.shared?.notch, self.settings.config.notchEnabled,
                      self.settings.config.notchHideInMissionControl else { return }
                self.ensureDockObserver()
                var open = Self.missionControlIsOpen()
                // The Dock keeps its window through the closing zoom; once it has said "exit", the
                // island comes back straight away instead of waiting for that window to go.
                if open, let exit = self.exposeExitAt, Date().timeIntervalSince(exit) < 1.0 { open = false }
                if open != self.missionControlOpen {
                    self.missionControlOpen = open
                    self.updateFullscreenHiding()
                }
            }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        missionControlTimer = timer
    }

    private func stopMissionControlWatch() {
        missionControlTimer?.invalidate()
        missionControlTimer = nil
        if missionControlOpen {
            missionControlOpen = false
            updateFullscreenHiding()
        }
    }

    private var exposeExitAt: Date?
    private var dockObserver: AXObserver?
    private var dockObserverPID: pid_t = 0

    /// With Accessibility allowed, the Dock tells us the moment Mission Control opens or starts
    /// closing (no polling delay). Re-created if the Dock restarts.
    private func ensureDockObserver() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let pid = dock.processIdentifier
        guard dockObserver == nil || pid != dockObserverPID else { return }
        if let old = dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
            dockObserver = nil
        }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, name, _ in
            let opening = (name as String) != "AXExposeExit"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppDelegate.shared?.notch?.dockExpose(opening: opening) }
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        for name in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", "AXExposeExit"] {
            AXObserverAddNotification(observer, app, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        dockObserver = observer
        dockObserverPID = pid
    }

    fileprivate func dockExpose(opening: Bool) {
        guard settings.config.notchHideInMissionControl else { return }
        exposeExitAt = opening ? nil : Date()
        guard opening != missionControlOpen else { return }
        missionControlOpen = opening
        updateFullscreenHiding()
    }

    private static func missionControlIsOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            (w[kCGWindowOwnerName as String] as? String) == "Dock" && (w[kCGWindowLayer as String] as? Int) == 20
        }
    }

    func updateFullscreenHiding() {
        let fullscreen = settings.config.notchHideInFullscreen && Self.frontmostIsFullscreen(on: geometry)
        let missionControl = settings.config.notchHideInMissionControl && missionControlOpen
        let hide = settings.config.notchEnabled && !model.locked && (fullscreen || missionControl)
        guard hide != hiddenForFullscreen || panel.alphaValue != (hide ? 0 : 1) else { return }
        hiddenForFullscreen = hide
        defer { syncDropCatcher() }
        updateFullscreenPolling() // while hidden, keep polling to catch the exit
        if hide {
            panel.ignoresMouseEvents = true
            if model.expanded { collapse() }
        }
        // Hide at once (Mission Control and fullscreen open fast); fade back in gently.
        if hide {
            panel.alphaValue = 0
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                panel.animator().alphaValue = 1
            }
        }
    }

    /// True when the frontmost app has a window covering the whole notch display (fullscreen).
    private static func frontmostIsFullscreen(on g: NotchGeometry) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let screen = NSScreen.screens.first(where: { abs($0.frame.maxY - g.screenTop) < 1 && $0.frame.minX <= g.centerX && $0.frame.maxX >= g.centerX }),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // CG window bounds are top-left based on the primary display; convert the notch screen's frame.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenTopLeftY = primaryHeight - screen.frame.maxY
        var covers = false
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = b["X"] ?? .infinity, y = b["Y"] ?? .infinity
            if abs(x - screen.frame.minX) < 2, abs(y - screenTopLeftY) < 2,
               (b["Width"] ?? 0) >= screen.frame.width, (b["Height"] ?? 0) >= screen.frame.height { covers = true; break }
        }
        guard covers else { return false }
        // With the menu bar set to auto-hide, an ordinary maximised (zoomed / "Fill") window also
        // covers the whole screen; that isn't fullscreen and must not hide the island. When the menu
        // bar reserves no room, require the display to actually be on a fullscreen Space. (If the
        // Space can't be read, keep the old behaviour.)
        let menuBarReservesRoom = screen.visibleFrame.maxY < screen.frame.maxY - 1
        if menuBarReservesRoom { return true }
        return currentSpaceIsFullscreen(on: screen) ?? true
    }

    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias MainConnectionID = @convention(c) () -> Int32
    private static let spaceAPI: (MainConnectionID, CopyManagedDisplaySpaces)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let copy = dlsym(handle, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(main, to: MainConnectionID.self), unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self))
    }()

    /// Whether `screen` is currently showing a fullscreen Space (type 4), or nil if unknown.
    private static func currentSpaceIsFullscreen(on screen: NSScreen) -> Bool? {
        guard let api = spaceAPI,
              let displays = api.1(api.0())?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty else { return nil }
        var entry: [String: Any]?
        if displays.count == 1 {
            entry = displays[0] // "Displays have separate Spaces" off: one entry ("Main") for all
        } else if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            let uuidString = CFUUIDCreateString(nil, uuid) as String
            entry = displays.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuidString) == .orderedSame }
        }
        guard let current = entry?["Current Space"] as? [String: Any], let type = current["type"] as? Int else { return nil }
        return type == 4
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            reposition()
            SkyLight.shared.moveToLockScreen(panel)
            panel.orderFrontRegardless()
            updateFullscreenHiding()
        } else {
            // Don't come back already open (and stuck that way) when the island is turned on again.
            if model.expanded { collapse() }
            panel.orderOut(nil)
        }
    }

    private func reposition() {
        geometry = NotchGeometry.current(widthAdjust: settings.config.notchWidthAdjust,
                                         heightAdjust: settings.config.notchHeightAdjust)
        let size = Self.panelSize
        panel.setFrame(NSRect(x: geometry.centerX - size.width / 2, y: geometry.screenTop - size.height,
                              width: size.width, height: size.height), display: true)
        model.objectWillChange.send()
    }

    private func batteryChanged(_ info: MacBatteryInfo) {
        if let last = lastPluggedIn, last != info.isPluggedIn {
            BrightnessWatcher.shared.powerSourceChanged()
            lastStateFlash = Date()
            // Give macOS ~2 s to settle (charger negotiation) and show what it's really doing.
            let plugged = info.isPluggedIn
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let settled = MacBattery.read() ?? info
                guard settled.isPluggedIn == plugged else { return }
                self.model.flash(.charging(level: settled.level, state: settled.chargeState))
                self.lastChargeState = settled.chargeState
            }
        } else if info.isPluggedIn, let previous = lastChargeState, previous != info.chargeState,
                  Date().timeIntervalSince(lastStateFlash) > 30 {
            // Still plugged in but macOS changed what it's doing: charging went on hold, resumed, or
            // finished. Rate-limited so a battery hovering at full can't flicker the island.
            model.flash(.charging(level: info.level, state: info.chargeState))
            lastStateFlash = Date()
        }
        lastPluggedIn = info.isPluggedIn
        lastChargeState = info.chargeState
        let threshold = settings.config.lowBatteryThreshold
        if !info.isPluggedIn, info.level <= threshold, warnedLowAt == nil || info.level <= (warnedLowAt ?? 0) - 10 {
            warnedLowAt = info.level
            model.flash(.lowBattery(level: info.level), seconds: 4)
            if settings.config.lockSounds { SystemSounds.play("Funk") }
        }
        if info.isPluggedIn || info.level > threshold { warnedLowAt = nil }
    }

    /// Names from IOBluetooth, CoreAudio and system_profiler differ in apostrophes (’ vs ') and case.
    static func normalizedDeviceName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deviceNamesMatch(_ a: String, _ b: String) -> Bool {
        let x = normalizedDeviceName(a), y = normalizedDeviceName(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.hasPrefix(y) || y.hasPrefix(x) || x.contains(y) || y.contains(x)
    }

    /// When each device last announced itself (normalized name), so IOBluetooth and CoreAudio
    /// reporting the same connection show it once.
    private var recentConnects: [String: Date] = [:]

    /// Called by the IOBluetooth connect notification and by CoreAudio gaining a Bluetooth output.
    func deviceConnected(_ name: String) {
        let now = Date()
        recentConnects = recentConnects.filter { now.timeIntervalSince($0.value) < 10 }
        guard !recentConnects.keys.contains(where: { Self.deviceNamesMatch($0, name) }) else { return }
        recentConnects[Self.normalizedDeviceName(name)] = now

        store.refreshPeripherals(fullScan: true)
        // Show it straight away (waiting for the battery scan meant the song peek of the resumed
        // music, or nothing, was all that appeared), then fill in the level once the scan is in.
        let first = deviceActivity(name)
        model.flash(first, seconds: 4)
        for delay in [3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, case .device(let shown, _, let oldLevel) = self.model.transient, shown == name else { return }
                let updated = self.deviceActivity(name)
                if case .device(_, _, let level) = updated, level != nil, level != oldLevel {
                    self.model.flash(updated, seconds: 4)
                }
            }
        }
    }

    private func deviceActivity(_ name: String) -> LiveActivity {
        let matches = store.peripherals.filter { Self.deviceNamesMatch($0.name, name) }
        let level = matches.filter { $0.component != "Case" }.map(\.level).min() ?? matches.first?.level
        // Both buds → the pair AirPods glyph; one bud → that bud; otherwise the device's own icon
        // (AirPods that report as a single device land in .headphones, so route those by name too).
        let buds = matches.filter { $0.kind == .earbudLeft || $0.kind == .earbudRight }
        let symbol: String
        if buds.contains(where: { $0.kind == .earbudLeft }) && buds.contains(where: { $0.kind == .earbudRight }) {
            symbol = SFSymbol.earbuds(for: name)
        } else if let bud = buds.first {
            symbol = bud.kind.symbol
        } else if name.lowercased().contains("airpod") {
            symbol = SFSymbol.earbuds(for: name)
        } else {
            symbol = matches.first?.kind.symbol ?? DeviceKind.guess(from: name).symbol
        }
        return .device(name: name, symbol: symbol, level: level)
    }

    // MARK: Size

    /// Everything is sized from the Mac's real notch, so it fits any MacBook: 1.0 on a 37.5 pt notch.
    var scale: CGFloat { min(1.35, max(0.75, geometry.height / 37.5)) }

    /// Size of the black island for the current state (shared with the view).
    func islandSize() -> CGSize {
        let g = geometry
        let k = scale
        // Compact-activity labels use a FIXED point size, so their width must not shrink below the
        // k = 1 budget on small notches / the short non-notch pill (where k clamps to 0.75) — that is
        // what clipped "On Hold" and long device names. `t` grows the text budget on big notches but
        // never shrinks it below the fixed-text worst case, so content always fits any notch width.
        let t = max(k, 1)
        if model.expanded { return CGSize(width: max(368 * k, g.width + 160 * k), height: 179.5 * k) }
        let content = NotchContent.current(model: model)
        // Breathe a little when the pointer reaches the notch, so it feels alive.
        let grow: CGFloat = model.hovering && hoverZone().contains(NSEvent.mouseLocation) ? 1 : 0
        if case .transient(.notification) = content { return CGSize(width: max(340 * k, g.width + 140 * k), height: g.height + 56 * k) }
        if case .transient(.songChange) = content { return CGSize(width: max(300 * k, g.width + 92 * k), height: 80 * k) }
        switch content {
        case .idle: return CGSize(width: g.width + 6 * k * grow, height: g.height + 2 * k * grow)
        case .nowPlaying: return CGSize(width: g.width + 2 * 37 * t + 4 * k * grow, height: g.height + 1.5 * k * grow)
        case .watching: return CGSize(width: g.width + 2 * 100 * t, height: g.height + 1.5 * k * grow)
        case .hud: return CGSize(width: g.width + 2 * (settings.config.hudShowsPercent ? 92 : 66) * t, height: g.height)
        case .device: return CGSize(width: g.width + 2 * 96 * t, height: g.height)
        case .transient(.event): return CGSize(width: g.width + 2 * 110 * t, height: g.height)
        case .transient(.charging(_, let state)):
            // Room for "On Hold 100%" + battery icon on one line (fixed-size, so use `t`, not `k`).
            return CGSize(width: g.width + 2 * (state == .onHold || state == .charged ? 132 : 80) * t, height: g.height)
        case .transient(.lowPower): return CGSize(width: g.width + 2 * 80 * t, height: g.height)
        case .transient(.focus): return CGSize(width: g.width + 2 * 64 * t, height: g.height)
        case .transient(.lowBattery): return CGSize(width: g.width + 2 * 60 * t, height: g.height)
        case .timer: return CGSize(width: g.width + 2 * 70 * t, height: g.height)
        case .locked: return CGSize(width: g.width + 2 * (g.height * 0.8), height: g.height)
        // At least 42 pt a side: the 12 pt temperature ("-12°") didn't fit in 0.95 × a short notch
        // (or the pill on Macs without one) and wrapped/truncated.
        case .idleWeather: return CGSize(width: g.width + 2 * max(g.height * 0.95, 42), height: g.height)
        case .idleNotPlaying: return CGSize(width: g.width + 2 * 84 * t, height: g.height) // fits "Not playing"
        default: return CGSize(width: g.width + 2 * 50 * t, height: g.height)
        }
    }

    /// Where hovering opens the island: the notch itself at the top edge, not the area around it.
    /// Only the middle of the notch opens it, so brushing a corner on the way to the menu bar doesn't.
    /// It reaches a few points above the screen's top edge: the pointer pinned at the very top row
    /// (y == screenTop) must still count as inside, since NSRect.contains excludes its max edge.
    private func hoverZone() -> NSRect {
        let g = geometry
        let w = g.width * 0.7
        return NSRect(x: g.centerX - w / 2, y: g.screenTop - g.height, width: w, height: g.height + 6)
    }

    private func islandRect(padding: CGFloat) -> NSRect {
        let size = islandSize()
        // +6 above the top edge so pushing the pointer to the very top doesn't count as leaving.
        return NSRect(x: geometry.centerX - size.width / 2 - padding, y: geometry.screenTop - size.height - padding,
                      width: size.width + 2 * padding, height: size.height + padding + 6)
    }

    // MARK: Retract

    private var lastCompact: NotchContent = .idle
    private var retractGhost: NotchContent?
    private var retractUntil = Date.distantPast
    private static let retractDuration: TimeInterval = 0.65

    /// When the collapsed island goes from Now Playing / Now Watching to the bare notch, returns that
    /// activity for `retractDuration` so the view can keep its wings while they retract (instead of
    /// removing them at once and leaving empty black wings while the island shrinks). Called from
    /// the view's body; only touches plain (unpublished) state.
    func retractingContent(for content: NotchContent) -> NotchContent? {
        defer { lastCompact = content }
        guard !model.expanded, content == .idle else { retractGhost = nil; return nil }
        if let ghost = retractGhost, Date() < retractUntil { return ghost }
        retractGhost = nil
        guard lastCompact == .nowPlaying || lastCompact == .watching else { return nil }
        retractGhost = lastCompact
        retractUntil = Date().addingTimeInterval(Self.retractDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retractDuration + 0.02) { [weak self] in
            self?.model.objectWillChange.send() // re-render so the faded wings are removed
        }
        return lastCompact
    }

    /// Tapping a replyable banner: open the island on Notifications with that message's reply field.
    /// Returns false when the island can't open (Compact only, locked…) so the caller opens the app.
    @discardableResult
    func openReply(to note: MirroredNotification) -> Bool {
        guard note.canReply, settings.config.notchExpandMode != .never, !model.locked, !hiddenForFullscreen else { return false }
        model.forcedPage = .notifications
        let reply = ReplyState.shared
        reply.activeID = note.id
        reply.text = ""
        reply.status = nil
        expand(on: .notifications)
        guard model.expanded else { model.forcedPage = nil; return false }
        // The text field needs a key window to type into.
        panel.makeKey()
        return true
    }

    /// Let the reply field take typing (the island is a non-activating panel).
    func focusPanel() { panel.makeKey() }

    /// Opens the island. `page` is a page this opening is for (a drop → the shelf, a reply →
    /// Notifications); without one, an opening picks its page from context (see pickPageForOpening).
    func expand(on page: NotchPage? = nil) {
        // Hidden over a fullscreen app the panel is transparent and ignores the mouse, so an island
        // opened from the context menu or Settings there would stay open, invisibly, until later.
        guard settings.config.notchEnabled, settings.config.notchExpandMode != .never, !model.locked,
              !hiddenForFullscreen else { return }
        if let page, model.availablePages.contains(page) {
            model.showPageAutomatically(page)
        } else if !model.expanded {
            model.pickPageForOpening()
        }
        if !model.availablePages.contains(model.page) { model.showPageAutomatically(model.availablePages[0]) }
        withAnimation(IslandMotion.open) { model.expanded = true }
        if YTMusicBridge.browser(for: MediaController.shared.info?.bundleIdentifier) != nil { YTMusicBridge.shared.refresh() }
        if settings.config.notchHaptics { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    }

    private(set) var justCollapsed = false

    private var collapseGeneration = 0

    func collapse() {
        model.forcedPage = nil
        justCollapsed = true
        collapseGeneration += 1
        let generation = collapseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.collapseGeneration == generation { self?.justCollapsed = false }
        }
        withAnimation(IslandMotion.close) {
            model.expanded = false
            model.pointerX = 0
        }
        panel.ignoresMouseEvents = true
        relinquishKeyFocus()
    }

    /// Typing a reply makes this non-activating panel the key window, and it stays key after the
    /// island closes — so the next keystrokes meant for the app in front went nowhere. Ordering the
    /// panel out hands key focus back to the active app's window; it is put straight back (same
    /// run-loop turn, so nothing flickers) on the lock-screen layer it lives in.
    private func relinquishKeyFocus() {
        guard panel.isKeyWindow, panel.isVisible else { return }
        panel.orderOut(nil)
        SkyLight.shared.moveToLockScreen(panel)
        panel.orderFrontRegardless()
    }

    // MARK: Mouse + gestures

    private func installEventMonitors() {
        let handler: (NSEvent) -> Void = { event in
            MainActor.assumeIsolated { AppDelegate.shared?.notch?.handle(event) }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) { monitors.append(local) }
    }

    fileprivate func handle(_ event: NSEvent) {
        guard settings.config.notchEnabled, !hiddenForFullscreen else { return }
        if event.type == .scrollWheel {
            handleScroll(event)
        } else {
            if event.type == .leftMouseDown {
                // Dragging a shelf item out starts on the island; any other drag is incoming.
                dragFromIsland = islandRect(padding: model.expanded ? 18 : 6).contains(NSEvent.mouseLocation)
            }
            mouseMoved()
        }
    }

    private var dragFromIsland = false

    /// The current drag carries files or images (not just a link, text or a browser tab).
    private static func dragCarriesFiles() -> Bool {
        let types = NSPasteboard(name: .drag).types ?? []
        return types.contains(.fileURL) || types.contains(.tiff) || types.contains(.png)
    }

    /// The physical notch (a little wider, and past the top edge) — nothing underneath to block.
    private func notchCatchRect() -> NSRect {
        let g = geometry
        return NSRect(x: g.centerX - g.width / 2 - 4, y: g.screenTop - g.height, width: g.width + 8, height: g.height + 6)
    }

    /// While dragging: the notch plus ~220 pt each side and a little lower, so a drag that arrives
    /// near the notch (not dead on it) still opens the shelf.
    private func dragApproachRect() -> NSRect {
        let g = geometry
        let side: CGFloat = 220
        let height = g.height + 40
        return NSRect(x: g.centerX - g.width / 2 - side, y: g.screenTop - height,
                      width: g.width + 2 * side, height: height + 6)
    }

    /// Keep the drop catcher over the notch whenever drops could be taken, and over the whole
    /// open island while a drag is on it.
    func syncDropCatcher() {
        let ok = settings.config.notchEnabled && settings.config.notchExpandMode != .never
            && settings.config.notchPages.contains(NotchPage.shelf.rawValue)
            && !model.locked && !hiddenForFullscreen && panel.isVisible
        guard ok else {
            if DropCatcher.shared.isShowing { DropCatcher.shared.hide() }
            return
        }
        let rect: NSRect
        if DropCatcher.shared.dragActive {
            rect = islandRect(padding: 18)
        } else if NSEvent.pressedMouseButtons & 1 != 0 && !dragFromIsland {
            // Something is being dragged: you only need to get near the notch, not exactly on it.
            rect = dragApproachRect()
        } else {
            rect = notchCatchRect()
        }
        DropCatcher.shared.show(over: rect)
    }

    /// A drag reached the notch: open on the shelf, let the drag through the island, and grow the
    /// catcher to the open island once it has resized.
    func dropDragEntered() {
        panel.ignoresMouseEvents = true
        if !model.expanded || model.page != .shelf { expand(on: .shelf) }
        syncDropCatcher()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.syncDropCatcher() }
    }

    /// Two-finger swipes over the island: horizontal = previous/next track, vertical = change page,
    /// swipe down on the collapsed island = open, swipe up when open = close.
    private func handleScroll(_ event: NSEvent) {
        // Trackpad inertia keeps sending "momentum" events after the fingers lift; acting on those
        // made the island flip pages by itself. Only real finger movement counts.
        guard event.momentumPhase.isEmpty else { return }
        guard islandRect(padding: model.expanded ? 18 : 8).contains(NSEvent.mouseLocation) else {
            resetScroll()
            return
        }
        let now = Date()
        // New gesture: trackpad says .began; for mouse wheels, a pause starts a new one.
        if event.phase == .began || now.timeIntervalSince(lastScrollEvent) > 0.3 {
            resetScroll()
        }
        lastScrollEvent = now
        if event.phase == .ended || event.phase == .cancelled {
            resetScroll()
            return
        }
        // One action per physical swipe.
        guard !gestureConsumed else { return }
        // Mouse wheels report lines, trackpads points; make both reach the threshold. Normalise
        // natural scrolling so "down" always means the fingers moved down.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let invert: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        scrollX += event.scrollingDeltaX * factor * invert
        scrollY += event.scrollingDeltaY * factor * invert
        guard now.timeIntervalSince(lastGesture) > 0.35 else { return }
        let threshold: CGFloat = 38
        if abs(scrollX) > threshold, abs(scrollX) > abs(scrollY) * 1.4, settings.config.swipeToSkip, MediaController.shared.info != nil {
            // scrollX runs opposite to the fingers: swipe left (scrollX > 0) = next song, right = previous.
            // swipeSkipReversed flips the final decision deterministically for Macs whose device
            // reports the opposite horizontal direction, keeping the natural-scroll normalization above.
            let dir = (scrollX > 0) != settings.config.swipeSkipReversed
            dir ? MediaController.shared.next() : MediaController.shared.previous()
            // Jiggle to match the skip decision (next lurches left, previous right — the original feel).
            model.jiggle(dir ? -1 : 1)
            gestureDone()
        } else if abs(scrollY) > threshold, abs(scrollY) > abs(scrollX) * 1.4 {
            if !model.expanded {
                if scrollY < 0 { expand() }
                else if model.transient != nil { model.dismissTransient() } // swipe up dismisses an activity
            } else if scrollY > 0, model.availablePages.count <= 1 {
                collapse()
            } else {
                model.cyclePage(forward: scrollY < 0)
            }
            gestureDone()
        }
    }

    private func gestureDone() {
        lastGesture = Date()
        gestureConsumed = true
        scrollX = 0
        scrollY = 0
    }

    private func resetScroll() {
        scrollX = 0
        scrollY = 0
        gestureConsumed = false
    }

    private func mouseMoved() {
        let mouse = NSEvent.mouseLocation
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        let inside = islandRect(padding: model.expanded ? 18 : 6).contains(mouse)
        // Accept clicks/drops only over the island; everywhere else clicks pass through.
        panel.ignoresMouseEvents = !inside
        // Drops can't reach the island's lock-screen-space window; DropCatcher (a normal window over
        // the notch) takes them. During a drag that didn't start on the island, let it through.
        if dragging && !dragFromIsland { panel.ignoresMouseEvents = true }
        // Open the shelf to meet a dragged FILE before it reaches the menu-bar strip: holding a file
        // up there makes macOS open Mission Control (to drop it on another Space) and steals the drop.
        if dragging && !dragFromIsland && !DropCatcher.shared.dragActive && !model.locked
            && settings.config.notchExpandMode != .never
            && settings.config.notchPages.contains(NotchPage.shelf.rawValue)
            && mouse.y > geometry.screenTop - 160 && abs(mouse.x - geometry.centerX) < geometry.width / 2 + 220
            && Self.dragCarriesFiles() {
            DropCatcher.shared.dragActive = true
            dropDragEntered()
        }
        // On release, macOS delivers the drop a moment after the button comes up; shrinking the
        // catcher right away would pull it out from under the drop. Tidy up only if no drop came.
        if !dragging, DropCatcher.shared.dragActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if NSEvent.pressedMouseButtons & 1 == 0, DropCatcher.shared.dragActive { DropCatcher.shared.endDrag() }
            }
        }
        syncDropCatcher()
        let inZone = hoverZone().contains(mouse)
        if inside != model.hovering || inZone != lastInZone {
            lastInZone = inZone
            withAnimation(IslandMotion.hover) {
                model.hovering = inside
                model.objectWillChange.send()
            }
        }


        if inside && !model.expanded {
            collapseWork?.cancel()
            collapseWork = nil
            // Opening needs the pointer up in the notch itself (or a file being dragged near it).
            guard dragging || hoverZone().contains(mouse) else { hoverWork?.cancel(); hoverWork = nil; return }
            let hover = settings.config.notchExpandMode == .hover
            guard (hover || dragging), settings.config.notchExpandMode != .never, !model.locked else { return }
            if hoverWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hoverWork = nil
                    guard dragging || self.hoverZone().contains(NSEvent.mouseLocation) else { return }
                    // Dragging something over the notch opens on the shelf for this opening only.
                    self.expand(on: dragging && self.model.availablePages.contains(.shelf) ? .shelf : nil)
                }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (dragging ? 0.05 : max(0.01, settings.config.hoverDelay)), execute: work)
            }
        } else if !inside {
            hoverWork?.cancel()
            hoverWork = nil
            if model.expanded && collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.collapseWork = nil
                    if !self.islandRect(padding: 18).contains(NSEvent.mouseLocation) { self.collapse() }
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Where the notch is. On Macs without a notch (or with the system Dynamic Island) a notch-sized
/// pill is drawn at the top centre of the main display instead.
struct NotchGeometry {
    var centerX: CGFloat
    var screenTop: CGFloat
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    static func current(widthAdjust: Double = 0, heightAdjust: Double = 0) -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        guard let screen else { return NotchGeometry(centerX: 0, screenTop: 0, width: 200, height: 32, hasNotch: false) }
        var g: NotchGeometry
        // Only trust the notch areas when they describe a plausible notch; otherwise (no notch,
        // odd values from a mirrored/scaled display) fall back to a pill so the island is never
        // zero-sized or off to one side.
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           case let width = screen.frame.width - left.width - right.width, width > 40, width < screen.frame.width / 2 {
            g = NotchGeometry(centerX: screen.frame.minX + left.width + width / 2, screenTop: screen.frame.maxY,
                              width: width, height: screen.safeAreaInsets.top, hasNotch: true)
        } else {
            g = NotchGeometry(centerX: screen.frame.midX, screenTop: screen.frame.maxY,
                              width: 190, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY), hasNotch: false)
        }
        g.width = max(120, g.width + CGFloat(widthAdjust))
        g.height = max(20, g.height + CGFloat(heightAdjust))
        return g
    }
}

/// What the collapsed island shows, in priority order.
enum NotchContent: Equatable {
    case idle
    case locked
    case transient(LiveActivity)
    case hud(HUDKind, Float, Bool)
    case device
    case timer
    case nowPlaying
    /// Watching a video in a browser or streaming app (Netflix, YouTube…): show title + service.
    case watching
    case idleWeather
    /// Idle: a dimmed note and "Not playing".
    case idleNotPlaying

    @MainActor
    static func current(model: NotchModel) -> NotchContent {
        let cfg = AppSettings.shared.config
        if let t = model.transient {
            switch t {
            case .volume(let level, let muted): return .hud(.volume, level, muted)
            case .brightness(let level): return .hud(.brightness, level, false)
            case .device: return .device
            default: return .transient(t)
            }
        }
        if model.locked, cfg.lockedIndicator != "none" { return .locked }
        if NotchTimer.shared.isRunning { return .timer }
        // Playing, or paused less than MediaController.pausedGrace (3 s) ago; after that the
        // paused song gives way to the idle content until playback resumes.
        let media = MediaController.shared
        if let info = media.info, media.songIsRecent,
           !(cfg.notchHideWhenSourceActive && info.bundleIdentifier == NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            // Watching video in a browser/streaming app has its own toggle; music is left to the
            // Now Playing activity (which keeps its own on/off switch).
            if cfg.watchingEnabled, WatchingDetector.shared.isWatching { return .watching }
            if !cfg.disabledActivities.contains("nowPlaying") { return .nowPlaying }
        }
        switch cfg.idleActivity {
        case "weather" where WidgetStore.shared.weather != nil: return .idleWeather
        case "notPlaying": return .idleNotPlaying
        default: return .idle
        }
    }
}
