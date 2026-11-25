import Foundation
import Network
import Observation
import os
import Security

let clientId = "https://git.borodutch.com/backmeupplz/homestill"
let logger = Logger(subsystem: "com.borodutch.homestill", category: "ha")
@MainActor let ha = Ha()

/// One entity as `subscribe_entities` describes it: state + raw attributes.
struct Entity { var s: String; var a: [String: Any] }

/// What a tile (or camera card) shows: the entity reduced to the attributes we use. Codable for the snapshot cache.
struct Tile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var s: String
    var brightness: Int?
    var rgb: [Int]?
    var modes: [String]?
    var features = 0
    var position: Int?
    var percentage: Int?
    var minK: Int?
    var maxK: Int?
    var kelvin: Int?
    var hue: Double?
    var picture: String?

    var domain: String { String(id.prefix { $0 != "." }) }
    /// Buttons, scenes and scripts carry a timestamp or `unknown` as state by design.
    var stateless: Bool { ["button", "input_button", "scene", "script"].contains(domain) }
    var unavailable: Bool { !stateless && (s == "unavailable" || s == "unknown") }
}

struct Section: Codable, Identifiable, Equatable { var id: String; var name: String; var tiles: [Tile] }

/// The registry facts we use about an entity.
struct Reg: Equatable { var device: String?; var area: String?; var skip = false }

enum HaError: LocalizedError {
    case signedOut, authInvalid, offline, server(String)
    var errorDescription: String? {
        switch self {
        case .signedOut: "Your session ended. Sign in again."
        case .authInvalid: "Authentication failed."
        case .offline: "Not connected to Home Assistant."
        case .server(let m): m
        }
    }
}

enum Conn { case connecting, connected, failed }
enum LockTap: Equatable { case confirmUnlock, lock, none }

// MARK: - Pure logic (unit-tested)

extension Ha {
    static let homeDomains: Set = ["light", "switch", "input_boolean", "fan", "cover", "lock", "button", "input_button", "scene", "script"]
    static func shown(_ id: String) -> Bool {
        let d = String(id.prefix { $0 != "." })
        return d == "camera" || homeDomains.contains(d)
    }

    /// Applies one `subscribe_entities` event (`a` added/full, `c` diffs, `r` removed). Returns the ids whose state `s` the
    /// server set (they settle optimistic flips). Entities outside the shown domains are never stored.
    @discardableResult
    static func apply(_ ev: [String: Any], to st: inout [String: Entity]) -> Set<String> {
        var settled = Set<String>()
        if let add = ev["a"] as? [String: [String: Any]] {
            for (id, e) in add where shown(id) {
                st[id] = Entity(s: e["s"] as? String ?? "unknown", a: e["a"] as? [String: Any] ?? [:])
                settled.insert(id)
            }
        }
        if let ch = ev["c"] as? [String: [String: Any]] {
            for (id, d) in ch {
                guard var e = st[id] else { continue }
                if let p = d["+"] as? [String: Any] {
                    if let s = p["s"] as? String { e.s = s; settled.insert(id) }
                    if let a = p["a"] as? [String: Any] { e.a.merge(a) { $1 } }
                }
                if let m = d["-"] as? [String: Any], let keys = m["a"] as? [String] { for k in keys { e.a[k] = nil } }
                st[id] = e
            }
        }
        for id in ev["r"] as? [String] ?? [] { st[id] = nil }
        return settled
    }

