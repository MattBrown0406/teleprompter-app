import SwiftUI

extension EditorSession {
    /// Binding into the active clip (selected, or under the playhead). Slider drags merge into one undo step.
    func clipBinding<T>(_ kp: WritableKeyPath<ClipItem, T>, _ fallback: T, key: String) -> Binding<T> {
        Binding(
            get: { self.activeClipIndex.map { self.project.clips[$0][keyPath: kp] } ?? fallback },
            set: { v in self.editClip(key) { $0[keyPath: kp] = v } }
        )
    }

    func textBinding<T>(_ kp: WritableKeyPath<TextItem, T>, _ fallback: T, key: String) -> Binding<T> {
        Binding(
            get: { self.selectedTextIndex.map { self.project.texts[$0][keyPath: kp] } ?? fallback },
            set: { v in self.editSelectedText(key) { $0[keyPath: kp] = v } }
        )
    }

    func audioBinding<T>(_ kp: WritableKeyPath<AudioItem, T>, _ fallback: T, key: String) -> Binding<T> {
        Binding(
            get: { self.selectedAudioIndex.map { self.project.audio[$0][keyPath: kp] } ?? fallback },
            set: { v in self.editSelectedAudio(key) { $0[keyPath: kp] = v } }
        )
    }

    /// Copies one clip setting to every clip.
    func applyToAllClips<T>(_ kp: WritableKeyPath<ClipItem, T>) {
        guard let i = activeClipIndex else { return }
        let v = project.clips[i][keyPath: kp]
        edit { p in for j in p.clips.indices { p.clips[j][keyPath: kp] = v } }
        message = "Applied to all clips"
    }
}

struct Chip<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(selected ? Theme.accent : Theme.panelRaised, in: Capsule())
                .foregroundStyle(selected ? .black : .white)
        }
    }
}

struct Swatches: View {
    @Binding var color: RGBA
    var body: some View {
        HStack(spacing: 10) {
            ForEach(RGBA.palette, id: \.self) { c in
                Circle()
                    .fill(Color(red: c.r, green: c.g, blue: c.b))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white, lineWidth: color.r == c.r && color.g == c.g && color.b == c.b ? 2.5 : 0.5))
                    .onTapGesture { color = RGBA(r: c.r, g: c.g, b: c.b, a: color.a) }
            }
        }
    }
}

struct NoClipHint: View {
    var body: some View {
        Text("Add a clip first.").font(.footnote).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
