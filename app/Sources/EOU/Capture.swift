import AppKit
import ApplicationServices
import ScriptingBridge

/// Reads what is open on the desk right now. Read only: nothing here changes any app.
@MainActor
enum Capture {
    static let chromeID = "com.google.Chrome"
    static let itermID = "com.googlecode.iterm2"
    static let obsidianID = "md.obsidian"
    static let spotifyID = "com.spotify.client"
    static let finderID = "com.apple.finder"

    /// The last app in front that was not EOU, so a save from the panel knows what you were working in.
    static var lastOtherFrontmost: String?
    static func watchFrontmost() {
        NotificationCenter.default.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier, id != Bundle.main.bundleIdentifier {
                MainActor.assumeIsolated { lastOtherFrontmost = id }
            }
        }
    }

    static let fieldSep = "\u{1F}"
    static let recordSep = "\u{1E}"

    struct Result {
        var items: [DeskItem]
        var problems: [String]
        /// Bundle id of the app in front when the capture ran.
        var frontmostApp: String?
    }

    static func everything() -> Result {
        var problems: [String] = []
        var items: [DeskItem] = []
        let scope = Profile.scope
        var tabs = chromeTabs(&problems, currentDesktopOnly: scope?.chromeWindows == "currentDesktop")
        if let allowed = scope?.chromeOnlyURLsStartingWith {
            // Keep a window only when all of its tabs are allowed.
            let windows = Dictionary(grouping: tabs, by: { $0.window ?? 0 })
            let clean = Set(windows.filter { _, wtabs in wtabs.allSatisfy { tab in allowed.contains { tab.ref.hasPrefix($0) } } }.keys)
            tabs = tabs.filter { clean.contains($0.window ?? 0) }
        }
        items += tabs
        let agents = claudeSessions()
        if let under = scope?.agentsUnder {
            items += agents.filter { agent in under.contains { agent.detail == $0 || agent.detail.hasPrefix($0 + "/") } }
        } else {
            items += agents
        }
        items += obsidianNotes(&problems, onlyVaults: scope?.vaults)
        if scope?.folders ?? true { items += finderFolders(&problems) }
        items += spotify(&problems)
        if let allowed = scope?.apps {
            items += otherApps().filter { allowed.contains($0.ref) }
        } else {
            items += otherApps()
        }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }
        var front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == Bundle.main.bundleIdentifier { front = lastOtherFrontmost }
        return Result(items: items, problems: problems, frontmostApp: front)
    }

    // MARK: AppleScript helpers

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Runs AppleScript on the main thread. Returns the string result or an error message.
    static func run(_ source: String) -> (String?, String?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (nil, "script did not compile") }
        let output = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "error"
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 { return (nil, "no Automation permission (System Settings, Privacy and Security, Automation)") }
            return (nil, message)
        }
        return (output.stringValue ?? "", nil)
    }

    /// Escapes text for use inside an AppleScript string literal.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Chrome

    /// Appends one line to ~/Library/Application Support/EOU/capture.log.
    static func debug(_ line: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("EOU/capture.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The person's own Chrome. Automation copies (a debugging port, headless) share the bundle id
    /// and would answer Apple Events with no windows, so they are skipped.
    static func humanChromePID() -> pid_t? {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).map(\.processIdentifier)
        return pids.first { pid in
            let args = arguments(of: Int(pid))
            return !args.contains("--remote-debugging-port") && !args.contains("--headless") && !args.contains("--user-data-dir")
        } ?? pids.first
    }

    static func arguments(of pid: Int) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "args=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    final class BridgeErrors: NSObject, SBApplicationDelegate {
        var last: String?
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
            let code = (error as NSError).code
            last = code == -1743 ? "no Automation permission (System Settings, Privacy and Security, Automation)" : error.localizedDescription
            return nil
        }
    }

    static func chromeApp() -> (SBApplication, BridgeErrors)? {
        guard let pid = humanChromePID(), let app = SBApplication(processIdentifier: pid) else { return nil }
        let errors = BridgeErrors()
        app.delegate = errors
        return (app, errors)
    }

    /// Frames of the person's Chrome windows that are on screen right now (this Desktop, the active screen).
    static func chromeFramesOnThisDesktop() -> [CGRect] {
        guard let pid = humanChromePID(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let screen = Spaces.activeScreenRect()
        return list.compactMap { w -> CGRect? in
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid), (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return rect.width > 100 && screen.contains(CGPoint(x: rect.midX, y: rect.midY)) ? rect : nil
        }
    }

    /// Titles of the person's Chrome windows on the current Desktop. Accessibility lists only this Desktop's
    /// windows, which positions cannot do: maximised windows on different Desktops share one frame.
    static func chromeTitlesOnThisDesktop() -> [String] {
        guard let pid = humanChromePID() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { w in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return t as? String
        }
    }

    static func chromeTabs(_ problems: inout [String], currentDesktopOnly: Bool = false) -> [DeskItem] {
        guard let (app, errors) = chromeApp() else { debug("chrome: not running"); return [] }
        var items: [DeskItem] = []
        let windows = (app.value(forKey: "windows") as? SBElementArray) ?? SBElementArray()
        let titlesHere = currentDesktopOnly ? chromeTitlesOnThisDesktop() : []
        if currentDesktopOnly && titlesHere.isEmpty { debug("chrome: no windows on this Desktop (or no Accessibility)"); return [] }
        for (index, element) in windows.enumerated() {
            guard let window = element as? SBObject else { continue }
            if (window.value(forKey: "mode") as? String) == "incognito" { continue }
            if currentDesktopOnly {
                // A Chrome window is on this Desktop when its title (the front tab's) heads one of this Desktop's window titles.
                let front = (window.value(forKey: "activeTab") as? SBObject)?.value(forKey: "title") as? String ?? ""
                guard !front.isEmpty, titlesHere.contains(where: { $0.hasPrefix(front) }) else { continue }
            }
            guard let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            let urls = (tabs.value(forKey: "URL") as? [Any]) ?? []
            let titles = (tabs.value(forKey: "title") as? [Any]) ?? []
            for (i, rawURL) in urls.enumerated() {
                guard let url = rawURL as? String, !url.isEmpty, !url.hasPrefix("chrome://newtab") else { continue }
                let title = (i < titles.count ? titles[i] as? String : nil).flatMap { $0.isEmpty ? nil : $0 } ?? url
                items.append(DeskItem(kind: .tab, title: title, detail: url, ref: url, window: index + 1))
            }
        }
        debug("chrome: windows=\(windows.count) tabs=\(items.count) error=\(errors.last ?? "none")")
        if let error = errors.last { problems.append("Chrome tabs: \(error)") }
        return items
    }

    // MARK: Claude Code

    /// Running Claude Code sessions, from the files Claude Code keeps in ~/.claude/sessions/<pid>.json.
    static func claudeSessions() -> [DeskItem] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var items: [DeskItem] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String,
                  kill(pid_t(pid), 0) == 0 else { continue }
            let name = (json["name"] as? String) ?? URL(fileURLWithPath: cwd).lastPathComponent
            items.append(DeskItem(kind: .agent, title: name, detail: cwd, ref: sessionId, pid: pid, state: json["status"] as? String))
        }
        return items.sorted { $0.title < $1.title }
    }

    // MARK: Obsidian

    static func openVaultPath() -> String? {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return nil }
        return vaults.values.first { ($0["open"] as? Bool) == true }?["path"] as? String
    }

    static func obsidianNotes(_ problems: inout [String], onlyVaults: [String]? = nil) -> [DeskItem] {
        guard isRunning(obsidianID) else { return [] }
        if let onlyVaults {
            return onlyVaults.flatMap { notes(inVault: $0, &problems) }
        }
        guard let vault = openVaultPath() else { return [] }
        return notes(inVault: vault, &problems)
    }

    /// Notes open in one vault: its main window and any pop-out windows.
    static func notes(inVault vault: String, _ problems: inout [String]) -> [DeskItem] {
        let workspace = URL(fileURLWithPath: vault).appendingPathComponent(".obsidian/workspace.json")
        guard let data = try? Data(contentsOf: workspace),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            problems.append("Obsidian: could not read the open vault's workspace")
            return []
        }
        var files: [String] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if (dict["type"] as? String) == "leaf",
                   let state = dict["state"] as? [String: Any],
                   (state["type"] as? String) == "markdown",
                   let inner = state["state"] as? [String: Any],
                   let file = inner["file"] as? String {
                    files.append(file)
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        if let dict = json as? [String: Any] {
            if let main = dict["main"] { walk(main) }
            if let floating = dict["floating"] { walk(floating) }
        }
        let vaultName = URL(fileURLWithPath: vault).lastPathComponent
        var seen = Set<String>()
        return files.filter { seen.insert($0).inserted }.map { file in
            let url = URL(fileURLWithPath: file)
            let folder = url.deletingLastPathComponent().relativePath
            return DeskItem(kind: .note, title: url.deletingPathExtension().lastPathComponent,
                            detail: folder == "." ? vaultName : "\(vaultName)/\(folder)",
                            ref: (vault as NSString).appendingPathComponent(file))
        }
    }

    // MARK: Finder

    static func finderFolders(_ problems: inout [String]) -> [DeskItem] {
        let source = """
        tell application id "com.apple.finder"
            set rs to (character id 30)
            set out to ""
            repeat with w in Finder windows
                try
                    set out to out & (POSIX path of (target of w as alias)) & rs
                end try
            end repeat
            return out
        end tell
        """
        let (output, error) = run(source)
        if let error { problems.append("Finder: \(error)"); return [] }
        return (output ?? "").components(separatedBy: recordSep).filter { !$0.isEmpty }.map { path in
            let url = URL(fileURLWithPath: path)
            return DeskItem(kind: .folder, title: url.lastPathComponent, detail: url.deletingLastPathComponent().path, ref: path)
        }
    }

    // MARK: Spotify

    static func spotify(_ problems: inout [String]) -> [DeskItem] {
        guard isRunning(spotifyID) else { return [] }
        let source = """
        tell application id "com.spotify.client"
            if player state is playing then
                return (spotify url of current track) & (character id 31) & (name of current track) & (character id 31) & (artist of current track)
            end if
            return ""
        end tell
        """
        let (output, error) = run(source)
        if let error { problems.append("Spotify: \(error)"); return [] }
        let f = (output ?? "").components(separatedBy: fieldSep)
        guard f.count >= 3, !f[0].isEmpty else { return [] }
        return [DeskItem(kind: .music, title: f[1], detail: f[2], ref: f[0])]
    }

    // MARK: Other apps

    static let coveredApps: Set<String> = [chromeID, itermID, obsidianID, spotifyID, finderID,
                                            "com.apple.systempreferences", "com.14a0.eou"]

    static func otherApps() -> [DeskItem] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> DeskItem? in
                guard let id = app.bundleIdentifier, !coveredApps.contains(id) else { return nil }
                return DeskItem(kind: .app, title: app.localizedName ?? id, detail: id, ref: id)
            }
    }

    /// The last thing a Claude Code session said, from its own transcript (read locally, last 64 KB only).
    nonisolated static func lastAgentMessage(sessionId: String) -> String? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        guard let file = dirs.map({ $0.appendingPathComponent("\(sessionId).jsonl") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (json["type"] as? String) == "assistant",
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let said = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            let clean = said.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { return String(clean.prefix(400)) }
        }
        return nil
    }

    /// The terminal device of a process, for example "/dev/ttys003".
    static func tty(of pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw != "??" else { return nil }
        return raw.hasPrefix("/dev/") ? raw : "/dev/" + raw
    }
}
