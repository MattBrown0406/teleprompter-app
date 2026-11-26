import Foundation

/// File locations shared by the recorder and the editor.
enum MediaLibrary {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// Raw takes from the recorder.
    static var recordings: URL { dir("Recordings") }
    /// Imported media (music, voiceovers, picked clips) copied into the sandbox.
    static var media: URL { dir("Media") }
    /// Editor project JSON files.
    static var projects: URL { dir("Projects") }
    /// Finished exports.
    static var exports: URL { dir("Exports") }

    static func newFile(in folder: URL, ext: String) -> URL {
        folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private static func dir(_ name: String) -> URL {
        let url = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stores paths relative to Documents so they survive app reinstalls and container moves.
    static func relativePath(_ url: URL) -> String {
        let base = documents.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count + 1)) : path
    }
    static func resolve(_ relative: String) -> URL {
        relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : documents.appendingPathComponent(relative)
    }
}
