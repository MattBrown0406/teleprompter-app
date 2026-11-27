import SwiftUI
import CoreImage
import UIKit

struct CanvasPanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ForEach(CanvasFormat.allCases) { f in
                    Button { session.edit { $0.canvas = f } } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(session.project.canvas == f ? Theme.accent : .white.opacity(0.6), lineWidth: 2)
                                .frame(width: f.aspect >= 1 ? 44 : 44 * f.aspect, height: f.aspect >= 1 ? 44 / f.aspect : 44)
                                .frame(width: 48, height: 48)
                            Text(f.shortLabel).font(.caption.bold())
                        }
                        .foregroundStyle(session.project.canvas == f ? Theme.accent : .white)
                    }
                }
            }
            Text(session.project.canvas.label).font(.footnote).foregroundStyle(Theme.textDim)
            Text("Pinch and drag the video in the preview to reframe a selected clip.")
                .font(.caption).foregroundStyle(Theme.textDim)
        }
        .padding()
    }
}

struct BackgroundPanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shows when a clip doesn't fill the canvas (Fit, or zoomed out).").font(.caption).foregroundStyle(Theme.textDim)
            HStack {
                Chip(selected: session.project.background == .blur, action: { session.edit { $0.background = .blur } }) {
                    Label("Blur", systemImage: "drop.halffull")
                }
                Spacer()
            }
            Swatches(color: Binding(
                get: { if case .color(let c) = session.project.background { return c }; return RGBA(r: -1, g: -1, b: -1) },
                set: { c in session.edit { $0.background = .color(c) } }))
        }
        .padding()
    }
}

struct FilterPanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if let i = session.activeClipIndex {
            let clip = session.project.clips[i]
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(FilterKind.allCases) { f in
                            Button { session.editClip { $0.filter = f } } label: {
                                VStack(spacing: 4) {
                                    FilterThumb(path: clip.path, seconds: clip.trimStart + 0.3, filter: f)
                                        .frame(width: 58, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(clip.filter == f ? Theme.accent : .clear, lineWidth: 2.5))
                                    Text(f.label).font(.system(size: 10, weight: .medium))
                                }
                            }
                            .foregroundStyle(clip.filter == f ? Theme.accent : .white)
                        }
                    }
                    .padding(.horizontal)
                }
                if clip.filter != .none {
                    SliderRow(title: "Strength", value: session.clipBinding(\.filterAmount, 1, key: "filterAmount"), range: 0...1,
                              format: { "\(Int($0 * 100))%" }).padding(.horizontal)
                }
                Button("Apply to all clips") { session.applyToAllClips(\.filter); session.applyToAllClips(\.filterAmount) }
                    .font(.caption.bold())
            }
            .padding(.vertical, 8)
        } else { NoClipHint() }
    }
}

/// Small preview of a filter on the clip's first frame.
struct FilterThumb: View {
    let path: String
    let seconds: Double
    let filter: FilterKind
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.panelRaised
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .task(id: "\(path)\(filter.rawValue)") {
            guard let base = await ThumbnailCache.shared.image(path: path, at: seconds),
                  let cg = base.cgImage else { return }
            let ci = CIImage(cgImage: cg)
            let out = Filters.apply(filter, amount: 1, adjust: Adjustments(), to: ci)
            if let rendered = CanvasCompositor.ciContext.createCGImage(out, from: ci.extent) {
                image = UIImage(cgImage: rendered)
            }
        }
    }
}

