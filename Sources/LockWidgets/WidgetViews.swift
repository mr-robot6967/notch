import SwiftUI
import LockWidgetsCore

// MARK: - Environment

/// Resolved colours for the lock-screen widgets, derived from settings + system theme.
struct WidgetTheme {
    var lightGlyphs: Bool = true
    var accent: Color = .blue
    var floating: Bool = true
    var glass: Bool = false
    var monochromeIcons: Bool = false

    var glyph: Color { lightGlyphs ? .white : .black }
    var secondary: Color { glyph.opacity(0.7) }
    var track: Color { glyph.opacity(0.22) }
    var shadow: Color { lightGlyphs ? .black.opacity(0.35) : .white.opacity(0.5) }

    @MainActor
    static func resolve(settings: AppSettings, store: WidgetStore, screenKey: String?) -> WidgetTheme {
        let cfg = settings.config
        var theme = WidgetTheme()
        theme.accent = cfg.accentSource == .system ? store.systemAccent : (Color(hex: cfg.accentHex) ?? .blue)
        theme.floating = cfg.visualStyle != .cards
        theme.glass = cfg.visualStyle == .glass
        theme.monochromeIcons = cfg.gaugeTint == .monochrome

        if cfg.visualStyle == .cards {
            switch cfg.cardStyle {
            case .system: theme.lightGlyphs = store.isDarkMode
            case .glass, .dark: theme.lightGlyphs = true
            case .light: theme.lightGlyphs = false
            }
        } else {
            switch cfg.glyphTheme {
            case .auto:
                theme.lightGlyphs = !store.wallpaperIsLight(screenKey: screenKey)
            case .system: theme.lightGlyphs = store.isDarkMode
            case .white: theme.lightGlyphs = true
            case .black: theme.lightGlyphs = false
            }
        }
        return theme
    }
}

private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private struct BakedRenderingKey: EnvironmentKey { static let defaultValue = false }
private struct WidgetThemeKey: EnvironmentKey { static let defaultValue = WidgetTheme() }
private struct IsPreviewKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
    /// True when rendering into an image; materials can't be rasterised there.
    var bakedRendering: Bool {
        get { self[BakedRenderingKey.self] }
        set { self[BakedRenderingKey.self] = newValue }
    }
    var widgetTheme: WidgetTheme {
        get { self[WidgetThemeKey.self] }
        set { self[WidgetThemeKey.self] = newValue }
    }
    /// Settings previews show placeholders for widgets that would otherwise hide.
    var isWidgetPreview: Bool {
        get { self[IsPreviewKey.self] }
        set { self[IsPreviewKey.self] = newValue }
    }
}

func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

enum TimeFormat {
    private static var cache: [String: DateFormatter] = [:]

    private static func formatter(_ key: String, _ build: (DateFormatter) -> Void) -> DateFormatter {
        if let f = cache[key] { return f }
        let f = DateFormatter()
        build(f)
        cache[key] = f
        return f
    }

    static func time(_ date: Date, h24: Bool, seconds: Bool = false) -> String {
        let pattern = (h24 ? "HH:mm" : "h:mm") + (seconds ? ":ss" : "")
        return formatter("t" + pattern) { $0.dateFormat = pattern }.string(from: date)
    }

    static func date(_ date: Date, long: Bool) -> String {
        let template = long ? "EEEEdMMMM" : "EEEdMMM"
        return formatter("d" + template) { $0.setLocalizedDateFormatFromTemplate(template) }.string(from: date)
    }

    static func weekday(_ date: Date) -> String {
        formatter("wEEE") { $0.dateFormat = "EEE" }.string(from: date)
    }

    static func day(_ date: Date) -> String {
        formatter("dd") { $0.dateFormat = "d" }.string(from: date)
    }
}

private func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