    /// "Living Room Lights" in "Living Room" → "Lights".
    static func displayName(_ name: String, area: String?) -> String {
        guard let area, let r = name.range(of: area + " ", options: [.caseInsensitive, .anchored]) else { return name }
        let rest = name[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    static func tile(_ id: String, _ e: Entity, area: String?) -> Tile {
        let a = e.a
        func int(_ k: String) -> Int? { (a[k] as? NSNumber).map { Int($0.doubleValue.rounded()) } }
        return Tile(id: id, name: displayName(a["friendly_name"] as? String ?? id, area: area), s: e.s,
                    brightness: int("brightness"), rgb: (a["rgb_color"] as? [NSNumber])?.map(\.intValue),
                    modes: a["supported_color_modes"] as? [String], features: int("supported_features") ?? 0,
                    position: int("current_position"), percentage: int("percentage"),
                    minK: int("min_color_temp_kelvin"), maxK: int("max_color_temp_kelvin"), kelvin: int("color_temp_kelvin"),
                    hue: (a["hs_color"] as? [NSNumber])?.first?.doubleValue, picture: a["entity_picture"] as? String)
    }

    /// Home sections (Scenes, areas in registry order, Other) and the camera list.
    static func build(states: [String: Entity], reg: [String: Reg], deviceArea: [String: String],
                      areas: [(id: String, name: String)]) -> (home: [Section], cameras: [Tile]) {
        let areaName = Dictionary(areas.map { ($0.id, $0.name) }) { a, _ in a }
        var inArea: [String: [Tile]] = [:], scenes: [Tile] = [], other: [Tile] = [], cameras: [Tile] = []
        for (id, e) in states where shown(id) {
            let r = reg[id]
            if r?.skip == true { continue }
            let area = (r?.area ?? r?.device.flatMap { deviceArea[$0] }).flatMap { areaName[$0] != nil ? $0 : nil }
            let t = tile(id, e, area: area.flatMap { areaName[$0] })
            switch t.domain {
            case "camera": cameras.append(Self.tile(id, e, area: nil))
            case _ where area != nil: inArea[area!, default: []].append(t)
            case "scene", "script": scenes.append(t)
            default: other.append(t)
            }
        }
        func sorted(_ t: [Tile]) -> [Tile] { t.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        var home: [Section] = []
        if !scenes.isEmpty { home.append(Section(id: "~scenes", name: "Scenes", tiles: sorted(scenes))) }
        for a in areas { if let t = inArea[a.id] { home.append(Section(id: a.id, name: a.name, tiles: sorted(t))) } }
        if !other.isEmpty { home.append(Section(id: "~other", name: "Other", tiles: sorted(other))) }
        return (home, sorted(cameras))
    }

    static func parseEntityReg(_ r: Any?) -> [String: Reg] {
        let list = (r as? [String: Any])?["entities"] as? [[String: Any]] ?? []
        var out: [String: Reg] = [:]
        for e in list {
            guard let id = e["ei"] as? String, shown(id) else { continue }
            out[id] = Reg(device: e["di"] as? String, area: e["ai"] as? String,
                          skip: (e["hb"] as? Bool) == true || (e["ec"] != nil && !(e["ec"] is NSNull)))
        }
        return out
    }

    static func lockTap(_ s: String) -> LockTap {
        switch s {
        case "locked": .confirmUnlock
        case "unlocked", "open", "jammed": .lock
        default: .none
        }
    }

    static func needsRefresh(token: String?, expiry: Date, now: Date = .now) -> Bool {
        token == nil || expiry.timeIntervalSince(now) < 60
    }

    /// Trim, drop trailing `/`; no scheme → https first, then http.
    static func candidates(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return [] }
        return s.contains("://") ? [s] : ["https://" + s, "http://" + s]
    }

    static func stateText(_ t: Tile) -> String {
        if t.unavailable { return "Unavailable" }
        let s = t.s.replacingOccurrences(of: "_", with: " ").capitalized
        switch t.domain {
        case "light": return t.s == "on" ? (t.brightness.map { "On · \(Int((Double($0) / 255 * 100).rounded()))%" } ?? "On") : s
        case "fan": return t.s == "on" ? (t.percentage.map { "On · \($0)%" } ?? "On") : s
        case "cover": return t.position.map { "\(s) · \($0)%" } ?? s
        case "button", "input_button": return "Press"
        case "scene": return "Activate"
        case "script": return t.s == "on" ? "Running" : "Run"
        default: return s
        }
    }
}

// MARK: - Model

@MainActor @Observable final class Ha {
    // Signed-in account (Keychain): base URL + refresh token. The access token lives in memory only.
    private(set) var base: String?
    @ObservationIgnored private var refresh: String?
    @ObservationIgnored var access: String?
    @ObservationIgnored var expiry = Date.distantPast

    var conn = Conn.connecting
    var home: [Section] = []
    var cameras: [Tile] = []
    var userName: String?
    var signInMessage: String?
    var needsCode = false
    var toast: String?
    var unlockAsk: Tile?
    var flashing: String?

    @ObservationIgnored private var states: [String: Entity] = [:]
    @ObservationIgnored private var reg: [String: Reg]?
    @ObservationIgnored private var deviceArea: [String: String]?
    @ObservationIgnored private var areas: [(id: String, name: String)]?
    @ObservationIgnored private var gotStates = false
    @ObservationIgnored private var ws: URLSessionWebSocketTask?
    @ObservationIgnored private var nextId = 0
    @ObservationIgnored private var subId = 0
    @ObservationIgnored private var lastPong = 0
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<Any?, Error>] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: (server: String, gen: Int)] = [:]
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private var flowId: String?
    @ObservationIgnored private var flowBase: String?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var pathSeen = false
    @ObservationIgnored private var wasConnected = false
    @ObservationIgnored var onSync: (() -> Void)?  // Debug hooks
    /// Unit tests run inside the app: never connect there.
    @ObservationIgnored let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var signedIn: Bool { base != nil }
    var connected: Bool { conn == .connected }

