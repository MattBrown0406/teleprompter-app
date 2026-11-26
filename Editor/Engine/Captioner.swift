import AVFoundation
import Speech

/// Auto-captions: transcribes the clips' own sound on the device and makes timed caption text items.
enum Captioner {
    struct Options {
        var maxWords = 5
        var maxSeconds = 2.2
        var style = TextStyle(font: .bold, size: 0.065, color: RGBA(r: 1, g: 1, b: 1), background: .box,
                              backgroundColor: RGBA(r: 0, g: 0, b: 0, a: 0.55), outline: false, shadow: false)
        var y = 0.72
        var uppercase = false
    }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    static func makeCaptions(for project: EditProject, options: Options = Options(),
                             locale: Locale = .current) async throws -> [TextItem] {
        guard await requestAccess() else {
            throw EditorError.exportFailed("Allow speech recognition in Settings to make captions.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw EditorError.exportFailed("Speech recognition isn't available right now.")
        }

        // Render only the clip sound (no music) to a temporary audio file.
        let built = try await CompositionBuilder.build(project, renderScale: 0.5, includeExtraAudio: false)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw EditorError.exportFailed("Couldn't read the audio.")
        }
        session.outputURL = audioURL
        session.outputFileType = .m4a
        session.audioMix = built.audioMix
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
        guard session.status == .completed else {
            throw EditorError.exportFailed(session.error?.localizedDescription ?? "Couldn't read the audio.")
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { c in
            var done = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    c.resume(returning: result.bestTranscription.segments)
                } else if let error {
                    done = true
                    c.resume(throwing: error)
                }
            }
        }
        return group(segments, options: options, duration: project.duration)
    }

    /// Groups words into short caption lines.
    static func group(_ segments: [SFTranscriptionSegment], options: Options, duration: Double) -> [TextItem] {
        var items: [TextItem] = []
        var words: [String] = []
        var start = 0.0, end = 0.0

        func flush() {
            guard !words.isEmpty else { return }
            var line = words.joined(separator: " ")
            if options.uppercase { line = line.uppercased() }
            var item = TextItem(text: line, start: start, end: max(end, start + 0.6), isCaption: true)
            item.style = options.style
            item.center = NPoint(x: 0.5, y: options.y)
            item.animation = .pop
            items.append(item)
            words.removeAll()
        }

        for seg in segments {
            let s = seg.timestamp, e = seg.timestamp + seg.duration
            if words.isEmpty { start = s }
            words.append(seg.substring)
            end = e
            let endsSentence = seg.substring.last.map { ".!?,".contains($0) } ?? false
            if words.count >= options.maxWords || end - start >= options.maxSeconds || endsSentence { flush() }
        }
        flush()
        // Hold each caption until the next one starts (no flicker), capped at the video end.
        for i in items.indices {
            let next = i + 1 < items.count ? items[i + 1].start : duration
            items[i].end = min(max(items[i].end, min(next, items[i].end + 0.8)), duration)
        }
        return items.filter { $0.end > $0.start }
    }
}
