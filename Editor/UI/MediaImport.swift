import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

/// A movie picked from Photos, copied into the app's Media folder.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = MediaLibrary.newFile(in: MediaLibrary.media, ext: ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

enum MediaImport {
    /// Loads picked Photos items in order. Items that fail are skipped.
    static func movies(from items: [PhotosPickerItem]) async -> [URL] {
        var urls: [URL] = []
        for item in items {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) { urls.append(movie.url) }
        }
        return urls
    }

    /// Copies a file picked in Files (security-scoped) into Media.
    static func copyIn(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = MediaLibrary.newFile(in: MediaLibrary.media, ext: url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
