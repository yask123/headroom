// Headroom's own Claude sign-in.
//
// It's the same browser OAuth that `claude /login` runs (PKCE, a localhost callback), but the
// tokens live in Headroom's own keychain item, so refreshing them never logs Claude Code out.

import AppKit
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class ClaudeAuth {
    static let shared = ClaudeAuth()

    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorize = URL(string: "https://claude.com/cai/oauth/authorize")!
    private static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let profile = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let scopes = "user:profile user:inference"

    struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
        var plan: String?
    }

    private var tokens: Tokens? = Keychain.load()
    private var refreshing: Task<Tokens, Error>?
    private var callback: Callback?

    var isSignedIn: Bool { tokens != nil }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let t = tokens else { throw UsageError.notSignedIn }
        if !forceRefresh, t.expires.timeIntervalSinceNow > 300 { return t.access }
        return try await refreshed().access
    }

    func plan() async -> String? {
        if let p = tokens?.plan { return p }
        guard let access = tokens?.access else { return nil }
        var req = URLRequest(url: Self.profile)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, _) = try? await Fetch.session.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let org = json["organization"] as? [String: Any] else { return nil }
        let type = (org["organization_type"] as? String ?? "").lowercased()
        let tier = (org["rate_limit_tier"] as? String ?? "").lowercased()
        var name: String? = type.contains("max") ? "Max" : type.contains("pro") ? "Pro"
            : type.contains("team") ? "Team" : type.contains("enterprise") ? "Enterprise" : nil
        if name == "Max", let m = tier.firstMatch(of: #/(\d+)x/#) { name = "Max \(m.1)×" }
        tokens?.plan = name
        if let tokens { Keychain.save(tokens) }
        return name
    }

    // MARK: Signing in

    func signIn() async throws {
        cancel()
        let verifier = Self.random(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.random(24)

        let cb = Callback()
        callback = cb
        let port = try await cb.start()
        let redirect = "http://localhost:\(port)/callback"

        var url = URLComponents(url: Self.authorize, resolvingAgainstBaseURL: false)!
        url.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        // `+` would be read as a space by some servers; encode it explicitly.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        NSWorkspace.shared.open(url.url!)

        defer { cb.stop(); if callback === cb { callback = nil } }
        let (code, returnedState) = try await cb.code()
        guard returnedState == state else {
            cb.reply(ok: false)
            throw UsageError.expired("Sign-in didn't match — try again")
        }
        do {
            let t = try await exchange([
                "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                "client_id": Self.clientID, "code_verifier": verifier, "state": state,
            ])
            tokens = t
            Keychain.save(t)
            cb.reply(ok: true)
            NSApp.activate()
        } catch {
            cb.reply(ok: false)
            throw error
        }
    }

    func cancel() {
        callback?.cancel()
        callback = nil
    }

    func signOut() {
        tokens = nil
        Keychain.delete()
    }

    // MARK: Tokens

    private func refreshed() async throws -> Tokens {
        if let refreshing { return try await refreshing.value }
        guard let t = tokens else { throw UsageError.notSignedIn }
        let task = Task { () throws -> Tokens in
            var fresh = try await exchange(["grant_type": "refresh_token", "refresh_token": t.refresh, "client_id": Self.clientID])
            fresh.plan = t.plan
            return fresh
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            Keychain.save(fresh)
            return fresh
        } catch UsageError.http(let code) where code == 400 || code == 401 {
            // The refresh token itself is gone (revoked, or unused for weeks): sign in again.
            signOut()
            throw UsageError.notSignedIn
        }
    }

    private func exchange(_ body: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: Self.token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await Fetch.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UsageError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { throw UsageError.shape }
        let life = (json["expires_in"] as? NSNumber)?.doubleValue ?? 8 * 3600
        return Tokens(access: access, refresh: json["refresh_token"] as? String ?? tokens?.refresh ?? "",
                      expires: .now + life, plan: nil)
    }

    private static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

// MARK: Localhost callback

/// Listens on a random loopback port for the browser's one redirect.
@MainActor
private final class Callback {
    private var listener: NWListener?
    private var waiting: CheckedContinuation<(String, String), Error>?
    private var pending: NWConnection?
    private var result: Result<(String, String), Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            l.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; cont.resume(returning: l.port?.rawValue ?? 0)
                    case .failed(let e): resumed = true; cont.resume(throwing: e)
                    default: break
                    }
                }
            }
            l.start(queue: .main)
        }
    }

    func code() async throws -> (String, String) {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func cancel() { finish(.failure(CancellationError())); stop() }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func finish(_ r: Result<(String, String), Error>) {
        guard result == nil else { return }
        result = r
        waiting?.resume(with: r)
        waiting = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                guard parts.count >= 2, parts[1].hasPrefix("/callback"),
                      let q = URLComponents(string: "http://localhost" + parts[1])?.queryItems else {
                    return self.respond(c, status: "404 Not Found", html: "")
                }
                if let code = q.first(where: { $0.name == "code" })?.value {
                    // Hold the tab until the token exchange settles, so the page tells the truth.
                    self.pending?.cancel()
                    self.pending = c
                    self.finish(.success((code, q.first(where: { $0.name == "state" })?.value ?? "")))
                } else {
                    let why = q.first(where: { $0.name == "error_description" || $0.name == "error" })?.value ?? "Sign-in was cancelled"
                    self.respond(c, status: "200 OK", html: Self.page(ok: false))
                    self.finish(.failure(UsageError.expired(why)))
                }
            }
        }
    }

    func reply(ok: Bool) {
        guard let c = pending else { return }
        pending = nil
        respond(c, status: "200 OK", html: Self.page(ok: ok))
    }

    private func respond(_ c: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private static func page(ok: Bool) -> String {
        let title = ok ? "Headroom is connected" : "That didn't go through"
        let line = ok ? "Your weekly Claude limit is in the menu bar now. You can close this tab."
                      : "Head back to Headroom and press Connect to try again."
        return """
        <!doctype html><meta charset=utf-8><title>Headroom</title>
        <style>
        :root{color-scheme:light dark}
        body{margin:0;height:100vh;display:grid;place-items:center;font:15px/1.5 -apple-system,system-ui;background:#f6f4f1;color:#1d1b19}
        @media (prefers-color-scheme:dark){body{background:#141312;color:#ece8e3}p{color:#9d968e}}
        main{text-align:center;max-width:26rem;padding:2rem}
        h1{font-weight:600;font-size:22px;letter-spacing:-.01em;margin:18px 0 6px}
        p{color:#6f6862;margin:0}
        .dot{width:10px;height:10px;border-radius:50%;margin:auto;background:\(ok ? "#d97757" : "#c44")}
        </style>
        <main><div class=dot></div><h1>\(title)</h1><p>\(line)</p></main>
        """
    }
}

// MARK: Keychain

private enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.yask.headroom",
        kSecAttrAccount as String: "claude",
    ]

    static func load() -> ClaudeAuth.Tokens? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(ClaudeAuth.Tokens.self, from: data)
    }

    static func save(_ t: ClaudeAuth.Tokens) {
        guard let data = try? JSONEncoder().encode(t) else { return }
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var q = base
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
