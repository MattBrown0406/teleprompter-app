import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: B-roll and cutaways

/// Where a picked photo or video should go.
private struct OverlayTarget: Equatable {
    var start: Double
    var length: Double?
    var note: String?
}

/// Imports a Photos pick as a B-roll file: videos are copied, photos saved as an upright JPEG.
@MainActor
private func importOverlay(_ item: PhotosPickerItem, into session: EditorSession, target: OverlayTarget?) async {
    session.message = "Adding B-roll…"
    let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
    if isMovie, let movie = try? await item.loadTransferable(type: PickedMovie.self) {
        await session.addOverlay(url: movie.url, kind: .video, at: target?.start, length: target?.length, note: target?.note)
        session.message = nil
        return
    }
    if let data = try? await item.loadTransferable(type: Data.self),
       let url = await Task.detached(operation: { OverlayRenderer.savePhoto(data) }).value {
        await session.addOverlay(url: url, kind: .photo, at: target?.start, length: target?.length, note: target?.note)
        session.message = nil
        return
    }
    session.message = "That item couldn't be added."
}

struct BRollPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var ai = AIClient.shared
    @State private var pick: PhotosPickerItem?
    @State private var showPicker = false
    @State private var target: OverlayTarget?
    @State private var suggestions: [CutawayPlanner.Suggestion] = []
    @State private var glances: [GazeCheck.Span] = []
    @State private var checkedGaze = false
    @State private var working: String?
    @State private var progress = 0.0
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { target = nil; showPicker = true } label: { accentLabel("Add at playhead") }
                    Button(working == "suggest" ? "Thinking…" : "Suggest cutaways") { suggest() }
                        .font(.caption.bold())
                        .disabled(working != nil)
                    Button(working == "gaze" ? "Checking…" : "Check eye contact") { checkGaze() }
                        .font(.caption.bold())
                        .disabled(working != nil)
                }
                if working != nil, progress > 0 { ProgressView(value: progress) }
                if !ai.isConfigured {
                    HStack {
                        Text("Cutaway ideas need your Anthropic or OpenAI key.").font(.caption2).foregroundStyle(Theme.textDim)
                        Button("Add key") { showSettings = true }.font(.caption2.bold())
                    }
                }

                if checkedGaze {
                    Text(glances.isEmpty ? "No clear look-aways found." : "You look away from the lens here")
                        .font(.caption.bold())
                    ForEach(glances) { g in
                        row(time: g.start, end: g.end, text: g.reason, icon: "eye.slash") {
                            target = OverlayTarget(start: max(0, g.start - 0.2), length: min(6, max(1.5, g.duration + 0.4)),
                                                   note: "Covers a look-away")
                            showPicker = true
                        }
                    }
                }

                if !suggestions.isEmpty {
                    Text("Cutaway ideas").font(.caption.bold())
                    ForEach(suggestions) { s in
                        row(time: s.start, end: s.end, text: s.idea, icon: s.coversGlance ? "eye.slash" : "sparkles") {
                            target = OverlayTarget(start: s.start, length: s.end - s.start, note: s.idea)
                            showPicker = true
                        }
                    }
                }

                Text("B-roll plays over you while your voice keeps going. Use your own photos, screen recordings or clips. Check eye contact finds moments you glance away so you can cover them; it doesn't change your eyes.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .photosPicker(isPresented: $showPicker, selection: $pick, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            let t = target
            pick = nil
            Task { await importOverlay(item, into: session, target: t) }
        }
        .sheet(isPresented: $showSettings) { AISettingsView() }
    }

    private func row(time: Double, end: Double, text: String, icon: String, add: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(Theme.accent)
            Button { session.seek(time) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(time.timecode)–\(end.timecode)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textDim)
                    Text(text).font(.caption).multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Add media", action: add).font(.caption.bold())
        }
        .padding(8)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func checkGaze() {
        working = "gaze"
        progress = 0
        session.pause()
        Task {
            do {
                glances = try await GazeCheck.run(session.project) { p in progress = p }
                checkedGaze = true
            } catch {
                session.message = "Couldn't check eye contact: \(error.localizedDescription)"
            }
            working = nil
            progress = 0
        }
    }

    private func suggest() {
        guard ai.isConfigured else { showSettings = true; return }
        working = "suggest"
        progress = 0
        session.pause()
        Task {
            do {
                let lines = try await CutawayPlanner.timedLines(session.project) { p in progress = p }
                progress = 0
                suggestions = try await CutawayPlanner.suggest(session.project, lines: lines, glances: glances)
                if suggestions.isEmpty { session.message = "No cutaway ideas came back. Try again." }
            } catch {
                session.message = error.localizedDescription
            }
            working = nil
        }
    }
}

