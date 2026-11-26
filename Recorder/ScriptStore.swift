import Foundation

struct Script: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var updatedAt = Date()

    var wordCount: Int { body.split { $0.isWhitespace || $0.isNewline }.count }

    /// Rough speaking time at a natural 150 words per minute.
    var estimatedDuration: TimeInterval { Double(wordCount) / 150 * 60 }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled script" : String(firstLine.prefix(40))
    }
}

/// Saved scripts, kept in Documents/Scripts.json.
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [Script] = []
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "rec.selectedScript") }
    }

    private let fileURL = MediaLibrary.documents.appendingPathComponent("Scripts.json")

    var selected: Script? { scripts.first { $0.id == selectedID } ?? scripts.first }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Script].self, from: data) {
            scripts = saved
        }
        if scripts.isEmpty { scripts = [Self.welcome] }
        selectedID = UUID(uuidString: UserDefaults.standard.string(forKey: "rec.selectedScript") ?? "") ?? scripts.first?.id
    }

    func save(_ script: Script) {
        var updated = script
        updated.updatedAt = Date()
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = updated
        } else {
            scripts.insert(updated, at: 0)
        }
        persist()
    }

    func delete(_ script: Script) {
        scripts.removeAll { $0.id == script.id }
        if selectedID == script.id { selectedID = scripts.first?.id }
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(scripts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Couldn't save scripts: \(error)")
        }
    }

    static let welcome = Script(
        title: "Try me",
        body: """
        Hi, I'm testing my new teleprompter.

        Tap the script to pause or start scrolling. Drag it to scroll back. Pinch to make the words bigger or smaller.

        Use the plus and minus buttons to change the speed while you record.

        When you're done, tap stop, then save the take to Photos or open it in the editor.
        """
    )
}
