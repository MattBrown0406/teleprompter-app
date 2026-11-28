import AVFoundation

/// The project's speech laid out on the timeline, for editing by text and finding clips.
enum Transcript {
    /// A spoken word in a clip, with its source time (in the file) and its timeline time.
    struct Word: Identifiable, Equatable {
        var id: String { "\(clipID.uuidString)-\(sourceStart)" }
        let clipID: UUID
        let text: String
        let sourceStart: Double
        let sourceEnd: Double
        let start: Double
        let end: Double
    }

    /// What the transcript editor shows: words, and the gaps between them worth cutting.
    struct Token: Identifiable, Equatable {
        enum Kind: Equatable { case word, gap }
        let id: String
        let kind: Kind
        let clipID: UUID
        /// Source seconds of the part this token stands for.
        let sourceStart: Double
        let sourceEnd: Double
        /// Timeline seconds.
        let start: Double
        let end: Double
        let text: String
        var isFiller: Bool { kind == .word && AutoCut.fillers.contains(Transcriber.normalize(text)) }
        var length: Double { sourceEnd - sourceStart }
    }

    /// A sentence (or a phrase ended by a long pause), in timeline seconds.
    struct Sentence: Equatable {
        var start: Double
        var end: Double
        var text: String
        var words: [Word]
    }

    /// Gaps shorter than this aren't shown as their own token.
    static let minGap = 0.45
    /// Breath left in when a gap is cut.
    static let keepGap = 0.25

    /// Clips whose sound has not been transcribed yet (by file).
    static func missingPaths(_ p: EditProject) -> [String] {
        var seen = Set<String>()
        return p.clips.compactMap { c in
            guard !c.isBrandClip, c.trimmedDuration > 0.3, p.spokenWords?[c.path] == nil, !seen.contains(c.path) else { return nil }
            seen.insert(c.path)
            return c.path
        }
    }

    /// Every cached word that is still in the edit, in timeline order.
    static func words(_ p: EditProject) -> [Word] {
        let starts = p.clipStarts
        var out: [Word] = []
        for (i, c) in p.clips.enumerated() where !c.isBrandClip {
            guard let list = p.spokenWords?[c.path] else { continue }
            for w in list {
                let mid = (w.start + w.end) / 2
                guard mid >= c.trimStart, mid < c.effectiveTrimEnd else { continue }
                let s = max(w.start, c.trimStart), e = min(w.end, c.effectiveTrimEnd)
                out.append(Word(clipID: c.id, text: w.text, sourceStart: s, sourceEnd: e,
                                start: starts[i] + (s - c.trimStart) / c.speed,
                                end: starts[i] + (e - c.trimStart) / c.speed))
            }
        }
        return out
    }

    /// Words plus the pauses between them (and the dead air at the ends of each clip).
    static func tokens(_ p: EditProject) -> [Token] {
        let starts = p.clipStarts
        let all = words(p)
        var out: [Token] = []
        for (i, c) in p.clips.enumerated() where !c.isBrandClip {
            let mine = all.filter { $0.clipID == c.id }
            func time(_ s: Double) -> Double { starts[i] + (s - c.trimStart) / c.speed }
            func gap(_ a: Double, _ b: Double) {
                guard b - a >= minGap else { return }
                out.append(Token(id: "g-\(c.id.uuidString)-\(a)", kind: .gap, clipID: c.id, sourceStart: a, sourceEnd: b,
                                 start: time(a), end: time(b), text: String(format: "%.1fs", b - a)))
            }
            guard !mine.isEmpty else {
                // A clip with no speech: show it as one silent stretch.
                gap(c.trimStart, c.effectiveTrimEnd)
                continue
            }
            var cursor = c.trimStart
            for w in mine {
                gap(cursor, w.sourceStart)
                out.append(Token(id: "w-\(w.id)", kind: .word, clipID: c.id, sourceStart: w.sourceStart, sourceEnd: w.sourceEnd,
                                 start: w.start, end: w.end, text: w.text))
                cursor = max(cursor, w.sourceEnd)
            }
            gap(cursor, c.effectiveTrimEnd)
        }
        return out
    }