/// Settings for the selected B-roll item.
struct OverlayPanel: View {
    @ObservedObject var session: EditorSession

    var body: some View {
        if let i = session.selectedOverlayIndex {
            let o = session.project.overlayItems[i]
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Layout", selection: Binding(get: { o.layout }, set: { v in session.editSelectedOverlay { $0.layout = v } })) {
                        ForEach(OverlayItem.Layout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    let room = max(0.6, min(o.maxDuration, session.project.duration - o.start))
                    SliderRow(title: "Length", value: Binding(get: { o.duration }, set: { v in session.editSelectedOverlay("ovlen") { $0.duration = v } }),
                              range: 0.5...max(0.6, room), format: { String(format: "%.1fs", $0) })
                    if o.kind == .video, o.sourceDuration > 1 {
                        SliderRow(title: "Starts at", value: Binding(get: { o.sourceStart }, set: { v in
                            session.editSelectedOverlay("ovsrc") { $0.sourceStart = v; $0.duration = min($0.duration, $0.maxDuration) }
                        }), range: 0...max(0.1, o.sourceDuration - 0.5), format: { String(format: "%.1fs", $0) })
                    }
                    HStack {
                        Toggle("Fade", isOn: Binding(get: { o.fade }, set: { v in session.editSelectedOverlay { $0.fade = v } }))
                        if o.kind == .photo {
                            Toggle("Slow zoom", isOn: Binding(get: { o.motion }, set: { v in session.editSelectedOverlay { $0.motion = v } }))
                        }
                    }
                    .font(.caption)
                    if let note = o.note { Text(note).font(.caption2).foregroundStyle(Theme.textDim) }
                    Text("Drag the bar on the timeline to move it. Your voice keeps playing underneath.")
                        .font(.caption2).foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal)
            }
        } else {
            Text("Select B-roll on the timeline.").font(.footnote).foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Hook versions

private struct HookRef: Identifiable { let id: UUID }

struct HookPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var ai = AIClient.shared
    @State private var recording: HookRef?
    @State private var pickingFor: UUID?
    @State private var pick: PhotosPickerItem?
    @State private var showPicker = false
    @State private var writing = false
    @State private var showSettings = false

    private var span: (start: Double, end: Double)? { HookPlanner.hookSpan(session.project) }
    private var hooks: [HookVariant] { session.project.hooks ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let span {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hook A (yours): \(span.start.timecode)–\(span.end.timecode)").font(.caption.bold())
                        let line = HookPlanner.originalLine(session.project)
                        if !line.isEmpty { Text(line).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2) }
                        HStack(spacing: 14) {
                            Button("Play") { session.seek(span.start); session.togglePlay() }
                            Button("End it at the playhead") { session.setHookEnd(at: session.currentTime) }
                        }
                        .font(.caption.bold())
                    }
                } else {
                    Text("First mark where your opening line ends. Move the playhead there, or let the app find it from your script.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                    HStack(spacing: 12) {
                        Button { session.setHookEnd(at: session.currentTime) } label: { accentLabel("Hook ends here") }
                        Button("Find from script") { findFromScript() }
                            .font(.caption.bold())
                            .disabled(session.project.scriptText == nil || !session.project.texts.contains(where: \.isCaption))
                    }
                }

                Divider()

                ForEach(hooks) { v in variantRow(v) }

