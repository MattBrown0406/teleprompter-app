import SwiftUI

/// Scrubbable multi-lane timeline. The playhead stays in the middle; dragging moves time.
/// Lanes: clips (with transition buttons), text and captions, music and voiceover.
struct EditorTimeline: View {
    @ObservedObject var session: EditorSession
    var onTransitionTap: (Int) -> Void

    @State private var pps: CGFloat = 60          // points per second
    @State private var ppsStart: CGFloat?
    @State private var scrubStart: Double?
    @State private var itemDrag: (id: UUID, start: Double, end: Double)?

    private let clipHeight: CGFloat = 58
    private let laneHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            let x0 = mid - CGFloat(session.currentTime) * pps   // x of time 0
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(scrub)
                    .simultaneousGesture(zoom)
                    .onTapGesture { session.selection = .none }

                ruler(x0: x0, width: geo.size.width)
                    .offset(y: 2)

                clipLane(x0: x0).offset(y: 22)
                textLane(x0: x0).offset(y: 22 + clipHeight + 8)
                audioLane(x0: x0).offset(y: 22 + clipHeight + 8 + laneHeight + 6)

                // Playhead
                Rectangle().fill(.white).frame(width: 2, height: geo.size.height - 4)
                    .shadow(radius: 2)
                    .offset(x: mid - 1, y: 2)
                    .allowsHitTesting(false)

