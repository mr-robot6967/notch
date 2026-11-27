import AppKit
import Combine
import EventKit
import ImageIO
import IOKit.ps
import Network
import SwiftUI
import LockWidgetsCore

/// Live data and system theme shared by every widget view.
@MainActor
final class WidgetStore: ObservableObject {
    static let shared = WidgetStore()

    // Data
    @Published private(set) var mac: MacBatteryInfo?
    @Published private(set) var peripherals: [DeviceBattery] = []
    @Published private(set) var weather: WeatherSnapshot?
    @Published private(set) var weatherStatus: String?
    @Published private(set) var isFetchingWeather = false
    @Published private(set) var nextEvent: NextEvent?
    @Published private(set) var calendarStatus: String?
    @Published private(set) var upcomingEvents: [NextEvent] = []
    @Published private(set) var eventDays: Set<Int> = []

    // System theme
    @Published private(set) var systemAccent: Color = Color(nsColor: .controlAccentColor)
    @Published private(set) var isDarkMode = true
    /// Per screen: is the wallpaper bright where the widgets sit? (true → use dark glyphs)
    @Published private(set) var wallpaperIsLight: [String: Bool] = [:]

    private let weatherService = WeatherService()
    private let calendar = CalendarProvider()
    private var timers: [Timer] = []
    private var cancellables = Set<AnyCancellable>()
    private var powerSource: CFRunLoopSource?
    private var peripheralsInFlight = false
    private var fullScanQueued = false
    private var usingDemoDevices = false
    private var lastBluetooth: [DeviceBattery] = []
    private var displaysAsleep = false
    private var weatherGeneration = 0
    private var calendarRequestInFlight = false
    private var started = false

    private var settings: AppSettings { .shared }

    func start() {
        guard !started else { return }
        started = true

        refreshTheme()
        refreshMac()
        refreshPeripherals()
        refreshWeather()
        refreshCalendar()

        // Low-energy schedule: generous tolerance lets macOS batch wake-ups, and nothing
        // runs while the displays are asleep. The Mac battery also updates instantly via
        // the power-source notification below.
        addTimer(every: 60) { $0.refreshMac() }
        // IOKit every minute; while AirPods/headphones are connected also refresh their L/R/case levels.
        addTimer(every: 60) { store in
            let audio: Set<DeviceKind> = [.earbudLeft, .earbudRight, .earbudCase, .headphones]
            store.refreshPeripherals(fullScan: store.peripherals.contains { audio.contains($0.kind) })
        }
        addTimer(every: 300) { $0.refreshPeripherals(fullScan: true) }        // + system_profiler
        addTimer(every: 120) { $0.refreshWeatherIfStale(); $0.refreshCalendar() }
        addTimer(every: 900) { $0.refreshWallpaperBrightness() }

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { _ in WidgetStore.shared.displaysAsleep = true }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { _ in
                WidgetStore.shared.displaysAsleep = false
                WidgetStore.shared.refreshMac()
                WidgetStore.shared.refreshPeripherals()
                WidgetStore.shared.refreshWeatherIfStale()
            }
            .store(in: &cancellables)

        // Instant updates when the power adapter is plugged/unplugged.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let store = Unmanaged<WidgetStore>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { store.refreshMac() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        // Refetch weather when its settings change.
        settings.$config
            .map { "\($0.locationMode.rawValue)|\($0.city)|\($0.unit.rawValue)" }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in WidgetStore.shared.refreshWeather() }
            .store(in: &cancellables)

