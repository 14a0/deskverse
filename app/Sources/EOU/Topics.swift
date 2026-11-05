import AppKit
import FoundationModels
import NaturalLanguage

/// Groups desk items into topics from evidence. The on-device model only names groups
/// that have no project name; it is not trusted to sort (it filed Netflix under research in tests).
@MainActor
final class Topics {
    static let leisure = "Leisure"
    static let otherApps = "Other apps"

    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private static let strongLeisureHosts = ["netflix.com", "disneyplus.com", "primevideo.com", "twitch.tv",
                                             "store.steampowered.com", "crunchyroll.com", "hulu.com", "max.com",
                                             "open.spotify.com", "music.apple.com", "tv.apple.com"]
    private static let softLeisureHosts = ["youtube.com", "bilibili.com", "reddit.com"]

    /// Assigns a topic to every item. `cache` maps item ids to topics from earlier desks, so an item keeps its topic.
    func assign(_ items: [DeskItem], frontmostApp: String?, cache: [String: String]) async -> [DeskItem] {
        var out = items
        var known = Set(cache.values)

        // 1. Projects from evidence that cannot be wrong: where an agent runs, where a note or folder lives.
        for i in out.indices where out[i].kind == .agent {
            out[i].topic = Self.projectName(forFolder: out[i].detail)
        }
        let anchors = Array(Set(out.compactMap { $0.kind == .agent ? $0.topic : nil })).sorted()
        known.formUnion(anchors)

        for i in out.indices where out[i].kind == .note || out[i].kind == .folder {
            if let cached = cache[out[i].id] { out[i].topic = cached; continue }
            let haystack = Self.norm(out[i].ref)
            if let anchor = Self.longestAnchor(in: haystack, anchors: anchors) {
                out[i].topic = anchor
            } else if out[i].kind == .note {
                out[i].topic = Self.noteTopic(vaultFolder: out[i].detail)
            } else {
                out[i].topic = Self.folderTopic(path: out[i].ref)
            }
        }

        // 2. Tabs: cached, then shared keywords, then strong leisure, then a confident similarity match.
        let anchorText = Dictionary(uniqueKeysWithValues: anchors.map { anchor in
            (anchor, ([anchor] + out.filter { $0.topic == anchor }.map(\.title)).prefix(8).joined(separator: ". "))
        })
        for i in out.indices where out[i].kind == .tab {
            if let cached = cache[out[i].id] { out[i].topic = cached; continue }
            let haystack = Self.norm(out[i].title + " " + out[i].detail)
            if let anchor = Self.longestAnchor(in: haystack, anchors: anchors) { out[i].topic = anchor; continue }
            let host = Self.host(out[i].detail)
            if Self.strongLeisureHosts.contains(where: { host.hasSuffix($0) }) { out[i].topic = Self.leisure; continue }
            if let embedding, let best = Self.closest(out[i].title, to: anchorText, embedding: embedding) {
                out[i].topic = best
            }
        }

        // 3. Tabs share a Chrome window with the task they belong to: unassigned tabs take the window's topic.
        let windows = Set(out.compactMap { $0.kind == .tab ? $0.window : nil })
        for w in windows {
            let assigned = out.filter { $0.kind == .tab && $0.window == w && $0.topic != nil && $0.topic != Self.leisure }
            let counts = Dictionary(grouping: assigned, by: { $0.topic! }).mapValues(\.count)
            if let top = counts.max(by: { $0.value < $1.value })?.key {
                for i in out.indices where out[i].kind == .tab && out[i].window == w && out[i].topic == nil {
                    out[i].topic = top
                }
            }
        }
        for i in out.indices where out[i].kind == .tab && out[i].topic == nil {
            let host = Self.host(out[i].detail)
            if Self.softLeisureHosts.contains(where: { host.hasSuffix($0) }) { out[i].topic = Self.leisure }
        }

        // 4. Windows with no project at all become their own topic, named on device from their titles.
        for w in windows.sorted() {
            let idx = out.indices.filter { out[$0].kind == .tab && out[$0].window == w && out[$0].topic == nil }
            guard !idx.isEmpty else { continue }
            let titles = idx.map { out[$0].title }
            var name = await Self.nameGroup(titles: titles) ?? Self.hostName(out[idx[0]].detail)
            name = Self.canonical(name, known: known)
            known.insert(name)
            for i in idx { out[i].topic = name }
        }

        // 5. Music follows the work in front; apps are leisure or simply "other apps".
        let focus = Self.focusTopic(out, frontmostApp: frontmostApp)
        for i in out.indices where out[i].kind == .music {
            out[i].topic = focus ?? Self.leisure
        }
        for i in out.indices where out[i].kind == .app {
            out[i].topic = Self.isLeisureApp(bundleID: out[i].ref) ? Self.leisure : Self.otherApps
        }
        for i in out.indices where out[i].topic == nil { out[i].topic = Self.otherApps }
        return out
    }

