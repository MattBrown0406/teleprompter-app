import SwiftUI

/// From Export: put the finished videos on the post calendar, captions filled in from the editor.
struct AddToCalendarSheet: View {
    let project: EditProject
    let outputs: [ExportOutput]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PostStore.shared
    @State private var title: String
    @State private var when = PostPlan.nextSlot
    @State private var remind = true
    @State private var platforms: Set<SocialPlatform> = Set(SocialPlatform.allCases)
    @State private var attachTo: UUID?
    @State private var error: String?
    @State private var added = false

    init(project: EditProject, outputs: [ExportOutput]) {
        self.project = project
        self.outputs = outputs
        _title = State(initialValue: project.name)
    }

    /// Ideas already on the calendar that are waiting for a video.
    private var ideas: [PostPlan] { store.plans.filter { !$0.hasVideo && !$0.isPosted } }

    var body: some View {
        NavigationStack {
            Form {
                if !ideas.isEmpty {
                    Section {
                        Picker("Add to", selection: $attachTo) {
                            Text("New post").tag(UUID?.none)
                            ForEach(ideas) { p in
                                Text("\(p.title.isEmpty ? "Untitled" : p.title), \(p.scheduledAt.formatted(date: .abbreviated, time: .omitted))")
                                    .tag(UUID?.some(p.id))
                            }
                        }
                    } footer: {
                        Text("Pick a planned idea to give it this video, or make a new post.")
                    }
                }
                if attachTo == nil {
                    Section {
                        TextField("Title", text: $title)
                        DatePicker("Post on", selection: $when, in: Date()...)
                        Toggle("Remind me", isOn: $remind)
                    }
                    Section("Platforms") {
                        ForEach(SocialPlatform.allCases) { p in
                            Toggle(isOn: Binding(get: { platforms.contains(p) }, set: { on in
                                if on { platforms.insert(p) } else if platforms.count > 1 { platforms.remove(p) }
                            })) { Label(p.name, systemImage: p.symbol) }
                        }
                    }
                }
                Section {
                    Button { add() } label: {
                        Text(added ? "Added" : "Add to post calendar").font(.headline).frame(maxWidth: .infinity)
                    }
                    .disabled(added)
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                } footer: {
                    Text(project.postCopy == nil
                         ? "Tip: write a post caption in the editor's AI copy tool first, or tap Write a caption for each platform on the post."
                         : "Your post caption is copied to each platform. You can tailor each one on the post.")
                }
            }
            .navigationTitle("Post calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func add() {
        do {
            let videos = try outputs.map { try store.keepVideo($0.url, format: $0.format) }
            var plan: PostPlan
            if let id = attachTo, let existing = store.plan(id) {
                plan = existing
            } else {
                plan = PostPlan.new(title: title, at: when, platforms: SocialPlatform.allCases.filter(platforms.contains))
                plan.remind = remind
            }
            plan.videos = videos
            plan.projectID = project.id
            plan.duration = project.duration
            let words = PostCopy.source(project)
            plan.script = words.isEmpty ? nil : words
            if let copy = project.postCopy {
                for i in plan.posts.indices where plan.posts[i].caption.isEmpty { plan.posts[i].caption = copy }
            }
            store.save(plan)
            added = true
            dismiss()
        } catch {
            self.error = "Couldn't keep the video for posting: \(error.localizedDescription)"
        }
    }
}