/// Temperature colours (Celsius anchors).
private func temperatureColor(celsius t: Double) -> Color {
    let anchors: [(Double, (Double, Double, Double))] = [
        (-15, (0.36, 0.36, 0.95)), (0, (0.30, 0.60, 1.00)), (10, (0.30, 0.85, 0.95)),
        (18, (0.45, 0.88, 0.45)), (24, (0.98, 0.85, 0.30)), (30, (0.98, 0.58, 0.22)), (38, (0.92, 0.25, 0.22)),
    ]
    if t <= anchors[0].0 { let c = anchors[0].1; return Color(red: c.0, green: c.1, blue: c.2) }
    for i in 1..<anchors.count where t <= anchors[i].0 {
        let (t0, a) = anchors[i - 1], (t1, b) = anchors[i]
        let f = (t - t0) / (t1 - t0)
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
    let c = anchors.last!.1
    return Color(red: c.0, green: c.1, blue: c.2)
}

@MainActor
private func batteryTint(level: Int, charging: Bool, settings: AppSettings, theme: WidgetTheme) -> Color {
    switch settings.config.gaugeTint {
    case .status:
        if charging { return .green }
        if level < settings.config.lowBatteryThreshold { return .red }
        if level < 50 { return .orange }
        return .green
    case .accent: return theme.accent
    case .monochrome: return theme.glyph.opacity(0.9)
    }
}

// MARK: - Strip

/// The row of enabled widgets shown on the lock screen.
struct WidgetStripView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @Environment(\.isWidgetPreview) private var isPreview
    var screenKey: String? = nil
    var scaleOverride: CGFloat? = nil

    var body: some View {
        let cfg = settings.config
        let entries = cfg.widgets.filter(\.enabled)
        let k = scaleOverride ?? settings.lockScale
        let spacing = CGFloat(cfg.spacing) * k
        let theme = WidgetTheme.resolve(settings: settings, store: store, screenKey: screenKey)

        Group {
            if entries.isEmpty {
                if isPreview {
                    WidgetContainer {
                        Label("No widgets turned on", systemImage: "square.grid.2x2")
                            .font(rounded(13 * k, .medium))
                            .foregroundStyle(theme.secondary)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(entries) { WidgetView(entry: $0) }
                }
            }
        }
        .padding(16 * k)
        .shadow(color: theme.floating && !theme.glass ? theme.shadow : .clear, radius: 8 * k, y: 3 * k)
        .environment(\.uiScale, k)
        .environment(\.widgetTheme, theme)
    }
}

struct WidgetView: View {
    let entry: WidgetEntry
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        // "Gauges for every widget" uses each widget's round form.
        let entry = settings.config.allGauges
            ? WidgetEntry(kind: self.entry.kind, enabled: self.entry.enabled, size: .compact)
            : self.entry
        switch entry.kind {
        case .weather: WeatherWidget(size: entry.size)
        case .airQuality: AirQualityWidget(size: entry.size)
        case .forecast: ForecastWidget(size: entry.size)
        case .macBattery: MacBatteryWidget(size: entry.size)
        case .peripherals: PeripheralsWidget(size: entry.size)
        case .calendar: CalendarWidget(size: entry.size)
        }
    }
}

/// Places its single child so that the child's centre sits at `placement` (fractions of the
/// available area), clamped to stay fully inside. Works in ImageRenderer too.
struct PlacementLayout: Layout {
    var placement: ScreenPlacement

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(.unspecified)
        let origin = placement.origin(for: size, in: bounds.size)
        child.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                    anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// One widget on its own (free arrangement), with the same size, theme and shadow as in the row.
struct SingleWidgetView: View {
    let entry: WidgetEntry
    var screenKey: String? = nil
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore

    var body: some View {
        let k = settings.lockScale
        let theme = WidgetTheme.resolve(settings: settings, store: store, screenKey: screenKey)
        WidgetView(entry: entry)
            .padding(10 * k)
            .shadow(color: theme.floating && !theme.glass ? theme.shadow : .clear, radius: 8 * k, y: 3 * k)
            .environment(\.uiScale, k)
            .environment(\.widgetTheme, theme)
    }
}

/// Places each child at its own spot (fractions of the canvas), kept fully on screen.
struct FreeLayout: Layout {
    var placements: [ScreenPlacement]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, child) in subviews.enumerated() {
            let size = child.sizeThatFits(.unspecified)
            let placement = index < placements.count ? placements[index] : ScreenPlacement(x: 0.5, y: 0.5)
            let o = placement.origin(for: size, in: bounds.size)
            child.place(at: CGPoint(x: bounds.minX + o.x, y: bounds.minY + o.y), anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

/// All enabled widgets, each at its own position (free arrangement).
struct FreeWidgetsView: View {
    var screenKey: String? = nil
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let entries = settings.config.widgets.filter(\.enabled)
        FreeLayout(placements: entries.map { settings.placement(for: $0.kind) }) {
            ForEach(entries) { entry in
                SingleWidgetView(entry: entry, screenKey: screenKey).fixedSize()
            }
        }
    }
}

/// The strip positioned on a full-screen canvas using the saved lock-screen placement.
struct PlacedStrip: View {
    @EnvironmentObject private var settings: AppSettings
    var screenKey: String? = nil

    var body: some View {
        if settings.config.freeLayout {
            ZStack(alignment: .topLeading) {
                FreeWidgetsView(screenKey: screenKey)
                PlacementLayout(placement: settings.config.playerPlacement ?? settings.defaultFreePlayerPlacement) {
                    LockPlayerSection(screenKey: screenKey).fixedSize()
                }
            }
        } else {
            LockLayout(widgets: settings.config.lockScreenPlacement, player: settings.config.playerPlacement) {
                WidgetStripView(screenKey: screenKey).fixedSize()
                LockPlayerSection(screenKey: screenKey).fixedSize()
            }
        }
    }
}

// MARK: - Containers

/// Floating style: content directly on the wallpaper. Cards style: a rounded tile.
struct WidgetContainer<Content: View>: View {
    @EnvironmentObject private var settings: AppSettings
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @Environment(\.uiScale) private var k

    var body: some View {
        switch settings.config.visualStyle {
        case .cards:
            WidgetCard { content }
        case .glass:
            content
                .padding(.horizontal, 16 * k)
                .padding(.vertical, 12 * k)
                .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 26 * k, style: .continuous)))
        case .floating:
            content
        }
    }
}

