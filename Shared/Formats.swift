import CoreGraphics
import AVFoundation

/// Output canvas shape. Shared by recorder and editor.
enum CanvasFormat: String, Codable, CaseIterable, Identifiable {
    case vertical = "9:16"
    case square = "1:1"
    case portrait = "4:5"
    case horizontal = "16:9"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .vertical: return "9:16  TikTok, Reels, Stories"
        case .square: return "1:1  Feed"
        case .portrait: return "4:5  Instagram feed"
        case .horizontal: return "16:9  YouTube, Facebook"
        }
    }
    var shortLabel: String { rawValue }
    /// True when taller than wide (9:16, 4:5). Square counts as portrait for capture.
    var isPortrait: Bool { self != .horizontal }
    var aspect: CGFloat {
        switch self {
        case .vertical: return 9.0 / 16.0
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        case .horizontal: return 16.0 / 9.0
        }
    }

    /// Render size in pixels for a quality. The short side is 1080 or 2160.
    func renderSize(_ quality: ExportQuality) -> CGSize {
        let short = quality.shortSide
        switch self {
        case .vertical: return CGSize(width: short, height: short * 16 / 9)
        case .square: return CGSize(width: short, height: short)
        case .portrait: return CGSize(width: short, height: short * 5 / 4)
        case .horizontal: return CGSize(width: short * 16 / 9, height: short)
        }
    }
}

enum ExportQuality: String, Codable, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case uhd4K = "4K"

    var id: String { rawValue }
    var shortSide: CGFloat { self == .hd1080 ? 1080 : 2160 }
    /// Target average bitrate, bits per second (HEVC is about 40% smaller at the same look).
    var bitrate: Int { self == .hd1080 ? 16_000_000 : 50_000_000 }
}

enum Video {
    static let frameRate: Int32 = 30
    static let frameDuration = CMTime(value: 1, timescale: frameRate)
}
