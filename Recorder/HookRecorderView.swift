import SwiftUI
import AVKit

/// Records one opening line (a hook version) from inside the editor. The line sits right under the
/// lens in large type, since a hook is short enough to read in one glance.
struct HookRecorderView: View {
    let line: String
    let canvas: CanvasFormat
    var onUse: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()
    @StateObject private var settings = RecorderSettings()
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var take: URL?
    @State private var player: AVPlayer?

    private var isRecording: Bool { camera.state == .recording || camera.state == .paused }
    private var orientationOK: Bool { camera.isPortraitHold == canvas.isPortrait }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let take {
                review(take)
            } else {
                CameraPreview(camera: camera)
                    .aspectRatio(canvas.isPortrait ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    Text(line.isEmpty ? "Say your opening line" : line)
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.55))
                        .foregroundStyle(.white)
                    Spacer()
                    if !orientationOK {
                        Text(canvas.isPortrait ? "Hold the phone upright for this video." : "Turn the phone sideways for this video.")
                            .font(.subheadline.bold()).padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    if let e = camera.errorMessage {
                        Text(e).font(.footnote).foregroundStyle(.red).padding(8).background(.black.opacity(0.6), in: Capsule())
                    }
                    controls
                }
                if let countdown {
                    Text("\(countdown)").font(.system(size: 120, weight: .heavy)).foregroundStyle(.white).shadow(radius: 8)
                }
            }
        }
        .statusBarHidden()
        .onAppear {
            OrientationLock.release()
            camera.start(front: settings.useFrontCamera, quality: settings.quality)
        }
        .onDisappear {
            countdownTask?.cancel()
            if isRecording { camera.stopRecording() }
            camera.stopSession()
            player?.pause()
            OrientationLock.portrait()
            PlaybackAudio.activate()
        }
        .onChange(of: camera.finishedTake) { _, url in
            guard let url else { return }
            camera.finishedTake = nil
            camera.stopSession()
            PlaybackAudio.activate()
            take = url
        }
    }

    private var controls: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.title2.bold()).frame(width: 56, height: 56)
            }
            .disabled(isRecording)
            Spacer()
            Button(action: recordTapped) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 32, height: 32)
                    } else {
                        Circle().fill(.red).frame(width: 64, height: 64)
                    }
                }
            }
            .disabled(!orientationOK || camera.permission != .granted || camera.state == .finishing)
            .accessibilityLabel(isRecording ? "Stop" : "Record")
            Spacer()
            Button {
                settings.useFrontCamera.toggle()
                camera.configure(front: settings.useFrontCamera, quality: settings.quality)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).frame(width: 56, height: 56)
            }
            .disabled(isRecording)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    private func review(_ url: URL) -> some View {
        VStack(spacing: 16) {
            VideoPlayer(player: player)
                .onAppear {
                    let p = AVPlayer(url: url)
                    player = p
                    p.play()
                }
            HStack(spacing: 16) {
                Button {
                    player?.pause()
                    try? FileManager.default.removeItem(at: url)
                    take = nil
                    camera.startSession()
                } label: {
                    Text("Retake").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 14))
                }
                Button {
                    player?.pause()
                    onUse(url)
                    dismiss()
                } label: {
                    Text("Use this take").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func recordTapped() {
        if isRecording { camera.stopRecording(); return }
        if countdown != nil { countdownTask?.cancel(); countdown = nil; return }
        camera.errorMessage = nil
        countdownTask = Task { @MainActor in
            for n in stride(from: 3, through: 1, by: -1) {
                countdown = n
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            countdown = nil
            camera.startRecording(codec: settings.codec)
        }
    }
}
