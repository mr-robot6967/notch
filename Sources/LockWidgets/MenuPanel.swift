import AppKit
import SwiftUI
import LockWidgetsCore

// MARK: - Model

/// The tabs along the top of the menu-bar panel.
enum MenuPanelTab: String, CaseIterable, Identifiable {
    case nowPlaying, island, shelf, lockScreen, devices, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .island: return "Island"
        case .shelf: return "Shelf"
        case .lockScreen: return "Lock Screen"
        case .devices: return "Battery & Devices"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .island: return "capsule"
        case .shelf: return "tray"
        case .lockScreen: return "lock"
        case .devices: return "battery.75percent"
        case .about: return "info.circle"
        }
    }

    /// The Settings page (SettingsPage raw value) the section's gear opens.
    var settingsPage: String {
        switch self {
        case .nowPlaying: return "nowPlaying"
        case .island, .shelf: return "notch"
        case .lockScreen: return "lockScreen"
        case .devices: return "batteries"
        case .about: return "general"
        }
    }
}

@MainActor
final class MenuPanelModel: ObservableObject {
    static let shared = MenuPanelModel()
    private static let tabKey = "menuPanelSelectedTab"

    @Published var tab: MenuPanelTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }

    /// Set by the controller: closes the panel (used before opening windows).
    var dismiss: () -> Void = {}

    private init() {
        tab = UserDefaults.standard.string(forKey: Self.tabKey).flatMap(MenuPanelTab.init(rawValue:)) ?? .nowPlaying
    }
}

// MARK: - Controller

/// A popover-style panel under the status item. Closes on an outside click, Esc, or a second
/// click on the status item.
@MainActor
final class MenuPanelController: NSObject {
    static let width: CGFloat = 380
    private static let cornerRadius: CGFloat = 18

    private let panel: MenuPanelWindow
    private let host: NSHostingController<MenuPanelView>
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private var anchorTop: CGFloat = 0
    private var anchorX: CGFloat = 0
    private var height: CGFloat = 420

    var isShown: Bool { panel.isVisible }

    override init() {
        panel = MenuPanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        host = NSHostingController(rootView: MenuPanelView(onSize: { size in
            MainActor.assumeIsolated { AppDelegate.shared?.menuPanel?.contentSizeChanged(size) }
        }))
        super.init()
        host.sizingOptions = []

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.close() }

        let content = host.view
        content.autoresizingMask = [.width, .height]
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.contentView = content
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
            content.frame = effect.bounds
            effect.addSubview(content)
            background = effect
        }
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        MenuPanelModel.shared.dismiss = { [weak self] in self?.close() }
    }

    func toggle(from button: NSStatusBarButton) {
        if isShown { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        self.button = button
        guard let buttonWindow = button.window else { return }
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? rect
        anchorTop = rect.minY - 6
        anchorX = min(max(rect.midX - Self.width / 2, visible.minX + 8), visible.maxX - Self.width - 8)

        let fitted = host.sizeThatFits(in: NSSize(width: Self.width, height: 10_000)).height
        if fitted > 1 { height = ceil(fitted) }
        applyFrame()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        installMonitors()
    }

    func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.monitors.isEmpty else { return } // reopened meanwhile
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    fileprivate func contentSizeChanged(_ size: CGSize) {
        let h = ceil(size.height)
        guard h > 1, abs(h - height) > 0.5 else { return }
        height = h
        if panel.isVisible { applyFrame() }
    }

    private func applyFrame() {
        panel.setFrame(NSRect(x: anchorX, y: anchorTop - height, width: Self.width, height: height), display: true)
        panel.invalidateShadow()
    }

    private func installMonitors() {
        removeMonitors()
        let outside: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: outside, handler: { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.menuPanel?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: outside.union([.leftMouseUp, .keyDown]), handler: { event in
            // Local monitors run on the main thread; the event never leaves it.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { AppDelegate.shared?.menuPanel?.handleLocal(event) ?? false }
            return consumed ? nil : event
        }) { monitors.append(local) }
    }

    /// True when the event is consumed (Esc).
    private func handleLocal(_ event: NSEvent) -> Bool {
        let onButton = event.window != nil && event.window === button?.window
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 && event.window === panel { close(); return true } // Esc
        case .leftMouseUp:
            // The status button un-highlights on mouse up; keep it lit while the panel is open.
            if onButton { DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { if self?.isShown == true { self?.button?.highlight(true) } }
            } }
        default:
            // Clicks on the status button itself are handled by its action (toggle).
            if event.window !== panel && !onButton { close() }
        }
        return false
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class MenuPanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Root view