    // MARK: Display

    /// How a topic reads on screen: "automation-dashboard" becomes "Automation Dashboard", and kcalm is always lowercase.
    nonisolated static func display(_ topic: String) -> String {
        let words = topic.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        let shown = words.map { word -> String in
            if word.lowercased() == "kcalm" { return "kcalm" }
            if word == word.lowercased(), let first = word.first, first.isLetter { return first.uppercased() + word.dropFirst() }
            return word
        }.joined(separator: " ")
        return shown.isEmpty ? topic : shown
    }

    // MARK: Evidence helpers

    static func norm(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func longestAnchor(in haystack: String, anchors: [String]) -> String? {
        anchors.filter { norm($0).count >= 4 && haystack.contains(norm($0)) }.max { norm($0).count < norm($1).count }
    }

    static func projectName(forFolder path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home || path == "/" { return "Home" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// `vaultFolder` is "<vault>/<folder inside the vault>". A dated research bundle names the topic
    /// ("Open loops and AI 2026-11-05" becomes "Open loops and AI"); otherwise the top vault folder does
    /// ("01 Journal/2026/Daily" becomes "Journal").
    static func noteTopic(vaultFolder: String) -> String {
        let parts = vaultFolder.split(separator: "/").map(String.init)
        let inside = Array(parts.dropFirst())
        if let bundle = inside.last(where: { $0.range(of: #"\d{4}-\d{2}-\d{2}[a-z]?$"#, options: .regularExpression) != nil }) {
            return cleanFolderName(bundle)
        }
        if let top = inside.first { return cleanFolderName(top) }
        return parts.first ?? "Notes"
    }

    static func folderTopic(path: String) -> String {
        let code = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code").path + "/"
        if path.hasPrefix(code) {
            return String(path.dropFirst(code.count)).split(separator: "/").first.map(String.init) ?? "Code"
        }
        return cleanFolderName(URL(fileURLWithPath: path).lastPathComponent)
    }

    static func cleanFolderName(_ name: String) -> String {
        var s = name
        if let r = s.range(of: #"\s*\d{4}-\d{2}-\d{2}[a-z]?$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"^\d{1,3}\s+"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.isEmpty ? name : s
    }

    static func host(_ url: String) -> String {
        (URL(string: url)?.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
    }

    static func hostName(_ url: String) -> String {
        let h = host(url)
        return h.isEmpty ? "Tabs" : h
    }

    static func canonical(_ name: String, known: Set<String>) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return known.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }

    /// Accepts a similarity match only when it is close and clearly better than the next anchor.
    static func closest(_ text: String, to anchors: [String: String], embedding: NLEmbedding) -> String? {
        let scored = anchors.map { ($0.key, embedding.distance(between: text, and: $0.value)) }.sorted { $0.1 < $1.1 }
        guard let first = scored.first, first.1 < 0.85 else { return nil }
        if scored.count > 1, scored[1].1 - first.1 < 0.08 { return nil }
        return first.0
    }

    static func focusTopic(_ items: [DeskItem], frontmostApp: String?) -> String? {
        switch frontmostApp {
        case Capture.chromeID:
            // Chrome numbers windows front to back across every Desktop; the frontmost one captured here is the lowest number.
            guard let frontWindow = items.filter({ $0.kind == .tab }).compactMap(\.window).min() else { return nil }
            let front = items.filter { $0.kind == .tab && $0.window == frontWindow }.compactMap(\.topic).filter { $0 != leisure }
            return Dictionary(grouping: front, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        case Capture.obsidianID:
            return items.first { $0.kind == .note }?.topic
        default:
            return nil
        }
    }

    static func isLeisureApp(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let category = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String else { return false }
        return category.contains("games") || category.hasSuffix("entertainment") || category.hasSuffix("video") || category.hasSuffix(".music")
    }

    // MARK: On-device naming

    @Generable
    struct GroupName {
        @Guide(description: "A topic name of 2 to 4 words in Title Case naming the subject, never the app or website")
        var name: String
    }

    static var modelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Meta's Llama on this Mac first; Apple's on-device model if Ollama is not running.
    static func nameGroup(titles: [String]) async -> String? {
        if let name = await MetaModel.nameGroup(titles: titles) { return name }
        guard modelAvailable else { return nil }
        let list = titles.prefix(12).map { "- \($0)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: "You name what a person is working on from the titles of their open browser tabs.")
        do {
            let response = try await session.respond(to: "Tabs:\n\(list)\nName the topic.", generating: GroupName.self)
            let name = response.content.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || name.count > 40 ? nil : name
        } catch {
            return nil
        }
    }
}
