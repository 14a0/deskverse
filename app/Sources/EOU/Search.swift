import AppKit
import FoundationModels

enum Command: String { case save, putAway }

enum RowKind {
    case command(Command)
    case desk(TopicDesk)
    case whole(Snapshot)
    case live(DeskItem)
    case file(URL)
}

struct ResultRow: Identifiable {
    let id: String
    let kind: RowKind
    let title: String
    let subtitle: String
    let symbol: String
    let accessory: String
    /// App icons to show instead of the symbol (desks show what they will open).
    var icons: [String] = []
    /// A second line shown only on the selected row: where you left off.
    var detail: String? = nil
}

/// Ranks desks, things open now and files for a query. Keyword evidence first; the on-device
/// model is asked only to match a whole sentence to a topic name when keywords find nothing.
@MainActor
enum Search {
    static let stopwords: Set<String> = ["the", "a", "an", "i", "im", "on", "back", "bring", "my", "to", "desk", "worked",
                                         "have", "had", "before", "this", "that", "for", "of", "and", "me", "please", "open",
                                         "show", "get", "with", "from", "about", "was", "which", "it", "in", "at", "is",
                                         "were", "been", "did", "do", "where", "what", "stuff", "things", "again", "up"]

    static func tokens(_ query: String) -> [String] {
        query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    static func rows(query: String, store: Store, files: [URL], meaningTopic: String?, meaningBy: String? = nil) -> [ResultRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let words = tokens(q)
        var rows: [ResultRow] = []

        // Commands.
        let saveRow = ResultRow(id: "cmd-save", kind: .command(.save), title: "Save this desk now",
                                subtitle: "Keep everything open as a new desk",
                                symbol: "square.and.arrow.down", accessory: "")
        let awayRow = ResultRow(id: "cmd-away", kind: .command(.putAway), title: "Put this desk away",
                                subtitle: "Save it, then hide every window. Nothing closes.",
                                symbol: "rectangle.stack.badge.minus", accessory: "")
        if !q.isEmpty {
            let lower = q.lowercased()
            if "save this desk now".contains(lower) || lower.hasPrefix("save") { rows.append(saveRow) }
            if lower.hasPrefix("put") || lower.hasPrefix("away") || lower.hasPrefix("clear") || lower.hasPrefix("hide") { rows.append(awayRow) }
        }

        // A desk number ("52" or "#52") or "everything" brings back a whole desk.
        if let number = Int(q.replacingOccurrences(of: "#", with: "")), let snapshot = store.snapshot(number: number) {
            rows.append(wholeRow(snapshot))
        } else if ["all", "everything", "whole"].contains(where: { q.lowercased().hasPrefix($0) }), let latest = store.snapshots.first {
            rows.append(wholeRow(latest))
        }

        // Topic desks.
        var scored: [(TopicDesk, Double)] = []
        for desk in store.desks {
            var score = recency(desk.createdAt)
            if words.isEmpty {
                // Calm by default: only desks with real work on them.
                if desk.items.count >= 2 { scored.append((desk, score)) }
                continue
            }
            var hits = 0.0
            let topic = desk.topic.lowercased()
            for word in words {
                if topic.contains(word) { hits += 5; continue }
                if desk.allVersionsItems.contains(where: { $0.title.lowercased().contains(word) }) { hits += 2; continue }
                if desk.allVersionsItems.contains(where: { $0.detail.lowercased().contains(word) }) { hits += 1 }
            }
            if desk.topic == meaningTopic { hits += 6 }
            guard hits > 0 else { continue }
            score += hits
            scored.append((desk, score))
        }
        let deskLimit = words.isEmpty ? 5 : 6
        for (desk, _) in scored.sorted(by: { $0.1 > $1.1 }).prefix(deskLimit) {
            rows.append(deskRow(desk, byMeaning: desk.topic == meaningTopic && !words.isEmpty ? (meaningBy ?? "meaning") : nil))
        }

        // Open now.
        if !words.isEmpty {
            let live = store.liveItems.compactMap { item -> (DeskItem, Int)? in
                let text = (item.title + " " + item.detail).lowercased()
                let hits = words.filter { text.contains($0) }.count
                return hits > 0 ? (item, hits) : nil
            }.sorted { $0.1 > $1.1 }.prefix(6)
            for (item, _) in live { rows.append(liveRow(item)) }
        }

        // Files from Spotlight's index.
        for url in files.prefix(5) {
            rows.append(ResultRow(id: "file-\(url.path)", kind: .file(url), title: url.lastPathComponent,
                                  subtitle: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                  symbol: url.hasDirectoryPath ? "folder" : "doc", accessory: ""))
        }
        return rows
    }

    static func recency(_ date: Date) -> Double {
        let hours = max(0, -date.timeIntervalSinceNow / 3600)
        return 1 / (1 + hours / 24)
    }

    static func deskRow(_ desk: TopicDesk, byMeaning: String?) -> ResultRow {
        var subtitle = "\(Fmt.short(desk.createdAt)) · \(desk.countsLine)"
        if let byMeaning { subtitle += " · understood by \(byMeaning), on this Mac" }
        var accessory = "#\(desk.snapshotNumber)"
        if !desk.earlier.isEmpty { accessory += " +\(desk.earlier.count)" }
        return ResultRow(id: "desk-\(desk.id)", kind: .desk(desk), title: desk.title, subtitle: subtitle,
                         symbol: "rectangle.stack", accessory: accessory, icons: desk.appBundleIDs,
                         detail: desk.receipt.map { "Left off: \($0)" })
    }

    static func wholeRow(_ snapshot: Snapshot) -> ResultRow {
        let topics = Set(snapshot.items.compactMap(\.topic)).subtracting([Topics.otherApps]).count
        return ResultRow(id: "whole-\(snapshot.number)", kind: .whole(snapshot),
                         title: "Everything on desk #\(snapshot.number)",
                         subtitle: "\(Fmt.when(snapshot.createdAt)) · \(snapshot.items.count) items in \(topics) topics",
                         symbol: "square.stack.3d.up", accessory: "")
    }

    static func liveRow(_ item: DeskItem) -> ResultRow {
        let subtitle: String
        switch item.kind {
        case .agent: subtitle = "Claude Code · \(item.state ?? "running") · \(item.detail.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        case .tab: subtitle = Topics.host(item.detail)
        default: subtitle = item.detail.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        return ResultRow(id: "live-\(item.id)", kind: .live(item), title: item.title, subtitle: subtitle,
                         symbol: item.kind.symbol, accessory: "open", icons: [AppIcons.bundleID(for: item)])
    }

    // MARK: Files

    /// Asks Spotlight's index for files and folders whose name matches.
    nonisolated static func files(matching query: String) async -> [URL] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return [] }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", NSHomeDirectory(), "-name", q]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
            return lines.filter { !$0.contains("/Library/") && !$0.contains("/.") }
                .prefix(5).map { URL(fileURLWithPath: $0) }
        }.value
    }

    // MARK: Meaning

    @Generable
    struct TopicChoice {
        @Guide(description: "The number of the topic the request is about, or 0 if none fits")
        var number: Int
    }

    /// Matches a whole sentence to a saved desk, on this Mac: Meta's Llama first (each desk described by
    /// what was on it), Apple's on-device model as the fallback.
    static func meaning(of query: String, desks: [TopicDesk]) async -> (topic: String, by: String)? {
        guard tokens(query).count >= 2, !desks.isEmpty else { return nil }
        // Plain clues for a small model: the readable name, where you left off, and what was on the desk.
        let described = desks.prefix(25).map { desk -> (name: String, about: String) in
            var parts: [String] = []
            for item in desk.allVersionsItems.prefix(8) {
                switch item.kind {
                case .tab: parts.append(item.title)
                case .note: parts.append("note \(item.title)")
                case .agent: parts.append("a coding agent")
                case .music: parts.append("the song \(item.title) playing")
                case .folder: parts.append("folder \(item.title)")
                case .app: parts.append("the app \(item.title)")
                }
            }
            var about = desk.receipt.map { "Left off: \($0). " } ?? ""
            about += "On it: " + parts.joined(separator: "; ")
            return (desk.title, about)
        }
        switch await MetaModel.pickDesk(for: query, desks: described) {
        case .desk(let title):
            // Map the readable name back to the desk's topic.
            let topic = desks.first { $0.title == title }?.topic ?? title
            return (topic, MetaModel.label)
        case .noMatch: return nil
        case .unavailable:
            if let topic = await meaning(of: query, topics: desks.map(\.topic)) { return (topic, "Apple on-device model") }
            return nil
        }
    }

    static func meaning(of query: String, topics: [String]) async -> String? {
        guard Topics.modelAvailable, tokens(query).count >= 2, !topics.isEmpty else { return nil }
        let list = topics.prefix(30).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: "You match what a person asks for to one of their saved work topics.")
        do {
            let response = try await session.respond(to: "Topics:\n\(list)\nRequest: \(query)\nWhich topic?", generating: TopicChoice.self)
            let n = response.content.number
            return (1...min(30, topics.count)).contains(n) ? topics[n - 1] : nil
        } catch {
            return nil
        }
    }
}
