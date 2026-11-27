import Photos
import SwiftUI
import UIKit

/// Gets a video into TikTok, Instagram or Facebook without platform approval:
/// copies the caption, saves the video to Photos, and opens the app (or the share sheet).
enum PostHandoff {
    enum Failure: LocalizedError {
        case photos, notSaved
        var errorDescription: String? {
            switch self {
            case .photos: return "Allow Cueframe to add to Photos in Settings so the video can go to the app."
            case .notSaved: return "The video couldn't be saved to Photos."
            }
        }
    }

    private final class Box: @unchecked Sendable { var id: String? }

    /// Saves a video to Photos and returns its asset id.
    static func saveToPhotos(_ url: URL) async throws -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.photos }
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            box.id = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)?
                .placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = box.id else { throw Failure.notSaved }
        return id
    }

    /// App links to try, best first. Instagram can open straight onto the saved video.
    static func appURLs(_ platform: SocialPlatform, photosID: String?) -> [URL] {
        var list: [String] = []
        switch platform {
        case .instagram:
            if let id = photosID, let enc = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                list.append("instagram://library?LocalIdentifier=\(enc)")
            }
            list.append("instagram://app")
        case .tiktok:
            list += ["tiktok://", "snssdk1233://"]
        case .facebook:
            list += ["fb://"]
        }
        return list.compactMap(URL.init(string:))
    }

    /// Opens the platform's app. False when it isn't installed.
    @MainActor
    static func openApp(_ platform: SocialPlatform, photosID: String?) async -> Bool {
        for url in appURLs(platform, photosID: photosID) where UIApplication.shared.canOpenURL(url) {
            if await UIApplication.shared.open(url) { return true }
        }
        return false
    }
}

/// The system share sheet, for apps that aren't installed or when you'd rather pick.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
