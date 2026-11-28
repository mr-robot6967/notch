import AppKit
import ApplicationServices
import Combine
import CoreLocation
import EventKit
import SwiftUI

/// First-launch welcome: a greeting animation, then which features to turn on, then the
/// permissions those features need. Shown once (Settings › General › Show Welcome again).
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()
    private var window: NSWindow?
    /// The welcome/setup window is on screen.
    var isShowing: Bool { window != nil }

    static let panelSize = CGSize(width: 440, height: 500)

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        // Same screen and size as the island: the notched display, or (Macs without a notch,
        // external main display) the primary screen with a menu-bar-high pill. NSScreen.main is the
        // screen of the key window, which can be any display, so it isn't used here.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        let g = NotchGeometry.current()
        let notch = CGSize(width: g.width, height: g.height)
        let size = CGSize(width: Self.panelSize.width + 80, height: Self.panelSize.height + 40)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        let w = KeyableWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = OnboardingView(notch: notch) { [weak self] in self?.close() }
            .environmentObject(AppSettings.shared)
        let host = NSHostingView(rootView: view)
        host.safeAreaRegions = []
        w.contentView = host
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called after the island has shrunk back into the notch.
    private func close() {
        AppSettings.shared.config.onboardingDone = true
        window?.orderOut(nil)
        window = nil
    }

}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class OnboardingState: ObservableObject {
    /// 0 = the notch, 1 = swelling, 2 = dripped into a tall pill, 3 = the full panel.
    @Published var phase = 0
    /// Motion-blur amount while the island morphs quickly (0–1).
    @Published var rim: Double = 0
    @Published var contentVisible = false
    /// Fades the island out once it is back at the notch's exact size (invisible over the real notch).
    @Published var islandOpacity: Double = 1
    @Published var step = 0
    /// Set up Spotify likes & devices (adds the Spotify step).
    @Published var wantsSpotify = !AppSettings.shared.config.spotifyClientID.isEmpty
    @Published var spotifyDraft = AppSettings.shared.config.spotifyClientID
    @Published var greeting = 0
    @Published var reveal: CGFloat = 0
    @Published var showWelcome = false
    @Published var accessibility = AXIsProcessTrusted()
    @Published var fullDisk = false
    @Published var location = CLLocationManager().authorizationStatus
    @Published var calendar = EKEventStore.authorizationStatus(for: .event)
    let locationManager = CLLocationManager()
    var timer: Timer?

    @MainActor func refresh() {
        accessibility = AXIsProcessTrusted()
        // Called every second while the welcome is open; re-reading the notification database (and
        // clearing the island's list) each time is only needed until access shows up.
        // (Only when notifications are switched on; otherwise nothing needs that access.)
        if AppSettings.shared.config.mirrorNotifications, !NotificationMirror.shared.hasAccess {
            NotificationMirror.shared.recheckAccess()
        }
        fullDisk = NotificationMirror.shared.hasAccess
        location = locationManager.authorizationStatus
        calendar = EKEventStore.authorizationStatus(for: .event)
    }
}

private struct OnboardingView: View {
    let notch: CGSize
    let onFinish: () -> Void
    @StateObject private var state = OnboardingState()
    @EnvironmentObject private var settings: AppSettings

    private let greetings = ["hello", "bonjour", "hola", "こんにちは", "नमस्ते", "hello"]

    private var islandSize: CGSize {
        let panel = OnboardingController.panelSize
        switch state.phase {
        case 0: return notch
        case 1: return CGSize(width: notch.width - 14, height: notch.height + 22)   // squeeze as it drops
        case 2: return CGSize(width: notch.width + 50, height: 160)                 // a tall droplet
        case 4: return CGSize(width: panel.width * 0.82, height: notch.height + 26)  // closing: retracted into a wide bar
        default: return panel
        }
    }

    private var islandShape: NotchShape {
        switch state.phase {
        case 0: return NotchShape(bottomRadius: notch.height * 0.4, flare: 7)
        case 1: return NotchShape(bottomRadius: (notch.height + 22) * 0.5, flare: 8)
        case 2: return NotchShape(bottomRadius: 70, flare: 14)
        case 4: return NotchShape(bottomRadius: (notch.height + 26) * 0.5, flare: 12)
        default: return NotchShape(bottomRadius: 36, flare: 18)
        }
    }

