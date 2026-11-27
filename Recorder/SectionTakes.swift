import SwiftUI
import AVKit

/// Record a script part by part: each paragraph is a section, each section can have
/// several takes, and the best take of each is joined in order.
final class SectionSession: ObservableObject {
    @Published private(set) var sections: [String] = []
    @Published var current = 0
    /// Takes per section, oldest first.
    @Published private(set) var takes: [[URL]] = []
    /// The take picked for each section. The newest take is picked until you choose another.
    @Published var chosen: [Int: URL] = [:]

    private var script = ""

    /// Splits the script into sections at blank lines. Parts whose text didn't change keep their takes,
    /// so fixing a typo in one paragraph doesn't throw away the others.
    func load(script newScript: String) {
        guard newScript != script else { return }
        let oldSections = sections, oldTakes = takes, oldChosen = chosen
        let oldCurrentText = currentText
        script = newScript
        sections = Self.split(newScript)
        var newTakes = Array(repeating: [URL](), count: sections.count)
        var newChosen: [Int: URL] = [:]
        var used = Set<Int>()
        for (i, text) in sections.enumerated() {
            guard let j = oldSections.indices.first(where: { !used.contains($0) && oldSections[$0] == text }),
                  oldTakes.indices.contains(j) else { continue }
            used.insert(j)
            newTakes[i] = oldTakes[j]
            newChosen[i] = oldChosen[j]
        }
        takes = newTakes
        chosen = newChosen
        current = sections.firstIndex(of: oldCurrentText) ?? min(current, max(0, sections.count - 1))
    }

    var currentText: String { sections.indices.contains(current) ? sections[current] : "" }
    var hasNext: Bool { current + 1 < sections.count }
    var hasPrevious: Bool { current > 0 }
    var takeCount: Int { takes.reduce(0) { $0 + $1.count } }
    var coveredCount: Int { sections.indices.filter { chosen[$0] != nil }.count }

    /// The picked take of each section, in script order. Sections with no take are left out.
    var bestTakes: [URL] { sections.indices.compactMap { chosen[$0] } }

    func add(_ url: URL) {
        guard takes.indices.contains(current) else { return }
        takes[current].append(url)
        chosen[current] = url
    }

    func remove(_ url: URL) {
        for index in takes.indices {
            takes[index].removeAll { $0 == url }
            if chosen[index] == url { chosen[index] = takes[index].last }
        }
    }

    func next() { if hasNext { current += 1 } }
    func previous() { if hasPrevious { current -= 1 } }

    static func split(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }
}

/// Shows where you are in a section-by-section recording, with arrows to move between parts.
struct SectionStrip: View {
    @ObservedObject var session: SectionSession
    let onShowTakes: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { session.previous() } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                .disabled(!session.hasPrevious)
                .accessibilityLabel("Previous part")
            VStack(spacing: 0) {
                Text("Part \(session.current + 1) of \(session.sections.count)")
                    .font(.subheadline.weight(.bold))
                let count = session.takes.indices.contains(session.current) ? session.takes[session.current].count : 0
                Text(count == 0 ? "No take yet" : count == 1 ? "1 take" : "\(count) takes")
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .frame(minWidth: 96)
            Button { session.next() } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                .disabled(!session.hasNext)
                .accessibilityLabel("Next part")
            Button(action: onShowTakes) {
                Label("Takes", systemImage: "square.stack.3d.up.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(session.coveredCount > 0 ? Theme.accent : Color.clear, in: Capsule())
                    .foregroundStyle(session.coveredCount > 0 ? Color.black : Color.white)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
    }
}

/// Every part of the script with its takes: pick the best, re-record a part, or join them.
struct SectionTakesView: View {
    @ObservedObject var session: SectionSession
    var onRecordPart: (Int) -> Void
    var onJoin: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var playing: URL?

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.sections.indices, id: \.self) { index in
                    Section {
                        let takes = session.takes.indices.contains(index) ? session.takes[index] : []
                        ForEach(Array(takes.enumerated()), id: \.element) { number, url in
                            HStack {
                                Button {
                                    session.chosen[index] = url
                                } label: {
                                    Image(systemName: session.chosen[index] == url ? "star.fill" : "star")
                                        .foregroundStyle(session.chosen[index] == url ? Theme.accent : Theme.textDim)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(session.chosen[index] == url ? "Best take" : "Use this take")
                                Text("Take \(number + 1)")
                                Spacer()
                                Button { playing = url } label: { Image(systemName: "play.circle.fill").font(.title3) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Play take \(number + 1)")
                            }
                        }
                        Button(takes.isEmpty ? "Record this part" : "Record another take") {
                            onRecordPart(index)
                            dismiss()
                        }
                    } header: {
                        Text("Part \(index + 1)")
                    } footer: {
                        Text(session.sections[index]).lineLimit(3)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onJoin(session.bestTakes)
                    dismiss()
                } label: {
                    Text(joinTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                }
                .disabled(session.bestTakes.isEmpty)
                .opacity(session.bestTakes.isEmpty ? 0.4 : 1)
                .padding()
                .background(.bar)
            }
            .navigationTitle("Takes by part")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { playing.map(PlayingTake.init) }, set: { playing = $0?.url })) { take in
                TakePlayer(url: take.url)
            }
        }
    }

    private var joinTitle: String {
        let covered = session.coveredCount, total = session.sections.count
        if covered == total { return "Join best takes and edit" }
        return "Join \(covered) of \(total) parts and edit"
    }

    private struct PlayingTake: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

private struct TakePlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                PlaybackAudio.activate()
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
            .onDisappear { player?.pause() }
    }
}
