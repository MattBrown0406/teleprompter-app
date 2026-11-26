import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    enum Tab: Hashable { case record, edit }

    @Published var tab: Tab = .record
    @Published var openProject: EditProject?
}

/// The one entry point the recorder uses to hand finished takes to the editor.
enum EditorLauncher {
    /// Opens the editor with the given clip files on a canvas.
    /// - Parameters:
    ///   - urls: local file URLs of the recorded takes, in timeline order.
    ///   - canvas: the aspect ratio the video was recorded for.
    ///   - quality: the resolution the user recorded at, used as the default export.
    @MainActor
    static func open(urls: [URL], canvas: CanvasFormat, quality: ExportQuality = .hd1080) {
        let project = EditProject.new(clips: urls, canvas: canvas, quality: quality)
        ProjectStore.shared.save(project)
        AppRouter.shared.tab = .edit
        AppRouter.shared.openProject = project
    }
}