    var body: some View {
        let panel = OnboardingController.panelSize
        let shape = islandShape
        let size = islandSize
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                .frame(width: size.width, height: size.height)
                .opacity(state.islandOpacity)
                // Brief motion blur while the shape moves fast; soft shadow once it has landed.
                .blur(radius: state.rim * 3)
                .shadow(color: .black.opacity(state.phase == 3 ? 0.45 : 0), radius: 30, y: 14)
            steps
                .frame(width: panel.width, height: panel.height)
                .clipShape(NotchShape(bottomRadius: 36, flare: 18))
                .opacity(state.contentVisible ? 1 : 0)
                .scaleEffect(state.contentVisible ? 1 : 0.86, anchor: .top)
                .offset(y: state.contentVisible ? 0 : -18)
                .blur(radius: state.contentVisible ? 0 : 14)
        }
        .frame(width: panel.width + 80, height: panel.height + 40, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear { enter() }
    }


    /// notch → squeeze and drop → droplet → widen into the panel (springs throughout) → content.
    private func enter() {
        func after(_ t: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work) }
        after(0.2) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { state.phase = 1 }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        after(0.42) {
            withAnimation(.easeIn(duration: 0.12)) { state.rim = 1 }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.68)) { state.phase = 2 }
        }
        after(0.72) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.76)) { state.phase = 3 }
            withAnimation(.easeOut(duration: 0.35).delay(0.1)) { state.rim = 0 }
        }
        after(1.15) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { state.contentVisible = true }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        after(1.45) { runGreeting() }
    }

    /// Close: content fades, the panel retracts upward into a wide bar under the notch (keeping its
    /// width), then narrows into the notch and dissolves into it.
    private func finish() {
        func after(_ t: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work) }
        withAnimation(.easeIn(duration: 0.14)) { state.contentVisible = false }
        after(0.06) { withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { state.phase = 4 } }
        after(0.34) { withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) { state.phase = 0 } }
        after(0.66) { withAnimation(.easeOut(duration: 0.15)) { state.islandOpacity = 0 } }
        after(0.85) { onFinish() }
    }

    private var steps: some View {
        ZStack {
            switch state.step {
            case 0: hello.transition(.opacity.combined(with: .scale(scale: 0.96)))
            case 1: features.transition(.push(from: .trailing))
            case 2: permissions.transition(.push(from: .trailing))
            case 3: spotifyStep.transition(.push(from: .trailing))
            default: done.transition(.push(from: .trailing))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: state.step)
    }

    // MARK: Hello

    private var hello: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 56)
            // Written in left to right; a fixed frame that scales long words down, so nothing clips.
            Text(greetings[state.greeting])
                .font(.custom("SnellRoundhand-Bold", size: 68))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 12)
                .frame(width: 360, height: 120)
                .foregroundStyle(.white)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: 360 * state.reveal)
                }
            VStack(spacing: 6) {
                Text("Welcome to Notch").font(.system(size: 20, weight: .semibold))
                Text("Your notch, lock screen and widgets, together.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 8)
            .opacity(state.showWelcome ? 1 : 0)
            .offset(y: state.showWelcome ? 0 : 8)
            Spacer()
            Button { state.step = 1 } label: { Text("Get Started").frame(width: 200) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                // Invisible buttons still take Return: pressing it mid-greeting skipped ahead and left
                // step 0 blank (no title, hidden button) when coming Back to it.
                .disabled(!state.showWelcome)
                .opacity(state.showWelcome ? 1 : 0)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    private func runGreeting() {
        func show(_ index: Int) {
            guard index < greetings.count, state.step == 0 else { return }
            // Swap the word while hidden, then write it in (no cross-fade, so words never overlap).
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { state.greeting = index; state.reveal = 0 }
            let write = index == 0 || index == greetings.count - 1 ? 0.9 : 0.45
            withAnimation(.easeInOut(duration: write)) { state.reveal = 1 }
            if index == greetings.count - 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + write) { withAnimation(.easeOut(duration: 0.5)) { state.showWelcome = true } }
                return
            }
            let hold = index == 0 ? 1.3 : 0.75
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                withAnimation(.easeIn(duration: 0.15)) { state.reveal = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { show(index + 1) }
            }
        }
        show(0)
    }

    // MARK: Features

    private var features: some View {
        StepLayout(symbol: "sparkles", title: "Choose your features",
                   subtitle: "You can change these any time in Settings.",
                   back: { state.step = 0 }, next: { state.step = 2 }) {
            GroupedList {
                FeatureRow(symbol: "capsule.tophalf.filled", color: Color(white: 0.25), title: "Island",
                           detail: "Music, activities and controls at the notch", isOn: $settings.config.notchEnabled)
                FeatureRow(symbol: "lock.fill", color: .indigo, title: "Lock Screen Widgets",
                           detail: "Weather, air quality, batteries and music", isOn: $settings.config.lockScreenWidgets)
                FeatureRow(symbol: "bell.badge.fill", color: .red, title: "Notifications",
                           detail: "See and reply to messages in the island", isOn: $settings.config.mirrorNotifications)
                FeatureRow(symbol: "speaker.wave.2.fill", color: .pink, title: "Volume & Brightness",
                           detail: "Show levels in the island", isOn: $settings.config.replaceSystemHUD)
                FeatureRow(symbol: "calendar", color: .orange, title: "Calendar",
                           detail: "A heads-up before your next event", isOn: $settings.config.calendarPeek)
                FeatureRow(symbol: "heart.fill", color: .green, title: "Spotify Likes & Devices",
                           detail: "Like songs and switch speakers (free, 2-minute setup)", isOn: $state.wantsSpotify, last: true)
            }
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        let rows = permissionRows(settings.config)
        return StepLayout(symbol: "hand.raised.fill", title: "Permissions",
                          subtitle: "Only what your features need. Nothing leaves your Mac.",
                          back: { state.step = 1 }, next: { state.step = state.wantsSpotify ? 3 : 4 }) {
            if rows.isEmpty {
                Text("Nothing to allow for the features you chose.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 20)
            } else {
                GroupedList {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        PermissionRow(symbol: row.symbol, color: row.color, title: row.title, detail: row.detail,
                                      granted: row.granted, last: index == rows.count - 1, action: row.action)
                    }
                }
            }
        }
        .onAppear {
            state.refresh()
            // onAppear can run again without an onDisappear in between (step transitions); never
            // leave an older 1 s timer running behind the new one.
            state.timer?.invalidate()
            state.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { state.refresh() }
            }
        }
        .onDisappear { state.timer?.invalidate() }
    }

    private struct PermissionItem {
        let symbol: String, color: Color, title: String, detail: String, granted: Bool, action: () -> Void
    }

    private func permissionRows(_ cfg: Config) -> [PermissionItem] {
        var rows: [PermissionItem] = []
        if cfg.replaceSystemHUD {
            rows.append(.init(symbol: "keyboard.fill", color: .gray, title: "Accessibility", detail: "For the volume and brightness keys",
                              granted: state.accessibility) {
                MediaKeyTap.requestTrust()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
        }
        if cfg.mirrorNotifications {
            rows.append(.init(symbol: "externaldrive.fill", color: .blue, title: "Full Disk Access", detail: "To read notifications and Focus",
                              granted: state.fullDisk) { NotificationMirror.openFullDiskAccessSettings() })
        }
        if cfg.lockScreenWidgets {
            rows.append(.init(symbol: "location.fill", color: .blue, title: "Location", detail: "For local weather",
                              granted: state.location == .authorizedAlways || state.location == .authorized) {
                if state.location == .notDetermined { state.locationManager.requestWhenInUseAuthorization() }
                else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
            })
        }
        if cfg.calendarPeek || cfg.widgets.contains(where: { $0.kind == .calendar && $0.enabled }) {
            rows.append(.init(symbol: "calendar", color: .red, title: "Calendars", detail: "For upcoming events",
                              granted: state.calendar == .fullAccess) {
                Task { _ = try? await EKEventStore().requestFullAccessToEvents(); await MainActor.run { state.refresh() } }
            })
        }
        return rows
    }

    // MARK: Spotify

    /// Each person uses their own free Spotify app, so nobody shares (or exhausts) anyone's limits.
    private var spotifyStep: some View {
        StepLayout(symbol: "heart.fill", title: "Connect Spotify",
                   subtitle: "Uses your own free Spotify app, so it never runs into anyone else's limits.",
                   back: { state.step = 2 }, next: {
                       // Keep a typed Client ID even if Connect wasn't pressed.
                       let id = state.spotifyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                       if !id.isEmpty { settings.config.spotifyClientID = id }
                       state.step = 4
                   }) {
            SpotifySetupCard(draft: $state.spotifyDraft)
        }
    }

    // MARK: Done

    private var done: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 56)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .symbolEffect(.bounce, value: state.step)
            Text("You're All Set").font(.system(size: 20, weight: .semibold)).padding(.top, 14)
            Text("Here's how to get around.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 4)
            GroupedList {
                TipRow(symbol: "cursorarrow", title: "Point at the notch to open the island")
                TipRow(symbol: "contextualmenu.and.cursorarrow", title: "Right-click the island for Settings")
                TipRow(symbol: "lock.fill", title: "Lock your Mac to see your widgets", last: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            Spacer()
            Button { finish() } label: { Text("Start Using Notch").frame(width: 200) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 28)
        }
    }
}

/// Centred header, a scrolling body and Back / Continue, laid out like Apple's setup screens.
private struct StepLayout<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let back: () -> Void
    let next: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
                .padding(.top, 52)
            Text(title).font(.system(size: 20, weight: .semibold)).padding(.top, 10)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.top, 4).padding(.horizontal, 40)
            ScrollView(showsIndicators: false) { content.padding(.horizontal, 32).padding(.vertical, 18) }
            HStack(spacing: 10) {
                Button(action: back) { Text("Back").frame(width: 90) }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button(action: next) { Text("Continue").frame(width: 140) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 26)
        }
    }
}

