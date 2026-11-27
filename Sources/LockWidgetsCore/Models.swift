import Foundation

/// The widgets the user can place on the strip.
public enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case weather
    case airQuality
    case forecast
    case macBattery
    case peripherals
    case calendar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .weather: return "Weather"
        case .airQuality: return "Air Quality"
        case .calendar: return "Next Event"
        case .forecast: return "Forecast"
        case .macBattery: return "Mac Battery"
        case .peripherals: return "Devices Battery"
        }
    }

    public var symbol: String {
        switch self {
        case .weather: return "cloud.sun.fill"
        case .airQuality: return "aqi.medium"
        case .calendar: return "calendar.badge.clock"
        case .forecast: return "calendar"
        case .macBattery: return "laptopcomputer"
        case .peripherals: return "headphones"
        }
    }
}

public enum WidgetSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case expanded

    public var id: String { rawValue }
    /// "compact" renders as a round gauge, "expanded" as a wide/inline widget.
    public var title: String { self == .compact ? "Round" : "Wide" }
}

public struct WidgetEntry: Codable, Identifiable, Hashable, Sendable {
    public var kind: WidgetKind
    public var enabled: Bool
    public var size: WidgetSize

    public var id: String { kind.rawValue }

    public init(kind: WidgetKind, enabled: Bool, size: WidgetSize) {
        self.kind = kind
        self.enabled = enabled
        self.size = size
    }

    public static let defaults: [WidgetEntry] = [
        WidgetEntry(kind: .weather, enabled: true, size: .compact),
        WidgetEntry(kind: .airQuality, enabled: true, size: .compact),
        WidgetEntry(kind: .macBattery, enabled: true, size: .compact),
        WidgetEntry(kind: .peripherals, enabled: true, size: .compact),
        WidgetEntry(kind: .calendar, enabled: false, size: .expanded),
        WidgetEntry(kind: .forecast, enabled: false, size: .expanded),
    ]

    /// Keeps the user's order but makes sure every known widget appears exactly once
    /// (handles configs saved by older versions).
    public static func normalized(_ entries: [WidgetEntry]) -> [WidgetEntry] {
        var seen = Set<WidgetKind>()
        var result: [WidgetEntry] = []
        for entry in entries where !seen.contains(entry.kind) {
            seen.insert(entry.kind)
            result.append(entry)
        }
        for entry in defaults where !seen.contains(entry.kind) {
            result.append(entry)
        }
        return result
    }
}

public enum DeviceKind: String, Codable, Sendable {
    case mouse, keyboard, trackpad, headphones, earbudLeft, earbudRight, earbudCase, earbuds, speaker, gamepad, other