    init() {
        if let acc = Self.keychain() { base = acc["base"]; refresh = acc["refresh"] }
        if base != nil, let d = try? Data(contentsOf: Self.snapshotURL), let s = try? JSONDecoder().decode(Snapshot.self, from: d) {
            home = s.home; cameras = s.cameras
        }
        monitor.pathUpdateHandler = { p in
            Task { @MainActor in
                if !ha.pathSeen { ha.pathSeen = true; return } // fires once at start
                if p.status == .satisfied, ha.conn != .connected { ha.reconnect() }
            }
        }
        monitor.start(queue: .main)
    }

    func tile(_ id: String) -> Tile? {
        for s in home { if let t = s.tiles.first(where: { $0.id == id }) { return t } }
        return cameras.first { $0.id == id }
    }

    // MARK: Connection lifecycle

    /// Starts the connect loop if signed in and not already running.
    func connect() {
        guard signedIn, loop == nil, !testing else { return }
        loop = Task { await run() }
    }

    /// Closes the socket (going to the background) and saves the snapshot.
    func disconnect() {
        ws?.cancel(with: .goingAway, reason: nil)
        loop?.cancel(); loop = nil
        conn = .connecting
        saveSnapshot()
    }

    /// Drops the current attempt (and its backoff) and connects again now.
    func reconnect() {
        guard signedIn, !testing, loop != nil else { return }
        ws?.cancel(with: .goingAway, reason: nil)
        let old = loop
        old?.cancel()
        loop = Task { await old?.value; await run() }
    }

