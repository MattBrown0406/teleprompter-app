import AVFoundation

/// Finds the bits of a take worth cutting: long pauses, filler words ("um", "uh") and restarted lines.
enum AutoCut {
    enum Kind: String, CaseIterable {
        case deadAir, pause, filler, retake
        var label: String {
            switch self {
            case .deadAir: return "Dead air"
            case .pause: return "Pause"
            case .filler: return "Filler"
            case .retake: return "Retake"
            }
        }
        var symbol: String {
            switch self {
            case .deadAir: return "hourglass"
            case .pause: return "pause.circle"
            case .filler: return "waveform.badge.minus"
            case .retake: return "arrow.counterclockwise"
            }
        }
    }

    struct Options: Equatable {
        var minPause = 0.7            // seconds of silence before it counts
        var keepPause = 0.25          // natural breath left in at each cut
        var cutFillers = true
        var cutRetakes = true
    }

    struct Cut: Identifiable, Equatable {
        let id = UUID()
        let clipID: UUID
        let kind: Kind
        /// Source seconds in the clip's file.
        var start: Double
        var end: Double
        var text: String
        var enabled = true
        var length: Double { end - start }
    }

    struct Analysis {
        var cuts: [Cut]
        var transcript: String
        /// Set when speech recognition failed, so only silences could be found.
        var speechProblem: String?
    }

    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh", "hmm", "mm", "mhm"]

