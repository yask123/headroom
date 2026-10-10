// What's left on each plan, and how it's read.
//
// Claude: the same endpoint behind Claude Code's /usage, with Headroom's own sign-in (ClaudeAuth).
// Codex: the endpoint behind Codex's /status, with the sign-in Codex keeps in ~/.codex/auth.json.

import AppKit
import Foundation
import Observation
import ServiceManagement

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
}

/// One rate-limit window, e.g. "Weekly · all models" or "5-hour session".
struct Window: Identifiable, Equatable {
    var id: String
    var label: String
    var used: Double            // 0…1
    var resetsAt: Date?
    var length: TimeInterval?

    var left: Double { min(1, max(0, 1 - used)) }

    /// How much of the window's time is still to come (0…1), for the even-pace marker.
    func timeLeft(at now: Date = .now) -> Double? {
        guard let resetsAt, let length, length > 0 else { return nil }
        return min(1, max(0, resetsAt.timeIntervalSince(now) / length))
    }
}

struct Snapshot: Equatable {
    var plan: String?
    var weekly: Window?
    var others: [Window]
    var fetched: Date
}

struct ProviderState {
    var snapshot: Snapshot?
    var error: String?
    var needsSignIn = false
    var loading = false
}

enum UsageError: LocalizedError {
    case notSignedIn
    case expired(String)
    case http(Int)
    case shape

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in"
        case .expired(let hint): hint
        case .http(let code): code == 429 ? "Rate limited — trying again soon" : "Couldn't reach the server (\(code))"
        case .shape: "The usage data changed shape"
        }
    }
}

// MARK: Store

@Observable
@MainActor
final class Store {
    static let shared = Store()

    var claude = ProviderState()
    var codex = ProviderState()
    var connecting = false

    var showNumbers = UserDefaults.standard.object(forKey: "showNumbers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNumbers, forKey: "showNumbers") }
    }
    var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            if openAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    let demo = Env.flag("DEMO")

    subscript(p: Provider) -> ProviderState {
        get { p == .claude ? claude : codex }
        set { if p == .claude { claude = newValue } else { codex = newValue } }
    }

    var lastFetched: Date? {
        [claude.snapshot?.fetched, codex.snapshot?.fetched].compactMap { $0 }.max()
    }

    func refresh() async {
        if demo { return loadDemo() }
        async let a: Void = refresh(.claude)
        async let b: Void = refresh(.codex)
        _ = await (a, b)
    }

    func refreshIfStale(_ age: TimeInterval = 60) async {
        guard lastFetched.map({ Date.now.timeIntervalSince($0) > age }) ?? true else { return }
        await refresh()
    }

    func refresh(_ p: Provider) async {
        guard !self[p].loading else { return }
        self[p].loading = true
        defer { self[p].loading = false }
        do {
            let snap = p == .claude ? try await Fetch.claude() : try await Fetch.codex()
            self[p].snapshot = snap
            self[p].error = nil
            self[p].needsSignIn = false
        } catch UsageError.notSignedIn {
            self[p].needsSignIn = true
            self[p].snapshot = nil
        } catch {
            self[p].error = (error as? LocalizedError)?.errorDescription ?? "Offline"
        }
    }

    func connectClaude() {
        guard !connecting else { return }
        connecting = true
        claude.error = nil
        Task {
            defer { connecting = false }
            do {
                try await ClaudeAuth.shared.signIn()
                await refresh(.claude)
            } catch is CancellationError {
            } catch {
                claude.error = (error as? LocalizedError)?.errorDescription ?? "Sign-in didn't finish"
            }
        }
    }

    func cancelConnect() { ClaudeAuth.shared.cancel() }

    func disconnectClaude() {
        ClaudeAuth.shared.signOut()
        claude = ProviderState(needsSignIn: true)
    }

    private func loadDemo() {
        let now = Date.now
        func w(_ id: String, _ label: String, _ used: Double, _ inS: TimeInterval, _ len: TimeInterval) -> Window {
            Window(id: id, label: label, used: used, resetsAt: now + inS, length: len)
        }
        claude.snapshot = Snapshot(plan: "Max 20×", weekly: w("seven_day", "Weekly · all models", 0.12, 4.6 * 86400, 604800),
                                   others: [w("five_hour", "Session", 0.31, 2.2 * 3600, 18000),
                                            w("seven_day_fable", "Weekly · Fable", 0.0, 4.6 * 86400, 604800)],
                                   fetched: now)
        codex.snapshot = Snapshot(plan: "Pro Lite", weekly: w("weekly", "Weekly", 0.34, 3.4 * 86400, 604800),
                                  others: [], fetched: now)
    }
}

// MARK: Fetching

enum Fetch {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    // Claude ------------------------------------------------------------------