/// Liquid Glass (macOS 26+) behind a widget, with a material fallback on older macOS and a
/// flat translucent fill when rendering into an image.
struct GlassBackground<S: Shape>: View {
    let shape: S
    @Environment(\.bakedRendering) private var baked
    @Environment(\.widgetTheme) private var theme
    @EnvironmentObject private var settings: AppSettings
    private var finish: String { settings.config.glassFinish }
    private var strength: Double { settings.config.glassStrength }
    @Environment(\.uiScale) private var k

    private func cornerRadius(for size: CGSize) -> CGFloat {
        if shape is Circle { return min(size.width, size.height) / 2 }
        if let rounded = shape as? RoundedRectangle { return rounded.cornerSize.width }
        return 16
    }

    var body: some View {
        if baked {
            shape.fill(theme.glyph.opacity(0.10))
                .overlay(shape.stroke(theme.glyph.opacity(0.22), lineWidth: 0.8))
        } else if finish == "dark" {
            shape.fill(Color.black.opacity(0.15 + 0.6 * strength)).overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.8))
        } else if finish == "light" {
            shape.fill(Color.white.opacity(0.2 + 0.6 * strength)).overlay(shape.stroke(Color.white.opacity(0.6), lineWidth: 0.8))
        } else if #available(macOS 26.0, *) {
            // AppKit's glass view is composited by the window server against what is really behind
            // the window (the lock-screen wallpaper, live wallpapers included), so it has proper
            // depth and refraction; SwiftUI's glass in this separate window rendered flat.
            ZStack {
                // Soft shadow only outside the shape (cut out inside so the glass isn't darkened):
                // lifts the circle off the wallpaper.
                ZStack {
                    shape.fill(Color.black).shadow(color: .black.opacity(0.14), radius: 5 * k, y: 2 * k)
                    shape.fill(Color.black).blendMode(.destinationOut)
                }
                .compositingGroup()
                GeometryReader { geo in
                    NativeGlass(cornerRadius: cornerRadius(for: geo.size),
                                style: finish == "regular" || finish == "tinted" ? .regular : .clear,
                                tint: finish == "tinted" ? NSColor(theme.accent.opacity(0.45)) : nil)
                }
                .clipShape(shape)
                // Light from above, a touch of shade below: reads as a rounded lens, not a flat disc.
                shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.14)],
                                          startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                .environment(\.colorScheme, theme.lightGlyphs ? .dark : .light)
        }
    }
}

struct WidgetCard<Content: View>: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @Environment(\.bakedRendering) private var baked
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(settings.config.cornerRadius) * k, style: .continuous)
        content
            .padding(.horizontal, 14 * k)
            .padding(.vertical, 12 * k)
            .background { background.clipShape(shape) }
            .overlay { shape.strokeBorder(theme.glyph.opacity(0.10), lineWidth: 0.8) }
            .shadow(color: .black.opacity(0.22), radius: 10 * k, y: 3 * k)
    }

    @ViewBuilder private var background: some View {
        let dark = theme.lightGlyphs
        switch settings.config.cardStyle {
        case .dark:
            Color(white: 0.08).opacity(0.85)
        case .glass, .system, .light:
            if baked {
                (dark ? Color.black.opacity(0.42) : Color.white.opacity(0.82))
            } else {
                Rectangle().fill(.regularMaterial)
                    .environment(\.colorScheme, dark ? .dark : .light)
            }
        }
    }
}

// MARK: - Gauges

