import SwiftUI
import UniformTypeIdentifiers
import LockWidgetsCore

// MARK: - Root

struct NotchRootView: View {
    let controller: NotchController
    @EnvironmentObject private var model: NotchModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var timer = NotchTimer.shared
    @ObservedObject private var store = WidgetStore.shared
    @ObservedObject private var watching = WatchingDetector.shared

    var body: some View {
        let size = controller.islandSize()
        let geometry = controller.geometry
        let content = NotchContent.current(model: model)
        // Music/video that just ended keeps its wings on screen while they retract into the notch.
        let ghost = controller.retractingContent(for: content)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: model.expanded ? 35 * controller.scale : 12 * controller.scale,
                           flare: model.expanded ? 19 * controller.scale : 6 * controller.scale)
                    .fill(Color.black)
                    .overlay(
                        NotchShape(bottomRadius: model.expanded ? 35 * controller.scale : 12 * controller.scale, flare: model.expanded ? 19 * controller.scale : 6 * controller.scale)
                            .stroke(Color.white.opacity(settings.config.contrastOutline ? 0.18 : 0), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(model.expanded ? 0.35 : 0), radius: 12, y: 6)
                if model.expanded {
                    // Laid out at the 37.5 pt-notch size, then scaled to this Mac's notch.
                    ExpandedNotch(notchHeight: geometry.height / controller.scale, notchWidth: geometry.width / controller.scale)
                        .frame(width: size.width / controller.scale, height: size.height / controller.scale)
                        .scaleEffect(controller.scale, anchor: .top)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .transition(.asymmetric(
                            insertion: .modifier(active: SoftAppear(progress: 0, scale: 0.86, blur: 10), identity: SoftAppear(progress: 1, scale: 0.86, blur: 10))
                                .animation(.spring(response: 0.3, dampingFraction: 0.8)),
                            removal: .modifier(active: SoftAppear(progress: 0, scale: 0.95, blur: 8), identity: SoftAppear(progress: 1, scale: 0.95, blur: 8))
                                .animation(.easeIn(duration: 0.06))))
                } else if case .transient(.songChange(let title, let artist)) = content {
                    SongPeek(title: title, artist: artist, notchHeight: geometry.height)
                        .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.08)))
                } else if case .transient(.notification(let note)) = content {
                    NotificationBanner(note: note, notchHeight: geometry.height)
                        .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                } else if let shown = ghost ?? (content != .idle ? content : nil) {
                    // Same view identity while retracting (no removal snap): the wings fade and
                    // shrink toward the notch as the island eases back to the bare notch.
                    CompactActivity(content: shown, notchWidth: geometry.width, height: geometry.height)
                        .opacity(ghost == nil ? 1 : 0)
                        .scaleEffect(ghost == nil ? 1 : 0.6)
                        .id(contentKey(shown))
                        .transition(.asymmetric(
                            // Wait until a collapsing card has shrunk, so the two never overlap.
                            insertion: .modifier(active: SoftAppear(progress: 0, scale: 0.6), identity: SoftAppear(progress: 1, scale: 0.6))
                                .animation(.spring(response: 0.3, dampingFraction: 0.82).delay(controller.justCollapsed ? 0.22 : 0.12)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(NotchShape(bottomRadius: (model.expanded ? 35 : (isPeek(content) ? 28 : 12)) * controller.scale,
                                  flare: (model.expanded ? 19 : (isPeek(content) ? 12 : 6)) * controller.scale))
            .compositingGroup()
            // Skip jiggle: the whole island lurches and stretches a little, then wobbles back.
            .scaleEffect(x: 1 + abs(model.nudge) / 150, y: 1 - abs(model.nudge) / 420, anchor: .top)
            .offset(x: model.nudge)
            .contentShape(NotchShape(bottomRadius: 14))
            .contextMenu { IslandContextMenu(controller: controller) }
            .onTapGesture {
                guard !model.expanded else { return }
                if case .notification(let note) = model.transient {
                    // It's been acted on; don't leave the banner covering the notch for the rest of its time.
                    model.dismissTransient()
                    // Messages: open the reply right here. Other apps: open the app.
                    if !controller.openReply(to: note),
                       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: note.bundleID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                } else if !model.expanded {
                    controller.expand()
                }
            }
            // Any kind of item (files, folders, images, links, text), several per drag.
            .onDrop(of: ShelfModel.acceptedTypes, isTargeted: $model.dropTargeted) { providers in
                // With the File Shelf page turned off the items would be stored on a shelf that
                // can't be seen (or emptied); refuse the drop so it springs back to its source.
                guard settings.config.notchPages.contains(NotchPage.shelf.rawValue) else { return false }
                ShelfModel.shared.accept(providers)
                return true
            }
            Spacer(minLength: 0)
        }
        // Playback ending (pause grace over, player quit, video ended) retracts slowly and softly,
        // whatever transaction (or none) the change arrived in. Appearing keeps its own spring.
        .transaction(value: ghost != nil) { t in
            if ghost != nil { t.animation = IslandMotion.retract }
        }
        // Now Watching ending while music keeps playing narrows the island smoothly, not in a snap.
        .transaction(value: content == .watching) { t in
            if content == .nowPlaying, t.animation == nil { t.animation = IslandMotion.retract }
        }
        .frame(width: NotchController.panelSize.width, height: NotchController.panelSize.height, alignment: .top)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    /// Identity of the collapsed content, so a new activity animates in instead of morphing text.
    private func contentKey(_ content: NotchContent) -> String {
        switch content {
        case .hud(let kind, _, _): return "hud-\(kind)"
        case .transient(let t): return "t-\(t.settingKey)"
        default: return String(describing: content).prefix(12).description
        }
    }
}

/// Flat top that melts into the screen edge with concave "ears", rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat = 7

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flare) }
        set { bottomRadius = newValue.first; flare = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        let f = min(flare, rect.width / 4, rect.height / 2)
        p.move(to: CGPoint(x: rect.minX - f, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + f), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX + f, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Shared pieces

/// Smooth equalizer: rounded bars driven by layered sine waves at 60 fps, drawn with Canvas
/// (one cheap draw call). When playback pauses the bars glide down to rest instead of stopping dead.
struct WaveformBars: View {
    var color: Color
    var playing: Bool
    var count = 6
    var maxHeight: CGFloat = 10
    var fps: Double = 30
    var barWidth: CGFloat = 1.9
    var gap: CGFloat = 1.9
    @StateObject private var energy = WaveEnergy()
    @StateObject private var live = LiveBars()
    @EnvironmentObject private var settings: AppSettings
    private var style: String { settings.config.waveformColor }

    var body: some View {
        let width = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !playing && energy.resting)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let level = energy.step(towards: playing ? 1 : 0, at: t)
            // Real audio levels (read each frame, not observed) blended in when capture is live.
            let audio = AudioLevels.shared
            let mix = live.step(bands: audio.bands, count: count,
                                live: settings.config.waveformReactsToAudio && audio.isLive, at: t)
            let liveValues = live.values
            Canvas { context, size in
                for i in 0..<count {
                    let fi = Double(i)
                    // Layered waves with different speeds per bar → organic, never in lockstep.
                    let wave = 0.55 * sin(t * (3.1 + fi * 0.73) + fi * 1.9)
                        + 0.30 * sin(t * (5.7 + fi * 0.41) + fi * 0.6)
                        + 0.15 * sin(t * 9.3 + fi * 2.4)
                    let synthetic = 0.5 + 0.5 * wave               // 0...1
                    let shaped = mix > 0.001 && i < liveValues.count
                        ? (1 - mix) * synthetic + mix * liveValues[i]
                        : synthetic
                    // Flattens to a row of dots when paused, rises smoothly when playing.
                    let h = max(barWidth, size.height * CGFloat((0.22 + 0.78 * shaped) * level))
                    let x = CGFloat(i) * (barWidth + gap)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    switch style {
                    case "monochrome":
                        context.fill(path, with: .color(.white.opacity(0.85)))
                    case "gradient":
                        context.fill(path, with: .linearGradient(
                            Gradient(colors: [color, color.opacity(0.35)]),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                    default:
                        context.fill(path, with: .color(color))
                    }
                }
            }
            .frame(width: width, height: maxHeight)
        }
        .onAppear { AudioLevels.shared.waveformAppeared() }
        .onDisappear { AudioLevels.shared.waveformDisappeared() }
    }
}

/// Per-frame interpolation of the live audio bands for one waveform: resamples the published
/// bands (low → high) to the bar count, glides towards them between 30 Hz updates, and cross-fades
/// between the synthetic animation and the live one.
final class LiveBars: ObservableObject {
    private(set) var values: [Double] = []
    private var mix: Double = 0
    private var last: Double = 0

    func step(bands: [Float], count: Int, live: Bool, at time: Double) -> Double {
        let dt = last == 0 ? 0 : min(0.1, time - last)
        last = time
        if values.count != count { values = Array(repeating: 0, count: count) }
        mix += ((live ? 1 : 0) - mix) * min(1, dt * 8)
        if mix < 0.001 && !live { mix = 0; return 0 }
        let k = min(1, dt * 30)                        // ~33 ms glide between updates
        let n = bands.count
        for i in 0..<count {
            var target = 0.0
            if n > 0 {
                let p = count > 1 ? Double(i) * Double(n - 1) / Double(count - 1) : 0
                let i0 = min(n - 1, Int(p)), i1 = min(n - 1, i0 + 1)
                let f = p - Double(i0)
                target = Double(bands[i0]) * (1 - f) + Double(bands[i1]) * f
            }
            values[i] += (target - values[i]) * k
        }
        return mix
    }
}

/// Eases the waveform's energy in and out (critically damped), so play/pause transitions glide.
final class WaveEnergy: ObservableObject {
    private(set) var level: Double = 0
    /// Bars have settled flat while paused. Published (unlike `level`) so the view re-renders and
    /// pauses its TimelineView: `paused:` is only read when the body runs, so after a pause the
    /// timeline kept redrawing flat bars at 30–60 fps until something else updated the view.
    @Published private(set) var resting = true
    private var last: Double = 0

    func step(towards target: Double, at time: Double) -> Double {
        let dt = last == 0 ? 0 : min(0.1, time - last)
        last = time
        level += (target - level) * min(1, dt * 6)
        let rest = target == 0 && level < 0.01
        if rest != resting {
            // Not during the view update that called us.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.resting != rest else { return }
                self.resting = rest
            }
        }
        return level
    }
}

/// Album art that flips (3D) when the track changes.
struct FlippingArtwork: View {
    let size: CGFloat
    let radius: CGFloat
    var body: some View { FlipContainer(size: size, radius: radius) }
}

private struct ArtworkFace: View {
    let size: CGFloat
    let radius: CGFloat
    /// The picture for this face. Passed in (not read live) so the face turning away keeps the old
    /// song's art instead of showing the new one mid-flip.
    let image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.12)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

/// Wraps the artwork so it does a 3D card flip whenever the track (or its art) changes.
struct FlipContainer: View {
    let size: CGFloat
    let radius: CGFloat
    @ObservedObject private var media = MediaController.shared
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        // Flip only when the song changes. Keying on the image object flipped on pause/resume and
        // seeks (the same art is re-sent as a new image) and flipped twice when art arrived late.
        let key = settings.config.artworkFlip
            ? "\(media.info?.title ?? "")|\(media.info?.artist ?? "")"
            : "art"
        ZStack {
            ArtworkFace(size: size, radius: radius, image: media.artwork)
                .id(key)
                .transition(.asymmetric(
                    insertion: .modifier(active: FlipModifier(angle: -90), identity: FlipModifier(angle: 0))
                        .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.2)),
                    removal: .modifier(active: FlipModifier(angle: 90), identity: FlipModifier(angle: 0))
                        .animation(.timingCurve(0.5, 0, 0.9, 0.5, duration: 0.2))))
        }
        .frame(width: size, height: size)
        .animation(.default, value: key)
    }
}

