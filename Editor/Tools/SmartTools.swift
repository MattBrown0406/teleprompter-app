import Foundation

/// Editor commands behind the smart tools (auto-cut, reframing, cleanup, captions).
extension EditorSession {
    /// Finds faces in any clip that hasn't been analysed yet. Results are cached in the project.
    func analyzeFaces(progress: @escaping @MainActor (Double) -> Void) async throws {
        let todo = project.clips.filter { $0.faces == nil && !$0.isBrandClip }
        var done = Set<String>()
        for (n, clip) in todo.enumerated() where !done.contains(clip.path) {
            done.insert(clip.path)
            let faces = try await FaceTracker.track(url: clip.url, from: 0, to: clip.sourceDuration) { p in
                progress((Double(n) + p) / Double(max(1, todo.count)))
            }
            applySilently { proj in
                for i in proj.clips.indices where proj.clips[i].path == clip.path { proj.clips[i].faces = faces }
            }
        }
        progress(1)
    }

    var needsFaceAnalysis: Bool { project.clips.contains { $0.faces == nil && !$0.isBrandClip } }

    /// Turns auto reframing on (analysing first if needed) or off.
    func setAutoReframe(_ on: Bool, progress: @escaping @MainActor (Double) -> Void) async {
        if on && needsFaceAnalysis {
            do { try await analyzeFaces(progress: progress) } catch {
                message = "Couldn't find faces: \(error.localizedDescription)"
                return
            }
            if !project.clips.contains(where: { !($0.faces ?? []).isEmpty }) {
                message = "No face found in these clips, so framing stays centred."
            }
        }
        edit { $0.autoReframe = on }
    }

    /// Changes every caption at once (one undo step per slider drag).
    func editAllCaptions(_ key: String? = nil, _ change: @escaping (inout TextItem) -> Void) {
        edit(key) { p in
            for i in p.texts.indices where p.texts[i].isCaption { change(&p.texts[i]) }
        }
    }

    var captionItems: [TextItem] { project.texts.filter(\.isCaption).sorted { $0.start < $1.start } }

    func addSubtitle(style: TextStyle, y: Double) {
        let start = min(currentTime, max(0, project.duration - 0.5))
        let next = project.texts.filter { $0.isCaption && $0.start > start + 0.1 }.map(\.start).min() ?? project.duration
        var item = TextItem(text: "Subtitle", start: start, end: min(project.duration, start + 2.5, max(start + 0.6, next)), isCaption: true)
        item.style = style
        item.center = NPoint(x: 0.5, y: y)
        item.animation = .fade
        item.look = .plain
        edit { $0.texts.append(item) }
        selection = .text(item.id)
    }
}
