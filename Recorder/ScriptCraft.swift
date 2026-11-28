import Foundation

// The thinking behind the script writer: your voice, reading a link, the prompts and
// reading the AI's answers back. No UI here (see ScriptWriterView).

// MARK: Your voice

/// What the writer knows about how you talk: a few lines about you and scripts you picked
/// as examples. Kept on the phone in UserDefaults.
struct VoiceProfile: Codable, Equatable {
    /// Who you are, who you talk to, words you use or never use.
    var about = ""
    /// Saved scripts that sound like you.
    var sampleIDs: [UUID] = []

    var isEmpty: Bool { about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sampleIDs.isEmpty }

    private static let key = "script.voiceProfile"

    static func load() -> VoiceProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(VoiceProfile.self, from: data) else { return VoiceProfile() }
        return profile
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// The prompt section that describes your voice, or nil when there is nothing to go on.
    func promptSection(scripts: [Script]) -> String? {
        let samples = sampleIDs.compactMap { id in scripts.first { $0.id == id } }
            .prefix(3)
            .map { String($0.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)) }
            .filter { !$0.isEmpty }
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !about.isEmpty || !samples.isEmpty else { return nil }
        var parts = ["Write it in my voice."]
        if !about.isEmpty { parts.append("About me and my audience:\n\(about)") }
        if !samples.isEmpty {
            parts.append("Scripts I've written. Match their rhythm, sentence length, word choice and attitude. Don't reuse their content:")
            for (i, sample) in samples.enumerated() { parts.append("<example \(i + 1)>\n\(sample)\n</example \(i + 1)>") }
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: Reading a link

/// Fetches a web page and keeps only its readable text, so a script can be written from it.
enum LinkReader {
    struct Page {
        let url: URL
        let title: String
        let text: String
    }

    enum Failure: LocalizedError {
        case badLink, unreadable(Int), tooLittle
        var errorDescription: String? {
            switch self {
            case .badLink: return "That doesn't look like a web link. It should start with https://"
            case .unreadable(let code): return "Couldn't open that page (error \(code)). Paste the main points into the notes instead."
            case .tooLittle: return "Couldn't find readable text on that page. It may need a login or be a video. Paste the main points into the notes instead."
            }
        }
    }

    /// Finds a link typed or pasted on its own, with or without https://.
    static func url(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("\n") else { return nil }
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let host = url.host, host.contains("."),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func read(_ url: URL) async throws -> Page {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Many sites only serve their article to something that looks like a phone browser.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.unreadable(code) }
        let html = String(data: data.prefix(3_000_000), encoding: .utf8)
            ?? String(data: data.prefix(3_000_000), encoding: .isoLatin1) ?? ""
        let page = extract(html: html, url: url)
        guard page.text.count >= 200 else { throw Failure.tooLittle }
        return page
    }

    /// Pulls the title and the main text out of a page. Plain text pages pass straight through.
    static func extract(html: String, url: URL) -> Page {
        guard html.range(of: "<[a-zA-Z!]", options: .regularExpression) != nil else {
            return Page(url: url, title: url.host ?? "", text: String(collapse(html).prefix(15_000)))
        }
        let title = decode(firstMatch(#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']*)"#, in: html)
            ?? firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html) ?? url.host ?? "")
        let summary = firstMatch(#"<meta[^>]+(?:name|property)=["'](?:og:)?description["'][^>]+content=["']([^"']*)"#, in: html)

        var body = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "aside", "form", "iframe"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        // Prefer the article itself over the whole page when the site marks it.
        for tag in ["article", "main"] {
            if let inner = firstMatch("<\(tag)\\b[^>]*>([\\s\\S]*)</\(tag)>", in: body), inner.count > 500 {
                body = inner
                break
            }
        }
        body = body.replacingOccurrences(of: "<(br|/p|/h[1-6]|/li|/div)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        var text = collapse(decode(body))
        if let summary, !summary.isEmpty { text = decode(summary) + "\n\n" + text }
        return Page(url: url, title: collapse(title), text: String(text.prefix(15_000)))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Joins runs of spaces and drops blank lines.
    private static func collapse(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 }
            .joined(separator: "\n")
    }

    private static func decode(_ text: String) -> String {
        var out = text
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&nbsp;": " ", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}",
                     "&ldquo;": "\u{201C}", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}"]
        for (entity, value) in named { out = out.replacingOccurrences(of: entity, with: value) }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return out }
        let ns = out as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let hex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

// MARK: Choices

enum ScriptLength: Int, CaseIterable, Identifiable {
    case fifteen = 15, thirty = 30, sixty = 60, ninety = 90, threeMinutes = 180
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .fifteen: return "15s"
        case .thirty: return "30s"
        case .sixty: return "1 min"
        case .ninety: return "90s"
        case .threeMinutes: return "3 min"
        }
    }
    /// Words at a natural 150 words per minute.
    var words: Int { rawValue * 150 / 60 }
}

enum ScriptTone: String, CaseIterable, Identifiable {
    case conversational, energetic, expert, storytelling, funny
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// How the script ends.
enum CallToAction: String, CaseIterable, Identifiable {
    case auto, follow, comment, save, share, link, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Best fit"
        case .follow: return "Follow for more"
        case .comment: return "Comment"
        case .save: return "Save this"
        case .share: return "Share it"
        case .link: return "Link in bio"
        case .custom: return "My own"
        }
    }
    func instruction(custom: String) -> String {
        switch self {
        case .auto: return "End with the one call to action that fits best (follow, comment, save or share)."
        case .follow: return "End by asking viewers to follow for more on this topic, with a reason to."
        case .comment: return "End by asking viewers one specific question to answer in the comments."
        case .save: return "End by asking viewers to save the video so they have it later."
        case .share: return "End by asking viewers to send it to someone who needs it."
        case .link: return "End by pointing viewers to the link in the bio, saying what they get there."
        case .custom:
            let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? CallToAction.auto.instruction(custom: "") : "End with this call to action, in your own words: \(text)"
        }
    }
}

/// Where a version of the script will be posted.
enum ScriptPlatform: String, CaseIterable, Identifiable {
    case tiktok, reels, facebook
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tiktok: return "TikTok"
        case .reels: return "Instagram Reel"
        case .facebook: return "Facebook"
        }
    }
    var shortLabel: String { self == .reels ? "Reel" : label }
    var marker: String { rawValue.uppercased() }
    var guidance: String {
        switch self {
        case .tiktok:
            return "TIKTOK: 20 to 35 seconds (50 to 85 words). Fastest pace, casual and punchy, hook in the first two seconds, one idea only. Call to action: follow or comment."
        case .reels:
            return "REELS (Instagram): 30 to 60 seconds (75 to 150 words). A little more polished, practical value people want to keep. Call to action: save or share."
        case .facebook:
            return "FACEBOOK: 45 to 90 seconds (110 to 225 words). A bit more context and warmth, explain anything a broader, slightly older audience might not know. Call to action: comment or share."
        }
    }
}

