import Foundation
import IOKit
import IOKit.ps
import CoreLocation
import EventKit
import SwiftUI
import LockWidgetsCore

// MARK: - Mac battery (IOKit power sources)

/// What macOS shows for the battery: charging, charging on hold (Optimized Battery Charging or
/// another pause while plugged in), fully charged, or running on battery.
enum ChargeState: Equatable {
    case charging, onHold, charged, onBattery
}

struct MacBatteryInfo: Equatable {
    var level: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var minutesRemaining: Int?
    var isCharged: Bool = false
    /// macOS's reason for not charging while plugged in (0 = none: it's about to charge).
    var notChargingReason: Int = 0
    /// The charge limit set in System Settings › Battery (100 when none).
    var chargeLimit: Int = 100

    var chargeState: ChargeState {
        if !isPluggedIn { return .onBattery }
        if isCharging { return .charging }
        if isCharged || level >= 100 { return .charged }
        // Only a real hold counts: macOS gave a reason, or the battery reached the charge limit.
        // Right after plugging in, macOS briefly reports "not charging" with no reason while the
        // charger negotiates — that's charging about to start, not "On Hold".
        if notChargingReason != 0 || level >= chargeLimit - 1 { return .onHold }
        return .charging
    }
}

enum MacBattery {
    /// ChargerData.NotChargingReason from the smart battery (0 when charging or about to).
    static func notChargingReason() -> Int {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, "ChargerData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return 0 }
        return (data["NotChargingReason"] as? NSNumber)?.intValue ?? 0
    }

    private static var limitCache: (value: Int, at: Date)?

    /// The charge limit from System Settings › Battery: the power daemon's manual charge-limit
    /// policy (soclimit), falling back to the Battery settings' stored limit. Cached for a minute.
    static func chargeLimit() -> Int {
        if let cached = limitCache, Date().timeIntervalSince(cached.at) < 60 { return cached.value }
        var limit = 100
        if let d = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.powerd.charging.plist"),
           let blob = d["policies"] as? Data,
           let archive = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
           let objects = archive["$objects"] as? [Any] {
            for case let object as [String: Any] in objects {
                if let soc = (object["soclimit"] as? NSNumber)?.intValue, soc > 0, soc <= 100 { limit = min(limit, soc) }
            }
        }
        if limit == 100, let ui = UserDefaults(suiteName: "com.apple.batteryui.charging.mac"),
           let stored = ui.object(forKey: "com.apple.batteryui.charging.mac.prior.limit") as? NSNumber,
           stored.intValue > 0, stored.intValue < 100 {
            limit = stored.intValue
        }
        limitCache = (limit, Date())
        return limit
    }

    static func read() -> MacBatteryInfo? {
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard
                let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            // While the Mac wakes, IOPS can briefly describe the battery without its capacity or power
            // state. Defaulting those to 0 % / "on battery" fired a false low-battery warning (with
            // sound) and an unplugged → charging pop-up pair. An incomplete reading is no reading.
            guard let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let state = desc[kIOPSPowerSourceStateKey] as? String else { return nil }
            let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let level = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let pluggedIn = state == kIOPSACPowerValue
            let minutes = desc[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
            return MacBatteryInfo(
                level: level,
                isCharging: charging,
                isPluggedIn: pluggedIn,
                minutesRemaining: minutes > 0 ? minutes : nil,
                isCharged: desc[kIOPSIsChargedKey] as? Bool ?? false,
                notChargingReason: Self.notChargingReason(),
                chargeLimit: Self.chargeLimit()
            )
        }
        return nil
    }
}

// MARK: - Apple accessories (Magic Keyboard / Mouse / Trackpad) via IOKit HID

