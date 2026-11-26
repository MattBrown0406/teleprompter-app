import Foundation

/// Saves projects as JSON in Documents/Projects, and queues each change for cloud backup (ProjectSync).
@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()
    @Published private(set) var projects: [EditProject] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() { reload() }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: MediaLibrary.projects, includingPropertiesForKeys: nil)) ?? []
        projects = urls.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(EditProject.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modified > $1.modified }
    }

    func save(_ project: EditProject) {
        var p = project
        p.modified = Date()
        guard let data = try? encoder.encode(p) else { return }
        try? data.write(to: file(for: p.id), options: .atomic)
        if let i = projects.firstIndex(where: { $0.id == p.id }) {
            projects[i] = p
        } else {
            projects.insert(p, at: 0)
        }
        projects.sort { $0.modified > $1.modified }
        ProjectSync.shared.markChanged(p.id)
    }

    /// Marks a project finished (exported) or back to in progress.
    func setFinished(_ project: EditProject, _ finished: Bool) {
        var p = projects.first { $0.id == project.id } ?? project
        guard p.isFinished != finished else { return }
        p.finishedAt = finished ? Date() : nil
        save(p)
    }

    /// Writes a project that came down from the cloud, keeping its own modified date and not re-queuing it.
    func applyFromCloud(_ project: EditProject) {
        guard let data = try? encoder.encode(project) else { return }
        try? data.write(to: file(for: project.id), options: .atomic)
        if let i = projects.firstIndex(where: { $0.id == project.id }) {
            projects[i] = project
        } else {
            projects.append(project)
        }
        projects.sort { $0.modified > $1.modified }
    }

    /// The project was deleted on another device. Removes the project file but leaves media alone.
    func removeFromCloud(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
        projects.removeAll { $0.id == id }
    }

    func delete(_ project: EditProject) {
        try? FileManager.default.removeItem(at: file(for: project.id))
        projects.removeAll { $0.id == project.id }
        ProjectSync.shared.markDeleted(project)
        // Free the space its media took, unless another project (a duplicate) or the brand kit uses it.
        let stillUsed = projects.reduce(into: Self.brandFiles()) { $0.formUnion(Self.files(of: $1)) }
        for path in Self.files(of: project).subtracting(stillUsed) {
            let url = MediaLibrary.resolve(path)
            // Only files the app made inside its own folders.
            guard url.standardizedFileURL.path.hasPrefix(MediaLibrary.documents.standardizedFileURL.path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// True when a saved project uses this file, so it must not be deleted.
    func uses(_ url: URL) -> Bool {
        let path = MediaLibrary.relativePath(url)
        return projects.contains { Self.files(of: $0).contains(path) }
    }

    /// Every media file a project points at, as stored paths.
    nonisolated static func files(of p: EditProject) -> Set<String> {
        var out = Set<String>()
        for c in p.clips where !c.isBrandClip {
            out.insert(c.path)
            if let clean = c.cleanAudioPath { out.insert(clean) }
        }
        for a in p.audio { out.insert(a.path) }
        if let logo = p.logo?.path { out.insert(logo) }
        return out
    }

    static func brandFiles() -> Set<String> {
        guard let kit = BrandStore.shared.kit else { return [] }
        return Set([kit.logoPath, kit.introPath, kit.outroPath, kit.customFontPath].compactMap { $0 })
    }

    func duplicate(_ project: EditProject) {
        var copy = project
        copy.id = UUID()
        copy.name = project.name + " copy"
        copy.created = Date()
        copy.finishedAt = nil
        save(copy)
    }

    private func file(for id: UUID) -> URL {
        MediaLibrary.projects.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