/// Circular capacity gauge: a 64pt ring with a glyph in the middle.
struct RingGauge<Center: View>: View {
    @EnvironmentObject private var settings: AppSettings
    let fraction: Double
    let tint: Color
    @ViewBuilder var center: Center
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: CGFloat(settings.config.gaugeLineWidth) * k)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: CGFloat(settings.config.gaugeLineWidth) * k, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center.foregroundStyle(theme.glyph)
        }
        .frame(width: 64 * k, height: 64 * k)
    }
}

/// 250° arc open at the bottom, filled with a gradient up to the value (no marker dot).
struct ArcGauge<Center: View>: View {
    @EnvironmentObject private var settings: AppSettings
    let fraction: Double
    let colors: [Color]
    @ViewBuilder var center: Center
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        let line = CGFloat(settings.config.gaugeLineWidth) * k
        let diameter = 64 * k
        let sweep = 250.0 / 360.0
        let value = min(1, max(0.04, fraction))
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(theme.track, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(145))
            Circle()
                .trim(from: 0, to: sweep * value)
                .stroke(
                    AngularGradient(colors: colors.count > 1 ? colors : colors + colors,
                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(250 * value)),
                    style: StrokeStyle(lineWidth: line, lineCap: .round)
                )
                .rotationEffect(.degrees(145))
            center.foregroundStyle(theme.glyph)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// A round widget: gauge on top, small label underneath (spacing 6, 13pt medium rounded).
/// Glass style puts the gauge on a glass disc.
struct RoundTile<Gauge: View, Caption: View>: View {
    @ViewBuilder var gauge: Gauge
    @ViewBuilder var caption: Caption
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        let content = VStack(spacing: 6 * k) {
            if theme.glass {
                gauge
                    .padding(8 * k)
                    .background(GlassBackground(shape: Circle()))
            } else {
                gauge
            }
            caption
                .font(rounded(13 * k, .medium))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 80 * k)
        }
        if settings.config.visualStyle == .cards {
            WidgetCard { content }
        } else {
            content
        }
    }
}