enum HIDBatteries {
    static func read() -> [DeviceBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var out: [DeviceBattery] = []
        var seen = Set<String>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let percent = property(service, "BatteryPercent") as? Int else { continue }
            let name = property(service, "Product") as? String ?? "Accessory"
            guard seen.insert(name).inserted else { continue }
            out.append(DeviceBattery(name: name, kind: DeviceKind.guess(from: name), level: percent))
        }
        return out
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

// MARK: - AirPods, Beats and other Bluetooth devices via system_profiler

enum BluetoothBatteries {
    /// nil when system_profiler failed or timed out (so callers keep the last good list instead of
    /// making every AirPods/Beats gauge vanish until the next scan).
    static func read() -> [DeviceBattery]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Bluetooth trouble can make system_profiler hang; never wait more than 15 s.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return BluetoothParser.parse(data)
    }
}

// MARK: - Location

enum LocationError: LocalizedError {
    case denied, timeout, unavailable
    var errorDescription: String? {
        switch self {
        case .denied: return "Location access is off. Allow it in System Settings › Privacy › Location Services, or set a city in Settings."
        case .timeout: return "Couldn't get your location. Set a city in Settings."
        case .unavailable: return "Location unavailable. Set a city in Settings."
        }
    }
}

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation, Error>] = []
    private var requestID = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentLocation() async throws -> CLLocation {
        if let loc = manager.location, -loc.timestamp.timeIntervalSinceNow < 30 * 60 {
            return loc
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            guard waiters.count == 1 else { return }
            requestID += 1
            let thisRequest = requestID
            switch manager.authorizationStatus {
            case .notDetermined where !AppSettings.shared.config.onboardingDone:
                // First launch: the welcome window asks for Location with an explanation. Until
                // then use the time-zone city (WeatherService falls back on this error).
                finish(.failure(LocationError.denied))
                return
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(LocationError.denied))
                return
            default:
                manager.requestLocation()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.requestID == thisRequest else { return }
                self.finish(.failure(LocationError.timeout))
            }
        }
    }

    func placeName(for location: CLLocation) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        return placemarks?.first?.locality ?? placemarks?.first?.name
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard !self.waiters.isEmpty else { return }
            switch self.manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted: self.finish(.failure(LocationError.denied))
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.finish(.success(last)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(LocationError.unavailable)) }
    }
}

// MARK: - Weather

@MainActor
final class WeatherService {
    private let location = LocationProvider()
    private var geocodeCache: [String: GeoPlace] = [:]
    /// The last real location fix. Right after wake (or offline) CoreLocation often times out or
    /// fails once; falling back to the time-zone city then replaced your weather with another
    /// city's. A transient failure reuses the last fix; only "denied" uses the time-zone city.
    private var lastFix: (latitude: Double, longitude: Double, name: String)?

    /// "Europe/London" → "London", "America/New_York" → "New York".
    static var timeZoneCity: String? {
        let id = TimeZone.current.identifier
        guard id.contains("/"), let last = id.split(separator: "/").last else { return nil }
        return last.replacingOccurrences(of: "_", with: " ")
    }