struct AdjustPanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if session.activeClipIndex != nil {
            ScrollView {
                VStack(spacing: 6) {
                    SliderRow(title: "Brightness", value: session.clipBinding(\.adjust.brightness, 0, key: "br"), range: -0.4...0.4, onReset: 0)
                    SliderRow(title: "Contrast", value: session.clipBinding(\.adjust.contrast, 1, key: "co"), range: 0.6...1.6, onReset: 1)
                    SliderRow(title: "Saturation", value: session.clipBinding(\.adjust.saturation, 1, key: "sa"), range: 0...2, onReset: 1)
                    SliderRow(title: "Warmth", value: session.clipBinding(\.adjust.warmth, 0, key: "wa"), range: -1...1, onReset: 0)
                    SliderRow(title: "Vignette", value: session.clipBinding(\.adjust.vignette, 0, key: "vi"), range: 0...1, onReset: 0)
                    SliderRow(title: "Sharpen", value: session.clipBinding(\.adjust.sharpen, 0, key: "sh"), range: 0...1, onReset: 0)
                    HStack {
                        Button("Reset") { session.editClip { $0.adjust = Adjustments() } }
                        Spacer()
                        Button("Apply to all clips") { session.applyToAllClips(\.adjust) }
                    }
                    .font(.caption.bold())
                    .padding(.top, 4)
                }
                .padding(.horizontal)
            }
        } else { NoClipHint() }
    }
}

struct TrimPanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if let i = session.activeClipIndex {
            let clip = session.project.clips[i]
            VStack(spacing: 12) {
                RangeTrimmer(clip: clip) { s, e in
                    session.editClip("trim") { $0.trimStart = s; $0.trimEnd = e }
                    session.seek(session.project.clipStarts[i])
                }
                .frame(height: 64)
                .padding(.horizontal)
                Text("\(clip.trimStart.timecode) to \(clip.effectiveTrimEnd.timecode)  ·  \(clip.trimmedDuration.timecode) kept")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                Text("Drag the handles. Use Split for cutting out the middle.").font(.caption2).foregroundStyle(Theme.textDim)
            }
            .padding(.vertical)
        } else { NoClipHint() }
    }
}

/// Filmstrip of the whole source with two handles.
struct RangeTrimmer: View {
    let clip: ClipItem
    let onChange: (Double, Double) -> Void
    @State private var startAtDrag: Double?

    var body: some View {
        GeometryReader { geo in
            let total = max(clip.sourceDuration, 0.1)
            let w = geo.size.width
            let sx: CGFloat = CGFloat(clip.trimStart / total) * w
            let ex: CGFloat = CGFloat(clip.effectiveTrimEnd / total) * w
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { k in
                        ThumbnailImage(path: clip.path, seconds: (Double(k) + 0.5) / 10 * total)
                            .frame(width: w / 10, height: geo.size.height)
                    }
                }
                Rectangle().fill(.black.opacity(0.6)).frame(width: sx)
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, w - ex)).offset(x: ex)
                RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 3)
                    .frame(width: max(0, ex - sx)).offset(x: sx)
                handle.offset(x: sx - 8)
                    .gesture(DragGesture().onChanged { v in
                        if startAtDrag == nil { startAtDrag = clip.trimStart }
                        let s = min(max(0, startAtDrag! + Double(v.translation.width / w) * total), clip.effectiveTrimEnd - 0.3)
                        onChange(s, clip.effectiveTrimEnd)
                    }.onEnded { _ in startAtDrag = nil })
                handle.offset(x: ex - 8)
                    .gesture(DragGesture().onChanged { v in
                        if startAtDrag == nil { startAtDrag = clip.effectiveTrimEnd }
                        let e = max(min(total, startAtDrag! + Double(v.translation.width / w) * total), clip.trimStart + 0.3)
                        onChange(clip.trimStart, e)
                    }.onEnded { _ in startAtDrag = nil })
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: 16)
            .overlay(Capsule().fill(.black).frame(width: 3, height: 18))
            .contentShape(Rectangle().inset(by: -12))
    }
}

