import AVFoundation
import Speech

/// A recognised word with its time in the asset (seconds).
struct SpokenWord: Codable, Equatable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

/// On-device speech to text with word timings.
///
/// Long audio is sent in short pieces: Apple's recognizer stops returning words after
/// about a minute of audio on some iPhones, which made captions end early.
enum Transcriber {
    static let chunkSeconds = 45.0
    static let overlapSeconds = 1.5

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    static func recognizer(locale: Locale = .current) async throws -> SFSpeechRecognizer {
        guard await requestAccess() else {
            throw EditorError.exportFailed("Allow speech recognition in Settings to use this.")
        }
        guard let r = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              r.isAvailable else {
            throw EditorError.exportFailed("Speech recognition isn't available right now.")
        }
        return r
    }

    /// Transcribes `range` of an asset's sound (optionally through an audio mix).
    /// Returned times are in the asset's timeline.
    static func transcribe(asset: AVAsset, audioMix: AVAudioMix? = nil, range: CMTimeRange,
                           progress: (@MainActor (Double) -> Void)? = nil) async throws -> [SpokenWord] {
        let recognizer = try await recognizer()
        let start = range.start.seconds
        let total = range.duration.seconds
        guard total > 0.2 else { return [] }

        var words: [SpokenWord] = []
        var firstError: Error?
        var anySucceeded = false
        var offset = 0.0
        while offset < total - 0.05 {
            try Task.checkCancellation()
            let length = min(chunkSeconds, total - offset)
            let chunk = CMTimeRange(start: (start + offset).cmTime, duration: length.cmTime)
            do {
                let url = try await exportAudio(asset: asset, audioMix: audioMix, range: chunk)
                defer { try? FileManager.default.removeItem(at: url) }
                let found = try await recognize(url: url, recognizer: recognizer)
                anySucceeded = true
                let base = start + offset
                // Drop words already heard in the overlap with the previous piece.
                let lastEnd = words.last?.end ?? -1
                for w in found {
                    let word = SpokenWord(text: w.text, start: base + w.start, end: base + w.end)
                    if word.start >= lastEnd - 0.05 { words.append(word) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A silent piece reports "no speech". Keep going and only fail if nothing worked.
                if firstError == nil { firstError = error }
            }
            if let progress { await progress(min(1, (offset + length) / total)) }
            if offset + length >= total - 0.05 { break }
            offset += length - overlapSeconds
        }
        if !anySucceeded, let firstError { throw firstError }
        return words
    }

    private static func exportAudio(asset: AVAsset, audioMix: AVAudioMix?, range: CMTimeRange) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw EditorError.exportFailed("Couldn't read the audio.")
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = range
        session.audioMix = audioMix
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
        guard session.status == .completed else {
            throw EditorError.exportFailed(session.error?.localizedDescription ?? "Couldn't read the audio.")
        }
        return url
    }

    /// Holds the recognition task so it isn't released mid-run.
    private final class TaskBox: @unchecked Sendable { var task: SFSpeechRecognitionTask? }

    private static func recognize(url: URL, recognizer: SFSpeechRecognizer) async throws -> [SpokenWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let box = TaskBox()
        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { c in
            var done = false
            box.task = recognizer.recognitionTask(with: request) { result, error in
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
        box.task = nil
        return segments.map { SpokenWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
    }

    /// Lower-case letters and digits only, for comparing words.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