/// Wide (inline) widget body: icon + headline + detail.
struct WideTile: View {
    let symbol: String
    let headline: String
    let detail: String?
    var symbolTint: Color? = nil
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        WidgetContainer {
            HStack(spacing: 10 * k) {
                ThemedSymbol(name: symbol, size: 24 * k, tint: symbolTint)
                    .frame(width: 30 * k)
                VStack(alignment: .leading, spacing: 1 * k) {
                    Text(headline)
                        .font(rounded(22 * k, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.glyph)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(rounded(12 * k, .medium))
                            .foregroundStyle(theme.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct ThemedSymbol: View {
    let name: String
    let size: CGFloat
    var tint: Color? = nil
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        let image = Image(systemName: name).font(.system(size: size, weight: .semibold))
        if let tint {
            image.foregroundStyle(tint)
        } else if theme.monochromeIcons {
            image.symbolRenderingMode(.hierarchical).foregroundStyle(theme.glyph)
        } else {
            image.symbolRenderingMode(.multicolor).foregroundStyle(theme.glyph)
        }
    }
}

private struct EmptyRound: View {
    let symbol: String
    let caption: String
    @Environment(\.uiScale) private var k

    var body: some View {
        RoundTile {
            RingGauge(fraction: 0, tint: .clear) {
                Image(systemName: symbol).font(.system(size: 20 * k, weight: .semibold)).opacity(0.7)
            }
        } caption: {
            Text(caption)
        }
    }
}

// MARK: - Weather

struct WeatherWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        if let w = store.weather {
            if size == .compact {
                RoundTile {
                    ArcGauge(fraction: temperatureFraction(current: w.temperature, low: w.low, high: w.high),
                             colors: arcColors(w)) {
                        VStack(spacing: 0) {
                            Image(systemName: w.symbol)
                                .font(.system(size: 11 * k, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                            Text(degrees(w.temperature))
                                .font(rounded(20 * k, .semibold))
                                .monospacedDigit()
                        }
                        .offset(y: 2 * k)
                    }
                } caption: {
                    HStack(spacing: 0) {
                        Text(degrees(w.low))
                        Spacer(minLength: 4 * k)
                        Text(degrees(w.high))
                    }
                    .font(rounded(11 * k, .medium))
                    .frame(width: 64 * k)
                }
            } else {
                WideTile(symbol: w.symbol,
                         headline: "\(degrees(w.temperature)) \(w.condition)",
                         detail: [settings.config.showLocationName ? w.locationName : nil,
                                  "H:\(degrees(w.high)) L:\(degrees(w.low))"].compactMap { $0 }.joined(separator: " · "))
            }
        } else if size == .compact {
            // "No weather" only after a fetch actually failed (offline, no location), not while loading.
            EmptyRound(symbol: "cloud.sun", caption: store.weatherStatus == nil || store.isFetchingWeather ? "Weather" : "No weather")
                .help(store.weatherStatus ?? "")
        } else {
            WideTile(symbol: "cloud.sun", headline: "Weather", detail: store.weatherStatus ?? "Loading…")
        }
    }

    private func arcColors(_ w: WeatherSnapshot) -> [Color] {
        switch settings.config.gaugeTint {
        case .monochrome: return [theme.glyph.opacity(0.9)]
        case .accent: return [theme.accent.opacity(0.6), theme.accent]
        case .status:
            let toC: (Double) -> Double = { w.unit == .celsius ? $0 : ($0 - 32) * 5 / 9 }
            let lo = toC(w.low), hi = toC(max(w.high, w.low + 0.1))
            return (0...5).map { temperatureColor(celsius: lo + (hi - lo) * Double($0) / 5) }
        }
    }
}

struct AirQualityWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        if let aqi = store.weather?.airQuality {
            let level = AirQualityLevel(aqi: aqi)
            let levelColor = Color(red: level.rgb.0, green: level.rgb.1, blue: level.rgb.2)
            let tint: Color = {
                switch settings.config.gaugeTint {
                case .status: return levelColor
                case .accent: return theme.accent
                case .monochrome: return theme.glyph.opacity(0.9)
                }
            }()
            if size == .compact {
                RoundTile {
                    ArcGauge(fraction: Double(aqi) / 300, colors: [tint]) {
                        VStack(spacing: -1 * k) {
                            Text("AQI").font(rounded(9 * k, .bold)).opacity(0.75)
                            Text("\(aqi)").font(rounded(20 * k, .semibold)).monospacedDigit()
                        }
                        .offset(y: 2 * k)
                    }
                } caption: {
                    Text(level.title)
                }
            } else {
                WideTile(symbol: "aqi.medium", headline: "AQI \(aqi)", detail: level.title,
                         symbolTint: settings.config.gaugeTint == .status ? levelColor : nil)
            }
        } else if size == .compact {
            EmptyRound(symbol: "aqi.medium", caption: "AQI")
        } else {
            WideTile(symbol: "aqi.medium", headline: "AQI —", detail: "Waiting for data")
        }
    }
}

struct ForecastWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var store: WidgetStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        if size == .compact, settings.config.allGauges {
            forecastGauge
        } else {
            forecastStrip
        }
    }

    /// Tomorrow as a gauge: where tomorrow's high sits in the week's range.
    @ViewBuilder private var forecastGauge: some View {
        if let w = store.weather, w.daily.count > 1 {
            let days = Array(w.daily.prefix(7))
            let tomorrow = days[1]
            let lo = days.map(\.low).min() ?? tomorrow.low, hi = days.map(\.high).max() ?? tomorrow.high
            RoundTile {
                ArcGauge(fraction: temperatureFraction(current: tomorrow.high, low: lo, high: hi),
                         colors: [theme.accent.opacity(0.6), theme.accent]) {
                    VStack(spacing: 0) {
                        Image(systemName: WeatherCode.symbol(tomorrow.code, isDay: true))
                            .font(.system(size: 11 * k, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                        Text(degrees(tomorrow.high)).font(rounded(20 * k, .semibold)).monospacedDigit()
                    }
                    .offset(y: 2 * k)
                }
            } caption: {
                Text("Tomorrow")
            }
        } else {
            EmptyRound(symbol: "calendar", caption: "Forecast")
        }
    }

    private var forecastStrip: some View {
        WidgetContainer {
            if let w = store.weather {
                HStack(spacing: 16 * k) {
                    ForEach(Array(w.daily.prefix(size == .compact ? 3 : 5).enumerated()), id: \.element.id) { index, day in
                        VStack(spacing: 4 * k) {
                            Text(index == 0 ? "Today" : TimeFormat.weekday(day.date))
                                .font(rounded(11 * k, .semibold))
                                .foregroundStyle(theme.secondary)
                            ThemedSymbol(name: WeatherCode.symbol(day.code, isDay: true), size: 18 * k)
                                .frame(height: 24 * k)
                            Text(degrees(day.high)).font(rounded(14 * k, .semibold)).foregroundStyle(theme.glyph)
                            Text(degrees(day.low)).font(rounded(12 * k, .medium)).foregroundStyle(theme.secondary)
                        }
                        .frame(minWidth: 34 * k)
                    }
                }
            } else {
                // Offline / failed fetch: say so instead of "loading" forever (retries every 2 min).
                Label(store.isFetchingWeather || store.weatherStatus == nil ? "Forecast loading…" : "No forecast",
                      systemImage: "calendar")
                    .font(rounded(13 * k, .medium))
                    .foregroundStyle(theme.secondary)
            }
        }
    }
}

// MARK: - Batteries

struct MacBatteryWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        if let b = store.mac {
            let tint = batteryTint(level: b.level, charging: b.isCharging, settings: settings, theme: theme)
            // On hold shows the same plug glyph as the island's "On Hold" pop-up.
            let symbol = b.chargeState == .onHold ? "powerplug.fill" : BatteryLook.symbol(for: b.level, charging: b.isCharging)
            if size == .compact {
                RoundTile {
                    RingGauge(fraction: Double(b.level) / 100, tint: tint) {
                        Image(systemName: symbol)
                            .font(.system(size: (b.isCharging ? 22 : 20) * k, weight: .semibold))
                    }
                } caption: {
                    Text(settings.config.showPercentText ? "\(b.level)%" : "Mac")
                }
            } else {
                WideTile(symbol: symbol, headline: "\(b.level)%", detail: status(b),
                         symbolTint: settings.config.gaugeTint == .monochrome ? nil : tint)
            }
        } else if size == .compact {
            EmptyRound(symbol: "powerplug.fill", caption: "No battery")
        } else {
            WideTile(symbol: "powerplug.fill", headline: "Mac", detail: "No battery")
        }
    }

    private func status(_ b: MacBatteryInfo) -> String {
        let time: String? = settings.config.showTimeRemaining
            ? b.minutesRemaining.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
            : nil
        // Follow chargeState, like the island: plugged in and not charging *yet* (no reason from
        // macOS, charger still negotiating) is "Charging", not "Charging on hold".
        switch b.chargeState {
        case .charging: return b.isCharging ? (time.map { "Charging · \($0) to full" } ?? "Charging") : "Charging"
        case .charged: return "Fully charged"
        case .onHold: return "Charging on hold"
        case .onBattery: return time.map { "On battery · \($0) left" } ?? "On battery"
        }
    }
}

struct PeripheralsWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        let devices = store.visiblePeripherals(hidden: settings.config.hiddenDevices)
        if devices.isEmpty {
            // Nothing on screen when no device is connected (except in previews).
            if isPreview {
                if size == .compact {
                    EmptyRound(symbol: "headphones", caption: "No devices")
                } else {
                    WideTile(symbol: "headphones", headline: "Devices", detail: "Nothing connected")
                }
            }
        } else if size == .compact {
            HStack(spacing: CGFloat(settings.config.spacing) * k) {
                ForEach(devices) { d in
                    RoundTile {
                        RingGauge(fraction: Double(d.level) / 100,
                                  tint: batteryTint(level: d.level, charging: d.isCharging, settings: settings, theme: theme)) {
                            Image(systemName: SFSymbol.symbol(for: d)).font(.system(size: 22 * k, weight: .semibold))
                        }
                    } caption: {
                        Text(settings.config.showPercentText ? "\(d.level)%" : d.component ?? d.name)
                    }
                    .help(d.displayName)
                }
            }
        } else {
            WidgetContainer {
                VStack(alignment: .leading, spacing: 9 * k) {
                    ForEach(devices) { d in
                        let tint = batteryTint(level: d.level, charging: d.isCharging, settings: settings, theme: theme)
                        HStack(spacing: 10 * k) {
                            Image(systemName: SFSymbol.symbol(for: d))
                                .font(.system(size: 15 * k, weight: .semibold))
                                .frame(width: 22 * k)
                            Text(d.displayName).font(rounded(13 * k, .medium)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 10 * k)
                            Capsule().fill(theme.track).frame(width: 60 * k, height: 6 * k)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(tint).frame(width: max(6 * k, 60 * k * CGFloat(d.level) / 100), height: 6 * k)
                                }
                            Text("\(d.level)%").font(rounded(13 * k, .semibold)).monospacedDigit()
                                .frame(width: 40 * k, alignment: .trailing)
                        }
                        .foregroundStyle(theme.glyph)
                    }
                }
                .frame(width: 280 * k)
            }
        }
    }
}

