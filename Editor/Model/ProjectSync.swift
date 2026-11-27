import Foundation

/// Backs up editor projects (the edit itself, not the video files) to the Supabase `projects` table.
///
/// The phone stays the source of truth: ProjectStore saves locally first and works offline.
/// This class remembers what still needs uploading, pushes it when there is a connection,
/// and pulls rows back so a project whose local file went missing reappears in the list.
@MainActor
final class ProjectSync: ObservableObject {
    static let shared = ProjectSync()

    enum Status: Equatable {
        case off                 // not configured in this build
        case idle                // configured, nothing done yet
        case syncing
        case synced(Date)
        case waiting(String)     // offline or failed; will retry
    }

    @Published private(set) var status: Status = SupabaseConfig.current == nil ? .off : .idle
    var isEnabled: Bool { SupabaseConfig.current != nil }

    /// Saved between launches so nothing is lost if the app closes while offline.
    private struct State: Codable {
        var pendingUpserts: Set<UUID> = []
        var pendingDeletes: [UUID: EditProject] = [:]
        /// Server `updated_at` of the newest row already pulled.
        var cursor: String?
        /// The cloud account these flags belong to. A new account means upload everything again.
        var userID: String?
    }

    private var state: State
    private var waitTask: Task<Void, Never>?
    private var running = false
    private var again = false

    private static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("project-sync.json")
    }

    /// Same date format as ProjectStore so a project round-trips unchanged.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        state = (try? Self.decoder.decode(State.self, from: Data(contentsOf: Self.stateURL))) ?? State()
    }

    // MARK: Called by ProjectStore

    func markChanged(_ id: UUID) {
        guard isEnabled else { return }
        state.pendingDeletes[id] = nil
        state.pendingUpserts.insert(id)
        persist()
        syncSoon()
    }

    func markDeleted(_ project: EditProject) {
        guard isEnabled else { return }
        state.pendingUpserts.remove(project.id)
        state.pendingDeletes[project.id] = project
        persist()
        syncSoon()
    }

    /// Debounced so a burst of edits becomes one upload. Never interrupts a pass that is already uploading.
    func syncSoon(delay: Double = 2) {
        guard isEnabled else { return }
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.startPass()
        }
    }

    // MARK: Sync pass

    private func startPass() {
        if running { again = true; return }
        running = true
        Task { await run() }
    }

    private func run() async {
        defer { running = false }
        repeat {
            again = false
            status = .syncing
            do {
                try await pass()
                status = .synced(Date())
                FootageSync.shared.syncSoon()
            } catch {
                status = .waiting((error as? URLError) != nil ? "Offline. Will back up when you're connected."
                                                              : error.localizedDescription)
                syncSoon(delay: 60)
                return
            }
        } while again
    }

    private func pass() async throws {
        let (_, user) = try await SupabaseClient.shared.session()
        if state.userID != user {
            // First sign-in on this install, or a fresh account: upload every local project.
            state.userID = user
            state.cursor = nil
            state.pendingUpserts.formUnion(ProjectStore.shared.projects.map(\.id))
            persist()
        }
        try await push()
        try await pull()
    }

    private func push() async throws {
        let store = ProjectStore.shared
        let upserts = state.pendingUpserts.compactMap { id in store.projects.first { $0.id == id } }
        let deletes = Array(state.pendingDeletes.values)
        // Ids queued for a project that no longer exists locally (and isn't a delete) can go.
        let stale = state.pendingUpserts.filter { id in !upserts.contains { $0.id == id } }
        state.pendingUpserts.subtract(stale)

        let rows = upserts.map { ProjectRow($0, deleted: false) } + deletes.map { ProjectRow($0, deleted: true) }
        // Small batches keep each request well under PostgREST's body limit even for long edits.
        for batch in stride(from: 0, to: rows.count, by: 20).map({ Array(rows[$0..<min($0 + 20, rows.count)]) }) {
            let body = try Self.encoder.encode(batch)
            _ = try await SupabaseClient.shared.rest("projects?on_conflict=id", method: "POST", body: body,
                                                     prefer: "resolution=merge-duplicates,return=minimal")
            for row in batch {
                // Only clear a flag if nothing newer was queued while this upload was in flight.
                if row.deleted_at != nil {
                    if state.pendingDeletes[row.id]?.modified == row.data?.modified { state.pendingDeletes[row.id] = nil }
                } else if let local = store.projects.first(where: { $0.id == row.id }), local.modified == row.data?.modified {
                    state.pendingUpserts.remove(row.id)
                }
            }
            persist()
        }
    }

    private func pull() async throws {
        var query = "projects?select=id,data,deleted_at,updated_at&order=updated_at.asc&limit=200"
        if let cursor = state.cursor,
           let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            query += "&updated_at=gt.\(encoded)"
        }
        while true {
            let data = try await SupabaseClient.shared.rest(query, method: "GET")
            let rows = try Self.decoder.decode([RemoteRow].self, from: data)
            let store = ProjectStore.shared
            for row in rows {
                // Local changes not yet uploaded win; they will overwrite the cloud on the next push.
                if state.pendingUpserts.contains(row.id) || state.pendingDeletes[row.id] != nil { continue }
                let local = store.projects.first { $0.id == row.id }
                if row.deleted_at != nil {
                    if local != nil { store.removeFromCloud(row.id) }
                } else if let remote = row.data.value, local == nil || remote.modified > local!.modified {
                    store.applyFromCloud(remote)
                }
            }
            if let last = rows.last?.updated_at { state.cursor = last; persist() }
            guard rows.count == 200, let cursor = state.cursor,
                  let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { break }
            query = "projects?select=id,data,deleted_at,updated_at&order=updated_at.asc&limit=200&updated_at=gt.\(encoded)"
        }
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}

/// One row of `public.projects` as the app writes it. `user_id` is filled in by the database.
private struct ProjectRow: Encodable {
    let id: UUID
    let name: String
    let status: String
    let canvas: String
    let quality: String
    let duration_seconds: Double
    let clip_count: Int
    let created_at: Date
    let modified_at: Date
    let finished_at: Date?
    let deleted_at: Date?
    let data: EditProject?

    init(_ p: EditProject, deleted: Bool) {
        id = p.id
        name = p.name
        status = p.finishedAt == nil ? "in_progress" : "finished"
        canvas = p.canvas.rawValue
        quality = p.quality.rawValue
        duration_seconds = p.duration
        clip_count = p.clips.count
        created_at = p.created
        modified_at = p.modified
        finished_at = p.finishedAt
        deleted_at = deleted ? Date() : nil
        data = p
    }

    // Write nulls explicitly so un-finishing a project clears the column in the cloud.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(quality, forKey: .quality)
        try c.encode(duration_seconds.isFinite ? duration_seconds : 0, forKey: .duration_seconds)
        try c.encode(clip_count, forKey: .clip_count)
        try c.encode(created_at, forKey: .created_at)
        try c.encode(modified_at, forKey: .modified_at)
        try c.encode(finished_at, forKey: .finished_at)
        try c.encode(deleted_at, forKey: .deleted_at)
        try c.encode(data, forKey: .data)
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, status, canvas, quality, duration_seconds, clip_count, created_at, modified_at, finished_at, deleted_at, data
    }
}

private struct RemoteRow: Decodable {
    let id: UUID
    let data: Lossy<EditProject>
    let deleted_at: String?
    let updated_at: String
}

/// Decodes to nil instead of failing, so one project saved by a newer app version can't block the rest.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