    private func run() async {
        var delay = 1.0, retriedAuth = false
        while !Task.isCancelled, signedIn {
            wasConnected = false
            do {
                try await session()
            } catch HaError.signedOut {
                signOut(message: HaError.signedOut.errorDescription, revoke: false); return
            } catch HaError.authInvalid {
                if retriedAuth { signOut(message: HaError.signedOut.errorDescription, revoke: false); return }
                retriedAuth = true; access = nil // refresh and retry once, right away
                continue
            } catch {
                logger.info("connect failed: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { return }
            if wasConnected { delay = 1; retriedAuth = false }
            conn = .failed
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }

    private func session() async throws {
        let token = try await accessToken()
        guard let base, let url = URL(string: base.replacingOccurrences(of: "http", with: "ws", options: .anchored) + "/api/websocket")
        else { throw HaError.signedOut }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20 // the first states event of a big home is several MB
        ws = task; task.resume()
        var heartbeat: Task<Void, Never>?
        defer {
            heartbeat?.cancel(); task.cancel(with: .goingAway, reason: nil)
            if ws === task { ws = nil }
            for c in waiting.values { c.resume(throwing: HaError.offline) }
            waiting = [:]
            if conn == .connected { conn = .connecting; saveSnapshot() }
        }
        while true {
            let msg = try await task.receive()
            guard case .string(let text) = msg, let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            else { continue }
            let id = m["id"] as? Int ?? 0
            switch m["type"] as? String {
            case "auth_required": raw(["type": "auth", "access_token": token])
            case "auth_invalid": logger.info("auth_invalid"); throw HaError.authInvalid
            case "auth_ok":
                logger.info("connected"); conn = .connected; wasConnected = true; nextId = 0; lastPong = 0; gotStates = false; reg = nil; deviceArea = nil; areas = nil
                subId = send(["type": "subscribe_entities"])
                fetchRegistries()
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(10)) // + 10 s pong wait = a ping every 20 s
                        guard let self, !Task.isCancelled else { return }
                        let ping = self.send(["type": "ping"])
                        try? await Task.sleep(for: .seconds(10))
                        if !Task.isCancelled, self.lastPong < ping { logger.info("no pong"); task.cancel(with: .goingAway, reason: nil); return }
                    }
                }
            case "event" where id == subId:
                if let ev = m["event"] as? [String: Any] { handle(ev) }
            case "pong": lastPong = max(lastPong, id)
            case "result":
                guard let c = waiting.removeValue(forKey: id) else { continue }
                if m["success"] as? Bool == true { c.resume(returning: m["result"]) }
                else { c.resume(throwing: HaError.server(((m["error"] as? [String: Any])?["message"] as? String) ?? "Failed")) }
            default: break
            }
        }
    }

    private func fetchRegistries() {
        Task {
            async let e = call(["type": "config/entity_registry/list_for_display"])
            async let d = call(["type": "config/device_registry/list"])
            async let a = call(["type": "config/area_registry/list"])
            async let u = call(["type": "auth/current_user"])
            guard let e = try? await e, let d = try? await d, let a = try? await a else { return }
            reg = Self.parseEntityReg(e)
            var da: [String: String] = [:]
            for x in d as? [[String: Any]] ?? [] { if let id = x["id"] as? String, let ar = x["area_id"] as? String { da[id] = ar } }
            deviceArea = da
            areas = (a as? [[String: Any]] ?? []).compactMap { x in
                (x["area_id"] as? String).map { ($0, x["name"] as? String ?? $0) }
            }
            userName = ((try? await u) as? [String: Any])?["name"] as? String
            rebuild(sync: true)
        }
    }

    private func handle(_ ev: [String: Any]) {
        if !gotStates, ev["a"] != nil { states = [:] } // a new subscription starts with every entity: replace, don't merge
        for id in Self.apply(ev, to: &states) { pending[id] = nil }
        let first = !gotStates
        gotStates = true
        rebuild(sync: first)
    }

    private func rebuild(sync: Bool = false) {
        guard gotStates, let reg, let deviceArea, let areas else { return }
        let r = Self.build(states: states, reg: reg, deviceArea: deviceArea, areas: areas)
        if r.home != home { home = r.home }
        if r.cameras != cameras { cameras = r.cameras }
        if sync { saveSnapshot(); onSync?(); onSync = nil }
    }

    // MARK: Commands

    @discardableResult private func send(_ m: [String: Any]) -> Int {
        nextId += 1
        var m = m; m["id"] = nextId
        raw(m)
        return nextId
    }