    /// Analyses every non-brand clip. Speech recognition runs on the device.
    static func analyze(_ project: EditProject, options: Options,
                        progress: @escaping @MainActor (String, Double) -> Void) async throws -> Analysis {
        var cuts: [Cut] = []
        var transcript: [String] = []
        var speechProblem: String?
        let clips = project.clips.filter { !$0.isBrandClip && $0.trimmedDuration > 0.5 }
        for (n, clip) in clips.enumerated() {
            let label = clips.count > 1 ? "Clip \(n + 1) of \(clips.count): " : ""
            await progress(label + "listening…", Double(n) / Double(clips.count))
            let asset = AVURLAsset(url: clip.url)
            let range = CMTimeRange(start: clip.trimStart.cmTime, duration: clip.trimmedDuration.cmTime)
            var words: [SpokenWord] = []
            do {
                if let cached = project.spokenWords?[clip.path] {
                    // Already heard by the transcript editor: no need to listen again.
                    words = cached.filter { ($0.start + $0.end) / 2 >= clip.trimStart && ($0.start + $0.end) / 2 < clip.effectiveTrimEnd }
                } else {
                    words = try await Transcriber.transcribe(asset: asset, range: range) { p in
                        progress(label + "listening…", (Double(n) + p * 0.7) / Double(clips.count))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Still find the pauses, but say why fillers and retakes weren't checked.
                speechProblem = error.localizedDescription
            }
            transcript.append(words.map(\.text).joined(separator: " "))
            await progress(label + "finding pauses…", (Double(n) + 0.8) / Double(clips.count))
            let rate = 16_000.0
            let samples = try await AudioPCM.read(url: clip.url, sampleRate: rate, range: range)
            let window = 0.02
            let levels = AudioPCM.levels(samples, sampleRate: rate, window: window)
            cuts += findCuts(clip: clip, words: words, levels: levels, window: window, options: options)
        }
        await progress("Done", 1)
        return Analysis(cuts: cuts, transcript: transcript.joined(separator: " "), speechProblem: speechProblem)
    }

    static func findCuts(clip: ClipItem, words: [SpokenWord], levels: [Float], window: Double, options: Options) -> [Cut] {
        let begin = clip.trimStart, finish = clip.effectiveTrimEnd
        var found: [Cut] = []

        // Silence: adaptive threshold between the room's noise floor and the voice level.
        if !levels.isEmpty {
            let sorted = levels.sorted()
            let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
            let voice = sorted[Int(Double(sorted.count - 1) * 0.9)]
            let threshold = max(floor + 6, floor + (voice - floor) * 0.3)
            var runStart: Int?
            for i in 0...levels.count {
                let quiet = i < levels.count && levels[i] < threshold
                if quiet, runStart == nil { runStart = i }
                if !quiet, let s = runStart {
                    runStart = nil
                    let sStart = begin + Double(s) * window
                    let sEnd = min(finish, begin + Double(i) * window)
                    // Never cut through a recognised word.
                    if words.contains(where: { $0.start < sEnd - 0.05 && $0.end > sStart + 0.05 }) { continue }
                    let atStart = s == 0, atEnd = i == levels.count
                    let pad = options.keepPause / 2
                    let cutStart = atStart ? sStart : sStart + pad
                    let cutEnd = atEnd ? sEnd : sEnd - pad
                    if atStart || atEnd {
                        if sEnd - sStart >= 0.4, cutEnd - cutStart > 0.15 {
                            found.append(Cut(clipID: clip.id, kind: .deadAir, start: cutStart, end: cutEnd,
                                             text: atStart ? "Before you start talking" : "After you stop talking"))
                        }
                    } else if sEnd - sStart >= options.minPause, cutEnd - cutStart > 0.15 {
                        found.append(Cut(clipID: clip.id, kind: .pause, start: cutStart, end: cutEnd,
                                         text: String(format: "%.1f s of silence", sEnd - sStart)))
                    }
                }
            }
        }

        let norm = words.map { Transcriber.normalize($0.text) }

        if options.cutFillers {
            for (i, w) in words.enumerated() where fillers.contains(norm[i]) {
                found.append(Cut(clipID: clip.id, kind: .filler, start: max(begin, w.start - 0.04),
                                 end: min(finish, w.end + 0.04), text: "\"\(w.text)\""))
            }
        }

        if options.cutRetakes {
            var i = 0
            while i < words.count {
                var matched = false
                // A phrase said again within the next few words: the first try is the mistake.
                for n in stride(from: 6, through: 3, by: -1) where i + n <= words.count {
                    let phrase = Array(norm[i..<i + n])
                    guard !phrase.allSatisfy({ fillers.contains($0) }) else { continue }
                    let lastJ = min(words.count - n, i + n + 10)
                    guard lastJ > i else { continue }
                    for j in (i + 1)...lastJ where Array(norm[j..<j + n]) == phrase {
                        let s = words[i].start, e = words[j].start - 0.05
                        if e - s > 0.3 {
                            let said = words[i..<j].map(\.text).joined(separator: " ")
                            found.append(Cut(clipID: clip.id, kind: .retake, start: s, end: e, text: "\"\(said)\""))
                        }
                        i = j
                        matched = true
                        break
                    }
                    if matched { break }
                }
                if !matched {
                    // Stutter: the same word twice in a row ("I I think").
                    if i + 1 < words.count, norm[i] == norm[i + 1], norm[i].count <= 4, !norm[i].isEmpty,
                       words[i + 1].start - words[i].end < 0.6 {
                        found.append(Cut(clipID: clip.id, kind: .retake, start: words[i].start, end: words[i + 1].start - 0.03,
                                         text: "\"\(words[i].text) \(words[i + 1].text)\""))
                    }
                    i += 1
                }
            }
        }

        return merge(found.filter { $0.end > $0.start + 0.08 }, clipStart: begin, clipEnd: finish)
    }

    /// Joins overlapping cuts and drops leftovers too short to keep.
    static func merge(_ cuts: [Cut], clipStart: Double, clipEnd: Double) -> [Cut] {
        let sorted = cuts.sorted { $0.start < $1.start }
        var out: [Cut] = []
        for c in sorted {
            if var last = out.last, c.start <= last.end + 0.05 {
                last.end = max(last.end, c.end)
                if c.kind == .retake || (c.kind == .filler && last.kind == .pause) {
                    out[out.count - 1] = Cut(clipID: c.clipID, kind: c.kind, start: last.start, end: last.end, text: c.text)
                } else {
                    out[out.count - 1] = last
                }
            } else {
                out.append(c)
            }
        }
        // Don't leave the whole clip cut.
        let kept = (clipEnd - clipStart) - out.reduce(0) { $0 + $1.length }
        return kept < 0.5 ? [] : out
    }

    /// Applies the enabled cuts by splitting clips into the kept pieces. One undo step.
    static func apply(_ cuts: [Cut], to project: inout EditProject) {
        let enabled = cuts.filter(\.enabled)
        guard !enabled.isEmpty else { return }
        let starts = project.clipStarts
        var removedTimeline: [(Double, Double)] = []
        var newClips: [ClipItem] = []

        for (i, clip) in project.clips.enumerated() {
            let mine = enabled.filter { $0.clipID == clip.id }.sorted { $0.start < $1.start }
            guard !mine.isEmpty else { newClips.append(clip); continue }
            var pieces: [(Double, Double)] = []
            var cursor = clip.trimStart
            for c in mine {
                let s = max(c.start, clip.trimStart), e = min(c.end, clip.effectiveTrimEnd)
                guard e > s else { continue }
                if s - cursor >= 0.1 { pieces.append((cursor, s)) }
                removedTimeline.append((starts[i] + (s - clip.trimStart) / clip.speed, starts[i] + (e - clip.trimStart) / clip.speed))
                cursor = max(cursor, e)
            }
            if clip.effectiveTrimEnd - cursor >= 0.1 { pieces.append((cursor, clip.effectiveTrimEnd)) }
            for (k, piece) in pieces.enumerated() {
                var c = clip
                if k > 0 { c.id = UUID() }
                c.trimStart = piece.0
                c.trimEnd = piece.1
                if k < pieces.count - 1 { c.transitionOut = .none }
                newClips.append(c)
            }
        }

        func map(_ t: Double) -> Double {
            var shift = 0.0
            for (s, e) in removedTimeline where s < t { shift += min(e, t) - s }
            return t - shift
        }
        func inside(_ t: Double) -> Bool { removedTimeline.contains { t > $0.0 && t < $0.1 } }

        project.clips = newClips
        project.texts = project.texts.compactMap { item in
            var item = item
            let s = map(item.start), e = map(item.end)
            guard e - s > 0.15 else { return nil }
            if let words = item.words {
                // Keep words that weren't cut, re-timed to the new timeline.
                let kept: [CaptionWord] = words.compactMap { w in
                    let ws = item.start + w.start, we = item.start + w.end
                    if inside((ws + we) / 2) { return nil }
                    return CaptionWord(text: w.text, start: map(ws) - s, end: map(we) - s)
                }
                guard !kept.isEmpty else { return nil }
                item.words = kept
                item.text = kept.map(\.text).joined(separator: " ")
            }
            item.start = s
            item.end = e
            return item
        }
        for k in project.audio.indices where project.audio[k].kind != .music {
            project.audio[k].start = map(project.audio[k].start)
        }
    }

    /// Timeline time of a cut, for previewing it.
    static func timelineTime(of cut: Cut, in project: EditProject) -> Double? {
        guard let i = project.clips.firstIndex(where: { $0.id == cut.clipID }) else { return nil }
        let c = project.clips[i]
        return project.clipStarts[i] + (cut.start - c.trimStart) / c.speed
    }
}