    func fetch(config: Config) async throws -> WeatherSnapshot {
        let latitude: Double
        let longitude: Double
        let name: String

        switch config.locationMode {
        case .city:
            let query = config.city.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = OpenMeteo.geocodeURL(city: query) else {
                throw WeatherError.cityNotFound("(no city set)")
            }
            let place: GeoPlace
            if let cached = geocodeCache[query.lowercased()] {
                place = cached
            } else {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let found = try OpenMeteo.decodeGeocode(data) else { throw WeatherError.cityNotFound(query) }
                geocodeCache[query.lowercased()] = found
                place = found
            }
            latitude = place.latitude
            longitude = place.longitude
            name = place.name

        case .automatic:
            do {
                let loc = try await location.currentLocation()
                latitude = loc.coordinate.latitude
                longitude = loc.coordinate.longitude
                // Reverse geocoding needs the network; keep the last name for the same place.
                let sameSpot = lastFix.map { abs($0.latitude - latitude) < 0.05 && abs($0.longitude - longitude) < 0.05 } ?? false
                name = await location.placeName(for: loc) ?? (sameSpot ? lastFix?.name : nil) ?? "Current Location"
                lastFix = (latitude, longitude, name)
            } catch let error as LocationError where error != .denied && lastFix != nil {
                latitude = lastFix!.latitude
                longitude = lastFix!.longitude
                name = lastFix!.name
            } catch {
                // No location permission/fix: use the city from the Mac's time-zone setting
                // (e.g. Asia/Kolkata → Kolkata) so the widget still shows local weather.
                guard let city = Self.timeZoneCity, let url = OpenMeteo.geocodeURL(city: city) else { throw error }
                let place: GeoPlace
                if let cached = geocodeCache[city.lowercased()] {
                    place = cached
                } else {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let found = try OpenMeteo.decodeGeocode(data) else { throw error }
                    geocodeCache[city.lowercased()] = found
                    place = found
                }
                latitude = place.latitude
                longitude = place.longitude
                name = place.name
            }
        }

        let url = OpenMeteo.forecastURL(latitude: latitude, longitude: longitude, unit: config.unit)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WeatherError.badResponse }
        var snapshot = try OpenMeteo.decodeForecast(data, locationName: name, unit: config.unit)

        // Air quality is optional: a failure here shouldn't hide the weather.
        let aqURL = OpenMeteo.airQualityURL(latitude: latitude, longitude: longitude)
        if let (aqData, _) = try? await URLSession.shared.data(from: aqURL) {
            snapshot.airQuality = OpenMeteo.decodeAirQuality(aqData)
        }
        return snapshot
    }
}

// MARK: - Calendar (EventKit)

struct NextEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var colorHex: String?
    var isHappeningNow: Bool { start <= Date() && end > Date() }
}

@MainActor
final class CalendarProvider {
    let store = EKEventStore()

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var hasAccess: Bool { status == .fullAccess }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted { store.reset() } // pick up calendars now that we can see them
        return granted
    }

    private var lastStatus: EKAuthorizationStatus?

    /// If access was granted later in System Settings, the store needs a reset to see events.
    func resetIfAccessChanged() {
        let current = status
        if let lastStatus, lastStatus != current, current == .fullAccess { store.reset() }
        lastStatus = current
    }

    /// Upcoming timed events today/tomorrow and the days of this month that have events.
    func upcoming(now: Date = Date()) -> (events: [NextEvent], days: Set<Int>) {
        guard hasAccess else { return ([], []) }
        let cal = Calendar.current
        guard let month = cal.dateInterval(of: .month, for: now) else { return ([], []) }
        let end = max(month.end, now.addingTimeInterval(36 * 3600))
        let all = store.events(matching: store.predicateForEvents(withStart: month.start, end: end, calendars: nil))
        // Mark every day of this month that an event covers.
        var days = Set<Int>()
        for event in all {
            var day = max(cal.startOfDay(for: event.startDate), month.start)
            let last = min(event.endDate.addingTimeInterval(-1), month.end.addingTimeInterval(-1))
            while day <= last {
                days.insert(cal.component(.day, from: day))
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        let soon = all.filter { !$0.isAllDay && $0.endDate > now && $0.startDate < now.addingTimeInterval(36 * 3600) }
            .sorted { $0.startDate < $1.startDate }
            .map { NextEvent(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                             colorHex: $0.calendar?.color.flatMap { Color(nsColor: $0).hexString }) }
        return (soon, days)
    }

    /// The next (or current) timed event in the coming 24 hours.
    func nextEvent(now: Date = Date()) -> NextEvent? {
        guard hasAccess else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600),
                                                 end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        guard let event = upcoming.first else { return nil }
        let color = event.calendar?.color.flatMap { Color(nsColor: $0).hexString }
        return NextEvent(title: event.title ?? "Event", start: event.startDate, end: event.endDate, colorHex: color)
    }
}
