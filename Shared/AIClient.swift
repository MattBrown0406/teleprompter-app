import Foundation
import Security

/// Which AI service the user picked. Shared by the recorder (script helper) and the editor (copy, caption fixes).
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic, openai
    var id: String { rawValue }
    var label: String { self == .anthropic ? "Anthropic (Claude)" : "OpenAI" }
    var defaultModel: String { self == .anthropic ? "claude-opus-5-5" : "gpt-5-mini" }
    var keyHint: String { self == .anthropic ? "sk-ant-…" : "sk-…" }
    var consoleURL: URL {
        URL(string: self == .anthropic ? "https://console.anthropic.com/settings/keys" : "https://platform.openai.com/api-keys")!
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case refused
    case empty
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add an Anthropic or OpenAI API key in AI settings first."
        case .http(let code, let message): return "The AI service returned an error (\(code)): \(message)"
        case .refused: return "The AI declined this request."
        case .empty: return "The AI sent back an empty answer."
        }
    }
}

/// API keys live in the iOS Keychain (this device only, never synced or backed up in plain text).
enum KeychainStore {
    private static let service = "cueframe.ai"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, _ account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// One entry point for AI text generation. Uses the provider and key the user set in AISettingsView.
@MainActor
final class AIClient: ObservableObject {
    static let shared = AIClient()

    @Published var provider: AIProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "ai.provider") }
    }
    @Published private(set) var keys: [AIProvider: Bool] = [:]

    private init() {
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .anthropic
        for p in AIProvider.allCases { keys[p] = KeychainStore.read(p.rawValue) != nil }
    }

    /// True when the chosen provider has a key saved.
    var isConfigured: Bool { keys[provider] == true }

    func hasKey(_ p: AIProvider) -> Bool { keys[p] == true }

    func setKey(_ key: String?, for p: AIProvider) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.write(trimmed, p.rawValue)
        keys[p] = KeychainStore.read(p.rawValue) != nil
    }

    func model(for p: AIProvider) -> String {
        let m = UserDefaults.standard.string(forKey: "ai.model.\(p.rawValue)")?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? p.defaultModel : m
    }

    func setModel(_ m: String, for p: AIProvider) {
        UserDefaults.standard.set(m, forKey: "ai.model.\(p.rawValue)")
        objectWillChange.send()
    }

    /// Sends one prompt and returns the reply text.
    func complete(system: String, prompt: String, maxTokens: Int = 4000) async throws -> String {
        let p = provider
        guard let key = KeychainStore.read(p.rawValue) else { throw AIError.notConfigured }
        let model = model(for: p)
        switch p {
        case .anthropic: return try await Self.anthropic(key: key, model: model, system: system, prompt: prompt, maxTokens: maxTokens)
        case .openai: return try await Self.openAI(key: key, model: model, system: system, prompt: prompt, maxTokens: maxTokens)
        }
    }

    /// Cheap request that proves a key works.
    func test(_ p: AIProvider) async throws {
        let saved = provider
        provider = p
        defer { provider = saved }
        _ = try await complete(system: "Reply with the single word OK.", prompt: "Test", maxTokens: 50)
    }

    // MARK: Providers (plain HTTPS: there is no official Swift SDK)

    private static func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(code, String(message.prefix(300)))
        }
        return json
    }

    private static func anthropic(key: String, model: String, system: String, prompt: String, maxTokens: Int) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": max(maxTokens, 1024),
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        var headers = ["x-api-key": key, "anthropic-version": "2026-10-21"]
        if model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5-5") || model.hasPrefix("claude-fable") {
            // Writing short copy: low effort keeps it quick. On a safety decline the API retries on a fallback model.
            body["output_config"] = ["effort": "low"]
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        let json = try await post(URL(string: "https://api.anthropic.com/v1/messages")!, headers: headers, body: body)
        if (json["stop_reason"] as? String) == "refusal" { throw AIError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.empty }
        return text
    }

    private static func openAI(key: String, model: String, system: String, prompt: String, maxTokens: Int) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        let json = try await post(URL(string: "https://api.openai.com/v1/chat/completions")!,
                                  headers: ["Authorization": "Bearer \(key)"], body: body)
        let choices = json["choices"] as? [[String: Any]] ?? []
        let text = (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.empty }
        return text
    }
}
