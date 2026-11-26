import Foundation
import AVFoundation
import Combine
import UIKit

/// What is selected on the timeline.
enum Selection: Equatable {
    case none
    case clip(UUID)
    case text(UUID)
    case audio(UUID)
}

/// View model for one open project: owns the player, undo history and editing commands.
@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var project: EditProject
    @Published var selection: Selection = .none
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var isLoading = true
    @Published var message: String?

    let player = AVPlayer()
    private var undoStack: [EditProject] = []
    private var redoStack: [EditProject] = []
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var lastCoalesceKey: String?
    private var lastCoalesceDate = Date.distantPast
    private var built: BuiltComposition?
    private var builtKey: [AnyHashable] = []

    init(project: EditProject) {
        self.project = project
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = t.seconds
                if s.isFinite { self.currentTime = s }
                self.isPlaying = self.player.rate != 0
            }
        }
        Task { await loadDurations() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: Editing core

    /// Applies a change with undo. Pass `coalesce` for slider drags so one drag is one undo step.
    func edit(_ coalesce: String? = nil, _ change: (inout EditProject) -> Void) {
        var next = project
        change(&next)
        guard next != project else { return }
        let now = Date()
        let merge = coalesce != nil && coalesce == lastCoalesceKey && now.timeIntervalSince(lastCoalesceDate) < 1.0
        if !merge {
            undoStack.append(project)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        lastCoalesceKey = coalesce
        lastCoalesceDate = now
        redoStack.removeAll()
        project = clamp(next)
        afterChange()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        project = prev
        lastCoalesceKey = nil
        afterChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        lastCoalesceKey = nil
        afterChange()
    }

    private func afterChange() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if case .clip(let id) = selection, !project.clips.contains(where: { $0.id == id }) { selection = .none }
        if case .text(let id) = selection, !project.texts.contains(where: { $0.id == id }) { selection = .none }
        if case .audio(let id) = selection, !project.audio.contains(where: { $0.id == id }) { selection = .none }
        scheduleSave()
        if let built, CompositionBuilder.structuralKey(project) == builtKey {
            applyStyleChange(built)
        } else {
            scheduleRebuild()
        }
    }

    private var saveTask: Task<Void, Never>?
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            ProjectStore.shared.save(self.project)
        }
    }

    /// Saves right away (closing the editor).
    func flush() {
        saveTask?.cancel()
        ProjectStore.shared.save(project)
    }

    /// Filters, framing and text don't change timing: update the shared render plan and redraw.
    private func applyStyleChange(_ built: BuiltComposition) {
        built.plan.project = project
        guard let item = player.currentItem,
              let copy = built.videoComposition.mutableCopy() as? AVMutableVideoComposition else { return }
        item.videoComposition = copy
    }

    /// Keeps overlays inside the timeline after clips get shorter.
    private func clamp(_ p: EditProject) -> EditProject {
        var p = p
        let d = p.duration
        p.texts = p.texts.compactMap { t in
            var t = t
            if t.start >= d && d > 0 { return nil }
            t.end = min(max(t.end, t.start + 0.2), max(d, 0.2))
            return t
        }
        for i in p.audio.indices {
            p.audio[i].duration = max(0.2, min(p.audio[i].duration, max(0.2, d - p.audio[i].start)))
        }
        return p
    }

    // MARK: Player

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        let snapshot = project
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.rebuild(snapshot)
        }
    }

    private func rebuild(_ snapshot: EditProject) async {
        guard !snapshot.clips.isEmpty else {
            built = nil
            player.replaceCurrentItem(with: nil)
            return
        }
        do {
            let built = try await CompositionBuilder.build(snapshot, renderScale: 0.5)
            guard !Task.isCancelled else { return }
            self.built = built
            self.builtKey = CompositionBuilder.structuralKey(snapshot)
            if CompositionBuilder.structuralKey(project) == builtKey {
                built.plan.project = project  // pick up style edits made while building
            }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            let resume = currentTime
            let wasPlaying = isPlaying
            player.replaceCurrentItem(with: item)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPlaying = false }
            }
            await player.seek(to: min(resume, snapshot.duration).cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch {
            message = "Could not build preview: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= project.duration - 0.05 { seek(0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(_ t: Double, precise: Bool = true) {
        let clamped = min(max(0, t), project.duration)
        currentTime = clamped
        let tol: CMTime = precise ? .zero : CMTime(value: 1, timescale: 10)
        player.seek(to: clamped.cmTime, toleranceBefore: tol, toleranceAfter: tol)
    }

    func pause() { player.pause(); isPlaying = false }

    // MARK: Loading

    private func loadDurations() async {
        var p = project
        for i in p.clips.indices where p.clips[i].sourceDuration == 0 {
            let asset = AVURLAsset(url: p.clips[i].url)
            if let d = try? await asset.load(.duration).seconds, d.isFinite { p.clips[i].sourceDuration = d }
        }
        project = p
        ProjectStore.shared.save(p)
        isLoading = false
        scheduleRebuild()
    }

    func addClips(_ urls: [URL], at index: Int? = nil) async {
        var items: [ClipItem] = []
        for url in urls {
            var c = ClipItem(url: url)
            let asset = AVURLAsset(url: url)
            c.sourceDuration = (try? await asset.load(.duration).seconds) ?? 0
            if c.sourceDuration > 0 { items.append(c) }
        }
        guard !items.isEmpty else { return }
        edit { p in
            let at = min(index ?? p.clips.count, p.clips.count)
            p.clips.insert(contentsOf: items, at: at)
        }
    }

    // MARK: Selection helpers

    var selectedClipIndex: Int? {
        if case .clip(let id) = selection { return project.clips.firstIndex { $0.id == id } }
        return nil
    }
    var selectedTextIndex: Int? {
        if case .text(let id) = selection { return project.texts.firstIndex { $0.id == id } }
        return nil
    }
    var selectedAudioIndex: Int? {
        if case .audio(let id) = selection { return project.audio.firstIndex { $0.id == id } }
        return nil
    }

    /// Clip under the playhead, or the selected one.
    var activeClipIndex: Int? { selectedClipIndex ?? project.clipIndex(at: currentTime) }

    func editClip(_ coalesce: String? = nil, _ change: (inout ClipItem) -> Void) {
        guard let i = activeClipIndex else { return }
        edit(coalesce) { change(&$0.clips[i]) }
    }

    func editSelectedText(_ coalesce: String? = nil, _ change: (inout TextItem) -> Void) {
        guard let i = selectedTextIndex else { return }
        edit(coalesce) { change(&$0.texts[i]) }
    }

    func editSelectedAudio(_ coalesce: String? = nil, _ change: (inout AudioItem) -> Void) {
        guard let i = selectedAudioIndex else { return }
        edit(coalesce) { change(&$0.audio[i]) }
    }

    // MARK: Clip commands

    /// Splits the clip under the playhead into two at the playhead.
    func splitAtPlayhead() {
        guard let i = project.clipIndex(at: currentTime) else { return }
        let clip = project.clips[i]
        let local = (currentTime - project.clipStarts[i]) * clip.speed
        let cut = clip.trimStart + local
        guard cut > clip.trimStart + 0.1, cut < clip.effectiveTrimEnd - 0.1 else {
            message = "Move the playhead inside a clip to split it."
            return
        }
        edit { p in
            var left = clip
            var right = clip
            left.trimEnd = cut
            left.transitionOut = .none
            right.id = UUID()
            right.trimStart = cut
            p.clips[i] = left
            p.clips.insert(right, at: i + 1)
        }
        selection = .clip(project.clips[i + 1].id)
    }

    func deleteSelection() {
        switch selection {
        case .clip(let id): edit { $0.clips.removeAll { $0.id == id } }
        case .text(let id): edit { $0.texts.removeAll { $0.id == id } }
        case .audio(let id): edit { $0.audio.removeAll { $0.id == id } }
        case .none: return
        }
        selection = .none
    }

    func duplicateSelection() {
        switch selection {
        case .clip:
            guard let i = selectedClipIndex else { return }
            var copy = project.clips[i]
            copy.id = UUID()
            edit { $0.clips.insert(copy, at: i + 1) }
            selection = .clip(copy.id)
        case .text:
            guard let i = selectedTextIndex else { return }
            var copy = project.texts[i]
            copy.id = UUID()
            copy.center.y = min(0.95, copy.center.y + 0.06)
            edit { $0.texts.append(copy) }
            selection = .text(copy.id)
        case .audio:
            guard let i = selectedAudioIndex else { return }
            var copy = project.audio[i]
            copy.id = UUID()
            copy.start = project.audio[i].end
            edit { $0.audio.append(copy) }
            selection = .audio(copy.id)
        case .none: break
        }
    }

    func moveClip(from: Int, to: Int) {
        guard from != to, project.clips.indices.contains(from) else { return }
        edit { p in
            let c = p.clips.remove(at: from)
            p.clips.insert(c, at: min(max(0, to), p.clips.count))
        }
    }

    /// Replaces a clip's footage by reversing it to a new file.
    func reverseActiveClip() async {
        guard let i = activeClipIndex else { return }
        let clip = project.clips[i]
        message = "Reversing clip…"
        do {
            let out = try await ClipReverser.reverse(url: clip.url, start: clip.trimStart, end: clip.effectiveTrimEnd)
            let d = (try? await AVURLAsset(url: out).load(.duration).seconds) ?? clip.trimmedDuration
            edit { p in
                guard let j = p.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                p.clips[j].path = MediaLibrary.relativePath(out)
                p.clips[j].sourceDuration = d
                p.clips[j].trimStart = 0
                p.clips[j].trimEnd = 0
                p.clips[j].volume = 0   // reversed audio sounds wrong; mute by default
            }
            message = nil
        } catch {
            message = "Could not reverse: \(error.localizedDescription)"
        }
    }

    // MARK: Text commands

    func addText(_ string: String = "Your text", caption: Bool = false) {
        let start = min(currentTime, max(0, project.duration - 0.5))
        let item = TextItem(text: string, start: start, end: min(project.duration, start + 3), isCaption: caption)
        edit { $0.texts.append(item) }
        selection = .text(item.id)
    }

    func replaceCaptions(_ captions: [TextItem]) {
        edit { p in
            p.texts.removeAll { $0.isCaption }
            p.texts.append(contentsOf: captions)
        }
    }

    // MARK: Audio commands

    func addAudio(url: URL, kind: AudioItem.Kind, name: String, at start: Double? = nil) async {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration).seconds) ?? 0
        guard d > 0 else { message = "That file has no audio we can use."; return }
        let begin = start ?? (kind == .music ? 0 : currentTime)
        let room = max(0.2, project.duration - begin)
        var item = AudioItem(kind: kind, name: name, path: MediaLibrary.relativePath(url),
                             sourceDuration: d, start: begin, duration: min(d, room))
        if kind == .music {
            item.volume = 0.5
            item.fadeIn = 0.5
            item.fadeOut = 1.5
            item.loop = d < room
            if item.loop { item.duration = room }
        } else {
            item.volume = 1
        }
        edit { $0.audio.append(item) }
        selection = .audio(item.id)
    }
}
