import AVFoundation

enum RecorderError: LocalizedError {
    case noCamera
    case cameraUnavailable(String)
    case writer(String)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No camera was found on this device."
        case .cameraUnavailable(let why): return "The camera couldn't start: \(why)"
        case .writer(let why): return "Recording failed: \(why)"
        case .nothingRecorded: return "Nothing was recorded. Try again."
        }
    }
}

/// Writes camera sample buffers to an .mp4 file.
///
/// Pause and resume are done by dropping samples while paused and shifting the
/// timestamps of everything after, so the gap is removed and the take plays as
/// one continuous clip.
///
/// Not thread safe: call every method from the same serial queue.
final class MovieWriter {
    enum Track { case video, audio }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?

    private var started = false
    private var startTime = CMTime.invalid
    /// Total paused time removed so far.
    private var offset = CMTime.zero
    /// End time, on the camera clock, of the last sample appended before a pause.
    private var lastRawEnd = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private var lastAudioTime = CMTime.invalid
    private var resumePending = false

    private(set) var isPaused = false
    private(set) var isFinishing = false
    private(set) var failure: Error?

    /// Length of the recorded take so far, in seconds, with pauses removed.
    var duration: TimeInterval {
        guard started, lastVideoTime.isValid else { return 0 }
        return max(0, (lastVideoTime - startTime).seconds)
    }

    init(url: URL, videoSettings: [String: Any], audioSettings: [String: Any]?) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.writer("the video settings aren't supported.") }
        writer.add(video)

        var audio: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }

        self.url = url
        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
    }

    func pause() {
        guard started, !isPaused else { return }
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        resumePending = true
    }

    func append(_ sampleBuffer: CMSampleBuffer, track: Track) {
        guard !isPaused, !isFinishing, failure == nil, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let rawTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var rawDuration = CMSampleBufferGetDuration(sampleBuffer)
        if !rawDuration.isValid { rawDuration = track == .video ? Video.frameDuration : .zero }

        if !started {
            // Start the file on a video frame so it never opens on black.
            guard track == .video else { return }
            guard writer.startWriting() else {
                failure = writer.error ?? RecorderError.writer("the file couldn't be created.")
                return
            }
            writer.startSession(atSourceTime: rawTime)
            startTime = rawTime
            started = true
        }

        if resumePending {
            if lastRawEnd.isValid {
                let gap = rawTime - lastRawEnd
                if gap > .zero { offset = offset + gap }
            }
            resumePending = false
        }

        let time = rawTime - offset
        guard time >= startTime else { return }

        switch track {
        case .video:
            if lastVideoTime.isValid && time <= lastVideoTime { return }
            guard videoInput.isReadyForMoreMediaData, let buffer = retimed(sampleBuffer) else { return }
            if videoInput.append(buffer) { lastVideoTime = time }
        case .audio:
            guard let audioInput else { return }
            if lastAudioTime.isValid && time <= lastAudioTime { return }
            guard audioInput.isReadyForMoreMediaData, let buffer = retimed(sampleBuffer) else { return }
            if audioInput.append(buffer) { lastAudioTime = time }
        }

        if writer.status == .failed {
            failure = writer.error ?? RecorderError.writer("the encoder stopped.")
            return
        }

        let end = rawTime + rawDuration
        if !lastRawEnd.isValid || end > lastRawEnd { lastRawEnd = end }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true

        guard started, lastVideoTime.isValid, failure == nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(failure ?? RecorderError.nothingRecorded))
            return
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        // End on the last video frame so the clip doesn't trail off in black.
        writer.endSession(atSourceTime: lastVideoTime + Video.frameDuration)
        let writer = self.writer
        let url = self.url
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(writer.error ?? RecorderError.writer("the file couldn't be saved.")))
            }
        }
    }

    /// Returns a copy of the buffer with the paused time removed from its timestamps.
    private func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset > .zero else { return sampleBuffer }

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)

        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid {
                timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            }
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset
            }
        }

        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
