import ImageIO
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import LockWidgetsCore

/// System-Settings-style window: sidebar on the left, one tidy grouped form per page.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, battery, connectivity, focus, display, sound, timing, nowPlaying, calendar, notch, desktop, lockScreen, widgets, placement, appearance, weather, batteries, integrations
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .battery: return "Battery"
        case .connectivity: return "Connectivity"
        case .focus: return "Focus"
        case .display: return "Display"
        case .sound: return "Sound"
        case .timing: return "Timing"
        case .nowPlaying: return "Now Playing"
        case .calendar: return "Calendar"
        case .notch: return "Island"
        case .desktop: return "Desktop"
        case .lockScreen: return "Lock Screen"
        case .widgets: return "Widgets"
        case .placement: return "Placement"
        case .appearance: return "Appearance"
        case .weather: return "Weather"
        case .batteries: return "Batteries"
        case .integrations: return "Integrations"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .battery: return "bolt.fill"
        case .connectivity: return "headphones"
        case .focus: return "moon.fill"
        case .display: return "sun.max.fill"
        case .sound: return "speaker.wave.2.fill"
        case .timing: return "timer"
        case .nowPlaying: return "play.fill"
        case .calendar: return "calendar"
        case .notch: return "capsule.tophalf.filled"
        case .desktop: return "menubar.dock.rectangle"
        case .lockScreen: return "lock.fill"
        case .widgets: return "square.grid.2x2.fill"
        case .placement: return "rectangle.dashed"
        case .appearance: return "paintbrush.fill"
        case .weather: return "cloud.sun.fill"
        case .batteries: return "battery.75percent"
        case .integrations: return "puzzlepiece.extension.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .battery: return .orange
        case .connectivity: return .green
        case .focus: return .indigo
        case .display: return .purple
        case .sound: return .pink
        case .timing: return .orange
        case .nowPlaying: return .red
        case .calendar: return .red
        case .notch: return .black
        case .desktop: return .teal
        case .lockScreen: return .indigo
        case .widgets: return .blue
        case .placement: return .teal
        case .appearance: return .pink
        case .weather: return .cyan
        case .batteries: return .green
        case .integrations: return .purple
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Startup, sounds and reset."
        case .battery: return "Charging, low battery and Low Power Mode alerts in the island."
        case .connectivity: return "AirPods and Bluetooth devices connecting, with their battery."
        case .focus: return "Show when Focus turns on or off."
        case .display: return "The brightness level in the island."
        case .sound: return "The volume level in the island, replacing the system pop-up."
        case .timing: return "How long everything stays on screen."
        case .nowPlaying: return "Music from any app — controls, song changes and titles."
        case .calendar: return "Upcoming events and the calendar page."
        case .notch: return "How the island opens, its pages, gestures and size."
        case .desktop: return "Optional widgets on your desktop, next to your apps."
        case .lockScreen: return "Widgets and the music player on the real lock screen."
        case .widgets: return "Choose and order the widgets shown on the lock screen."
        case .placement: return "Move the widgets and the player anywhere on the lock screen."
        case .appearance: return "Glass, floating or cards — and colours that match your Mac."
        case .weather: return "Live weather and air quality from your location."
        case .batteries: return "Your Mac, AirPods and other Bluetooth devices."
        case .integrations: return "Notifications, Discord and Spotify."
        }
    }

    static let groups: [(String, [SettingsPage])] = [
        ("", [.general]),
        ("Notifications", [.battery, .connectivity, .focus, .display, .sound]),
        ("Live Activities", [.nowPlaying, .calendar, .notch]),
        ("Desktop", [.desktop]),
        ("Lock Screen", [.lockScreen, .widgets, .placement, .appearance]),
        ("Live Data", [.weather, .batteries]),
        ("Connected", [.integrations]),
    ]
}

final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var page: SettingsPage? = .notch
}

/// The sidebar: a few sections, each with tabs for its pages (keeps the old pages for deep links).
struct SettingsSection: Identifiable {
    let title: String
    let symbol: String
    let color: Color
    let subtitle: String
    let pages: [(SettingsPage, String)]
    var id: String { title }
    var head: SettingsPage { pages[0].0 }

    static let all: [SettingsSection] = [
        .init(title: "General", symbol: "gearshape.fill", color: .gray, subtitle: "Startup, sounds and reset.",
              pages: [(.general, "General")]),
        .init(title: "Island", symbol: "capsule.tophalf.filled", color: .black, subtitle: "How the island opens, its pages and the music player.",
              pages: [(.notch, "Behaviour"), (.nowPlaying, "Now Playing")]),
        .init(title: "Activities", symbol: "bolt.badge.clock.fill", color: .orange, subtitle: "What pops up around the notch, and for how long.",
              pages: [(.battery, "Battery"), (.connectivity, "Devices"), (.focus, "Focus"), (.sound, "Sound"),
                      (.display, "Display"), (.calendar, "Calendar"), (.timing, "Timing")]),
        .init(title: "Notifications & Apps", symbol: "app.badge.fill", color: .red, subtitle: "Notifications, replies, Spotify and Discord.",
              pages: [(.integrations, "Notifications & Apps")]),
        .init(title: "Lock Screen", symbol: "lock.fill", color: .indigo, subtitle: "Widgets and player on the lock screen.",
              pages: [(.lockScreen, "Lock Screen"), (.placement, "Layout")]),
        .init(title: "Widgets", symbol: "square.grid.2x2.fill", color: .blue, subtitle: "Which widgets, their look and their data.",
              pages: [(.widgets, "Widgets"), (.appearance, "Theme"), (.weather, "Weather"), (.batteries, "Batteries")]),
        .init(title: "Desktop", symbol: "menubar.dock.rectangle", color: .teal, subtitle: "Optional widgets on your desktop.",
              pages: [(.desktop, "Desktop")]),
    ]