                HStack(spacing: 12) {
                    Button("Add a hook") { _ = session.addHookVariant() }
                        .disabled(hooks.count >= HookPlanner.maxVariants)
                    Button(writing ? "Writing…" : "Write hooks with AI") { write() }
                        .disabled(writing || hooks.filter { !$0.line.isEmpty || $0.clip != nil }.count >= HookPlanner.maxVariants)
                }
                .font(.caption.bold())
                Text("Record each line, then Export makes one video per hook with the same body, ready to test.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .fullScreenCover(item: $recording) { ref in
            HookRecorderView(line: hooks.first { $0.id == ref.id }?.line ?? "", canvas: session.project.canvas) { url in
                Task { await session.setHookTake(ref.id, url: url) }
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pick, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: pick) { _, item in
            guard let item, let id = pickingFor else { return }
            pick = nil
            Task {
                session.message = "Adding take…"
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    await session.setHookTake(id, url: movie.url)
                } else {
                    session.message = "That video couldn't be added."
                }
            }
        }
        .sheet(isPresented: $showSettings) { AISettingsView() }
    }

    private func variantRow(_ v: HookVariant) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hook \(v.name)").font(.caption.bold())
                if let c = v.clip {
                    Label(String(format: "%.1fs take", c.sourceDuration), systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(Theme.accent)
                } else {
                    Text("No take yet").font(.caption2).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button {
                    session.pause()
                    recording = HookRef(id: v.id)
                } label: { Image(systemName: "record.circle").foregroundStyle(.red) }
                    .accessibilityLabel("Record hook \(v.name)")
                Menu {
                    Button("Choose a video", systemImage: "photo.on.rectangle") { pickingFor = v.id; showPicker = true }
                    Button("Remove", systemImage: "trash", role: .destructive) { session.removeHookVariant(v.id) }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            TextField("Opening line to say", text: Binding(get: { v.line }, set: { t in session.updateHook(v.id) { $0.line = t } }),
                      axis: .vertical)
                .lineLimit(1...3)
                .font(.caption)
                .padding(8)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(8)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func findFromScript() {
        guard let t = HookPlanner.detectHookEnd(session.project) else {
            session.message = "Couldn't match the script's first sentence. Move the playhead and tap Hook ends here."
            return
        }
        session.seek(t)
        session.setHookEnd(at: t)
    }

    private func write() {
        guard ai.isConfigured else { showSettings = true; return }
        writing = true
        Task {
            do { try await session.writeHooks() } catch { session.message = error.localizedDescription }
            writing = false
        }
    }
}

// MARK: Templates

struct TemplatePanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var store = TemplateStore.shared
    @State private var name = ""
    @State private var parts = VideoTemplate.Parts()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if store.templates.isEmpty {
                    Text("Save this edit's look, captions, music and brand as a template, then put it on any new take in one tap.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
                ForEach(store.templates) { t in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.caption.bold())
                            Text(summary(t)).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            store.defaultID = store.defaultID == t.id ? nil : t.id
                        } label: {
                            Image(systemName: store.defaultID == t.id ? "star.fill" : "star")
                                .foregroundStyle(store.defaultID == t.id ? Theme.accent : Theme.textDim)
                        }
                        .accessibilityLabel(store.defaultID == t.id ? "Used for new videos" : "Use for new videos")
                        Button("Apply") { Task { await session.applyTemplate(t) } }.font(.caption.bold())
                        Menu {
                            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(t) }
                        } label: { Image(systemName: "ellipsis") }
                    }
                    .padding(8)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                }
                if store.defaultID != nil {
                    Text("The starred template goes on every new video automatically.").font(.caption2).foregroundStyle(Theme.textDim)
                }

                Divider()
                Text("Save this edit as a template").font(.caption.bold())
                TextField("Name, e.g. Tips series", text: $name)
                    .font(.caption)
                    .padding(8)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Toggle("Look", isOn: $parts.look)
                    Toggle("Captions", isOn: $parts.captions)
                    Toggle("Music", isOn: $parts.music)
                }
                .font(.caption)
                HStack {
                    Toggle("Brand", isOn: $parts.brand)
                    Toggle("On-screen text", isOn: $parts.text)
                }
                .font(.caption)
                Button { save() } label: { accentLabel("Save template") }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func save() {
        let t = VideoTemplate(name: name.trimmingCharacters(in: .whitespaces), from: session.project, parts: parts)
        store.add(t)
        name = ""
        session.message = "Saved \u{201C}\(t.name)\u{201D}. Tap the star to use it on every new video."
    }

    private func summary(_ t: VideoTemplate) -> String {
        var bits = [t.canvas.rawValue]
        if t.filter != .none { bits.append(t.filter.label) }
        if t.captions != nil { bits.append("captions") }
        if !t.music.isEmpty { bits.append("music") }
        if t.logo != nil || t.intro != nil || t.outro != nil { bits.append("brand") }
        if !t.texts.isEmpty { bits.append("text") }
        return bits.joined(separator: " · ")
    }
}