// MARK: - Lock-screen player (below the widgets)

/// Glass media player for whatever is playing system-wide (Spotify, Music, YouTube Music in a
/// browser, Podcasts…). Its buttons work on the lock screen.
struct LockPlayerCard: View {
    @ObservedObject private var media = MediaController.shared
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme
    @Environment(\.isWidgetPreview) private var isPreview

    var body: some View {
        if let info = media.info {
            card(info)
        } else if isPreview {
            card(NowPlayingInfo(title: "Nothing playing", artist: "Play something in any app", album: "",
                                isPlaying: false, duration: 0, elapsed: 0, elapsedDate: Date(), rate: 1,
                                bundleIdentifier: nil, appName: nil))
                .opacity(0.7)
        }
    }

    private func card(_ info: NowPlayingInfo) -> some View {
        let accent = theme.lightGlyphs ? media.artworkColor : theme.glyph
        let shape = RoundedRectangle(cornerRadius: 26 * k, style: .continuous)
        return VStack(spacing: 12 * k) {
            HStack(spacing: 12 * k) {
                artwork
                VStack(alignment: .leading, spacing: 2 * k) {
                    Text(info.displayTitle).font(rounded(16 * k, .semibold)).foregroundStyle(theme.glyph)
                    Text(info.artist).font(rounded(13 * k, .medium)).foregroundStyle(theme.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8 * k)
                if let icon = info.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 22 * k, height: 22 * k).opacity(0.9)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let position = info.currentPosition(at: ctx.date)
                VStack(spacing: 4 * k) {
                    GeometryReader { geo in
                        Capsule().fill(theme.glyph.opacity(0.2))
                            .overlay(alignment: .leading) {
                                Capsule().fill(accent)
                                    .frame(width: info.duration > 0 ? geo.size.width * CGFloat(position / info.duration) : 0)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { location in
                                guard info.duration > 0, geo.size.width > 0 else { return }
                                media.seek(to: info.duration * Double(location.x / geo.size.width))
                            }
                    }
                    .frame(height: 5 * k)
                    HStack {
                        Text(clock(position))
                        Spacer()
                        Text(info.duration > 0 ? "-" + clock(max(0, info.duration - position)) : "Live")
                    }
                    .font(rounded(10 * k, .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondary)
                }
            }
            HStack(spacing: 40 * k) {
                control("backward.fill", 20) { media.previous() }
                control(info.isPlaying ? "pause.fill" : "play.fill", 28) { media.playPause() }
                control("forward.fill", 20) { media.next() }
            }
        }
        .padding(16 * k)
        .frame(width: 340 * k)
        .background(GlassBackground(shape: shape))
    }

    private var artwork: some View {
        FlippingArtwork(size: 56 * k, radius: 12 * k)
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * k, weight: .semibold))
                .foregroundStyle(theme.glyph)
                .frame(width: 44 * k, height: 36 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The music player as its own movable piece on the lock screen.
struct LockPlayerSection: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var media = MediaController.shared
    @Environment(\.isWidgetPreview) private var isPreview
    var screenKey: String? = nil

    var body: some View {
        if settings.config.lockScreenPlayer, media.info != nil || isPreview {
            LockPlayerCard()
                .environment(\.uiScale, settings.lockScale)
                .environment(\.widgetTheme, WidgetTheme.resolve(settings: settings, store: WidgetStore.shared, screenKey: screenKey))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(12)
        }
    }
}

/// Places the widgets at their placement and the player either at its own placement or, when it
/// has none, centred just under the widgets.
struct LockLayout: Layout {
    var widgets: ScreenPlacement
    var player: ScreenPlacement?
    var gap: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let strip = subviews.first else { return }
        let stripSize = strip.sizeThatFits(.unspecified)
        let o = widgets.origin(for: stripSize, in: bounds.size)
        strip.place(at: CGPoint(x: bounds.minX + o.x, y: bounds.minY + o.y), anchor: .topLeading, proposal: ProposedViewSize(stripSize))
        guard subviews.count > 1 else { return }
        let card = subviews[1]
        let cardSize = card.sizeThatFits(.unspecified)
        var p: CGPoint
        if let player {
            p = player.origin(for: cardSize, in: bounds.size)
        } else {
            p = CGPoint(x: o.x + stripSize.width / 2 - cardSize.width / 2, y: o.y + stripSize.height + gap)
            p.x = min(max(0, p.x), max(0, bounds.width - cardSize.width))
            p.y = min(max(0, p.y), max(0, bounds.height - cardSize.height))
        }
        card.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), anchor: .topLeading, proposal: ProposedViewSize(cardSize))
    }
}

