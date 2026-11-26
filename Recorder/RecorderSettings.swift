import SwiftUI
import AVFoundation

/// Video codec for recorded takes. HEVC is smaller at the same quality; H.264 plays everywhere.
enum RecordCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC"
    case h264 = "H.264"

    var id: String { rawValue }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
    var detail: String {
        self == .hevc ? "Smaller files, same quality. Accepted by TikTok, Instagram and Facebook."
                      : "Largest compatibility with older apps and computers."
    }
}

extension ExportQuality {
    /// Recording bitrate. HEVC needs about 30% less for the same look.
    func recordingBitrate(_ codec: RecordCodec) -> Int {
        codec == .hevc ? Int(Double(bitrate) * 0.7) : bitrate
    }
}

/// Recorder preferences, saved between launches.
final class RecorderSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var canvas: CanvasFormat { didSet { defaults.set(canvas.rawValue, forKey: Keys.canvas) } }
    @Published var quality: ExportQuality { didSet { defaults.set(quality.rawValue, forKey: Keys.quality) } }
    @Published var codec: RecordCodec { didSet { defaults.set(codec.rawValue, forKey: Keys.codec) } }
    @Published var useFrontCamera: Bool { didSet { defaults.set(useFrontCamera, forKey: Keys.front) } }
    /// Seconds of countdown before recording starts. 0 turns it off.
    @Published var countdown: Int { didSet { defaults.set(countdown, forKey: Keys.countdown) } }
    /// Scroll speed in points per second.
    @Published var scrollSpeed: Double { didSet { defaults.set(scrollSpeed, forKey: Keys.speed) } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.font) } }
    @Published var mirrorText: Bool { didSet { defaults.set(mirrorText, forKey: Keys.mirror) } }
    /// Darkness behind the script, 0 to 1.
    @Published var prompterOpacity: Double { didSet { defaults.set(prompterOpacity, forKey: Keys.opacity) } }
    /// Share of the screen height the script takes up.
    @Published var prompterHeight: Double { didSet { defaults.set(prompterHeight, forKey: Keys.height) } }
    @Published var showGrid: Bool { didSet { defaults.set(showGrid, forKey: Keys.grid) } }
    @Published var scrollStartsWithRecording: Bool { didSet { defaults.set(scrollStartsWithRecording, forKey: Keys.autoScroll) } }
    @Published var centerText: Bool { didSet { defaults.set(centerText, forKey: Keys.center) } }
    /// Scroll follows your voice instead of a fixed speed.
    @Published var followVoice: Bool { didSet { defaults.set(followVoice, forKey: Keys.followVoice) } }
    /// Script in a narrow band right next to the lens, so your eyes stay on the viewer.
    @Published var eyeContactLayout: Bool { didSet { defaults.set(eyeContactLayout, forKey: Keys.eyeContact) } }
    /// Record the script one paragraph at a time and join the best take of each.
    @Published var recordBySection: Bool { didSet { defaults.set(recordBySection, forKey: Keys.bySection) } }

    static let speedRange: ClosedRange<Double> = 10...400
    static let fontRange: ClosedRange<Double> = 18...96
    static let countdownChoices = [0, 3, 5, 10]

    init() {
        let d = UserDefaults.standard
        // The recorder offers 9:16 and 16:9 only.
        let savedCanvas = CanvasFormat(rawValue: d.string(forKey: Keys.canvas) ?? "") ?? .vertical
        canvas = savedCanvas == .horizontal ? .horizontal : .vertical
        quality = ExportQuality(rawValue: d.string(forKey: Keys.quality) ?? "") ?? .uhd4K
        codec = RecordCodec(rawValue: d.string(forKey: Keys.codec) ?? "") ?? .hevc
        useFrontCamera = d.object(forKey: Keys.front) as? Bool ?? true
        countdown = d.object(forKey: Keys.countdown) as? Int ?? 3
        scrollSpeed = d.object(forKey: Keys.speed) as? Double ?? 60
        fontSize = d.object(forKey: Keys.font) as? Double ?? 34
        mirrorText = d.bool(forKey: Keys.mirror)
        prompterOpacity = d.object(forKey: Keys.opacity) as? Double ?? 0.55
        prompterHeight = d.object(forKey: Keys.height) as? Double ?? 0.36
        showGrid = d.bool(forKey: Keys.grid)
        scrollStartsWithRecording = d.object(forKey: Keys.autoScroll) as? Bool ?? true
        centerText = d.object(forKey: Keys.center) as? Bool ?? true
        followVoice = d.object(forKey: Keys.followVoice) as? Bool ?? true
        eyeContactLayout = d.object(forKey: Keys.eyeContact) as? Bool ?? true
        recordBySection = d.bool(forKey: Keys.bySection)
    }

    func adjustSpeed(by delta: Double) {
        scrollSpeed = min(max(scrollSpeed + delta, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    func setFontSize(_ value: Double) {
        fontSize = min(max(value, Self.fontRange.lowerBound), Self.fontRange.upperBound).rounded()
    }

    private enum Keys {
        static let canvas = "rec.canvas", quality = "rec.quality", codec = "rec.codec", front = "rec.front"
        static let countdown = "rec.countdown", speed = "rec.speed", font = "rec.font", mirror = "rec.mirror"
        static let opacity = "rec.opacity", height = "rec.height", grid = "rec.grid"
        static let autoScroll = "rec.autoScroll", center = "rec.center"
        static let followVoice = "rec.followVoice", eyeContact = "rec.eyeContact", bySection = "rec.bySection"
    }
}
