import Foundation
import CoreGraphics
import CoreMedia

/// A whole edit. Plain Codable value so undo/redo is just keeping old copies.
struct EditProject: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var modified = Date()
    var canvas: CanvasFormat
    var quality: ExportQuality
    var background: CanvasBackground = .blur
    var clips: [ClipItem] = []
    var texts: [TextItem] = []
    var audio: [AudioItem] = []

    static func new(clips urls: [URL], canvas: CanvasFormat, quality: ExportQuality) -> EditProject {
        let df = DateFormatter()
        df.dateFormat = "MMM d, h:mm a"
        var p = EditProject(name: "Video \(df.string(from: Date()))", canvas: canvas, quality: quality)
        p.clips = urls.map { ClipItem(url: $0) }
        return p
    }

    // MARK: Timeline math (seconds)

    /// Where each clip starts on the output timeline. Transitions overlap neighbouring clips.
    var clipStarts: [Double] {
        var starts: [Double] = []
        var t = 0.0
        for (i, c) in clips.enumerated() {
            starts.append(t)
            t += c.outputDuration
            if i < clips.count - 1 { t -= transitionDuration(after: i) }
        }
        return starts
    }

    var duration: Double {
        guard let last = clips.indices.last else { return 0 }
        return clipStarts[last] + clips[last].outputDuration
    }

    /// The effective overlap after clip i, clamped so a transition never eats more than half of either clip.
    func transitionDuration(after i: Int) -> Double {
        guard i < clips.count - 1, clips[i].transitionOut != .none else { return 0 }
        let maxLen = min(clips[i].outputDuration, clips[i + 1].outputDuration) / 2
        return min(clips[i].transitionDuration, maxLen)
    }

    /// Clip index under a timeline time, and the time inside that clip's output.
    func clipIndex(at time: Double) -> Int? {
        let starts = clipStarts
        for i in clips.indices.reversed() where time >= starts[i] - 0.0001 {
            return i
        }
        return clips.isEmpty ? nil : 0
    }
}

enum CanvasBackground: Codable, Equatable, Hashable {
    case blur
    case color(RGBA)

    static let black = CanvasBackground.color(RGBA(r: 0, g: 0, b: 0))
    static let white = CanvasBackground.color(RGBA(r: 1, g: 1, b: 1))
}

struct ClipItem: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    /// Path relative to Documents (see MediaLibrary.relativePath).
    var path: String
    /// Full source length, filled in when the asset is first loaded.
    var sourceDuration: Double = 0
    var trimStart: Double = 0
    var trimEnd: Double = 0           // 0 means "end of source"
    var speed: Double = 1
    var volume: Float = 1
    var filter: FilterKind = .none
    var filterAmount: Double = 1
    var adjust = Adjustments()
    var fit: ClipFit = .fill
    var zoom: Double = 1              // extra scale on top of fit
    var offset = NPoint.zero         // pan, in fractions of canvas size
    var rotation: Int = 0             // extra quarter turns
    var mirrored = false
    var transitionOut: TransitionKind = .none
    var transitionDuration: Double = 0.5

    init(url: URL) { path = MediaLibrary.relativePath(url) }

    var url: URL { MediaLibrary.resolve(path) }
    var effectiveTrimEnd: Double { trimEnd > 0 ? min(trimEnd, sourceDuration) : sourceDuration }
    var trimmedDuration: Double { max(0, effectiveTrimEnd - trimStart) }
    var outputDuration: Double { trimmedDuration / speed }
}

enum ClipFit: String, Codable, CaseIterable { case fill, fit }

struct Adjustments: Codable, Equatable, Hashable {
    var brightness: Double = 0   // -0.5...0.5
    var contrast: Double = 1     // 0.5...1.5
    var saturation: Double = 1   // 0...2
    var warmth: Double = 0       // -1...1
    var vignette: Double = 0     // 0...1
    var sharpen: Double = 0      // 0...1

    var isIdentity: Bool { self == Adjustments() }
}

