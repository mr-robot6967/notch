import AppKit
import CryptoKit
import Foundation

/// Checks GitHub for a newer Notch release and installs it in place.
///
/// - Check: one unauthenticated request to the GitHub releases API (daily when automatic checks
///   are on, or on demand). No account, no tracking.
/// - Install: downloads the release's Notch.dmg over HTTPS, mounts it read-only, verifies the app
///   inside (same bundle identifier, valid code signature, and the SHA-256 from the release notes
///   when one is listed), then swaps it in with a small helper script once Notch quits, and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "mr-robot6967/notch"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseNotes = ""
    @Published private(set) var lastChecked: Date?

    private var dmgURL: URL?
    private var expectedSHA: String?
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    /// Daily automatic checks (first one shortly after launch).
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.autoCheck() }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.autoCheck() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func autoCheck() {
        guard AppSettings.shared.config.autoCheckUpdates else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 20 * 3600 { return }
        check()
    }

    func check() {
        guard state != .checking, state != .downloading, state != .installing else { return }
        let previous = state
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notch-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        Task {
            let result = try? await URLSession.shared.data(for: request)
            guard let (data, response) = result, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                // A failed re-check (offline after wake) must not forget an update already found:
                // that cleared the menu-bar badge and the Update Now button until the next good check.
                if case .available = previous, self.dmgURL != nil {
                    self.state = previous
                } else {
                    self.state = .failed("Couldn't reach GitHub. Try again later.")
                }
                return
            }
            // Only a check that got an answer counts for the 20 h auto-check gate: stamping failures
            // too meant one offline launch (Wi-Fi not up yet 30 s after login) skipped a whole day.
            self.lastChecked = Date()
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            self.latestVersion = version
            self.releaseNotes = json["body"] as? String ?? ""
            self.expectedSHA = Self.sha256(in: self.releaseNotes)
            // Only this repo's own release downloads are accepted.
            let link = dmg?["browser_download_url"] as? String ?? ""
            self.dmgURL = link.hasPrefix("https://github.com/\(Self.repo)/releases/download/") ? URL(string: link) : nil
            if Self.isNewer(version, than: self.currentVersion), self.dmgURL != nil {
                self.state = .available(version: version)
            } else {
                self.state = .upToDate
            }
        }
    }

    /// "1.4.10" > "1.4.9".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A "SHA-256: <64 hex>" line in the release notes, if present. Anything may sit between the label
    /// and the hash on the same line (e.g. "SHA-256 checksum:"), so a wording change can't silently
    /// skip verification; the hash must be a whole 64-hex word.
    nonisolated static func sha256(in notes: String) -> String? {
        guard let range = notes.range(of: #"(?i)sha-?256[^\n]*?\b([0-9a-f]{64})\b"#, options: .regularExpression) else { return nil }
        let match = String(notes[range])
        return match.range(of: #"[0-9a-fA-F]{64}"#, options: .regularExpression).map { String(match[$0]).lowercased() }
    }

    /// Why Notch can't replace itself where it is, or nil when it can.
    nonisolated static func installBlocker(for path: String) -> String? {
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Move Notch to your Applications folder first, then update."
        }
        let folder = (path as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: folder) || !FileManager.default.isWritableFile(atPath: path) {
            return "Notch can't update itself here (no permission). Download the new version from GitHub instead."
        }
        return nil
    }

    var releasePage: URL { URL(string: "https://github.com/\(Self.repo)/releases/latest")! }

    func install() {
        guard case .available = state, let dmgURL else { return }
        if let blocker = Self.installBlocker(for: Bundle.main.bundleURL.path) {
            state = .failed(blocker)
            return
        }
        state = .downloading
        let expected = expectedSHA
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let installedPath = Bundle.main.bundleURL.path
        let tag = latestVersion ?? ""
        let current = currentVersion
        Task.detached(priority: .userInitiated) {
            // Runs codesign and waits for it, so off the main thread (it froze the UI for a moment).
            guard let requirement = Self.pinnedRequirement(of: installedPath) else {
                await MainActor.run {
                    Updater.shared.state = .failed("This copy of Notch isn't signed with a certificate, so it can't verify updates. Download the new version from GitHub instead.")
                }
                return
            }
            do {
                let (temp, response) = try await URLSession.shared.download(from: dmgURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Download failed.") }
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("NotchUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let dmg = work.appendingPathComponent("Notch.dmg")
                try FileManager.default.moveItem(at: temp, to: dmg)
                if let expected {
                    guard try Self.fileSHA256(dmg) == expected else { throw UpdateError.message("The download didn't match its checksum.") }
                }
                await MainActor.run { Updater.shared.state = .installing }
                let staged = try Self.stage(dmg: dmg, into: work, bundleID: bundleID, requirement: requirement,
                                            tag: tag, current: current)
                try Self.scheduleSwap(newApp: staged, installedPath: installedPath, work: work)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                let text = (error as? UpdateError).map { if case .message(let m) = $0 { return m } else { return "" } }
                    ?? "Update failed: \(error.localizedDescription)"
                await MainActor.run { Updater.shared.state = .failed(text) }
            }
        }
    }

    enum UpdateError: Error { case message(String) }

    /// Mounts the DMG read-only, copies Notch.app out, detaches, and checks the copy.
    /// The running app's designated requirement when it pins a certificate (e.g. `identifier "…" and
    /// certificate leaf = H"…"`). Ad-hoc builds pin only their own cdhash, which every new build
    /// changes, so they can't verify an update — nil then.
    nonisolated static func pinnedRequirement(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-r-", path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.contains("designated =>") }) else { return nil }
        let requirement = line.components(separatedBy: "designated =>").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return requirement.contains("certificate leaf") ? requirement : nil
    }

    /// SHA-256 of a file, read in chunks (no need to hold the whole DMG in memory).
    nonisolated static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mounts the DMG read-only, copies Notch.app out, detaches, and checks the copy: it must be a real
    /// Notch.app folder (not a symlink), signed by the same certificate as this Notch, intact, and the
    /// version the release says — newer than what's installed.
    nonisolated private static func stage(dmg: URL, into work: URL, bundleID: String, requirement: String,
                                          tag: String, current: String) throws -> URL {
        let mount = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) == 0 else {
            throw UpdateError.message("Couldn't open the downloaded update.")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let app = mount.appendingPathComponent("Notch.app")
        let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false else {
            throw UpdateError.message("The update doesn't contain Notch — not installed.")
        }
        let staged = work.appendingPathComponent("Notch.app")
        guard run("/usr/bin/ditto", [app.path, staged.path]) == 0 else { throw UpdateError.message("Couldn't copy the update.") }
        let bundle = Bundle(url: staged)
        guard bundle?.bundleIdentifier == bundleID else { throw UpdateError.message("The update isn't Notch — not installed.") }
        // Same signer as this Notch (certificate pinned), and an intact signature.
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + requirement, staged.path]) == 0 else {
            throw UpdateError.message("The update isn't signed by the same developer — not installed.")
        }
        // No downgrades or mismatches: the app inside must be the release's version, and newer.
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard version == tag, isNewer(version, than: current) else {
            throw UpdateError.message("The update's version doesn't match the release — not installed.")
        }
        return staged
    }

    /// Single-quotes a path for /bin/sh (any character is safe inside, including spaces and $).
    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A tiny script waits for Notch to quit, then swaps the app safely: the new copy goes in next to
    /// the old one first, the old one is moved aside, the new one takes its place, and only then is
    /// the old one deleted. If any step fails the old app is put back — never left with no app.
    nonisolated private static func scheduleSwap(newApp: URL, installedPath: String, work: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let tag = UUID().uuidString.prefix(8)
        let app = shellQuote(installedPath)
        let new = shellQuote(installedPath + ".new-\(tag)")
        let old = shellQuote(installedPath + ".old-\(tag)")
        let staged = shellQuote(newApp.path)
        let workDir = shellQuote(work.path)
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        n=0; while kill -0 \(pid) 2>/dev/null && [ $n -lt 300 ]; do sleep 0.2; n=$((n+1)); done
        if ! /usr/bin/ditto \(staged) \(new); then rm -rf \(new); /usr/bin/open \(app); exit 1; fi
        if ! /bin/mv \(app) \(old); then rm -rf \(new); /usr/bin/open \(app); exit 1; fi
        if /bin/mv \(new) \(app); then rm -rf \(old); else /bin/mv \(old) \(app); fi
        /usr/bin/open \(app)
        rm -rf \(workDir)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run() // keeps running after Notch quits
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
