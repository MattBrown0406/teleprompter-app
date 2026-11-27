import Foundation
import AVFoundation

/// Editing commands for B-roll, hook versions and templates.
extension EditorSession {
    // MARK: Templates

    /// Runs once the clip lengths are known: a default template for a new video, then its captions.
    func runPendingSetup() async {
        if let id = project.pendingTemplateID {
            if let t = TemplateStore.template(id) {
                edit { p in
                    t.apply(to: &p)
                    p.pendingTemplateID = nil
                }
                message = "Applied template \u{201C}\(t.name)\u{201D}. Tap undo to remove it."
            } else {
                applySilently { $0.pendingTemplateID = nil }
            }
        }
        guard let preset = project.pendingCaptions else { return }
        applySilently { $0.pendingCaptions = nil }
        guard !project.texts.contains(where: \.isCaption), !project.clips.isEmpty else { return }
        var opts = preset.options
        opts.script = project.scriptText
        message = "Adding captions from your template…"
        do {
            let out = try await Captioner.makeCaptions(for: project, options: opts)
            replaceCaptions(out.captions)
            applySilently { $0.transcript = out.transcript }
            message = out.captions.isEmpty ? "No speech found for captions." : "Captions added in your template's style."
        } catch {
            message = "Couldn't add captions: \(error.localizedDescription)"
        }
    }

    func applyTemplate(_ t: VideoTemplate) async {
        pause()
        edit { t.apply(to: &$0) }
        message = "Applied \u{201C}\(t.name)\u{201D}. Tap undo to go back."
        await runPendingSetup()
    }

    // MARK: B-roll

    func editSelectedOverlay(_ coalesce: String? = nil, _ change: (inout OverlayItem) -> Void) {
        guard let i = selectedOverlayIndex else { return }
        edit(coalesce) { p in
            guard var list = p.overlays, list.indices.contains(i) else { return }
            change(&list[i])
            p.overlays = list
        }
    }

    /// Puts a photo or video over the video at a time (the playhead by default).
    func addOverlay(url: URL, kind: OverlayItem.Kind, at start: Double? = nil, length: Double? = nil, note: String? = nil) async {
        let begin = min(max(0, start ?? currentTime), max(0, project.duration - 0.5))
        var item = OverlayItem(kind: kind, path: MediaLibrary.relativePath(url), start: begin, duration: length ?? 3)
        item.note = note
        if kind == .video {
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            guard d > 0.2 else { message = "That video couldn't be read."; return }
            item.sourceDuration = d
            item.duration = min(length ?? min(d, 4), d)
        }
        item.duration = max(0.5, min(item.duration, project.duration - begin))
        edit { $0.overlays = ($0.overlays ?? []) + [item] }
        selection = .overlay(item.id)
    }

    // MARK: Hook versions

    /// Marks where the opening line ends. Splits the clip there if the time falls inside one.
    func setHookEnd(at t: Double) {
        guard let i = project.clipIndex(at: t), !project.clips[i].isBrandClip else {
            message = "Move the playhead to where your opening line ends."
            return
        }
        let clip = project.clips[i]
        let cut = clip.trimStart + (t - project.clipStarts[i]) * clip.speed
        if cut >= clip.effectiveTrimEnd - 0.15 {
            edit { $0.hookEndClipID = clip.id }
        } else if cut <= clip.trimStart + 0.15 {
            guard i > 0, !project.clips[i - 1].isBrandClip else {
                message = "The hook needs at least a moment of video. Move the playhead later."
                return
            }
            let prev = project.clips[i - 1].id
            edit { $0.hookEndClipID = prev }
        } else {
            let rightID = UUID()
            edit { p in
                var left = clip, right = clip
                left.trimEnd = cut
                left.transitionOut = .none
                right.id = rightID
                right.trimStart = cut
                p.clips[i] = left
                p.clips.insert(right, at: i + 1)
                p.hookEndClipID = left.id
            }
        }
        message = "Hook marked. It ends at \(t.timecode)."
    }

