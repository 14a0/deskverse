import AppKit
import ScriptingBridge

/// Brings desk items back, focuses ones that are still open, and puts the desk away.
/// It never quits an app, closes a tab or ends a session.
@MainActor
enum Restore {
    struct Outcome {
        var opened: [String] = []
        var problems: [String] = []
    }

    static func bringBack(_ items: [DeskItem]) -> Outcome {
        var outcome = Outcome()
        let before = Layout.snapshot([Capture.chromeID, Capture.itermID, Capture.obsidianID])

        // Tabs: one new Chrome window per original window.
        let tabs = items.filter { $0.kind == .tab }
        var windowOrder: [Int] = []
        for tab in tabs where !windowOrder.contains(tab.window ?? 0) { windowOrder.append(tab.window ?? 0) }
        for w in windowOrder {
            let urls = tabs.filter { ($0.window ?? 0) == w }.map(\.ref)
            if let problem = openChromeWindow(urls) { outcome.problems.append(problem) } else { outcome.opened.append("\(urls.count) tabs") }
        }

        // Claude Code: focus sessions still running, resume the ones that stopped.
        let agents = items.filter { $0.kind == .agent }
        let stopped = agents.filter { !isRunning($0) }
        // Agents still running stay where they are; jumping to them would pull you off the fresh Desktop.
        if !stopped.isEmpty {
            if let problem = resumeAgents(stopped) { outcome.problems.append(problem) } else { outcome.opened.append("\(stopped.count) agents resumed") }
        }
        if agents.count > stopped.count { outcome.opened.append("\(agents.count - stopped.count) agents still running") }

        for note in items where note.kind == .note {
            var components = URLComponents()
            components.scheme = "obsidian"
            components.host = "open"
            // A note opens in its own window on this Desktop, instead of pulling you to Obsidian's main window.
            components.queryItems = [URLQueryItem(name: "path", value: note.ref), URLQueryItem(name: "paneType", value: "window")]
            if let url = components.url { NSWorkspace.shared.open(url) }
        }
        let notes = items.filter { $0.kind == .note }.count
        if notes > 0 { outcome.opened.append("\(notes) notes") }

        for folder in items where folder.kind == .folder {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder.ref))
        }

        if let track = items.first(where: { $0.kind == .music }) {
            let (_, error) = Capture.run("tell application id \"com.spotify.client\" to play track \(Capture.literal(track.ref))")
            if let error { outcome.problems.append("Spotify: \(error)") } else { outcome.opened.append("music") }
        }

        for app in items where app.kind == .app {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.ref) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }

        // Once the windows exist, lay the desk out: browser left, note top right, agents bottom right.
        let hasTabs = !tabs.isEmpty, hasNote = notes > 0, hasAgents = !stopped.isEmpty
        if (hasTabs || hasNote || hasAgents) && Layout.trusted {
            Task { @MainActor in
                let browser = hasTabs ? await Layout.newWindow(Capture.chromeID, before: before) : nil
                let noteWindows = hasNote ? await Layout.newWindows(Capture.obsidianID, before: before, count: notes) : []
                let agents = hasAgents ? await Layout.newWindow(Capture.itermID, before: before) : nil
                Capture.debug("layout: browser=\(browser != nil) notes=\(noteWindows.count) agents=\(agents != nil)")
                Layout.arrange(browser: browser, notes: noteWindows, agents: agents)
                if noteWindows.count > 1 { Layout.stack(Array(noteWindows.dropFirst()), over: noteWindows[0]) }
                if hasTabs { firstTabInFront() }
            }
        }
        return outcome
    }

    // MARK: Chrome

    /// Opens the URLs as one new window in the person's own Chrome. Chrome's command line hands them
    /// to the running instance with the default profile folder, never to an automation copy.
    static func openChromeWindow(_ urls: [String]) -> String? {
        guard !urls.isEmpty else { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Capture.chromeID) else { return "Chrome is not installed" }
        let process = Process()
        process.executableURL = appURL.appendingPathComponent("Contents/MacOS/Google Chrome")
        process.arguments = ["--new-window"] + urls
        do { try process.run() } catch { return "Chrome: \(error.localizedDescription)" }
        if let pid = Capture.humanChromePID() { NSRunningApplication(processIdentifier: pid)?.activate() }
        return nil
    }

    /// The first tab of the window just opened is the one in front (the paper, not the last link).
    static func firstTabInFront() {
        guard let (app, _) = Capture.chromeApp(),
              let front = ((app.value(forKey: "windows") as? SBElementArray) ?? SBElementArray()).firstObject as? SBObject else { return }
        front.setValue(1, forKey: "activeTabIndex")
    }

    @discardableResult
    static func focusTab(url: String) -> Bool {
        guard let (app, _) = Capture.chromeApp(), let pid = Capture.humanChromePID() else { return false }
        let windows = (app.value(forKey: "windows") as? SBElementArray) ?? SBElementArray()
        for element in windows {
            guard let window = element as? SBObject, let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            let urls = (tabs.value(forKey: "URL") as? [Any]) ?? []
            if let i = urls.firstIndex(where: { ($0 as? String) == url }) {
                window.setValue(i + 1, forKey: "activeTabIndex")
                window.setValue(1, forKey: "index")
                NSRunningApplication(processIdentifier: pid)?.activate()
                return true
            }
        }
        return false
    }

    // MARK: Claude Code in iTerm2

    static func isRunning(_ agent: DeskItem) -> Bool {
        guard let pid = agent.pid, kill(pid_t(pid), 0) == 0 else { return false }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["sessionId"] as? String) == agent.ref
    }

    @discardableResult
    static func focusAgent(pid: Int) -> Bool {
        guard let tty = Capture.tty(of: pid) else { return false }
        let script = """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(Capture.literal(tty)) then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "missing"
        end tell
        """
        return Capture.run(script).0 == "ok"
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Reopens stopped agents in one new iTerm2 window, each in its own pane, so every agent's work is visible:
    /// two side by side, three or four as a grid. Five or more continue as tabs.
    static func resumeAgents(_ agents: [DeskItem]) -> String? {
        guard !agents.isEmpty else { return nil }
        func command(_ agent: DeskItem) -> String {
            Capture.literal("cd \(shellQuote(agent.detail)) && claude --resume \(shellQuote(agent.ref))")
        }
        let grid = Array(agents.prefix(4))
        var script = """
        tell application id "com.googlecode.iterm2"
            activate
            set w to (create window with default profile)
            set s1 to current session of w
            tell s1 to write text \(command(grid[0]))

        """
        if grid.count >= 2 {
            script += "    tell s1 to set s2 to (split vertically with default profile)\n    tell s2 to write text \(command(grid[1]))\n"
        }
        if grid.count >= 3 {
            script += "    tell s1 to set s3 to (split horizontally with default profile)\n    tell s3 to write text \(command(grid[2]))\n"
        }
        if grid.count >= 4 {
            script += "    tell s2 to set s4 to (split horizontally with default profile)\n    tell s4 to write text \(command(grid[3]))\n"
        }
        for agent in agents.dropFirst(4) {
            script += "    tell w\n        set t to (create tab with default profile)\n        tell current session of t to write text \(command(agent))\n    end tell\n"
        }
        script += "end tell"
        let (_, error) = Capture.run(script)
        return error.map { "iTerm2: \($0)" }
    }

    // MARK: Put away

    /// Hides every other app's windows. Command+Tab brings any of them back.
    static func putAway() {
        NSWorkspace.shared.hideOtherApplications()
    }

    static func open(_ item: DeskItem) -> Outcome {
        switch item.kind {
        case .tab:
            if focusTab(url: item.ref) { return Outcome(opened: ["tab"]) }
            return bringBack([item])
        case .agent:
            if isRunning(item), let pid = item.pid, focusAgent(pid: pid) { return Outcome(opened: ["agent"]) }
            return bringBack([item])
        default:
            return bringBack([item])
        }
    }
}
