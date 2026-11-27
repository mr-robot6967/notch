import AppKit
import Foundation

/// YouTube Music in a browser (or a browser-made web app): the system Now Playing has no like,
/// shuffle or repeat for it, so we press YouTube Music's own buttons in its tab through AppleScript
/// and read their state back. Browsers need "Allow JavaScript from Apple Events" turned on once
/// (View › Developer in Chromium browsers; Develop menu in Safari).
@MainActor
final class YTMusicBridge: ObservableObject {
    static let shared = YTMusicBridge()

    /// The song in the YouTube Music tab is liked.
    @Published private(set) var liked = false
    /// Repeat in MediaRemote numbering: 1 off, 2 one, 3 all.
    @Published private(set) var repeatMode = 1
    /// A YouTube Music tab was found in the playing browser.
    @Published private(set) var active = false
    /// Set when the browser refused to run the script (its setting is off), with where to turn it on.
    @Published private(set) var needsAppleEvents: String?

    // Constants, also read from the AppleScript queue: nonisolated so they aren't main-actor-bound.
    private nonisolated static let chromium: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "company.thebrowser.Browser": "Arc",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// Browser app for a Now Playing bundle (web apps like "com.google.Chrome.app.xyz" count).
    nonisolated static func browser(for bundle: String?) -> (app: String, safari: Bool)? {
        guard let bundle else { return nil }
        if bundle == "com.apple.Safari" { return ("Safari", true) }
        if let name = chromium[bundle] { return (name, false) }
        if let base = chromium.keys.first(where: { bundle.hasPrefix($0 + ".app.") }), let name = chromium[base] { return (name, false) }
        return nil
    }

    // YouTube Music's player bar. Like state is the like renderer's `like-status` attribute;
    // repeat state is in the repeat button's title ("Repeat off / all / one").
    private nonisolated static let stateJS = "(function(){var b=document.querySelector('ytmusic-player-bar');if(!b)return '';var r=b.querySelector('.repeat');var l=b.querySelector('ytmusic-like-button-renderer');var t=r?((r.getAttribute('title')||r.getAttribute('aria-label')||'')+'').toLowerCase():'';return JSON.stringify({repeat:t.indexOf('one')>=0?2:(t.indexOf('all')>=0?3:1),like:l?(l.getAttribute('like-status')||''):''});})()"
    private nonisolated static let likeJS = "(function(){var l=document.querySelector('ytmusic-player-bar ytmusic-like-button-renderer');if(!l)return '';var b=l.querySelector('#button-shape-like button')||l.querySelector('[aria-label=\"Like\"]')||l.querySelector('button');if(b){b.click();return 'ok';}return '';})()"
    private nonisolated static let shuffleJS = "(function(){var b=document.querySelector('ytmusic-player-bar .shuffle');if(b){b.click();return 'ok';}return '';})()"
    private nonisolated static let repeatJS = "(function(){var b=document.querySelector('ytmusic-player-bar .repeat');if(b){b.click();return 'ok';}return '';})()"

    /// Runs `js` in the first music.youtube.com tab. Returns (result, error message).
    private nonisolated static func run(_ js: String, in browser: (app: String, safari: Bool)) -> (String?, String?) {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let action = browser.safari ? "do JavaScript \"\(escaped)\" in t" : "execute t javascript \"\(escaped)\""
        // `is running` is checked inside the script as well: the browser may have quit since the
        // caller looked, and a bare `tell application` would launch it again.
        let source = """
        if application "\(browser.app)" is running then
            tell application "\(browser.app)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "music.youtube.com" then return \(action)
                    end repeat
                end repeat
            end tell
        end if
        return "__none__"
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -1743: Notch isn't allowed to control the browser (Automation) — not the JavaScript setting.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { return (nil, "automation-denied") }
            return (nil, (error[NSAppleScript.errorMessage] as? String) ?? "error")
        }
        let value = result?.stringValue
        return (value == "__none__" ? nil : value, nil)
    }

    private func currentBrowser() -> (app: String, safari: Bool)? {
        let bundle = MediaController.shared.info?.bundleIdentifier
        guard let browser = Self.browser(for: bundle), let bundle,
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return nil }
        return browser
    }

    private func perform(_ js: String) {
        guard let browser = currentBrowser() else { return }
        appleScriptQueue.async {
            let (_, error) = Self.run(js, in: browser)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    YTMusicBridge.shared.noteError(error, browser: browser)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { YTMusicBridge.shared.refresh() }
                }
            }
        }
    }

    private func noteError(_ error: String?, browser: (app: String, safari: Bool)) {
        guard let error else { needsAppleEvents = nil; return }
        if error == "automation-denied" {
            needsAppleEvents = "Allow Notch to control \(browser.app) in System Settings › Privacy & Security › Automation."
        } else if error.localizedCaseInsensitiveContains("javascript") || error.localizedCaseInsensitiveContains("apple event") {
            needsAppleEvents = browser.safari
                ? "In Safari, turn on Develop › Allow JavaScript from Apple Events."
                : "In \(browser.app), turn on View › Developer › Allow JavaScript from Apple Events."
        }
    }

    /// Reads like/repeat from the YouTube Music tab (on song change, island open, after actions).
    func refresh() {
        guard let browser = currentBrowser() else { active = false; return }
        appleScriptQueue.async {
            let (value, error) = Self.run(Self.stateJS, in: browser)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let bridge = YTMusicBridge.shared
                    bridge.noteError(error, browser: browser)
                    guard let value, let data = value.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        bridge.active = false
                        return
                    }
                    bridge.active = true
                    bridge.liked = (json["like"] as? String) == "LIKE"
                    bridge.repeatMode = json["repeat"] as? Int ?? 1
                    MediaController.shared.applyYouTubeModes(repeatMode: bridge.repeatMode)
                }
            }
        }
    }

    func toggleLike() {
        liked.toggle() // instant feedback; the refresh corrects it
        perform(Self.likeJS)
    }

    func shuffle() { perform(Self.shuffleJS) }

    func cycleRepeat() {
        // YouTube Music cycles Off → All → One → Off.
        repeatMode = repeatMode == 1 ? 3 : (repeatMode == 3 ? 2 : 1)
        MediaController.shared.applyYouTubeModes(repeatMode: repeatMode)
        perform(Self.repeatJS)
    }
}