enum FilterKind: String, Codable, CaseIterable, Identifiable {
    case none, vivid, warmGlow, coolBlue, mono, noir, fade, film, dusk, mint, punch, sepia
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Original"
        case .vivid: return "Vivid"
        case .warmGlow: return "Warm"
        case .coolBlue: return "Cool"
        case .mono: return "Mono"
        case .noir: return "Noir"
        case .fade: return "Fade"
        case .film: return "Film"
        case .dusk: return "Dusk"
        case .mint: return "Mint"
        case .punch: return "Punch"
        case .sepia: return "Sepia"
        }
    }
}

enum TransitionKind: String, Codable, CaseIterable, Identifiable {
    case none, crossfade, fadeBlack, fadeWhite, slideLeft, slideUp, wipe, zoom, blur
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Cut"
        case .crossfade: return "Dissolve"
        case .fadeBlack: return "Dip black"
        case .fadeWhite: return "Dip white"
        case .slideLeft: return "Slide"
        case .slideUp: return "Push up"
        case .wipe: return "Wipe"
        case .zoom: return "Zoom"
        case .blur: return "Blur"
        }
    }
    var symbol: String {
        switch self {
        case .none: return "scissors"
        case .crossfade: return "circle.lefthalf.filled"
        case .fadeBlack: return "moon.fill"
        case .fadeWhite: return "sun.max.fill"
        case .slideLeft: return "arrow.left.square"
        case .slideUp: return "arrow.up.square"
        case .wipe: return "rectangle.righthalf.inset.filled"
        case .zoom: return "plus.magnifyingglass"
        case .blur: return "drop"
        }
    }
}

struct TextItem: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var text: String
    var start: Double                 // timeline seconds
    var end: Double
    var center = NPoint(x: 0.5, y: 0.8)  // fraction of canvas
    var scale: Double = 1
    var rotation: Double = 0          // degrees
    var style = TextStyle()
    var isCaption = false
    var animation: TextAnimation = .fade

    var duration: Double { end - start }
}

struct TextStyle: Codable, Equatable, Hashable {
    var font: TextFont = .bold
    /// Font size as a fraction of canvas width, so 1080p and 4K look the same.
    var size: Double = 0.07
    var color = RGBA(r: 1, g: 1, b: 1)
    var background: TextBackground = .none
    var backgroundColor = RGBA(r: 0, g: 0, b: 0, a: 0.6)
    var outline = false
    var shadow = true
    var alignment: TextAlign = .center
}

enum TextFont: String, Codable, CaseIterable, Identifiable {
    case bold, rounded, serif, mono, condensed, light
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum TextBackground: String, Codable, CaseIterable { case none, box, pill }
enum TextAlign: String, Codable, CaseIterable { case leading, center, trailing }
enum TextAnimation: String, Codable, CaseIterable, Identifiable {
    case none, fade, pop, slideUp, typewriter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .slideUp: return "Rise"
        case .typewriter: return "Type"
        }
    }
}

struct AudioItem: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable { case music, voiceover, effect }
    var id = UUID()
    var kind: Kind
    var name: String
    var path: String
    var sourceDuration: Double
    var start: Double                 // timeline seconds
    var sourceStart: Double = 0
    var duration: Double
    var volume: Float = 0.8
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var loop = false

    var url: URL { MediaLibrary.resolve(path) }
    var end: Double { start + duration }
}

struct RGBA: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let palette: [RGBA] = [
        .init(r: 1, g: 1, b: 1), .init(r: 0, g: 0, b: 0),
        .init(r: 1, g: 0.42, b: 0.36), .init(r: 1, g: 0.8, b: 0.2),
        .init(r: 0.36, g: 0.78, b: 1), .init(r: 0.45, g: 0.9, b: 0.55),
        .init(r: 0.75, g: 0.5, b: 1), .init(r: 1, g: 0.45, b: 0.75),
    ]
}

/// Normalized point (0...1 of canvas). Own type so it is Codable and Hashable everywhere.
struct NPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    static let zero = NPoint(x: 0, y: 0)
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

extension Double {
    var cmTime: CMTime { CMTime(seconds: self, preferredTimescale: 600) }
    var timecode: String {
        let s = Swift.max(0, self)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let tenth = Int((s - floor(s)) * 10)
        return String(format: "%d:%02d.%d", m, sec, tenth)
    }
}