private struct FlipModifier: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .scaleEffect(1 - 0.12 * abs(angle) / 90)
            .shadow(color: .black.opacity(0.35 * abs(angle) / 90), radius: 6, x: angle > 0 ? -4 : 4)
            .opacity(abs(angle) >= 89 ? 0 : 1)
    }
}

private struct MiniRing: View {
    let level: Int
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: CGFloat(level) / 100)
                .stroke(level < 20 ? Color.red : level < 50 ? Color.orange : Color.green,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Collapsed live activities

private struct CompactActivity: View {
    let content: NotchContent
    let notchWidth: CGFloat
    let height: CGFloat
    @EnvironmentObject private var model: NotchModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var timer = NotchTimer.shared
    @ObservedObject private var watching = WatchingDetector.shared

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 9)
            Color.clear.frame(width: notchWidth)
            right.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 11)
        }
        .frame(height: height)
        .foregroundStyle(.white)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
    }

    @ViewBuilder private var left: some View {
        switch content {
        case .nowPlaying:
            FlippingArtwork(size: 20, radius: 5)
        case .watching:
            HStack(spacing: 6) {
                Image(systemName: watching.service.symbol).font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                // Show the service here only when the title (on the right) is the real show; a bare
                // service name shows on the right instead, so it isn't duplicated.
                if watching.hasDistinctTitle {
                    Text(watching.service.name).font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(1).fixedSize()
                }
            }
        case .timer, .transient(.timerDone):
            Image(systemName: "timer").foregroundStyle(.orange)
        case .hud(let kind, _, let muted):
            HStack(spacing: 6) {
                Image(systemName: kind == .brightness ? "sun.max.fill"
                      : muted ? "speaker.slash.fill"
                      : (settings.config.hudShowsDevice ? (AudioDevices.shared.current?.symbol ?? "speaker.wave.2.fill") : "speaker.wave.2.fill"))
                Text(kind == .brightness ? "Display" : "Sound").font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        case .device:
            if case .device(_, let symbol, _) = model.transient {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            }
        case .locked:
            if settings.config.lockedIndicator == "icon" {
                Image(systemName: "lock.fill").font(.system(size: height * 0.27, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            } else {
                BreathingGlow(color: WidgetStore.shared.systemAccent).scaleEffect(0.75)
            }
        case .transient(.unlocked):
            UnlockGlyph(size: height * 0.27)
        case .transient(.charging(_, let state)):
            switch state {
            case .charging: Image(systemName: "bolt.fill").foregroundStyle(.green)
            case .onHold: Image(systemName: "powerplug.fill").foregroundStyle(.orange)
            case .charged: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .onBattery: Image(systemName: SFSymbol.unpluggedPlug).foregroundStyle(.white)
            }
        case .transient(.lowBattery):
            Image(systemName: "battery.25percent").foregroundStyle(.red)
        case .transient(.event(_, _, let colorHex)):
            Image(systemName: "calendar").foregroundStyle(colorHex.flatMap(Color.init(hex:)) ?? .red)
        case .transient(.lowPower(let on)):
            Image(systemName: on ? "leaf.fill" : "leaf").foregroundStyle(on ? .yellow : .white)
        case .transient(.focus(let on)):
            Image(systemName: on ? "moon.fill" : "moon").foregroundStyle(on ? .indigo : .white)
        case .idleWeather:
            if let w = WidgetStore.shared.weather {
                Image(systemName: w.symbol).symbolRenderingMode(.multicolor).font(.system(size: height * 0.34))
            }
        case .idleNotPlaying:
            Image(systemName: "music.note").foregroundStyle(.white.opacity(0.45))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var right: some View {
        switch content {
        case .nowPlaying:
            WaveformBars(color: media.artworkColor, playing: media.info?.isPlaying == true, count: 5, maxHeight: 12, barWidth: 2.5, gap: 1)
        case .watching:
            Text(watching.hasDistinctTitle ? watching.title : watching.service.name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 150, alignment: .trailing)
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(formatDuration(timer.remaining(at: ctx.date))).monospacedDigit().foregroundStyle(.orange).lineLimit(1).fixedSize()
            }
        case .hud(_, let level, let muted):
            let percent = muted ? 0 : Int((level * 100).rounded())
            HStack(spacing: 7) {
                HUDBar(level: muted ? 0 : level, style: settings.config.hudStyle,
                       color: settings.config.hudUsesAccent ? WidgetStore.shared.systemAccent : .white)
                if settings.config.hudShowsPercent {
                    Text("\(percent)")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(percent)))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 26, alignment: .trailing)
                }
            }
        case .device:
            if case .device(let name, _, let level) = model.transient {
                HStack(spacing: 6) {
                    Text(name).lineLimit(1).truncationMode(.tail).font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7)).frame(maxWidth: 96)
                    if let level { MiniRing(level: level).frame(width: 17, height: 17) }
                }
            }
        case .locked:
            EmptyView()
        case .transient(.charging(let level, let state)):
            HStack(spacing: 5) {
                if state == .onHold {
                    Text("On Hold").foregroundStyle(.orange).lineLimit(1)
                } else if state == .charged {
                    Text("Charged").foregroundStyle(.green).lineLimit(1)
                }
                Text("\(level)%").monospacedDigit().lineLimit(1)
                    .foregroundStyle(state == .onHold || state == .charged ? .white.opacity(0.7) : .white)
                Image(systemName: BatteryLook.symbol(for: level, charging: false))
                    .foregroundStyle(state == .onBattery ? (level < 20 ? .red : .white) : (state == .onHold ? .orange : .green))
            }
            .fixedSize()
        case .transient(.lowBattery(let level)):
            Text("\(level)%").monospacedDigit().foregroundStyle(.red).lineLimit(1).fixedSize()
        case .transient(.event(let title, let minutes, _)):
            HStack(spacing: 4) {
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 70, alignment: .trailing)
                Text(minutes <= 0 ? "now" : "\(minutes)m").foregroundStyle(.white.opacity(0.6)).monospacedDigit().fixedSize()
            }
        case .transient(.lowPower(let on)):
            Text(on ? "Low Power" : "Off").foregroundStyle(on ? .yellow : .white.opacity(0.7)).lineLimit(1).fixedSize()
        case .transient(.focus(let on)):
            Text(on ? "Focus" : "Off").foregroundStyle(on ? .indigo : .white.opacity(0.7)).lineLimit(1).fixedSize()
        case .idleWeather:
            if let w = WidgetStore.shared.weather {
                Text("\(Int(w.temperature.rounded()))°").monospacedDigit().foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).fixedSize() // one line, like every other compact activity
            }
        case .idleNotPlaying:
            Text("Not playing").foregroundStyle(.white.opacity(0.55)).lineLimit(1).fixedSize()
        case .transient(.unlocked):
            EmptyView()
        case .transient(.timerDone):
            Text("Done").foregroundStyle(.orange).lineLimit(1).fixedSize()
        default:
            EmptyView()
        }
    }
}