    /// Turns struck tokens into cuts. A struck word takes the pause after it with it, so the
    /// sentence closes up the way it would if you had never said the word.
    static func cuts(for struck: Set<String>, in tokens: [Token], project p: EditProject) -> [AutoCut.Cut] {
        var cuts: [AutoCut.Cut] = []
        for (k, t) in tokens.enumerated() where struck.contains(t.id) {
            guard let clip = p.clips.first(where: { $0.id == t.clipID }) else { continue }
            let prev = k > 0 && tokens[k - 1].clipID == t.clipID ? tokens[k - 1] : nil
            let next = k + 1 < tokens.count && tokens[k + 1].clipID == t.clipID ? tokens[k + 1] : nil
            var s: Double, e: Double
            switch t.kind {
            case .word:
                s = max(prev?.sourceEnd ?? clip.trimStart, t.sourceStart - 0.03)
                if let next, next.kind == .word {
                    e = max(t.sourceEnd, next.sourceStart - 0.03)
                } else {
                    e = min(next?.sourceStart ?? clip.effectiveTrimEnd, t.sourceEnd + 0.06)
                }
            case .gap:
                let atStart = prev == nil, atEnd = next == nil
                s = atStart ? t.sourceStart : t.sourceStart + keepGap / 2
                e = atEnd ? t.sourceEnd : t.sourceEnd - keepGap / 2
            }
            s = max(s, clip.trimStart)
            e = min(e, clip.effectiveTrimEnd)
            guard e - s > 0.05 else { continue }
            cuts.append(AutoCut.Cut(clipID: t.clipID, kind: t.kind == .gap ? .pause : (t.isFiller ? .filler : .retake),
                                    start: s, end: e, text: t.text))
        }
        // Merge per clip so neighbouring cuts become one.
        var merged: [AutoCut.Cut] = []
        for c in p.clips {
            let mine = cuts.filter { $0.clipID == c.id }
            guard !mine.isEmpty else { continue }
            merged += AutoCut.merge(mine, clipStart: c.trimStart, clipEnd: c.effectiveTrimEnd)
        }
        return merged
    }

    /// Marks the tokens an auto-cut pass would remove.
    static func struck(by cuts: [AutoCut.Cut], tokens: [Token]) -> Set<String> {
        var out = Set<String>()
        for t in tokens {
            let mid = (t.sourceStart + t.sourceEnd) / 2
            if cuts.contains(where: { $0.clipID == t.clipID && mid > $0.start && mid < $0.end }) { out.insert(t.id) }
        }
        return out
    }

    /// Splits the words into sentences, using punctuation and long pauses.
    static func sentences(_ words: [Word]) -> [Sentence] {
        var out: [Sentence] = []
        var line: [Word] = []
        func flush() {
            guard let f = line.first, let l = line.last else { return }
            out.append(Sentence(start: f.start, end: l.end, text: line.map(\.text).joined(separator: " "), words: line))
            line.removeAll()
        }
        for w in words {
            if let last = line.last, w.start - last.end > 1.2 { flush() }
            line.append(w)
            let ends = w.text.last.map { ".!?".contains($0) } ?? false
            if ends || line.count >= 45 { flush() }
        }
        flush()
        return out
    }
}

extension Transcript {
    /// Runs the auto-cut rules (pauses, dead air, "um"s, restarted lines) on the words already heard,
    /// so the transcript editor can show what it would cut.
    static func autoClean(_ p: EditProject, options: AutoCut.Options,
                          progress: @escaping @MainActor (Double) -> Void) async throws -> [AutoCut.Cut] {
        let clips = p.clips.filter { !$0.isBrandClip && $0.trimmedDuration > 0.5 }
        var cuts: [AutoCut.Cut] = []
        for (n, clip) in clips.enumerated() {
            await progress(Double(n) / Double(max(1, clips.count)))
            let words = (p.spokenWords?[clip.path] ?? []).filter {
                let mid = ($0.start + $0.end) / 2
                return mid >= clip.trimStart && mid < clip.effectiveTrimEnd
            }
            let rate = 16_000.0, window = 0.02
            let range = CMTimeRange(start: clip.trimStart.cmTime, duration: clip.trimmedDuration.cmTime)
            let samples = (try? await AudioPCM.read(url: clip.url, sampleRate: rate, range: range)) ?? []
            let levels = AudioPCM.levels(samples, sampleRate: rate, window: window)
            cuts += AutoCut.findCuts(clip: clip, words: words, levels: levels, window: window, options: options)
        }
        await progress(1)
        return cuts
    }
}
