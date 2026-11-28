import Foundation

/// Long video to short clips: finds the strongest 15 to 90 second moments in what was said,
/// then builds a vertical, captioned project for each.
enum ClipFinder {
    enum Length: String, CaseIterable, Identifiable {
        case short, standard, long
        var id: String { rawValue }
        var range: ClosedRange<Double> {
            switch self {
            case .short: return 15...30
            case .standard: return 30...60
            case .long: return 60...90
            }
        }
        var label: String {
            switch self {
            case .short: return "15–30 s"
            case .standard: return "30–60 s"
            case .long: return "60–90 s"
            }
        }
    }

    struct Moment: Identifiable, Equatable {
        let id = UUID()
        /// Timeline seconds in the long video.
        var start: Double
        var end: Double
        var title: String
        var why: String
        var text: String
        var enabled = true
        var length: Double { end - start }
    }

    // MARK: Finding moments

    /// Uses the AI writer when a key is set, otherwise scores the sentences on the device.
    @MainActor
    static func find(in project: EditProject, length: Length, count: Int) async -> (moments: [Moment], usedAI: Bool, note: String?) {
        let sentences = Transcript.sentences(Transcript.words(project))
        guard !sentences.isEmpty else { return ([], false, "No speech found to pick clips from.") }
        var note: String?
        if AIClient.shared.isConfigured {
            do {
                let found = try await withAI(sentences, length: length, count: count)
                if !found.isEmpty { return (found, true, nil) }
                note = "The AI didn't pick any moments, so these were picked on your iPhone."
            } catch {
                note = "AI unavailable (\(error.localizedDescription)), so these were picked on your iPhone."
            }
        }
        return (onDevice(sentences, length: length, count: count), false, note)
    }

