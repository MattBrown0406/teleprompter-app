import Foundation
import CoreText
import UIKit

/// Saved once, applied to any video: logo, colours, font, intro and outro.
struct BrandKit: Codable, Equatable {
    var name = "My brand"
    var logoPath: String?
    var logoCorner: LogoCorner = .topRight
    var logoSize = 0.18
    var logoOpacity = 0.9
    /// Caption highlight and accents.
    var accent = RGBA(r: 1, g: 0.86, b: 0.1)
    /// Box and pill backgrounds.
    var primary = RGBA(r: 1, g: 0.42, b: 0.36)
    var textColor = RGBA(r: 1, g: 1, b: 1)
    var font: TextFont = .bold
    var customFontPath: String?
    var customFontName: String?
    var introPath: String?
    var introDuration = 0.0
    var outroPath: String?
    var outroDuration = 0.0
    /// Put the brand on every new video automatically.
    var autoApply = false

    var colors: [RGBA] { [accent, primary, textColor] }
    var hasLogo: Bool { logoPath != nil }

    init() {}

    // Tolerant decoding so adding a field later never wipes a saved kit.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrandKit()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? d.name
        logoPath = try? c.decodeIfPresent(String.self, forKey: .logoPath)
        logoCorner = (try? c.decodeIfPresent(LogoCorner.self, forKey: .logoCorner)) ?? d.logoCorner
        logoSize = (try? c.decodeIfPresent(Double.self, forKey: .logoSize)) ?? d.logoSize
        logoOpacity = (try? c.decodeIfPresent(Double.self, forKey: .logoOpacity)) ?? d.logoOpacity
        accent = (try? c.decodeIfPresent(RGBA.self, forKey: .accent)) ?? d.accent
        primary = (try? c.decodeIfPresent(RGBA.self, forKey: .primary)) ?? d.primary
        textColor = (try? c.decodeIfPresent(RGBA.self, forKey: .textColor)) ?? d.textColor
        font = (try? c.decodeIfPresent(TextFont.self, forKey: .font)) ?? d.font
        customFontPath = try? c.decodeIfPresent(String.self, forKey: .customFontPath)
        customFontName = try? c.decodeIfPresent(String.self, forKey: .customFontName)
        introPath = try? c.decodeIfPresent(String.self, forKey: .introPath)
        introDuration = (try? c.decodeIfPresent(Double.self, forKey: .introDuration)) ?? 0
        outroPath = try? c.decodeIfPresent(String.self, forKey: .outroPath)
        outroDuration = (try? c.decodeIfPresent(Double.self, forKey: .outroDuration)) ?? 0
        autoApply = (try? c.decodeIfPresent(Bool.self, forKey: .autoApply)) ?? false
    }

    struct Parts: Equatable {
        var logo = true
        var intro = true
        var outro = true
        var text = true
    }

    /// Adds or refreshes the brand on a project. Calling it again replaces the old intro/outro.
    func apply(to p: inout EditProject, parts: Parts = Parts()) {
        // Intro: replace any existing one and shift everything that was timed after it.
        let oldIntro = p.clips.first?.role == .intro ? p.clips[0].outputDuration : 0
        p.clips.removeAll { $0.isBrandClip }
        var shift = -oldIntro
        if parts.intro, let introPath, FileManager.default.fileExists(atPath: MediaLibrary.resolve(introPath).path) {
            var c = ClipItem(url: MediaLibrary.resolve(introPath))
            c.sourceDuration = introDuration
            c.role = .intro
            p.clips.insert(c, at: 0)
            shift += introDuration
        }
        if parts.outro, let outroPath, FileManager.default.fileExists(atPath: MediaLibrary.resolve(outroPath).path) {
            var c = ClipItem(url: MediaLibrary.resolve(outroPath))
            c.sourceDuration = outroDuration
            c.role = .outro
            p.clips.append(c)
        }
        if abs(shift) > 0.001 {
            for i in p.texts.indices {
                p.texts[i].start = max(0, p.texts[i].start + shift)
                p.texts[i].end = max(p.texts[i].start + 0.2, p.texts[i].end + shift)
            }
            for i in p.audio.indices where p.audio[i].kind != .music {
                p.audio[i].start = max(0, p.audio[i].start + shift)
            }
        }
        if parts.logo, let logoPath {
            p.logo = LogoOverlay(path: logoPath, corner: logoCorner, size: logoSize, opacity: logoOpacity)
        } else {
            p.logo = nil
        }
        if parts.text {
            for i in p.texts.indices {
                p.texts[i].style.font = font
                p.texts[i].style.customFont = customFontName
                p.texts[i].style.color = textColor
                p.texts[i].style.highlightColor = accent
                p.texts[i].style.backgroundColor = RGBA(r: primary.r, g: primary.g, b: primary.b, a: 0.85)
            }
        }
    }

    /// Removes the brand intro, outro and logo.
    static func remove(from p: inout EditProject) {
        let oldIntro = p.clips.first?.role == .intro ? p.clips[0].outputDuration : 0
        p.clips.removeAll { $0.isBrandClip }
        p.logo = nil
        if oldIntro > 0 {
            for i in p.texts.indices {
                p.texts[i].start = max(0, p.texts[i].start - oldIntro)
                p.texts[i].end = max(p.texts[i].start + 0.2, p.texts[i].end - oldIntro)
            }
            for i in p.audio.indices where p.audio[i].kind != .music {
                p.audio[i].start = max(0, p.audio[i].start - oldIntro)
            }
        }
    }

    static func applyIfAutomatic(to p: inout EditProject) {
        guard let kit = BrandStore.current, kit.autoApply else { return }
        kit.apply(to: &p)
    }
}

/// Reads and writes the brand kit (Documents/BrandKit.json) and installs its font.
@MainActor
final class BrandStore: ObservableObject {
    static let shared = BrandStore()
    @Published var kit: BrandKit? {
        didSet { save() }
    }

    private init() {
        kit = Self.load()
        Self.registerFont(kit)
    }

    nonisolated private static var fileURL: URL { MediaLibrary.documents.appendingPathComponent("BrandKit.json") }

    /// The saved kit, readable from any thread (render code, project creation).
    nonisolated static var current: BrandKit? {
        let kit = load()
        registerFont(kit)
        return kit
    }

    nonisolated private static func load() -> BrandKit? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BrandKit.self, from: data)
    }

    private func save() {
        if let kit, let data = try? JSONEncoder().encode(kit) {
            try? data.write(to: Self.fileURL, options: .atomic)
        } else if kit == nil {
            try? FileManager.default.removeItem(at: Self.fileURL)
        }
        Self.registerFont(kit)
    }

    /// Makes an imported .ttf/.otf usable by name in this app session.
    nonisolated static func registerFont(_ kit: BrandKit?) {
        guard let path = kit?.customFontPath else { return }
        let url = MediaLibrary.resolve(path)
        if let name = kit?.customFontName, UIFont(name: name, size: 12) != nil { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Copies a font file in, installs it and returns its PostScript name.
    nonisolated static func importFont(from url: URL) -> (path: String, name: String)? {
        guard let local = MediaImport.copyIn(url) else { return nil }
        guard let provider = CGDataProvider(url: local as CFURL), let cg = CGFont(provider),
              let cfName = cg.postScriptName else { return nil }
        let name = cfName as String
        CTFontManagerRegisterFontsForURL(local as CFURL, .process, nil)
        return (MediaLibrary.relativePath(local), name)
    }
}