                addClipButton(x: x0 + CGFloat(session.project.duration) * pps + 10)
                    .offset(y: 22 + clipHeight / 2 - 18)
            }
            .clipped()
        }
        .background(Theme.panel)
    }

    // MARK: Gestures

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if scrubStart == nil { scrubStart = session.currentTime; session.pause() }
                session.seek(scrubStart! - Double(v.translation.width / pps), precise: false)
            }
            .onEnded { _ in
                scrubStart = nil
                session.seek(session.currentTime)
            }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if ppsStart == nil { ppsStart = pps }
                pps = max(8, min(400, ppsStart! * v.magnification))
            }
            .onEnded { _ in ppsStart = nil }
    }

    // MARK: Lanes

    private func ruler(x0: CGFloat, width: CGFloat) -> some View {
        let step: Double = pps > 120 ? 0.5 : pps > 40 ? 1 : pps > 15 ? 5 : 10
        let first = max(0, floor(Double(-x0 / pps) / step) * step)
        let last = Double((width - x0) / pps)
        let ticks = Array(stride(from: first, through: max(first, last), by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { t in
                Text(t.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(t))s" : "·")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
                    .offset(x: x0 + CGFloat(t) * pps - 4)
            }
        }
        .allowsHitTesting(false)
    }

    private func clipLane(x0: CGFloat) -> some View {
        let starts = session.project.clipStarts
        return ZStack(alignment: .topLeading) {
            ForEach(Array(session.project.clips.enumerated()), id: \.element.id) { i, clip in
                let x = x0 + CGFloat(starts[i]) * pps
                let w = max(4, CGFloat(clip.outputDuration) * pps)
                ClipStrip(clip: clip, width: w, height: clipHeight, selected: session.selection == .clip(clip.id))
                    .offset(x: x)
                    .onTapGesture { session.selection = .clip(clip.id) }
                    .contextMenu {
                        Button("Move left", systemImage: "arrow.left") { session.moveClip(from: i, to: i - 1) }.disabled(i == 0)
                        Button("Move right", systemImage: "arrow.right") { session.moveClip(from: i, to: i + 1) }
                            .disabled(i == session.project.clips.count - 1)
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            session.selection = .clip(clip.id); session.duplicateSelection()
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            session.selection = .clip(clip.id); session.deleteSelection()
                        }
                    }
                if i < session.project.clips.count - 1 {
                    let tx = x0 + CGFloat(starts[i + 1] + session.project.transitionDuration(after: i) / 2) * pps
                    Button { onTransitionTap(i) } label: {
                        Image(systemName: clip.transitionOut == .none ? "plus" : clip.transitionOut.symbol)
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(clip.transitionOut == .none ? Color.white : Theme.accent2, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.black)
                    }
                    .offset(x: tx - 12, y: clipHeight / 2 - 12)
                }
            }
        }
    }

    private func textLane(x0: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.project.texts) { item in
                let selected = session.selection == .text(item.id)
                laneBar(id: item.id, start: item.start, end: item.end, x0: x0,
                        color: item.isCaption ? Color.yellow.opacity(0.85) : Theme.accent,
                        icon: item.isCaption ? "captions.bubble" : "textformat",
                        label: item.text, selected: selected) { s, e in
                    session.edit("textTime") { p in
                        if let j = p.texts.firstIndex(where: { $0.id == item.id }) {
                            p.texts[j].start = s; p.texts[j].end = e
                        }
                    }
                }
                .onTapGesture { session.selection = .text(item.id) }
            }
        }
    }

    private func audioLane(x0: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.project.audio) { item in
                let selected = session.selection == .audio(item.id)
                laneBar(id: item.id, start: item.start, end: item.end, x0: x0,
                        color: item.kind == .voiceover ? Color.green.opacity(0.8) : Theme.accent2,
                        icon: item.kind == .voiceover ? "mic.fill" : "music.note",
                        label: item.name, selected: selected) { s, e in
                    session.edit("audioTime") { p in
                        if let j = p.audio.firstIndex(where: { $0.id == item.id }) {
                            let a = p.audio[j]
                            // Moving the left edge trims the start of the song; moving the bar keeps it.
                            let delta = s - a.start
                            if abs((e - s) - a.duration) > 0.001 && abs(e - a.end) < 0.001 {
                                p.audio[j].sourceStart = max(0, a.sourceStart + delta)
                            }
                            p.audio[j].start = s
                            p.audio[j].duration = e - s
                        }
                    }
                }
                .onTapGesture { session.selection = .audio(item.id) }
            }
        }
    }

    /// A draggable bar. Drag the middle to move, drag an edge (when selected) to change length.
    private func laneBar(id: UUID, start: Double, end: Double, x0: CGFloat, color: Color, icon: String,
                         label: String, selected: Bool, onChange: @escaping (Double, Double) -> Void) -> some View {
        let x = x0 + CGFloat(start) * pps
        let w = max(18, CGFloat(end - start) * pps)
        let total = session.project.duration
        func moveGesture(_ mode: Int) -> BarDrag { barDrag(id: id, start: start, end: end, mode: mode, total: total, onChange: onChange) }
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: w, height: laneHeight, alignment: .leading)
        .background(color.opacity(selected ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: selected ? 2 : 0))
        .foregroundStyle(.black)
        .overlay(alignment: .leading) {
            if selected { handle.gesture(moveGesture(1)) }
        }
        .overlay(alignment: .trailing) {
            if selected { handle.gesture(moveGesture(2)) }
        }
        .gesture(moveGesture(0), including: selected ? .all : .subviews)
        .offset(x: x)
    }

    typealias BarDrag = _EndedGesture<_ChangedGesture<DragGesture>>

    /// mode 0 moves the bar, 1 drags the left edge, 2 the right edge.
    private func barDrag(id: UUID, start: Double, end: Double, mode: Int, total: Double,
                         onChange: @escaping (Double, Double) -> Void) -> BarDrag {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if itemDrag?.id != id { itemDrag = (id, start, end) }
                guard let d = itemDrag else { return }
                let dt = Double(v.translation.width / pps)
                switch mode {
                case 0:
                    let len = d.end - d.start
                    let s = min(max(0, d.start + dt), max(0, total - len))
                    onChange(s, s + len)
                case 1: onChange(min(max(0, d.start + dt), d.end - 0.2), d.end)
                default: onChange(d.start, max(d.start + 0.2, min(total, d.end + dt)))
                }
            }
            .onEnded { _ in itemDrag = nil }
    }

    private var handle: some View {
        Capsule().fill(.white).frame(width: 8, height: laneHeight + 6).contentShape(Rectangle().inset(by: -10))
    }

    private func addClipButton(x: CGFloat) -> some View {
        AddClipButton(session: session)
            .offset(x: x)
    }
}

/// Filmstrip for one clip.
struct ClipStrip: View {
    let clip: ClipItem
    let width: CGFloat
    let height: CGFloat
    let selected: Bool

    var body: some View {
        let frameW = height * 0.75
        let count = max(1, Int(ceil(width / frameW)))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { k in
                let local = (Double(k) + 0.5) / Double(count) * clip.trimmedDuration
                ThumbnailImage(path: clip.path, seconds: clip.trimStart + local)
                    .frame(width: frameW, height: height)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                if clip.speed != 1 { Text(String(format: "%.2gx", clip.speed)) }
                if clip.volume == 0 { Image(systemName: "speaker.slash.fill") }
                if clip.filter != .none { Image(systemName: "camera.filters") }
            }
            .font(.system(size: 9, weight: .bold))
            .padding(3)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            .padding(3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : .clear, lineWidth: 3))
    }
}
