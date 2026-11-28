import AppKit
import SwiftUI
import LockWidgetsCore

/// Glass = gauges on glass discs. Floating = gauges straight on the wallpaper. Cards = rounded tiles.
enum VisualStyle: String, Codable, CaseIterable, Identifiable {
    case glass, floating, cards
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: return "Glass"
        case .floating: return "Floating"
        case .cards: return "Cards"
        }
    }
}

enum CardStyle: String, Codable, CaseIterable, Identifiable {
    case system, glass, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Match system (light/dark)"
        case .glass: return "Glass"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

/// Colour of text and icons.
enum GlyphTheme: String, Codable, CaseIterable, Identifiable {
    case auto, system, white, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Match wallpaper"
        case .system: return "Match light/dark mode"
        case .white: return "White"
        case .black: return "Black"
        }
    }
}

/// Colour of the gauge rings.
enum GaugeTint: String, Codable, CaseIterable, Identifiable {
    case status, accent, monochrome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return "Status (red / orange / green)"
        case .accent: return "Accent colour"
        case .monochrome: return "Monochrome"
        }
    }
}

enum AccentSource: String, Codable, CaseIterable, Identifiable {
    case system, custom
    var id: String { rawValue }
    var title: String { self == .system ? "System accent" : "Custom" }
}

enum NotchExpandMode: String, Codable, CaseIterable, Identifiable {
    case hover, click, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hover: return "Hover"
        case .click: return "Click"
        case .never: return "Compact only"
        }
    }
}

enum LocationMode: String, Codable, CaseIterable, Identifiable {
    case automatic, city
    var id: String { rawValue }
    var title: String { self == .automatic ? "My location" : "City" }
}

/// Everything the user can customise. Stored as JSON in UserDefaults.
struct Config: Codable, Equatable {
    // Widgets
    var widgets: [WidgetEntry] = WidgetEntry.defaults

    // Look
    var visualStyle: VisualStyle = .glass
    var glassMigrationDone: Bool = true
    var cardStyle: CardStyle = .system
    var glyphTheme: GlyphTheme = .auto
    var gaugeTint: GaugeTint = .status
    var accentSource: AccentSource = .system
    var accentHex: String = "#0A84FF"
    var cornerRadius: Double = 22
    var spacing: Double = 22

    // Lock screen
    var lockScreenWidgets: Bool = true
    var lockScreenPlayer: Bool = true
    var lockScreenPlacement: ScreenPlacement = .lockScreenDefault
    var lockScreenScale: Double = 1.1
    var allDisplays: Bool = false
    var wallpaperMode: Bool = false
    var originalWallpapers: [String: String] = [:]

    // Times shown in widgets follow the system locale by default
    var use24Hour: Bool = Config.systemUses24Hour

    // Weather — defaults follow the system locale and location
    var unit: TemperatureUnit = Config.systemUnit
    var locationMode: LocationMode = .automatic
    var city: String = ""
    var weatherRefreshMinutes: Int = 10
    var showLocationName: Bool = true

    // Batteries
    var showPercentText: Bool = true
    var lowBatteryThreshold: Int = 20
    var showTimeRemaining: Bool = true
    var hiddenDevices: [String] = []

