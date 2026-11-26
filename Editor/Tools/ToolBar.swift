import SwiftUI
import PhotosUI

/// Bottom row of tools. Changes with what is selected.
struct ToolBar: View {
    @ObservedObject var session: EditorSession
    var pick: (EditorTool) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                switch session.selection {
                case .clip:
                    tool("Trim", "timeline.selection") { pick(.trim) }
                    tool("Split", "scissors") { session.splitAtPlayhead() }
                    tool("Speed", "gauge.with.dots.needle.67percent") { pick(.speed) }
                    tool("Volume", "speaker.wave.2") { pick(.volume) }
                    tool("Filters", "camera.filters") { pick(.filters) }
                    tool("Adjust", "slider.horizontal.3") { pick(.adjust) }
                    tool("Frame", "crop") { pick(.framing) }
                    tool("Transition", "square.split.2x1") { pick(.transition) }
                    tool("Reverse", "backward.fill") { Task { await session.reverseActiveClip() } }
                    tool("Copy", "plus.square.on.square") { session.duplicateSelection() }
                    tool("Delete", "trash", tint: .red) { session.deleteSelection() }
                case .text:
                    tool("Edit", "character.cursor.ibeam") { pick(.textStyle) }
                    tool("Copy", "plus.square.on.square") { session.duplicateSelection() }
                    tool("Delete", "trash", tint: .red) { session.deleteSelection() }
                case .audio:
                    tool("Volume", "speaker.wave.2") { pick(.audioEdit) }
                    tool("Split", "scissors") { splitAudio() }
                    tool("Copy", "plus.square.on.square") { session.duplicateSelection() }
                    tool("Delete", "trash", tint: .red) { session.deleteSelection() }
                case .none:
                    tool("Auto-cut", "wand.and.stars") { pick(.autoCut) }
                    tool("Captions", "captions.bubble") { pick(.captions) }
                    tool("Canvas", "aspectratio") { pick(.canvas) }
                    tool("Text", "textformat") { session.addText(); pick(.textStyle) }
                    tool("Clean audio", "waveform.badge.magnifyingglass") { pick(.cleanup) }
                    tool("Brand", "seal") { pick(.brand) }
                    tool("AI", "sparkles") { pick(.ai) }
                    tool("Music", "music.note") { pick(.music) }
                    tool("Voiceover", "mic") { pick(.voiceover) }
                    tool("Filters", "camera.filters") { pick(.filters) }
                    tool("Adjust", "slider.horizontal.3") { pick(.adjust) }
                    tool("Background", "square.fill.on.square") { pick(.background) }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func splitAudio() {
        guard let i = session.selectedAudioIndex else { return }
        let a = session.project.audio[i]
        let t = session.currentTime
        guard t > a.start + 0.2, t < a.end - 0.2 else {
            session.message = "Move the playhead inside the sound to split it."
            return
        }
        session.edit { p in
            var left = a, right = a
            left.duration = t - a.start
            left.fadeOut = 0
            right.id = UUID()
            right.start = t
            right.sourceStart = a.sourceStart + (t - a.start)
            right.duration = a.end - t
            right.fadeIn = 0
            p.audio[i] = left
            p.audio.append(right)
        }
    }

    private func tool(_ title: String, _ symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
        }
    }
}

/// "+" at the end of the clips to append more videos.
struct AddClipButton: View {
    @ObservedObject var session: EditorSession
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $items, maxSelectionCount: 20, selectionBehavior: .ordered, matching: .videos,
                     preferredItemEncoding: .current) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 36, height: 36)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.black)
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                session.message = "Adding clips…"
                let urls = await MediaImport.movies(from: picked)
                await session.addClips(urls)
                session.message = nil
                items = []
            }
        }
    }
}

/// Panel host with a header and done button.
struct ToolPanel: View {
    let tool: EditorTool
    @ObservedObject var session: EditorSession
    let transitionIndex: Int?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Button { close() } label: {
                    Image(systemName: "checkmark").font(.headline).padding(8).background(Theme.panelRaised, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            Group {
                switch tool {
                case .canvas: CanvasPanel(session: session)
                case .background: BackgroundPanel(session: session)
                case .text, .textStyle: TextPanel(session: session)
                case .captions: CaptionsPanel(session: session)
                case .music: MusicPanel(session: session)
                case .voiceover: VoiceoverPanel(session: session)
                case .filters: FilterPanel(session: session)
                case .adjust: AdjustPanel(session: session)
                case .trim: TrimPanel(session: session)
                case .speed: SpeedPanel(session: session)
                case .volume: ClipVolumePanel(session: session)
                case .framing: FramingPanel(session: session)
                case .transition: TransitionPanel(session: session, index: transitionIndex ?? session.activeClipIndex ?? 0)
                case .audioEdit: AudioEditPanel(session: session)
                case .autoCut: AutoCutPanel(session: session)
                case .cleanup: CleanupPanel(session: session)
                case .brand: BrandPanel(session: session)
                case .ai: AIPanel(session: session)
                case .addClip: EmptyView()
                }
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .background(Theme.panel)
    }

    private var title: String {
        switch tool {
        case .canvas: return "Canvas"
        case .background: return "Background"
        case .text, .textStyle: return "Text"
        case .captions: return "Captions and subtitles"
        case .music: return "Music"
        case .voiceover: return "Voiceover"
        case .filters: return session.selectedClipIndex == nil ? "Filters (clip under playhead)" : "Filters"
        case .adjust: return "Adjust"
        case .trim: return "Trim"
        case .speed: return "Speed"
        case .volume: return "Clip volume"
        case .framing: return "Frame"
        case .transition: return "Transition"
        case .audioEdit: return "Sound"
        case .autoCut: return "Auto-cut mistakes"
        case .cleanup: return "Clean up audio"
        case .brand: return "Brand kit"
        case .ai: return "AI help"
        case .addClip: return "Add"
        }
    }
}

/// Labeled slider row used by several panels.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var onReset: Double? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
                .onTapGesture(count: 2) { if let onReset { value = onReset } }
        }
    }
}
