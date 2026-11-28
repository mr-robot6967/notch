import AppKit
import ApplicationServices
import Combine
import Foundation

/// A streaming service we can show in the island: a display name and an SF Symbol.
struct WatchingService: Equatable {
    let name: String
    let symbol: String
}

/// "Now Watching": shows what the user is watching in a browser (Netflix, Prime Video, Disney+,
/// YouTube, Hotstar…) or a streaming desktop app, the same way Now Playing works for music.
///
/// Streaming sites mostly don't publish the show/episode title to the system — macOS Now Playing
/// shows just the service (e.g. "Netflix"). YouTube is the exception: its Now Playing title IS the
/// video title. So detection is layered, best-effort, and degrades gracefully:
///
///   1. Baseline (every browser/app, no setup): the current Now Playing source is a browser or a
///      known streaming app → we're "watching". The service is read from the Now Playing app
///      name/title. YouTube's title is the video title and is used directly.
///   2. Window title via Accessibility (every browser, no per-browser setting; Notch already holds
///      Accessibility): read the browser's focused-window title and strip the trailing service
///      suffix (" - Netflix", " | Prime Video"…). Used when it beats the bare service name.
///   3. Exact title bridge (opt-in, Safari/Chrome/Brave/Edge with "Allow JavaScript from Apple
///      Events"): read the real title from the player DOM for Netflix/Prime/Disney+. Mirrors
///      YTMusicBridge's AppleScript/JS plumbing. If JS is off or unsupported, falls through to 2→1.
///
/// Best title wins: layer 3 > layer 2 (if better than the service name) > layer 1. It never
/// launches a browser (every script checks `is running`), and it stays off when music is the
/// source — the music Now Playing UI handles that.
@MainActor
final class WatchingDetector: ObservableObject {
    static let shared = WatchingDetector()

    /// A video source (browser or streaming app) is the current Now Playing source.
    @Published private(set) var isWatching = false
    /// The service being watched (name + SF Symbol); `generic` when it can't be identified.
    @Published private(set) var service: WatchingService = WatchingDetector.generic
    /// The best title we have: the show/episode/movie, or the service name as a fallback.
    @Published private(set) var title: String = ""
    /// The browser (or app) the video is in, for the expanded island.
    @Published private(set) var browserName: String?
    /// Set when a supported browser refused the exact-title script (its JS/Automation setting is
    /// off), with where to turn it on — mirrors YTMusicBridge.
    @Published private(set) var needsAppleEvents: String?

    /// True when `title` is the show/episode and not just the bare service name.
    var hasDistinctTitle: Bool {
        !title.isEmpty && title.caseInsensitiveCompare(service.name) != .orderedSame
    }

    private var cancellables = Set<AnyCancellable>()
    private var pollScheduled = false

    static let generic = WatchingService(name: "Browser video", symbol: "play.tv.fill")

    // Music sources are handled by the music Now Playing UI, never by this feature.
    private nonisolated static let musicBundles: Set<String> = [
        "com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.apple.iTunes",
    ]