    func updateHook(_ id: UUID, _ change: (inout HookVariant) -> Void) {
        edit("hook-\(id)") { p in
            guard var list = p.hooks, let i = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[i])
            p.hooks = list
        }
    }

    @discardableResult
    func addHookVariant(line: String = "") -> UUID? {
        let used = Set((project.hooks ?? []).map(\.name))
        guard let name = HookPlanner.letters.first(where: { !used.contains($0) }) else {
            message = "You can test up to \(HookPlanner.maxVariants) other hooks."
            return nil
        }
        let v = HookVariant(name: name, line: line)
        edit { $0.hooks = ($0.hooks ?? []) + [v] }
        return v.id
    }

    func removeHookVariant(_ id: UUID) {
        edit { $0.hooks?.removeAll { $0.id == id } }
    }

    /// Uses a recorded or imported take for a hook. Captions and face framing are made for it
    /// when the video has them, so the exported version matches the original.
    func setHookTake(_ id: UUID, url: URL) async {
        var clip = ClipItem(url: url)
        clip.sourceDuration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        guard clip.sourceDuration > 0.2 else { message = "That take couldn't be read."; return }
        updateHook(id) { $0.clip = clip; $0.captions = nil }
        let line = project.hooks?.first { $0.id == id }?.line ?? ""

        if project.autoReframe == true,
           let faces = try? await FaceTracker.track(url: url, from: 0, to: clip.sourceDuration) {
            clip.faces = faces
            applySilently { p in
                guard let i = p.hooks?.firstIndex(where: { $0.id == id }) else { return }
                p.hooks?[i].clip?.faces = faces
            }
        }
        guard let preset = CaptionPreset(captionsOf: project) else { return }
        message = "Captioning hook…"
        var temp = EditProject(name: "hook", canvas: project.canvas, quality: project.quality)
        temp.clips = [clip]
        var opts = preset.options
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { opts.script = line }
        do {
            let caps = try await Captioner.makeCaptions(for: temp, options: opts).captions
            applySilently { p in
                guard let i = p.hooks?.firstIndex(where: { $0.id == id }) else { return }
                p.hooks?[i].captions = caps
            }
            message = "Hook take added."
        } catch {
            message = "Take added, but captions failed: \(error.localizedDescription)"
        }
    }

    /// Finds the face in hook takes that don't have it yet, for face-centred export.
    func prepareHookFaces() async {
        for v in project.hooks ?? [] {
            guard let clip = v.clip, clip.faces == nil,
                  let faces = try? await FaceTracker.track(url: clip.url, from: 0, to: clip.sourceDuration) else { continue }
            applySilently { p in
                guard let i = p.hooks?.firstIndex(where: { $0.id == v.id }) else { return }
                p.hooks?[i].clip?.faces = faces
            }
        }
    }

    /// Asks the AI for other opening lines and fills the empty hook slots.
    func writeHooks() async throws {
        let source = PostCopy.source(project)
        let original = HookPlanner.originalLine(project)
        let free = HookPlanner.maxVariants - (project.hooks ?? []).filter { !$0.line.isEmpty || $0.clip != nil }.count
        guard free > 0 else { message = "All hook slots are used. Remove one to write more."; return }
        let reply = try await AIClient.shared.complete(
            system: """
            You write opening lines (hooks) for short talking-head videos on TikTok, Instagram Reels and Facebook. \
            Each hook is one spoken sentence of at most 15 words that makes people keep watching, and it must lead \
            naturally into the rest of the video. Use a different angle for each: a question, a bold claim, a surprising \
            number or a quick story. Reply with only the hooks, one per line, no numbering or quotes.
            """,
            prompt: "Current hook: \(original.isEmpty ? "(none)" : original)\n\nThe video:\n\(String(source.prefix(6000)))\n\nWrite \(free) new hooks.",
            maxTokens: 1000)
        let lines = reply.split(separator: "\n")
            .map { String($0).replacingOccurrences(of: #"^\s*(?:[-•*]|\d+[.)])?\s*["'“]?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”").union(.whitespaces)) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw AIError.empty }
        var queue = lines.prefix(free).map { $0 }
        // Fill blank variants first, then add new ones.
        for v in project.hooks ?? [] where v.line.isEmpty && v.clip == nil && !queue.isEmpty {
            let line = queue.removeFirst()
            updateHook(v.id) { $0.line = line }
        }
        for line in queue { addHookVariant(line: line) }
    }
}
