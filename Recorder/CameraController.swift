import AVFoundation
import UIKit

/// Owns the capture session, picks a 1080p or 4K format at exactly 30 fps,
/// and records takes through `MovieWriter`.
///
/// Threads: published properties change on the main thread. Session setup runs
/// on `sessionQueue`. Sample buffers and the writer live on `dataQueue`.
final class CameraController: NSObject, ObservableObject {
    enum State: Equatable { case idle, recording, paused, finishing }
    enum Permission { case unknown, granted, denied }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var permission: Permission = .unknown
    @Published private(set) var microphoneAllowed = false
    /// Rotation the recording will use: 90 or 270 means the phone is upright.
    @Published private(set) var captureAngle: CGFloat = 90
    /// The quality actually in use. Falls back to 1080p on cameras without 4K at 30 fps.
    @Published private(set) var activeQuality: ExportQuality = .hd1080
    @Published private(set) var supports4K = true
    @Published var errorMessage: String?
    /// Set when a take is saved. The view clears it after showing the review.
    @Published var finishedTake: URL?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "cueframe.recorder.session")
    private let dataQueue = DispatchQueue(label: "cueframe.recorder.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // sessionQueue
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var outputsAdded = false

    // main thread
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewAngleObservation: NSKeyValueObservation?
    private var captureAngleObservation: NSKeyValueObservation?

    // dataQueue
    private struct PendingRecording {
        let url: URL
        let codec: AVVideoCodecType
        let bitrate: Int
        let audioSettings: [String: Any]?
    }
    private var pending: PendingRecording?
    private var writer: MovieWriter?
    private var pausedOnDataQueue = false
    private var lastElapsedPublish: TimeInterval = -1

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    // MARK: Setup

    /// Asks for camera and microphone access, then configures and starts the camera.
    func start(front: Bool, quality: ExportQuality) {
        Task {
            let camera = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                self.permission = camera ? .granted : .denied
                self.microphoneAllowed = mic
            }
            guard camera else { return }
            self.configure(front: front, quality: quality)
            self.startSession()
        }
    }

    func startSession() {
        sessionQueue.async { [self] in
            guard videoDeviceInput != nil, !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Switches camera or quality. Ignored while recording.
    func configure(front: Bool, quality: ExportQuality) {
        guard state == .idle else { return }
        sessionQueue.async { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .inputPriority

            if let existing = videoDeviceInput {
                session.removeInput(existing)
                videoDeviceInput = nil
            }
            let position: AVCaptureDevice.Position = front ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video) else {
                publishError(RecorderError.noCamera)
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    publishError(RecorderError.cameraUnavailable("it is in use by another app."))
                    return
                }
                session.addInput(input)
                videoDeviceInput = input
            } catch {
                publishError(RecorderError.cameraUnavailable(error.localizedDescription))
                return
            }

            addMicrophoneIfAllowed()
            addOutputsIfNeeded()
            let (applied, has4K) = applyFormat(to: device, quality: quality)

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    // The preview is mirrored like a selfie, but takes are saved the right way
                    // round so any words behind you read correctly, as the iPhone camera does.
                    connection.isVideoMirrored = false
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .standard
                }
            }

            DispatchQueue.main.async { [self] in
                activeQuality = applied
                supports4K = has4K
                currentDevice = device
                makeRotationCoordinator()
            }
        }
    }

    /// Called by the preview view once its layer exists.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        makeRotationCoordinator()
    }

    private func addMicrophoneIfAllowed() {
        guard audioDeviceInput == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        audioDeviceInput = input
    }

    private func addOutputsIfNeeded() {
        guard !outputsAdded else { return }
        // Keep every frame while recording; dropping frames would make 30 fps uneven.
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        outputsAdded = true
    }

    /// Picks the format for the requested quality and locks it to 30 fps.
    private func applyFormat(to device: AVCaptureDevice, quality: ExportQuality) -> (ExportQuality, Bool) {
        let has4K = Self.format(on: device, width: 3840, height: 2160) != nil
        let use = (quality == .uhd4K && !has4K) ? ExportQuality.hd1080 : quality
        let size: (Int32, Int32) = use == .uhd4K ? (3840, 2160) : (1920, 1080)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let format = Self.format(on: device, width: size.0, height: size.1) {
                device.activeFormat = format
            }
            device.activeVideoMinFrameDuration = Video.frameDuration
            device.activeVideoMaxFrameDuration = Video.frameDuration
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {
            publishError(RecorderError.cameraUnavailable(error.localizedDescription))
        }
        return (use, has4K)
    }

    /// The best format at exactly this size that can run at 30 fps.
    static func format(on device: AVCaptureDevice, width: Int32, height: Int32) -> AVCaptureDevice.Format? {
        let fps = Double(Video.frameRate)
        let matches = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return d.width == width && d.height == height &&
                format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }
        // Prefer 8-bit 4:2:0 full range, which every social app plays correctly.
        func rank(_ format: AVCaptureDevice.Format) -> Int {
            switch CMFormatDescriptionGetMediaSubType(format.formatDescription) {
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return 0
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return 1
            default: return 2
            }
        }
        return matches.min { rank($0) < rank($1) }
    }

    /// Tracks how the phone is held, so the preview stays level and the take
    /// is written upright for both portrait and landscape.
    private func makeRotationCoordinator() {
        guard let device = currentDevice else { return }
        previewAngleObservation = nil
        captureAngleObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        previewAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let connection = self?.previewLayer?.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
        captureAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            DispatchQueue.main.async {
                guard let self, self.state == .idle else { return }
                self.captureAngle = angle
            }
        }
    }

    // MARK: Recording

    var isPortraitHold: Bool { Int(captureAngle.rounded()) % 180 == 90 }

    func startRecording(codec: RecordCodec) {
        guard state == .idle, permission == .granted else { return }
        let url = MediaLibrary.newFile(in: MediaLibrary.recordings, ext: "mp4")
        let audioSettings = microphoneAllowed
            ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) as? [String: Any]
            : nil
        let request = PendingRecording(
            url: url, codec: codec.avCodec,
            bitrate: activeQuality.recordingBitrate(codec), audioSettings: audioSettings)
        let angle = captureAngle

        state = .recording
        elapsed = 0
        UIApplication.shared.isIdleTimerDisabled = true

        sessionQueue.async { [self] in
            // Frames come out already upright, in the shape of the take.
            if let connection = videoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            dataQueue.async { [self] in
                pausedOnDataQueue = false
                lastElapsedPublish = -1
                pending = request
            }
        }
    }

    func pause() {
        guard state == .recording else { return }
        state = .paused
        dataQueue.async { [self] in
            pausedOnDataQueue = true
            writer?.pause()
        }
    }

    func resume() {
        guard state == .paused else { return }
        state = .recording
        dataQueue.async { [self] in
            pausedOnDataQueue = false
            writer?.resume()
        }
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        // Hop through the session queue so the start request is queued before we stop.
        sessionQueue.async { [self] in
            dataQueue.async { [self] in
                pending = nil
                guard let current = writer else {
                    finishOnMain(.failure(RecorderError.nothingRecorded))
                    return
                }
                writer = nil
                current.finish { [self] result in
                    _ = current
                    finishOnMain(result)
                }
            }
        }
    }

    private func finishOnMain(_ result: Result<URL, Error>) {
        DispatchQueue.main.async { [self] in
            state = .idle
            elapsed = 0
            UIApplication.shared.isIdleTimerDisabled = false
            captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? captureAngle
            switch result {
            case .success(let url): finishedTake = url
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private func publishError(_ error: Error) {
        DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        DispatchQueue.main.async { [self] in
            if state == .recording || state == .paused { stopRecording() }
            if error?.code == .mediaServicesWereReset { startSession() }
            else if let error { errorMessage = error.localizedDescription }
        }
    }

    // dataQueue
    private func makeWriter(_ request: PendingRecording, firstFrame: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(firstFrame) else { return }
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: request.bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(Video.frameRate),
            AVVideoMaxKeyFrameIntervalKey: Int(Video.frameRate),
        ]
        if request.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: request.codec,
            AVVideoWidthKey: CVPixelBufferGetWidth(pixels),
            AVVideoHeightKey: CVPixelBufferGetHeight(pixels),
            AVVideoCompressionPropertiesKey: compression,
        ]
        do {
            let newWriter = try MovieWriter(url: request.url, videoSettings: videoSettings, audioSettings: request.audioSettings)
            if pausedOnDataQueue { newWriter.pause() }
            writer = newWriter
        } catch {
            finishOnMain(.failure(error))
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        if isVideo, let request = pending {
            pending = nil
            makeWriter(request, firstFrame: sampleBuffer)
        }
        guard let writer else { return }

        writer.append(sampleBuffer, track: isVideo ? .video : .audio)

        if let failure = writer.failure {
            self.writer = nil
            writer.finish { _ in }
            finishOnMain(.failure(failure))
            return
        }

        if isVideo {
            let duration = writer.duration
            if duration - lastElapsedPublish >= 0.25 {
                lastElapsedPublish = duration
                DispatchQueue.main.async { self.elapsed = duration }
            }
        }
    }
}
