import SwiftUI
import AVFoundation

/// Which panel is open under the timeline.
enum EditorTool: String, Identifiable {
    case canvas, background, text, textStyle, captions, music, voiceover, filters, adjust, trim, speed, volume,
         framing, transition, audioEdit, addClip, autoCut, cleanup, brand, ai
    var id: String { rawValue }
}

struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: EditorSession
    @State private var tool: EditorTool?
    @State private var transitionIndex: Int?
    @State private var showExport = false

    init(project: EditProject) {
        _session = StateObject(wrappedValue: EditorSession(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            PreviewCanvas(session: session)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 12)
            transport
            EditorTimeline(session: session, onTransitionTap: { i in
                transitionIndex = i
                session.selection = .clip(session.project.clips[i].id)
                tool = .transition
            })
            .frame(height: 176)
            Divider().overlay(Color.white.opacity(0.08))
            if let tool {
                ToolPanel(tool: tool, session: session, transitionIndex: transitionIndex) { self.tool = nil }
                    .frame(height: 230)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ToolBar(session: session) { picked in
                    if picked == .transition { transitionIndex = session.activeClipIndex }
                    withAnimation(.snappy) { tool = picked }
                }
                .frame(height: 84)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.snappy, value: tool)
        .onChange(of: session.selection) { _, sel in
            // Close panels that don't fit the new selection.
            switch (tool, sel) {
            case (.textStyle?, .text), (.audioEdit?, .audio): break
            case (.trim?, .clip), (.speed?, .clip), (.volume?, .clip), (.framing?, .clip), (.filters?, .clip),
                 (.adjust?, .clip), (.transition?, .clip): break
            case (.some(let t), _) where [.trim, .speed, .volume, .framing, .textStyle, .audioEdit].contains(t): tool = nil
            default: break
            }
        }
        .sheet(isPresented: $showExport) {
            ExportView(session: session).presentationDetents([.medium, .large])
        }
        .overlay(alignment: .top) {
            if let msg = session.message {
                Text(msg)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 56)
                    .onTapGesture { session.message = nil }
                    .task(id: msg) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if session.message == msg { session.message = nil }
                    }
            }
        }
        .overlay { if session.isLoading { ProgressView() } }
        .onAppear { PlaybackAudio.activate() }
        .onDisappear { session.pause(); session.flush() }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { session.pause(); dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)) }
            Menu {
                Picker("Canvas", selection: Binding(get: { session.project.canvas }, set: { c in session.edit { $0.canvas = c } })) {
                    ForEach(CanvasFormat.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label(session.project.canvas.shortLabel, systemImage: "aspectratio").font(.subheadline.weight(.semibold))
            }
            Spacer()
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!session.canUndo)
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!session.canRedo)
            Button {
                session.pause()
                showExport = true
            } label: {
                Text("Export").font(.subheadline.bold())
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
            .disabled(session.project.clips.isEmpty)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transport: some View {
        HStack {
            Text("\(session.currentTime.timecode) / \(session.project.duration.timecode)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button { session.togglePlay() } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            Spacer()
            Button { session.splitAtPlayhead() } label: {
                Label("Split", systemImage: "scissors").font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

/// The video preview framed to the canvas, with direct manipulation of text and the clip.
struct PreviewCanvas: View {
    @ObservedObject var session: EditorSession
    @State private var dragStart: NPoint?
    @State private var pinchStart: Double?
    @State private var rotateStart: Double?

    var body: some View {
        GeometryReader { geo in
            let aspect = session.project.canvas.aspect
            let fitW = min(geo.size.width, geo.size.height * aspect)
            let size = CGSize(width: fitW, height: fitW / aspect)
            ZStack {
                PlayerLayerView(player: session.player)
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { location in tapCanvas(location, size: size) }
                    .gesture(clipGestures(size: size))
                if let i = session.selectedTextIndex {
                    textHandle(session.project.texts[i], size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    /// Visible text under a tap selects it; otherwise selects the clip under the playhead.
    private func tapCanvas(_ p: CGPoint, size: CGSize) {
        let t = session.currentTime
        let nx = Double(p.x / size.width), ny = Double(p.y / size.height)
        let hit = session.project.texts.last { item in
            t >= item.start && t < item.end &&
            abs(item.center.x - nx) < 0.3 * item.scale && abs(item.center.y - ny) < item.style.size * item.scale * 1.2 * Double(size.width / size.height)
        }
        if let hit {
            session.selection = .text(hit.id)
        } else if let i = session.project.clipIndex(at: t) {
            session.selection = .clip(session.project.clips[i].id)
        }
    }

    /// Drag to pan and pinch to zoom the selected clip inside the canvas.
    private func clipGestures(size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard let i = session.selectedClipIndex else { return }
                if dragStart == nil { dragStart = session.project.clips[i].offset }
                let s = dragStart!
                session.editClip("pan") {
                    $0.offset = NPoint(x: s.x + Double(v.translation.width / size.width), y: s.y + Double(v.translation.height / size.height))
                }
            }
            .onEnded { _ in dragStart = nil }
        let pinch = MagnifyGesture()
            .onChanged { v in
                guard let i = session.selectedClipIndex else { return }
                if pinchStart == nil { pinchStart = session.project.clips[i].zoom }
                let z = max(0.3, min(5, pinchStart! * Double(v.magnification)))
                session.editClip("zoom") { $0.zoom = z }
            }
            .onEnded { _ in pinchStart = nil }
        return drag.simultaneously(with: pinch)
    }

    private func textHandle(_ item: TextItem, size: CGSize) -> some View {
        let w: CGFloat = max(60, min(size.width * 0.9, CGFloat(item.text.count) * CGFloat(item.style.size * item.scale) * size.width * 0.6))
        let h: CGFloat = max(30, CGFloat(item.style.size * item.scale) * size.width * 1.5)
        return RoundedRectangle(cornerRadius: 4)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .rotationEffect(.degrees(item.rotation))
            .position(x: CGFloat(item.center.x) * size.width, y: CGFloat(item.center.y) * size.height)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if dragStart == nil { dragStart = item.center }
                        let s = dragStart!
                        session.editSelectedText("move") {
                            $0.center = NPoint(x: min(1, max(0, s.x + Double(v.translation.width / size.width))),
                                               y: min(1, max(0, s.y + Double(v.translation.height / size.height))))
                        }
                    }
                    .onEnded { _ in dragStart = nil }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { v in
                            if pinchStart == nil { pinchStart = item.scale }
                            let sc = max(0.3, min(4, pinchStart! * Double(v.magnification)))
                            session.editSelectedText("scale") { $0.scale = sc }
                        }
                        .onEnded { _ in pinchStart = nil })
                    .simultaneously(with: RotateGesture()
                        .onChanged { v in
                            if rotateStart == nil { rotateStart = item.rotation }
                            let r = rotateStart! + v.rotation.degrees
                            session.editSelectedText("rotate") { $0.rotation = r }
                        }
                        .onEnded { _ in rotateStart = nil })
            )
    }
}
