import AVFoundation

/// Auto-captions: transcribes the clips' own sound on the device and makes timed, word-by-word caption items.
enum Captioner {
    struct Options {
        var maxWords = 4
        var maxSeconds = 2.2
        var look: CaptionLook = .highlight
        var style = Captioner.style(for: .highlight)
        var y = 0.7
        var uppercase = true
        /// Script to take exact wording from, if the take followed one.
        var script: String?
    }

    struct Output {
        var captions: [TextItem]
        var transcript: String
        /// Share of spoken words that matched the script (nil when no script was used).
        var scriptMatch: Double?
    }

    /// A good starting style for each look, in the bold short-form video style.
    static func style(for look: CaptionLook) -> TextStyle {
        var s = TextStyle(font: .bold, size: 0.075, color: RGBA(r: 1, g: 1, b: 1), background: .none,
                          backgroundColor: RGBA(r: 0, g: 0, b: 0, a: 0.55), outline: true, shadow: true)
        s.highlightColor = TextOverlay.defaultHighlight
        switch look {
        case .plain:
            s.size = 0.065
            s.background = .box
            s.outline = false
            s.shadow = false
        case .highlight, .reveal:
            break
        case .box:
            s.outline = false
            s.highlightColor = RGBA(r: 0.45, g: 0.9, b: 0.55)
        case .oneWord:
            s.size = 0.11
        }
        if let brand = BrandStore.current {
            s.font = brand.font
            s.customFont = brand.customFontName
            s.highlightColor = brand.accent
        }
        return s
    }

    static func makeCaptions(for project: EditProject, options: Options,
                             progress: (@MainActor (Double) -> Void)? = nil) async throws -> Output {
        // Only the clip sound (no music) so the recogniser hears the voice clearly.
        let built = try await CompositionBuilder.build(project, renderScale: 0.5, includeExtraAudio: false)
        let range = CMTimeRange(start: .zero, duration: project.duration.cmTime)
        var words = try await Transcriber.transcribe(asset: built.composition, audioMix: built.audioMix,
                                                     range: range, progress: progress)
        let transcript = words.map(\.text).joined(separator: " ")
        var match: Double?
        if let script = options.script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let aligned = ScriptAligner.align(spoken: words, script: script)
            match = aligned.matchRate
            words = aligned.words
        }
        // Brand intro/outro are not speech worth captioning.
        let brandRanges = brandTimeRanges(project)
        words.removeAll { w in AutoCut.fillers.contains(Transcriber.normalize(w.text)) ||
            brandRanges.contains { w.start >= $0.0 && w.start < $0.1 } }
        return Output(captions: group(words, options: options, duration: project.duration),
                      transcript: transcript, scriptMatch: match)
    }

    static func brandTimeRanges(_ p: EditProject) -> [(Double, Double)] {
        let starts = p.clipStarts
        return p.clips.indices.filter { p.clips[$0].isBrandClip }.map { (starts[$0], starts[$0] + p.clips[$0].outputDuration) }
    }

    /// Groups words into short caption lines, keeping each word's timing.
    static func group(_ words: [SpokenWord], options: Options, duration: Double) -> [TextItem] {
        var items: [TextItem] = []
        var line: [SpokenWord] = []

        func flush() {
            guard let first = line.first, let last = line.last else { return }
            let start = first.start
            var item = TextItem(text: "", start: start, end: max(last.end, start + 0.5), isCaption: true)
            item.words = line.map { w in
                CaptionWord(text: options.uppercase ? w.text.uppercased() : w.text,
                            start: max(0, w.start - start), end: max(0.05, w.end - start))
            }
            item.text = item.words!.map(\.text).joined(separator: " ")
            item.style = options.style
            item.center = NPoint(x: 0.5, y: options.y)
            item.look = options.look
            item.animation = options.look == .plain ? .pop : .none
            items.append(item)
            line.removeAll()
        }

        for w in words {
            // A long gap starts a new caption even if the line isn't full.
            if let last = line.last, w.start - last.end > 0.8 { flush() }
            line.append(w)
            let span = w.end - (line.first?.start ?? w.start)
            let endsSentence = w.text.last.map { ".!?,;:".contains($0) } ?? false
            if line.count >= options.maxWords || span >= options.maxSeconds || endsSentence { flush() }
        }
        flush()
        // Hold each caption until the next one starts (no flicker), capped at the video end.
        for i in items.indices {
            let next = i + 1 < items.count ? items[i + 1].start : duration
            items[i].end = min(max(items[i].end, min(next, items[i].end + 0.8)), duration)
        }
        return items.filter { $0.end > $0.start }
    }

    /// SubRip subtitles for platforms that take a caption file (YouTube, Facebook).
    static func srt(_ project: EditProject) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        let lines = project.texts.filter(\.isCaption).sorted { $0.start < $1.start }
        return lines.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n"
        }.joined(separator: "\n")
    }
}