    private static func withAI(_ sentences: [Transcript.Sentence], length: Length, count: Int) async throws -> [Moment] {
        var lines: [String] = []
        var budget = 60_000
        for (i, s) in sentences.enumerated() {
            let line = "[\(i)] \(String(format: "%.1f", s.start))-\(String(format: "%.1f", s.end))s: \(s.text)"
            budget -= line.count
            if budget < 0 { break }
            lines.append(line)
        }
        let r = length.range
        let system = """
        You are a short-form video editor. From a numbered transcript of a long talking video, pick the strongest \
        self-contained moments to post as TikToks, Reels and Facebook videos. A good moment opens with a hook (a bold \
        claim, a question, a surprising fact or a clear promise), makes one complete point, and ends on a finished thought. \
        Never start mid-thought or end mid-sentence. Moments must not overlap. Reply with only JSON: \
        [{"first": <sentence number>, "last": <sentence number>, "title": "<on-screen hook title, at most 7 words>", \
        "why": "<one short sentence on why it works>"}], best first.
        """
        let prompt = "Pick up to \(count) moments, each \(Int(r.lowerBound)) to \(Int(r.upperBound)) seconds long.\n\nTranscript:\n" + lines.joined(separator: "\n")
        let reply = try await AIClient.shared.complete(system: system, prompt: prompt, maxTokens: 3000)
        guard let open = reply.firstIndex(of: "["), let close = reply.lastIndex(of: "]"), open < close,
              let data = String(reply[open...close]).data(using: .utf8),
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw AIError.empty }
        var out: [Moment] = []
        for item in items {
            guard let a = (item["first"] as? NSNumber)?.intValue, let b = (item["last"] as? NSNumber)?.intValue,
                  sentences.indices.contains(a), sentences.indices.contains(b), a <= b else { continue }
            var (first, last) = fit(sentences, first: a, last: b, range: r)
            if out.contains(where: { overlaps($0, sentences[first].start, sentences[last].end) }) {
                // Trim back to the AI's own end if fitting pushed it into a moment already picked.
                (first, last) = (a, b)
                if out.contains(where: { overlaps($0, sentences[a].start, sentences[b].end) }) { continue }
            }
            let title = (item["title"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines)) ?? ""
            out.append(moment(sentences, first, last, title: title.isEmpty ? defaultTitle(sentences[first].text) : title,
                              why: item["why"] as? String ?? ""))
            if out.count >= count { break }
        }
        return out
    }

    /// Widens or narrows a sentence range until it fits the length, adding whole sentences only.
    static func fit(_ s: [Transcript.Sentence], first: Int, last: Int, range: ClosedRange<Double>) -> (Int, Int) {
        var a = first, b = last
        func len() -> Double { s[b].end - s[a].start }
        while len() < range.lowerBound {
            if b + 1 < s.count, s[b + 1].end - s[a].start <= range.upperBound { b += 1 }
            else if a > 0, s[b].end - s[a - 1].start <= range.upperBound { a -= 1 }
            else { break }
        }
        while len() > range.upperBound, b > a { b -= 1 }
        return (a, b)
    }

    private static func overlaps(_ m: Moment, _ s: Double, _ e: Double) -> Bool { s < m.end - 0.2 && e > m.start + 0.2 }

    private static func moment(_ s: [Transcript.Sentence], _ a: Int, _ b: Int, title: String, why: String) -> Moment {
        Moment(start: max(0, s[a].start - 0.15), end: s[b].end + 0.25, title: title, why: why,
               text: s[a...b].map(\.text).joined(separator: " "))
    }

    /// No AI: score every run of whole sentences that fits the length and keep the best that don't overlap.
    static func onDevice(_ s: [Transcript.Sentence], length: Length, count: Int) -> [Moment] {
        let r = length.range
        var candidates: [(score: Double, a: Int, b: Int, why: String)] = []
        for a in s.indices {
            var b = a
            while b < s.count {
                let len = s[b].end - s[a].start
                if len > r.upperBound { break }
                if len >= r.lowerBound {
                    let (score, why) = score(s, a, b, target: (r.lowerBound + r.upperBound) / 2)
                    candidates.append((score, a, b, why))
                }
                b += 1
            }
        }
        if candidates.isEmpty, let whole = s.indices.last {
            // Shorter than the shortest clip: offer the whole talk as one moment.
            return [moment(s, 0, whole, title: defaultTitle(s[0].text), why: "The whole video fits in one clip.")]
        }
        var picked: [Moment] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            let m = moment(s, c.a, c.b, title: defaultTitle(s[c.a].text), why: c.why)
            guard !picked.contains(where: { overlaps($0, m.start, m.end) }) else { continue }
            picked.append(m)
            if picked.count >= count { break }
        }
        return picked
    }

    private static let hookWords: Set<String> = ["you", "your", "why", "how", "what", "stop", "never", "secret", "mistake",
        "mistakes", "truth", "nobody", "everyone", "best", "worst", "biggest", "first", "only", "simple", "easy", "fast",
        "money", "free", "need", "want", "should", "dont", "cant", "wrong", "actually", "most", "real", "here", "this"]
    private static let closers: Set<String> = ["so", "that", "remember", "bottom", "line", "follow", "try", "start", "comment", "share"]

    private static func score(_ s: [Transcript.Sentence], _ a: Int, _ b: Int, target: Double) -> (Double, String) {
        let opener = s[a].text
        let first = opener.split(separator: " ").prefix(8).map { Transcriber.normalize(String($0)) }
        var score = 0.0
        var reasons: [String] = []
        let hooks = first.filter { hookWords.contains($0) }.count
        if opener.contains("?") { score += 2; reasons.append("opens with a question") }
        if hooks > 0 { score += min(3, Double(hooks)); if reasons.isEmpty { reasons.append("strong opening line") } }
        if opener.rangeOfCharacter(from: .decimalDigits) != nil { score += 1.5; reasons.append("has a number up front") }
        // Joined-on openers ("and", "but", "so") usually depend on what came before.
        if let w = first.first, ["and", "but", "so", "because", "which", "also", "or"].contains(w) { score -= 3 }
        // Lively delivery: more words per second, few fillers, few long pauses.
        let words = s[a...b].flatMap(\.words)
        let len = s[b].end - s[a].start
        let rate = Double(words.count) / max(1, len)
        score += min(2, max(0, (rate - 1.8) * 2))
        let fillers = words.filter { AutoCut.fillers.contains(Transcriber.normalize($0.text)) }.count
        score -= Double(fillers) * 0.5
        var gaps = 0
        for k in a..<b where s[k + 1].start - s[k].end > 1.5 { gaps += 1 }
        score -= Double(gaps)
        let lastWords = s[b].text.split(separator: " ").map { Transcriber.normalize(String($0)) }
        if lastWords.contains(where: closers.contains) || s[b].text.hasSuffix("!") { score += 1; reasons.append("ends on a clear point") }
        // Prefer lengths near the middle of the range.
        score -= abs(len - target) / target
        if reasons.isEmpty { reasons.append("steady, clear delivery") }
        return (score, reasons.prefix(2).joined(separator: ", ").capitalizedFirst + ".")
    }

    static func defaultTitle(_ sentence: String) -> String {
        let words = sentence.split(separator: " ").prefix(7).joined(separator: " ")
        return words.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!"))
    }

    // MARK: Making clips

    struct MakeOptions {
        var titleOnScreen = true
        var tighten = true
        var addToCalendar = true
    }

    /// A new vertical project for one moment: its pieces of footage, face-following crop,
    /// captions in the long video's caption style, and the hook title on screen.
    static func makeProject(_ m: Moment, from source: EditProject, options: MakeOptions) async -> EditProject {
        let starts = source.clipStarts
        var p = EditProject(name: m.title, canvas: .vertical, quality: source.quality)
        p.background = source.background
        p.autoReframe = true
        p.logo = source.logo
        p.transcript = m.text
        // Pieces of each clip that fall inside the moment.
        var newIDs: [UUID: UUID] = [:]
        for (i, c) in source.clips.enumerated() where !c.isBrandClip {
            let cs = starts[i], ce = cs + c.outputDuration
            let s = max(m.start, cs), e = min(m.end, ce)
            guard e - s >= 0.2 else { continue }
            var piece = c
            piece.id = UUID()
            piece.trimStart = c.trimStart + (s - cs) * c.speed
            piece.trimEnd = c.trimStart + (e - cs) * c.speed
            piece.transitionOut = .none
            newIDs[c.id] = piece.id
            p.clips.append(piece)
        }
        // Keep brand intro and outro if the long video had them.
        if let intro = source.clips.first(where: { $0.role == .intro }) { var c = intro; c.id = UUID(); p.clips.insert(c, at: 0) }
        if let outro = source.clips.last(where: { $0.role == .outro }) { var c = outro; c.id = UUID(); p.clips.append(c) }
        var words: [String: [SpokenWord]] = [:]
        for c in p.clips where !c.isBrandClip { words[c.path] = source.spokenWords?[c.path] }
        p.spokenWords = words

        // Captions from words already heard, in the long video's caption style.
        let preset = CaptionPreset(captionsOf: source)
        var opts = preset?.options ?? Captioner.Options()
        if preset == nil { opts.style = Captioner.style(for: opts.look) }
        let spoken = Transcript.words(p).filter { !AutoCut.fillers.contains(Transcriber.normalize($0.text)) }
            .map { SpokenWord(text: $0.text, start: $0.start, end: $0.end) }
        p.texts = Captioner.group(spoken, options: opts, duration: p.duration)

        if options.titleOnScreen {
            let intro = p.clips.first?.role == .intro ? p.clips[0].outputDuration : 0
            var item = TextItem(text: m.title, start: intro, end: min(p.duration, intro + 3))
            item.center = NPoint(x: 0.5, y: 0.22)
            item.style.size = 0.08
            item.style.background = .box
            item.animation = .pop
            if let kit = BrandStore.current {
                item.style.font = kit.font
                item.style.customFont = kit.customFontName
                item.style.backgroundColor = RGBA(r: kit.primary.r, g: kit.primary.g, b: kit.primary.b, a: 0.9)
            }
            p.texts.append(item)
        }

        if options.tighten {
            // Close up long pauses and "um"s inside the clip. Captions move with the cuts.
            var tight = AutoCut.Options()
            tight.cutRetakes = false
            if let cuts = try? await Transcript.autoClean(p, options: tight, progress: { _ in }) {
                AutoCut.apply(cuts, to: &p)
            }
        }
        return p
    }

    /// Puts a clip on the posting calendar as a planned post, one per day from tomorrow.
    @MainActor
    static func schedule(_ p: EditProject, dayOffset: Int) {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: 1 + dayOffset, to: PostPlan.nextSlot) ?? PostPlan.nextSlot
        var plan = PostPlan.new(title: p.name, at: base)
        plan.projectID = p.id
        plan.duration = p.duration
        plan.script = p.transcript
        plan.notes = "Clip from a longer video. Open it in Edit to export, then post."
        PostStore.shared.save(plan)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
