import Foundation

/// Saves projects as JSON in Documents/Projects.
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
    }

    func delete(_ project: EditProject) {
        try? FileManager.default.removeItem(at: file(for: project.id))
        projects.removeAll { $0.id == project.id }
    }

    func duplicate(_ project: EditProject) {
        var copy = project
        copy.id = UUID()
        copy.name = project.name + " copy"
        copy.created = Date()
        save(copy)
    }

    private func file(for id: UUID) -> URL {
        MediaLibrary.projects.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
