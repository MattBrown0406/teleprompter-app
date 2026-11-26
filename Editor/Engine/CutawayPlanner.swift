import Foundation

/// Asks the AI where a cutaway (B-roll) would help, based on what is said and when.
enum CutawayPlanner {
    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        var start: Double
        var end: Double
        /// What to show, e.g. "Screen recording of the signup page".
        var idea: String
        /// True when it covers a moment you looked away from the lens.
        var coversGlance = false
    }

    /// Timed lines of speech: captions if there are any, otherwise a fresh on-device transcription.
    static func timedLines(_ p: EditProject, progress: (@MainActor (Double) -> Void)? = nil) async throws -> [(Double, Double, String)] {
        var caps = p.texts.filter(\.isCaption).sorted { $0.start < $1.start }
        if caps.isEmpty {
            var o = Captioner.Options()
            o.maxWords = 12
            o.maxSeconds = 6
            o.uppercase = false
            o.script = p.scriptText
            caps = try await Captioner.makeCaptions(for: p, options: o, progress: progress).captions
        }
        return caps.map { ($0.start, $0.end, $0.text) }
    }

    static func suggest(_ p: EditProject, lines: [(Double, Double, String)], glances: [GazeCheck.Span]) async throws -> [Suggestion] {
        guard !lines.isEmpty else { return [] }
        let numbered = lines.map { String(format: "[%.1f-%.1f] %@", $0.0, $0.1, $0.2) }.joined(separator: "\n")
        let glanceText = glances.isEmpty ? "" :
            "\n\nThe speaker looks away from the lens at these times. Cover them if a cutaway makes sense there:\n" +
            glances.map { String(format: "%.1f-%.1f", $0.start, $0.end) }.joined(separator: ", ")
        let count = max(2, min(8, Int(p.duration / 8)))
        let reply = try await AIClient.shared.complete(
            system: """
            You plan B-roll for short talking-head videos (TikTok, Reels, Facebook). Pick moments where a cutaway \
            makes the point clearer or keeps attention: a product, a place, a screen, a before/after, a number. \
            Never cover the first 2 seconds (the hook) or the call to action at the end. Each cutaway is 1.5 to 5 seconds. \
            The person will use their own photos and clips, so describe something they could film or screenshot. \
            Reply with only a JSON array: [{"start": seconds, "end": seconds, "idea": "what to show, under 12 words"}].
            """,
            prompt: "Suggest up to \(count) cutaways for this video (\(String(format: "%.1f", p.duration)) seconds long).\n\nWhat is said, with times:\n\(String(numbered.prefix(12000)))\(glanceText)",
            maxTokens: 2000)
        return parse(reply, duration: p.duration, glances: glances)
    }

    static func parse(_ reply: String, duration: Double, glances: [GazeCheck.Span]) -> [Suggestion] {
        guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
              let data = String(reply[a...b]).data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        var out: [Suggestion] = []
        for item in items {
            guard var s = num(item["start"]), var e = num(item["end"]),
                  let idea = (item["idea"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !idea.isEmpty else { continue }
            s = max(0, min(s, duration - 0.5))
            e = min(duration, max(e, s + 1.5), s + 6)
            guard e - s >= 0.5 else { continue }
            let covers = glances.contains { $0.start < e && $0.end > s }
            out.append(Suggestion(start: s, end: e, idea: idea, coversGlance: covers))
        }
        return out.sorted { $0.start < $1.start }
    }
}
