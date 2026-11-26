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
        struct User: Decodable { let id: String }
    }

    /// A valid access token and the signed-in user id, signing in if needed.
    func session() async throws -> (token: String, userID: String) {
        guard let cfg = SupabaseConfig.current else { throw CloudError.notConfigured }
        if let t = accessToken, let u = userID, expiresAt > Date().addingTimeInterval(60) { return (t, u) }

        if let refresh = KeychainStore.read(Self.refreshAccount) {
            do {
                return try await signIn(cfg, path: "token?grant_type=refresh_token", body: ["refresh_token": refresh])
            } catch CloudError.http(let code, _) where (400..<500).contains(code) {
                // The saved sign-in is no longer valid: start a new anonymous account below.
                // ProjectSync notices the new user id and uploads every local project again.
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
        accessToken = s.access_token
        expiresAt = Date().addingTimeInterval(s.expires_in)
        userID = s.user.id
        return (s.access_token, s.user.id)
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

    private static func send(_ req: URLRequest) async throws -> Data {
        var req = req
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
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
