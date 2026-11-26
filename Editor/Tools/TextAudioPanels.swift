import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct TextPanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if session.selectedTextIndex != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Type something", text: session.textBinding(\.text, "", key: "typing"), axis: .vertical)
                        .lineLimit(1...3)
                        .padding(10)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 10))
                    if let i = session.selectedTextIndex {
                        FontChips(style: session.project.texts[i].style) { font, custom in
                            session.editSelectedText { $0.style.font = font; $0.style.customFont = custom }
                        }
                    }
                    Swatches(color: session.textBinding(\.style.color, RGBA(r: 1, g: 1, b: 1), key: "color"))
                    SliderRow(title: "Size", value: session.textBinding(\.style.size, 0.07, key: "size"), range: 0.03...0.18,
                              format: { "\(Int($0 * 1000))" })
                    HStack {
                        Picker("Box", selection: session.textBinding(\.style.background, .none, key: "bg")) {
                            Text("Plain").tag(TextBackground.none)
                            Text("Box").tag(TextBackground.box)
                            Text("Pill").tag(TextBackground.pill)
                        }
                        .pickerStyle(.segmented)
                        Picker("Align", selection: session.textBinding(\.style.alignment, .center, key: "align")) {
                            Image(systemName: "text.alignleft").tag(TextAlign.leading)
                            Image(systemName: "text.aligncenter").tag(TextAlign.center)
                            Image(systemName: "text.alignright").tag(TextAlign.trailing)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                    if session.textBinding(\.style.background, .none, key: "bg").wrappedValue != .none {
                        Swatches(color: session.textBinding(\.style.backgroundColor, RGBA(r: 0, g: 0, b: 0, a: 0.6), key: "bgc"))
                    }
                    HStack {
                        Toggle("Outline", isOn: session.textBinding(\.style.outline, false, key: "outline"))
                        Toggle("Shadow", isOn: session.textBinding(\.style.shadow, true, key: "shadow"))
                    }
                    .font(.caption)
                    Text("Animation").font(.caption).foregroundStyle(Theme.textDim)
                    HStack {
                        ForEach(TextAnimation.allCases) { a in
                            let sel = session.textBinding(\.animation, .fade, key: "anim")
                            Chip(selected: sel.wrappedValue == a, action: { sel.wrappedValue = a }) { Text(a.label) }
                        }
                    }
                    Text("Drag, pinch or twist the text in the preview. Drag its bar on the timeline to change when it shows.")
                        .font(.caption2).foregroundStyle(Theme.textDim)
                    if let i = session.selectedTextIndex, session.project.texts[i].isCaption {
                        Button("Use this style for all captions") {
                            let style = session.project.texts[i].style
                            let y = session.project.texts[i].center.y
                            let look = session.project.texts[i].look
                            let anim = session.project.texts[i].animation
                            session.edit { p in
                                for j in p.texts.indices where p.texts[j].isCaption {
                                    p.texts[j].style = style
                                    p.texts[j].center.y = y
                                    p.texts[j].look = look
                                    p.texts[j].animation = anim
                                }
                            }
                        }
                        .font(.caption.bold())
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        } else {
            VStack {
                Button { session.addText() } label: { Label("Add text at playhead", systemImage: "plus") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MusicPanel: View {
    @ObservedObject var session: EditorSession
    @State private var showFiles = false
    @State private var videoItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button { showFiles = true } label: { bigButton("From Files", "folder") }
                PhotosPicker(selection: $videoItem, matching: .videos) { bigButton("Sound from a video", "film") }
            }
            Text("Use music you own or have licensed. Songs from Apple Music can't be used in edits (they're copy protected). For TikTok and Reels, you can also add trending sounds inside those apps after upload.")
                .font(.caption2).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            let music = session.project.audio.filter { $0.kind == .music }
            if !music.isEmpty {
                Text("\(music.count) music track\(music.count == 1 ? "" : "s") added. Tap one on the timeline to change volume and fades.")
                    .font(.caption)
            }
        }
        .padding(.horizontal)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
            guard case .success(let url) = result, let local = MediaImport.copyIn(url) else { return }
            Task { await session.addAudio(url: local, kind: .music, name: url.deletingPathExtension().lastPathComponent) }
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    await session.addAudio(url: movie.url, kind: .music, name: "Video sound")
                }
                videoItem = nil
            }
        }
    }

    private func bigButton(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption.bold())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct VoiceoverPanel: View {
    @ObservedObject var session: EditorSession
    @StateObject private var recorder = VoiceRecorder()

    var body: some View {
        VStack(spacing: 12) {
            Text(recorder.isRecording ? "Recording… \(recorder.elapsed.timecode)" : "Starts at the playhead. The video plays silently while you talk.")
                .font(.caption).foregroundStyle(recorder.isRecording ? .white : Theme.textDim)
            Button {
                if recorder.isRecording { stop() } else { start() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                    } else {
                        Circle().fill(.red).frame(width: 60, height: 60)
                    }
                }
            }
            if recorder.isRecording {
                Capsule().fill(.green).frame(width: max(8, CGFloat(recorder.level) * 220), height: 6)
                    .animation(.linear(duration: 0.05), value: recorder.level)
            }
        }
        .padding()
        .onDisappear { if recorder.isRecording { stop() } }
        // The video stopping (end of timeline, or play/pause tapped) ends the voiceover too,
        // otherwise it keeps recording past the end of the video.
        .onChange(of: session.isPlaying) { _, playing in
            if !playing && recorder.isRecording { stop() }
        }
    }

    private func start() {
        Task {
            do {
                // Playing from the end jumps back to the start, so start there now; otherwise the
                // voiceover is placed at the old playhead while you talk over the beginning.
                if session.currentTime >= session.project.duration - 0.05 { session.seek(0) }
                try await recorder.start(at: session.currentTime)
                session.player.isMuted = true
                if !session.isPlaying { session.togglePlay() }
            } catch {
                session.message = error.localizedDescription
            }
        }
    }

    private func stop() {
        session.pause()
        session.player.isMuted = false
        let at = recorder.startTime
        if let url = recorder.stop() {
            Task { await session.addAudio(url: url, kind: .voiceover, name: "Voiceover", at: at) }
        }
    }
}

struct AudioEditPanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if let i = session.selectedAudioIndex {
            let item = session.project.audio[i]
            let vol = session.audioBinding(\.volume, 1, key: "avol")
            ScrollView {
                VStack(spacing: 8) {
                    Text(item.name).font(.caption.bold()).lineLimit(1)
                    SliderRow(title: "Volume", value: Binding(get: { Double(vol.wrappedValue) }, set: { vol.wrappedValue = Float($0) }),
                              range: 0...1, format: { "\(Int($0 * 100))%" })
                    SliderRow(title: "Fade in", value: session.audioBinding(\.fadeIn, 0, key: "fin"), range: 0...5, format: { String(format: "%.1fs", $0) })
                    SliderRow(title: "Fade out", value: session.audioBinding(\.fadeOut, 0, key: "fout"), range: 0...5, format: { String(format: "%.1fs", $0) })
                    if item.kind == .music {
                        Toggle("Loop to fill the video", isOn: session.audioBinding(\.loop, false, key: "loop")).font(.caption)
                    }
                    Button("Lower all clip sound to 30%") {
                        session.edit { p in for j in p.clips.indices { p.clips[j].volume = min(p.clips[j].volume, 0.3) } }
                    }
                    .font(.caption.bold())
                }
                .padding(.horizontal)
            }
        } else {
            Text("Select a sound on the timeline.").font(.footnote).foregroundStyle(Theme.textDim)
        }
    }
}