// MARK: - Calendar

struct CalendarWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @Environment(\.uiScale) private var k
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let event = store.nextEvent
            if size == .compact {
                RoundTile {
                    RingGauge(fraction: eventFraction(event, now: context.date),
                              tint: event?.colorHex.flatMap(Color.init(hex:)) ?? theme.accent) {
                        VStack(spacing: -2 * k) {
                            Text(TimeFormat.weekday(context.date).uppercased())
                                .font(rounded(10 * k, .bold))
                                .foregroundStyle(theme.accent)
                            Text(TimeFormat.day(context.date))
                                .font(rounded(22 * k, .semibold))
                        }
                    }
                } caption: {
                    Text(event.map { $0.isHappeningNow ? "Now" : TimeFormat.time($0.start, h24: settings.config.use24Hour) }
                         ?? (store.calendarStatus == nil ? "Free" : "No access"))
                }
            } else {
                WidgetContainer {
                    HStack(spacing: 10 * k) {
                        RoundedRectangle(cornerRadius: 2 * k)
                            .fill(event?.colorHex.flatMap(Color.init(hex:)) ?? theme.accent)
                            .frame(width: 4 * k, height: 36 * k)
                        VStack(alignment: .leading, spacing: 2 * k) {
                            Text(event?.title ?? (store.calendarStatus ?? "No more events today"))
                                .font(rounded(16 * k, .semibold))
                                .foregroundStyle(theme.glyph)
                                .lineLimit(1)
                            Text(detail(event))
                                .font(rounded(12 * k, .medium))
                                .foregroundStyle(theme.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 280 * k, alignment: .leading)
                }
            }
        }
    }

    /// Full during an event; otherwise fills over the hour before it starts.
    private func eventFraction(_ event: NextEvent?, now: Date) -> Double {
        guard let event else { return 0 }
        if event.isHappeningNow { return 1 }
        let minutes = event.start.timeIntervalSince(now) / 60
        return max(0.02, min(1, 1 - minutes / 60))
    }

    private func detail(_ event: NextEvent?) -> String {
        guard let event else { return TimeFormat.date(Date(), long: true) }
        let h24 = settings.config.use24Hour
        if event.isHappeningNow { return "Now · until \(TimeFormat.time(event.end, h24: h24))" }
        return "\(TimeFormat.time(event.start, h24: h24)) – \(TimeFormat.time(event.end, h24: h24))"
    }
}

