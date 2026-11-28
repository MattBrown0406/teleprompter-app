import SwiftUI
import Combine

/// Edit by text: the take as words. Strike out words or pauses, and the video is cut to match.
struct TranscriptEditorView: View {
    // Not observed: the playhead moves 30 times a second and redrawing every word that often is slow.
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var tokens: [Transcript.Token] = []
    @State private var struck = Set<String>()
    @State private var anchor: String?
    @State private var selectStretch = false
    @State private var working: String?
    @State private var progress = 0.0
    @State private var problem: String?
    @State private var options = AutoCut.Options()
    @State private var note: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let working {
                    Spacer()
                    ProgressView(value: progress) { Text(working).font(.caption) }.padding(32)
                    Spacer()
                } else if tokens.isEmpty {
                    Spacer()
                    Text(problem ?? "No speech found in these clips.")
                        .font(.footnote).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding(32)
                    Spacer()
                } else {
                    controls
                    Divider().overlay(Color.white.opacity(0.08))
                    ScrollView {
                        FlowLayout(spacing: 4, lineSpacing: 6) {
                            ForEach(tokens) { t in
                                TokenView(token: t, struck: struck.contains(t.id), anchor: anchor == t.id)
                                    .onTapGesture { tap(t) }
                                    .onLongPressGesture { play(from: t) }
                            }
                        }
                        .padding(16)
                    }
                    footer
                }
            }
            .background(Theme.panel)
            .foregroundStyle(.white)
            .navigationTitle("Edit by text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    UndoButton(session: session) { reload() }.disabled(working != nil)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { session.pause(); dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        // The editor stays usable behind the half-height sheet: follow any change made there,
        // so cuts are never worked out from clips that have since been trimmed or removed.
        .onReceive(session.$project.dropFirst()) { p in
            if working == nil { reload(p) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { autoClean() } label: { accentLabel("Auto-clean") }
                Menu {
                    Toggle("Cut \"um\" and \"uh\"", isOn: $options.cutFillers)
                    Toggle("Cut lines you started again", isOn: $options.cutRetakes)
                    Picker("Pauses over", selection: $options.minPause) {
                        ForEach([0.5, 0.7, 1.0, 1.5], id: \.self) { Text(String(format: "%.1f s", $0)).tag($0) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").padding(8).background(Theme.panelRaised, in: Circle())
                }
                .accessibilityLabel("Auto-clean settings")
                Spacer()
                Toggle(isOn: $selectStretch) { Text("Select a stretch").font(.caption) }
                    .toggleStyle(.button)
                    .onChange(of: selectStretch) { _, _ in anchor = nil }
            }
            Text(selectStretch
                 ? (anchor == nil ? "Tap the first word of the part to cut." : "Now tap the last word.")
                 : "Tap a word or pause to cut it, tap again to keep it. Press and hold to hear it.")
                .font(.caption2).foregroundStyle(Theme.textDim)
            if let note { Text(note).font(.caption.bold()).foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        let cuts = Transcript.cuts(for: struck, in: tokens, project: session.project)
        let saves = cuts.reduce(0) { $0 + $1.length }
        return HStack {
            if !struck.isEmpty {
                Button("Keep all") { struck.removeAll() }.font(.caption.bold())
            }
            Spacer()
            Button { apply(cuts) } label: {
                accentLabel(struck.isEmpty ? "Nothing marked" : "Cut \(struck.count) (saves \(String(format: "%.1f", saves)) s)")
            }
            .disabled(cuts.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.panelRaised)
    }

    private func load() async {
        if !Transcript.missingPaths(session.project).isEmpty {
            working = "Listening…"
            session.pause()
            do {
                try await session.ensureWords { s, p in working = s; progress = p }
            } catch {
                problem = "Couldn't hear the speech: \(error.localizedDescription)"
            }
            working = nil
        }
        reload()
    }

    private func reload(_ project: EditProject? = nil) {
        // @Published sends the new value before the property changes, so use it when given.
        tokens = Transcript.tokens(project ?? session.project)
        struck = struck.filter { id in tokens.contains { $0.id == id } }
        anchor = nil
    }

    private func tap(_ t: Transcript.Token) {
        guard selectStretch else {
            if struck.contains(t.id) { struck.remove(t.id) } else { struck.insert(t.id) }
            return
        }
        guard let a = anchor, let i = tokens.firstIndex(where: { $0.id == a }),
              let j = tokens.firstIndex(where: { $0.id == t.id }) else {
            anchor = t.id
            return
        }
        for k in min(i, j)...max(i, j) { struck.insert(tokens[k].id) }
        anchor = nil
    }

    private func play(from t: Transcript.Token) {
        session.pause()
        session.seek(max(0, t.start - 0.3))
        session.togglePlay()
    }

    private func autoClean() {
        working = "Finding pauses and mistakes…"
        progress = 0
        session.pause()
        let opts = options
        Task {
            do {
                let cuts = try await Transcript.autoClean(session.project, options: opts) { p in progress = p }
                let found = Transcript.struck(by: cuts, tokens: tokens)
                struck.formUnion(found)
                note = found.isEmpty ? "Nothing to clean. Your take is already tight."
                                                : "Marked \(found.count) bits to cut. Check them, then tap Cut."
            } catch {
                note = error.localizedDescription
            }
            working = nil
        }
    }

    private func apply(_ cuts: [AutoCut.Cut]) {
        let n = struck.count
        session.applyTranscriptCuts(cuts)
        struck.removeAll()
        reload()
        note = "Cut \(n) bits. Tap undo to bring them back."
    }
}

private struct TokenView: View {
    let token: Transcript.Token
    let struck: Bool
    let anchor: Bool

    var body: some View {
        Group {
            switch token.kind {
            case .word:
                Text(token.text)
                    .font(.body)
                    .strikethrough(struck, color: .red)
                    .foregroundStyle(struck ? Color.red.opacity(0.8) : (token.isFiller ? Color.orange : Color.white))
            case .gap:
                Label(token.text, systemImage: "pause.fill")
                    .font(.caption2.monospacedDigit())
                    .labelStyle(.titleAndIcon)
                    .strikethrough(struck, color: .red)
                    .foregroundStyle(struck ? Color.red.opacity(0.8) : Theme.textDim)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(background, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(anchor ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    private var background: Color {
        if struck { return Color.red.opacity(0.15) }
        if token.kind == .gap { return Theme.panelRaised }
        return .clear
    }
}

private struct UndoButton: View {
    @ObservedObject var session: EditorSession
    let after: () -> Void
    var body: some View {
        Button { session.undo(); after() } label: { Image(systemName: "arrow.uturn.backward") }
            .disabled(!session.canUndo)
            .accessibilityLabel("Undo")
    }
}

/// Lays views out left to right and wraps them onto new lines, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