// MARK: - Expanded

private struct ExpandedNotch: View {
    let notchHeight: CGFloat
    let notchWidth: CGFloat
    @EnvironmentObject private var model: NotchModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let pages = model.availablePages
        HStack(spacing: 0) {
            Group {
                switch model.page {
                case .nowPlaying: NowPlayingPage()
                case .notifications: NotificationsPage()
                case .calendar: CalendarPage()
                case .widgets: WidgetsPage()
                case .shelf: ShelfPage()
                case .timer: TimerPage()
                }
            }
            .id(model.page)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if pages.count > 1, settings.config.notchPageDots {
                VStack(spacing: 5) {
                    ForEach(pages) { page in
                        Capsule()
                            .fill(Color.white.opacity(page == model.page ? 0.9 : 0.25))
                            .frame(width: 4, height: page == model.page ? 12 : 4)
                            .onTapGesture { model.choosePage(page) }
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(.top, model.page == .nowPlaying ? 18 : notchHeight + 4)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }
}

private struct NowPlayingPage: View {
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var audio = AudioDevices.shared
    @ObservedObject private var spotify = SpotifyClient.shared
    @ObservedObject private var ytMusic = YTMusicBridge.shared
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if let info = media.info {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 16.5) {
                    // Art + title: click to open the app that's playing.
                    HStack(alignment: .center, spacing: 16.5) {
                        FlippingArtwork(size: 56, radius: 10)
                            .scaleEffect(info.isPlaying ? 1 : 0.857)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: info.isPlaying)
                            .overlay(alignment: .bottomTrailing) {
                                if settings.config.showSourceBadge, let icon = info.appIcon {
                                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                        .shadow(color: .black.opacity(0.5), radius: 2)
                                        .offset(x: 5, y: 5)
                                }
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.displayTitle).font(.system(size: 14.5, weight: .semibold))
                            Text(info.artist).font(.system(size: 14.5))
                                .foregroundStyle(Color(red: 0.553, green: 0.553, blue: 0.569))
                        }
                        .lineLimit(1)
                        .padding(.top, 14)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openSource(info) }
                    .help(info.appName.map { "Open \($0)" } ?? "Open the player")
                    Spacer(minLength: 6)
                    WaveformBars(color: media.artworkColor, playing: info.isPlaying, count: 7, maxHeight: 13, fps: 60, barWidth: 2, gap: 2)
                        .padding(.top, 4)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(height: 56)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let position = info.currentPosition(at: ctx.date)
                    HStack(spacing: 10) {
                        Text(formatDuration(position)).frame(width: 36, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(Color(red: 0.169, green: 0.176, blue: 0.173))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(media.artworkColor.opacity(0.8))
                                        .frame(width: info.duration > 0 ? geo.size.width * CGFloat(position / info.duration) : 0)
                                }
                                .contentShape(Rectangle().inset(by: -6))
                                .onTapGesture(coordinateSpace: .local) { location in
                                    guard info.duration > 0, geo.size.width > 0 else { return }
                                    let fraction = min(1, max(0, Double(location.x / geo.size.width)))
                                    media.seek(to: info.duration * fraction)
                                }
                        }
                        .frame(height: 6)
                        Text(info.duration > 0 ? "-" + formatDuration(info.duration - position) : "Live")
                            .frame(width: 40, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                }
                HStack {
                    leftControl(info)
                    Spacer()
                    control("backward.fill", 20) { media.previous() }
                    Spacer()
                    control(info.isPlaying ? "pause.fill" : "play.fill", 26) { media.playPause() }
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    control("forward.fill", 20) { media.next() }
                    Spacer()
                    Menu {
                        if spotify.connected, info.bundleIdentifier == "com.spotify.client" {
                            Section("Spotify Connect") {
                                ForEach(spotify.devices) { device in
                                    Button {
                                        Task { await spotify.transfer(to: device) }
                                    } label: {
                                        Label(device.name, systemImage: device.isActive ? "checkmark" : device.symbol)
                                    }
                                }
                                Button("Refresh devices") { Task { await spotify.loadDevices() } }
                            }
                            Section("This Mac's output") {
                                ForEach(audio.outputs) { device in
                                    Button { audio.select(device) } label: {
                                        Label(device.name, systemImage: device.id == audio.currentID ? "checkmark" : device.symbol)
                                    }
                                }
                            }
                        } else {
                        ForEach(audio.outputs) { device in
                            Button {
                                audio.select(device)
                            } label: {
                                Label(device.name, systemImage: device.id == audio.currentID ? "checkmark" : device.symbol)
                            }
                        }
                        }
                    } label: {
                        Image(systemName: audio.current?.symbol ?? "headphones")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        } else {
            HStack(spacing: 14) {
                FlippingArtwork(size: 56, radius: 11)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing playing").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Spotify, Music, YouTube Music or any app").font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
        }
    }

    /// Brings the app that's playing to the front (browsers open to their window; macOS doesn't let
    /// other apps pick a tab), then closes the island.
    private func openSource(_ info: NowPlayingInfo) {
        guard settings.config.openSourceOnTap, let id = info.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        if settings.config.notchHaptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        AppDelegate.shared?.notch?.collapse()
    }

    /// The button left of "previous": Like, Shuffle or Repeat (Settings › Island). Like only appears
    /// where it works (Music/Podcasts, or Spotify once connected); otherwise Shuffle is shown.
    @ViewBuilder private func leftControl(_ info: NowPlayingInfo) -> some View {
        let choice = settings.config.notchLeftControl
        if choice == "like" {
            let youtube = YTMusicBridge.browser(for: info.bundleIdentifier) != nil
            let music = info.bundleIdentifier == "com.apple.Music"
            let spotifyApp = info.bundleIdentifier == "com.spotify.client"
            // YouTube's state counts only while its tab is the source (it lingers from the last song).
            let liked = (spotifyApp && spotify.isLiked) || (youtube && ytMusic.active && ytMusic.liked)
                || (music && media.musicFavorited)
            // Each service's own control: Apple Music "Favourite" (star), Spotify "Liked Songs"
            // (plus → green tick), YouTube Music "Like" (thumbs up); a heart elsewhere.
            let symbol: String = music ? (liked ? "star.fill" : "star")
                : spotifyApp ? (liked ? "checkmark.circle.fill" : "plus.circle")
                : youtube ? (liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                : (liked ? "heart.fill" : "heart")
            let tint: Color? = !liked ? nil
                : music ? Color(red: 0.98, green: 0.24, blue: 0.33)       // Apple Music red
                : spotifyApp ? Color(red: 0.11, green: 0.73, blue: 0.33)  // Spotify green
                : youtube ? .white : .red
            let likeLabel = music ? (liked ? "Unfavourite" : "Favourite")
                : spotifyApp ? (liked ? "Remove from Liked Songs" : "Add to Liked Songs")
                : youtube ? (liked ? "Remove like" : "Like") : "Like"
            control(symbol, 16, dim: !liked, tint: tint) {
                if info.canLike {
                    media.like()
                } else {
                    // Spotify needs the optional connection; YouTube Music needs the browser setting.
                    if youtube { YTMusicBridge.shared.refresh() } else { AppActions.shared.openSettingsPage("integrations") }
                }
            }
            .help(spotify.busyUntil != nil && spotifyApp ? "Spotify is busy — likes paused for a few minutes" : info.canLike ? likeLabel : (youtube ? (ytMusic.needsAppleEvents ?? "Open YouTube Music in the browser") : "Connect Spotify in Settings › Notifications & Apps to like songs"))
        } else if choice == "repeat" {
            control(info.repeatMode == 2 ? "repeat.1" : "repeat", 16, dim: !info.repeatOn, tint: info.repeatOn ? media.artworkColor : nil) { media.toggleRepeat() }
        } else if choice == "none" {
            Color.clear.frame(width: 38, height: 34)
        } else {
            control("shuffle", 16, dim: !info.shuffleOn, tint: info.shuffleOn ? media.artworkColor : nil) { media.toggleShuffle() }
        }
    }

    private func control(_ symbol: String, _ size: CGFloat, dim: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        MediaButton(symbol: symbol, size: size, tint: tint ?? .white.opacity(dim ? 0.55 : 1), haptics: settings.config.notchHaptics, action: action)
    }
}

private struct WidgetsPage: View {
    @EnvironmentObject private var store: WidgetStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                if let w = store.weather {
                    item(symbol: w.symbol, multicolor: true, title: "\(Int(w.temperature.rounded()))°",
                         detail: "H:\(Int(w.high.rounded()))° L:\(Int(w.low.rounded()))°")
                    if let aqi = w.airQuality {
                        let level = AirQualityLevel(aqi: aqi)
                        item(symbol: "aqi.medium", tint: Color(red: level.rgb.0, green: level.rgb.1, blue: level.rgb.2),
                             title: "\(aqi)", detail: level.title)
                    }
                }
                if let b = store.mac {
                    item(symbol: BatteryLook.symbol(for: b.level, charging: b.isCharging),
                         tint: b.isCharging ? .green : (b.level < 20 ? .red : .white),
                         title: "\(b.level)%", detail: b.isCharging ? "Charging" : (b.isPluggedIn ? "Plugged in" : "Battery"))
                }
            }
            let devices = store.visiblePeripherals(hidden: settings.config.hiddenDevices)
            if !devices.isEmpty {
                HStack(spacing: 12) {
                    ForEach(devices.prefix(6)) { d in
                        HStack(spacing: 5) {
                            ZStack {
                                MiniRing(level: d.level).frame(width: 24, height: 24)
                                Image(systemName: d.kind.symbol).font(.system(size: 10, weight: .semibold))
                            }
                            Text("\(d.level)%").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        .help(d.displayName)
                    }
                }
            }
            if let event = store.nextEvent {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(event.colorHex.flatMap(Color.init(hex:)) ?? .red).frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text(event.isHappeningNow ? "Now" : TimeFormat.time(event.start, h24: settings.config.use24Hour))
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(symbol: String, multicolor: Bool = false, tint: Color = .white, title: String, detail: String) -> some View {
        HStack(spacing: 7) {
            Group {
                if multicolor { Image(systemName: symbol).symbolRenderingMode(.multicolor) }
                else { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(detail).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

private struct ShelfPage: View {
    @ObservedObject private var shelf = ShelfModel.shared
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        let border = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 22))
                    Text("Drop files, images, links or text").font(.system(size: 13, weight: .medium, design: .rounded))
                    Text("Drag them back out to any app").font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        // Newest first.
                        ForEach(shelf.items.reversed(), id: \.self) { url in
                            ShelfItemView(url: url)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !shelf.items.isEmpty {
                Button { shelf.clear() } label: {
                    Text("Clear all").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = shelf.notice {
                Text(notice).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shelf.notice)
        .background(border.strokeBorder(Color.white.opacity(model.dropTargeted ? 0.6 : 0.14),
                                        style: StrokeStyle(lineWidth: 1.3, dash: [5, 4])))
    }
}

/// One shelf item: its Quick Look thumbnail (Finder icon until that arrives) and name; drag it out,
/// double-click to open, hover for a remove button.
private struct ShelfItemView: View {
    let url: URL
    @ObservedObject private var shelf = ShelfModel.shared
    @StateObject private var hover = RowHover()

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: shelf.thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 40)
            Text(url.lastPathComponent).font(.system(size: 9, weight: .medium, design: .rounded))
                .lineLimit(2).multilineTextAlignment(.center).frame(width: 64)
        }
        .overlay(alignment: .topTrailing) {
            if hover.on {
                Button { shelf.remove(url) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -4)
                .help("Remove from Shelf")
            }
        }
        .onHover { hover.on = $0 }
        .onAppear { shelf.loadThumbnail(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop…") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url]) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(url) }
            Button("Clear Shelf") { shelf.clear() }
        }
    }
}

private struct TimerPage: View {
    @ObservedObject private var timer = NotchTimer.shared
    private let presets = [1, 5, 10, 15, 25, 45]

    var body: some View {
        HStack(spacing: 20) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remaining = timer.remaining(at: ctx.date)
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: timer.isRunning && timer.total > 0 ? CGFloat(remaining / timer.total) : 0)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(timer.isRunning ? formatDuration(remaining) : "0:00")
                        .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 88, height: 88)
            }
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 6), count: 3), spacing: 6) {
                    ForEach(presets, id: \.self) { minutes in
                        Button { timer.start(minutes: minutes) } label: {
                            Text("\(minutes)m").font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 54, height: 26)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if timer.isRunning {
                    Button { timer.cancel() } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Notification banner

/// A mirrored notification: app icon, title and message under the notch (click to open the app).
private struct NotificationBanner: View {
    let note: MirroredNotification
    let notchHeight: CGFloat
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Group {
                if let icon = note.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.badge.fill").resizable().foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(note.title.isEmpty ? note.appName : note.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer(minLength: 6)
                    Text(note.appName).font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .lineLimit(1)
                if settings.config.notificationShowBody {
                    Text([note.subtitle, note.body].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            if note.canReply {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .islandGlass(Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(11)
        .notificationPlatter(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.top, notchHeight + 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Blur + scale + fade, used for content appearing inside the island.
private struct SoftAppear: ViewModifier {
    var progress: CGFloat
    var scale: CGFloat = 0.9
    var blur: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .opacity(Double(progress))
            .scaleEffect(scale + (1 - scale) * progress, anchor: .top)
            .blur(radius: blur * (1 - progress))
    }
}

// MARK: - Lock animations

/// A padlock whose shackle snaps shut (locked) or springs open (unlocked) when it appears.
struct AnimatedPadlock: View {
    let locked: Bool
    @StateObject private var state = PadlockState()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let bodyH = h * 0.55
            ZStack(alignment: .bottom) {
                // Shackle
                Shackle()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.16, lineCap: .round))
                    .frame(width: w * 0.62, height: h * 0.5)
                    .offset(x: state.open ? w * 0.18 : 0, y: -(bodyH - w * 0.05) - (state.open ? h * 0.12 : 0))
                    .rotationEffect(.degrees(state.open ? 12 : 0), anchor: .bottomTrailing)
                // Body
                RoundedRectangle(cornerRadius: w * 0.18, style: .continuous)
                    .fill(Color.white)
                    .frame(width: w, height: bodyH)
                    .scaleEffect(state.pulse ? 1.12 : 1)
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
        .onAppear {
            // Start in the opposite pose, then spring into place.
            state.open = locked
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { state.open = !locked }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5).delay(0.18)) { state.pulse = true }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.36)) { state.pulse = false }
            }
        }
    }
}

private final class PadlockState: ObservableObject {
    @Published var open = false
    @Published var pulse = false
}

private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.width / 2
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

/// A soft glow that slowly breathes while the Mac is locked.
struct BreathingGlow: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 1.6) + 1) / 2 // 0...1, ~4 s cycle
            ZStack {
                Circle()
                    .fill(color.opacity(0.35 + 0.35 * phase))
                    .frame(width: 14, height: 14)
                    .blur(radius: 4 + 3 * phase)
                Circle()
                    .fill(color)
                    .frame(width: 5 + 2 * phase, height: 5 + 2 * phase)
                    .shadow(color: color, radius: 3 + 3 * phase)
            }
            .frame(width: 18, height: 18)
        }
    }
}

