import AVFoundation

/// Records a voiceover to an .m4a in Documents/Media.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var level: Float = 0
    @Published var elapsed: Double = 0
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private(set) var startTime: Double = 0

    func start(at timelineTime: Double) async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw EditorError.exportFailed("Allow the microphone in Settings to record a voiceover.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let url = MediaLibrary.newFile(in: MediaLibrary.media, ext: "m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        r.record()
        recorder = r
        startTime = timelineTime
        isRecording = true
        elapsed = 0
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.level = max(0, (r.averagePower(forChannel: 0) + 50) / 50)
                self.elapsed = r.currentTime
            }
        }
    }

    /// Stops and returns the recorded file.
    func stop() -> URL? {
        meterTask?.cancel()
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return r.url
    }
}
