import AppKit
import Combine
import OSLog

private let discordLog = Logger(subsystem: "com.k2a.LockWidgets", category: "discord")

/// Minimal Discord RPC client over the local IPC socket ($TMPDIR/discord-ipc-N).
/// Frame = little-endian UInt32 opcode + UInt32 length + JSON. Only SET_ACTIVITY is used, which needs
/// no OAuth — just the Client ID of a (free) application from the Discord Developer Portal.
final class DiscordIPC {
    private var fd: Int32 = -1
    /// The handshake binds the socket to one application; a changed Client ID needs a new connection.
    private(set) var clientID: String?
    var isConnected: Bool { fd >= 0 }

    func isConnected(as clientID: String) -> Bool { fd >= 0 && self.clientID == clientID }

    func connect(clientID: String) -> Bool {
        close()
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        for index in 0..<10 {
            let path = (base as NSString).appendingPathComponent("discord-ipc-\(index)")
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { continue }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let ok = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard ok else { Darwin.close(socketFD); continue }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            fd = socketFD
            guard send(opcode: 0, ["v": 1, "client_id": clientID]),
                  let ready = readFrame(), (ready["evt"] as? String) == "READY" else {
                close()
                continue
            }
            self.clientID = clientID
            return true
        }
        return false
    }

    func setActivity(_ activity: [String: Any]?) -> Bool {
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": Int(getpid()), "activity": (activity as Any?) ?? NSNull()],
            "nonce": UUID().uuidString,
        ]
        guard send(opcode: 1, payload) else { close(); return false }
        // If the reply can't be read completely the stream is out of sync — reconnect next time.
        if readFrame() == nil { close() }
        return true
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        clientID = nil
    }

    private func send(opcode: UInt32, _ object: [String: Any]) -> Bool {
        guard fd >= 0, let json = try? JSONSerialization.data(withJSONObject: object) else { return false }
        var frame = Data()
        withUnsafeBytes(of: opcode.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)
        return frame.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func readFrame() -> [String: Any]? {
        guard let header = readExactly(8) else { return nil }
        let length = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        guard length < 1_000_000, let body = readExactly(Int(length)) else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return data
    }
}

/// Shows what you're listening to as your Discord status ("Listening to …").
@MainActor
final class DiscordPresence: ObservableObject {
    static let shared = DiscordPresence()

    @Published private(set) var status = "Off"
    private let ipc = DiscordIPC()
    private let queue = DispatchQueue(label: "LockWidgets.discord")
    private var cancellables = Set<AnyCancellable>()
    private var lastSent: String?
    private var lastSendDate = Date.distantPast
    private var pendingUpdate: DispatchWorkItem?
    private var artCache: [String: String] = [:]