// MARK: - Media button

/// A media control that squishes on press and bounces its symbol when tapped.
private struct MediaButton: View {
    let symbol: String
    let size: CGFloat
    let tint: Color
    let haptics: Bool
    let action: () -> Void
    @StateObject private var taps = TapCounter()
    @ObservedObject private var media = MediaController.shared
    private var isForward: Bool { symbol.contains("forward") }
    private var isBackward: Bool { symbol.contains("backward") }

    var body: some View {
        Button {
            if haptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
            taps.count += 1
            let direction: CGFloat = symbol.contains("forward") ? 1 : (symbol.contains("backward") ? -1 : 0)
            if direction != 0 {
                NotchModel.shared.jiggle(direction)
                withAnimation(.easeOut(duration: 0.1)) { taps.dart = 14 * direction }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.38)) { taps.dart = 0 }
                }
            }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                // Skip buttons: directional wiggle (driven by the media controller, so it also plays for
                // key/swipe skips and survives the view rebuilding) plus a dart. Others bounce.
                .offset(x: taps.dart)
                .rotationEffect(.degrees(Double(taps.dart) * 0.9))
                .scaleEffect(1 + abs(taps.dart) / 14 * 0.22)
                .modifier(SkipWiggle(forward: isForward ? media.skipForwardCount : 0, back: isBackward ? media.skipBackCount : 0))
                .symbolEffect(.bounce, value: isForward || isBackward ? 0 : taps.count)
                .contentTransition(.symbolEffect(.replace.offUp))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle())
    }
}

