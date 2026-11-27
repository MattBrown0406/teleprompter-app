import SwiftUI

/// What works: views and engagement across posted videos, by hook, length, topic, platform and time.
struct PerformanceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PostStore.shared
    @State private var aiAdvice: String?
    @State private var asking = false
    @State private var aiError: String?

    private var results: [PostResult] { PostInsights.results(store.plans) }

    var body: some View {
        NavigationStack {
            List {
                let r = results
                if r.isEmpty {
                    Section {
                        Text("Once you've posted, add each video's views and likes (open the post on the calendar, then Add views and likes). Cueframe then shows which hooks, lengths and topics do best for you.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        LabeledContent("Posts with stats", value: "\(r.count)")
                        LabeledContent("Total views", value: r.reduce(0) { $0 + $1.stats.views }.formatted())
                        LabeledContent("Average engagement", value: PostInsights.avgEngagement(r).formatted(.percent.precision(.fractionLength(1))))
                    }

                    groupSection("By platform", PostInsights.group(r) { $0.platform.name })
                    groupSection("By opening line", PostInsights.group(r) { PostInsights.hookStyle($0.hook) },
                                 footer: "How the first sentence starts: a question, a number or list, a warning, a personal story, or a plain statement.")
                    groupSection("By length", PostInsights.group(r) { PostInsights.lengthBucket($0.duration) })
                    groupSection("By topic", Array(PostInsights.topics(r).prefix(8)),
                                 footer: "Topics come from the hashtags in each caption.")
                    groupSection("By time posted", PostInsights.group(r) { PostInsights.timeBucket($0.postedAt) })

                    Section("Top videos") {
                        ForEach(Array(r.sorted { $0.stats.views > $1.stats.views }.prefix(5))) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.headline).lineLimit(1)
                                Text("\(item.platform.name) · \(item.stats.views.formatted()) views · \(item.stats.engagement.formatted(.percent.precision(.fractionLength(1)))) engagement")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !item.hook.isEmpty {
                                    Text("“\(item.hook)”").font(.caption).italic().lineLimit(2)
                                }
                            }
                        }
                    }

                    Section {
                        if let aiAdvice {
                            Text(aiAdvice).font(.callout)
                        }
                        Button {
                            Task { await ask(r) }
                        } label: {
                            if asking { ProgressView() } else { Label(aiAdvice == nil ? "Ask AI what to try next" : "Ask again", systemImage: "sparkles") }
                        }
                        .disabled(asking || !AIClient.shared.isConfigured || r.count < 3)
                        if let aiError { Text(aiError).font(.footnote).foregroundStyle(.red) }
                    } footer: {
                        Text(!AIClient.shared.isConfigured ? "Add an AI key in Settings to get advice from your numbers."
                             : r.count < 3 ? "Needs stats on at least 3 posts." : "Sends your titles, opening lines and numbers, not your videos.")
                    }
                }

                Section {
                    Text("Stats are typed in for now. Once TikTok and Meta approve Cueframe's access, views and likes can fill in on their own.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func groupSection(_ title: String, _ groups: [PostInsights.Bucket], footer: String? = nil) -> some View {
        if !groups.isEmpty {
            let top = groups.map(\.avgViews).max() ?? 1
            Section {
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(g.label)
                            Spacer()
                            Text("\(Int(g.avgViews.rounded()).formatted()) avg views").font(.caption.monospacedDigit())
                        }
                        GeometryReader { geo in
                            Capsule().fill(g.id == groups.first?.id ? Theme.accent : Theme.accent2.opacity(0.6))
                                .frame(width: max(4, geo.size.width * g.avgViews / max(top, 1)))
                        }
                        .frame(height: 6)
                        Text("\(g.count) post\(g.count == 1 ? "" : "s") · \(g.avgEngagement.formatted(.percent.precision(.fractionLength(1)))) engagement")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    @MainActor
    private func ask(_ r: [PostResult]) async {
        asking = true
        aiError = nil
        defer { asking = false }
        let lines = r.sorted { $0.stats.views > $1.stats.views }.prefix(40).map { item in
            "- \(item.platform.name) | \(Int(item.duration ?? 0))s | posted \(item.postedAt.formatted(.dateTime.weekday().hour())) | views \(item.stats.views) | likes \(item.stats.likes) | comments \(item.stats.comments) | shares \(item.stats.shares) | saves \(item.stats.saves) | title: \(item.title) | opening line: \(item.hook) | tags: \(item.tags.joined(separator: " "))"
        }.joined(separator: "\n")
        let system = """
        You are a short-form video coach. Look at a creator's own results and say what is working. \
        Be specific and practical, refer to their actual opening lines and topics, and say how confident you are given how few posts there are. \
        Plain text, no markdown headings, under 180 words: three findings, then three things to try in the next videos.
        """
        do {
            aiAdvice = try await AIClient.shared.complete(system: system, prompt: "My posted videos:\n\(lines)", maxTokens: 800)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            aiError = error.localizedDescription
        }
    }
}

/// One platform post that has stats.
struct PostResult: Identifiable {
    let id: String
    let title: String
    let platform: SocialPlatform
    let hook: String
    let duration: Double?
    let postedAt: Date
    let stats: PostStats
    let tags: [String]
}

enum PostInsights {
    struct Bucket: Identifiable {
        let label: String
        let count: Int
        let avgViews: Double
        let avgEngagement: Double
        var id: String { label }
    }

    static func results(_ plans: [PostPlan]) -> [PostResult] {
        plans.flatMap { plan in
            plan.posts.compactMap { post -> PostResult? in
                guard let stats = post.stats, let at = post.postedAt else { return nil }
                return PostResult(id: "\(plan.id)-\(post.platform.rawValue)", title: plan.title.isEmpty ? "Untitled" : plan.title,
                                  platform: post.platform, hook: plan.hook, duration: plan.duration,
                                  postedAt: at, stats: stats, tags: hashtags(post.caption))
            }
        }
    }

    static func avgEngagement(_ r: [PostResult]) -> Double {
        r.isEmpty ? 0 : r.map(\.stats.engagement).reduce(0, +) / Double(r.count)
    }

    /// Groups results by a label, best average views first.
    static func group(_ r: [PostResult], by key: (PostResult) -> String) -> [Bucket] {
        Dictionary(grouping: r, by: key).map { label, items in
            Bucket(label: label, count: items.count,
                  avgViews: Double(items.map(\.stats.views).reduce(0, +)) / Double(items.count),
                  avgEngagement: avgEngagement(items))
        }
        .sorted { $0.avgViews > $1.avgViews }
    }

    /// One result can count toward several hashtags.
    static func topics(_ r: [PostResult]) -> [Bucket] {
        var byTag: [String: [PostResult]] = [:]
        for item in r { for t in Set(item.tags) { byTag[t, default: []].append(item) } }
        return byTag.map { tag, items in
            Bucket(label: tag, count: items.count,
                  avgViews: Double(items.map(\.stats.views).reduce(0, +)) / Double(items.count),
                  avgEngagement: avgEngagement(items))
        }
        .sorted { $0.avgViews == $1.avgViews ? $0.count > $1.count : $0.avgViews > $1.avgViews }
    }

    static func hashtags(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .map { "#" + $0.dropFirst().trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { $0.count > 1 }
    }

    static func hookStyle(_ hook: String) -> String {
        let h = hook.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return "No opening line" }
        let first = h.split(separator: " ").first.map(String.init) ?? ""
        let questionWords: Set<String> = ["how", "why", "what", "who", "when", "where", "did", "do", "does", "are", "is", "can", "should", "have", "ever", "would", "want"]
        if h.hasSuffix("?") || questionWords.contains(first) { return "Question" }
        if let c = h.first, c.isNumber { return "Number or list" }
        let warnings = ["stop ", "don't", "never ", "mistake", "avoid", "warning", "wrong"]
        if warnings.contains(where: { h.contains($0) }) { return "Warning" }
        if first == "i" || first == "i'm" || first == "i've" || first == "my" || h.contains(" i ") { return "Personal story" }
        return "Statement"
    }

    static func lengthBucket(_ seconds: Double?) -> String {
        guard let s = seconds else { return "Unknown length" }
        switch s {
        case ..<15: return "Under 15s"
        case ..<30: return "15 to 30s"
        case ..<60: return "30 to 60s"
        case ..<90: return "1 to 1.5 min"
        case ..<180: return "1.5 to 3 min"
        default: return "Over 3 min"
        }
    }

    static func timeBucket(_ date: Date) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let weekend = cal.isDateInWeekend(date)
        let part: String
        switch hour {
        case 5..<12: part = "morning"
        case 12..<17: part = "afternoon"
        case 17..<22: part = "evening"
        default: part = "night"
        }
        return (weekend ? "Weekend " : "Weekday ") + part
    }
}
