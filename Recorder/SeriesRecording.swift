import SwiftUI

/// Record several scripts back to back. Each kept take is filed to its own editor project,
/// named after its script.
@MainActor
final class SeriesSession: ObservableObject {
    struct Filed: Identifiable, Equatable {
        let scriptID: UUID
        let title: String
        let projectID: UUID
        var id: UUID { projectID }
    }

    @Published private(set) var queue: [UUID] = []
    @Published private(set) var index = 0
    @Published private(set) var filed: [Filed] = []
    @Published private(set) var isActive = false
    /// Skip the take review: file each take and roll straight into the next script.
    @Published var backToBack = false
    /// Shows the summary of what the series made.
    @Published var showSummary = false

    var currentID: UUID? { queue.indices.contains(index) ? queue[index] : nil }
    var position: String { "\(min(index + 1, queue.count)) of \(queue.count)" }
    var isLast: Bool { index >= queue.count - 1 }

    func start(_ ids: [UUID], backToBack: Bool) {
        guard !ids.isEmpty else { return }
        queue = ids
        index = 0
        filed = []
        self.backToBack = backToBack
        isActive = true
        showSummary = false
    }

    /// Files a take into a new project for the current script, then moves on.
    /// Returns the new project.
    @discardableResult
    func file(take url: URL, script: Script?, canvas: CanvasFormat, quality: ExportQuality) -> EditProject {
        var project = EditProject.new(clips: [url], canvas: canvas, quality: quality)
        if let script {
            project.name = script.displayTitle
            let body = script.body.trimmingCharacters(in: .whitespacesAndNewlines)
            project.scriptText = body.isEmpty ? nil : script.body
        }
        ProjectStore.shared.save(project)
        filed.append(Filed(scriptID: script?.id ?? UUID(), title: project.name, projectID: project.id))
        advance()
        return project
    }

    /// Leaves the current script without a take.
    func skip() { advance() }

    /// Stops the series. The screen shows the summary once any review has closed.
    func end() {
        isActive = false
    }

    func finishSummary() {
        showSummary = false
        queue = []
        filed = []
        index = 0
    }

    private func advance() {
        if index + 1 < queue.count {
            index += 1
        } else {
            index = queue.count
            end()
        }
    }
}

/// Pick the scripts for a series and their order.
struct SeriesSetupView: View {
    @ObservedObject var store: ScriptStore
    let onStart: (_ ids: [UUID], _ backToBack: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [UUID] = []
    @AppStorage("rec.seriesBackToBack") private var backToBack = false

    var body: some View {
        NavigationStack {
            List {
                if !picked.isEmpty {
                    Section {
                        ForEach(picked, id: \.self) { id in
                            if let script = store.scripts.first(where: { $0.id == id }) {
                                HStack {
                                    Text("\((picked.firstIndex(of: id) ?? 0) + 1)").font(.headline.monospacedDigit()).foregroundStyle(Theme.accent).frame(width: 26)
                                    VStack(alignment: .leading) {
                                        Text(script.displayTitle)
                                        Text("about \(RecorderFormat.time(script.estimatedDuration))").font(.caption).foregroundStyle(Theme.textDim)
                                    }
                                }
                            }
                        }
                        .onMove { picked.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { picked.remove(atOffsets: $0) }
                    } header: {
                        HStack {
                            Text("Recording order")
                            Spacer()
                            if picked.count > 1 { EditButton().font(.caption.weight(.semibold)) }
                        }
                    } footer: {
                        Text("Tap Edit to reorder. Total about \(RecorderFormat.time(totalTime)).")
                    }
                }

                Section("Scripts") {
                    ForEach(store.scripts) { script in
                        Button {
                            if let i = picked.firstIndex(of: script.id) { picked.remove(at: i) } else { picked.append(script.id) }
                        } label: {
                            HStack {
                                Image(systemName: picked.contains(script.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(script.id) ? Theme.accent : Theme.textDim)
                                Text(script.displayTitle).foregroundStyle(.primary)
                                Spacer()
                                Text("\(script.wordCount) words").font(.caption).foregroundStyle(Theme.textDim)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Back to back", isOn: $backToBack)
                } footer: {
                    Text(backToBack
                         ? "After each take, it is filed and the next script starts after the countdown. Review them all at the end."
                         : "After each take you can watch it and retake before moving on.")
                }
            }
            .navigationTitle("Record a series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start \(picked.isEmpty ? "" : "(\(picked.count))")") {
                        onStart(picked, backToBack)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }

    private var totalTime: TimeInterval {
        picked.compactMap { id in store.scripts.first { $0.id == id }?.estimatedDuration }.reduce(0, +)
    }
}

/// Shown above the script while a series runs: which script, and a way to skip or stop.
struct SeriesStrip: View {
    @ObservedObject var series: SeriesSession
    let title: String
    let onSkip: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.number").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Series \(series.position)").font(.caption.weight(.bold))
                Text(title).font(.caption).lineLimit(1).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            Button("Skip", action: onSkip).font(.caption.weight(.bold))
            Button("End", action: onEnd).font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 12)
    }
}

/// "Up next" card shown during the countdown between back-to-back takes.
struct SeriesUpNext: View {
    let title: String
    let position: String

    var body: some View {
        VStack(spacing: 6) {
            Text("Up next · \(position)").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }
}

/// The projects a series made, each ready to open in the editor.
struct SeriesSummaryView: View {
    let filed: [SeriesSession.Filed]
    let onOpen: (UUID) -> Void
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filed) { item in
                        Button { onOpen(item.projectID); dismiss() } label: {
                            HStack {
                                Image(systemName: "film").foregroundStyle(Theme.accent)
                                Text(item.title).foregroundStyle(.primary)
                                Spacer()
                                Text("Open").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent2)
                            }
                        }
                    }
                } footer: {
                    Text("Each take is its own project in the Edit tab, named after its script.")
                }
            }
            .navigationTitle("Series done: \(filed.count) \(filed.count == 1 ? "video" : "videos")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onDisappear(perform: onDone)
        }
    }
}