/// Directional SF Symbol wiggle for the skip buttons (macOS 15+; older systems keep the dart).
private struct SkipWiggle: ViewModifier {
    let forward: Int
    let back: Int
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .symbolEffect(.wiggle.right.byLayer, options: .repeat(2).speed(1.1), value: forward)
                .symbolEffect(.wiggle.left.byLayer, options: .repeat(2).speed(1.1), value: back)
        } else {
            content
        }
    }
}

private final class TapCounter: ObservableObject {
    @Published var count = 0
    @Published var dart: CGFloat = 0
}

private struct SquishButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Song-change peek

/// Quick Peek when the song changes: the compact row stays on top and one centred line
/// "♪ Title · Artist" appears underneath.
private struct SongPeek: View {
    let title: String
    let artist: String
    let notchHeight: CGFloat
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                FlippingArtwork(size: 20, radius: 5)
                Spacer()
                WaveformBars(color: media.artworkColor, playing: true, count: 5, maxHeight: 12, barWidth: 2.5, gap: 1)
            }
            .padding(.horizontal, 11)
            .frame(height: notchHeight)
            Text("♪ \(title) · \(artist)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.78))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Tall transient cards get round, pill-like corners instead of the compact island's small ones.
private func isPeek(_ content: NotchContent) -> Bool {
    switch content {
    case .transient(.songChange), .transient(.notification): return true
    default: return false
    }
}

// MARK: - Notifications page

/// Recent notifications in the open island. Click to open the app; Messages can be replied to here.
private struct NotificationsPage: View {
    @ObservedObject private var mirror = NotificationMirror.shared
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var reply = ReplyState.shared

    var body: some View {
        if !settings.config.mirrorNotifications || !mirror.hasAccess {
            VStack(spacing: 6) {
                Image(systemName: "app.badge").font(.system(size: 20))
                Text(settings.config.mirrorNotifications ? "Allow Full Disk Access to see notifications here" : "Notifications are turned off")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Button("Open Settings") { AppActions.shared.openSettingsPage("integrations") }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.blue)
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mirror.recent.isEmpty {
            Text("No notifications yet").font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                HStack {
                    Text("Notifications").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button("Clear all") { withAnimation(IslandMotion.page) { mirror.clearAll() } }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 4)
                ScrollView(.vertical, showsIndicators: false) {
                    GlassGroup {
                        VStack(spacing: 6) {
                            ForEach(mirror.recent.prefix(8)) { note in
                                NotificationRow(note: note, reply: reply)
                                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                            removal: .scale(scale: 0.9).combined(with: .opacity)))
                            }
                        }
                    }
                }
            }
        }
    }
}

