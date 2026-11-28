import SwiftUI

/// One tap: clean, even voice and a matched colour and light fix on every clip.
struct PolishPanel: View {
    @ObservedObject var session: EditorSession
    @State private var sound = true
    @State private var look = true
    @State private var audioStrength: AudioCleaner.Strength = .standard
    @State private var lookStrength: LookPolish.Strength = .natural
    @State private var working = false
    @State private var status = ""
    @State private var progress = 0.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Removes background noise, evens out your voice and gives every clip the same bright, clean look, so all your videos sound and look alike.")
                    .font(.caption).foregroundStyle(Theme.textDim)
                HStack {
                    Toggle("Sound", isOn: $sound)
                    Picker("", selection: $audioStrength) {
                        ForEach(AudioCleaner.Strength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).disabled(!sound)
                }
                .font(.caption)
                HStack {
                    Toggle("Look", isOn: $look)
                    Picker("", selection: $lookStrength) {
                        ForEach(LookPolish.Strength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).disabled(!look)
                }
                .font(.caption)
                if working {
                    ProgressView(value: progress) { Text(status).font(.caption) }
                } else {
                    HStack(spacing: 16) {
                        Button { run() } label: { accentLabel("Polish video") }
                            .disabled(session.project.clips.isEmpty || (!sound && !look))
                        Button("Remove polish") {
                            session.edit { p in
                                for i in p.clips.indices where !p.clips[i].isBrandClip {
                                    p.clips[i].cleanAudioPath = nil
                                    p.clips[i].adjust = Adjustments()
                                }
                            }
                        }
                        .font(.caption.bold())
                    }
                }
                Text("Your filter stays. The fix sets Adjust on each clip, so you can fine-tune it there or tap undo.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func run() {
        working = true
        progress = 0
        session.pause()
        let clips = session.project.clips.filter { !$0.isBrandClip }
        // One measurement and one cleaned sound file per recording, shared by its pieces.
        var firstByPath: [String: ClipItem] = [:]
        for c in clips where firstByPath[c.path] == nil { firstByPath[c.path] = c }
        let paths = Array(firstByPath.keys)
        let lookup = firstByPath
        let doSound = sound, doLook = look, aLevel = audioStrength, lLevel = lookStrength
        let steps = Double(paths.count * ((doSound ? 1 : 0) + (doLook ? 1 : 0)))
        Task {
            var cleaned: [String: String] = [:]
            var stats: [String: LookPolish.Stats] = [:]
            var done = 0.0
            var problems: [String] = []
            for path in paths {
                if doLook, let clip = lookup[path] {
                    status = "Checking light and colour…"
                    if let s = try? await LookPolish.measure(clip) { stats[path] = s }
                    done += 1
                    progress = done / max(1, steps)
                }
                if doSound {
                    status = "Cleaning sound…"
                    do {
                        let base = done
                        let out = try await AudioCleaner.clean(MediaLibrary.resolve(path), strength: aLevel) { p in
                            progress = (base + p) / max(1, steps)
                        }
                        cleaned[path] = MediaLibrary.relativePath(out)
                    } catch {
                        problems.append(error.localizedDescription)
                    }
                    done += 1
                    progress = done / max(1, steps)
                }
            }
            session.edit { p in
                for i in p.clips.indices where !p.clips[i].isBrandClip {
                    let path = p.clips[i].path
                    if let r = cleaned[path] { p.clips[i].cleanAudioPath = r }
                    if let s = stats[path] {
                        p.clips[i].adjust = LookPolish.adjustments(for: s, strength: lLevel, keeping: p.clips[i].adjust)
                    }
                }
            }
            var note: [String] = []
            if !cleaned.isEmpty { note.append("voice cleaned") }
            if !stats.isEmpty { note.append("look matched on \(stats.count == 1 ? "the clip" : "\(stats.count) recordings")") }
            if note.isEmpty {
                session.message = problems.first ?? "Couldn't polish these clips."
            } else {
                session.message = "Polished: " + note.joined(separator: ", ") + ". Tap undo to compare."
            }
            working = false
        }
    }
}