    func start() {
        Publishers.CombineLatest(MediaController.shared.$info, AppSettings.shared.$config)
            .map { info, cfg -> String in
                guard cfg.discordEnabled, !cfg.discordClientID.isEmpty else { return "off" }
                guard let info, info.isPlaying else { return "idle|\(cfg.discordClientID)" }
                return "\(cfg.discordClientID)|\(info.title)|\(info.artist)|\(Int(info.elapsed))|\(cfg.discordShowArt)"
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleUpdate() }
            .store(in: &cancellables)

        // Updates are only sent when the song changes, so a Discord restart (or the socket dying
        // over sleep) left the status blank until the next track; and a failed send was never
        // retried. Reconnect when Discord launches (its IPC socket takes a few seconds to appear)
        // and after wake; forget the dead socket when it quits.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .filter { Self.isDiscord($0) }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                for delay in [5.0, 20.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.reconnectIfEnabled() }
                }
            }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .filter { Self.isDiscord($0) }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.lastSent = nil
                self.queue.async { [ipc = self.ipc] in ipc.close() }
            }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reconnectIfEnabled() }
            .store(in: &cancellables)
    }

    private static func isDiscord(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier?.hasPrefix("com.hnc.Discord") == true // Discord, PTB, Canary
    }

    private func reconnectIfEnabled() {
        let cfg = AppSettings.shared.config
        guard cfg.discordEnabled, !cfg.discordClientID.isEmpty else { return }
        reconnect()
    }

    /// Discord asks clients not to update presence more than about every 15 s.
    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        let wait = max(1.5, 15 - Date().timeIntervalSince(lastSendDate))
        let work = DispatchWorkItem { [weak self] in self?.update() }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func update() {
        let cfg = AppSettings.shared.config
        guard cfg.discordEnabled, !cfg.discordClientID.isEmpty else {
            if lastSent != nil { send(nil, key: nil, clientID: cfg.discordClientID) }
            status = cfg.discordEnabled ? "Add your Discord Client ID" : "Off"
            return
        }
        guard let info = MediaController.shared.info, info.isPlaying else {
            send(nil, key: "idle", clientID: cfg.discordClientID)
            return
        }
        let now = Date()
        let start = now.addingTimeInterval(-info.currentPosition(at: now))
        var activity: [String: Any] = [
            "type": 2, // Listening
            "details": String(info.title.prefix(128)),
            "state": String(("by " + info.artist).prefix(128)),
        ]
        var timestamps: [String: Any] = ["start": Int(start.timeIntervalSince1970 * 1000)]
        if info.duration > 0 { timestamps["end"] = Int(start.addingTimeInterval(info.duration).timeIntervalSince1970 * 1000) }
        activity["timestamps"] = timestamps
        var assets: [String: Any] = [:]
        if !info.album.isEmpty { assets["large_text"] = String(info.album.prefix(128)) }
        let key = "\(info.title)|\(info.artist)|\(Int(start.timeIntervalSince1970 / 5))"
        let artKey = "\(info.artist)|\(info.album.isEmpty ? info.title : info.album)"
        if cfg.discordShowArt, let url = artCache[artKey] {
            assets["large_image"] = url
        } else if cfg.discordShowArt {
            lookUpArtwork(artist: info.artist, album: info.album.isEmpty ? info.title : info.album, cacheKey: artKey)
        }
        if !assets.isEmpty { activity["assets"] = assets }
        send(activity, key: key, clientID: cfg.discordClientID)
    }

    private func send(_ activity: [String: Any]?, key: String?, clientID: String) {
        guard key != lastSent else { return }
        lastSent = key
        lastSendDate = Date()
        let ipc = self.ipc
        queue.async {
            // Turning the integration off: clear the status on the connection we already have
            // (never open a new one just for that), then hang up.
            if key == nil {
                if ipc.isConnected { _ = ipc.setActivity(nil) }
                ipc.close()
                return
            }
            var ok = ipc.isConnected(as: clientID) || ipc.connect(clientID: clientID)
            if ok { ok = ipc.setActivity(activity) }
            if !ok, ipc.connect(clientID: clientID) { ok = ipc.setActivity(activity) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let presence = DiscordPresence.shared
                    if ok {
                        presence.status = activity == nil ? "Connected — nothing playing" : "Showing “Listening to…”"
                    } else {
                        presence.status = "Discord isn't running (or the Client ID is wrong)"
                        presence.lastSent = nil
                    }
                }
            }
        }
    }

    /// Optional: album art for Discord via the public iTunes Search API (sends artist + album to Apple).
    private func lookUpArtwork(artist: String, album: String, cacheKey: String) {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(album)"),
                                 URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "limit", value: "1")]
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let art = first["artworkUrl100"] as? String else { return }
            let big = art.replacingOccurrences(of: "100x100", with: "512x512")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let presence = DiscordPresence.shared
                    presence.artCache[cacheKey] = big
                    presence.lastSent = nil
                    presence.scheduleUpdate()
                }
            }
        }.resume()
    }

    func reconnect() {
        lastSent = nil
        queue.async { [ipc] in ipc.close() }
        scheduleUpdate()
    }
}
