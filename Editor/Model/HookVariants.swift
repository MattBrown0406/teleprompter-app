import Foundation

/// Another opening line for the same video. The original hook is version A; each variant swaps
/// the opening clips for its own take and exports as its own video, so you can test which one works.
struct HookVariant: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    /// "B", "C", "D".
    var name: String
    /// The line to say.
    var line: String
    /// The recorded or imported take of this line.
    var clip: ClipItem?
    /// Captions for the take, timed from the start of the hook. Made when the take is added,
    /// if the video has captions.
    var captions: [TextItem]?
}

/// Works out the hook part of a project and builds a version of the project for each variant.
enum HookPlanner {
    static let letters = ["B", "C", "D"]
    static let maxVariants = 3

    /// Clip indices that make up the original hook: from the first non-intro clip to the marked end.
    static func hookRange(_ p: EditProject) -> ClosedRange<Int>? {
        guard let endID = p.hookEndClipID, let hi = p.clips.firstIndex(where: { $0.id == endID }) else { return nil }
        guard let lo = p.clips.firstIndex(where: { $0.role != .intro }), lo <= hi, !p.clips[hi].isBrandClip else { return nil }
        return lo...hi
    }

    /// Timeline span of the original hook: where it starts, and where the rest of the video begins.
    static func hookSpan(_ p: EditProject) -> (start: Double, end: Double)? {
        guard let r = hookRange(p) else { return nil }
        let starts = p.clipStarts
        let end = r.upperBound + 1 < p.clips.count ? starts[r.upperBound + 1] : p.duration
        return (starts[r.lowerBound], end)
    }

    /// What was said in the hook, from its captions (or the script's first sentence).
    static func originalLine(_ p: EditProject) -> String {
        if let span = hookSpan(p) {
            let words = p.texts.filter { $0.isCaption && $0.start >= span.start - 0.05 && $0.start < span.end - 0.05 }
                .sorted { $0.start < $1.start }.map(\.text)
            if !words.isEmpty { return words.joined(separator: " ") }
        }
        return firstSentence(p.scriptText ?? p.transcript ?? "")
    }

    static func firstSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        var out = ""
        for ch in t {
            if ch == "\n" { break }
            out.append(ch)
            if ".?!".contains(ch) && out.count > 8 { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Time where the script's first sentence ends, using word-timed captions. Nil if it can't tell.
    static func detectHookEnd(_ p: EditProject) -> Double? {
        let sentence = firstSentence(p.scriptText ?? "")
        let n = ScriptAligner.tokens(sentence).count
        guard n > 0 else { return nil }
        var ends: [Double] = []
        for item in p.texts where item.isCaption {
            if let words = item.words, !words.isEmpty {
                ends += words.map { item.start + $0.end }
            } else {
                // No word timing: spread the line's words evenly.
                let count = max(1, item.text.split(separator: " ").count)
                for k in 1...count { ends.append(item.start + item.duration * Double(k) / Double(count)) }
            }
        }
        ends.sort()
        guard ends.count >= n else { return nil }
        return min(p.duration, ends[n - 1] + 0.15)
    }

    /// The project as it would be with this variant's take as the opening. Nil if it has no take
    /// or the hook isn't marked.
    static func project(_ p: EditProject, with v: HookVariant) -> EditProject? {
        guard let range = hookRange(p), let span = hookSpan(p), var take = v.clip, take.sourceDuration > 0 else { return nil }
        let first = p.clips[range.lowerBound], last = p.clips[range.upperBound]
        // Same look as the original opening.
        take.id = UUID()
        take.filter = first.filter
        take.filterAmount = first.filterAmount
        take.adjust = first.adjust
        take.fit = first.fit
        take.zoom = first.zoom
        take.offset = first.offset
        take.transitionOut = last.transitionOut
        take.transitionDuration = last.transitionDuration
        take.role = nil

        var q = p
        q.id = UUID()
        q.name = p.name + " hook " + v.name
        q.hooks = nil
        q.clips.replaceSubrange(range, with: [take])
        q.hookEndClipID = take.id
        let newEnd = range.lowerBound + 1 < q.clips.count ? q.clipStarts[range.lowerBound + 1] : q.duration
        let delta = newEnd - span.end

        func insideHook(_ s: Double, _ e: Double) -> Bool { s >= span.start - 0.05 && e <= span.end + 0.05 }

        q.texts = p.texts.compactMap { t in
            var t = t
            if insideHook(t.start, t.end) {
                // The old hook's captions are replaced by the take's own; other text stays, cut to fit.
                if t.isCaption { return nil }
                t.end = min(t.end, newEnd)
                return t.end - t.start > 0.2 ? t : nil
            }
            if t.start >= span.end - 0.05 {
                t.start += delta
                t.end += delta
            } else if t.end > span.end {
                t.end += delta
            }
            return t
        }
        for c in v.captions ?? [] {
            var c = c
            c.id = UUID()
            c.start += span.start
            c.end += span.start
            guard c.start < newEnd else { continue }
            c.end = min(c.end, newEnd)
            q.texts.append(c)
        }

        q.audio = p.audio.compactMap { a in
            var a = a
            if a.start <= span.start + 0.05 && a.end > span.end - 0.05 {
                // Music under the whole video: make it longer or shorter with the video.
                a.duration = max(0.2, a.duration + delta)
                if !a.loop { a.duration = min(a.duration, a.sourceDuration - a.sourceStart) }
                return a
            }
            if insideHook(a.start, a.end) { return nil }
            if a.start >= span.end - 0.05 { a.start += delta }
            return a
        }

        q.overlays = p.overlays?.compactMap { o in
            var o = o
            if insideHook(o.start, o.end) { return nil }
            if o.start >= span.end - 0.05 { o.start += delta }
            return o
        }

        let d = q.duration
        q.texts = q.texts.filter { $0.start < d - 0.1 }.map { var t = $0; t.end = min(t.end, d); return t }
        for i in q.audio.indices { q.audio[i].duration = max(0.2, min(q.audio[i].duration, d - q.audio[i].start)) }
        q.audio.removeAll { $0.start >= d - 0.1 }
        q.overlays = q.overlays?.filter { $0.start < d - 0.1 }.map { var o = $0; o.duration = min(o.duration, d - o.start); return o }
        return q
    }

    /// Every version to export: the original first, then each variant with a take.
    static func versions(_ p: EditProject) -> [(label: String, project: EditProject)] {
        var out: [(label: String, project: EditProject)] = [(label: "Hook A", project: p)]
        for v in p.hooks ?? [] {
            if let q = project(p, with: v) { out.append((label: "Hook \(v.name)", project: q)) }
        }
        return out
    }
}
