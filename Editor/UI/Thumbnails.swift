import AVFoundation
import UIKit
import SwiftUI

/// Small cached frame grabs for the timeline and trim strip.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: UIImage] = [:]
    private var generators: [String: AVAssetImageGenerator] = [:]

    func image(path: String, at seconds: Double, height: CGFloat = 120) async -> UIImage? {
        let key = "\(path)@\(Int(seconds * 4))"
        if let hit = cache[key] { return hit }
        let gen = generator(for: path, height: height)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? await gen.image(at: time).image else { return nil }
        let img = UIImage(cgImage: cg)
        if cache.count > 600 { cache.removeAll() }
        cache[key] = img
        return img
    }

    private func generator(for path: String, height: CGFloat) -> AVAssetImageGenerator {
        if let g = generators[path] { return g }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: MediaLibrary.resolve(path)))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: height * 2, height: height * 2)
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generators[path] = g
        return g
    }
}

struct ThumbnailImage: View {
    let path: String
    let seconds: Double
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.panelRaised
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .clipped()
        .task(id: "\(path)\(Int(seconds * 4))") {
            image = await ThumbnailCache.shared.image(path: path, at: seconds)
        }
    }
}