    // Notch island
    var notchEnabled: Bool = true
    var notchExpandMode: NotchExpandMode = .hover
    var hoverDelay: Double = 0.15
    var hoverMigrated: Bool = true
    var hoverDwellMigrated: Bool = true
    var contrastOutline: Bool = false
    var notchPages: [String] = NotchPage.allCases.map(\.rawValue)
    var notchWidthAdjust: Double = 0
    var notchHeightAdjust: Double = 0
    var notchHaptics: Bool = true
    var swipeToSkip: Bool = true
    /// Flip which swipe direction skips forward. Some Macs' trackpads/mice report horizontal scroll
    /// opposite to the natural-scroll normalization, so the user can invert it here. New default-false
    /// bool: old configs merge over it safely, no migration flag needed.
    var swipeSkipReversed: Bool = false
    var artworkFlip: Bool = true
    var replaceSystemHUD: Bool = true
    var hudShowsPercent: Bool = true
    var hudUsesAccent: Bool = false
    var hudShowsDevice: Bool = true
    var notchPageDots: Bool = false
    /// How long each kind of activity stays on screen, in seconds (Settings › each page).
    var activityDurations: [String: Double] = [:]
    /// Waveform colour: "monochrome", "colored" (from the album art) or "gradient".
    var waveformColor: String = "colored"
    /// What the island shows while the Mac is locked: "none", "icon" or "glow".
    var lockedIndicator: String = "icon"
    var lockIndicatorMigrated: Bool = true
    var cleanSongTitles: Bool = true
    /// Show what the user is watching in a browser or streaming app (Netflix, Prime, YouTube…) in
    /// the island, the way Now Playing works for music. New field: old configs merge over the
    /// default (true), so loading them stays safe.
    var watchingEnabled: Bool = true
    /// What the collapsed island shows when nothing is playing (or a song has been paused for a
    /// few seconds, MediaController.pausedGrace): "weather", "notPlaying" (a dimmed note + "Not playing") or "none" (plain notch).
    /// When nothing plays the island returns to its normal state (plain notch) unless the user picks
    /// "Not playing" or weather in Settings.
    var idleActivity: String = "none"
    var idleMigrated: Bool = true
    var idleRestored: Bool = true
    var hudStyle: String = "level"      // level | gradient | glow | plain | segments
    var hudStyleMigrated: Bool = true
    var showMenuBarIcon: Bool = true
    var songChangePeek: Bool = true
    var notificationReply: Bool = true
    var notchLeftControl: String = "like"   // like | shuffle | repeat | none
    var notchHideInFullscreen: Bool = true
    var notchHideFromCapture: Bool = false
    var notchHideWhenSourceActive: Bool = false
    var keepAwake: Bool = false
    var hourlyChime: Bool = false
    var calendarPeek: Bool = false
    var calendarPeekMinutes: Int = 5
    var lowPowerActivity: Bool = true
    var playerPlacement: ScreenPlacement? = nil
    /// Free arrangement: every lock-screen widget has its own position.
    var freeLayout: Bool = false
    // Optional desktop widgets
    var desktopWidgetsEnabled: Bool = false
    var desktopLineMode: Bool = false
    var desktopPlacements: [String: ScreenPlacement] = [:]
    var desktopLinePlacement: ScreenPlacement = ScreenPlacement(x: 0.5, y: 0.22)
    var widgetPlacements: [String: ScreenPlacement] = [:]
    var lockScreenAutoSize: Bool = true
    /// Live activities turned off: "charging", "devices", "volume", "unlock", "timer", "nowPlaying".
    var disabledActivities: [String] = []
    var shelfItems: [String] = []

