import Foundation

/// Where a finished video gets posted.
enum SocialPlatform: String, Codable, CaseIterable, Identifiable {
    case tiktok, instagram, facebook

    var id: String { rawValue }
    var name: String {
        switch self {
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .facebook: return "Facebook"
        }
    }
    var symbol: String {
        switch self {
        case .tiktok: return "music.note"
        case .instagram: return "camera"
        case .facebook: return "f.square"
        }
    }
    /// The editor's caption writer for this platform.
    var copyPlatform: PostCopy.Platform {
        switch self {
        case .tiktok: return .tiktok
        case .instagram: return .instagram
        case .facebook: return .facebook
        }
    }
    /// Video shapes this platform shows best, preferred first.
    var formats: [CanvasFormat] {
        switch self {
        case .tiktok, .instagram: return [.vertical, .portrait, .square, .horizontal]
        case .facebook: return [.vertical, .horizontal, .portrait, .square]
        }
    }
    /// Caption length the platform accepts.
    var captionLimit: Int { self == .facebook ? 63_206 : 2_200 }
}

/// Views and engagement for one post, entered by hand until platform access is approved.
struct PostStats: Codable, Hashable {
    var views = 0
    var likes = 0
    var comments = 0
    var shares = 0
    var saves = 0
    var updatedAt = Date()

    var interactions: Int { likes + comments + shares + saves }
    /// Interactions per view.
    var engagement: Double { views > 0 ? Double(interactions) / Double(views) : 0 }
}

/// One platform's version of a planned post.
struct PlatformPost: Codable, Hashable, Identifiable {
    var platform: SocialPlatform
    var caption = ""
    var postedAt: Date?
    var link = ""
    var stats: PostStats?

    var id: SocialPlatform { platform }
    var isPosted: Bool { postedAt != nil }
}

/// An exported video file kept for posting, one per shape.
struct PostVideo: Codable, Hashable {
    var format: CanvasFormat
    /// Path relative to Documents.
    var path: String
    /// The Photos asset made from this file, so posting to three apps saves it once.
    var photosID: String?

    var url: URL { MediaLibrary.resolve(path) }
}

/// A post on the content calendar: an idea, or a finished video waiting to go out.
struct PostPlan: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var scheduledAt: Date
    var remind = true
    var projectID: UUID?
    var videos: [PostVideo] = []
    var posts: [PlatformPost]
    var notes = ""
    /// Video length in seconds, for insights.
    var duration: Double?
    /// What the video says (script or transcript), for the hook and insights.
    var script: String?
    var created = Date()

    var isPosted: Bool { !posts.isEmpty && posts.allSatisfy(\.isPosted) }
    var isPartlyPosted: Bool { posts.contains(where: \.isPosted) && !isPosted }
    var hasVideo: Bool { !videos.isEmpty }
    var isOverdue: Bool { !isPosted && scheduledAt < Date() }
    var platforms: [SocialPlatform] { posts.map(\.platform) }

    /// The best file for a platform's preferred shape.
    func video(for platform: SocialPlatform) -> PostVideo? {
        for f in platform.formats {
            if let v = videos.first(where: { $0.format == f }) { return v }
        }
        return nil
    }

    /// The opening line: first sentence of the script, else the first caption line.
    var hook: String {
        if let s = script, let first = Self.firstSentence(s) { return first }
        let caption = posts.first { !$0.caption.isEmpty }?.caption ?? ""
        return caption.split(separator: "\n").first.map(String.init) ?? ""
    }

    static func firstSentence(_ text: String) -> String? {
        var out: String?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sub, _, _, stop in
            let s = (sub ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out = s; stop = true }
        }
        return out
    }

    static func new(title: String, at date: Date, platforms: [SocialPlatform] = SocialPlatform.allCases) -> PostPlan {
        PostPlan(title: title, scheduledAt: date, posts: platforms.map { PlatformPost(platform: $0) })
    }

    /// Next whole hour from now, a sensible default slot.
    static var nextSlot: Date {
        let cal = Calendar.current
        let hour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        return cal.date(byAdding: .hour, value: 1, to: hour) ?? Date()
    }
}

/// Saves the content calendar as JSON in Documents/Posts, along with the videos kept for posting.
@MainActor
final class PostStore: ObservableObject {
    static let shared = PostStore()
    @Published private(set) var plans: [PostPlan] = []

    static var folder: URL {
        let url = MediaLibrary.documents.appendingPathComponent("Posts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var file: URL { Self.folder.appendingPathComponent("plans.json") }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: file),
              let list = try? decoder.decode([PostPlan].self, from: data) else { plans = []; return }
        plans = list.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    func plan(_ id: UUID) -> PostPlan? { plans.first { $0.id == id } }

    func save(_ plan: PostPlan) {
        if let i = plans.firstIndex(where: { $0.id == plan.id }) { plans[i] = plan } else { plans.append(plan) }
        plans.sort { $0.scheduledAt < $1.scheduledAt }
        persist()
        PostReminders.shared.update(plan)
    }

    func delete(_ plan: PostPlan) {
        plans.removeAll { $0.id == plan.id }
        persist()
        PostReminders.shared.cancel(plan.id)
        let base = Self.folder.standardizedFileURL.path
        for v in plan.videos where v.url.standardizedFileURL.path.hasPrefix(base) {
            try? FileManager.default.removeItem(at: v.url)
        }
    }

    func plans(on day: Date) -> [PostPlan] {
        let cal = Calendar.current
        return plans.filter { cal.isDate($0.scheduledAt, inSameDayAs: day) }
    }

    /// Keeps a copy of an export for posting, so a later re-export doesn't change a planned post.
    /// On the iPhone's file system the copy is a clone, so it takes no extra space until one changes.
    func keepVideo(_ url: URL, format: CanvasFormat) throws -> PostVideo {
        let dest = MediaLibrary.newFile(in: Self.folder, ext: url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: dest)
        return PostVideo(format: format, path: MediaLibrary.relativePath(dest))
    }

    private func persist() {
        guard let data = try? encoder.encode(plans) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