// MARK: Drafts

/// A script in three parts, as the writer shows it.
struct ScriptDraft: Equatable {
    var title: String
    var hook: String
    var body: String
    var callToAction: String

    /// The script as it is read: hook, body and call to action as separate paragraphs.
    var fullText: String {
        [hook, body, callToAction].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var script: Script { Script(title: title, body: fullText) }

    /// Reads "Title:", then HOOK:, BODY: and CTA: sections. Copes with answers that skip any of them.
    static func parse(_ text: String) -> ScriptDraft {
        var title = "AI script"
        var sections: [String: [String]] = [:]
        var current = "BODY"
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "*#_ "))
            let upper = bare.uppercased()
            if upper.hasPrefix("TITLE:") {
                title = String(bare.dropFirst(6)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"*")))
                continue
            }
            if let marker = ["HOOK", "BODY", "CTA", "CALL TO ACTION"].first(where: { upper.hasPrefix($0 + ":") }) {
                current = marker == "CALL TO ACTION" ? "CTA" : marker
                let rest = String(bare.dropFirst(marker.count + 1)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { sections[current, default: []].append(rest) }
                continue
            }
            sections[current, default: []].append(raw)
        }
        func clean(_ key: String) -> String {
            (sections[key] ?? []).joined(separator: "\n")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ScriptDraft(title: title.isEmpty ? "AI script" : title,
                           hook: clean("HOOK"), body: clean("BODY"), callToAction: clean("CTA"))
    }
}

/// One script rewritten for one platform.
struct PlatformVersion: Identifiable, Equatable {
    let platform: ScriptPlatform
    var draft: ScriptDraft
    var id: String { platform.rawValue }

