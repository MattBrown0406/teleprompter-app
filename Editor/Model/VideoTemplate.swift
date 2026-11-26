import Foundation

/// How captions look, saved in a template so a new take gets the same captions automatically.
struct CaptionPreset: Codable, Equatable, Hashable {
    var look: CaptionLook = .highlight
    var style = TextStyle()
    var y = 0.7
    var maxWords = 4
    var uppercase = true

    /// Reads the style off a project's existing captions.
    init?(captionsOf p: EditProject) {
        let caps = p.texts.filter(\.isCaption).sorted { $0.start < $1.start }
        guard let first = caps.first else { return nil }
        look = first.look ?? .plain
        style = first.style
        y = first.center.y
        let counts = caps.map { $0.words?.count ?? $0.text.split(separator: " ").count }
        maxWords = min(8, max(1, counts.max() ?? 4))
        uppercase = caps.allSatisfy { $0.text == $0.text.uppercased() }
    }

    var options: Captioner.Options {
        var o = Captioner.Options()
        o.look = look
        o.style = style
        o.y = y
        o.maxWords = maxWords
        o.uppercase = uppercase
        return o
    }
}

/// A finished edit's look, captions, music and brand, saved to put on a new take in one tap.
struct VideoTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    var canvas: CanvasFormat
    var background: CanvasBackground = .blur
    var autoReframe: Bool?
    // Look (from the first clip of the talking head)
    var filter: FilterKind = .none
    var filterAmount = 1.0
    var adjust = Adjustments()
    var fit: ClipFit = .fill
    var zoom = 1.0
    var transition: TransitionKind = .none
    var transitionDuration = 0.5
    // Captions
    var captions: CaptionPreset?
    // Music (whole-video beds)
    var music: [AudioItem] = []
    // Brand
    var logo: LogoOverlay?
    var intro: ClipItem?
    var outro: ClipItem?
    /// On-screen text that isn't captions (a call to action, a title). Times count from the start,
    /// or back from the end for text in the second half.
    var texts: [TemplateText] = []

    struct TemplateText: Codable, Equatable {
        var item: TextItem
        var fromEnd: Bool
    }

    struct Parts: Equatable {
        var look = true
        var captions = true
        var music = true
        var brand = true
        var text = false
    }

    /// Captures a project. Parts that are off are left empty.
    init(name: String, from p: EditProject, parts: Parts) {
        self.name = name
        canvas = p.canvas
        background = p.background
        autoReframe = p.autoReframe
        let body = p.clips.filter { !$0.isBrandClip }
        if parts.look, let c = body.first {
            filter = c.filter
            filterAmount = c.filterAmount
            adjust = c.adjust
            fit = c.fit
            zoom = c.zoom
            if let t = body.dropLast().first(where: { $0.transitionOut != .none }) {
                transition = t.transitionOut
                transitionDuration = t.transitionDuration
            }
        }
        if parts.captions { captions = CaptionPreset(captionsOf: p) }
        if parts.music {
            music = p.audio.filter { $0.kind == .music }
        }
        if parts.brand {
            logo = p.logo
            intro = p.clips.first { $0.role == .intro }
            outro = p.clips.first { $0.role == .outro }
        }
        if parts.text {
            let d = p.duration
            texts = p.texts.filter { !$0.isCaption }.map { t in
                var t = t
                let fromEnd = t.start > d / 2
                if fromEnd { t.start -= d; t.end -= d }   // negative: seconds before the end
                return TemplateText(item: t, fromEnd: fromEnd)
            }
        }
    }

    /// Every media file the template needs, as stored paths (so deleting a project keeps them).
    var files: Set<String> {
        var out = Set(music.map(\.path))
        if let l = logo?.path { out.insert(l) }
        if let i = intro?.path { out.insert(i) }
        if let o = outro?.path { out.insert(o) }
        return out
    }

    /// Puts the template on a project. Clip lengths must be known (sourceDuration filled in).
    func apply(to p: inout EditProject) {
        p.canvas = canvas
        p.background = background
        if let autoReframe { p.autoReframe = autoReframe }

        // Brand clips: swap for the template's (and shift timed items by the change in intro length).
        if intro != nil || outro != nil || logo != nil {
            let oldIntro = p.clips.first?.role == .intro ? p.clips[0].outputDuration : 0
            p.clips.removeAll { $0.isBrandClip }
            var newIntro = 0.0
            if var c = intro, FileManager.default.fileExists(atPath: c.url.path) {
                c.id = UUID()
                p.clips.insert(c, at: 0)
                newIntro = c.outputDuration
            }
            if var c = outro, FileManager.default.fileExists(atPath: c.url.path) {
                c.id = UUID()
                p.clips.append(c)
            }
            let shift = newIntro - oldIntro
            if abs(shift) > 0.001 {
                for i in p.texts.indices {
                    p.texts[i].start = max(0, p.texts[i].start + shift)
                    p.texts[i].end = max(p.texts[i].start + 0.2, p.texts[i].end + shift)
                }
                for i in p.audio.indices where p.audio[i].kind != .music { p.audio[i].start = max(0, p.audio[i].start + shift) }
                if var o = p.overlays { for i in o.indices { o[i].start = max(0, o[i].start + shift) }; p.overlays = o }
            }
            p.logo = logo
        }

        let bodyIndices = p.clips.indices.filter { !p.clips[$0].isBrandClip }
        for (k, i) in bodyIndices.enumerated() {
            p.clips[i].filter = filter
            p.clips[i].filterAmount = filterAmount
            p.clips[i].adjust = adjust
            p.clips[i].fit = fit
            p.clips[i].zoom = zoom
            if k < bodyIndices.count - 1 {
                p.clips[i].transitionOut = transition
                p.clips[i].transitionDuration = transitionDuration
            }
        }

        let d = p.duration
        if !music.isEmpty {
            p.audio.removeAll { $0.kind == .music }
            for m in music {
                var m = m
                m.id = UUID()
                m.start = 0
                m.loop = m.loop || m.sourceDuration - m.sourceStart < d
                m.duration = m.loop ? d : min(d, m.sourceDuration - m.sourceStart)
                if FileManager.default.fileExists(atPath: m.url.path), m.duration > 0.2 { p.audio.append(m) }
            }
        }

        for t in texts {
            var item = t.item
            item.id = UUID()
            if t.fromEnd { item.start += d; item.end += d }
            item.start = max(0, item.start)
            item.end = min(d, item.end)
            if item.end - item.start > 0.2 { p.texts.append(item) }
        }

        if let captions {
            if p.texts.contains(where: \.isCaption) {
                for i in p.texts.indices where p.texts[i].isCaption {
                    p.texts[i].style = captions.style
                    p.texts[i].look = captions.look
                    p.texts[i].center.y = captions.y
                }
            } else {
                p.pendingCaptions = captions
            }
        }
    }
}