    // Integrations
    var mirrorNotifications: Bool = false
    var notificationSeconds: Double = 5
    var notificationSound: Bool = false
    var notificationShowBody: Bool = true
    var mutedNotificationApps: [String] = []
    /// Per-app behaviour: "banner" (pop up + list, default), "quiet" (list only) or "off".
    var notificationAppModes: [String: String] = [:]
    /// Apps that have notified (or were added by hand), so they stay configurable.
    var notificationKnownApps: [String] = []
    /// Tapping a Messages notification opens the reply here (true) or always opens the app.
    var notificationTapReplies: Bool = true
    /// "glass" (Liquid Glass) or "solid".
    var notificationStyle: String = "glass"
    /// Every lock-screen widget drawn as a round gauge.
    var allGauges: Bool = true
    /// Hide the island while Mission Control (four-finger swipe up) is open.
    var notchHideInMissionControl: Bool = false
    var missionControlMigrated: Bool = true
    /// Jiggle the whole island when a song is skipped, and how far (points).
    var skipJiggle: Bool = true
    /// Show both AirPods as one gauge (lower of the two levels) when both are connected.
    var combineEarbuds: Bool = true
    var skipJiggleAmount: Double = 18
    /// The first-launch welcome has been completed.
    var onboardingDone: Bool = false
    /// Ring/arc thickness of widget gauges (points at 1×).
    var gaugeLineWidth: Double = 6
    /// How strong the Dark/Light glass finishes and card backgrounds are (0–1).
    var glassStrength: Double = 0.5
    /// Clicking the song in the island opens the app it's playing from.
    var openSourceOnTap: Bool = true
    /// Small icon of the playing app on the album art.
    var showSourceBadge: Bool = true
    /// Glass finish for the Glass widget style: clear, regular, tinted, dark, light.
    var glassFinish: String = "clear"
    /// Hold notification banners (and optionally peeks) while Do Not Disturb / a Focus is on.
    var respectFocus: Bool = true
    var focusHoldsPeeks: Bool = false
    var spotifyClientID: String = ""
    /// Check GitHub for a newer Notch once a day.
    var autoCheckUpdates: Bool = true
    /// Also count songs liked from another release (reads the whole Liked Songs list once a day —
    /// many requests, so off by default).
    var spotifyMatchReleases: Bool = false

    // Sounds
    var lockSounds: Bool = true
    var lockSoundName: String = "Notch Lock"
    /// Optional sound files chosen by the user (stay on their Mac; never bundled).
    var customLockSoundPath: String = ""
    var customUnlockSoundPath: String = ""
    var unlockSoundName: String = "Notch Unlock"
    var soundsMigrated: Bool = true
    var userDisabledLaunchAtLogin: Bool = false

    var hasLaunchedBefore: Bool = false
    var launchAtLoginConfigured: Bool = false

    static var systemUnit: TemperatureUnit {
        Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }

