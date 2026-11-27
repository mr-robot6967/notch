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
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notch-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        Task {
            let result = try? await URLSession.shared.data(for: request)
            self.lastChecked = Date()
            guard let (data, response) = result, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                self.state = .failed("Couldn't reach GitHub. Try again later.")
                return
            }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            self.latestVersion = version
            self.releaseNotes = json["body"] as? String ?? ""
            self.expectedSHA = Self.sha256(in: self.releaseNotes)
            self.dmgURL = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:))
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

    /// A "SHA-256: <64 hex>" line in the release notes, if present.
    nonisolated static func sha256(in notes: String) -> String? {
        guard let range = notes.range(of: #"(?i)sha-?256[^0-9a-f]*([0-9a-f]{64})"#, options: .regularExpression) else { return nil }
        let match = String(notes[range])
        return match.range(of: #"[0-9a-fA-F]{64}"#, options: .regularExpression).map { String(match[$0]).lowercased() }
    }

    func install() {
        guard case .available = state, let dmgURL else { return }
        state = .downloading
        let expected = expectedSHA
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let installedPath = Bundle.main.bundleURL.path
        Task.detached(priority: .userInitiated) {
            do {
                let (temp, response) = try await URLSession.shared.download(from: dmgURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Download failed.") }
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("NotchUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let dmg = work.appendingPathComponent("Notch.dmg")
                try FileManager.default.moveItem(at: temp, to: dmg)
                if let expected {
                    let digest = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
                    guard digest == expected else { throw UpdateError.message("The download didn't match its checksum.") }
                }
                await MainActor.run { Updater.shared.state = .installing }
                let staged = try Self.stage(dmg: dmg, into: work, bundleID: bundleID)
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
    nonisolated private static func stage(dmg: URL, into work: URL, bundleID: String) throws -> URL {
        let mount = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path]) == 0 else {
            throw UpdateError.message("Couldn't open the downloaded update.")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.message("No app found in the update.") }
        let staged = work.appendingPathComponent(app.lastPathComponent)
        guard run("/usr/bin/ditto", [app.path, staged.path]) == 0 else { throw UpdateError.message("Couldn't copy the update.") }
        // Must be Notch (same identifier) with an intact code signature.
        let newID = Bundle(url: staged)?.bundleIdentifier
        guard newID == bundleID else { throw UpdateError.message("The update isn't Notch — not installed.") }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]) == 0 else {
            throw UpdateError.message("The update's signature is invalid — not installed.")
        }
        return staged
    }

    /// A tiny script waits for this process to quit, replaces the app, and opens the new one.
    nonisolated private static func scheduleSwap(newApp: URL, installedPath: String, work: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(installedPath)"
        /usr/bin/ditto "\(newApp.path)" "\(installedPath)"
        /usr/bin/open "\(installedPath)"
        rm -rf "\(work.path)"
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
