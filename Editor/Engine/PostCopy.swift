import Foundation
import NaturalLanguage

/// Post captions and hashtags for TikTok, Instagram and Facebook, from what the video says.
enum PostCopy {
    enum Platform: String, CaseIterable, Identifiable {
        case tiktok = "TikTok", instagram = "Instagram", facebook = "Facebook"
        var id: String { rawValue }
        var hashtagCount: Int { self == .instagram ? 12 : self == .tiktok ? 5 : 3 }
        var guidance: String {
            switch self {
            case .tiktok: return "TikTok: one punchy line under 150 characters, then 4 to 6 hashtags mixing broad and niche."
            case .instagram: return "Instagram Reels: a hook line, 2 to 3 short sentences, a call to action, then 10 to 15 relevant hashtags on their own line."
            case .facebook: return "Facebook: a friendly 2 to 4 sentence post with a question to drive comments, then 2 to 3 hashtags."
            }
        }
    }

    /// The words of the video: script if there is one, otherwise transcript, otherwise caption text.
    static func source(_ p: EditProject) -> String {
        if let s = p.transcript, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        if let s = p.scriptText, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        let caps = p.texts.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        return caps
    }

    /// Uses AI when a key is set, otherwise builds hashtags from the video's key words on the phone.
    @MainActor
    static func make(for p: EditProject, platform: Platform) async throws -> String {
        let words = source(p)
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditorError.exportFailed("Make captions first (or record from a script) so there are words to write from.")
        }
        if AIClient.shared.isConfigured {
            let system = """
            You write social media post captions for a creator's short vertical videos. \
            Write in the creator's voice, first person, plain and specific. No emojis unless they fit naturally, at most two. \
            Hashtags must be relevant to the actual content, lower case or camel case, no spaces, and never banned or spammy tags. \
            Reply with only the post text, ready to paste.
            """
            let prompt = """
            \(platform.guidance)

            What the video says:
            \"\"\"
            \(String(words.prefix(8000)))
            \"\"\"
            """
            return try await AIClient.shared.complete(system: system, prompt: prompt, maxTokens: 2000)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return offline(words, platform: platform)
    }

    /// No-AI fallback: the first sentence as the hook, and hashtags from the most-used key words.
    static func offline(_ text: String, platform: Platform) -> String {
        let tags = hashtags(text, count: platform.hashtagCount)
        var hook = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sub, _, _, stop in
            if let sub, sub.trimmingCharacters(in: .whitespaces).count > 12 { hook = sub.trimmingCharacters(in: .whitespacesAndNewlines); stop = true }
        }
        if hook.count > 150 { hook = String(hook.prefix(147)) + "…" }
        return [hook, tags.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func hashtags(_ text: String, count: Int) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .lemma])
        tagger.string = text
        var scores: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            guard tag == .noun || tag == .organizationName || tag == .placeName || tag == .personalName else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? String(text[range])
            let word = Transcriber.normalize(lemma)
            guard word.count >= 4, !stop.contains(word) else { return true }
            scores[word, default: 0] += 1
            return true
        }
        let top = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(count).map { "#\($0.key)" }
        return Array(top)
    }

    private static let stop: Set<String> = ["thing", "things", "today", "time", "people", "way", "something", "everyone",
                                            "anything", "nothing", "lot", "lots", "video", "guys", "kind", "stuff", "year", "day"]
}