    static var systemUses24Hour: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !format.contains("a")
    }

    /// Decode on top of the defaults so configs from older versions keep working.
    static func load(from data: Data) -> Config {
        guard
            var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let defaultsData = try? JSONEncoder().encode(Config()),
            var base = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { return Config() }
        // Drop widget entries that no longer exist (e.g. the old Clock) or are malformed,
        // one at a time, instead of losing the whole list.
        if let entries = saved["widgets"] as? [[String: Any]] {
            saved["widgets"] = entries.filter { entry in
                guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return false }
                return (try? JSONDecoder().decode(WidgetEntry.self, from: data)) != nil
            }
        }
        // Same for per-widget placements: one bad entry must not cost the others.
        if let placements = saved["widgetPlacements"] as? [String: Any] {
            saved["widgetPlacements"] = placements.filter { _, value in
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return false }
                return (try? JSONDecoder().decode(ScreenPlacement.self, from: data)) != nil
            }
        }
        func decode(_ dict: [String: Any]) -> Config? {
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(Config.self, from: data)
        }
        var merged = base
        merged.merge(saved) { _, new in new }
        var decoded = decode(merged)
        if decoded == nil {
            // A single key with the wrong type (hand edits, a renamed enum case, a downgrade)
            // used to reset every setting. Keep each saved key that decodes on its own and
            // fall back to the default only for the keys that don't.
            for (key, value) in saved {
                var trial = base
                trial[key] = value
                if decode(trial) != nil { base[key] = value }
            }
            decoded = decode(base)
        }
        guard var config = decoded else { return Config() }
        config.widgets = WidgetEntry.normalized(config.widgets)
        // Mission Control hiding is now opt-in (fullscreen hiding stays on); switch it off once.
        if saved["missionControlMigrated"] == nil {
            config.notchHideInMissionControl = false
            config.missionControlMigrated = true
        }
        // Switch to the level-colour bar once (green when low → red when high).
        if saved["hudStyleMigrated"] == nil {
            config.hudStyle = "level"
            config.hudStyleMigrated = true
        }
        // Open instantly on hover by default (older configs waited 0.08–0.15 s).
        if saved["hoverMigrated"] == nil {
            config.hoverDelay = 0
            config.hoverMigrated = true
        }
        // A short dwell so brushing past the notch (e.g. heading for the menu bar) doesn't open it.
        if saved["hoverDwellMigrated"] == nil {
            if config.hoverDelay < 0.15 { config.hoverDelay = 0.15 }
            config.hoverDwellMigrated = true
        }
        // Show the small lock while locked by default (older configs had "none").
        if saved["lockIndicatorMigrated"] == nil {
            config.lockedIndicator = "icon"
            config.lockIndicatorMigrated = true
        }
        // Weather was briefly made the idle default and switched on for everyone; the island should
        // return to its normal (plain) state when nothing plays. Undo that once.
        if saved["idleRestored"] == nil {
            if config.idleActivity == "weather" { config.idleActivity = "none" }
            config.idleRestored = true
            config.idleMigrated = true
        }
        // The app was renamed: carry the saved built-in sound choice over.
        if config.lockSoundName == "Islet Lock" { config.lockSoundName = "Notch Lock" }
        if config.unlockSoundName == "Islet Unlock" { config.unlockSoundName = "Notch Unlock" }
        // Move the old default sounds to Notch's own lock/unlock sounds once.
        if saved["soundsMigrated"] == nil {
            if config.lockSoundName == "Tink" { config.lockSoundName = "Notch Lock" }
            if config.unlockSoundName == "Pop" { config.unlockSoundName = "Notch Unlock" }
            config.soundsMigrated = true
        }
        // Configs saved before the Glass style existed: switch to it once.
        if saved["glassMigrationDone"] == nil {
            config.visualStyle = .glass
            config.glassMigrationDone = true
        }
        return config
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private static let key = "LockWidgets.config.v2"

    /// Snapshot/test runs set this to false so they never overwrite the user's settings.
    var persist = true

    @Published var config: Config {
        didSet { if config != oldValue { save() } }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            config = Config.load(from: data)
        } else {
            config = Config()
        }
    }

    static let defaultDurations: [String: Double] = [
        "battery": 5, "devices": 5, "focus": 2.5, "hud": 1.5, "songChange": 2, "calendar": 6, "unlock": 2,
    ]

    /// Duration group for an activity key (charging + low battery share "battery", volume + brightness share "hud").
    static func durationGroup(for key: String) -> String {
        switch key {
        case "charging", "lowBattery", "lowPower": return "battery"
        case "volume", "brightness": return "hud"
        default: return key
        }
    }

    func duration(_ group: String) -> Binding<Double> {
        Binding(
            get: { self.config.activityDurations[group] ?? AppSettings.defaultDurations[group] ?? 3 },
            set: { self.config.activityDurations[group] = $0 }
        )
    }

    /// Where a widget sits in the free arrangement: its saved spot, or spread out along the row.
    func placement(for kind: WidgetKind) -> ScreenPlacement {
        if let saved = config.widgetPlacements[kind.rawValue] { return saved }
        let enabled = config.widgets.filter(\.enabled).map(\.kind)
        let index = Double(enabled.firstIndex(of: kind) ?? 0)
        let count = Double(max(1, enabled.count))
        let base = config.lockScreenPlacement
        return ScreenPlacement(x: base.x + (index - (count - 1) / 2) * 0.075, y: base.y).clamped()
    }

    /// Moves the widget group. In the free arrangement each widget (and a placed player) has its own
    /// saved spot, so changing only the group placement did nothing visible for them; shift those
    /// spots by the same amount so presets, sliders and click-to-place work in both arrangements.
    func moveGroup(to placement: ScreenPlacement) {
        var cfg = config
        if cfg.freeLayout {
            let dx = placement.x - cfg.lockScreenPlacement.x
            let dy = placement.y - cfg.lockScreenPlacement.y
            func shifted(_ p: ScreenPlacement) -> ScreenPlacement { ScreenPlacement(x: p.x + dx, y: p.y + dy).clamped() }
            cfg.widgetPlacements = cfg.widgetPlacements.mapValues(shifted)
            cfg.playerPlacement = cfg.playerPlacement.map(shifted)
        }
        cfg.lockScreenPlacement = placement
        config = cfg
    }

    /// Binding for one axis of the group placement (the Fine tune sliders).
    func groupAxis(_ axis: WritableKeyPath<ScreenPlacement, Double>) -> Binding<Double> {
        Binding(
            get: { self.config.lockScreenPlacement[keyPath: axis] },
            set: { value in
                var p = self.config.lockScreenPlacement
                p[keyPath: axis] = value
                self.moveGroup(to: p)
            }
        )
    }

    /// The player's spot when it has none of its own in the free arrangement.
    var defaultFreePlayerPlacement: ScreenPlacement {
        ScreenPlacement(x: config.lockScreenPlacement.x, y: min(0.9, config.lockScreenPlacement.y + 0.2))
    }

    /// Lock-screen widget size: automatic from the main display's height, or the manual slider.
    var lockScale: CGFloat {
        guard config.lockScreenAutoSize else { return CGFloat(config.lockScreenScale) }
        let height = NSScreen.screens.first?.frame.height ?? 1112
        return min(1.4, max(0.7, 0.95 * height / 1112))
    }

    func save() {
        guard persist, let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func resetToDefaults() {
        var fresh = Config()
        fresh.hasLaunchedBefore = true
        fresh.launchAtLoginConfigured = config.launchAtLoginConfigured
        // Not a preference either: resetting re-ran the welcome on the next launch.
        fresh.onboardingDone = config.onboardingDone
        fresh.originalWallpapers = config.originalWallpapers
        fresh.wallpaperMode = config.wallpaperMode
        // Not preferences: a reset must not re-register the login item the user turned off, empty
        // the file shelf behind its back, or orphan the saved Spotify sign-in (its refresh needs the ID).
        fresh.userDisabledLaunchAtLogin = config.userDisabledLaunchAtLogin
        fresh.shelfItems = config.shelfItems
        fresh.spotifyClientID = config.spotifyClientID
        config = fresh
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded())
        )
    }
}

