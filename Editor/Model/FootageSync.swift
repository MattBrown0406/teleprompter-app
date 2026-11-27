import Foundation
import UIKit

/// Backs up the media files projects use (takes, imported clips, music, voiceovers, logos) to the
/// private Supabase Storage bucket `footage`, and downloads them again when a project comes back
/// without them (new phone, reinstall, or a file that went missing).
///
/// Wi-Fi only by default. Uploads are resumable (TUS, 6 MB chunks), so a 4K take that is
/// interrupted picks up where it stopped instead of starting over.
@MainActor
final class FootageSync: ObservableObject {
    static let shared = FootageSync()

    enum Status: Equatable {
        case off
        case idle
        case working(String)
        case done
        case waiting(String)
    }

    @Published private(set) var status: Status = .idle
    /// Bytes this account has in the bucket, as far as this phone knows.
    @Published private(set) var backedUpBytes: Int64 = 0
    @Published private(set) var pendingCount = 0

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "footage.enabled"); refreshStatus(); syncSoon(delay: 0) }
    }
    @Published var useCellular: Bool {
        didSet { UserDefaults.standard.set(useCellular, forKey: "footage.cellular"); session = Self.makeSession(cellular: useCellular); syncSoon(delay: 0) }
    }

    private struct State: Codable {
        var userID: String?
        /// Stored path -> size in bytes, for files already in the bucket.
        var uploaded: [String: Int64] = [:]
    }

    private var state: State
    private var session: URLSession
    private var waitTask: Task<Void, Never>?
    private var running = false
    private var again = false
    /// Paths the bucket doesn't have, so we don't ask again until next launch.
    private var notInCloud: Set<String> = []

    private static let bucket = "footage"
    private static let chunk = 6 * 1024 * 1024   // Supabase's required TUS chunk size

    private static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("footage-sync.json")
    }

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "footage.enabled") as? Bool ?? true
        let cellular = defaults.bool(forKey: "footage.cellular")
        useCellular = cellular
        session = Self.makeSession(cellular: cellular)
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: Self.stateURL))) ?? State()
        backedUpBytes = state.uploaded.values.reduce(0, +)
        refreshStatus()
    }

    private static func makeSession(cellular: Bool) -> URLSession {
        let c = URLSessionConfiguration.default
        c.allowsExpensiveNetworkAccess = cellular     // cellular and personal hotspot
        c.allowsConstrainedNetworkAccess = false      // Low Data Mode
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }

    private func refreshStatus() {
        if SupabaseConfig.current == nil { status = .off }
        else if !enabled { status = .off }
        else if case .off = status { status = .idle }
    }

    func syncSoon(delay: Double = 3) {
        guard enabled, SupabaseConfig.current != nil else { return }
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            if self.running { self.again = true; return }
            self.running = true
            Task { await self.run() }
        }
    }

    private func run() async {
        // Ask iOS for extra time so leaving the app doesn't cut an upload off mid-chunk.
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "footage-backup") {
            UIApplication.shared.endBackgroundTask(bg)
            bg = .invalid
        }
        defer {
            running = false
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        repeat {
            again = false
            do {
                try await pass()
                status = .done
            } catch {
                status = .waiting(Self.describe(error, cellular: useCellular))
                syncSoon(delay: 120)
                return
            }
        } while again && enabled
    }

    private static func describe(_ error: Error, cellular: Bool) -> String {
        if let u = error as? URLError {
            if u.networkUnavailableReason == .expensive || (!cellular && u.code == .notConnectedToInternet) {
                return "Waiting for Wi-Fi"
            }
            if u.networkUnavailableReason == .constrained { return "Paused by Low Data Mode" }
            return "Offline. Will continue when connected."
        }
        return error.localizedDescription
    }

    // MARK: Pass

    private func neededPaths() -> Set<String> {
        let store = ProjectStore.shared
        let all = store.projects.reduce(into: ProjectStore.brandFiles()) { $0.formUnion(ProjectStore.files(of: $1)) }
        // Takes not used in a project yet are backed up too.
        let takes = ((try? FileManager.default.contentsOfDirectory(at: MediaLibrary.recordings,
                                                                   includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { MediaLibrary.relativePath($0) }
        // Absolute paths point outside the app's folders and can't be restored to the same place.
        return all.union(takes).filter { !$0.hasPrefix("/") }
    }

    private func pass() async throws {
        guard enabled else { return }
        let (_, user) = try await SupabaseClient.shared.session()
        if state.userID != user {
            state = State(userID: user)
            notInCloud = []
            persist()
        }
        let needed = neededPaths()
        let fm = FileManager.default

        // 1. Upload what's on the phone and not in the bucket yet.
        var toUpload: [(path: String, size: Int64)] = []
        var toDownload: [String] = []
        for path in needed.sorted() {
            let url = MediaLibrary.resolve(path)
            if let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int64 {
                // Skip a file that is still being written (a take mid-recording, an export in progress).
                let recent = (attrs[.modificationDate] as? Date).map { Date().timeIntervalSince($0) < 30 } ?? false
                if state.uploaded[path] != size && !recent { toUpload.append((path, size)) }
            } else if !notInCloud.contains(path) {
                toDownload.append(path)
            }
        }
        pendingCount = toUpload.count + toDownload.count

        for (i, item) in toUpload.enumerated() {
            status = .working("Uploading \(i + 1) of \(toUpload.count)")
            try await upload(path: item.path, size: item.size, user: user) { [weak self] sent in
                self?.status = .working("Uploading \(i + 1) of \(toUpload.count) · \(Int(Double(sent) / Double(max(item.size, 1)) * 100))%")
            }
            state.uploaded[item.path] = item.size
            backedUpBytes = state.uploaded.values.reduce(0, +)
            pendingCount -= 1
            persist()
        }

        // 2. Bring back files projects need but the phone doesn't have.
        for (i, path) in toDownload.enumerated() {
            status = .working("Restoring \(i + 1) of \(toDownload.count)")
            if try await download(path: path, user: user) {
                if let size = (try? fm.attributesOfItem(atPath: MediaLibrary.resolve(path).path))?[.size] as? Int64 {
                    state.uploaded[path] = size
                }
            } else {
                notInCloud.insert(path)
            }
            pendingCount -= 1
            persist()
        }
        backedUpBytes = state.uploaded.values.reduce(0, +)

        // 3. Free cloud space for files that were deleted on the phone and no project uses.
        // A file still on the phone is kept, in case its project only went missing locally.
        let unused = Set(state.uploaded.keys).subtracting(needed)
            .filter { !fm.fileExists(atPath: MediaLibrary.resolve($0).path) }
        if !unused.isEmpty {
            status = .working("Cleaning up")
            var req = try await SupabaseClient.shared.storageRequest("object/\(Self.bucket)", method: "DELETE")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["prefixes": unused.map { "\(user)/\($0)" }])
            _ = try await SupabaseClient.send(req, using: session)
            for p in unused { state.uploaded[p] = nil }
            backedUpBytes = state.uploaded.values.reduce(0, +)
            persist()
        }
    }

    // MARK: Resumable upload (TUS)

    private func upload(path: String, size: Int64, user: String, progress: @escaping (Int64) -> Void) async throws {
        let fileURL = MediaLibrary.resolve(path)
        let object = "\(user)/\(path)"
        let resumeKey = "footage.tus.\(object).\(size)"
        let endpoint = try await SupabaseClient.shared.storageRequest("upload/resumable", method: "POST").url!

        var location = UserDefaults.standard.string(forKey: resumeKey).flatMap(URL.init(string:))
        var offset: Int64 = 0

        if let loc = location {
            var head = URLRequest(url: loc)
            head.httpMethod = "HEAD"
            head.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            try await SupabaseClient.shared.authorize(&head)
            if let result = try? await session.data(for: head), let http = result.1 as? HTTPURLResponse,
               http.statusCode == 200, let o = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init) {
                offset = o
            } else {
                location = nil
            }
        }

        if location == nil {
            var create = URLRequest(url: endpoint)
            create.httpMethod = "POST"
            create.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            create.setValue(String(size), forHTTPHeaderField: "Upload-Length")
            create.setValue("true", forHTTPHeaderField: "x-upsert")
            let meta = ["bucketName": Self.bucket, "objectName": object,
                        "contentType": Self.contentType(path), "cacheControl": "3600"]
            create.setValue(meta.map { "\($0.key) \(Data($0.value.utf8).base64EncodedString())" }.joined(separator: ","),
                            forHTTPHeaderField: "Upload-Metadata")
            try await SupabaseClient.shared.authorize(&create)
            let (data, resp) = try await session.data(for: create)
            guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
            guard http.statusCode == 201, let loc = http.value(forHTTPHeaderField: "Location"),
                  let url = URL(string: loc, relativeTo: endpoint)?.absoluteURL else {
                throw CloudError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
            }
            location = url
            offset = 0
            UserDefaults.standard.set(url.absoluteString, forKey: resumeKey)
        }

        guard let location else { throw CloudError.badResponse }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        while offset < size {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Self.chunk) ?? Data()
            if data.isEmpty { break }
            var patch = URLRequest(url: location)
            patch.httpMethod = "PATCH"
            patch.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            patch.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            patch.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            try await SupabaseClient.shared.authorize(&patch)
            let (body, resp) = try await session.upload(for: patch, from: data)
            guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
            if http.statusCode == 409 || http.statusCode == 404 || http.statusCode == 410 {
                // The server lost or disagrees about this upload: start it fresh next pass.
                UserDefaults.standard.removeObject(forKey: resumeKey)
            }
            guard http.statusCode == 204,
                  let next = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init) else {
                throw CloudError.http(http.statusCode, String(data: body.prefix(200), encoding: .utf8) ?? "")
            }
            offset = next
            progress(offset)
        }
        UserDefaults.standard.removeObject(forKey: resumeKey)
    }

    // MARK: Download

    /// Returns false when the bucket doesn't have the file.
    private func download(path: String, user: String) async throws -> Bool {
        let encoded = "\(user)/\(path)".split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let req = try await SupabaseClient.shared.storageRequest("object/authenticated/\(Self.bucket)/\(encoded)", method: "GET")
        let (tmp, resp) = try await session.download(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
        if http.statusCode == 400 || http.statusCode == 404 { return false }
        guard (200..<300).contains(http.statusCode) else { throw CloudError.http(http.statusCode, "download failed") }
        let dest = MediaLibrary.resolve(path)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return true
    }

    private static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        default: return "application/octet-stream"
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}
