import AppKit
import Combine
import OSLog
import SQLite3

private let notifLog = Logger(subsystem: "com.k2a.LockWidgets", category: "notifications")

struct MirroredNotification: Equatable, Identifiable {
    let id: Int64
    let bundleID: String
    let appName: String
    let title: String
    let subtitle: String
    let body: String
    let date: Date

    /// App icons are looked up once per app and cached: rows redraw every second (relative time),
    /// and a disk lookup per redraw made the list and banners stutter.
    private static let iconCache = NSCache<NSString, NSImage>()

    var icon: NSImage? {
        if let cached = Self.iconCache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache.setObject(image, forKey: bundleID as NSString)
        return image
    }

    /// Messages is the only app whose conversations macOS lets other apps reply to.
    @MainActor var canReply: Bool {
        let cfg = AppSettings.shared.config
        return bundleID == "com.apple.MobileSMS" && cfg.notificationReply && cfg.notificationTapReplies
    }
}

/// Mirrors other apps' notifications into the notch.
///
/// macOS has no API for this, so it reads Notification Center's
/// own database — `~/Library/Group Containers/group.com.apple.usernoted/db2/db` — which needs Full
/// Disk Access. It never writes to that database: on each change it copies the three SQLite files into
/// a private temp folder, reads the new rows, and deletes the copy straight away. Nothing is logged or
/// stored; only the last few notifications are kept in memory for the notch.
@MainActor
final class NotificationMirror: ObservableObject {
    static let shared = NotificationMirror()

    @Published private(set) var hasAccess = true
    @Published private(set) var recent: [MirroredNotification] = []

    func dismiss(_ id: Int64) { recent.removeAll { $0.id == id } }
    func clearAll() { recent.removeAll() }
    @Published private(set) var running = false