    /// Browsers we treat as a video source. Firefox and DuckDuckGo are included for the baseline and
    /// the window-title layer; the exact-title bridge (YTMusicBridge.browser) covers only the
    /// scriptable ones (Safari/Chrome/Brave/Edge/Arc/Vivaldi).
    private nonisolated static let browserBundles: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.brave.Browser.beta",
        "com.brave.Browser.nightly", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.operasoftware.OperaGX", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.duckduckgo.macos.browser", "com.duckduckgo.mobile.ios", "org.chromium.Chromium", "app.zen-browser.zen",
    ]

    /// Known streaming desktop apps (not browsers) that count as watching.
    private nonisolated static let streamingApps: [String: WatchingService] = [
        "com.apple.TV": WatchingService(name: "Apple TV", symbol: "appletv.fill"),
        "com.netflix.Netflix": WatchingService(name: "Netflix", symbol: "play.tv.fill"),
    ]

    /// Trailing names stripped from a window title (services and browsers), longest first so
    /// "Amazon Prime Video" is matched before "Prime Video".
    private nonisolated static let trailingNames: [String] = [
        "Amazon Prime Video", "Disney+ Hotstar", "JioHotstar", "Prime Video", "Disney Plus", "Disney+",
        "YouTube Music", "Netflix", "Hotstar", "YouTube", "HBO Max", "Apple TV+", "Apple TV", "Paramount+",
        "Peacock", "Hulu", "Max", "HBO",
        "Google Chrome", "Microsoft Edge", "Mozilla Firefox", "Chromium", "Chrome", "Brave", "Safari",
        "Firefox", "Vivaldi", "Opera", "DuckDuckGo", "Arc",
    ].sorted { $0.count > $1.count }

    private nonisolated static func isBrowser(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        if browserBundles.contains(bundle) { return true }
        // Chromium/Safari web apps, e.g. "com.google.Chrome.app.xyz".
        return browserBundles.contains { bundle.hasPrefix($0 + ".app.") }
    }

    private func isMusicSource(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        if Self.musicBundles.contains(bundle) { return true }
        // YouTube Music in a browser: the music UI (and YTMusicBridge) owns it.
        return YTMusicBridge.browser(for: bundle) != nil && YTMusicBridge.shared.active
    }

    /// First recognised service named anywhere in `text` (an app name, title, window title or URL),
    /// in priority order. Nil when none match.
    nonisolated static func detectService(in text: String) -> WatchingService? {
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }
        if t.contains("netflix") { return WatchingService(name: "Netflix", symbol: "play.tv.fill") }
        if t.contains("hotstar") { return WatchingService(name: "Hotstar", symbol: "play.tv.fill") }
        if t.contains("disney") { return WatchingService(name: "Disney+", symbol: "sparkles.tv.fill") }
        if t.contains("prime video") || t.contains("primevideo") { return WatchingService(name: "Prime Video", symbol: "film.fill") }
        if t.contains("hbomax") || t.contains("hbo") { return WatchingService(name: "Max", symbol: "play.tv.fill") }
        if t.contains("youtube") { return WatchingService(name: "YouTube", symbol: "play.rectangle.fill") }
        if t.contains("apple tv") || t.contains("tv+") { return WatchingService(name: "Apple TV", symbol: "appletv.fill") }
        return nil
    }

    /// The host substring and player-title JS for the exact-title bridge (layer 3). Only the three
    /// services the task asks for; everything else falls through to layers 2 then 1.
    private nonisolated static func bridge(for service: WatchingService) -> (host: String, js: String)? {
        switch service.name {
        case "Netflix":
            return ("netflix.com",
                "(function(){var e=document.querySelector('[data-uia=video-title]');if(e&&e.innerText)return e.innerText.replace(/\\n+/g,' ').trim();var h=document.querySelector('.ellipsize-text h4,.video-title h4');if(h&&h.innerText)return h.innerText.trim();return '';})()")
        case "Prime Video":
            return ("primevideo.com",
                "(function(){var e=document.querySelector('.atvwebplayersdk-title-text')||document.querySelector('h1[data-automation-id=title]');if(e&&e.innerText)return e.innerText.trim();return '';})()")
        case "Disney+":
            return ("disneyplus.com",
                "(function(){var e=document.querySelector('[data-testid=player-title]')||document.querySelector('.title-field');if(e&&e.innerText)return e.innerText.trim();return '';})()")
        default:
            return nil
        }
    }

    /// Strips trailing service/browser suffixes (and a leading YouTube "(3) " unread count) from a
    /// window title. Returns nil when nothing useful is left.
    nonisolated static func strip(windowTitle raw: String) -> String? {
        var t = raw.replacingOccurrences(of: "\u{200e}", with: "").replacingOccurrences(of: "\u{200f}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        var changed = true
        while changed {
            changed = false
            let lower = t.lowercased()
            for name in trailingNames {
                for sep in ["—", "-", "|", "·", ":", "•"] {
                    let suffix = " \(sep) \(name)"
                    if lower.hasSuffix(suffix.lowercased()) {
                        t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        changed = true
                        break
                    }
                }
                if changed { break }
            }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private nonisolated static func browserDisplayName(_ bundle: String?) -> String? {
        guard let bundle else { return nil }
        if let b = YTMusicBridge.browser(for: bundle) { return b.app }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
    }

    // MARK: Lifecycle

    func start() {
        guard cancellables.isEmpty else { return }
        // Re-evaluate whenever Now Playing changes (source, title) or the toggle flips.
        MediaController.shared.$info
            .receive(on: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { WatchingDetector.shared.evaluate() } }
            .store(in: &cancellables)
        AppSettings.shared.$config
            .map(\.watchingEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { WatchingDetector.shared.evaluate() } }
            .store(in: &cancellables)
        // Switching apps changes whether the browser is in front, which decides if a paused video
        // keeps its logo — re-check on every app activation/deactivation.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification))
            .receive(on: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { WatchingDetector.shared.evaluate() } }
            .store(in: &cancellables)
        evaluate()
    }

    // MARK: Layer 1 (baseline)

    private func evaluate() {
        guard AppSettings.shared.config.watchingEnabled else { stopWatching(); return }
        let media = MediaController.shared
        guard let info = media.info else { stopWatching(); return }
        let bundle = info.bundleIdentifier
        guard !isMusicSource(bundle) else { stopWatching(); return }

        let combined = [info.appName, info.title].compactMap { $0 }.joined(separator: " ")
        let streaming = Self.streamingApps[bundle ?? ""]
        // A video source: a known streaming app, a recognised service in the title/appName (this
        // catches browsers that report media through a generic process, e.g. DuckDuckGo via
        // "com.apple.WebKit.GPU"), or any known browser.
        guard let detected = streaming ?? Self.detectService(in: combined)
                ?? (Self.isBrowser(bundle) ? Self.generic : nil) else { stopWatching(); return }
        // Keep the logo while it plays, OR while paused but the browser/streaming app is still in
        // front (you're browsing Netflix) — clear once you switch to another app. Music is never
        // handled here, so its "idle a few seconds after pause" behaviour is unchanged.
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontIsViewer = Self.isBrowser(frontBundle) || Self.streamingApps[frontBundle ?? ""] != nil
        guard info.isPlaying || frontIsViewer else { stopWatching(); return }
        let serviceChanged = detected != service
        let wasWatching = isWatching

        service = detected
        browserName = streaming != nil ? detected.name : Self.browserDisplayName(bundle)

        // Layer-1 title: the Now Playing title when it's distinct from the service (YouTube reports
        // the video title here); otherwise the service name until layers 2/3 refine it.
        if !wasWatching || serviceChanged {
            let np = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = (!np.isEmpty && np.caseInsensitiveCompare(detected.name) != .orderedSame) ? np : detected.name
        }

        isWatching = true
        if !wasWatching { needsAppleEvents = nil }
        refresh()        // immediate layers 2/3 pass
        startPolling()   // then at most every ~2 s while watching
    }

    private func stopWatching() {
        if isWatching { isWatching = false }
        // The poll loop notices isWatching == false and stops itself (no CPU while idle).
    }

    // MARK: Layers 2 & 3 (window title / exact-title bridge), polled while watching

    private func startPolling() {
        guard !pollScheduled else { return }
        pollScheduled = true
        scheduleNextPoll()
    }

    private func scheduleNextPoll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard self.isWatching else { self.pollScheduled = false; return }
            self.refresh()
            self.scheduleNextPoll()
        }
    }

    /// Reads the window title (layer 2) and, for supported browsers/services, the player DOM title
    /// (layer 3) off the main thread, then picks the best title.
    private func refresh() {
        guard isWatching, let bundle = MediaController.shared.info?.bundleIdentifier else { return }
        let scriptable = YTMusicBridge.browser(for: bundle)
        let currentService = service
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
        let axPermitted = AXIsProcessTrusted()

        appleScriptQueue.async {
            // Layer 2: the browser's focused-window title through Accessibility.
            var windowTitle: String?
            if axPermitted, let pid { windowTitle = Self.axWindowTitle(pid: pid) }
            let windowService = windowTitle.flatMap { Self.detectService(in: $0) }
            let strippedTitle = windowTitle.flatMap { Self.strip(windowTitle: $0) }

            // Layer 3: exact title from the player DOM (opt-in, scriptable browsers only).
            var exactTitle: String?
            var scriptError: String?
            let serviceForBridge = windowService ?? currentService
            if let scriptable, let bridge = Self.bridge(for: serviceForBridge) {
                let (value, error) = Self.runBridge(bridge.js, host: bridge.host, in: scriptable)
                scriptError = error
                if let value, !value.isEmpty { exactTitle = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let d = WatchingDetector.shared
                    guard d.isWatching else { return }
                    d.noteError(scriptError, browser: scriptable)
                    // A more specific service from the window title wins over a generic guess.
                    if let windowService { d.service = windowService }
                    let svc = d.service.name

                    func better(_ candidate: String?) -> String? {
                        guard let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty,
                              c.caseInsensitiveCompare(svc) != .orderedSame else { return nil }
                        return c
                    }
                    // layer 3 > layer 2 > layer 1 (keep the existing layer-1 title otherwise).
                    if let best = better(exactTitle) ?? better(strippedTitle) {
                        d.title = best
                    } else if d.title.isEmpty {
                        d.title = svc
                    }
                }
            }
        }
    }

    /// The browser's focused-window title (falling back to its first window) via the AX API.
    /// Defensive: nil whenever an attribute is missing or the wrong type.
    private nonisolated static func axWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
            return ref as? String
        }
        func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement)
        }
        if let window = element(app, "AXFocusedWindow"), let title = string(window, "AXTitle"),
           !title.isEmpty { return title }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &ref) == .success,
           let windows = ref as? [AXUIElement] {
            for window in windows {
                if let title = string(window, "AXTitle"), !title.isEmpty { return title }
            }
        }
        return nil
    }

    /// Runs `js` in the first tab whose URL contains `host`. Mirrors YTMusicBridge.run, including the
    /// "is running" guard (never launches the browser) and -1743 / JavaScript-off handling.
    private nonisolated static func runBridge(_ js: String, host: String, in browser: (app: String, safari: Bool)) -> (String?, String?) {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let action = browser.safari ? "do JavaScript \"\(escaped)\" in t" : "execute t javascript \"\(escaped)\""
        let source = """
        if application "\(browser.app)" is running then
            tell application "\(browser.app)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "\(host)" then return \(action)
                    end repeat
                end repeat
            end tell
        end if
        return "__none__"
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { return (nil, "automation-denied") }
            return (nil, (error[NSAppleScript.errorMessage] as? String) ?? "error")
        }
        let value = result?.stringValue
        return (value == "__none__" ? nil : value, nil)
    }

    private func noteError(_ error: String?, browser: (app: String, safari: Bool)?) {
        guard let error, let browser else { needsAppleEvents = nil; return }
        if error == "automation-denied" {
            needsAppleEvents = "Allow Notch to control \(browser.app) in System Settings › Privacy & Security › Automation."
        } else if error.localizedCaseInsensitiveContains("javascript") || error.localizedCaseInsensitiveContains("apple event") {
            needsAppleEvents = browser.safari
                ? "In Safari, turn on Settings › Developer › Allow JavaScript from Apple Events."
                : "In \(browser.app), turn on View › Developer › Allow JavaScript from Apple Events."
        }
    }
}
