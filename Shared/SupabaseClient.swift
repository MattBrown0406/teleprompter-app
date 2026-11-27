import Foundation

/// Where the app's Supabase project lives. Read from Info.plist (SupabaseURL, SupabaseKey in project.yml).
/// When either is blank, cloud backup is off and the app works purely on the phone.
struct SupabaseConfig {
    let url: URL
    /// The publishable (anon) key. Safe to ship in the app: row level security limits each user to their own rows.
    let key: String

    static let current: SupabaseConfig? = {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              let k = Bundle.main.object(forInfoDictionaryKey: "SupabaseKey") as? String,
              !s.isEmpty, !k.isEmpty, let url = URL(string: s) else { return nil }
        return SupabaseConfig(url: url, key: k)
    }()
}

enum CloudError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud backup isn't set up in this build."
        case .http(let code, let message): return "The cloud returned an error (\(code)): \(message)"
        case .badResponse: return "The cloud sent back something unexpected."
        }
    }
}

/// A small Supabase client over URLSession: anonymous sign-in plus PostgREST calls.
/// No sign-in screen: each install gets its own private account, kept in the Keychain so it
/// survives app updates (and reinstalls on the same phone).
actor SupabaseClient {
    static let shared = SupabaseClient()

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private(set) var userID: String?

    private static let refreshAccount = "supabase.refresh"
    private static let userAccount = "supabase.user"

    private struct AuthSession: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
        struct User: Decodable {
            let id: String
            let email: String?
            let is_anonymous: Bool?
        }
    }

    /// The email of the signed-in account, or nil for the automatic (anonymous) one.
    private(set) var email: String? = KeychainStore.read("supabase.email")

    /// The sign-in in flight, shared by every caller that needs a token meanwhile.
    private var signingIn: Task<(token: String, userID: String), Error>?

    /// A valid access token and the signed-in user id, signing in if needed.
    func session() async throws -> (token: String, userID: String) {
        guard let cfg = SupabaseConfig.current else { throw CloudError.notConfigured }
        if let t = accessToken, let u = userID, expiresAt > Date().addingTimeInterval(60) { return (t, u) }
        // Project and footage backup ask at the same time. Without this, both would spend the same
        // refresh token (Supabase rotates it), and the loser could end up on a brand-new account.
        if let signingIn { return try await signingIn.value }
        let task = Task { try await self.refreshOrSignUp(cfg) }
        signingIn = task
        defer { signingIn = nil }
        return try await task.value
    }

    private func refreshOrSignUp(_ cfg: SupabaseConfig) async throws -> (token: String, userID: String) {
        if let refresh = KeychainStore.read(Self.refreshAccount) {
            do {
                return try await signIn(cfg, path: "token?grant_type=refresh_token", body: ["refresh_token": refresh])
            } catch CloudError.http(let code, _) where code == 400 || code == 401 || code == 403 {
                // The saved sign-in is no longer valid: start a new anonymous account below.
                // ProjectSync notices the new user id and uploads every local project again.
                // Anything else (rate limit, server error, offline) is passed on and retried later,
                // so a busy moment never swaps the account.
            }
        }
        return try await signIn(cfg, path: "signup", body: ["data": [String: String]()])
    }

    private func signIn(_ cfg: SupabaseConfig, path: String, body: [String: Any]) async throws -> (token: String, userID: String) {
        var req = URLRequest(url: URL(string: "auth/v1/\(path)", relativeTo: cfg.url)!)
        req.httpMethod = "POST"
        req.setValue(cfg.key, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await Self.send(req)
        guard let s = try? JSONDecoder().decode(AuthSession.self, from: data) else { throw CloudError.badResponse }
        // Save the refresh token first: Supabase rotates it, and losing it means a new account.
        KeychainStore.write(s.refresh_token, Self.refreshAccount)
        KeychainStore.write(s.user.id, Self.userAccount)
        let mail = (s.user.is_anonymous == true) ? nil : s.user.email
        KeychainStore.write(mail, "supabase.email")
        email = mail
        accessToken = s.access_token
        expiresAt = Date().addingTimeInterval(s.expires_in)
        userID = s.user.id
        return (s.access_token, s.user.id)
    }

    // MARK: Email sign-in (so projects and footage follow you to a new phone)

    /// Emails a one-time code. Creates the account the first time.
    func sendCode(to email: String) async throws {
        guard let cfg = SupabaseConfig.current else { throw CloudError.notConfigured }
        var req = URLRequest(url: URL(string: "auth/v1/otp", relativeTo: cfg.url)!)
        req.httpMethod = "POST"
        req.setValue(cfg.key, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "create_user": true])
        _ = try await Self.send(req)
    }

    /// Signs in with the emailed code. From then on this phone uses that account.
    func verify(email: String, code: String) async throws {
        guard let cfg = SupabaseConfig.current else { throw CloudError.notConfigured }
        _ = try await signIn(cfg, path: "verify", body: ["type": "email", "email": email, "token": code])
    }

    /// Back to an automatic account for this phone. Nothing on the phone is deleted.
    func signOut() {
        KeychainStore.write(nil, Self.refreshAccount)
        KeychainStore.write(nil, Self.userAccount)
        KeychainStore.write(nil, "supabase.email")
        accessToken = nil
        userID = nil
        email = nil
    }

    // MARK: Storage

    /// A request to the Storage API with the user's token, e.g. `storage("object/footage/…")`.
    func storageRequest(_ path: String, method: String) async throws -> URLRequest {
        guard let cfg = SupabaseConfig.current else { throw CloudError.notConfigured }
        let (token, _) = try await session()
        var req = URLRequest(url: URL(string: "storage/v1/\(path)", relativeTo: cfg.url)!.absoluteURL)
        req.httpMethod = method
        req.setValue(cfg.key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Adds fresh auth headers to a request built elsewhere (resumable upload chunks).
    func authorize(_ req: inout URLRequest) async throws {
        guard let cfg = SupabaseConfig.current else { throw CloudError.notConfigured }
        let (token, _) = try await session()
        req.setValue(cfg.key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Calls a PostgREST endpoint, e.g. `rest("projects?select=id", method: "GET")`.
    func rest(_ pathAndQuery: String, method: String, body: Data? = nil, prefer: String? = nil) async throws -> Data {
        guard let cfg = SupabaseConfig.current else { throw CloudError.notConfigured }
        let (token, _) = try await session()
        var req = URLRequest(url: URL(string: "rest/v1/\(pathAndQuery)", relativeTo: cfg.url)!)
        req.httpMethod = method
        req.setValue(cfg.key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        req.httpBody = body
        do {
            return try await Self.send(req)
        } catch CloudError.http(401, _) {
            // Token went stale early (clock change, revoked): refresh once and retry.
            accessToken = nil
            let (fresh, _) = try await session()
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            return try await Self.send(req)
        }
    }

    static func send(_ req: URLRequest, using session: URLSession = .shared) async throws -> Data {
        var req = req
        req.timeoutInterval = 90
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["message"] as? String ?? $0["msg"] as? String ?? $0["error_description"] as? String }
                ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw CloudError.http(http.statusCode, message)
        }
        return data
    }
}
