import Foundation

/// A photo or video shown over the talking head (B-roll / cutaway). The main clip's sound keeps playing.
struct OverlayItem: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable { case photo, video }

    enum Layout: String, Codable, CaseIterable, Identifiable {
        /// B-roll fills the screen.
        case full
        /// B-roll in a box in the top corner, you stay full screen.
        case corner
        /// B-roll fills the screen and you stay visible in a small circle (good for screen recordings).
        case speakerBubble
        var id: String { rawValue }
        var label: String {
            switch self {
            case .full: return "Full screen"
            case .corner: return "In a box"
            case .speakerBubble: return "You in a bubble"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// Path relative to Documents.
    var path: String
    /// Timeline seconds.
    var start: Double
    var duration: Double
    /// Where a video overlay starts playing inside its own file.
    var sourceStart: Double = 0
    /// Length of the video file (0 for photos).
    var sourceDuration: Double = 0
    var layout: Layout = .full
    /// Quick fade in and out.
    var fade = true
    /// Slow push-in on photos so they don't look frozen.
    var motion = true
    /// What the AI suggested showing here, if it came from a suggestion.
    var note: String?

    var url: URL { MediaLibrary.resolve(path) }
    var end: Double { start + duration }

    /// The longest this overlay can run from where it starts in its file.
    var maxDuration: Double { kind == .video ? max(0.2, sourceDuration - sourceStart) : 60 }
}

extension EditProject {
    var overlayItems: [OverlayItem] { overlays ?? [] }

    /// Converts a time inside a clip's source file to timeline time (nil if trimmed away).
    func timelineTime(clip index: Int, sourceTime: Double) -> Double? {
        guard clips.indices.contains(index) else { return nil }
        let c = clips[index]
        guard sourceTime >= c.trimStart - 0.001, sourceTime <= c.effectiveTrimEnd + 0.001 else { return nil }
        return clipStarts[index] + (sourceTime - c.trimStart) / c.speed
    }
}