    public var symbol: String {
        switch self {
        case .mouse: return "magicmouse.fill"
        case .keyboard: return "keyboard.fill"
        case .trackpad: return "rectangle.and.hand.point.up.left.fill"
        case .headphones: return "headphones"
        case .earbudLeft: return "airpod.left"
        case .earbudRight: return "airpod.right"
        case .earbudCase: return "airpods.chargingcase.fill"
        case .earbuds: return "airpods"
        case .speaker: return "hifispeaker.fill"
        case .gamepad: return "gamecontroller.fill"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    /// Guess a device kind from a Bluetooth minor type or product name.
    public static func guess(from text: String) -> DeviceKind {
        let t = text.lowercased()
        if t.contains("mouse") { return .mouse }
        if t.contains("trackpad") { return .trackpad }
        if t.contains("keyboard") { return .keyboard }
        if t.contains("headphone") || t.contains("headset") || t.contains("airpods") || t.contains("beats") || t.contains("buds") { return .headphones }
        if t.contains("speaker") { return .speaker }
        if t.contains("gamepad") || t.contains("controller") || t.contains("joystick") { return .gamepad }
        return .other
    }
}

public struct DeviceBattery: Identifiable, Hashable, Codable, Sendable {
    /// Stable id used for the "hide this device" setting.
    public var id: String
    public var name: String
    public var kind: DeviceKind
    public var level: Int
    public var isCharging: Bool
    /// "L", "R", "Case" for split devices like AirPods, otherwise nil.
    public var component: String?

    public init(name: String, kind: DeviceKind, level: Int, isCharging: Bool = false, component: String? = nil) {
        self.name = name
        self.kind = kind
        self.level = max(0, min(100, level))
        self.isCharging = isCharging
        self.component = component
        self.id = component.map { "\(name)#\($0)" } ?? name
    }

    public var displayName: String {
        guard let component else { return name }
        return "\(name) (\(component))"
    }
}

public enum PeripheralMerge {
    /// Combine IOKit HID results with system_profiler results, dropping duplicates by name.
    /// HID entries win because they report charging state.
    public static func merge(hid: [DeviceBattery], bluetooth: [DeviceBattery]) -> [DeviceBattery] {
        var result = hid
        let hidNames = Set(hid.map { $0.name.lowercased() })
        for device in bluetooth where !hidNames.contains(device.name.lowercased()) {
            result.append(device)
        }
        return result.sorted { ($0.name, $0.component ?? "") < ($1.name, $1.component ?? "") }
    }
}

public enum EarbudCombine {
    /// When both earbuds of the same pair are connected, show them as one "earbuds" entry at the
    /// lower of the two levels (so the gauge never overstates); the case and single buds stay as
    /// they are. Order is preserved (the pair takes the left bud's place).
    public static func combine(_ devices: [DeviceBattery]) -> [DeviceBattery] {
        var result: [DeviceBattery] = []
        var handled = Set<String>()
        for device in devices {
            guard device.kind == .earbudLeft || device.kind == .earbudRight else {
                result.append(device)
                continue
            }
            let key = device.name.lowercased()
            if handled.contains(key) { continue }
            let pair = devices.filter { $0.name.lowercased() == key && ($0.kind == .earbudLeft || $0.kind == .earbudRight) }
            if pair.contains(where: { $0.kind == .earbudLeft }), pair.contains(where: { $0.kind == .earbudRight }) {
                handled.insert(key)
                var both = DeviceBattery(name: device.name, kind: .earbuds,
                                         level: pair.map(\.level).min() ?? device.level,
                                         isCharging: pair.allSatisfy(\.isCharging), component: nil)
                both.id = device.name + "#both"
                result.append(both)
            } else {
                result.append(device)
            }
        }
        return result
    }
}

/// Battery glyph and status colour ramp.
public enum BatteryLook {
    public enum Status: Equatable, Sendable { case low, medium, good }

    /// red < 20, orange < 50, green otherwise.
    public static func status(for level: Int) -> Status {
        if level < 20 { return .low }
        if level < 50 { return .medium }
        return .good
    }

    public static func symbol(for level: Int, charging: Bool) -> String {
        if charging { return "bolt.fill" }
        switch level {
        case ..<10: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<70: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Where a widget group sits on a screen, as fractions of the screen (0...1, origin top-left).
/// x/y is the centre of the group.
public struct ScreenPlacement: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func clamped() -> ScreenPlacement {
        ScreenPlacement(x: min(0.98, max(0.02, x)), y: min(0.98, max(0.02, y)))
    }

    /// Default lock-screen spot: centred, under the system clock.
    public static let lockScreenDefault = ScreenPlacement(x: 0.5, y: 0.36)

    public static let presets: [(name: String, placement: ScreenPlacement)] = [
        ("Under clock", ScreenPlacement(x: 0.5, y: 0.36)),
        ("Top", ScreenPlacement(x: 0.5, y: 0.14)),
        ("Centre", ScreenPlacement(x: 0.5, y: 0.5)),
        ("Above login", ScreenPlacement(x: 0.5, y: 0.7)),
        ("Top left", ScreenPlacement(x: 0.16, y: 0.14)),
        ("Top right", ScreenPlacement(x: 0.84, y: 0.14)),
        ("Bottom left", ScreenPlacement(x: 0.16, y: 0.86)),
        ("Bottom right", ScreenPlacement(x: 0.84, y: 0.86)),
    ]

    /// Top-left origin of a box of `size` centred on this placement inside `bounds`,
    /// kept fully inside the bounds.
    public func origin(for size: CGSize, in bounds: CGSize) -> CGPoint {
        let cx = bounds.width * x
        let cy = bounds.height * y
        let ox = min(max(0, cx - size.width / 2), max(0, bounds.width - size.width))
        let oy = min(max(0, cy - size.height / 2), max(0, bounds.height - size.height))
        return CGPoint(x: ox, y: oy)
    }
}