/// Small bridge so SwiftUI views (settings) can trigger app-level actions.
@MainActor
final class AppActions {
    static let shared = AppActions()
    var openSettings: () -> Void = {}
    var openSettingsPage: (String) -> Void = { _ in }
    var previewLockScreen: () -> Void = {}
    var showLockPreview: () -> Void = {}
    var refreshAll: () -> Void = {}
    var rebakeWallpaper: () -> Void = {}
}

/// Notch's own lock/unlock clicks (bundled) plus the built-in macOS alert sounds.
enum SystemSounds {
    static let names = ["Notch Lock", "Notch Unlock", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    private static var cache: [String: NSSound] = [:]

    /// Plays a user-chosen file if one is set for this slot, otherwise the named sound.
    static func play(_ name: String, customPath: String) {
        if !customPath.isEmpty, let sound = NSSound(contentsOf: URL(fileURLWithPath: customPath), byReference: true) {
            sound.volume = 0.8
            sound.play()
            return
        }
        play(name)
    }

    static func play(_ name: String) {
        if let sound = cache[name] {
            sound.stop()
            sound.play()
            return
        }
        let bundled: [String: String] = ["Notch Lock": "lock", "Notch Unlock": "unlock"]
        let sound: NSSound?
        if let file = bundled[name], let url = Bundle.main.url(forResource: file, withExtension: "caf") {
            sound = NSSound(contentsOf: url, byReference: true)
        } else {
            sound = NSSound(named: NSSound.Name(name))
        }
        sound?.volume = 0.8
        cache[name] = sound
        sound?.play()
    }
}