/// Saved templates (Documents/Templates.json) and which one new videos get automatically.
@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()
    @Published private(set) var templates: [VideoTemplate] = []
    @Published var defaultID: UUID? {
        didSet { UserDefaults.standard.set(defaultID?.uuidString, forKey: Self.defaultKey) }
    }

    nonisolated private static let defaultKey = "templates.default"
    nonisolated private static var fileURL: URL { MediaLibrary.documents.appendingPathComponent("Templates.json") }

    private init() {
        templates = Self.load()
        defaultID = Self.defaultTemplateID
    }

    /// The template new videos get, readable from any thread. Nil if none or it was deleted.
    nonisolated static var defaultTemplateID: UUID? {
        guard let s = UserDefaults.standard.string(forKey: defaultKey), let id = UUID(uuidString: s) else { return nil }
        return load().contains { $0.id == id } ? id : nil
    }

    nonisolated static func template(_ id: UUID) -> VideoTemplate? { load().first { $0.id == id } }

    /// Media files any template uses.
    nonisolated static var allFiles: Set<String> { load().reduce(into: Set<String>()) { $0.formUnion($1.files) } }

    nonisolated private static func load() -> [VideoTemplate] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([VideoTemplate].self, from: data)) ?? []
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(templates) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    func add(_ t: VideoTemplate) {
        templates.insert(t, at: 0)
        save()
    }

    func delete(_ t: VideoTemplate) {
        templates.removeAll { $0.id == t.id }
        if defaultID == t.id { defaultID = nil }
        save()
    }

    func rename(_ t: VideoTemplate, to name: String) {
        guard let i = templates.firstIndex(where: { $0.id == t.id }) else { return }
        templates[i].name = name
        save()
    }
}