struct SpeedPanel: View {
    @ObservedObject var session: EditorSession
    private let presets: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    var body: some View {
        if session.activeClipIndex != nil {
            let speed = session.clipBinding(\.speed, 1, key: "speed")
            VStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(presets, id: \.self) { v in
                            Chip(selected: abs(speed.wrappedValue - v) < 0.001, action: { speed.wrappedValue = v }) {
                                Text(String(format: "%gx", v))
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                // Log scale slider from 0.1x to 8x.
                SliderRow(title: "Custom", value: Binding(get: { log2(speed.wrappedValue) }, set: { speed.wrappedValue = (pow(2, $0) * 100).rounded() / 100 }),
                          range: log2(0.1)...log2(8), format: { String(format: "%.2fx", pow(2, $0)) })
                    .padding(.horizontal)
                Text("Voice pitch is kept natural at any speed.").font(.caption2).foregroundStyle(Theme.textDim)
            }
            .padding(.vertical)
        } else { NoClipHint() }
    }
}

struct ClipVolumePanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if session.activeClipIndex != nil {
            let vol = session.clipBinding(\.volume, 1, key: "vol")
            VStack(spacing: 14) {
                SliderRow(title: "Volume", value: Binding(get: { Double(vol.wrappedValue) }, set: { vol.wrappedValue = Float($0) }),
                          range: 0...1, format: { "\(Int($0 * 100))%" })
                HStack {
                    Button(vol.wrappedValue == 0 ? "Unmute" : "Mute") { vol.wrappedValue = vol.wrappedValue == 0 ? 1 : 0 }
                    Spacer()
                    Button("Apply to all clips") { session.applyToAllClips(\.volume) }
                }
                .font(.caption.bold())
            }
            .padding()
        } else { NoClipHint() }
    }
}

struct FramingPanel: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if session.activeClipIndex != nil {
            VStack(spacing: 12) {
                Picker("Fit", selection: session.clipBinding(\.fit, .fill, key: "fit")) {
                    Text("Fill canvas").tag(ClipFit.fill)
                    Text("Fit whole video").tag(ClipFit.fit)
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Zoom", value: session.clipBinding(\.zoom, 1, key: "zoom"), range: 0.3...4, format: { String(format: "%.2fx", $0) }, onReset: 1)
                HStack(spacing: 22) {
                    Button { session.editClip { $0.rotation = ($0.rotation + 1) % 4 } } label: { Label("Rotate", systemImage: "rotate.right") }
                    Button { session.editClip { $0.mirrored.toggle() } } label: { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Button { session.editClip { $0.offset = .zero; $0.zoom = 1 } } label: { Label("Center", systemImage: "scope") }
                }
                .font(.caption.bold())
            }
            .padding()
        } else { NoClipHint() }
    }
}

struct TransitionPanel: View {
    @ObservedObject var session: EditorSession
    let index: Int
    var body: some View {
        if index < session.project.clips.count - 1 {
            let clip = session.project.clips[index]
            VStack(spacing: 12) {
                Text("Between clip \(index + 1) and \(index + 2)").font(.caption).foregroundStyle(Theme.textDim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(TransitionKind.allCases) { k in
                            Chip(selected: clip.transitionOut == k, action: { session.edit { $0.clips[index].transitionOut = k } }) {
                                Label(k.label, systemImage: k.symbol)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                if clip.transitionOut != .none {
                    SliderRow(title: "Length", value: Binding(get: { clip.transitionDuration },
                                                              set: { v in session.edit("tdur") { $0.clips[index].transitionDuration = v } }),
                              range: 0.2...1.5, format: { String(format: "%.1fs", $0) })
                        .padding(.horizontal)
                }
                Button("Apply to all cuts") {
                    session.edit { p in
                        for j in p.clips.indices {
                            p.clips[j].transitionOut = clip.transitionOut
                            p.clips[j].transitionDuration = clip.transitionDuration
                        }
                    }
                }
                .font(.caption.bold())
            }
            .padding(.vertical)
        } else {
            Text("Transitions go between two clips. Tap a square between clips on the timeline.")
                .font(.footnote).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding()
        }
    }
}
