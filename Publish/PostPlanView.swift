import SwiftUI
import UIKit

/// One planned post: when it goes out, the caption for each platform, and one-tap posting.
struct PostPlanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: PostPlan
    @State private var busy: SocialPlatform?
    @State private var writing = false
    @State private var message: String?
    @State private var error: String?
    @State private var awaitingConfirm: SocialPlatform?
    @State private var askConfirm = false
    @State private var share: ShareTarget?
    @State private var statsFor: SocialPlatform?
    @State private var confirmDelete = false

    struct ShareTarget: Identifiable {
        let platform: SocialPlatform
        let url: URL
        var id: String { platform.rawValue }
    }

    init(plan: PostPlan) { _draft = State(initialValue: plan) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    DatePicker("Post on", selection: $draft.scheduledAt)
                    Toggle("Remind me", isOn: $draft.remind)
                } footer: {
                    Text("At this time your phone reminds you, with the video and captions ready to go.")
                }

                videoSection

                Section("Platforms") {
                    ForEach(SocialPlatform.allCases) { p in
                        Toggle(isOn: platformBinding(p)) { Label(p.name, systemImage: p.symbol) }
                    }
                }

                ForEach($draft.posts) { $post in
                    platformSection($post)
                }

                Section {
                    Button {
                        Task { await writeCaptions() }
                    } label: {
                        if writing { ProgressView() } else { Label("Write a caption for each platform", systemImage: "sparkles") }
                    }
                    .disabled(writing || (draft.projectID == nil && (draft.script ?? "").isEmpty))
                } footer: {
                    Text("Each platform gets its own length, tone and hashtags. Uses AI when a key is set in Settings, otherwise picks hashtags from your words on the phone.")
                }

                Section("Notes") {
                    TextField("Ideas, hook to try, who to tag…", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Button("Delete from calendar", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(draft.title.isEmpty ? "Post" : draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if let message {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Theme.panelRaised, in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                message = nil
            }
            .onChange(of: draft) { _, new in PostStore.shared.save(new) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, awaitingConfirm != nil { askConfirm = true }
            }
            .sheet(item: $share, onDismiss: {
                if awaitingConfirm != nil { askConfirm = true }
            }) { t in
                ActivitySheet(items: [t.url]).presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { statsFor.map { StatsTarget(platform: $0) } }, set: { statsFor = $0?.platform })) { t in
                StatsEditor(stats: statsBinding(t.platform), platform: t.platform)
            }
            .confirmationDialog(confirmTitle, isPresented: $askConfirm, titleVisibility: .visible) {
                Button("Yes, mark as posted") {
                    if let p = awaitingConfirm { markPosted(p, true) }
                    awaitingConfirm = nil
                }
                Button("Not yet", role: .cancel) { awaitingConfirm = nil }
            }
            .confirmationDialog("Delete this post from the calendar?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    PostStore.shared.delete(draft)
                    dismiss()
                }
            } message: {
                Text("The video stays in Photos and in your project. Stats for this post are removed.")
            }
            .alert("Couldn't post", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private struct StatsTarget: Identifiable {
        let platform: SocialPlatform
        var id: String { platform.rawValue }
    }

    private var confirmTitle: String {
        "Did it post to \(awaitingConfirm?.name ?? "the app")?"
    }

    // MARK: Sections

    @ViewBuilder private var videoSection: some View {
        Section {
            if draft.videos.isEmpty {
                Label("No video yet", systemImage: "film")
                Text("Export a project and tap Add to post calendar to attach its video here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(draft.videos, id: \.path) { v in
                            VStack(spacing: 4) {
                                ThumbnailImage(path: v.path, seconds: 0.5)
                                    .frame(width: 120 * v.format.aspect, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(v.format.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let d = draft.duration { LabeledContent("Length", value: d.timecode) }
            }
        } header: { Text("Video") }
    }

    @ViewBuilder private func platformSection(_ post: Binding<PlatformPost>) -> some View {
        let p = post.wrappedValue.platform
        Section {
            TextField("Caption and hashtags", text: post.caption, axis: .vertical)
                .lineLimit(3...12)
            HStack {
                Text("\(post.wrappedValue.caption.count) / \(p.captionLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(post.wrappedValue.caption.count > p.captionLimit ? .red : .secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = post.wrappedValue.caption
                    message = "Caption copied"
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless)
            }

            if let when = post.wrappedValue.postedAt {
                LabeledContent("Posted", value: when.formatted(date: .abbreviated, time: .shortened))
                TextField("Link to the post (optional)", text: post.link)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    statsFor = p
                } label: {
                    if let s = post.wrappedValue.stats {
                        Label("\(s.views.formatted()) views · \(s.interactions.formatted()) interactions", systemImage: "chart.bar")
                    } else {
                        Label("Add views and likes", systemImage: "chart.bar")
                    }
                }
                Button("Mark as not posted", role: .destructive) { markPosted(p, false) }
            } else {
                Button {
                    Task { await handOff(p) }
                } label: {
                    HStack {
                        if busy == p { ProgressView() } else { Image(systemName: "paperplane.fill") }
                        Text("Post to \(p.name)").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy != nil || !draft.hasVideo)
                Button("I posted it myself") { markPosted(p, true) }
                    .buttonStyle(.borderless)
            }
        } header: {
            Label(p.name, systemImage: p.symbol)
        } footer: {
            if !post.wrappedValue.isPosted { Text(handoffNote(p)) }
        }
    }

    private func handoffNote(_ p: SocialPlatform) -> String {
        let shape = draft.video(for: p)?.format.rawValue ?? "best"
        switch p {
        case .instagram:
            return "Copies the caption, saves the \(shape) video to Photos and opens Instagram on it. Choose Reel, then paste the caption."
        case .tiktok:
            return "Copies the caption, saves the \(shape) video to Photos and opens TikTok. Tap +, pick the newest video, then paste the caption."
        case .facebook:
            return "Copies the caption, saves the \(shape) video to Photos and opens Facebook. Create a Reel or post, pick the newest video, then paste."
        }
    }

    // MARK: Actions

    private func platformBinding(_ p: SocialPlatform) -> Binding<Bool> {
        Binding(get: { draft.platforms.contains(p) }, set: { on in
            if on, !draft.platforms.contains(p) {
                var post = PlatformPost(platform: p)
                post.caption = draft.posts.first?.caption ?? ""
                draft.posts.append(post)
                draft.posts.sort { a, b in
                    SocialPlatform.allCases.firstIndex(of: a.platform)! < SocialPlatform.allCases.firstIndex(of: b.platform)!
                }
            } else if !on, draft.posts.count > 1 {
                draft.posts.removeAll { $0.platform == p }
            }
        })
    }

    private func statsBinding(_ p: SocialPlatform) -> Binding<PostStats> {
        Binding(get: { draft.posts.first { $0.platform == p }?.stats ?? PostStats() },
                set: { s in
                    if let i = draft.posts.firstIndex(where: { $0.platform == p }) {
                        var s = s
                        s.updatedAt = Date()
                        draft.posts[i].stats = s
                    }
                })
    }

    private func markPosted(_ p: SocialPlatform, _ posted: Bool) {
        guard let i = draft.posts.firstIndex(where: { $0.platform == p }) else { return }
        draft.posts[i].postedAt = posted ? Date() : nil
    }

    @MainActor
    private func handOff(_ p: SocialPlatform) async {
        guard let i = draft.posts.firstIndex(where: { $0.platform == p }) else { return }
        guard let video = draft.video(for: p), let vi = draft.videos.firstIndex(of: video) else {
            error = "Attach a video first: export a project and tap Add to post calendar."
            return
        }
        guard FileManager.default.fileExists(atPath: video.url.path) else {
            error = "The video file for this post is missing. Export the project again and add it to the calendar."
            return
        }
        UIPasteboard.general.string = draft.posts[i].caption
        busy = p
        defer { busy = nil }
        do {
            var id = video.photosID
            if id == nil {
                id = try await PostHandoff.saveToPhotos(video.url)
                draft.videos[vi].photosID = id
            }
            awaitingConfirm = p
            if await PostHandoff.openApp(p, photosID: id) {
                message = "Caption copied. Paste it in \(p.name)."
            } else {
                // App not installed: the share sheet can still reach it (or anything else).
                share = ShareTarget(platform: p, url: video.url)
            }
        } catch {
            awaitingConfirm = nil
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func writeCaptions() async {
        writing = true
        defer { writing = false }
        let project = draft.projectID.flatMap { id in ProjectStore.shared.projects.first { $0.id == id } }
        for i in draft.posts.indices {
            let platform = draft.posts[i].platform.copyPlatform
            do {
                if let project {
                    draft.posts[i].caption = try await PostCopy.make(for: project, platform: platform)
                } else if let script = draft.script, !script.isEmpty {
                    draft.posts[i].caption = PostCopy.offline(script, platform: platform)
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
    }
}

/// Views and engagement, typed in from the app's own insights.
struct StatsEditor: View {
    @Binding var stats: PostStats
    let platform: SocialPlatform
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PostStats

    init(stats: Binding<PostStats>, platform: SocialPlatform) {
        _stats = stats
        self.platform = platform
        _draft = State(initialValue: stats.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Views", $draft.views)
                    row("Likes", $draft.likes)
                    row("Comments", $draft.comments)
                    row("Shares", $draft.shares)
                    row(platform == .facebook ? "Saves (if shown)" : "Saves", $draft.saves)
                } footer: {
                    Text("Copy these from \(platform.name)'s insights for this video. Once \(platform.name) approves Cueframe they can fill in on their own.")
                }
                if draft.views > 0 {
                    LabeledContent("Engagement", value: draft.engagement.formatted(.percent.precision(.fractionLength(1))))
                }
            }
            .navigationTitle("\(platform.name) stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { stats = draft; dismiss() } }
            }
        }
    }

    private func row(_ label: String, _ value: Binding<Int>) -> some View {
        LabeledContent(label) {
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }
}