    static func containing(_ page: SettingsPage) -> SettingsSection {
        all.first { $0.pages.contains { $0.0 == page } } ?? all[0]
    }
}

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(
                get: { SettingsSection.containing(nav.page ?? .notch).id },
                set: { id in
                    if let section = SettingsSection.all.first(where: { $0.id == id }) { nav.page = section.head }
                }
            )) {
                ForEach(SettingsSection.all) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(section.color.gradient))
                        Text(section.title).font(.system(size: 14))
                    }
                    .padding(.vertical, 3)
                    .tag(section.id)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 40)
            .navigationSplitViewColumnWidth(min: 220, ideal: 235, max: 270)
        } detail: {
            let page = nav.page ?? .notch
            let section = SettingsSection.containing(page)
            VStack(spacing: 0) {
                SectionHeader(section: section)
                if section.pages.count > 1 {
                    Picker("", selection: Binding(get: { page }, set: { nav.page = $0 })) {
                        ForEach(section.pages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
                Group {
                switch page {
                case .general: GeneralTab()
                case .desktop: DesktopPage()
                case .battery: BatteryActivityPage()
                case .connectivity: ConnectivityPage()
                case .focus: FocusPage()
                case .display: DisplayPage()
                case .sound: SoundPage()
                case .timing: TimingPage()
                case .nowPlaying: NowPlayingSettingsPage()
                case .calendar: CalendarSettingsPage()
                case .notch: NotchSettingsTab()
                case .lockScreen: LockScreenTab()
                case .widgets: WidgetsTab()
                case .placement: PlacementTab()
                case .appearance: AppearanceTab()
                case .weather: WeatherTab()
                case .batteries: BatteriesTab()
                case .integrations: IntegrationsTab()
                }
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(section.title)
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

private struct SectionHeader: View {
    let section: SettingsSection
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(section.color.gradient))
                .shadow(color: section.color.opacity(0.3), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.title3.weight(.semibold))
                Text(section.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

private struct PageHeader: View {
    let page: SettingsPage
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: page.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(page.color.gradient))
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title).font(.headline)
                Text(page.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(page.color.gradient))
        }
    }
}

extension WidgetKind {
    var explanation: String {
        switch self {
        case .weather: return "Live temperature on a coloured arc, with today's low and high"
        case .airQuality: return "Live US air-quality index, coloured by level"
        case .macBattery: return "This Mac's charge and charging state"
        case .peripherals: return "AirPods, Magic Keyboard/Mouse/Trackpad, other Bluetooth devices"
        case .calendar: return "Your next event from Calendar (asks for access)"
        case .forecast: return "The next days at a glance (best as Wide)"
        }
    }
}

// MARK: - Shared preview

/// Loads downscaled wallpapers in the background (they can be 6K HEICs, and reading one in a
/// protected folder like Downloads waits on a macOS privacy prompt — never on the main thread).
@MainActor
final class WallpaperThumbnails: ObservableObject {
    static let shared = WallpaperThumbnails()
    @Published private var images: [URL: NSImage] = [:]
    private var loading = Set<URL>()
    /// Files that couldn't be read (moved, deleted, unsupported type) — don't keep retrying.
    private var failed = Set<URL>()

    /// Returns the cached image, or nil while it loads (the view refreshes when it arrives).
    func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let cached = images[url] { return cached }
        guard !loading.contains(url), !failed.contains(url) else { return nil }
        loading.insert(url)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.load(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shared = WallpaperThumbnails.shared
                    shared.loading.remove(url)
                    if let image { shared.images[url] = image } else { shared.failed.insert(url) }
                }
            }
        }
        return nil
    }

    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    nonisolated static func load(_ url: URL) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2400]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

final class DragState: ObservableObject {
    enum Target: Equatable { case widgets, player, widget(String) }
    var target: Target?
    var start: ScreenPlacement?
    /// Where the player currently is in the canvas (screen points), for dragging it out of "auto".
    var playerFrame: CGRect = .zero
    @Published var snappedX = false
    @Published var snappedY = false
}

/// The lock screen at real size (main display): wallpaper, macOS's clock and login button, and the
/// widgets + player at their saved places, each draggable. Used scaled in Settings and full-size in
/// the full-screen preview.
struct LockCanvas: View {
    var interactive = true
    var dimSystemUI = true
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @ObservedObject var drag: DragState
    @ObservedObject private var thumbnails = WallpaperThumbnails.shared