    private func raw(_ m: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: m), let s = String(data: d, encoding: .utf8) else { return }
        ws?.send(.string(s)) { e in if let e { logger.info("send failed: \(e.localizedDescription, privacy: .public)") } }
    }

    /// Sends a command and waits for its `result`.
    func call(_ m: [String: Any]) async throws -> Any? {
        guard ws != nil, connected else { throw HaError.offline }
        let id = send(m)
        return try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }

    /// The tile tap (SPEC "Tap behavior").
    func tap(_ t: Tile) {
        guard connected, !t.unavailable else { return }
        switch t.domain {
        case "lock":
            switch Self.lockTap(t.s) {
            case .confirmUnlock: unlockAsk = t
            case .lock: service(t.id, "lock", "lock", optimistic: "locking")
            case .none: break
            }
        case "button", "input_button": flash(t.id); service(t.id, t.domain, "press")
        case "scene", "script": flash(t.id); service(t.id, t.domain, "turn_on")
        case "cover": service(t.id, "cover", "toggle", optimistic: ["open", "opening"].contains(t.s) ? "closing" : "opening")
        default: service(t.id, t.domain, "toggle", optimistic: t.s == "on" ? "off" : "on")
        }
    }

    func unlock(_ t: Tile) { service(t.id, "lock", "unlock", optimistic: "unlocking") }

    /// `call_service` with an optional optimistic state; reverted after 5 s without confirmation or on failure.
    func service(_ id: String, _ domain: String, _ service: String, _ data: [String: Any] = [:], optimistic: String? = nil) {
        guard connected else { return }
        var g = 0
        if let o = optimistic, let e = states[id] {
            gen += 1; g = gen
            pending[id] = (pending[id]?.server ?? e.s, g)
            states[id]?.s = o
            rebuild()
            Task { try? await Task.sleep(for: .seconds(5)); revert(id, g) }
        }
        Task {
            do { _ = try await call(["type": "call_service", "domain": domain, "service": service, "service_data": data, "target": ["entity_id": id]]) }
            catch { if g > 0 { revert(id, g) }; show(error.localizedDescription) }
        }
    }

    private func revert(_ id: String, _ g: Int) {
        guard let p = pending[id], p.gen == g else { return }
        pending[id] = nil
        states[id]?.s = p.server
        rebuild()
    }

    private func flash(_ id: String) {
        flashing = id
        Task { try? await Task.sleep(for: .milliseconds(350)); if flashing == id { flashing = nil } }
    }

    func show(_ message: String) {
        toast = message
        Task { try? await Task.sleep(for: .seconds(3)); if toast == message { toast = nil } }
    }

    // MARK: Auth

    func accessToken(force: Bool = false) async throws -> String {
        if !force, let access, !Self.needsRefresh(token: access, expiry: expiry) { return access }
        guard let base, let refresh else { throw HaError.signedOut }
        let (data, code) = try await post(base + "/auth/token", form: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientId])
        if code == 400 { throw HaError.signedOut }
        guard code == 200, let t = Self.obj(data)?["access_token"] as? String else { throw HaError.server("HTTP \(code)") }
        access = t
        expiry = .now + ((Self.obj(data)?["expires_in"] as? Double) ?? 1800)
        return t
    }

    /// Step 1–2 of the login flow; finds the server first (https, then http).
    func signIn(server: String, user: String, password: String) async {
        signInMessage = nil; needsCode = false; flowId = nil
        var found: String?
        for c in Self.candidates(server) {
            guard let u = URL(string: c + "/auth/providers") else { continue }
            var req = URLRequest(url: u); req.timeoutInterval = 6
            guard let res = try? await URLSession.shared.data(for: req), (res.1 as? HTTPURLResponse)?.statusCode == 200 else { continue }
            found = c
            let j = try? JSONSerialization.jsonObject(with: res.0)
            let list = (j as? [String: Any])?["providers"] as? [[String: Any]] ?? j as? [[String: Any]] ?? []
            if !list.contains(where: { $0["type"] as? String == "homeassistant" }) {
                signInMessage = "This server needs a sign-in method Homestill doesn't support yet."; return
            }
            break
        }
        guard let found else { signInMessage = "Can't reach Home Assistant at this address."; return }
        flowBase = found
        do {
            let (d, _) = try await post(found + "/auth/login_flow", json: ["client_id": clientId, "handler": ["homeassistant", NSNull()], "redirect_uri": clientId])
            guard let f = Self.obj(d), let id = f["flow_id"] as? String else { signInMessage = "Unexpected answer from Home Assistant."; return }
            flowId = id
            await step(["client_id": clientId, "username": user, "password": password])
        } catch { signInMessage = error.localizedDescription }
    }

    func submitCode(_ code: String) async { await step(["client_id": clientId, "code": code]) }

    private func step(_ body: [String: Any]) async {
        guard let base = flowBase, let flowId else { return }
        do {
            let (d, _) = try await post(base + "/auth/login_flow/" + flowId, json: body)
            guard let f = Self.obj(d) else { signInMessage = "Unexpected answer from Home Assistant."; return }
            switch (f["type"] as? String, f["step_id"] as? String) {
            case ("create_entry", _):
                guard let code = f["result"] as? String else { return }
                let (td, status) = try await post(base + "/auth/token", form: ["grant_type": "authorization_code", "code": code, "client_id": clientId])
                guard status == 200, let t = Self.obj(td), let a = t["access_token"] as? String, let r = t["refresh_token"] as? String
                else { signInMessage = "Sign-in failed (HTTP \(status))."; return }
                access = a; expiry = .now + ((t["expires_in"] as? Double) ?? 1800)
                refresh = r; Self.saveKeychain(["base": base, "refresh": r])
                needsCode = false; signInMessage = nil; conn = .connecting
                self.base = base
                connect()
            case ("form", "select_mfa_module"):
                let opts = ((f["data_schema"] as? [[String: Any]])?.first?["options"]) as? [Any]
                let first = (opts?.first as? [Any])?.first ?? opts?.first
                await step(["client_id": clientId, "multi_factor_auth_module": first ?? NSNull()])
            case ("form", let s):
                let err = (f["errors"] as? [String: Any])?["base"] as? String
                if s == "mfa" { needsCode = true }
                signInMessage = switch err {
                case nil: nil
                case "invalid_auth": "Wrong username or password."
                case "invalid_code": "Wrong code."
                case let e?: e
                }
            case ("abort", _):
                self.flowId = nil; needsCode = false
                signInMessage = f["reason"] as? String ?? "Sign-in was aborted."
            default: signInMessage = "Unexpected answer from Home Assistant."
            }
        } catch { signInMessage = error.localizedDescription }
    }

    /// Revokes the refresh token (best effort), wipes storage and caches.
    func signOut(message: String? = nil, revoke: Bool = true) {
        let (b, r) = (base, refresh)
        if revoke, let b, let r {
            Task {
                let code = (try? await post(b + "/auth/token", form: ["token": r, "action": "revoke"]))?.1
                logger.info("revoke: HTTP \(code ?? -1, privacy: .public)")
            }
        }
        ws?.cancel(with: .goingAway, reason: nil)
        loop?.cancel(); loop = nil
        base = nil; refresh = nil; access = nil; expiry = .distantPast
        states = [:]; reg = nil; deviceArea = nil; areas = nil; gotStates = false; pending = [:]
        home = []; cameras = []; userName = nil; unlockAsk = nil
        conn = .connecting; needsCode = false; signInMessage = message
        Self.saveKeychain(nil)
        try? FileManager.default.removeItem(at: Self.snapshotURL)
    }

    // MARK: HTTP

    private func post(_ url: String, json: [String: Any]? = nil, form: [String: String]? = nil) async throws -> (Data, Int) {
        guard let u = URL(string: url) else { throw HaError.server("Bad URL") }
        var req = URLRequest(url: u); req.httpMethod = "POST"; req.timeoutInterval = 15
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(Self.formBody(form).utf8)
        }
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func formBody(_ f: [String: String]) -> String {
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return f.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok) ?? "")" }.joined(separator: "&")
    }

    static func obj(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }

    // MARK: Storage

    struct Snapshot: Codable { var home: [Section]; var cameras: [Tile] }
    static let snapshotURL = URL.cachesDirectory.appending(path: "home.json")

    func saveSnapshot() {
        guard signedIn, !home.isEmpty || !cameras.isEmpty, let d = try? JSONEncoder().encode(Snapshot(home: home, cameras: cameras)) else { return }
        try? d.write(to: Self.snapshotURL, options: .atomic)
    }

    private static let kq: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "homestill", kSecAttrAccount as String: "account"]

    static func keychain() -> [String: String]? {
        var q = kq; q[kSecReturnData as String] = true
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: d)
    }

    static func saveKeychain(_ v: [String: String]?) {
        SecItemDelete(kq as CFDictionary)
        guard let v else { return }
        var q = kq
        q[kSecValueData as String] = try? JSONEncoder().encode(v)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