        // Ask for calendar access only once the calendar widget is turned on.
        settings.$config
            .map { $0.widgets.contains { $0.kind == .calendar && $0.enabled } }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in WidgetStore.shared.refreshCalendar() }
            .store(in: &cancellables)

        // Once the welcome is finished, fetch what it may just have been given access to.
        settings.$config
            .map(\.onboardingDone)
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { _ in
                WidgetStore.shared.refreshCalendar()
                WidgetStore.shared.refreshWeather()
            }
            .store(in: &cancellables)

        settings.$config
            .map { $0.widgets.contains { $0.kind == .peripherals && $0.enabled } }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in DispatchQueue.main.async { WidgetStore.shared.refreshPeripherals() } }
            .store(in: &cancellables)

        // Re-sample the wallpaper where the widgets sit when placement changes.
        settings.$config
            .map { "\($0.lockScreenPlacement)" }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { _ in WidgetStore.shared.refreshWallpaperBrightness() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)
            .sink { _ in WidgetStore.shared.refreshCalendar() }
            .store(in: &cancellables)

        // System accent colour and light/dark mode.
        NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .merge(with: DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleColorPreferencesChangedNotification")))
            .merge(with: DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification")))
            .delay(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { _ in WidgetStore.shared.refreshTheme() }
            .store(in: &cancellables)

        // Wallpaper may change per Space or on screen changes.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in WidgetStore.shared.refreshWallpaperBrightness() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { _ in WidgetStore.shared.displaysAsleep = false } // never stay paused if screensDidWake is missed
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification))
            .delay(for: .seconds(3), scheduler: RunLoop.main)
            .sink { _ in WidgetStore.shared.refreshAll() }
            .store(in: &cancellables)

        // The refresh 3 s after wake usually runs before Wi-Fi is back, and a failed weather fetch
        // then waited for the 2-minute timer (or stayed "No weather" from a cold offline launch).
        // Refetch the moment the network returns, if what we have is missing, failed or stale.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WidgetStore.shared.networkChanged(online: online) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "LockWidgets.network", qos: .utility))
        pathMonitor = monitor
    }

    private var pathMonitor: NWPathMonitor?
    private var wasOnline: Bool?

    private func networkChanged(online: Bool) {
        defer { wasOnline = online }
        guard online, wasOnline == false else { return }
        if weather == nil || weatherStatus != nil { refreshWeather() } else { refreshWeatherIfStale() }
    }

    func refreshAll() {
        refreshMac()
        refreshPeripherals()
        refreshWeather()
        refreshCalendar()
        refreshTheme()
    }

    /// Called when the Mac locks: make sure what's on the lock screen is fresh.
    func refreshForLock() {
        refreshMac()
        refreshPeripherals()
        refreshCalendar()
        if let w = weather, Date().timeIntervalSince(w.fetchedAt) < 5 * 60 { return }
        refreshWeather()
    }

    // MARK: Theme

    func refreshTheme() {
        systemAccent = Color(nsColor: .controlAccentColor)
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        refreshWallpaperBrightness()
    }

    func refreshWallpaperBrightness() {
        var jobs: [(String, URL, ScreenPlacement)] = []
        for screen in NSScreen.screens {
            let key = WallpaperBaker.key(for: screen)
            guard let url = AppDelegate.shared?.baker?.originalWallpaper(for: screen)
                    ?? NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            jobs.append((key, url, settings.config.lockScreenPlacement))
        }
        DispatchQueue.global(qos: .utility).async {
            var result: [String: Bool] = [:]
            for (key, url, placement) in jobs {
                if let luminance = Self.luminance(of: url, around: placement) {
                    result[key] = luminance > 0.62
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if result != WidgetStore.shared.wallpaperIsLight { WidgetStore.shared.wallpaperIsLight = result }
                }
            }
        }
    }

    func wallpaperIsLight(screenKey: String?) -> Bool {
        let key = screenKey ?? NSScreen.screens.first.map(WallpaperBaker.key(for:)) ?? ""
        return wallpaperIsLight[key] ?? false
    }

    /// Average luminance (0...1) of the wallpaper in a band around the widget placement.
    nonisolated static func luminance(of url: URL, around placement: ScreenPlacement) -> Double? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Rows in the bitmap run top-to-bottom.
        let x0 = Int(Double(w) * max(0, placement.x - 0.25)), x1 = Int(Double(w) * min(1, placement.x + 0.25))
        let y0 = Int(Double(h) * max(0, placement.y - 0.1)), y1 = Int(Double(h) * min(1, placement.y + 0.1))
        var total = 0.0, count = 0.0
        for y in y0..<max(y0 + 1, y1) where y < h {
            for x in x0..<max(x0 + 1, x1) where x < w {
                let i = (y * w + x) * 4
                total += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
                count += 1
            }
        }
        return count > 0 ? total / count : nil
    }

    // MARK: Data

    func refreshMac() {
        // A Mac's internal battery doesn't disappear: a nil/incomplete reading (IOPS during wake) is
        // transient, so keep the last good value and look again shortly instead of blanking the gauge.
        guard let info = MacBattery.read() else {
            if mac != nil, !macRetryScheduled {
                macRetryScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    WidgetStore.shared.macRetryScheduled = false
                    WidgetStore.shared.refreshMac()
                }
            }
            return
        }
        if info != mac { mac = info }
    }

    private var macRetryScheduled = false

    private func addTimer(every seconds: TimeInterval, _ work: @escaping (WidgetStore) -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in
            MainActor.assumeIsolated {
                let store = WidgetStore.shared
                // Ask the display itself: a missed screensDidWake must not pause every refresh for good.
                if store.displaysAsleep, CGDisplayIsAsleep(CGMainDisplayID()) == 0 { store.displaysAsleep = false }
                guard !store.displaysAsleep else { return }
                work(store)
            }
        }
        timer.tolerance = seconds * 0.2
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    /// `fullScan` also asks System Information about AirPods & co (spawns a process), so it
    /// runs less often and only when the devices widget is on. IOKit HID is cheap.
    func refreshPeripherals(fullScan: Bool = true) {
        guard settings.config.widgets.contains(where: { $0.kind == .peripherals && $0.enabled }) else {
            if !peripherals.isEmpty && !usingDemoDevices { peripherals = [] }
            return
        }
        guard !peripheralsInFlight else {
            // A cheap IOKit pass is running; a full scan asked for meanwhile (a device just connected)
            // must not be dropped, or the new AirPods show without a battery until the next 5-min scan.
            if fullScan { fullScanQueued = true }
            return
        }
        peripheralsInFlight = true
        let previousBluetooth = lastBluetooth
        DispatchQueue.global(qos: .utility).async {
            let bluetooth = fullScan ? (BluetoothBatteries.read() ?? previousBluetooth) : previousBluetooth
            let merged = PeripheralMerge.merge(hid: HIDBatteries.read(), bluetooth: bluetooth)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = WidgetStore.shared
                    store.peripheralsInFlight = false
                    if fullScan { store.lastBluetooth = bluetooth }
                    if store.fullScanQueued {
                        store.fullScanQueued = false
                        if !fullScan { store.refreshPeripherals(fullScan: true) }
                    }
                    guard !store.usingDemoDevices else { return }
                    if merged != store.peripherals { store.peripherals = merged }
                }
            }
        }
    }

    func refreshWeatherIfStale() {
        let maxAge = TimeInterval(max(5, settings.config.weatherRefreshMinutes) * 60)
        if let w = weather, Date().timeIntervalSince(w.fetchedAt) < maxAge { return }
        refreshWeather()
    }

    /// Each request gets a generation number; only the newest one may update the widgets, so a
    /// slow fetch started with an old city/unit can't overwrite a newer setting.
    func refreshWeather() {
        weatherGeneration += 1
        let generation = weatherGeneration
        isFetchingWeather = true
        if weather == nil { weatherStatus = "Loading weather…" }
        let config = settings.config
        Task { @MainActor in
            do {
                var snapshot = try await self.weatherService.fetch(config: config)
                guard generation == self.weatherGeneration else { return }
                // Air quality is a separate, optional request; one failed fetch (network still
                // waking) used to blank the AQI until the next refresh. Keep the last value for the
                // same place for a while.
                if snapshot.airQuality == nil, let old = self.weather, old.airQuality != nil,
                   old.locationName == snapshot.locationName, Date().timeIntervalSince(old.fetchedAt) < 3 * 3600 {
                    snapshot.airQuality = old.airQuality
                }
                self.weather = snapshot
                self.weatherStatus = nil
            } catch {
                guard generation == self.weatherGeneration else { return }
                self.weatherStatus = error.localizedDescription
            }
            self.isFetchingWeather = false
        }
    }

    func refreshCalendar() {
        guard settings.config.widgets.contains(where: { $0.kind == .calendar && $0.enabled }) || settings.config.calendarPeek
                || settings.config.notchPages.contains("calendar") else { return }
        calendar.resetIfAccessChanged()
        switch calendar.status {
        case .fullAccess:
            calendarStatus = nil
            let event = calendar.nextEvent()
            if event != nextEvent { nextEvent = event }
            let upcoming = calendar.upcoming()
            if upcoming.events != upcomingEvents { upcomingEvents = upcoming.events }
            if upcoming.days != eventDays { eventDays = upcoming.days }
        case .notDetermined:
            // On a fresh install the welcome window asks for permissions with an explanation;
            // don't fire the system prompt behind it at launch.
            guard settings.config.onboardingDone else { calendarStatus = "Allow Calendars to see events"; return }
            guard !calendarRequestInFlight else { return }
            calendarRequestInFlight = true
            Task { @MainActor in
                defer { self.calendarRequestInFlight = false }
                if await self.calendar.requestAccess() {
                    self.refreshCalendar()
                } else {
                    self.calendarStatus = "No calendar access"
                }
            }
        default:
            calendarStatus = "Allow Calendars in System Settings › Privacy"
        }
    }

    /// Snapshot mode only: sample devices so the artwork shows the device gauges.
    func injectDemoDevices() {
        usingDemoDevices = true
        peripherals = [
            DeviceBattery(name: "AirPods Pro", kind: .earbudLeft, level: 86, component: "L"),
            DeviceBattery(name: "AirPods Pro", kind: .earbudRight, level: 82, component: "R"),
            DeviceBattery(name: "AirPods Pro", kind: .earbudCase, level: 34, isCharging: true, component: "Case"),
            DeviceBattery(name: "Magic Mouse", kind: .mouse, level: 14),
        ]
    }

    func visiblePeripherals(hidden: [String]) -> [DeviceBattery] {
        let hiddenSet = Set(hidden)
        let visible = peripherals.filter { !hiddenSet.contains($0.id) }
        // Both buds in: one AirPods gauge, like Apple's Batteries widget (case stays separate).
        return AppSettings.shared.config.combineEarbuds ? EarbudCombine.combine(visible) : visible
    }
}