    var body: some View {
        let screen = NSScreen.screens.first
        let screenSize = screen?.frame.size ?? CGSize(width: 1470, height: 956)
        let key = screen.map(WallpaperBaker.key(for:))
        let wallpaperURL = screen.flatMap { AppDelegate.shared?.baker?.originalWallpaper(for: $0) ?? NSWorkspace.shared.desktopImageURL(for: $0) }
        let wallpaper = thumbnails.image(for: wallpaperURL)

        ZStack(alignment: .topLeading) {
            WallpaperBackground(image: wallpaper, size: screenSize)
                .onTapGesture(coordinateSpace: .local) { location in
                    guard interactive else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        settings.moveGroup(to: ScreenPlacement(x: location.x / screenSize.width,
                                                               y: location.y / screenSize.height).clamped())
                    }
                }
            FakeSystemLockScreen(size: screenSize, dimmed: dimSystemUI)
            if settings.config.freeLayout {
                freeContent(key: key, screenSize: screenSize)
            } else {
            LockLayout(widgets: settings.config.lockScreenPlacement, player: settings.config.playerPlacement) {
                WidgetStripView(screenKey: key)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .scaleEffect(drag.target == .widgets ? 1.04 : 1)
                    .shadow(color: .black.opacity(drag.target == .widgets ? 0.35 : 0), radius: 20, y: 8)
                    .gesture(interactive ? dragGesture(.widgets, screen: screenSize) : nil)
                LockPlayerSection(screenKey: key)
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { drag.playerFrame = g.frame(in: .named("lockCanvas")) }
                            .onChange(of: g.frame(in: .named("lockCanvas"))) { _, frame in drag.playerFrame = frame }
                    })
                    .contentShape(Rectangle())
                    .scaleEffect(drag.target == .player ? 1.04 : 1)
                    .shadow(color: .black.opacity(drag.target == .player ? 0.35 : 0), radius: 20, y: 8)
                    .gesture(interactive ? dragGesture(.player, screen: screenSize) : nil)
            }
            .frame(width: screenSize.width, height: screenSize.height)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: drag.target)
            }

            if drag.snappedX && drag.target != nil {
                Rectangle().fill(Color.yellow.opacity(0.85)).frame(width: 1.5, height: screenSize.height)
                    .offset(x: screenSize.width / 2).allowsHitTesting(false)
            }
            if drag.snappedY && drag.target != nil {
                Rectangle().fill(Color.yellow.opacity(0.85)).frame(width: screenSize.width, height: 1.5)
                    .offset(y: screenSize.height / 2).allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "lockCanvas")
        .environment(\.isWidgetPreview, true)
        .frame(width: screenSize.width, height: screenSize.height)
    }

    /// Free arrangement: every widget and the player are separate drag targets.
    @ViewBuilder
    private func freeContent(key: String?, screenSize: CGSize) -> some View {
        let entries = settings.config.widgets.filter(\.enabled)
        FreeLayout(placements: entries.map { settings.placement(for: $0.kind) }
                   + [settings.config.playerPlacement ?? settings.defaultFreePlayerPlacement]) {
            ForEach(entries) { entry in
                SingleWidgetView(entry: entry, screenKey: key)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .scaleEffect(drag.target == .widget(entry.kind.rawValue) ? 1.06 : 1)
                    .shadow(color: .black.opacity(drag.target == .widget(entry.kind.rawValue) ? 0.35 : 0), radius: 16, y: 6)
                    .gesture(interactive ? dragGesture(.widget(entry.kind.rawValue), screen: screenSize) : nil)
            }
            LockPlayerSection(screenKey: key)
                .fixedSize()
                .contentShape(Rectangle())
                .scaleEffect(drag.target == .player ? 1.04 : 1)
                .gesture(interactive ? dragGesture(.player, screen: screenSize) : nil)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: drag.target)
    }

    private func dragGesture(_ target: DragState.Target, screen: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("lockCanvas"))
            .onChanged { value in
                guard screen.width > 0, screen.height > 0 else { return }
                if drag.target == nil {
                    drag.target = target
                    switch target {
                    case .widgets:
                        drag.start = settings.config.lockScreenPlacement
                    case .widget(let kind):
                        drag.start = WidgetKind(rawValue: kind).map { settings.placement(for: $0) }
                    case .player:
                        if settings.config.freeLayout {
                            drag.start = settings.config.playerPlacement ?? settings.defaultFreePlayerPlacement
                        } else {
                            let f = drag.playerFrame
                            drag.start = settings.config.playerPlacement
                                ?? ScreenPlacement(x: f.midX / screen.width, y: f.midY / screen.height)
                        }
                    }
                }
                guard drag.target == target, let start = drag.start else { return }
                var p = ScreenPlacement(x: start.x + value.translation.width / screen.width,
                                        y: start.y + value.translation.height / screen.height).clamped()
                drag.snappedX = abs(p.x - 0.5) < 0.012
                drag.snappedY = abs(p.y - 0.5) < 0.012
                if drag.snappedX { p.x = 0.5 }
                if drag.snappedY { p.y = 0.5 }
                switch target {
                case .widgets: settings.config.lockScreenPlacement = p
                case .widget(let kind): settings.config.widgetPlacements[kind] = p
                case .player: settings.config.playerPlacement = p
                }
            }
            .onEnded { _ in
                drag.target = nil
                drag.start = nil
                drag.snappedX = false
                drag.snappedY = false
            }
    }
}

/// Settings preview: the lock canvas scaled to fit, with an "Open full screen" button.
struct PlacementEditor: View {
    var interactive = true
    @StateObject private var drag = DragState()

    var body: some View {
        let screenSize = NSScreen.screens.first?.frame.size ?? CGSize(width: 1470, height: 956)
        GeometryReader { geo in
            let scale = geo.size.width / screenSize.width
            LockCanvas(interactive: interactive, dimSystemUI: true, drag: drag)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: screenSize.height * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator))
                .overlay(alignment: .topTrailing) {
                    if interactive {
                        Button {
                            AppActions.shared.showLockPreview()
                        } label: {
                            Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }
        }
        .aspectRatio(screenSize.width / screenSize.height, contentMode: .fit)
    }
}

/// Full-screen, life-size preview of the lock screen where the widgets and player can be dragged.
@MainActor
final class LockPreviewController {
    static let shared = LockPreviewController()
    private var window: NSWindow?

    func show() {
        guard window == nil, let screen = NSScreen.screens.first else { return }
        let w = PreviewWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.onClose = { LockPreviewController.shared.hide() }
        w.contentView = NSHostingView(rootView: LockPreviewView(onDone: { LockPreviewController.shared.hide() })
            .environmentObject(AppSettings.shared)
            .environmentObject(WidgetStore.shared))
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            w.animator().alphaValue = 1
        }
        window = w
    }

    func hide() {
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }
}

private final class PreviewWindow: NSWindow {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 36 { onClose?() } else { super.keyDown(with: event) } // Esc / Return
    }
}

private struct LockPreviewView: View {
    let onDone: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var drag = DragState()

