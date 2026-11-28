import SwiftUI

/// Long video to short clips: pick the best moments, then make a vertical, captioned project for each.
struct ClipFinderView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var ai = AIClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var length: ClipFinder.Length = .standard
    @State private var count = 5
    @State private var options = ClipFinder.MakeOptions()
    @State private var moments: [ClipFinder.Moment] = []
    @State private var searched = false
    @State private var working: String?
    @State private var progress = 0.0
    @State private var note: String?
    @State private var made: Int?
    @State private var showAISettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let working {
                        ProgressView(value: progress) { Text(working).font(.caption) }
                    } else if let made {
                        doneCard(made)
                    } else if !searched {
                        setup
                    } else {
                        results
                    }
                    if let note { Text(note).font(.caption).foregroundStyle(Theme.textDim) }
                }
                .padding(16)
            }
            .background(Theme.panel)
            .foregroundStyle(.white)
            .navigationTitle("Make short clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { session.pause(); dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAISettings) { AISettingsView() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finds the strongest moments in this video and turns each into its own vertical clip with captions, ready to post.")
                .font(.footnote).foregroundStyle(Theme.textDim)
            Text("Clip length").font(.caption.bold())
            Picker("Length", selection: $length) {
                ForEach(ClipFinder.Length.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper("Up to \(count) clips", value: $count, in: 1...10).font(.caption)
            Toggle("Hook title on screen for 3 s", isOn: $options.titleOnScreen).font(.caption)
            Toggle("Close up pauses and \"um\"s", isOn: $options.tighten).font(.caption)
            Toggle("Add to the posting calendar (one a day)", isOn: $options.addToCalendar).font(.caption)
            Button { find() } label: { accentLabel("Find best moments") }
                .disabled(session.project.clips.isEmpty)
            if ai.isConfigured {
                Text("Your AI key picks the moments from what you said. Nothing else leaves your iPhone.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
            } else {
                HStack {
                    Text("Picked on your iPhone. Add an AI key for smarter picks and titles.")
                        .font(.caption2).foregroundStyle(Theme.textDim)
                    Button("Add key") { showAISettings = true }.font(.caption2.bold())
                }
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            if moments.isEmpty {
                Text("No moments found. Try another clip length.").font(.footnote)
            } else {
                let on = moments.filter(\.enabled).count
                HStack {
                    Button { make() } label: { accentLabel("Make \(on) clip\(on == 1 ? "" : "s")") }.disabled(on == 0)
                    Spacer()
                }
                Text("Tap play to hear a moment. Edit any title, untick ones you don't want.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
                ForEach($moments) { $m in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Title", text: $m.title).font(.subheadline.bold())
                            Toggle("", isOn: $m.enabled).labelsHidden()
                        }
                        HStack(spacing: 8) {
                            Button { preview(m) } label: { Image(systemName: "play.circle.fill").font(.title3) }
                                .accessibilityLabel("Play this moment")
                            Text("\(m.start.timecode) to \(m.end.timecode) · \(Int(m.length.rounded())) s")
                                .font(.caption.monospacedDigit())
                        }
                        if !m.why.isEmpty { Text(m.why).font(.caption2).foregroundStyle(Theme.accent) }
                        Text(m.text).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(3)
                    }
                    .padding(12)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Button("Search again") { searched = false; moments = []; note = nil }.font(.caption.bold())
        }
    }

    private func doneCard(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Made \(n) clip\(n == 1 ? "" : "s")", systemImage: "checkmark.circle.fill").font(.headline)
            Text("They're in the Edit tab under In progress, each with captions and your face kept in frame."
                 + (options.addToCalendar ? " They're also on the posting calendar, one a day from tomorrow." : ""))
                .font(.footnote).foregroundStyle(Theme.textDim)
            Button("Make more") { made = nil; searched = false; moments = [] }.font(.caption.bold())
        }
    }

    private func find() {
        session.pause()
        working = "Listening…"
        progress = 0
        note = nil
        let len = length, n = count
        Task {
            do {
                try await session.ensureWords { s, p in working = s; progress = p * 0.8 }
            } catch {
                note = "Couldn't hear the speech: \(error.localizedDescription)"
                working = nil
                return
            }
            working = ai.isConfigured ? "Picking the best moments with AI…" : "Picking the best moments…"
            progress = 0.85
            let result = await ClipFinder.find(in: session.project, length: len, count: n)
            moments = result.moments
            if let msg = result.note { note = msg }
            searched = true
            working = nil
        }
    }

    private func preview(_ m: ClipFinder.Moment) {
        session.pause()
        session.seek(m.start)
        session.togglePlay()
    }

    private func make() {
        session.pause()
        let chosen = moments.filter(\.enabled)
        let opts = options
        working = "Making clips…"
        progress = 0
        Task {
            // Landscape footage needs to know where the face is to crop to vertical.
            if session.project.canvas != .vertical && session.needsFaceAnalysis {
                working = "Finding your face for the vertical crop…"
                try? await session.analyzeFaces { p in progress = p * 0.5 }
            }
            let source = session.project
            for (k, m) in chosen.enumerated() {
                working = "Making clip \(k + 1) of \(chosen.count)…"
                progress = 0.5 + 0.5 * Double(k) / Double(chosen.count)
                let p = await ClipFinder.makeProject(m, from: source, options: opts)
                ProjectStore.shared.save(p)
                if opts.addToCalendar { ClipFinder.schedule(p, dayOffset: k) }
            }
            made = chosen.count
            working = nil
        }
    }
}
