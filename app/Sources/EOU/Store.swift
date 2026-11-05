import Foundation

/// Saved desks on disk, the topic index the panel searches, and the capture loop.
@MainActor
final class Store {
    static let shared = Store()

    private(set) var snapshots: [Snapshot] = []   // newest first
    private(set) var desks: [TopicDesk] = []       // newest version of each topic first
    /// What is open right now (topics from earlier desks where known).
    private(set) var liveItems: [DeskItem] = []
    private(set) var lastProblems: [String] = []

    private let topics = Topics()
    private var capturing = false
    let folder: URL

    static let standardGaps = [
        "Scroll position and typed text inside tabs",
        "Which Chrome profile each window used",
        "Plain terminal tabs that are not Claude Code sessions",
        "Unsaved edits in any app",
    ]

    init() {
        folder = Profile.folder.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    // MARK: Disk

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        snapshots = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Snapshot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.number > $1.number }
        rebuildDesks()
    }

    private func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = folder.appendingPathComponent(String(format: "desk-%05d.json", snapshot.number))
        try? encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// Item id to topic, newest desk wins, so an item keeps the topic it had.
    var topicCache: [String: String] {
        var cache: [String: String] = [:]
        for snapshot in snapshots {
            for item in snapshot.items where cache[item.id] == nil {
                if let topic = item.topic { cache[item.id] = topic }
            }
        }
        return cache
    }

    // MARK: Capture

    /// Reads what is open now without saving, for "open now" results.
    func refreshLive() {
        let result = Capture.everything()
        let cache = topicCache
        liveItems = result.items.map { item in
            var copy = item
            if copy.kind == .agent { copy.topic = Topics.projectName(forFolder: copy.detail) } else { copy.topic = cache[copy.id] }
            return copy
        }
        lastProblems = result.problems
    }

    /// Saves the desk as a new numbered snapshot when something changed (or always when forced).
    @discardableResult
    func capture(force: Bool) async -> Snapshot? {
        guard !capturing else { return nil }
        capturing = true
        defer { capturing = false }
        let result = Capture.everything()
        lastProblems = result.problems
        if result.items.isEmpty { return nil }
        if !force, let last = snapshots.first, last.keySet == Set(result.items.map(\.id)) {
            return nil
        }
        let assigned = await topics.assign(result.items, frontmostApp: result.frontmostApp, cache: topicCache)
        liveItems = assigned
        let number = (snapshots.first?.number ?? 0) + 1
        let snapshot = Snapshot(id: "\(Int(Date().timeIntervalSince1970))-\(number)", number: number,
                                createdAt: Date(), items: assigned,
                                notCaptured: Self.standardGaps + result.problems)
        save(snapshot)
        snapshots.insert(snapshot, at: 0)
        rebuildDesks()
        Task { await writeReceipts(snapshotNumber: number) }
        return snapshot
    }

    // MARK: Receipts

    /// Writes "where you left off" for each topic of a desk, on this Mac with Llama. A topic whose items did not
    /// change keeps its earlier receipt, so the model only runs for what changed.
    func writeReceipts(snapshotNumber: Int) async {
        guard let index = snapshots.firstIndex(where: { $0.number == snapshotNumber }) else { return }
        let snapshot = snapshots[index]
        var receipts = snapshot.receipts ?? [:]
        let grouped = Dictionary(grouping: snapshot.items.filter { ($0.topic ?? Topics.otherApps) != Topics.otherApps }, by: { $0.topic! })
        for (topic, items) in grouped where receipts[topic] == nil {
            let keys = Set(items.map(\.id))
            if let earlier = snapshots.dropFirst(index + 1).first(where: { snap in
                Set(snap.items.filter { $0.topic == topic }.map(\.id)) == keys && snap.receipts?[topic] != nil
            }) {
                receipts[topic] = earlier.receipts?[topic]
                continue
            }
            if let line = await MetaModel.receipt(topic: Topics.display(topic), items: items) { receipts[topic] = line }
        }
        guard let fresh = snapshots.firstIndex(where: { $0.number == snapshotNumber }) else { return }
        snapshots[fresh].receipts = receipts
        save(snapshots[fresh])
        rebuildDesks()
    }

    // MARK: Desk index

    private func rebuildDesks() {
        var versionsByTopic: [String: [TopicDesk]] = [:]
        for snapshot in snapshots {
            let grouped = Dictionary(grouping: snapshot.items.filter { ($0.topic ?? Topics.otherApps) != Topics.otherApps },
                                     by: { $0.topic! })
            for (topic, items) in grouped {
                let desk = TopicDesk(topic: topic, snapshotNumber: snapshot.number, createdAt: snapshot.createdAt,
                                     items: items, notCaptured: snapshot.notCaptured, receipt: snapshot.receipts?[topic].map(MetaModel.tidy))
                var versions = versionsByTopic[topic, default: []]
                if let newer = versions.last, Set(newer.items.map(\.id)) == Set(items.map(\.id)) { continue }
                versions.append(desk)
                versionsByTopic[topic] = versions
            }
        }
        desks = versionsByTopic.values.map { versions in
            var head = versions[0]
            head.earlier = Array(versions.dropFirst())
            return head
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func snapshot(number: Int) -> Snapshot? { snapshots.first { $0.number == number } }
}
