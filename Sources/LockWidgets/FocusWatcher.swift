import Combine
import Foundation

/// Tracks whether Do Not Disturb or any Focus is on.
///
/// Current macOS no longer posts the old `_NSDoNotDisturb…` distributed notifications, so the state
/// is read from Focus's own store, `~/Library/DoNotDisturb/DB/Assertions.json` (readable with the Full
/// Disk Access Notch already uses for notifications). While a Focus is on, that file lists an
/// assertion record. The directory is watched for changes, with a slow poll as a safety net
/// (atomic saves replace the file, which a plain file watch would miss).
@MainActor
final class FocusWatcher: ObservableObject {
    static let shared = FocusWatcher()

    @Published private(set) var active = false
    /// Name of the active mode when known ("Do Not Disturb", "Work", …).
    @Published private(set) var modeName = ""

    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var started = false
    private var debounce: DispatchWorkItem?

    func start() {
        guard !started else { return }
        started = true
        refresh(announce: false)
        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleRefresh() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        poll = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(announce: true) }
        }
        poll?.tolerance = 5
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(announce: true) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refresh(announce: Bool) {
        let dir = self.dir
        DispatchQueue.global(qos: .utility).async {
            let state = FocusWatcher.read(dir: dir)
            DispatchQueue.main.async { [weak self] in
                guard let self, let state else { return }
                let changed = state.active != self.active
                self.active = state.active
                self.modeName = state.name
                if changed && announce {
                    NotchModel.shared.flash(.focus(state.active), seconds: 2.5)
                }
            }
        }
    }

    /// nil when the store can't be read (no Full Disk Access) — then nothing is ever held back.
    nonisolated static func read(dir: URL) -> (active: Bool, name: String)? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("Assertions.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return nil }
        let records = entries.flatMap { ($0["storeAssertionRecords"] as? [[String: Any]]) ?? [] }
        guard let first = records.first else { return (false, "") }
        let details = first["assertionDetails"] as? [String: Any]
        let mode = details?["assertionDetailsModeIdentifier"] as? String ?? ""
        return (true, modeName(for: mode, dir: dir))
    }

    nonisolated private static func modeName(for identifier: String, dir: URL) -> String {
        if identifier.isEmpty || identifier.hasSuffix(".default") { return "Do Not Disturb" }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("ModeConfigurations.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return "Focus" }
        for entry in entries {
            guard let configs = entry["modeConfigurations"] as? [String: Any],
                  let config = configs[identifier] as? [String: Any],
                  let mode = config["mode"] as? [String: Any],
                  let name = mode["name"] as? String else { continue }
            return name
        }
        return "Focus"
    }

    /// Whether a banner/peek of this kind should be held back right now.
    func holds(_ kind: HeldKind) -> Bool {
        let cfg = AppSettings.shared.config
        guard active, cfg.respectFocus else { return false }
        switch kind {
        case .notification: return true
        case .peek: return cfg.focusHoldsPeeks
        }
    }

    enum HeldKind { case notification, peek }
}