    var body: some View {
        ZStack(alignment: .bottom) {
            LockCanvas(interactive: true, dimSystemUI: false, drag: drag)
            HStack(spacing: 14) {
                Image(systemName: "hand.draw.fill")
                Text("Drag the widgets and the player to place them on your lock screen")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                if settings.config.playerPlacement != nil {
                    Button("Player under widgets") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { settings.config.playerPlacement = nil }
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("", action: onDone).keyboardShortcut(.cancelAction).frame(width: 0).opacity(0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(.bottom, 26)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Widgets

private struct WidgetsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach($settings.config.widgets) { $entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.kind.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(entry.enabled ? Color.accentColor : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.kind.title)
                            Text(entry.kind.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Picker("Style", selection: $entry.size) {
                            ForEach(WidgetSize.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 130)
                        .disabled(!entry.enabled)
                        Toggle("", isOn: $entry.enabled).labelsHidden().toggleStyle(.switch)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { settings.config.widgets.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Widgets on the lock screen")
            } footer: {
                Text("Round = a gauge, Wide = a line of text. Drag rows to change the order.")
            }

            Section {
                PlacementEditor()
                    .frame(maxHeight: 280)
                Text("Drag to move. The dimmed clock and login button are macOS's own, shown for reference.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Placement

private struct PlacementTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                PlacementEditor()
                Text("Your main display's lock screen with your real wallpaper. Drag the widgets or click where they should go.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Arrangement", selection: $settings.config.freeLayout) {
                    Text("Row — move together").tag(false)
                    Text("Free — move each widget").tag(true)
                }
                .pickerStyle(.segmented)
                if settings.config.freeLayout {
                    Button("Reset widget positions") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            settings.config.widgetPlacements = [:]
                            settings.config.playerPlacement = nil
                        }
                    }
                }
            } header: {
                Text("Arrangement")
            } footer: {
                Text(settings.config.freeLayout
                     ? "Drag each widget and the player wherever you like in the preview (or the full-screen preview)."
                     : "The widgets move as one row; the player follows them unless you drag it.")
            }

            Section("Quick positions") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(ScreenPlacement.presets, id: \.name) { preset in
                        Button(preset.name) { settings.moveGroup(to: preset.placement) }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Player position") {
                    if settings.config.playerPlacement == nil {
                        Text("Automatic — under the widgets").foregroundStyle(.secondary)
                    } else {
                        Button("Put it back under the widgets") { settings.config.playerPlacement = nil }
                    }
                }
            } header: {
                Text("Music player")
            } footer: {
                Text("Drag the player in the preview to place it on its own. Until you do, it follows the widgets.")
            }

            Section("Fine tune") {
                LabeledContent("Horizontal") {
                    Slider(value: settings.groupAxis(\.x), in: 0.02...0.98)
                }
                LabeledContent("Vertical") {
                    Slider(value: settings.groupAxis(\.y), in: 0.02...0.98)
                }
                Toggle("Size automatically for this display", isOn: $settings.config.lockScreenAutoSize)
                if !settings.config.lockScreenAutoSize {
                    LabeledContent("Size") {
                        HStack {
                            Slider(value: $settings.config.lockScreenScale, in: 0.6...2.0, step: 0.05)
                            Text("\(Int(settings.config.lockScreenScale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                LabeledContent("Spacing") {
                    Slider(value: $settings.config.spacing, in: 4...44, step: 1)
                }
            }

            Section {
                Button("Open full-screen preview") { AppActions.shared.showLockPreview() }
                Button("Test on the real lock-screen layer (6 s)") { AppActions.shared.previewLockScreen() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore

    var body: some View {
        Form {
            Section("Style") {
                Picker("Widget style", selection: $settings.config.visualStyle) {
                    ForEach(VisualStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Gauges for every widget", isOn: $settings.config.allGauges)
                LabeledContent("Gauge thickness") {
                    Slider(value: $settings.config.gaugeLineWidth, in: 3...10, step: 0.5)
                }
                if settings.config.visualStyle == .glass {
                    Picker("Glass finish", selection: $settings.config.glassFinish) {
                        Text("Clear").tag("clear"); Text("Liquid").tag("regular"); Text("Tinted").tag("tinted")
                        Text("Dark").tag("dark"); Text("Light").tag("light")
                    }
                    .pickerStyle(.segmented)
                    if ["dark", "light"].contains(settings.config.glassFinish) {
                        LabeledContent("Glass strength") {
                            Slider(value: $settings.config.glassStrength, in: 0...1)
                        }
                    }
                }
                if settings.config.visualStyle == .floating {
                    Picker("Text & icons", selection: $settings.config.glyphTheme) {
                        ForEach(GlyphTheme.allCases) { Text($0.title).tag($0) }
                    }
                } else {
                    Picker("Card", selection: $settings.config.cardStyle) {
                        ForEach(CardStyle.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Corner radius") {
                        Slider(value: $settings.config.cornerRadius, in: 8...36, step: 1)
                    }
                }
            }
            Section("Colour") {
                Picker("Gauge colour", selection: $settings.config.gaugeTint) {
                    ForEach(GaugeTint.allCases) { Text($0.title).tag($0) }
                }
                Picker("Accent", selection: $settings.config.accentSource) {
                    ForEach(AccentSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.config.accentSource == .custom {
                    ColorPicker("Custom accent", selection: Binding(
                        get: { Color(hex: settings.config.accentHex) ?? .blue },
                        set: { settings.config.accentHex = $0.hexString }
                    ), supportsOpacity: false)
                } else {
                    LabeledContent("System accent") {
                        Circle().fill(store.systemAccent).frame(width: 16, height: 16)
                    }
                }
                Text("Text colour adapts to your wallpaper.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Times") {
                Toggle("24-hour times (calendar)", isOn: $settings.config.use24Hour)
            }
            Section("Preview") {
                PlacementEditor(interactive: false)
                    .frame(maxHeight: 280)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Weather

private final class CityDraft: ObservableObject {
    @Published var text = ""
}

private struct WeatherTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore
    @StateObject private var draft = CityDraft()

    var body: some View {
        Form {
            Section("Location") {
                Picker("Use", selection: $settings.config.locationMode) {
                    ForEach(LocationMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.config.locationMode == .city {
                    HStack {
                        TextField("City", text: $draft.text, prompt: Text("e.g. Pune"))
                            .onSubmit { settings.config.city = draft.text }
                        Button("Set") { settings.config.city = draft.text }
                            .disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty || draft.text == settings.config.city)
                    }
                } else {
                    Text("Uses your Mac's Location Services, so the weather follows you. macOS asks for permission the first time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show place name (Wide style)", isOn: $settings.config.showLocationName)
            }
            Section("Units & refresh") {
                Picker("Temperature", selection: $settings.config.unit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                Button("Use system setting (\(Config.systemUnit.symbol))") { settings.config.unit = Config.systemUnit }
                    .disabled(settings.config.unit == Config.systemUnit)
                Picker("Refresh every", selection: $settings.config.weatherRefreshMinutes) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                Text("Weather and air quality also refresh every time you lock the Mac if they're more than 5 minutes old.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Live data") {
                if let w = store.weather {
                    LabeledContent("Now", value: "\(w.locationName): \(Int(w.temperature.rounded()))\(w.unit.symbol), \(w.condition)")
                    LabeledContent("Today", value: "Low \(Int(w.low.rounded()))° · High \(Int(w.high.rounded()))°")
                    if let aqi = w.airQuality {
                        LabeledContent("Air quality", value: "AQI \(aqi), \(AirQualityLevel(aqi: aqi).title)")
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        LabeledContent("Updated", value: w.fetchedAt.formatted(.relative(presentation: .named)))
                    }
                }
                if let status = store.weatherStatus {
                    Text(status).foregroundStyle(.orange)
                }
                Button(store.isFetchingWeather ? "Refreshing…" : "Refresh now") { store.refreshWeather() }
                    .disabled(store.isFetchingWeather)
                Text("Data from Open-Meteo.com (free, no account).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { draft.text = settings.config.city }
    }
}

// MARK: - Batteries

private struct BatteriesTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WidgetStore

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Show percentage under gauges", isOn: $settings.config.showPercentText)
                Toggle("Show Mac time remaining (Wide style)", isOn: $settings.config.showTimeRemaining)
                Toggle("Show both AirPods as one", isOn: $settings.config.combineEarbuds)
                Picker("Red below", selection: $settings.config.lowBatteryThreshold) {
                    ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
            Section("Mac") {
                if let b = store.mac {
                    LabeledContent("Battery", value: "\(b.level)%\(b.isCharging ? " · charging" : b.isPluggedIn ? " · plugged in" : "")")
                } else {
                    Text("This Mac has no battery.").foregroundStyle(.secondary)
                }
            }
            Section("Connected devices") {
                if store.peripherals.isEmpty {
                    Text("No devices are reporting a battery. Connect AirPods, a keyboard, mouse or trackpad.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.peripherals) { device in
                    Toggle(isOn: Binding(
                        get: { !settings.config.hiddenDevices.contains(device.id) },
                        set: { show in
                            settings.config.hiddenDevices.removeAll { $0 == device.id }
                            if !show { settings.config.hiddenDevices.append(device.id) }
                        }
                    )) {
                        Label("\(device.displayName) — \(device.level)%", systemImage: device.kind.symbol)
                    }
                }
                Button("Rescan devices") { store.refreshPeripherals() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Lock Screen

private struct LockScreenTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var overlay: LockScreenOverlay

    var body: some View {
        Form {
            Section {
                Toggle("Show widgets on the lock screen", isOn: $settings.config.lockScreenWidgets)
                Toggle("Show the music player below the widgets", isOn: $settings.config.lockScreenPlayer)
                Toggle("Show on all displays", isOn: $settings.config.allDisplays)
                Button("Preview on the lock-screen layer (6 s)") { AppActions.shared.previewLockScreen() }
                LabeledContent("Status") {
                    if let problem = overlay.lastProblem {
                        Text(problem).foregroundStyle(.orange)
                    } else if overlay.isShowing {
                        Text("Showing now").foregroundStyle(.green)
                    } else {
                        Text("Ready — lock with ⌃⌘Q to see them")
                    }
                }
            } header: {
                Text("Lock screen")
            } footer: {
                Text("Widgets appear when you lock your Mac.")
            }

            Section {
                Toggle("Draw widgets into the wallpaper instead", isOn: $settings.config.wallpaperMode)
                if settings.config.wallpaperMode {
                    Button("Update now") { AppActions.shared.rebakeWallpaper() }
                }
            } header: {
                Text("Fallback")
            } footer: {
                Text("Draws widgets onto your wallpaper instead, if the overlay doesn't show.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private final class LoginItemState: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?
}

private struct GeneralTab: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var login = LoginItemState()

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome & permissions").font(.headline)
                        Text("Replay the welcome, choose features and check permissions.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Welcome") { OnboardingController.shared.show() }
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { login.enabled },
                    set: { wanted in
                        do {
                            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            settings.config.userDisabledLaunchAtLogin = !wanted
                            login.error = nil
                        } catch {
                            login.error = error.localizedDescription
                        }
                        login.enabled = SMAppService.mainApp.status == .enabled
                    }
                ))
                if let message = login.error {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Text("Notch runs in the menu bar and opens at login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sounds") {
                Toggle("Play sounds on lock, unlock and low battery", isOn: $settings.config.lockSounds)
                if settings.config.lockSounds {
                    Picker("Lock sound", selection: $settings.config.lockSoundName) {
                        ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Unlock sound", selection: $settings.config.unlockSoundName) {
                        ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("Custom lock sound") {
                        SoundFileButton(path: $settings.config.customLockSoundPath)
                    }
                    LabeledContent("Custom unlock sound") {
                        SoundFileButton(path: $settings.config.customUnlockSoundPath)
                    }
                    HStack {
                        Button("Play lock") { SystemSounds.play(settings.config.lockSoundName, customPath: settings.config.customLockSoundPath) }
                        Button("Play unlock") { SystemSounds.play(settings.config.unlockSoundName, customPath: settings.config.customUnlockSoundPath) }
                    }
                    Text("Use any sound file on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Reset") {
                Button("Restore default settings", role: .destructive) { settings.resetToDefaults() }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Button("Quit Notch") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notch

@MainActor
private final class TrustState: ObservableObject {
    @Published var trusted = MediaKeyTap.isTrusted
    @Published var tapRunning = MediaKeyTap.shared.isRunning
    func refresh() {
        trusted = MediaKeyTap.isTrusted
        if trusted && AppSettings.shared.config.replaceSystemHUD { MediaKeyTap.shared.start() }
        tapRunning = MediaKeyTap.shared.isRunning
    }
}

private func tryButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
}

private struct NotchSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var media = MediaController.shared
    @StateObject private var trust = TrustState()

    private let activities: [(key: String, title: String, symbol: String)] = [
        ("nowPlaying", "Now playing (album art + waveform)", "music.note"),
        ("unlock", "Unlock", "lock.open.fill"),
        ("volume", "Volume", "speaker.wave.2.fill"),
        ("brightness", "Brightness", "sun.max.fill"),
        ("charging", "Charging / unplugged", "bolt.fill"),
        ("lowBattery", "Low battery", "battery.25percent"),
        ("devices", "AirPods & Bluetooth devices connecting", "airpodspro"),
        ("timer", "Timer", "timer"),
        ("notifications", "Notifications from other apps", "app.badge.fill"),
        ("calendar", "Upcoming calendar event", "calendar"),
        ("focus", "Focus on / off", "moon.fill"),
        ("lowPower", "Low Power Mode on / off", "leaf.fill"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Show the island", isOn: $settings.config.notchEnabled)
                Picker("Open on", selection: $settings.config.notchExpandMode) {
                    ForEach(NotchExpandMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.config.notchExpandMode == .hover {
                    LabeledContent("Hover delay") {
                        Slider(value: $settings.config.hoverDelay, in: 0...0.8, step: 0.05)
                        Text(String(format: "%.2fs", settings.config.hoverDelay)).monospacedDigit().frame(width: 44)
                    }
                }
                Toggle("Haptic feedback", isOn: $settings.config.notchHaptics)
            }

            Section("Pages") {
                ForEach(NotchPage.allCases) { page in
                    Toggle(page.title, isOn: Binding(
                        get: { settings.config.notchPages.contains(page.rawValue) },
                        set: { on in
                            settings.config.notchPages.removeAll { $0 == page.rawValue }
                            if on { settings.config.notchPages.append(page.rawValue) }
                        }
                    ))
                }
            }

            Section("Try it") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    tryButton("Volume", "speaker.wave.2.fill") { NotchModel.shared.flash(.volume(level: 0.62, muted: false), seconds: 2) }
                    tryButton("Brightness", "sun.max.fill") { NotchModel.shared.flash(.brightness(level: 0.45), seconds: 2) }
                    tryButton("Charging", "bolt.fill") { NotchModel.shared.flash(.charging(level: WidgetStore.shared.mac?.level ?? 80, state: WidgetStore.shared.mac?.chargeState ?? .charging)) }
                    tryButton("Song change", "music.note") {
                        let info = MediaController.shared.info
                        NotchModel.shared.flash(.songChange(title: info?.displayTitle ?? "Song title", artist: info?.artist ?? "Artist"), seconds: 3)
                    }
                    tryButton("Notification", "app.badge.fill") {
                        NotchModel.shared.flash(.notification(MirroredNotification(id: -1, bundleID: "com.apple.MobileSMS", appName: "Messages",
                            title: "Notch", subtitle: "", body: "This is how notifications look in the island.", date: Date())), seconds: 4)
                    }
                    tryButton("Device", "airpodspro") { NotchModel.shared.flash(.device(name: "AirPods Pro", symbol: "airpodspro", level: 76), seconds: 3) }
                    tryButton("Unlock", "lock.open.fill") { NotchModel.shared.flash(.unlocked, seconds: 2) }
                    tryButton("Open island", "capsule.tophalf.filled") { AppDelegate.shared?.notch?.expand() }
                }
                .padding(.vertical, 4)
            }

            Section {
                DisclosureGroup("More options") {
                    Picker("When nothing is playing", selection: $settings.config.idleActivity) {
                        Text("Show nothing").tag("none")
                        Text("Show the weather").tag("weather")
                    }
                    Picker("While locked", selection: $settings.config.lockedIndicator) {
                        Text("Nothing").tag("none")
                        Text("Small lock").tag("icon")
                        Text("Soft glow").tag("glow")
                    }
                    Toggle("Unlock animation", isOn: settings.activity("unlock"))
                    Toggle("Timer finished", isOn: settings.activity("timer"))
                    Toggle("Page dots", isOn: $settings.config.notchPageDots)
                    Toggle("Outline on dark wallpapers", isOn: $settings.config.contrastOutline)
                    Toggle("Menu bar icon", isOn: $settings.config.showMenuBarIcon)
                    Toggle("Hide in fullscreen apps", isOn: $settings.config.notchHideInFullscreen)
                    Toggle("Hide in Mission Control", isOn: $settings.config.notchHideInMissionControl)
                    Toggle("Hide from screenshots", isOn: $settings.config.notchHideFromCapture)
                    Toggle("Keep the Mac awake", isOn: $settings.config.keepAwake)
                    Toggle("Hourly chime", isOn: $settings.config.hourlyChime)
                }
                DisclosureGroup("Fit to your notch") {
                    LabeledContent("Width") {
                        Slider(value: $settings.config.notchWidthAdjust, in: -40...40, step: 1)
                        Text("\(Int(settings.config.notchWidthAdjust))").monospacedDigit().frame(width: 32)
                    }
                    LabeledContent("Height") {
                        Slider(value: $settings.config.notchHeightAdjust, in: -10...10, step: 0.5)
                        Text(String(format: "%.1f", settings.config.notchHeightAdjust)).monospacedDigit().frame(width: 32)
                    }
                    Button("Reset to the real notch size") {
                        settings.config.notchWidthAdjust = 0
                        settings.config.notchHeightAdjust = 0
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Integrations

@MainActor
private final class Drafts: ObservableObject {
    @Published var discordID = AppSettings.shared.config.discordClientID
    @Published var spotifyID = AppSettings.shared.config.spotifyClientID
}

private struct IntegrationsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var notifications = NotificationMirror.shared
    @ObservedObject private var discord = DiscordPresence.shared
    @ObservedObject private var spotify = SpotifyClient.shared
    @StateObject private var drafts = Drafts()

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications in the notch", isOn: $settings.config.mirrorNotifications)
                if settings.config.mirrorNotifications {
                    LabeledContent("Status") {
                        if notifications.hasAccess {
                            Text(notifications.running ? "Active" : "Starting…").foregroundStyle(.green)
                        } else {
                            HStack {
                                Text("Needs Full Disk Access").foregroundStyle(.orange)
                                Button("Open System Settings…") { NotificationMirror.openFullDiskAccessSettings() }
                                Button("Check again") { notifications.recheckAccess() }
                            }
                        }
                    }
                    Toggle("Show the message text", isOn: $settings.config.notificationShowBody)
                    Toggle("Play a sound", isOn: $settings.config.notificationSound)
                    LabeledContent("Show for") {
                        Slider(value: $settings.config.notificationSeconds, in: 2...12, step: 1)
                        Text("\(Int(settings.config.notificationSeconds)) s").monospacedDigit().frame(width: 36)
                    }
                    Picker("Look", selection: $settings.config.notificationStyle) {
                        Text("Glass").tag("glass"); Text("Clear").tag("clear"); Text("Tinted").tag("tinted")
                        Text("Dark").tag("dark"); Text("Light").tag("light"); Text("Solid").tag("solid")
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Needs Full Disk Access. Read-only; nothing leaves your Mac.")
            }

            if settings.config.mirrorNotifications {
                Section {
                    Toggle("Reply to Messages from the island", isOn: $settings.config.notificationReply)
                    if settings.config.notificationReply {
                        Picker("Tapping a Messages notification", selection: $settings.config.notificationTapReplies) {
                            Text("Opens the reply here").tag(true)
                            Text("Opens Messages").tag(false)
                        }
                    }
                } header: {
                    Text("Reply")
                } footer: {
                    Text("Only Messages can be replied to. Other apps open when tapped.")
                }

                Section {
                    let apps = Array(Set(settings.config.notificationKnownApps + notifications.recent.map(\.bundleID)
                                         + settings.config.mutedNotificationApps + Array(settings.config.notificationAppModes.keys))).sorted { appName($0) < appName($1) }
                    if apps.isEmpty {
                        Text("Apps show up here after their first notification.").foregroundStyle(.secondary)
                    }
                    ForEach(apps, id: \.self) { id in
                        Picker(selection: Binding(
                            get: { NotificationMirror.mode(for: id, settings.config) },
                            set: { mode in
                                settings.config.mutedNotificationApps.removeAll { $0 == id }
                                settings.config.notificationAppModes[id] = mode
                            }
                        )) {
                            Text("Banner").tag("banner"); Text("List only").tag("quiet"); Text("Off").tag("off")
                        } label: {
                            HStack(spacing: 8) {
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                                }
                                Text(appName(id))
                            }
                        }
                    }
                    Button("Add app…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        panel.allowsMultipleSelection = true
                        guard panel.runModal() == .OK else { return }
                        for url in panel.urls {
                            if let id = Bundle(url: url)?.bundleIdentifier, !settings.config.notificationKnownApps.contains(id) {
                                settings.config.notificationKnownApps.append(id)
                            }
                        }
                    }
                } header: {
                    Text("Apps")
                } footer: {
                    Text("Banner pops up. List only collects quietly. Off hides it.")
                }

            }

            Section {
                Toggle("Show “Listening to …” on Discord", isOn: $settings.config.discordEnabled)
                HStack {
                    TextField("Discord Application ID", text: $drafts.discordID)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        // Write the trimmed ID back too, or Save stays enabled for a pasted trailing space.
                        drafts.discordID = drafts.discordID.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.config.discordClientID = drafts.discordID
                        discord.reconnect()
                    }
                    .disabled(drafts.discordID == settings.config.discordClientID)
                }
                Toggle("Show album art (looks the album up with the iTunes Search API)", isOn: $settings.config.discordShowArt)
                LabeledContent("Status", value: discord.status)
                Button("Open the Discord Developer Portal…") {
                    NSWorkspace.shared.open(URL(string: "https://discord.com/developers/applications")!)
                }
            } header: {
                Text("Discord")
            } footer: {
                Text("1. In the Developer Portal click New Application and name it what you want Discord to show (e.g. “Music”). 2. Copy the Application ID from General Information and paste it here. The Discord app must be running. This only sets your status — it never reads your messages.")
            }

            Section {
                HStack {
                    TextField("Spotify Client ID", text: $drafts.spotifyID)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        drafts.spotifyID = drafts.spotifyID.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.config.spotifyClientID = drafts.spotifyID
                    }
                        .disabled(drafts.spotifyID == settings.config.spotifyClientID)
                }
                LabeledContent("Redirect URI") {
                    HStack {
                        Text(SpotifyClient.redirectURI).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyClient.redirectURI, forType: .string)
                        }
                    }
                }
                HStack {
                    if spotify.connected {
                        Button("Disconnect") { spotify.disconnect() }
                    } else {
                        Button("Connect Spotify…") { spotify.connect() }
                            .disabled(settings.config.spotifyClientID.isEmpty)
                    }
                    Button("Open Spotify Dashboard…") {
                        NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
                    }
                }
                LabeledContent("Status", value: spotify.busyUntil != nil ? "Busy — likes paused for a few minutes" : spotify.status)
                Toggle("Match likes saved from other releases", isOn: $settings.config.spotifyMatchReleases)
            } header: {
                Text("Spotify (optional extras)")
            } footer: {
                Text("Uses your own free Spotify app, so your limits are yours alone: 1. Open Spotify Dashboard and create an app. 2. Add the Redirect URI above and tick Web API. 3. Paste its Client ID here, Save, then Connect. Matching other releases reads your whole Liked Songs list once a day, so leave it off unless you need it.")
            }
        }
        .formStyle(.grouped)
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}

/// Choose / clear a sound file for lock or unlock.
private struct SoundFileButton: View {
    @Binding var path: String
    var body: some View {
        HStack {
            Text(path.isEmpty ? "None" : (path as NSString).lastPathComponent)
                .foregroundStyle(.secondary).lineLimit(1)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
            if !path.isEmpty { Button("Clear") { path = "" } }
        }
    }
}

// MARK: - Activity pages

extension AppSettings {
    /// On/off for one live activity (stored as a "disabled" list).
    func activity(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !self.config.disabledActivities.contains(key) },
            set: { on in
                self.config.disabledActivities.removeAll { $0 == key }
                if !on { self.config.disabledActivities.append(key) }
            }
        )
    }
}

/// "Show for N s" slider for an activity group.
private struct DurationRow: View {
    let group: String
    var range: ClosedRange<Double> = 1...10
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        let binding = settings.duration(group)
        LabeledContent("Show for") {
            HStack {
                Slider(value: binding, in: range, step: 0.5)
                Text(String(format: "%.1f s", binding.wrappedValue)).monospacedDigit().frame(width: 46, alignment: .trailing)
            }
        }
    }
}

private struct BatteryActivityPage: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Charging / unplugged", isOn: settings.activity("charging"))
                Toggle("Low battery warning", isOn: settings.activity("lowBattery"))
                Picker("Warn below", selection: $settings.config.lowBatteryThreshold) {
                    ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                Toggle("Low Power Mode on / off", isOn: $settings.config.lowPowerActivity)
                DurationRow(group: "battery")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectivityPage: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Show when AirPods or Bluetooth devices connect", isOn: settings.activity("devices"))
                DurationRow(group: "devices")
            } footer: {
                Text("Shows the device and its battery.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct FocusPage: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var focus = FocusWatcher.shared
    var body: some View {
        Form {
            Section {
                Toggle("Show Focus turning on and off", isOn: settings.activity("focus"))
                DurationRow(group: "focus", range: 1...6)
            }
            Section {
                Toggle("Hold notifications while a Focus is on", isOn: $settings.config.respectFocus)
                if settings.config.respectFocus {
                    Toggle("Also hold song-change and calendar peeks", isOn: $settings.config.focusHoldsPeeks)
                }
                LabeledContent("Right now") {
                    Text(focus.active ? "\(focus.modeName) is on" : "No Focus").foregroundStyle(focus.active ? .indigo : .secondary)
                }
            } header: {
                Text("Do Not Disturb")
            } footer: {
                Text("Held notifications still appear in the island's list.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Shared status row: replacing the system pop-up needs Accessibility.
private struct HUDReplaceSection: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var trust = TrustState()
    var body: some View {
        Section {
            Toggle("Replace the system pop-up", isOn: $settings.config.replaceSystemHUD)
            if settings.config.replaceSystemHUD {
                LabeledContent("Status") {
                    if trust.trusted {
                        Text(trust.tapRunning ? "Active — the system pop-up is hidden" : "Allowed — starting…").foregroundStyle(.green)
                    } else {
                        HStack {
                            Text("Needs Accessibility — the system pop-up still shows").foregroundStyle(.orange)
                            Button("Open Settings…") {
                                MediaKeyTap.requestTrust()
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            Button("Check again") { trust.refresh() }
                        }
                    }
                }
            }
        } footer: {
            Text("Turn on Notch in Privacy & Security › Accessibility.")
        }
        .onAppear { trust.refresh() }
    }
}

private struct SoundPage: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Show volume in the island", isOn: settings.activity("volume"))
                Toggle("Show percentage", isOn: $settings.config.hudShowsPercent)
                Toggle("Show the output device (AirPods, headphones…)", isOn: $settings.config.hudShowsDevice)
                Picker("Bar style", selection: $settings.config.hudStyle) {
                    Text("Level colour").tag("level"); Text("Gradient").tag("gradient"); Text("Glow").tag("glow")
                    Text("Plain").tag("plain"); Text("Segments").tag("segments")
                }
                .pickerStyle(.segmented)
                Toggle("Use the accent colour", isOn: $settings.config.hudUsesAccent)
                DurationRow(group: "hud", range: 0.5...5)
            }
            HUDReplaceSection()
        }
        .formStyle(.grouped)
    }
}

private struct DisplayPage: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Show brightness in the island", isOn: settings.activity("brightness"))
                Toggle("Show percentage", isOn: $settings.config.hudShowsPercent)
                DurationRow(group: "hud", range: 0.5...5)
            } footer: {
                Text("Bar style, colour and duration are shared with Sound.")
            }
            HUDReplaceSection()
        }
        .formStyle(.grouped)
    }
}

private struct NowPlayingSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var media = MediaController.shared
    var body: some View {
        Form {
            Section {
                Toggle("Show what's playing in the island", isOn: settings.activity("nowPlaying"))
                Picker("Extra button", selection: $settings.config.notchLeftControl) {
                    Text("Like").tag("like"); Text("Shuffle").tag("shuffle"); Text("Repeat").tag("repeat"); Text("None").tag("none")
                }
                Toggle("Quick Peek when the song changes", isOn: $settings.config.songChangePeek)
                if settings.config.songChangePeek { DurationRow(group: "songChange", range: 1...6) }
                Picker("Waveform colour", selection: $settings.config.waveformColor) {
                    Text("Monochrome").tag("monochrome"); Text("Coloured").tag("colored"); Text("Gradient").tag("gradient")
                }
                .pickerStyle(.segmented)
                Toggle("Flip album art when the song changes", isOn: $settings.config.artworkFlip)
                Toggle("Clean up song titles", isOn: $settings.config.cleanSongTitles)
                Toggle("Swipe left/right on the island to skip", isOn: $settings.config.swipeToSkip)
                Toggle("Jiggle the island when skipping", isOn: $settings.config.skipJiggle)
                if settings.config.skipJiggle {
                    LabeledContent("Jiggle strength") {
                        HStack {
                            Slider(value: $settings.config.skipJiggleAmount, in: 6...30, step: 1)
                            Button("Try") { NotchModel.shared.jiggle(1) }
                        }
                    }
                }
                Toggle("Hide while the playing app is in front", isOn: $settings.config.notchHideWhenSourceActive)
                Toggle("Click the song to open the app playing it", isOn: $settings.config.openSourceOnTap)
                Toggle("Show the app's icon on the album art", isOn: $settings.config.showSourceBadge)
            }
            if let hint = YTMusicBridge.shared.needsAppleEvents {
                Section("YouTube Music") {
                    Label(hint, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("This lets Notch press YouTube Music's own Like, Shuffle and Repeat buttons. Only the music.youtube.com tab is touched.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Source") {
                LabeledContent("Reading from") {
                    Text(media.usingHelper ? "Any app (system Now Playing)" : "Music & Spotify only")
                        .foregroundStyle(media.usingHelper ? .green : .orange)
                }
                if let info = media.info {
                    LabeledContent("Playing", value: "\(info.displayTitle) — \(info.artist)")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalendarSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Peek at upcoming events", isOn: $settings.config.calendarPeek)
                if settings.config.calendarPeek {
                    Picker("Show before the event", selection: $settings.config.calendarPeekMinutes) {
                        ForEach([1, 2, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    DurationRow(group: "calendar", range: 2...15)
                }
                Toggle("Calendar page in the open island", isOn: Binding(
                    get: { settings.config.notchPages.contains("calendar") },
                    set: { on in
                        settings.config.notchPages.removeAll { $0 == "calendar" }
                        if on { settings.config.notchPages.append("calendar") }
                    }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

private struct DesktopPage: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Show widgets on the desktop", isOn: $settings.config.desktopWidgetsEnabled)
                if settings.config.desktopWidgetsEnabled {
                    Picker("Layout", selection: $settings.config.desktopLineMode) {
                        Text("Free — move each widget").tag(false)
                        Text("Line — move them together").tag(true)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Button("Arrange in a line") { AppDelegate.shared?.desktopWidgets?.arrangeInLine() }
                            .disabled(settings.config.desktopLineMode)
                        Button("Reset positions") { AppDelegate.shared?.desktopWidgets?.resetPositions() }
                    }
                }
            } footer: {
                Text("Drag widgets anywhere; they stay where you put them.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct TimingPage: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section {
                TimingRow(title: "Charging & battery", group: "battery")
                TimingRow(title: "Devices connecting", group: "devices")
                TimingRow(title: "Focus on / off", group: "focus", range: 1...6)
                TimingRow(title: "Volume & brightness", group: "hud", range: 0.5...5)
                TimingRow(title: "Song change", group: "songChange", range: 1...6)
                TimingRow(title: "Calendar event", group: "calendar", range: 2...15)
                TimingRow(title: "Unlocked", group: "unlock", range: 0.5...5)
                LabeledContent("Notifications") {
                    HStack {
                        Slider(value: $settings.config.notificationSeconds, in: 2...12, step: 0.5)
                        Text(String(format: "%.1f s", settings.config.notificationSeconds)).monospacedDigit().frame(width: 46, alignment: .trailing)
                    }
                }
            } header: {
                Text("Show for")
            }
            Section("Time") {
                Toggle("24-hour time", isOn: $settings.config.use24Hour)
            }
            Section {
                Button("Reset all timings") {
                    settings.config.activityDurations = [:]
                    settings.config.notificationSeconds = 5
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TimingRow: View {
    let title: String
    let group: String
    var range: ClosedRange<Double> = 1...10
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        let binding = settings.duration(group)
        LabeledContent(title) {
            HStack {
                Slider(value: binding, in: range, step: 0.5)
                Text(String(format: "%.1f s", binding.wrappedValue)).monospacedDigit().frame(width: 46, alignment: .trailing)
            }
        }
    }
}
