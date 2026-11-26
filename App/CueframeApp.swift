import SwiftUI

@main
struct CueframeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Taps on posting reminders open the post.
        PostReminders.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            // Back up projects whenever the app comes to the front.
            if phase == .active { ProjectSync.shared.syncSoon(delay: 0) }
        }
    }
}

/// Top-level navigation shared by the recorder and the editor.
struct RootView: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        TabView(selection: $router.tab) {
            RecorderTabPlaceholder()
                .tabItem { Label("Record", systemImage: "record.circle") }
                .tag(AppRouter.Tab.record)
            ProjectsView()
                .tabItem { Label("Edit", systemImage: "film.stack") }
                .tag(AppRouter.Tab.edit)
            PostCalendarView()
                .tabItem { Label("Post", systemImage: "calendar") }
                .tag(AppRouter.Tab.post)
        }
        .onChange(of: router.openPostPlan) { _, id in
            // A reminder tapped while the editor is open: close it so the post shows.
            if id != nil { router.openProject = nil }
        }
        .fullScreenCover(item: $router.openProject) { project in
            EditorView(project: project)
        }
    }
}

struct RecorderTabPlaceholder: View {
    var body: some View { RecorderRootView() }
}
