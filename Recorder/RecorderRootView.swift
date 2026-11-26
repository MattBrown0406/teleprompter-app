import SwiftUI
import AVFoundation

/// The Record tab: camera, scrolling script near the lens, and recording controls.
struct RecorderRootView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var settings = RecorderSettings()
    @StateObject private var scripts = ScriptStore()
    /// @State on purpose: the engine publishes every frame, and only the script view should redraw.
    @State private var engine = PrompterEngine()

    @State private var countdownValue: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var showScripts = false
    @State private var showSettings = false
    @State private var review: Take?
    @State private var editAfterReview: [URL]?
    @State private var sessionTakes: [URL] = []
    @FocusState private var keyboardFocus: Bool
    @Environment(\.scenePhase) private var scenePhase

    struct Take: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private var isRecording: Bool { camera.state == .recording || camera.state == .paused }
    private var isBusy: Bool { camera.state != .idle || countdownValue != nil }
    private var orientationMatches: Bool { camera.isPortraitHold == settings.canvas.isPortrait }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if camera.permission == .denied {
                    permissionView
                } else {
                    cameraFrame
                    VStack(spacing: 8) {
                        topBar
                        TeleprompterView(
                            engine: engine,
                            text: scripts.selected?.body ?? "",
                            fontSize: settings.fontSize,
                            mirrored: settings.mirrorText,
                            centered: settings.centerText,
                            backgroundOpacity: settings.prompterOpacity,
                            onFontSizeChange: { settings.setFontSize($0) }
                        )
                        .frame(height: geo.size.height * settings.prompterHeight)
                        .padding(.horizontal, 10)

                        Spacer(minLength: 0)

                        if let message = camera.errorMessage { errorBanner(message) }
                        if !orientationMatches && !isBusy { orientationHint }
                        prompterControls
                        bottomBar
                    }
                    .padding(.bottom, 8)
                }

                if let value = countdownValue { CountdownOverlay(value: value) }
            }
        }
        .toolbar(isBusy ? .hidden : .visible, for: .tabBar)
        .statusBarHidden(isBusy)
        .persistentSystemOverlays(isBusy ? .hidden : .automatic)
        .focusable()
        .focused($keyboardFocus)
        .focusEffectDisabled()
        // Bluetooth page turners and keyboards work as a remote.
        .onKeyPress(.space) { engine.toggle(); return .handled }
        .onKeyPress(.upArrow) { engine.nudge(by: -lineStep); return .handled }
        .onKeyPress(.downArrow) { engine.nudge(by: lineStep); return .handled }
        .onKeyPress(.pageUp) { engine.nudge(by: -lineStep * 3); return .handled }
        .onKeyPress(.pageDown) { engine.nudge(by: lineStep * 3); return .handled }
        .onKeyPress(.leftArrow) { settings.adjustSpeed(by: -10); return .handled }
        .onKeyPress(.rightArrow) { settings.adjustSpeed(by: 10); return .handled }
        .onKeyPress(.return) { recordTapped(); return .handled }
        .onAppear {
            engine.speed = settings.scrollSpeed
            keyboardFocus = true
            if camera.permission == .unknown {
                camera.start(front: settings.useFrontCamera, quality: settings.quality)
            } else {
                camera.startSession()
            }
        }
        .onDisappear {
            cancelCountdown()
            if isRecording { stopRecording() }
            camera.stopSession()
        }
        .onChange(of: settings.scrollSpeed) { _, speed in engine.speed = speed }
        .onChange(of: settings.useFrontCamera) { _, front in camera.configure(front: front, quality: settings.quality) }
        .onChange(of: settings.quality) { _, quality in camera.configure(front: settings.useFrontCamera, quality: quality) }
        .onChange(of: scripts.selectedID) { _, _ in engine.rewind() }
        .onChange(of: camera.finishedTake) { _, url in
            guard let url else { return }
            camera.finishedTake = nil
            sessionTakes.append(url)
            review = Take(url: url)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                cancelCountdown()
                if isRecording { stopRecording() }
            case .active:
                camera.startSession()
            default:
                break
            }
        }
        .sheet(isPresented: $showScripts) { ScriptLibraryView(store: scripts) }
        .sheet(isPresented: $showSettings) { RecorderSettingsView(settings: settings, supports4K: camera.supports4K) }
        .fullScreenCover(item: $review, onDismiss: openEditorIfRequested) { take in
            TakeReviewView(
                url: take.url,
                sessionTakes: sessionTakes,
                onRetake: {
                    try? FileManager.default.removeItem(at: take.url)
                    sessionTakes.removeAll { $0 == take.url }
                    engine.rewind()
                    review = nil
                },
                onEdit: { urls in
                    editAfterReview = urls
                    review = nil
                },
                onKeep: {
                    engine.rewind()
                    review = nil
                }
            )
        }
    }

    // MARK: Pieces

    /// The camera picture in the exact shape of the take, so what you see is what records.
    private var cameraFrame: some View {
        CameraPreview(camera: camera)
            .aspectRatio(settings.canvas.isPortrait ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
            .overlay { if settings.showGrid { ThirdsGrid() } }
            .overlay {
                if isRecording {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(camera.state == .paused ? Color.yellow : Theme.accent, lineWidth: 3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if isRecording {
                recordingBadge
                Spacer()
                Text("\(settings.canvas.rawValue) · \(camera.activeQuality.rawValue) · 30 fps")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            } else {
                Button { showScripts = true } label: {
                    Label(scripts.selected?.displayTitle ?? "Scripts", systemImage: "text.alignleft")
                        .lineLimit(1)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                aspectPicker
                qualityToggle
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .padding(9)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Recorder settings")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .disabled(countdownValue != nil)
    }

    private var aspectPicker: some View {
        HStack(spacing: 0) {
            ForEach([CanvasFormat.vertical, CanvasFormat.horizontal]) { format in
                Button { settings.canvas = format } label: {
                    Text(format.rawValue)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(settings.canvas == format ? Theme.accent : Color.clear, in: Capsule())
                        .foregroundStyle(settings.canvas == format ? Color.black : Color.white)
                }
            }
        }
        .padding(2)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video shape")
    }

    private var qualityToggle: some View {
        Button {
            settings.quality = settings.quality == .uhd4K ? .hd1080 : .uhd4K
        } label: {
            Text(camera.activeQuality.rawValue)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("Resolution \(camera.activeQuality.rawValue)")
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(camera.state == .paused ? Color.yellow : Color.red)
                .frame(width: 10, height: 10)
            Text(camera.state == .paused ? "Paused \(RecorderFormat.time(camera.elapsed))" : RecorderFormat.time(camera.elapsed))
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var prompterControls: some View {
        HStack(spacing: 10) {
            Button { engine.rewind() } label: { controlIcon("backward.end.fill") }
                .accessibilityLabel("Back to the start of the script")
            ScrollPlayButton(engine: engine)

            stepper(label: "Speed", value: "\(Int(settings.scrollSpeed / 10))",
                    minus: { settings.adjustSpeed(by: -10) }, plus: { settings.adjustSpeed(by: 10) })
            stepper(label: "Text", value: "\(Int(settings.fontSize))",
                    minus: { settings.setFontSize(settings.fontSize - 2) }, plus: { settings.setFontSize(settings.fontSize + 2) })
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
    }

    private var bottomBar: some View {
        HStack {
            // Left: switch camera while idle, pause or resume while recording.
            Group {
                if isRecording {
                    Button(action: togglePause) {
                        Image(systemName: camera.state == .paused ? "play.fill" : "pause.fill")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(camera.state == .paused ? "Resume recording" : "Pause recording")
                } else {
                    Button { settings.useFrontCamera.toggle() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("Switch camera")
                }
            }
            .frame(maxWidth: .infinity)

            RecordButton(state: camera.state, countingDown: countdownValue != nil,
                         enabled: orientationMatches || isBusy, action: recordTapped)
                .frame(maxWidth: .infinity)

            // Right: the takes recorded so far.
            Group {
                if let last = sessionTakes.last, !isBusy {
                    Button { review = Take(url: last) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "film.stack").font(.title3)
                            Text("\(sessionTakes.count)").font(.caption2.weight(.bold))
                        }
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Review takes")
                } else {
                    Color.clear.frame(width: 56, height: 56)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    private var orientationHint: some View {
        Label(settings.canvas.isPortrait ? "Hold your phone upright to record 9:16"
                                         : "Turn your phone sideways to record 16:9",
              systemImage: settings.canvas.isPortrait ? "iphone" : "iphone.landscape")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.footnote)
            Spacer(minLength: 0)
            Button { camera.errorMessage = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Cueframe needs your camera and microphone to record.")
                .font(.headline).multilineTextAlignment(.center)
            Text("Turn on Camera and Microphone for Cueframe in Settings.")
                .font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.subheadline.weight(.semibold))
            .frame(width: 40, height: 40)
            .background(.ultraThinMaterial, in: Circle())
    }

    private func stepper(label: String, value: String,
                         minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: minus) { Image(systemName: "minus").frame(width: 32, height: 36) }
                .accessibilityLabel("Less \(label.lowercased())")
            VStack(spacing: 0) {
                Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim)
                Text(value).font(.subheadline.monospacedDigit().weight(.bold))
            }
            .frame(minWidth: 34)
            Button(action: plus) { Image(systemName: "plus").frame(width: 32, height: 36) }
                .accessibilityLabel("More \(label.lowercased())")
        }
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private var lineStep: CGFloat { settings.fontSize * 1.3 }

    // MARK: Actions

    private func recordTapped() {
        switch camera.state {
        case .idle:
            if countdownValue != nil { cancelCountdown(); return }
            guard orientationMatches, camera.permission == .granted else { return }
            camera.errorMessage = nil
            runCountdown(seconds: settings.countdown) {
                camera.startRecording(codec: settings.codec)
                if settings.scrollStartsWithRecording { engine.play() }
            }
        case .recording, .paused:
            stopRecording()
        case .finishing:
            break
        }
    }

    private func togglePause() {
        switch camera.state {
        case .recording:
            camera.pause()
            engine.pause()
        case .paused:
            // A short countdown so you can get back in position before it rolls again.
            runCountdown(seconds: min(settings.countdown, 3)) {
                camera.resume()
                if settings.scrollStartsWithRecording { engine.play() }
            }
        default:
            break
        }
    }

    private func stopRecording() {
        cancelCountdown()
        engine.pause()
        camera.stopRecording()
    }

    private func runCountdown(seconds: Int, then action: @escaping () -> Void) {
        cancelCountdown()
        guard seconds > 0 else { action(); return }
        let tick = UIImpactFeedbackGenerator(style: .medium)
        countdownTask = Task { @MainActor in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                countdownValue = remaining
                tick.impactOccurred()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdownValue = nil
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            action()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownValue = nil
    }

    private func openEditorIfRequested() {
        guard let urls = editAfterReview, !urls.isEmpty else { return }
        editAfterReview = nil
        engine.rewind()
        EditorLauncher.open(urls: urls, canvas: settings.canvas, quality: camera.activeQuality)
    }
}

/// Starts or pauses the script scroll. Its own view so only it redraws while the script moves.
private struct ScrollPlayButton: View {
    @ObservedObject var engine: PrompterEngine

    var body: some View {
        Button { engine.toggle() } label: {
            Image(systemName: engine.isScrolling ? "pause.fill" : "play.fill")
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(engine.isScrolling ? "Pause script" : "Scroll script")
    }
}

private struct RecordButton: View {
    let state: CameraController.State
    let countingDown: Bool
    let enabled: Bool
    let action: () -> Void

    private var isRecording: Bool { state == .recording || state == .paused }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 5).frame(width: 78, height: 78)
                if state == .finishing {
                    ProgressView().tint(.white)
                } else {
                    RoundedRectangle(cornerRadius: isRecording ? 8 : 32)
                        .fill(countingDown ? Color.white.opacity(0.7) : Theme.accent)
                        .frame(width: isRecording ? 32 : 64, height: isRecording ? 32 : 64)
                        .animation(.snappy, value: isRecording)
                }
            }
        }
        .disabled(!enabled || state == .finishing)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(isRecording ? "Stop recording" : countingDown ? "Cancel countdown" : "Start recording")
    }
}
