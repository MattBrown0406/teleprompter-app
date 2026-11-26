import SwiftUI
import AVKit
import Photos

/// Shown after each take: watch it back, then save, share, edit or retake.
struct TakeReviewView: View {
    let url: URL
    /// Every take recorded since the recorder opened, oldest first, including this one.
    let sessionTakes: [URL]
    var onRetake: () -> Void
    var onEdit: ([URL]) -> Void
    var onKeep: () -> Void

    @State private var player: AVPlayer
    @State private var saveState: SaveState = .idle
    @State private var confirmDiscard = false
    @State private var fileInfo = ""

    enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    init(url: URL, sessionTakes: [URL], onRetake: @escaping () -> Void,
         onEdit: @escaping ([URL]) -> Void, onKeep: @escaping () -> Void) {
        self.url = url
        self.sessionTakes = sessionTakes
        self.onRetake = onRetake
        self.onEdit = onEdit
        self.onKeep = onKeep
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button { confirmDiscard = true } label: {
                    Label("Retake", systemImage: "arrow.counterclockwise")
                }
                Spacer()
                Text(fileInfo).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim)
                Spacer()
                Button("Done") { onKeep() }.fontWeight(.semibold)
            }
            .padding(.horizontal)

            VideoPlayer(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

            HStack(spacing: 12) {
                actionButton(saveTitle, systemImage: saveIcon, disabled: saveState == .saving || saveState == .saved) {
                    Task { await saveToPhotos() }
                }
                ShareLink(item: url) {
                    actionLabel("Share", systemImage: "square.and.arrow.up")
                }
                actionButton("Edit", systemImage: "scissors", prominent: true) {
                    player.pause()
                    onEdit([url])
                }
            }
            .padding(.horizontal)

            if sessionTakes.count > 1 {
                Button {
                    player.pause()
                    onEdit(sessionTakes)
                } label: {
                    Text("Edit all \(sessionTakes.count) takes together")
                        .font(.subheadline.weight(.semibold))
                }
            }

            if case .failed(let message) = saveState {
                Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
        }
        .padding(.vertical)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { player.play() }
        .task { await loadFileInfo() }
        .onDisappear { player.pause() }
        .confirmationDialog("Delete this take and record again?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Delete and retake", role: .destructive) {
                player.pause()
                onRetake()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var saveTitle: String {
        switch saveState {
        case .saving: return "Saving"
        case .saved: return "Saved"
        default: return "Save"
        }
    }

    private var saveIcon: String { saveState == .saved ? "checkmark.circle.fill" : "photo.on.rectangle" }

    /// Size, length and file size, read from the file once the view opens.
    private func loadFileInfo() async {
        let asset = AVURLAsset(url: url)
        var parts: [String] = []
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform) {
            let shown = loaded.0.applying(loaded.1)
            parts.append("\(Int(abs(shown.width)))×\(Int(abs(shown.height)))")
        }
        if let duration = try? await asset.load(.duration) {
            parts.append(RecorderFormat.time(duration.seconds))
        }
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        fileInfo = parts.joined(separator: " · ")
    }

    private func saveToPhotos() async {
        saveState = .saving
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed("Allow Cueframe to add to Photos in Settings, then try again.")
            return
        }
        do {
            let fileURL = url
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func actionButton(_ title: String, systemImage: String, prominent: Bool = false,
                              disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, systemImage: systemImage, prominent: prominent) }
            .disabled(disabled)
    }

    private func actionLabel(_ title: String, systemImage: String, prominent: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title3)
            Text(title).font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .foregroundStyle(prominent ? Color.black : Color.white)
        .background(prominent ? Theme.accent : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
    }
}