    private let dbDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2", isDirectory: true)
    private let readQueue = DispatchQueue(label: "LockWidgets.notifications", qos: .utility)
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var lastID: Int64 = -1
    private var pending: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        AppSettings.shared.$config
            .map(\.mirrorNotifications)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in on ? self?.enable() : self?.disable() }
            .store(in: &cancellables)
    }

    /// Opens System Settings at Privacy › Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func recheckAccess() {
        if AppSettings.shared.config.mirrorNotifications { disable(); enable() }
    }

    private func enable() {
        guard !running else { return }
        running = true
        primePosition()
        // Safety net: WAL checkpoints can replace the watched file.
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let mirror = NotificationMirror.shared
                // The WAL is deleted/replaced on checkpoints and around sleep; if the re-watch found
                // no file at that moment the watcher was gone for good and banners came only from this
                // 15 s timer. Re-attach whenever the watched file is no longer the current one.
                if mirror.running, mirror.hasAccess, mirror.lastID >= 0, !mirror.watchIsCurrent() { mirror.watch() }
                // Each read copies the whole database to a temp folder; doing that every 15 s while
                // nothing changed was pure disk churn. Read when the files changed since the last tick
                // (or the last read failed, so a missed row is retried).
                let signature = mirror.databaseSignature()
                guard signature != mirror.lastTickSignature || mirror.lastReadFailed else { return }
                mirror.lastTickSignature = signature
                mirror.scheduleRead()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let mirror = NotificationMirror.shared
                    guard mirror.running, mirror.hasAccess, mirror.lastID >= 0 else { return }
                    mirror.watch()
                    mirror.scheduleRead()
                }
            }
        }
    }

    private var wakeObserver: NSObjectProtocol?
    private var watchedInode: ino_t = 0
    private var lastTickSignature: String?
    private var lastReadFailed = false
    private var primeRetryDelay: TimeInterval = 5

    /// Size, modification time and inode of the database and its WAL: changes whenever a row lands.
    private func databaseSignature() -> String {
        ["db", "db-wal"].map { name -> String in
            var info = stat()
            guard stat(dbDir.appendingPathComponent(name).path, &info) == 0 else { return "-" }
            return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        }.joined(separator: "|")
    }

    private func watchIsCurrent() -> Bool {
        guard watcher != nil else { return false }
        var info = stat()
        guard stat(dbDir.appendingPathComponent("db-wal").path, &info) == 0 else { return true } // no WAL right now
        return info.st_ino == watchedInode
    }

    /// Learn where we are without showing old notifications.
    private func primePosition() {
        readQueue.async { [dbDir] in
            let result = Self.readRecords(in: dbDir, after: nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let mirror = NotificationMirror.shared
                    // Turned off (or off and on again) while this first read was running.
                    guard mirror.running, mirror.lastID < 0 else { return }
                    switch result {
                    case .failure(.failed):
                        // A copy that raced a checkpoint (or the database busy at login) is not "no
                        // Full Disk Access"; that used to switch mirroring off until Settings rechecked.
                        // Back off (5 s doubling to 5 min): a failure that persists (a database layout
                        // this macOS changed) must not copy the whole database every 5 s forever.
                        let delay = mirror.primeRetryDelay
                        mirror.primeRetryDelay = min(300, delay * 2)
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NotificationMirror.shared.primePosition() }
                    case .failure:
                        mirror.hasAccess = false
                        // Nothing to read without Full Disk Access: stop the 15 s safety-net timer
                        // (recheckAccess() turns it back on once access is granted).
                        mirror.fallbackTimer?.invalidate()
                        mirror.fallbackTimer = nil
                        notifLog.notice("No access to the notification database (Full Disk Access needed)")
                    case .success(let result):
                        mirror.primeRetryDelay = 5
                        mirror.hasAccess = true
                        mirror.lastID = result.maxID
                        mirror.watch()
                    }
                }
            }
        }
    }

    private func disable() {
        running = false
        // Forget the position so the next enable starts fresh (and stale reads are ignored).
        lastID = -1
        pending?.cancel()
        pending = nil
        watcher?.cancel()
        watcher = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        recent.removeAll()
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        // A delayed re-watch (after the WAL was replaced) must not restart a disabled mirror.
        guard running else { return }
        let wal = dbDir.appendingPathComponent("db-wal").path
        let fd = open(wal, O_EVTONLY)
        guard fd >= 0 else { return } // no WAL at the moment; the 15 s check re-attaches
        watchedFD = fd
        var info = stat()
        watchedInode = fstat(fd, &info) == 0 ? info.st_ino : 0
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.watch() }
            }
            self.scheduleRead()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRead() {
        guard running, hasAccess, lastID >= 0 else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readNew() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func readNew() {
        let after = lastID
        readQueue.async { [dbDir] in
            guard case .success(let result) = Self.readRecords(in: dbDir, after: after) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { NotificationMirror.shared.lastReadFailed = true } }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let mirror = NotificationMirror.shared
                    mirror.lastReadFailed = false
                    // Notification Center rebuilt its database (ids start again lower): nothing would
                    // ever be "after" our old position again, so resync to the new newest id. (A big
                    // drop only: a copy that missed the WAL can lag slightly behind and is no reset.)
                    if result.rows.isEmpty, result.maxID < after / 2, mirror.running, mirror.lastID == after {
                        notifLog.notice("Notification database was reset; resyncing")
                        mirror.lastID = result.maxID
                        return
                    }
                    mirror.deliver(result.rows)
                }
            }
        }
    }

    private func deliver(_ rows: [MirroredNotification]) {
        guard running, lastID >= 0 else { return }
        // Two reads can overlap and return the same rows; only rows past our position are new
        // (duplicates would also break the notifications list, which is keyed by id).
        let rows = rows.filter { $0.id > lastID }
        guard let maxID = rows.map(\.id).max() else { return }
        lastID = maxID
        let cfg = AppSettings.shared.config
        let candidates = rows
            .filter { !$0.bundleID.isEmpty && $0.bundleID != Bundle.main.bundleIdentifier }
            .filter { Date().timeIntervalSince($0.date) < 120 }
        // Remember every app that notifies so it can be configured in Settings.
        let newApps = Set(candidates.map(\.bundleID)).subtracting(cfg.notificationKnownApps)
        if !newApps.isEmpty { AppSettings.shared.config.notificationKnownApps += newApps.sorted() }
        let fresh = candidates.filter { NotificationMirror.mode(for: $0.bundleID, cfg) != "off" }
        guard !fresh.isEmpty else { return }
        recent = Array((fresh.reversed() + recent).prefix(12))
        // "List only" apps collect quietly; the newest banner-mode one pops up.
        if let newest = fresh.last(where: { NotificationMirror.mode(for: $0.bundleID, cfg) == "banner" }) {
            NotchModel.shared.flash(.notification(newest), seconds: cfg.notificationSeconds)
            if cfg.notificationSound, !FocusWatcher.shared.holds(.notification) { SystemSounds.play("Tink") }
        }
    }

    /// Per-app mode; the older mute list still means "off".
    static func mode(for bundleID: String, _ cfg: Config) -> String {
        if cfg.mutedNotificationApps.contains(bundleID) { return "off" }
        return cfg.notificationAppModes[bundleID] ?? "banner"
    }

    /// `--test-notifications`: prints how many recent notifications can be read and from which apps
    /// (never their text), to check the reader works on this macOS version.
    nonisolated static func selfTest() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2", isDirectory: true)
        guard case .success(let head) = readRecords(in: dir, after: nil), case let maxID = head.maxID, maxID > 0 else {
            print("notifications: no access (Full Disk Access needed)")
            return
        }
        guard case .success(let result) = readRecords(in: dir, after: max(0, maxID - 20)) else {
            print("notifications: read failed")
            return
        }
        let rows = result.rows
        let withText = rows.filter { !$0.title.isEmpty || !$0.body.isEmpty }.count
        print("notifications: newest id \(maxID), read \(rows.count) recent rows (\(withText) with text) from \(Set(rows.map(\.bundleID)).sorted())")
    }

    // MARK: SQLite (on readQueue)

    private enum ReadError: Error { case noAccess, failed }

    /// `maxID` is the newest record id in the database (the starting point when `after` is nil).
    nonisolated private static func readRecords(in dir: URL, after: Int64?) -> Result<(rows: [MirroredNotification], maxID: Int64), ReadError> {
        let fm = FileManager.default
        let db = dir.appendingPathComponent("db")
        guard fm.isReadableFile(atPath: db.path), (try? Data(contentsOf: db, options: .alwaysMapped).prefix(16)) != nil else {
            return .failure(.noAccess)
        }
        // Read a private copy so we never take locks on Notification Center's live database.
        let temp = fm.temporaryDirectory.appendingPathComponent("lw-notif-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: dir.appendingPathComponent("db"), to: temp.appendingPathComponent("db"))
            // The WAL/SHM can vanish between a check and the copy (checkpoint); that's fine.
            for name in ["db-wal", "db-shm"] {
                let source = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    try? fm.copyItem(at: source, to: temp.appendingPathComponent(name))
                }
            }
        } catch {
            // The database was readable a moment ago, so this is a transient failure, not missing access.
            try? fm.removeItem(at: temp)
            return .failure(.failed)
        }
        defer { try? fm.removeItem(at: temp) }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(temp.appendingPathComponent("db").path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return .failure(.failed)
        }
        defer { sqlite3_close(handle) }

        let sql = """
        SELECT r.rec_id, a.identifier, r.data, r.delivered_date
        FROM record r JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 50
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return .failure(.failed) }
        defer { sqlite3_finalize(statement) }
        // With no starting point, only fetch the newest id.
        sqlite3_bind_int64(statement, 1, after ?? Int64.max - 1)

        var rows: [MirroredNotification] = []
        var maxID: Int64 = 0
        var maxStatement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT IFNULL(MAX(rec_id), 0) FROM record", -1, &maxStatement, nil) == SQLITE_OK,
           sqlite3_step(maxStatement) == SQLITE_ROW {
            maxID = sqlite3_column_int64(maxStatement, 0)
        } else {
            sqlite3_finalize(maxStatement)
            return .failure(.failed)
        }
        sqlite3_finalize(maxStatement)
        if after == nil { return .success((rows, maxID)) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let bundle = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            var title = "", subtitle = "", body = ""
            if let bytes = sqlite3_column_blob(statement, 2) {
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let req = plist["req"] as? [String: Any] {
                    title = req["titl"] as? String ?? ""
                    subtitle = req["subt"] as? String ?? ""
                    body = req["body"] as? String ?? ""
                }
            }
            let delivered = sqlite3_column_double(statement, 3)
            let date = delivered > 0 ? Date(timeIntervalSinceReferenceDate: delivered) : Date()
            let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
            guard !(title.isEmpty && body.isEmpty) else {
                // Keep the position moving past empty rows so reading can't stall on them.
                rows.append(MirroredNotification(id: id, bundleID: "", appName: "", title: "", subtitle: "", body: "", date: .distantPast))
                continue
            }
            rows.append(MirroredNotification(id: id, bundleID: bundle, appName: appName,
                                             title: title, subtitle: subtitle, body: body, date: date))
        }
        return .success((rows, maxID))
    }
}