    /// Splits an answer at "=== TIKTOK ===" style markers.
    static func parse(_ text: String) -> [PlatformVersion] {
        var chunks: [ScriptPlatform: [String]] = [:]
        var current: ScriptPlatform?
        for line in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "=#*- ")).uppercased()
            if line.contains("==") || line.hasPrefix("#"),
               let platform = ScriptPlatform.allCases.first(where: { bare == $0.marker || bare.hasPrefix($0.marker) || (bare.contains("INSTAGRAM") && $0 == .reels) }) {
                current = platform
                continue
            }
            if let current { chunks[current, default: []].append(line) }
        }
        return ScriptPlatform.allCases.compactMap { platform in
            guard let lines = chunks[platform] else { return nil }
            var draft = ScriptDraft.parse(lines.joined(separator: "\n"))
            guard !draft.fullText.isEmpty else { return nil }
            draft.title = draft.title == "AI script" ? platform.label : draft.title
            return PlatformVersion(platform: platform, draft: draft)
        }
    }
}

// MARK: Prompts

enum ScriptPrompt {
    private static let rules = """
    You write scripts for short videos (TikTok, Instagram Reels, Facebook) that one person reads aloud from a teleprompter.
    Rules:
    - The hook is the first one or two sentences. It makes a scrolling viewer stop within 3 seconds: a bold claim, a surprising fact, a question or a promise. No greetings, no "Hey guys", no "In this video".
    - Write the way people talk: short sentences, everyday words, contractions. Each sentence easy to say in one breath.
    - The body is short paragraphs separated by one blank line, one idea per paragraph.
    - The call to action is one or two sentences at the end.
    - Plain spoken text only: no headings inside the script, no bullet points, no stage directions, no emojis, no hashtags, no markdown.
    - Keep facts from the notes or source. Don't invent statistics, names, quotes or claims.
    """

    private static let format = """
    Reply in exactly this format and nothing else:
    Title: <a short title, under 8 words>
    HOOK:
    <the hook>
    BODY:
    <the body>
    CTA:
    <the call to action>
    """

    static let system = rules + "\n" + format

    static func make(notes: String, page: LinkReader.Page?, length: ScriptLength, tone: ScriptTone,
                     cta: CallToAction, customCTA: String, voice: String?) -> String {
        var parts = ["Write a \(length.rawValue) second script, about \(length.words) words in total, in a \(tone.rawValue) tone. Stay close to that word count."]
        parts.append(cta.instruction(custom: customCTA))
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("Topic or notes:\n\(notes)") }
        if let page {
            parts.append("""
            Source to base it on (from \(page.url.absoluteString)). Use its facts and ideas, put them in your own words, and don't copy its sentences:
            <source title="\(page.title)">
            \(page.text)
            </source>
            """)
        }
        if let voice { parts.append(voice) }
        return parts.joined(separator: "\n\n")
    }

    static let hooksSystem = rules + """

    Reply with exactly 3 alternative hooks for the script you're given, each a different style (a bold claim, a question, a surprising fact or a tiny story).
    One hook per line, each starting with "1. ", "2. " or "3. ", and nothing else.
    """

    static func hooks(for draft: ScriptDraft, voice: String?) -> String {
        var parts = ["Current hook:\n\(draft.hook)", "Rest of the script:\n\(draft.body)\n\n\(draft.callToAction)"]
        if let voice { parts.append(voice) }
        return parts.joined(separator: "\n\n")
    }

    static func parseHooks(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                guard let range = line.range(of: #"^\s*(\d+[\.\)]|[-•*])\s*"#, options: .regularExpression) else { return nil }
                let hook = line[range.upperBound...].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"*\u{201C}\u{201D}")))
                return hook.isEmpty ? nil : hook
            }
            .prefix(3).map { $0 }
    }

    static let versionsSystem = rules + """

    You turn one script into a version for each platform, keeping the message, the facts and the speaker's voice, but changing length, pace and call to action to suit the platform:
    \(ScriptPlatform.allCases.map(\.guidance).joined(separator: "\n"))
    Reply with the three versions in this exact layout and nothing else:
    === TIKTOK ===
    Title: <title>
    HOOK:
    <hook>
    BODY:
    <body>
    CTA:
    <call to action>
    === REELS ===
    (same layout)
    === FACEBOOK ===
    (same layout)
    """

    static func versions(of script: String, voice: String?) -> String {
        var parts = ["The script:\n<script>\n\(script.trimmingCharacters(in: .whitespacesAndNewlines))\n</script>"]
        if let voice { parts.append(voice) }
        return parts.joined(separator: "\n\n")
    }
}
