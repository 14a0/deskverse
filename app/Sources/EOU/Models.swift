import Foundation

/// What kind of thing an item on a desk is.
enum ItemKind: String, Codable, CaseIterable {
    case tab, agent, note, folder, music, app

    var symbol: String {
        switch self {
        case .tab: return "globe"
        case .agent: return "terminal"
        case .note: return "doc.text"
        case .folder: return "folder"
        case .music: return "music.note"
        case .app: return "app"
        }
    }

    var plural: String {
        switch self {
        case .tab: return "tabs"
        case .agent: return "agents"
        case .note: return "notes"
        case .folder: return "folders"
        case .music: return "music"
        case .app: return "apps"
        }
    }
}

/// One thing that was open on the desk.
struct DeskItem: Codable, Hashable, Identifiable {
    var kind: ItemKind
    var title: String
    /// URL for tabs, folder for agents, vault folder for notes, path for folders, artist for music, bundle id for apps.
    var detail: String
    /// What restores it: URL, Claude session id, absolute note path, folder path, Spotify URI, bundle id.
    var ref: String
    /// Chrome window number for tabs (tabs in one window are usually one task).
    var window: Int?
    /// Process id for running Claude Code sessions.
    var pid: Int?
    /// Claude Code status when captured ("idle", "busy").
    var state: String?
    /// Topic the item was grouped under.
    var topic: String?

    var id: String { "\(kind.rawValue)|\(ref)" }
}

/// Everything open at one moment: one "parallel universe" desk, numbered.
struct Snapshot: Codable, Identifiable {
    var id: String
    var number: Int
    var createdAt: Date
    var items: [DeskItem]
    /// The receipt: what this desk could not keep.
    var notCaptured: [String]
    /// One line per topic, written on this Mac by Llama: where you left off.
    var receipts: [String: String]?

    var keySet: Set<String> { Set(items.map(\.id)) }
}

/// The items of one topic inside one snapshot. What the panel calls a desk.
struct TopicDesk: Identifiable {
    var topic: String
    var snapshotNumber: Int
    var createdAt: Date
    var items: [DeskItem]
    var notCaptured: [String]
    /// Where you left off, written on this Mac by Llama.
    var receipt: String?
    /// Older, different versions of the same topic (earlier universes).
    var earlier: [TopicDesk] = []

    var title: String { Topics.display(topic) }

    /// The apps this desk opens, most important first, at most four.
    var appBundleIDs: [String] {
        var seen: [String] = []
        for kind: ItemKind in [.tab, .note, .agent, .music, .folder, .app] {
            for item in items where item.kind == kind {
                let id = AppIcons.bundleID(for: item)
                if !seen.contains(id) { seen.append(id) }
            }
        }
        return Array(seen.prefix(4))
    }

    var id: String { "\(snapshotNumber)#\(topic)" }

    var countsLine: String {
        var parts: [String] = []
        for kind: ItemKind in [.tab, .note, .agent, .folder, .music, .app] {
            let n = items.filter { $0.kind == kind }.count
            if n == 0 { continue }
            if kind == .music { parts.append("music") } else { parts.append("\(n) \(n == 1 ? String(kind.plural.dropLast()) : kind.plural)") }
        }
        return parts.joined(separator: ", ")
    }

    /// All items across this version and earlier ones, newest first, without duplicates.
    var allVersionsItems: [DeskItem] {
        var seen = Set<String>()
        var out: [DeskItem] = []
        for item in items + earlier.flatMap(\.items) where !seen.contains(item.id) {
            seen.insert(item.id)
            out.append(item)
        }
        return out
    }
}

enum Fmt {
    /// "11:59" today, "Yesterday", or "3 Nov" further back: the least you need to tell desks apart.
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }
}

import AppKit

/// Real app icons for desk rows, from the apps installed on this Mac.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    nonisolated static func bundleID(for item: DeskItem) -> String {
        switch item.kind {
        case .tab: return "com.google.Chrome"
        case .agent: return "com.googlecode.iterm2"
        case .note: return "md.obsidian"
        case .folder: return "com.apple.finder"
        case .music: return "com.spotify.client"
        case .app: return item.ref
        }
    }

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}
