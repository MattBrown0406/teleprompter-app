import SwiftUI

/// The Post tab: a month calendar of what's planned and posted, plus what needs doing next.
struct PostCalendarView: View {
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var store = PostStore.shared
    @State private var month = Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var editing: PostPlan?
    @State private var showInsights = false

    private let cal = Calendar.current

    var body: some View {
        NavigationStack {
            List {
                Section { monthGrid }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                Section {
                    let day = store.plans(on: selectedDay)
                    if day.isEmpty {
                        Button { add(on: selectedDay) } label: { Label("Plan a post for this day", systemImage: "plus") }
                    } else {
                        ForEach(day) { row($0) }
                    }
                } header: {
                    Text(selectedDay.formatted(.dateTime.weekday(.wide).month().day()))
                }

                let overdue = store.plans.filter(\.isOverdue)
                if !overdue.isEmpty {
                    Section("Waiting to post") { ForEach(overdue) { row($0) } }
                }

                let upcoming = store.plans.filter { !$0.isPosted && $0.scheduledAt >= Date() }.prefix(10)
                if !upcoming.isEmpty {
                    Section("Coming up") { ForEach(Array(upcoming)) { row($0) } }
                }

                let needStats = store.plans.filter { plan in
                    plan.posts.contains { $0.isPosted && $0.stats == nil && ($0.postedAt ?? .distantFuture) < Date().addingTimeInterval(-86_400) }
                }
                if !needStats.isEmpty {
                    Section {
                        ForEach(needStats) { row($0) }
                    } header: {
                        Text("Add stats")
                    } footer: {
                        Text("Posted over a day ago. Add views and likes to see what works in Insights.")
                    }
                }

                if store.plans.isEmpty {
                    Section {
                        Text("Plan posts here. Export a video and tap Add to post calendar, or tap + to plan an idea. You'll get a reminder at post time with the video and caption ready.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Post")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showInsights = true } label: { Label("Insights", systemImage: "chart.bar.xaxis") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { add(on: selectedDay) } label: { Label("Plan a post", systemImage: "plus") }
                }
            }
            .sheet(item: $editing) { PostPlanView(plan: $0) }
            .sheet(isPresented: $showInsights) { PerformanceView() }
            .onAppear { openPending() }
            .onChange(of: router.openPostPlan) { _, _ in openPending() }
        }
    }

    // MARK: Month grid

    private var monthGrid: some View {
        VStack(spacing: 8) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 40) }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let plans = store.plans(on: day)
        let selected = cal.isDate(day, inSameDayAs: selectedDay)
        let today = cal.isDateInToday(day)
        return Button {
            selectedDay = cal.startOfDay(for: day)
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.subheadline.weight(today ? .bold : .regular))
                    .foregroundStyle(selected ? Color.black : (today ? Theme.accent : Color.primary))
                HStack(spacing: 2) {
                    ForEach(plans.prefix(3)) { p in
                        Circle().fill(dotColor(p)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func dotColor(_ p: PostPlan) -> Color {
        if p.isPosted { return .green }
        if p.isOverdue { return .orange }
        return p.hasVideo ? Theme.accent2 : .gray
    }

    private var days: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let dates: [Date?] = (0..<count).map { cal.date(byAdding: .day, value: $0, to: first) }
        return Array(repeating: nil, count: offset) + dates
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(s[start...] + s[..<start])
    }

    private func shiftMonth(_ by: Int) {
        month = cal.date(byAdding: .month, value: by, to: month) ?? month
    }

    // MARK: Rows

    private func row(_ plan: PostPlan) -> some View {
        Button { editing = plan } label: {
            HStack(spacing: 12) {
                if let v = plan.videos.first {
                    ThumbnailImage(path: v.path, seconds: 0.5)
                        .frame(width: 40, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised)
                        .frame(width: 40, height: 56)
                        .overlay(Image(systemName: "lightbulb").foregroundStyle(.secondary))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.title.isEmpty ? "Untitled post" : plan.title).font(.headline).lineLimit(1)
                    Text(plan.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(plan.isOverdue ? .orange : .secondary)
                    HStack(spacing: 6) {
                        ForEach(plan.posts) { post in
                            Image(systemName: post.isPosted ? "checkmark.circle.fill" : post.platform.symbol)
                                .foregroundStyle(post.isPosted ? .green : .secondary)
                                .font(.caption)
                        }
                        if !plan.hasVideo { Text("Needs video").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
            }
        }
        .foregroundStyle(.primary)
        .swipeActions {
            Button(role: .destructive) { store.delete(plan) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: Actions

    private func add(on day: Date) {
        let start = cal.startOfDay(for: day)
        var when = cal.date(bySettingHour: 18, minute: 0, second: 0, of: start) ?? start
        if when < Date() { when = PostPlan.nextSlot }
        let plan = PostPlan.new(title: "", at: when)
        store.save(plan)
        editing = plan
    }

    private func openPending() {
        guard let id = router.openPostPlan else { return }
        router.openPostPlan = nil
        if let plan = store.plan(id) {
            selectedDay = cal.startOfDay(for: plan.scheduledAt)
            month = plan.scheduledAt
            editing = plan
        }
    }
}
