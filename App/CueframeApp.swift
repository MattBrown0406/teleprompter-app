import SwiftUI

@main
struct CueframeApp: App {
    @StateObject private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
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
        }
        .fullScreenCover(item: $router.openProject) { project in
            EditorView(project: project)
        }
    }
}

struct RecorderTabPlaceholder: View {
    var body: some View { RecorderRootView() }
}
