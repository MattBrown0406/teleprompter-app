import AVFoundation

/// Editor commands behind editing by text, one-tap polish and the clip finder.
extension EditorSession {
    /// Transcribes any clip file that hasn't been heard yet and keeps the words in the project.
    /// Runs on the device. Later cuts reuse the words, so this only happens once per file.
    func ensureWords(progress: @escaping @MainActor (String, Double) -> Void) async throws {
        let todo = Transcript.missingPaths(project)
        guard !todo.isEmpty else { return }
        var failures: [Error] = []
        for (n, path) in todo.enumerated() {
            let label = todo.count > 1 ? "Clip \(n + 1) of \(todo.count): listening…" : "Listening…"
            progress(label, Double(n) / Double(todo.count))
            let url = MediaLibrary.resolve(path)
            let asset = AVURLAsset(url: url)
            let length = (try? await asset.load(.duration).seconds) ?? 0
            guard length > 0.3 else { continue }
            do {
                let words = try await Transcriber.transcribe(asset: asset, range: CMTimeRange(start: .zero, duration: length.cmTime)) { p in
                    progress(label, (Double(n) + p) / Double(todo.count))
                }
                applySilently { p in
                    var all = p.spokenWords ?? [:]
                    all[path] = words
                    p.spokenWords = all
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(error)
            }
        }
        progress("Done", 1)
        if failures.count == todo.count, let first = failures.first { throw first }
    }

    /// Cuts from struck words or pauses in the transcript editor. One undo step.
    func applyTranscriptCuts(_ cuts: [AutoCut.Cut]) {
        guard !cuts.isEmpty else { return }
        pause()
        edit { p in
            AutoCut.apply(cuts, to: &p)
            let words = Transcript.words(p).map(\.text).joined(separator: " ")
            if !words.isEmpty { p.transcript = words }
        }
    }
}