private struct MenuPanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct MenuPanelView: View {
    var onSize: @Sendable (CGSize) -> Void
    @ObservedObject private var model = MenuPanelModel.shared
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 14) {
            header
            tabBar
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle
                content
            }
            footer
        }
        .padding(16)
        .frame(width: MenuPanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geo in
            Color.clear.preference(key: MenuPanelSizeKey.self, value: geo.size)
        })
        .onPreferenceChange(MenuPanelSizeKey.self) { size in onSize(size) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .font(.system(size: 13))
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            Text("Notch").font(.system(size: 13, weight: .semibold))
            Text("Version \(updater.currentVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(MenuPanelTab.allCases) { tab in
                let selected = model.tab == tab
                Button { model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.accentColor : Color.clear))
                        .overlay(alignment: .topTrailing) {
                            if tab == .about && updater.updateAvailable {
                                Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: -10, y: 5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    private var sectionTitle: some View {
        HStack {
            Text(model.tab.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                let page = model.tab.settingsPage
                model.dismiss()
                AppActions.shared.openSettingsPage(page)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(model.tab.title) Settings")
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .nowPlaying: NowPlayingSection()
        case .island: IslandSection()
        case .shelf: ShelfSection()
        case .lockScreen: LockScreenSection()
        case .devices: DevicesSection()
        case .about: AboutSection()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.dismiss()
                AppActions.shared.openSettings()
            } label: { Label("Settings", systemImage: "gearshape") }
            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
        }
        .buttonStyle(FooterButtonStyle())
    }
}

// MARK: - Sections

private struct NowPlayingSection: View {
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        if let info = media.info {
            PanelCard {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        artwork
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title.isEmpty ? "Unknown title" : info.title)
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if !info.artist.isEmpty {
                                Text(info.artist).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let app = info.appName, !app.isEmpty {
                                Text(app).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 28) {
                        control("backward.fill", size: 15, label: "Previous") { media.previous() }
                        control(info.isPlaying ? "pause.fill" : "play.fill", size: 20,
                                label: info.isPlaying ? "Pause" : "Play") { media.playPause() }
                        control("forward.fill", size: 15, label: "Next") { media.next() }
                    }
                }
                .padding(12)
            }
            PanelCard {
                PanelRow(symbol: "capsule", title: "Show in Island", chevron: true) {
                    MenuPanelModel.shared.dismiss()
                    AppDelegate.shared?.notch?.expand(on: .nowPlaying)
                }
            }
        } else {
            PanelCard {
                VStack(spacing: 6) {
                    Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(.secondary)
                    Text("Nothing playing").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        }
    }

    private var artwork: some View {
        Group {
            if let art = media.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFadeStyle())
        .accessibilityLabel(label)
    }
}

private struct IslandSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        PanelCard {
            PanelToggleRow(symbol: "capsule", title: "Show island", isOn: $settings.config.notchEnabled)
            PanelDivider()
            HStack(spacing: 10) {
                PanelIcon(symbol: "cursorarrow.rays")
                Text("Expand on")
                Spacer()
                Picker("Expand on", selection: $settings.config.notchExpandMode) {
                    ForEach(NotchExpandMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            .rowPadding()
            PanelDivider()
            PanelToggleRow(symbol: "arrow.up.left.and.arrow.down.right", title: "Hide in fullscreen apps",
                           isOn: $settings.config.notchHideInFullscreen)
            PanelDivider()
            PanelToggleRow(symbol: "hand.draw", title: "Swipe to skip tracks", isOn: $settings.config.swipeToSkip)
        }
        if settings.config.notchEnabled && settings.config.notchExpandMode != .never {
            PanelCard {
                PanelRow(symbol: "rectangle.expand.vertical", title: "Open island", chevron: true) {
                    MenuPanelModel.shared.dismiss()
                    AppDelegate.shared?.notch?.expand()
                }
            }
        }
    }
}

private struct ShelfSection: View {
    @ObservedObject private var shelf = ShelfModel.shared

    var body: some View {
        PanelCard {
            HStack(spacing: 10) {
                PanelIcon(symbol: "tray")
                VStack(alignment: .leading, spacing: 1) {
                    Text(shelf.items.isEmpty ? "Shelf is empty"
                         : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") on the shelf")
                    if shelf.items.isEmpty {
                        Text("Drop files on the island to keep them here.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .rowPadding()
            ForEach(Array(shelf.items.suffix(4).reversed()), id: \.self) { url in
                PanelDivider()
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 18, height: 18)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .rowPadding()
            }
        }
        PanelCard {
            if AppSettings.shared.config.notchEnabled {
                PanelRow(symbol: "rectangle.expand.vertical", title: "Open shelf", chevron: true) {
                    MenuPanelModel.shared.dismiss()
                    AppDelegate.shared?.notch?.expand(on: .shelf)
                }
                PanelDivider()
            }
            PanelRow(symbol: "trash", title: "Clear shelf", tint: .red) { shelf.clear() }
                .disabled(shelf.items.isEmpty)
                .opacity(shelf.items.isEmpty ? 0.45 : 1)
        }
    }
}

private struct LockScreenSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        PanelCard {
            PanelToggleRow(symbol: "lock.rectangle", title: "Show widgets on lock screen",
                           isOn: $settings.config.lockScreenWidgets)
            PanelDivider()
            PanelRow(symbol: "eye", title: "Preview on lock screen") {
                MenuPanelModel.shared.dismiss()
                AppActions.shared.previewLockScreen()
            }
            PanelDivider()
            PanelRow(symbol: "arrow.clockwise", title: "Refresh now") {
                AppActions.shared.refreshAll()
                AppActions.shared.rebakeWallpaper()
            }
        }
    }
}

private struct DevicesSection: View {
    @ObservedObject private var store = WidgetStore.shared

    var body: some View {
        PanelCard {
            if let mac = store.mac {
                HStack(spacing: 10) {
                    PanelIcon(symbol: "laptopcomputer")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("This Mac")
                        Text(stateText(mac)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    BatteryValue(level: mac.level, charging: mac.chargeState == .charging)
                }
                .rowPadding()
            } else {
                HStack(spacing: 10) {
                    PanelIcon(symbol: "desktopcomputer")
                    Text("This Mac has no battery").foregroundStyle(.secondary)
                    Spacer()
                }
                .rowPadding()
            }
        }
        PanelCard {
            if store.peripherals.isEmpty {
                HStack(spacing: 10) {
                    PanelIcon(symbol: "dot.radiowaves.left.and.right")
                    Text("No devices reporting battery").foregroundStyle(.secondary)
                    Spacer()
                }
                .rowPadding()
            } else {
                ForEach(Array(store.peripherals.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { PanelDivider() }
                    HStack(spacing: 10) {
                        PanelIcon(symbol: device.kind.symbol)
                        Text(device.displayName).lineLimit(1)
                        Spacer()
                        BatteryValue(level: device.level, charging: device.isCharging)
                    }
                    .rowPadding()
                }
            }
        }
    }

    private func stateText(_ mac: MacBatteryInfo) -> String {
        switch mac.chargeState {
        case .charging: return "Charging"
        case .onHold: return "Plugged in, not charging"
        case .charged: return "Fully charged"
        case .onBattery:
            guard let minutes = mac.minutesRemaining, minutes > 0 else { return "On battery" }
            return "On battery · \(minutes / 60):\(String(format: "%02d", minutes % 60)) left"
        }
    }
}

private struct BatteryValue: View {
    var level: Int
    var charging: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text("\(level)%").monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: BatteryLook.symbol(for: level, charging: charging))
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 22)
        }
    }

    private var color: Color {
        if charging { return .green }
        switch BatteryLook.status(for: level) {
        case .low: return .red
        case .medium: return .orange
        case .good: return .secondary
        }
    }
}

private struct AboutSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if case .available(let version) = updater.state {
            Button {
                Updater.shared.install()
            } label: {
                Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFadeStyle())
        }
        PanelCard {
            HStack(spacing: 10) {
                PanelIcon(symbol: "app.badge")
                Text("Version")
                Spacer()
                Text(updater.currentVersion).foregroundStyle(.secondary)
            }
            .rowPadding()
            PanelDivider()
            HStack(spacing: 10) {
                PanelIcon(symbol: "arrow.triangle.2.circlepath")
                Button("Check for Updates") { Updater.shared.check() }
                    .buttonStyle(.plain)
                    .disabled(busy)
                Spacer()
                status
            }
            .rowPadding()
            PanelDivider()
            PanelRow(symbol: "sparkles", title: "What's New…") {
                MenuPanelModel.shared.dismiss()
                WhatsNewController.shared.show()
            }
            PanelDivider()
            PanelRow(symbol: "chevron.left.forwardslash.chevron.right", title: "GitHub", chevron: true) {
                MenuPanelModel.shared.dismiss()
                if let url = URL(string: "https://github.com/\(Updater.repo)") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var busy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Label("Up to date", systemImage: "checkmark").labelStyle(.titleAndIcon)
            .font(.system(size: 11)).foregroundStyle(.secondary)
        case .available(let version): Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
        case .downloading: Text("Downloading…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .installing: Text("Installing…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let message): Text("Failed").font(.system(size: 11)).foregroundStyle(.red).help(message)
        }
    }
}

// MARK: - Building blocks

private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct PanelIcon: View {
    var symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 18)
    }
}

private struct PanelDivider: View {
    var body: some View { Divider().padding(.leading, 40).opacity(0.6) }
}

private extension View {
    func rowPadding() -> some View { padding(.horizontal, 12).padding(.vertical, 9) }
}

private struct PanelRow: View {
    var symbol: String
    var title: String
    var chevron = false
    var tint: Color? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(tint ?? Color.secondary)
                    .frame(width: 18)
                Text(title).foregroundStyle(tint ?? Color.primary)
                Spacer()
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .rowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }
}

private struct PanelToggleRow: View {
    var symbol: String
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            PanelIcon(symbol: symbol)
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .rowPadding()
    }
}

private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
    }
}

private struct PressFadeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .contentShape(Rectangle())
    }
}