// MARK: - Full-screen views

struct WallpaperBackground: View {
    let image: NSImage?
    let size: CGSize
    var blur: CGFloat = 0

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .scaleEffect(blur > 0 ? 1.08 : 1)
                .blur(radius: blur)
                .clipped()
        } else {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.13, blue: 0.30), Color(red: 0.42, green: 0.22, blue: 0.45)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: size.width, height: size.height)
        }
    }
}

/// Stand-in for the macOS lock screen's own clock and login button, used in previews.
struct FakeSystemLockScreen: View {
    let size: CGSize
    var dimmed = true
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let h = size.height
        let now = Date()
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Text(TimeFormat.date(now, long: true))
                    .font(rounded(h * 0.026, .semibold))
                Text(TimeFormat.time(now, h24: settings.config.use24Hour))
                    .font(.system(size: h * 0.13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.top, h * 0.07)

            VStack(spacing: h * 0.012) {
                Circle().fill(.white.opacity(0.35)).frame(width: h * 0.06, height: h * 0.06)
                    .overlay(Image(systemName: "person.fill").font(.system(size: h * 0.03)).foregroundStyle(.white))
                Capsule().fill(.white.opacity(0.25)).frame(width: h * 0.16, height: h * 0.028)
            }
            .padding(.top, h * 0.80)
        }
        .frame(width: size.width, height: size.height)
        .opacity(dimmed ? 0.45 : 0.95)
        .allowsHitTesting(false)
    }
}

/// Fallback: what gets drawn into the wallpaper so the widgets show on the lock screen
/// when the lock-screen layer isn't available.
struct BakedWallpaperView: View {
    let background: NSImage?
    let size: CGSize
    let screenKey: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            WallpaperBackground(image: background, size: size)
            PlacedStrip(screenKey: screenKey)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.bakedRendering, true)
    }
}

/// Wraps NSGlassEffectView (macOS 26+): real Liquid Glass drawn by the window server.
@available(macOS 26.0, *)
struct NativeGlass: NSViewRepresentable {
    var cornerRadius: CGFloat
    var style: NSGlassEffectView.Style
    var tint: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.contentView = NSView()
        update(view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) { update(view) }

    private func update(_ view: NSGlassEffectView) {
        if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
        if view.style != style { view.style = style }
        view.tintColor = tint
    }
}