final class ReplyState: ObservableObject {
    static let shared = ReplyState()
    @Published var activeID: Int64?
    @Published var text = ""
    @Published var status: String?
}

private struct NotificationRow: View {
    let note: MirroredNotification
    @ObservedObject var reply: ReplyState
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var hover = RowHover()

    var canReply: Bool { settings.config.notificationReply && note.canReply }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 9) {
                Group {
                    if let icon = note.icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "app.badge.fill").resizable() }
                }
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(note.appName.uppercased()).font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        Spacer(minLength: 4)
                        // Updated once a minute (a per-second relative date redrew every row constantly).
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(shortAgo(note.date, now: context.date)).font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        if hover.on {
                            Button { withAnimation(IslandMotion.page) { NotificationMirror.shared.dismiss(note.id) } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                    if !note.title.isEmpty {
                        Text(note.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                    if settings.config.notificationShowBody {
                        Text([note.subtitle, note.body].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
                    }
                }
                if canReply {
                    Button {
                        withAnimation(IslandMotion.page) {
                            reply.activeID = reply.activeID == note.id ? nil : note.id
                            reply.text = ""
                            reply.status = nil
                        }
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(SquishButtonStyle())
                }
            }
            if reply.activeID == note.id {
                HStack(spacing: 6) {
                    TextField("Reply to \(note.title)…", text: $reply.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .islandGlass(Capsule())
                        .onSubmit { send() }
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(.blue)
                    }
                    .buttonStyle(SquishButtonStyle())
                    .disabled(reply.text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let status = reply.status {
                    Text(status).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(10)
        .notificationPlatter(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hover.on = inside } }
        .onTapGesture {
            // Messages: tap opens (or closes) the reply. Other apps: open the app.
            if canReply {
                guard reply.activeID != note.id else { return }
                withAnimation(IslandMotion.page) {
                    reply.activeID = note.id
                    reply.text = ""
                    reply.status = nil
                }
                AppDelegate.shared?.notch?.focusPanel()
                return
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: note.bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func send() {
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply.status = "Sending…"
        MessagesReply.send(text, to: note.title) { ok in
            reply.status = ok ? "Sent" : "Couldn't send — open Messages to reply"
            if ok {
                reply.text = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(IslandMotion.page) { reply.activeID = nil }
                    reply.status = nil
                }
            }
        }
    }
}

/// Replies to a Messages conversation by the sender's name (the notification title), via the
/// Messages AppleScript dictionary. macOS asks once for permission to control Messages.
enum MessagesReply {
    static func send(_ text: String, to sender: String, completion: @escaping (Bool) -> Void) {
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = """
        tell application "Messages"
            set target to missing value
            try
                set target to first chat whose name is "\(escape(sender))"
            end try
            if target is missing value then
                repeat with c in chats
                    try
                        if name of c is "\(escape(sender))" then
                            set target to c
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if target is missing value then
                set target to participant "\(escape(sender))" of (1st account whose service type = iMessage)
            end if
            send "\(escape(text))" to target
        end tell
        """
        appleScriptQueue.async {
            var error: NSDictionary?
            // A script that can't even be created must not be reported as "Sent".
            let ran = NSAppleScript(source: source).map { script in
                _ = script.executeAndReturnError(&error)
                return true
            } ?? false
            DispatchQueue.main.async { completion(ran && error == nil) }
        }
    }
}

// MARK: - Unlock glyph

/// The closed lock briefly morphs into an open lock, then the activity fades away.
private struct UnlockGlyph: View {
    let size: CGFloat
    @StateObject private var state = UnlockState()

    var body: some View {
        Image(systemName: state.open ? "lock.open.fill" : "lock.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .contentTransition(.symbolEffect(.replace))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.open = true }
                }
            }
    }
}

private final class UnlockState: ObservableObject {
    @Published var open = false
}

// MARK: - HUD bar

/// Volume / brightness level: plain, gradient or segmented (Settings › Island).
private struct HUDBar: View {
    let level: Float
    let style: String
    let color: Color
    private let width: CGFloat = 44

    /// Green when low → yellow → orange → red near 100 %.
    static func levelColor(_ level: Float) -> Color {
        let stops: [(Float, (Double, Double, Double))] = [
            (0.0, (0.20, 0.84, 0.45)), (0.5, (0.98, 0.84, 0.26)), (0.8, (1.0, 0.58, 0.20)), (1.0, (1.0, 0.27, 0.23)),
        ]
        let l = min(1, max(0, level))
        for i in 1..<stops.count where l <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            let t = Double((l - a) / (b - a))
            return Color(red: ca.0 + (cb.0 - ca.0) * t, green: ca.1 + (cb.1 - ca.1) * t, blue: ca.2 + (cb.2 - ca.2) * t)
        }
        return Color(red: 1.0, green: 0.27, blue: 0.23)
    }

    private static let spectrum = LinearGradient(
        colors: [levelColor(0), levelColor(0.5), levelColor(0.8), levelColor(1)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        Group {
            if style == "level" {
                // The bar and its glow take the colour of the current level.
                let tint = HUDBar.levelColor(level)
                Capsule().fill(tint.opacity(0.2)).frame(width: width, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint)
                            .frame(width: max(level > 0 ? 3 : 0, width * CGFloat(level)), height: 3)
                            .shadow(color: tint.opacity(0.9), radius: 3)
                    }
                    .animation(.easeOut(duration: 0.2), value: level)
            } else if style == "gradient" {
                // Whole green→red spectrum, revealed up to the level.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: width, height: 4)
                    Capsule().fill(HUDBar.spectrum).frame(width: width, height: 4)
                        .mask(alignment: .leading) {
                            Capsule().frame(width: max(level > 0 ? 4 : 0, width * CGFloat(level)), height: 4)
                        }
                        .shadow(color: HUDBar.levelColor(level).opacity(0.7), radius: 3)
                }
            } else if style == "glow" {
                Capsule().fill(color.opacity(0.22)).frame(width: width, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: max(level > 0 ? 3 : 0, width * CGFloat(level)), height: 3)
                            .shadow(color: color.opacity(0.9), radius: 3)
                    }
            } else if style == "segments" {
                HStack(spacing: 2) {
                    ForEach(0..<10, id: \.self) { i in
                        Capsule()
                            .fill(Float(i) < (level * 10).rounded(.up) ? color : Color.white.opacity(0.2))
                            .frame(width: (width - 18) / 10, height: 6)
                    }
                }
            } else {
                Capsule().fill(Color.white.opacity(0.22)).frame(width: width, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(style == "gradient"
                                  ? AnyShapeStyle(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
                                  : AnyShapeStyle(color))
                            .frame(width: max(level > 0 ? 3 : 0, width * CGFloat(level)), height: 5)
                    }
            }
        }
        .animation(.snappy(duration: 0.18), value: level)
    }
}

// MARK: - Calendar page

/// Month grid on the left (today highlighted, dots on days with events) and upcoming events on the right.
private struct CalendarPage: View {
    @EnvironmentObject private var store: WidgetStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            MonthGrid(eventDays: store.eventDays)
                .frame(width: 150)
            VStack(alignment: .leading, spacing: 7) {
                Text(TimeFormat.date(Date(), long: true)).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                if store.upcomingEvents.isEmpty {
                    if let w = store.weather {
                        HStack(spacing: 6) {
                            Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                            Text("Your day is clear · \(Int(w.temperature.rounded()))° \(w.condition)")
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    } else {
                        Text(store.calendarStatus ?? "Your day is clear")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                } else {
                    ForEach(Array(store.upcomingEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(event.colorHex.flatMap(Color.init(hex:)) ?? .red)
                                .frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(event.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                Text(event.isHappeningNow ? "Now" : "\(TimeFormat.time(event.start, h24: settings.config.use24Hour)) – \(TimeFormat.time(event.end, h24: settings.config.use24Hour))")
                                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MonthGrid: View {
    let eventDays: Set<Int>

    var body: some View {
        let calendar = Calendar.current
        let today = Date()
        let interval = calendar.dateInterval(of: .month, for: today)!
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let lead = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: today)!.count
        let todayDay = calendar.component(.day, from: today)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        let columns = Array(repeating: GridItem(.fixed(18), spacing: 3), count: 7)

        VStack(alignment: .leading, spacing: 4) {
            Text(today.formatted(.dateTime.month(.wide))).font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.4))
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 16) }
                ForEach(1...days, id: \.self) { day in
                    VStack(spacing: 1) {
                        Text("\(day)")
                            .font(.system(size: 9, weight: day == todayDay ? .bold : .medium, design: .rounded))
                            .foregroundStyle(day == todayDay ? .white : .white.opacity(day < todayDay ? 0.35 : 0.8))
                            .frame(width: 16, height: 12)
                            .background(Circle().fill(day == todayDay ? Color.red : .clear).frame(width: 15, height: 15))
                        Circle().fill(eventDays.contains(day) ? Color.white.opacity(0.6) : .clear).frame(width: 2.5, height: 2.5)
                    }
                    .frame(height: 16)
                }
            }
        }
    }
}

// MARK: - Right-click menu

/// Right-click on the island: quick actions and the way into Settings.
private struct IslandContextMenu: View {
    let controller: NotchController
    @EnvironmentObject private var model: NotchModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button("Settings…") { AppActions.shared.openSettings() }
        Divider()
        Button("Quit Notch") { NSApp.terminate(nil) }
    }
}

// MARK: - Glass

extension View {
    /// Apple's Liquid Glass on macOS 26+, frosted material before that.
    @ViewBuilder
    func islandGlass<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

extension View {
    /// Notification banners and rows: Liquid Glass or solid, per Settings › Notifications & Apps.
    @ViewBuilder
    func notificationPlatter<S: Shape>(_ shape: S) -> some View {
        switch AppSettings.shared.config.notificationStyle {
        case "solid": self.background(shape.fill(Color.white.opacity(0.09)))
        case "dark": self.background(shape.fill(Color.black.opacity(0.55))).overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        case "light": self.background(shape.fill(Color.white.opacity(0.22))).overlay(shape.stroke(Color.white.opacity(0.3), lineWidth: 0.5))
        case "clear":
            if #available(macOS 26.0, *) { self.glassEffect(.clear, in: shape) } else { self.islandGlass(shape) }
        case "tinted":
            if #available(macOS 26.0, *) {
                self.glassEffect(.regular.tint(Color.accentColor.opacity(0.35)), in: shape)
            } else {
                self.background(shape.fill(Color.accentColor.opacity(0.25)))
            }
        default: self.islandGlass(shape)
        }
    }
}

private final class RowHover: ObservableObject { @Published var on = false }

/// "now", "5m", "2h", "3d".
func shortAgo(_ date: Date, now: Date) -> String {
    let s = max(0, now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    return "\(Int(s / 86400))d"
}

/// Groups glass shapes so they render together (much cheaper than separate glass layers).
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { content }
        } else {
            content
        }
    }
}

/// SF Symbols newer than macOS 14 render as an empty image there, so pick a fallback at runtime.
enum SFSymbol {
    /// "powerplug.portrait" is macOS 15+; "powerplug" exists since macOS 12.
    static let unpluggedPlug: String = NSImage(systemSymbolName: "powerplug.portrait", accessibilityDescription: nil) != nil
        ? "powerplug.portrait" : "powerplug"

    /// First of `names` that actually renders on this OS; the last is the guaranteed fallback so
    /// `Image(systemName:)` is never blank.
    static func first(_ names: String...) -> String {
        for name in names where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        return names.last ?? ""
    }

    /// Regular AirPods glyph: the two-earbud "airpods.gen3" where available, else the classic "airpods".
    static let airpods: String = first("airpods.gen3", "airpods")

    /// Best earbud glyph for a device name: AirPods Pro and Max keep their own symbol; everything
    /// else (plain AirPods and the combined pair) uses the regular AirPods glyph — never a generic
    /// headphones icon.
    static func earbuds(for name: String) -> String {
        let t = name.lowercased()
        if t.contains("max") { return first("airpodsmax", "airpods.gen3", "airpods") }
        if t.contains("pro") { return first("airpodspro", "airpods.gen3", "airpods") }
        return airpods
    }

    /// Icon for a connected peripheral, routing AirPods (split, combined, or reported as one device)
    /// to the AirPods glyphs and leaving every other device its own symbol.
    static func symbol(for device: DeviceBattery) -> String {
        switch device.kind {
        case .earbuds: return earbuds(for: device.name)
        case .earbudLeft: return device.kind.symbol
        case .earbudRight: return device.kind.symbol
        case .headphones where device.name.lowercased().contains("airpod"): return earbuds(for: device.name)
        default: return device.kind.symbol
        }
    }
}
