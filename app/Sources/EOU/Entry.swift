import AppKit

@main
@MainActor
enum Entry {
    static var delegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--dry-run") {
            DryRun.start()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}

/// Prints one capture, grouped by topic, without saving and without UI.
@MainActor
enum DryRun {
    static func start() {
        Task { @MainActor in
            if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
                let query = CommandLine.arguments[i + 1]
                MetaModel.trace = { print($0) }
                let started = Date()
                let match = await Search.meaning(of: query, desks: Store.shared.desks)
                print("\(query) -> \(match.map { "\($0.topic) (by \($0.by))" } ?? "no match") in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                exit(0)
            }
            if CommandLine.arguments.contains("--selftest") {
                await selfTest()
                exit(0)
            }
            if CommandLine.arguments.contains("--timing") {
                var p: [String] = []
                for (name, run) in [("chrome", { _ = Capture.chromeTabs(&p) }), ("claude", { _ = Capture.claudeSessions() }),
                                    ("obsidian", { _ = Capture.obsidianNotes(&p) }), ("finder", { _ = Capture.finderFolders(&p) }),
                                    ("spotify", { _ = Capture.spotify(&p) }), ("apps", { _ = Capture.otherApps() })] as [(String, () -> Void)] {
                    let t = Date(); run(); print(name, String(format: "%.2f s", Date().timeIntervalSince(t)))
                }
            }
            let started = Date()
            let result = Capture.everything()
            let captured = Date().timeIntervalSince(started)
            let assigned = await Topics().assign(result.items, frontmostApp: result.frontmostApp, cache: Store.shared.topicCache)
            let grouped = Dictionary(grouping: assigned, by: { $0.topic ?? "?" })
            print("Captured \(assigned.count) items in \(String(format: "%.2f", captured)) s; grouped in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            for (topic, items) in grouped.sorted(by: { $0.value.count > $1.value.count }) {
                let counts = ItemKind.allCases.compactMap { kind -> String? in
                    let n = items.filter { $0.kind == kind }.count
                    return n > 0 ? "\(n) \(kind.rawValue)" : nil
                }.joined(separator: ", ")
                print("\n[\(topic)] \(counts)")
                for item in items.prefix(6) { print("  \(item.kind.rawValue): \(item.title.prefix(70))") }
                if items.count > 6 { print("  ... \(items.count - 6) more") }
            }
            if !result.problems.isEmpty { print("\nProblems:"); result.problems.forEach { print("  \($0)") } }
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Groups a made-up desk and checks the result. Run with --dry-run --selftest.
    static func selfTest() async {
        let research = "/Users/x/vault/19 Ideas/research/Open loops and AI 2026-11-05/Open loops and AI 2026-11-05.md"
        let items = [
            DeskItem(kind: .agent, title: "kcalm-24", detail: "/Users/x/Code/KCALM", ref: "s1"),
            DeskItem(kind: .agent, title: "research-1", detail: "/Users/x/Code/EOU", ref: "s2"),
            DeskItem(kind: .note, title: "Open loops and AI 2026-11-05", detail: "vault/19 Ideas/research/Open loops and AI 2026-11-05", ref: research),
            DeskItem(kind: .tab, title: "When the Tab Comes Due: Challenges in the Cost Structure of Browser Tab Usage", detail: "https://josephcc.com/paper.pdf", ref: "https://josephcc.com/paper.pdf", window: 2),
            DeskItem(kind: .tab, title: "Attention residue when switching work tasks", detail: "https://doi.org/10.1016/j.obhdp", ref: "https://doi.org/10.1016/j.obhdp", window: 2),
            DeskItem(kind: .tab, title: "Study group chat | Facebook", detail: "https://www.facebook.com/groups/study", ref: "https://www.facebook.com/groups/study", window: 2),
            DeskItem(kind: .tab, title: "App Store Connect: kcalm ratings", detail: "https://appstoreconnect.apple.com/apps/1", ref: "https://appstoreconnect.apple.com/apps/1", window: 1),
            DeskItem(kind: .tab, title: "Severance: Season 2, Episode 4", detail: "https://www.netflix.com/watch/1", ref: "https://www.netflix.com/watch/1", window: 3),
            DeskItem(kind: .music, title: "Lofi study beats", detail: "Lofi Girl", ref: "spotify:track:1"),
        ]
        let assigned = await Topics().assign(items, frontmostApp: Capture.chromeID, cache: [:])
        let expect: [String: String] = ["s1": "KCALM", "s2": "EOU", research: "Open loops and AI",
                                        "https://appstoreconnect.apple.com/apps/1": "KCALM",
                                        "https://www.netflix.com/watch/1": Topics.leisure]
        var failures = 0
        for item in assigned {
            let mark: String
            if let want = expect[item.ref] { mark = item.topic == want ? "ok  " : "FAIL"; if item.topic != want { failures += 1 } } else { mark = "    " }
            print("\(mark) \(item.kind.rawValue): \(item.title.prefix(50)) -> \(item.topic ?? "nil")")
        }
        let window2 = Set(assigned.filter { $0.window == 2 }.compactMap(\.topic))
        print(window2.count == 1 ? "ok   research window stays one topic: \(window2.first!)" : "FAIL research window split: \(window2)")
        if window2.count != 1 { failures += 1 }

        // The video's hero desk: four papers and the agents' draft in one Chrome window, two notes in the
        // "Thesis research" vault, four agents in thesis-research, study music. It must be one desk.
        let root = "/Users/14a0/Code/EOU-demo"
        var hero: [DeskItem] = (1...4).map { DeskItem(kind: .agent, title: "thesis-research-\($0)", detail: "\(root)/thesis-research", ref: "a\($0)") }
        hero += [DeskItem(kind: .note, title: "Thesis outline", detail: "Thesis research", ref: "\(root)/Thesis research/Thesis outline.md"),
                 DeskItem(kind: .note, title: "Reading notes", detail: "Thesis research/Literature", ref: "\(root)/Thesis research/Literature/Reading notes.md")]
        hero += ["https://josephcc.com/static/papers/233987809/paper.pdf", "https://doi.org/10.1016/j.obhdp.2009.04.002",
                 "https://www.pewresearch.org/short-reads/2025/07/22/google-users-are-less-likely-to-click-on-links-when-an-ai-summary-appears-in-the-results/",
                 "https://news.ycombinator.com/item?id=43834101",
                 "file://\(root)/thesis-research/notes/section-3-draft.md"].enumerated().map {
            DeskItem(kind: .tab, title: ["When the Tab Comes Due", "Why is it so hard to do my work?", "Google users are less likely to click", "Ask HN: tabs", "section-3-draft.md"][$0.offset], detail: $0.element, ref: $0.element, window: 1)
        }
        hero.append(DeskItem(kind: .music, title: "Deep Focus", detail: "Spotify", ref: "spotify:playlist:1"))
        let heroTopics = Set(await Topics().assign(hero, frontmostApp: Capture.chromeID, cache: [:]).compactMap(\.topic))
        if heroTopics.count == 1 {
            let desk = TopicDesk(topic: heroTopics.first!, snapshotNumber: 0, createdAt: Date(),
                                 items: hero, notCaptured: [])
            print("ok   hero desk is one desk: \(desk.title), \(desk.countsLine)")
        } else {
            print("FAIL hero desk split: \(heroTopics.sorted())"); failures += 1
        }
        print(failures == 0 ? "PASS" : "\(failures) FAILED")
    }
}