/// One rounded container with hairline dividers between rows (System Settings style).
private struct GroupedList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

private struct RowDivider: View {
    var body: some View { Divider().opacity(0.6).padding(.leading, 52) }
}

private struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
    }
}

private struct FeatureRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { RowDivider() }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let granted: Bool
    var last = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if granted {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Allow", action: action).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: granted)
            if !last { RowDivider() }
        }
    }
}

private struct TipRow: View {
    let symbol: String
    let title: String
    var last = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 28)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if !last { RowDivider() }
        }
    }
}

/// Spotify setup: open the dashboard, add the Redirect URI, paste the Client ID, connect.
private struct SpotifySetupCard: View {
    @Binding var draft: String
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var spotify = SpotifyClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupedList {
                SetupRow(number: 1, title: "Create a free app at the Spotify Dashboard", last: false) {
                    Button("Open") { NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!) }
                        .controlSize(.small)
                }
                SetupRow(number: 2, title: "Add this Redirect URI and tick Web API", last: false) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SpotifyClient.redirectURI, forType: .string)
                    }
                    .controlSize(.small)
                }
                Text(SpotifyClient.redirectURI)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 52).padding(.bottom, 8)
                SetupRow(number: 3, title: "Paste the app's Client ID", last: true) { EmptyView() }
                HStack {
                    TextField("Client ID", text: $draft).textFieldStyle(.roundedBorder).controlSize(.small)
                    Button(spotify.connected ? "Connected" : "Connect") {
                        settings.config.spotifyClientID = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        spotify.connect()
                    }
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || spotify.connected)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Text(spotify.connected ? "Spotify is connected. Likes and devices are ready." : spotify.status)
                .font(.system(size: 11)).foregroundStyle(spotify.connected ? .green : .secondary)
                .padding(.top, 8)
        }
    }
}

private struct SetupRow<Accessory: View>: View {
    let number: Int
    let title: String
    let last: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 22, height: 22).background(Circle().fill(.white))
                    .frame(width: 28)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }
}
