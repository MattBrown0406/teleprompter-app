import AVFoundation
import Speech

/// Listens to the camera's microphone and reports the words heard, on the device when it can.
///
/// Audio comes from the capture session (see `CameraController.audioTap`), so it works
/// while recording without fighting the camera for the microphone.
final class SpeechFollower: ObservableObject {
    enum Status: Equatable {
        case off
        case listening
        case unavailable(String)
    }

    @Published private(set) var status: Status = .off
    /// True when the recognizer runs on the phone, so no audio leaves it.
    @Published private(set) var onDevice = false

    /// Called on the main thread with every word heard in the current pass.
    var onWords: (([String]) -> Void)?
    /// Called on the main thread with the full transcript of the current pass so far, with timing.
    /// Each call replaces the previous one for the same pass. Used by practice mode.
    var onTranscript: ((HeardPass) -> Void)?

    private let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    // Guarded by `lock`: touched from the camera's data queue and the main thread.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var passStarted = Date()
    private var wanted = false
    private var contextWords: [String] = []
    // main thread
    private var generation = 0
    private var quickFailures = 0

    /// Starts listening. Asks for speech permission the first time.
    func start(script: String) {
        wanted = true
        quickFailures = 0
        contextWords = Self.contextWords(from: script)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            beginPass()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] auth in
                DispatchQueue.main.async {
                    guard let self, self.wanted else { return }
                    if auth == .authorized { self.beginPass() } else { self.refuse() }
                }
            }
        default:
            refuse()
        }
    }

    func stop() {
        wanted = false
        generation += 1
        quickFailures = 0
        endPass()
        status = .off
    }

    /// Feeds microphone audio. Safe to call from any thread.
    func append(_ buffer: CMSampleBuffer) {
        lock.lock()
        let request = self.request
        let age = Date().timeIntervalSince(passStarted)
        lock.unlock()
        guard let request else { return }
        request.appendAudioSampleBuffer(buffer)
        // Recognition passes have a time limit; start a fresh one before it is reached.
        if age > 50 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wanted, self.currentAge() > 50 else { return }
                self.beginPass()
            }
        }
    }

    private func refuse() {
        status = .unavailable("Speech recognition is off for Cueframe. Turn it on in Settings, or switch to fixed speed.")
    }

    private func currentAge() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(passStarted)
    }

    private func beginPass() {
        endPass()
        guard let recognizer, recognizer.isAvailable else {
            status = .unavailable("Speech recognition isn't available right now. The script will wait for you to scroll it.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextWords
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            onDevice = true
        } else {
            onDevice = false
        }
        request.addsPunctuation = false

        generation += 1
        let pass = generation
        let started = Date()
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                // Ignore a pass we already replaced or cancelled.
                guard let self, self.wanted, pass == self.generation else { return }
                if let result {
                    if let onTranscript = self.onTranscript {
                        onTranscript(HeardPass(
                            id: pass, started: started,
                            segments: result.bestTranscription.segments.map {
                                HeardSegment(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                            }))
                    }
                    self.onWords?(result.bestTranscription.segments.flatMap { ScriptWords.keys($0.substring) })
                    if !result.bestTranscription.segments.isEmpty { self.quickFailures = 0 }
                }
                // A pass ends after a long silence, an error or its time limit. Keep listening,
                // but give up if it keeps failing straight away (for example, no speech model).
                guard error != nil || result?.isFinal == true else { return }
                if error != nil, Date().timeIntervalSince(started) < 2 {
                    self.quickFailures += 1
                    if self.quickFailures >= 3 {
                        self.endPass()
                        self.status = .unavailable("Voice following couldn't start on this phone. Switch to fixed speed, or try again later.")
                        return
                    }
                }
                self.beginPass()
            }
        }
        lock.lock()
        self.request = request
        self.task = task
        passStarted = Date()
        lock.unlock()
        status = .listening
    }

    private func endPass() {
        lock.lock()
        let request = self.request, task = self.task
        self.request = nil
        self.task = nil
        lock.unlock()
        request?.endAudio()
        task?.cancel()
    }

    /// Unusual words from the script help the recognizer spell names and jargon.
    private static func contextWords(from script: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        script.enumerateSubstrings(in: script.startIndex..<script.endIndex, options: .byWords) { word, _, _, _ in
            guard let word, word.count >= 6 || word.first?.isUppercase == true, seen.insert(word.lowercased()).inserted else { return }
            result.append(word)
        }
        return Array(result.prefix(100))
    }
}

/// One word or phrase the recognizer heard, timed from the start of its pass.
struct HeardSegment {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
}

/// What one recognition pass has heard so far.
struct HeardPass {
    let id: Int
    let started: Date
    let segments: [HeardSegment]
}
