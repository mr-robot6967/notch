import AppKit
import Combine
import OSLog
import SwiftUI

private let mediaLog = Logger(subsystem: "com.k2a.LockWidgets", category: "media")

/// NSAppleScript is not thread-safe: every script in the app (player fallback, Messages replies)
/// runs on this one serial queue — never two at once, and never blocking the main thread.
let appleScriptQueue = DispatchQueue(label: "LockWidgets.applescript", qos: .userInitiated)

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var duration: Double      // seconds (0 if unknown, e.g. live streams)
    var elapsed: Double       // seconds, at `elapsedDate`
    var elapsedDate: Date
    var rate: Double
    var bundleIdentifier: String?
    var appName: String?
    /// MediaRemote modes: shuffle 1 = off, >1 = on; repeat 1 = off, 2 = one, 3 = all (0 = unknown).
    var shuffleMode: Int = 0
    var repeatMode: Int = 0

    var shuffleOn: Bool { shuffleMode > 1 }
    var repeatOn: Bool { repeatMode > 1 }

    /// Title without extras like "(From …)", "(feat. …)", "- Remastered 2011" (Settings › Island).
    @MainActor var displayTitle: String {
        guard AppSettings.shared.config.cleanSongTitles else { return title }
        return NowPlayingInfo.clean(title)
    }

    static func clean(_ title: String) -> String {
        var t = title
        let patterns = [
            #"\s*[\(\[](from|feat\.?|ft\.?|with|prod\.?)[^\)\]]*[\)\]]"#,
            #"\s*[\(\[][^\)\]]*(remaster|version|edit|mix|live|mono|stereo|deluxe|bonus)[^\)\]]*[\)\]]"#,
            #"\s+-\s+[^-]*(remaster|version|edit|mix|live|mono|stereo)[^-]*$"#,
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }

    /// Players where "Like" works: Spotify (with the Spotify connection) and Apple's own apps.
    @MainActor var canLike: Bool {
        switch bundleIdentifier {
        case "com.spotify.client": return SpotifyClient.shared.connected
        case "com.apple.Music", "com.apple.podcasts": return true
        default:
            // YouTube Music in a browser: like through its own button (see YTMusicBridge).
            return YTMusicBridge.browser(for: bundleIdentifier) != nil && YTMusicBridge.shared.active
        }
    }

    /// Playback position now, extrapolated while playing (no polling needed).
    func currentPosition(at date: Date = Date()) -> Double {
        // Clamped while paused too: a player can report elapsed past the end (or < 0), which made the
        // progress bar wider than its track or gave it a negative width.
        let p = !isPlaying ? elapsed : elapsed + date.timeIntervalSince(elapsedDate) * (rate > 0 ? rate : 1)
        return duration > 0 ? min(duration, max(0, p)) : max(0, p)
    }

    var appIcon: NSImage? {
        guard let id = bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// System-wide Now Playing — whatever Control Center shows: Spotify, Apple Music, YouTube Music or
/// any site in a browser, Podcasts, VLC…
///
/// Primary source: a small bundled helper loaded into Apple's /usr/bin/perl (Helpers/mediaremote),
/// because macOS 15.4+ only lets Apple-signed processes read MediaRemote. It streams JSON lines and
/// takes commands on stdin. Fallback (if the helper can't run): Music/Spotify notifications +
/// AppleScript controls.
@MainActor
final class MediaController: ObservableObject {
    static let shared = MediaController()

    @Published private(set) var info: NowPlayingInfo? { didSet { updatePauseClock() } }
    /// When playback stopped (nil while playing or with no song). The collapsed island keeps a
    /// paused song for `pausedGrace` seconds, then shows its idle content; the open island keeps
    /// the player so the song can still be resumed.
    @Published private(set) var pausedSince: Date?
    static let pausedGrace: TimeInterval = 3
    private var pauseExpiry: DispatchWorkItem?

    /// The collapsed island should still show the current song (playing, or paused < `pausedGrace`).
    var songIsRecent: Bool {
        guard let info else { return false }
        if info.isPlaying { return true }
        guard let pausedSince else { return false }
        return Date().timeIntervalSince(pausedSince) < Self.pausedGrace
    }

    private func updatePauseClock() {
        guard let info, !info.isPlaying else {
            // Playing again (or nothing at all): the pause is over.
            pauseExpiry?.cancel()
            pauseExpiry = nil
            if pausedSince != nil { pausedSince = nil }
            return
        }
        guard pausedSince == nil else { return } // already counting this pause
        pausedSince = Date()
        // One timer per pause (no polling): when the grace ends, republish so the island re-reads
        // `songIsRecent` and morphs to its idle content.
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let media = MediaController.shared
                media.pauseExpiry = nil
                withAnimation(IslandMotion.activity) { media.objectWillChange.send() }
            }
        }
        pauseExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pausedGrace + 0.05, execute: work)
    }

    /// AppleScript for Spotify/Music that does nothing unless the app is already running: a bare
    /// `tell application` launches it (e.g. pressing play after quitting it, or a race with quitting).
    nonisolated static func ifRunning(_ app: String, _ body: String) -> String {
        """
        if application "\(app)" is running then
            tell application "\(app)"
                \(body)
            end tell
        end if
        """
    }
    @Published private(set) var artwork: NSImage?
    /// Dominant colour of the artwork, used as an accent in the player.
    @Published private(set) var artworkColor: Color = .white
    @Published private(set) var usingHelper = false

    private var helper: Process?
    private var helperInput: FileHandle?
    private var buffer = Data()
    private var helperFailures = 0
    private var helperStartedAt = Date()
    private var fallbackCancellables = Set<AnyCancellable>()
    private var scriptQueue: DispatchQueue { appleScriptQueue }
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        if !startHelper() { startFallback() }
        // MediaRemote can drop a client's registration while the Mac sleeps (mediaremoted restarts),
        // leaving the player frozen on whatever was playing. Ask the helper to re-register and
        // re-read after wake/unlock; if it had given up and we're on the fallback, try it again.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MediaController.shared.refreshAfterWake() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MediaController.shared.refreshAfterWake() }
        }
    }

    private func refreshAfterWake() {
        if usingHelper {
            send("refresh")
        } else if helper == nil {
            // After repeated failures a slow retry (up to 10 min) is pending; wake/unlock is exactly
            // when mediaremoted is back, so retry now instead of waiting for it.
            helperRetry?.cancel()
            helperRetry = nil
            helperFailures = 0
            _ = startHelper()
        }
    }

    private var helperRetry: DispatchWorkItem?

    // MARK: Controls

    func playPause() { command("toggle", script: "playpause") }
    /// Bumped on every skip (button, key, swipe) so the skip buttons can animate even if the
    /// player view is rebuilt as the track changes.
    @Published private(set) var skipForwardCount = 0
    @Published private(set) var skipBackCount = 0
    private var clearWork: DispatchWorkItem?

    func next() { skipForwardCount += 1; command("next", script: "next track") }
    func previous() { skipBackCount += 1; command("previous", script: "previous track") }
    // Spotify and Music don't report shuffle/repeat to the system Now Playing, and ignore its
    // shuffle/repeat commands — so the buttons read "off" and did nothing. Both apps expose these
    // through AppleScript, which is what we use for them (only while the app is already running).
    // Modes use MediaRemote's numbering: shuffle 1 off / 2 on; repeat 1 off / 2 one / 3 all.
    private var appModes: (bundle: String, shuffle: Int, repeat: Int)?

    private static let scriptablePlayers: [String: String] = ["com.spotify.client": "Spotify", "com.apple.Music": "Music"]

    private func scriptablePlayer() -> (bundle: String, app: String)? {
        guard let bundle = info?.bundleIdentifier, let app = Self.scriptablePlayers[bundle],
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return nil }
        return (bundle, app)
    }

    /// Reads the real shuffle/repeat state from Spotify/Music and shows it on the buttons.
    func refreshAppModes() {
        guard let player = scriptablePlayer() else { return }
        if player.app == "Spotify", SpotifyClient.shared.connected {
            Task { @MainActor in
                guard let modes = await SpotifyClient.shared.playbackModes() else { return }
                let shuffle = modes.shuffle ? 2 : 1
                let repeatMode = modes.repeatState == "track" ? 2 : (modes.repeatState == "context" ? 3 : 1)
                self.appModes = (player.bundle, shuffle, repeatMode)
                if var current = self.info, current.bundleIdentifier == player.bundle {
                    current.shuffleMode = shuffle
                    current.repeatMode = repeatMode
                    self.info = current
                }
            }
            return
        }
        let source = player.app == "Spotify"
            ? Self.ifRunning("Spotify", "return {shuffling, repeating}")
            : Self.ifRunning("Music", "return {shuffle enabled, (song repeat as string)}")
        appleScriptQueue.async {
            var error: NSDictionary?
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil,
                  result.numberOfItems >= 2,
                  let first = result.atIndex(1), let second = result.atIndex(2) else { return }
            let shuffle = first.booleanValue ? 2 : 1
            let repeatMode: Int
            if player.app == "Spotify" {
                repeatMode = second.booleanValue ? 3 : 1
            } else {
                switch second.stringValue ?? "off" { case "one": repeatMode = 2; case "all": repeatMode = 3; default: repeatMode = 1 }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let media = MediaController.shared
                    media.appModes = (player.bundle, shuffle, repeatMode)
                    if var current = media.info, current.bundleIdentifier == player.bundle {
                        current.shuffleMode = shuffle
                        current.repeatMode = repeatMode
                        media.info = current
                    }
                }
            }
        }
    }

    private func runPlayerScript(_ source: String) {
        appleScriptQueue.async {
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { MediaController.shared.refreshAppModes() }
            }
        }
    }

    /// Repeat state read from the YouTube Music tab, shown on the button.
    func applyYouTubeModes(repeatMode: Int) {
        guard var current = info, YTMusicBridge.browser(for: current.bundleIdentifier) != nil else { return }
        current.repeatMode = repeatMode
        info = current
    }

    private var isYouTubeMusic: Bool {
        YTMusicBridge.browser(for: info?.bundleIdentifier) != nil && YTMusicBridge.shared.active
    }

    func toggleShuffle() {
        if isYouTubeMusic { YTMusicBridge.shared.shuffle(); return }
        if let player = scriptablePlayer(), player.app == "Spotify", SpotifyClient.shared.connected {
            let turnOn = !(info?.shuffleOn ?? false)
            if var current = info { current.shuffleMode = turnOn ? 2 : 1; info = current }
            Task { @MainActor in
                await SpotifyClient.shared.setShuffle(turnOn)
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.refreshAppModes()
            }
            return
        }
        if let player = scriptablePlayer() {
            if var current = info { current.shuffleMode = current.shuffleOn ? 1 : 2; info = current }
            runPlayerScript(player.app == "Spotify"
                ? Self.ifRunning("Spotify", "set shuffling to not shuffling")
                : Self.ifRunning("Music", "set shuffle enabled to not shuffle enabled"))
            return
        }
        guard usingHelper else { return }
        send("shuffle")
        if var current = info { current.shuffleMode = current.shuffleOn ? 1 : 2; info = current }
    }

    func toggleRepeat() {
        if isYouTubeMusic { YTMusicBridge.shared.cycleRepeat(); return }
        if let player = scriptablePlayer(), player.app == "Spotify", SpotifyClient.shared.connected {
            // Spotify cycles Off → All (context) → One (track) → Off.
            let mode = info?.repeatMode ?? 1
            let next = mode == 1 ? 3 : (mode == 3 ? 2 : 1)
            if var current = info { current.repeatMode = next; info = current }
            Task { @MainActor in
                await SpotifyClient.shared.setRepeat(next == 3 ? "context" : (next == 2 ? "track" : "off"))
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.refreshAppModes()
            }
            return
        }
        if let player = scriptablePlayer() {
            if player.app == "Spotify" {
                if var current = info { current.repeatMode = current.repeatOn ? 1 : 3; info = current }
                runPlayerScript(Self.ifRunning("Spotify", "set repeating to not repeating"))
            } else {
                // Music cycles Off → All → One → Off, like its own button.
                if var current = info { current.repeatMode = current.repeatMode == 3 ? 2 : (current.repeatMode == 2 ? 1 : 3); info = current }
                runPlayerScript(Self.ifRunning("Music", """
                    if song repeat is off then
                        set song repeat to all
                    else if song repeat is all then
                        set song repeat to one
                    else
                        set song repeat to off
                    end if
                    """))
            }
            return
        }
        guard usingHelper else { return }
        send("repeat")
        if var current = info { current.repeatMode = current.repeatOn ? 1 : 3; info = current }
    }

    /// Like / favourite the current track (works for players that support it, e.g. Music).
    func like() {
        if info?.bundleIdentifier == "com.spotify.client", SpotifyClient.shared.connected {
            Task { await SpotifyClient.shared.toggleLike() }
        } else if isYouTubeMusic {
            YTMusicBridge.shared.toggleLike()
        } else if usingHelper {
            send("like")
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func seek(to seconds: Double) {
        guard usingHelper, var current = info else { return }
        send("seek \(seconds)")
        current.elapsed = seconds
        current.elapsedDate = Date()
        info = current
    }

    private func command(_ helperCommand: String, script: String) {
        if usingHelper {
            send(helperCommand)
            // Optimistic UI for play/pause; the helper confirms a moment later.
            if helperCommand == "toggle", var current = info {
                current.elapsed = current.currentPosition()
                current.elapsedDate = Date()
                current.isPlaying.toggle()
                info = current
            }
        } else if let app = fallbackApp {
            let source = Self.ifRunning(app, script)
            scriptQueue.async { _ = Self.runScript(source) }
        }
    }

    // MARK: Helper

    private func startHelper() -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let script = resources.appendingPathComponent("lwmr.pl")
        let bundled = resources.appendingPathComponent("LWMediaRemote.dylib")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: bundled.path) else {
            mediaLog.notice("Now Playing helper not bundled; using fallback")
            return false
        }
        let dylib = Self.loadableHelper(bundled)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, dylib.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil // EOF: stop, or this would spin forever
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MediaController.shared.receive(data) }
            }
        }
        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MediaController.shared.helperExited(status: proc.terminationStatus) }
            }
        }
        do {
            try process.run()
        } catch {
            mediaLog.error("Could not start Now Playing helper: \(error.localizedDescription, privacy: .public)")
            return false
        }
        helper = process
        helperInput = input.fileHandleForWriting
        // Never die from SIGPIPE if the helper exits while we're writing a command.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        usingHelper = true
        helperStartedAt = Date()
        mediaLog.notice("Now Playing helper started (pid \(process.processIdentifier))")
        return true
    }

    /// An app downloaded from the internet carries a quarantine flag on every file, and macOS
    /// refuses to load a quarantined dylib that isn't notarised into /usr/bin/perl ("library load
    /// disallowed by system policy"), so Now Playing would silently fall back to Music/Spotify only.
    /// In that case load an unflagged copy from Application Support instead (written with
    /// Data.write, which doesn't carry the extended attribute over). Any failure → the bundled
    /// file, and the AppleScript fallback still covers Music and Spotify.
    private static func loadableHelper(_ bundled: URL) -> URL {
        guard getxattr(bundled.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 else { return bundled }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: bundled) else { return bundled }
        let dir = support.appendingPathComponent("Notch", isDirectory: true)
        let copy = dir.appendingPathComponent("LWMediaRemote.dylib")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? Data(contentsOf: copy)) != data { try data.write(to: copy, options: .atomic) }
            // Never pass on a flag the copy might have picked up.
            removexattr(copy.path, "com.apple.quarantine", 0)
            return copy
        } catch {
            mediaLog.error("Could not stage Now Playing helper: \(error.localizedDescription, privacy: .public)")
            return bundled
        }
    }

    private func send(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? helperInput?.write(contentsOf: data)
    }

    private func helperExited(status: Int32) {
        helper = nil
        helperInput = nil
        usingHelper = false
        buffer.removeAll()
        // A restart (e.g. after sleep) takes ~3 s and the new helper reports the same track at once;
        // clearing straight away made the player vanish and reappear. Clear only if nothing comes back.
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return } // (any message from a restarted helper cancels this)
            self.info = nil
            self.setArtwork(nil)
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        // Only count quick crashes; a helper that ran for a while (e.g. until sleep) resets the count.
        if Date().timeIntervalSince(helperStartedAt) > 120 { helperFailures = 0 }
        helperFailures += 1
        mediaLog.error("Now Playing helper exited (status \(status)); failures=\(self.helperFailures)")
        // Retry quickly a couple of times, then use the fallback meanwhile but keep retrying slowly:
        // three quick failures while mediaremoted was still starting after wake used to switch to
        // the Music/Spotify-only fallback for good, until relaunch.
        if helperFailures > 2 { startFallback() }
        let delay: TimeInterval = helperFailures <= 2 ? 3 : min(600, 30 * Double(helperFailures - 2))
        helperRetry?.cancel()
        let retry = DispatchWorkItem {
            MainActor.assumeIsolated {
                let media = MediaController.shared
                media.helperRetry = nil
                guard media.helper == nil else { return }
                if !media.startHelper() { media.startFallback() }
            }
        }
        helperRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handleHelper(object)
        }
    }

    private func handleHelper(_ o: [String: Any]) {
        guard o["type"] as? String == "nowPlaying" else { return }
        // The helper works again: stop the fallback, whose events would otherwise overwrite it.
        if !fallbackCancellables.isEmpty {
            fallbackCancellables.removeAll()
            fallbackApp = nil
            mediaLog.notice("Now Playing helper is back; fallback stopped")
        }
        if o["empty"] as? Bool == true {
            // Players report "nothing" for a moment between tracks; clearing at once made the player
            // (and its button animations) vanish and flash "Nothing playing". Clear only if it lasts.
            clearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.info = nil
                self.setArtwork(nil)
            }
            clearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            return
        }
        clearWork?.cancel()
        let timestamp = (o["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        var new = NowPlayingInfo(
            title: o["title"] as? String ?? "",
            artist: o["artist"] as? String ?? "",
            album: o["album"] as? String ?? "",
            isPlaying: o["playing"] as? Bool ?? false,
            duration: o["duration"] as? Double ?? 0,
            elapsed: o["elapsed"] as? Double ?? 0,
            elapsedDate: timestamp,
            rate: o["rate"] as? Double ?? 1,
            bundleIdentifier: o["bundleIdentifier"] as? String,
            appName: o["appName"] as? String,
            shuffleMode: o["shuffle"] as? Int ?? 0,
            repeatMode: o["repeat"] as? Int ?? 0
        )
        // The player didn't report shuffle/repeat (Spotify, Music): keep what AppleScript told us.
        if o["shuffle"] == nil, let modes = appModes, modes.bundle == new.bundleIdentifier {
            new.shuffleMode = modes.shuffle
            new.repeatMode = modes.repeat
        }
        let songChanged = new.title != info?.title || new.bundleIdentifier != info?.bundleIdentifier
        if new.title != info?.title || new.album != info?.album, o["artwork"] == nil, o["artworkCleared"] == nil {
            // New track; keep the old art until the new one arrives (it can lag a little).
        }
        // Song changed while playing → a short "peek" in the island showing the new track.
        if let old = info, old.title != new.title, new.isPlaying, !new.title.isEmpty,
           AppSettings.shared.config.songChangePeek, !NotchModel.shared.expanded {
            NotchModel.shared.flash(.songChange(title: new.displayTitle, artist: new.artist), seconds: 2.0)
        }
        if songChanged, YTMusicBridge.browser(for: new.bundleIdentifier) != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { YTMusicBridge.shared.refresh() }
            }
        }
        if songChanged, Self.scriptablePlayers[new.bundleIdentifier ?? ""] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { MediaController.shared.refreshAppModes() }
            }
        }
        // Starting/stopping changes the island's shape, so animate those changes.
        if info == nil || info?.isPlaying != new.isPlaying {
            withAnimation(IslandMotion.activity) { info = new }
        } else {
            info = new
        }
        if let base64 = o["artwork"] as? String, let data = Data(base64Encoded: base64) {
            setArtwork(NSImage(data: data))
        } else if o["artworkCleared"] as? Bool == true {
            setArtwork(nil)
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        artworkColor = image.flatMap(Self.dominantColor) ?? .white
    }

    /// Average colour of a tiny version of the artwork, brightened so it reads on black.
    private static func dominantColor(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(1, s * 1.2), brightness: max(0.75, b))
    }

    // MARK: Fallback (Music / Spotify only)

    private var fallbackApp: String?

    private func startFallback() {
        guard fallbackCancellables.isEmpty else { return }
        mediaLog.notice("Using Music/Spotify fallback for Now Playing")
        let dnc = DistributedNotificationCenter.default()
        dnc.publisher(for: Notification.Name("com.apple.Music.playerInfo"))
            .receive(on: RunLoop.main)
            .sink { MediaController.shared.handleFallback($0.userInfo, app: "Music", bundle: "com.apple.Music") }
            .store(in: &fallbackCancellables)
        dnc.publisher(for: Notification.Name("com.spotify.client.PlaybackStateChanged"))
            .receive(on: RunLoop.main)
            .sink { MediaController.shared.handleFallback($0.userInfo, app: "Spotify", bundle: "com.spotify.client") }
            .store(in: &fallbackCancellables)
    }

    private func handleFallback(_ userInfo: [AnyHashable: Any]?, app: String, bundle: String) {
        guard let u = userInfo else { return }
        let state = (u["Player State"] as? String ?? "").lowercased()
        if state == "stopped" {
            // Forget the app too, so later controls never address an app that has quit.
            if fallbackApp == app { info = nil; setArtwork(nil); fallbackApp = nil }
            return
        }
        fallbackApp = app
        let durationMS = (u["Total Time"] as? Double) ?? (u["Duration"] as? Double) ?? 0
        let changedTrack = (u["Name"] as? String) != info?.title
        info = NowPlayingInfo(title: u["Name"] as? String ?? "", artist: u["Artist"] as? String ?? "",
                              album: u["Album"] as? String ?? "", isPlaying: state == "playing",
                              duration: durationMS / 1000, elapsed: (u["Playback Position"] as? Double) ?? 0,
                              elapsedDate: Date(), rate: 1, bundleIdentifier: bundle, appName: app)
        if changedTrack { fetchFallbackArtwork(app: app) }
    }

    private func fetchFallbackArtwork(app: String) {
        scriptQueue.async {
            var image: NSImage?
            if app == "Music", let data = Self.runScript(Self.ifRunning("Music", "return data of artwork 1 of current track"))?.data {
                image = NSImage(data: data)
            } else if app == "Spotify",
                      let s = Self.runScript(Self.ifRunning("Spotify", "return artwork url of current track"))?.stringValue,
                      let url = URL(string: s), url.scheme == "https", let data = try? Data(contentsOf: url) {
                image = NSImage(data: data)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { MediaController.shared.setArtwork(image) } }
        }
    }

    nonisolated private static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    func stop() {
        helper?.terminate()
    }
}