    static func claude() async throws -> Snapshot {
        var token = try await ClaudeAuth.shared.accessToken()
        var (data, status) = try await claudeUsage(token)
        if status == 401 {
            token = try await ClaudeAuth.shared.accessToken(forceRefresh: true)
            (data, status) = try await claudeUsage(token)
        }
        guard status == 200 else { throw UsageError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.shape }

        var weekly: Window?
        var others: [Window] = []
        for (key, value) in json {
            guard let w = value as? [String: Any], let pct = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            let resets = (w["resets_at"] as? String).flatMap(ISO.date)
            switch key {
            case "five_hour":
                others.append(Window(id: key, label: "Session", used: pct / 100, resetsAt: resets, length: 5 * 3600))
            case "seven_day":
                weekly = Window(id: key, label: "Weekly · all models", used: pct / 100, resetsAt: resets, length: 7 * 86400)
            case _ where key.hasPrefix("seven_day_") && !key.contains("oauth") && !key.contains("cowork"):
                let model = key.dropFirst("seven_day_".count).split(separator: "_").map { $0.capitalized }.joined(separator: " ")
                others.append(Window(id: key, label: "Weekly · \(model)", used: pct / 100, resetsAt: resets, length: 7 * 86400))
            default: continue
            }
        }
        guard weekly != nil || !others.isEmpty else { throw UsageError.shape }
        others.sort { ($0.id == "five_hour" ? "" : $0.id) < ($1.id == "five_hour" ? "" : $1.id) }
        return Snapshot(plan: await ClaudeAuth.shared.plan(), weekly: weekly, others: others, fetched: .now)
    }

    private static func claudeUsage(_ token: String) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // Codex -------------------------------------------------------------------

    static var codexHome: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func codex() async throws -> Snapshot {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let auth = codexAuth(authURL) else { throw UsageError.notSignedIn }
        var (data, status) = try await codexUsage(auth.access, account: auth.account)
        if status == 401 || status == 403 {
            let fresh = try await refreshCodex(authURL)
            (data, status) = try await codexUsage(fresh, account: auth.account)
        }
        guard status == 200 else { throw UsageError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.shape }

        let limit = json["rate_limit"] as? [String: Any] ?? [:]
        var windows: [Window] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = limit[key] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let length = (w["limit_window_seconds"] as? NSNumber)?.doubleValue
            let resets = (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ?? (w["reset_after_seconds"] as? NSNumber).map { Date.now + $0.doubleValue }
            let label = length.map { $0 >= 6 * 86400 ? "Weekly" : $0 <= 6 * 3600 ? "5-hour session" : Dur.span($0) } ?? "Limit"
            windows.append(Window(id: key, label: label, used: pct / 100, resetsAt: resets, length: length))
        }
        guard !windows.isEmpty else { throw UsageError.shape }
        // The weekly window is the headline; anything shorter sits under it.
        windows.sort { ($0.length ?? 0) > ($1.length ?? 0) }
        let plan = (json["plan_type"] as? String).map(planName)
        return Snapshot(plan: plan, weekly: windows.first, others: Array(windows.dropFirst()), fetched: .now)
    }

    private static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite", "pro_lite": "Pro Lite"
        case "plus": "Plus"
        case "pro": "Pro"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "free": "Free"
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func codexAuth(_ url: URL) -> (access: String, account: String?)? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { return nil }
        return (access, tokens["account_id"] as? String)
    }

    private static func codexUsage(_ token: String, account: String?) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Does what Codex does when its token runs out: trades the refresh token for a new pair and
    /// writes them back into auth.json, so Codex itself stays signed in.
    private static func refreshCodex(_ url: URL) async throws -> String {
        let hint = UsageError.expired("Codex sign-in expired — open Codex once")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = json["tokens"] as? [String: Any],
              let refresh = tokens["refresh_token"] as? String else { throw hint }
        var req = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "grant_type": "refresh_token",
            "refresh_token": refresh, "scope": "openid profile email",
        ])
        let (body, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let out = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = out["access_token"] as? String else { throw hint }
        tokens["access_token"] = access
        for k in ["refresh_token", "id_token"] { if let v = out[k] { tokens[k] = v } }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: .now)
        let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes])
        try updated.write(to: url, options: .atomic)
        return access
    }
}

// MARK: Small helpers

enum Env {
    static func value(_ key: String) -> String? { ProcessInfo.processInfo.environment["HEADROOM_" + key] }
    static func flag(_ key: String) -> Bool { value(key).map { $0 != "0" && !$0.isEmpty } ?? false }
}

enum ISO {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts "2026-10-14T16:00:00.943648+00:00": fractional seconds of any length are dropped.
    static func date(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: trimmed)
    }
}

enum Dur {
    /// "3d 10h", "2h 10m", "12m".
    static func span(_ t: TimeInterval) -> String {
        let m = Int(max(0, t) / 60)
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return mm > 0 ? "\(h)h \(mm)m" : "\(h)h" }
        return "\(max(mm, 1))m"
    }

    /// "Tue 9:00 AM" — or just "4:12 PM" when it's today.
    static func reset(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? "jmm" : "EEE jmm")
        return f.string(from: d)
    }
}
