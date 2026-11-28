import AppKit
import Combine
import CryptoKit
import Network
import OSLog
import Security

private let spotifyLog = Logger(subsystem: "com.k2a.LockWidgets", category: "spotify")

/// Optional Spotify Web API connection for extras the system Now Playing can't do: saving the song
/// to Liked Songs and Spotify Connect (play on another device).
///
/// Uses Authorization Code + PKCE (no client secret) with the user's own Client ID and a loopback
/// redirect (http://127.0.0.1:47321/callback). The refresh token is kept in a private file (0600).
@MainActor
final class SpotifyClient: ObservableObject {
    static let shared = SpotifyClient()
    static let redirectURI = "http://127.0.0.1:47321/callback"
    private static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state user-library-read user-library-modify"

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let type: String
        let isActive: Bool
        var symbol: String {
            switch type.lowercased() {
            case "computer": return "laptopcomputer"
            case "smartphone": return "iphone"
            case "speaker": return "hifispeaker.fill"
            case "tv": return "tv"
            case "tablet": return "ipad"
            default: return "music.note.house"
            }
        }
    }

    @Published private(set) var connected = false
    @Published private(set) var status = "Not connected"
    @Published private(set) var isLiked = false
    @Published private(set) var devices: [Device] = []

    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private var verifier = ""
    private var state = ""
    private var listener: NWListener?
    private var currentTrackID: String?
    /// Every ID the playing song is known by: the copy being played and, for relinked tracks, the
    /// original it was relinked from (Liked Songs may hold either).
    private var currentTrackIDs: [String] = []
    /// Liked state per track ID with when it was checked (one API call per song, not per minute).
    private var likedCache: [String: (liked: Bool, matched: String?, at: Date)] = [:]
    private var lastIslandCheck = Date.distantPast
    /// Liked Songs indexed by recording (ISRC) and by title + artist → saved track ID, so a song
    /// liked from another release (single vs album) shows as liked, like the Spotify app does.
    private var likedByISRC: [String: String] = [:]
    private var likedByKey: [String: String] = [:]
    private var likedIndexAt: Date?
    private var indexing = false
    /// The saved version that matched the playing song (to remove it when unliking).
    private var matchedSavedID: String?

    private static func songKey(_ name: String, _ artist: String) -> String {
        func clean(_ s: String) -> String {
            var t = s.lowercased()
            if let r = t.range(of: " (") { t = String(t[..<r.lowerBound]) }
            if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
            return t.trimmingCharacters(in: .whitespaces)
        }
        return clean(name) + "|" + clean(artist)
    }

    private static func keyAndISRC(_ track: [String: Any]) -> (key: String, isrc: String?) {
        let name = track["name"] as? String ?? ""
        let artist = ((track["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
        let isrc = (track["external_ids"] as? [String: Any])?["isrc"] as? String
        return (songKey(name, artist), isrc?.uppercased())
    }

    /// Reads Liked Songs (50 per page) into the index. Refreshed at most every 15 minutes.
    /// When the whole Liked Songs list was last read (a full read is dozens of requests).
    private var likedFullAt: Date?

    func refreshLikedIndex(force: Bool = false) async {
        guard connected, !indexing else { return }
        if likedIndexAt == nil { loadLikedCache() }
        if !force, let at = likedIndexAt, Date().timeIntervalSince(at) < 30 * 60 { return }
        indexing = true
        defer { indexing = false }
        // Full read at most once a day (or when asked); otherwise just the newest page, where new
        // likes appear, merged into the saved index — one request instead of dozens.
        let full = force || likedFullAt == nil || Date().timeIntervalSince(likedFullAt ?? .distantPast) > 24 * 3600
        var byISRC: [String: String] = full ? [:] : likedByISRC, byKey: [String: String] = full ? [:] : likedByKey
        var offset = 0
        while offset < (full ? 10_000 : 50) {
            let (code, data) = await api("GET", "/me/tracks?limit=50&offset=\(offset)")
            guard code == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return }
            for item in items {
                guard let track = item["track"] as? [String: Any], let id = track["id"] as? String else { continue }
                let (key, isrc) = Self.keyAndISRC(track)
                if let isrc { byISRC[isrc] = id }
                byKey[key] = id
            }
            if items.count < 50 { break }
            offset += 50
        }
        likedByISRC = byISRC
        likedByKey = byKey
        likedIndexAt = Date()
        if full { likedFullAt = Date() }
        saveLikedCache()
    }

    // The index is saved next to the sign-in file (owner-only) so a relaunch doesn't re-read it all.
    nonisolated private static var likedCacheURL: URL {
        tokenURL.deletingLastPathComponent().appendingPathComponent("spotify-liked.json")
    }

    private func saveLikedCache() {
        let payload: [String: Any] = ["full": likedFullAt?.timeIntervalSince1970 ?? 0,
                                      "at": likedIndexAt?.timeIntervalSince1970 ?? 0,
                                      "isrc": likedByISRC, "key": likedByKey]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let url = Self.likedCacheURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadLikedCache() {
        guard let data = try? Data(contentsOf: Self.likedCacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        likedByISRC = json["isrc"] as? [String: String] ?? [:]
        likedByKey = json["key"] as? [String: String] ?? [:]
        if let full = json["full"] as? Double, full > 0 { likedFullAt = Date(timeIntervalSince1970: full) }
        if let at = json["at"] as? Double, at > 0 { likedIndexAt = Date(timeIntervalSince1970: at) }
    }

    /// The playing song's index keys (to update the saved index locally after a like/unlike).
    private var currentIndexKeys: (key: String, isrc: String?)?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            let hasToken = Self.loadRefreshToken() != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let client = SpotifyClient.shared
                    if hasToken && !client.connected {
                        client.connected = true
                        client.status = "Connected"
                        spotifyLog.notice("Spotify: refresh token found, connected")
                        Task { await client.refreshTrackState() }
                    }
                }
            }
        }
        // Keep the heart in sync with the current Spotify track.
        MediaController.shared.$info
            .map { info -> String in info?.bundleIdentifier == "com.spotify.client" ? "\(info?.title ?? "")|\(info?.artist ?? "")" : "" }
            // "Nothing playing" for a moment (waking from sleep, between tracks) isn't a new song:
            // ignore it, so the same song coming back keeps its heart.
            .filter { !$0.isEmpty }
            .removeDuplicates()
            .handleEvents(receiveOutput: { key in
                MainActor.assumeIsolated {
                    let client = SpotifyClient.shared
                    guard key != client.likedKey else { return }
                    // A different song: forget the old one straight away so a quick ♥ can't hit it.
                    client.currentTrackID = nil
                    client.isLiked = false
                }
            })
            .debounce(for: .seconds(1.0), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.connected else { return }
                Task { await self.refreshTrackState() }
            }
            .store(in: &cancellables)
        // "Match likes saved from other releases" changed: cached hearts were worked out under the old
        // setting for up to 10 min. With matching turned off a cached match kept the heart filled,
        // and an unlike would still delete that other saved release. Forget them and ask again.
        AppSettings.shared.$config
            .map(\.spotifyMatchReleases)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.likedCache = [:]
                self.matchedSavedID = nil
                guard self.connected, MediaController.shared.info?.bundleIdentifier == "com.spotify.client" else { return }
                Task { await self.refreshTrackState() }
            }
            .store(in: &cancellables)
        // After sleep the network comes back a few seconds late; re-check then (with retries).
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    for delay in [4.0, 6.0, 10.0] {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        if await self.refreshTrackState() { break }
                    }
                }
            }
            .store(in: &cancellables)
        // Opening the island re-checks the heart.
        NotchModel.shared.$expanded
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, self.connected, MediaController.shared.info?.bundleIdentifier == "com.spotify.client",
                      Date().timeIntervalSince(self.lastIslandCheck) > 60 else { return }
                self.lastIslandCheck = Date()
                self.likedCache[self.currentTrackID ?? ""] = nil // opening the island asks for a fresh answer
                Task { await self.refreshTrackState() }
            }
            .store(in: &cancellables)
    }

    // MARK: Connect / disconnect

    func connect() {
        let clientID = AppSettings.shared.config.spotifyClientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else { status = "Paste your Client ID first"; return }
        verifier = Self.randomString(64)
        state = Self.randomString(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        guard startListener(clientID: clientID) else { status = "Couldn't open the local callback (port 47321 busy?)"; return }
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        if let url = c.url {
            status = "Waiting for you to approve in the browser…"
            NSWorkspace.shared.open(url)
        }
    }

    func disconnect() {
        Self.deleteRefreshToken()
        listener?.cancel()
        listener = nil
        accessToken = nil
        tokenExpiry = .distantPast
        connected = false
        isLiked = false
        devices = []
        // Forget everything tied to this account, so connecting another one never shows its hearts.
        currentTrackID = nil
        currentTrackIDs = []
        currentIndexKeys = nil
        matchedSavedID = nil
        likedKey = ""
        likedCache = [:]
        likedByISRC = [:]
        likedByKey = [:]
        likedIndexAt = nil
        likedFullAt = nil
        try? FileManager.default.removeItem(at: Self.likedCacheURL)
        status = "Not connected"
    }

    private func startListener(clientID: String) -> Bool {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 47321)
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                let path = firstLine.components(separatedBy: " ").dropFirst().first ?? ""
                // Browsers open speculative connections (no request at all) and ask for
                // /favicon.ico; neither is the redirect, so answer and keep waiting for it.
                guard path.hasPrefix("/callback") else {
                    if !request.isEmpty {
                        let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        connection.send(content: notFound.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                    } else {
                        connection.cancel()
                    }
                    return
                }
                let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let returnedState = items.first { $0.name == "state" }?.value
                let message = code != nil ? "Notch is connected to Spotify. You can close this tab." : "Spotify connection failed. You can close this tab and try again."
                let html = "<html><body style=\"font-family:-apple-system;background:#111;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh\"><h2>\(message)</h2></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                MainActor.assumeIsolated {
                    let client = SpotifyClient.shared
                    client.listener?.cancel()
                    client.listener = nil
                    guard let code, returnedState == client.state else {
                        client.status = "Connection was cancelled"
                        return
                    }
                    Task { await client.exchange(code: code, clientID: clientID) }
                }
            }
        }
        // Binding the port fails asynchronously (e.g. it's in use); say so instead of "Waiting…" for 3 min.
        listener.stateUpdateHandler = { [weak listener] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                let client = SpotifyClient.shared
                guard let listener, client.listener === listener else { return }
                listener.cancel()
                client.listener = nil
                client.status = "Couldn't open the local callback (port 47321 busy?)"
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        // Give up after 3 minutes — only for this attempt's listener.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self, weak listener] in
            guard let self, let listener, self.listener === listener else { return }
            listener.cancel()
            self.listener = nil
            if !self.connected { self.status = "Timed out — try again" }
        }
        return true
    }

    private func exchange(code: String, clientID: String) async {
        let body = ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                    "client_id": clientID, "code_verifier": verifier]
        guard let token = await tokenRequest(body) else { status = "Spotify didn't accept the sign-in"; return }
        // Fresh sign-in: forget any half-finished refresh of the previous token.
        refreshTask = nil
        apply(token)
        connected = true
        status = "Connected"
        await refreshTrackState()
    }

    /// One refresh at a time: Spotify rotates refresh tokens, so two parallel refreshes with the same
    /// token could see the second rejected and wrongly sign the user out.
    private var refreshTask: Task<Bool, Never>?

    private func refreshAccessToken() async -> Bool {
        if let running = refreshTask { return await running.value }
        let task = Task { await self.performTokenRefresh() }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    private func performTokenRefresh() async -> Bool {
        let refresh = await Task.detached(priority: .userInitiated) { Self.loadRefreshToken() }.value
        guard let refresh else { connected = false; spotifyLog.error("Spotify: no refresh token"); return false }
        let clientID = AppSettings.shared.config.spotifyClientID.trimmingCharacters(in: .whitespaces)
        let (token, code) = await tokenRequestWithStatus(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        spotifyLog.notice("Spotify: token refresh → \(code)")
        // Disconnected while the request was in flight: don't save the rotated refresh token
        // (that would silently sign the user back in on the next launch).
        guard connected else { return false }
        guard let token else {
            // Only a rejected refresh token means signed out; network trouble just fails this call.
            if code == 400 || code == 401 {
                status = "Sign-in expired — connect again"
                connected = false
            } else {
                status = "Spotify unreachable — will retry"
            }
            return false
        }
        apply(token)
        return true
    }

    private func apply(_ token: [String: Any]) {
        accessToken = token["access_token"] as? String
        tokenExpiry = Date().addingTimeInterval(TimeInterval((token["expires_in"] as? Int) ?? 3600) - 60)
        if let refresh = token["refresh_token"] as? String { Self.saveRefreshToken(refresh) }
    }

    private func tokenRequest(_ fields: [String: String]) async -> [String: Any]? {
        await tokenRequestWithStatus(fields).0
    }

    private func tokenRequestWithStatus(_ fields: [String: String]) async -> ([String: Any]?, Int) {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (nil, 0) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return (nil, code) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any], code)
    }

    // MARK: API

    /// Spotify rate-limits this app's key (development-mode apps get a small quota). After a 429 we
    /// stop calling until the time it asks for; hammering it kept the quota exhausted, so every
    /// like check failed and the heart showed "not liked".
    private var blockedUntil = Date.distantPast {
        didSet {
            busyUntil = blockedUntil > Date() ? blockedUntil : nil
            // There's no polling, so nothing else would clear "busy" once the pause ends: the heart
            // and Settings would say "busy" until the next request. Clear it when the pause is over.
            guard let until = busyUntil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.blockedUntil <= Date() else { return }
                    self.busyUntil = nil
                }
            }
        }
    }
    /// Set while Spotify calls are paused (rate limit or our own budget) — shown on the heart.
    @Published private(set) var busyUntil: Date?
    /// Our own ceiling, well under what one key allows, so a single user can never exhaust it.
    private static let hourlyBudget = 150
    private var recentRequests: [Date] = []

    @discardableResult
    private func api(_ method: String, _ path: String, json: Any? = nil, retried: Bool = false) async -> (Int, Data?) {
        if Date() < blockedUntil { return (429, nil) }
        if busyUntil != nil { busyUntil = nil } // the pause is over
        let now = Date()
        recentRequests.removeAll { now.timeIntervalSince($0) > 3600 }
        if recentRequests.count >= Self.hourlyBudget, let oldest = recentRequests.first {
            blockedUntil = oldest.addingTimeInterval(3600)
            status = "Notch paused Spotify requests for a few minutes (hourly limit)"
            return (429, nil)
        }
        recentRequests.append(now)
        if accessToken == nil || Date() > tokenExpiry {
            guard await refreshAccessToken() else { return (401, nil) }
        }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            spotifyLog.error("Spotify: \(method, privacy: .public) \(path, privacy: .public) → network error")
            return (0, nil)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let detail = code >= 400 ? (String(data: data.prefix(300), encoding: .utf8) ?? "") : ""
        spotifyLog.notice("Spotify: \(method, privacy: .public) \(path.components(separatedBy: "?").first ?? path, privacy: .public) → \(code) \(detail, privacy: .public)")
        if code == 401, !retried, await refreshAccessToken() { return await api(method, path, json: json, retried: true) }
        if code == 429 {
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 120
            let wait = max(30, min(retry, 3600))
            blockedUntil = Date().addingTimeInterval(wait)
            status = "Spotify is busy — Notch will try again in \(Int((wait / 60).rounded(.up))) min"
        }
        return (code, data)
    }

    /// "title|artist" of the playing Spotify song; nil when Spotify isn't the source (momentary gaps).
    private static func playingKey() -> String? {
        guard let info = MediaController.shared.info, info.bundleIdentifier == "com.spotify.client" else { return nil }
        return "\(info.title)|\(info.artist)"
    }

    /// Song key ("title|artist") the current heart belongs to.
    private(set) var likedKey = ""

    /// Updates the heart for the playing song. Returns false if Spotify couldn't be reached — the
    /// heart is then left as it was (a failed check must never look like "not liked").
    @discardableResult
    func refreshTrackState() async -> Bool {
        guard connected else { return false }
        // Right after a skip Spotify can still report the previous song; retry briefly until it
        // matches what's on screen, so the heart is never taken from the wrong track.
        let expected = MediaController.shared.info?.title.lowercased() ?? ""
        // The song this check is for. If another starts while we wait on Spotify, this answer must
        // not land on it: it would show the old song's heart under the new key (likedKey), and a ♥
        // in that window saved or removed the previous track.
        let checkingKey = Self.playingKey()
        func stillSameSong() -> Bool { Self.playingKey().map { $0 == checkingKey } ?? true }
        var item: [String: Any]?
        for attempt in 0..<3 {
            let (code, data) = await api("GET", "/me/player/currently-playing?market=from_token")
            if code == 200, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let found = json["item"] as? [String: Any] {
                item = found
                let name = (found["name"] as? String ?? "").lowercased()
                if expected.isEmpty || name == expected || expected.contains(name) || name.contains(expected) { break }
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        }
        guard let item, let id = item["id"] as? String, stillSameSong() else { return false }
        var ids = [id]
        if let linked = (item["linked_from"] as? [String: Any])?["id"] as? String, linked != id { ids.append(linked) }
        currentTrackID = id
        currentTrackIDs = ids
        let (key, isrc) = Self.keyAndISRC(item)
        currentIndexKeys = (key, isrc)
        // One check per song: reuse a recent answer for the same track instead of asking again.
        if let cached = likedCache[id], Date().timeIntervalSince(cached.at) < 600 {
            isLiked = cached.liked
            // The saved other-release version belongs to this song, not to whichever was checked last
            // (a stale one would be deleted by the next unlike).
            matchedSavedID = cached.matched
            if let info = MediaController.shared.info { likedKey = "\(info.title)|\(info.artist)" }
            return true
        }
        let matchReleases = AppSettings.shared.config.spotifyMatchReleases
        if matchReleases { await refreshLikedIndex() }
        let other = matchReleases ? (isrc.flatMap { likedByISRC[$0] } ?? likedByKey[key]) : nil
        let exactResult = await libraryContains(ids)
        guard stillSameSong(), currentTrackID == id else { return false }
        if let exact = exactResult {
            matchedSavedID = exact ? nil : other
            isLiked = exact || other != nil
        } else if let other {
            matchedSavedID = other
            isLiked = true
        } else {
            return false
        }
        if let info = MediaController.shared.info { likedKey = "\(info.title)|\(info.artist)" }
        likedCache[id] = (isLiked, matchedSavedID, Date())
        return true
    }

    /// True if any of the IDs is in Liked Songs; nil if Spotify couldn't be asked.
    private func libraryContains(_ ids: [String]) async -> Bool? {
        let uris = ids.map { "spotify:track:\($0)" }.joined(separator: ",")
        let encoded = uris.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uris
        var (code, data) = await api("GET", "/me/library/contains?uris=\(encoded)")
        if code != 200 { (code, data) = await api("GET", "/me/tracks/contains?ids=\(ids.joined(separator: ","))") }
        guard code == 200, let data, let flags = try? JSONSerialization.jsonObject(with: data) as? [Bool] else { return nil }
        return flags.contains(true)
    }

    // No background polling of the heart: song changes, opening the island (throttled) and wake
    // re-check it. Keeps each user far below Spotify's per-key limits.

    // Shuffle/repeat: Spotify's AppleScript setter no longer works (it has three shuffle modes now),
    // so with the connection we use the Web API, which sets and reports them reliably.

    /// Current shuffle and repeat ("off", "context", "track"), or nil if Spotify couldn't be asked.
    func playbackModes() async -> (shuffle: Bool, repeatState: String)? {
        guard connected else { return nil }
        let (code, data) = await api("GET", "/me/player")
        guard code == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["shuffle_state"] as? Bool ?? false, json["repeat_state"] as? String ?? "off")
    }

    @discardableResult
    func setShuffle(_ on: Bool) async -> Bool {
        guard connected else { return false }
        let (code, _) = await api("PUT", "/me/player/shuffle?state=\(on)")
        return (200...299).contains(code)
    }

    /// state: "off", "context" (repeat all) or "track" (repeat one).
    @discardableResult
    func setRepeat(_ state: String) async -> Bool {
        guard connected else { return false }
        let (code, _) = await api("PUT", "/me/player/repeat?state=\(state)")
        return (200...299).contains(code)
    }

    /// `--spotify-modes-test`: flips shuffle, reads it back, restores it (proves control works).
    func modesTest() async {
        guard Self.loadRefreshToken() != nil else { print("spotify: no token"); return }
        connected = true
        guard let before = await playbackModes() else { print("spotify: player state unavailable"); return }
        print("spotify: before shuffle=\(before.shuffle) repeat=\(before.repeatState)")
        // Flip: print the raw status code so a refusal (403 premium-only, 404 no device…) is visible.
        let (flipCode, flipData) = await api("PUT", "/me/player/shuffle?state=\(!before.shuffle)")
        let flipBody = flipData.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200) ?? ""
        print("spotify: PUT shuffle=\(!before.shuffle) → \(flipCode) \(flipBody)")
        try? await Task.sleep(nanoseconds: 700_000_000)
        let mid = await playbackModes()
        print("spotify: read back shuffle=\(mid?.shuffle.description ?? "?")")
        // Always restore, even if the flip looked refused (it may have applied anyway).
        let (restoreCode, _) = await api("PUT", "/me/player/shuffle?state=\(before.shuffle)")
        print("spotify: PUT shuffle=\(before.shuffle) (restore) → \(restoreCode)")
        try? await Task.sleep(nanoseconds: 700_000_000)
        print("spotify: restored shuffle=\((await playbackModes())?.shuffle.description ?? "?")")
    }

    /// Saves or removes the current song from Liked Songs.
    func toggleLike() async {
        // Flip the heart at once (the API call takes a moment); revert below if Spotify refuses.
        let previous = isLiked
        let saving = !previous
        isLiked = saving
        // Only look the song up again if what we know belongs to another song.
        let info = MediaController.shared.info
        let key = info.map { "\($0.title)|\($0.artist)" } ?? ""
        if currentTrackID == nil || key != likedKey {
            await refreshTrackState()
            isLiked = saving
        }
        guard let id = currentTrackID else {
            isLiked = previous
            status = "Couldn't find the current song on Spotify"
            return
        }
        // Unliking removes every ID the song is known by (it may be saved under the original).
        if !saving, currentTrackIDs.count > 1 {
            let uris = currentTrackIDs.map { "spotify:track:\($0)" }.joined(separator: ",")
            _ = await api("DELETE", "/me/library?uris=\(uris.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uris)")
        }
        // Newer apps must use /me/library; older ones /me/tracks. Try both.
        let uri = "spotify:track:\(id)"
        let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
        var (code, _) = await api(saving ? "PUT" : "DELETE", "/me/library?uris=\(encoded)")
        if !(200...299).contains(code) {
            (code, _) = await api(saving ? "PUT" : "DELETE", "/me/library", json: ["uris": [uri]])
        }
        if !(200...299).contains(code) {
            (code, _) = await api(saving ? "PUT" : "DELETE", "/me/tracks?ids=\(id)")
        }
        // Unliking a song saved under another release removes that saved version too.
        if !saving, let saved = matchedSavedID, saved != id {
            let uri = "spotify:track:\(saved)"
            let (savedCode, _) = await api("DELETE", "/me/library?uris=\(uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri)")
            // Only report success if removing that saved version actually worked.
            if (200...299).contains(savedCode) { code = savedCode }
        }
        if (200...299).contains(code) {
            isLiked = saving
            likedCache[id] = (saving, nil, Date())
            if let keys = currentIndexKeys {
                if saving {
                    likedByKey[keys.key] = id
                    if let isrc = keys.isrc { likedByISRC[isrc] = id }
                } else {
                    likedByKey.removeValue(forKey: keys.key)
                    if let isrc = keys.isrc { likedByISRC.removeValue(forKey: isrc) }
                }
                saveLikedCache()
            }
            matchedSavedID = nil
            status = saving ? "Saved to Liked Songs" : "Removed from Liked Songs"
        } else {
            isLiked = previous
            status = "Spotify refused (code \(code))"
        }
    }

    func loadDevices() async {
        guard connected else { return }
        let (code, data) = await api("GET", "/me/player/devices")
        guard code == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["devices"] as? [[String: Any]] else { return }
        devices = list.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return Device(id: id, name: name, type: d["type"] as? String ?? "", isActive: d["is_active"] as? Bool ?? false)
        }
    }

    func transfer(to device: Device) async {
        let (code, _) = await api("PUT", "/me/player", json: ["device_ids": [device.id], "play": true])
        status = (200...299).contains(code) ? "Playing on \(device.name)" : "Couldn't switch device (code \(code))"
        await loadDevices()
    }

    /// `--spotify-selftest`: read-only checks (current track, liked state, devices), printed to stdout.
    func selfTest() async {
        guard Self.loadRefreshToken() != nil else { print("spotify: no token — connect first"); return }
        connected = true
        let (code, data) = await api("GET", "/me/player/currently-playing")
        var name = "-"
        var id: String?
        var linked: String?
        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let item = json["item"] as? [String: Any] {
            name = item["name"] as? String ?? "-"
            id = item["id"] as? String
            linked = (item["linked_from"] as? [String: Any])?["id"] as? String
            let context = json["context"] as? [String: Any]
            print("spotify: context → \(context?["type"] as? String ?? "none") \(context?["uri"] as? String ?? "")")
        }
        print("spotify: currently-playing → \(code) \(name) id=\(id ?? "-") linked_from=\(linked ?? "none")")
        _ = await api("GET", "/me/player/currently-playing?market=from_token")
        if let id {
            let liked = await libraryContains([id] + (linked.map { [$0] } ?? []))
            print("spotify: liked (exact ids) → \(liked.map { String($0) } ?? "unknown")")
            await refreshLikedIndex(force: true)
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let item = json["item"] as? [String: Any] {
                let (key, isrc) = Self.keyAndISRC(item)
                print("spotify: liked index \(likedByKey.count) songs; same recording saved → \(isrc.flatMap { likedByISRC[$0] } != nil), same title+artist saved → \(likedByKey[key] != nil)")
            }
        }
        if let id {
            let (c2, d2) = await api("GET", "/me/tracks/contains?ids=\(id)")
            print("spotify: tracks/contains → \(c2) \(d2.flatMap { String(data: $0, encoding: .utf8) } ?? "")")
            let uri = "spotify:track:\(id)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let (c3, d3) = await api("GET", "/me/library/contains?uris=\(uri)")
            print("spotify: library/contains → \(c3) \(d3.flatMap { String(data: $0, encoding: .utf8) }?.prefix(120) ?? "")")
        }
        for path in ["/me/tracks?limit=2", "/me/library?limit=2", "/me/library?types=track&limit=2"] {
            let (c, d) = await api("GET", path)
            print("spotify: \(path) → \(c) \(d.flatMap { String(data: $0, encoding: .utf8) }?.replacingOccurrences(of: "\n", with: " ").prefix(160) ?? "")")
        }
        if let id {
            let (c, d) = await api("GET", "/tracks/\(id)")
            let isrc = ((d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["external_ids"] as? [String: Any])?["isrc"] as? String
            print("spotify: track isrc → \(c) \(isrc ?? "-")")
        }
        let (c4, d4) = await api("GET", "/me/player/devices")
        let count = (d4.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["devices"] as? [Any])?.count ?? 0
        print("spotify: devices → \(c4) (\(count) devices)")
    }

    // MARK: Token storage

    /// The refresh token lives in a private file (mode 0600) in Application Support. The login
    /// keychain was used before, but with a self-signed build macOS re-asks for keychain access
    /// after every update, which silently blocked Spotify until the prompt was answered.
    nonisolated private static var tokenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Islet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("spotify-token")
    }

    nonisolated private static func saveRefreshToken(_ token: String) {
        let url = tokenURL
        try? Data(token.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    nonisolated private static func loadRefreshToken() -> String? {
        guard let data = try? Data(contentsOf: tokenURL), let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    nonisolated private static func deleteRefreshToken() {
        try? FileManager.default.removeItem(at: tokenURL)
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
