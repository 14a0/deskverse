import AppKit

/// Which set of desks EOU uses. "main" is everything; a named profile (for example "demo", for recording
/// in Hao's own account) has its own saved desks and only sees what its scope allows.
/// Choose with `--profile demo`, or the menu; the choice is remembered.
@MainActor
enum Profile {
    struct Scope: Codable {
        /// Claude Code sessions are seen only when they run inside one of these folders.
        var agentsUnder: [String]?
        /// Obsidian notes are read only from these vaults.
        var vaults: [String]?
        /// Chrome: "all" windows, or only those on the "currentDesktop".
        var chromeWindows: String?
        /// Chrome windows count only when every tab's address starts with one of these (a demo can never pick up a private window).
        var chromeOnlyURLsStartingWith: [String]?
        /// Finder windows are seen.
        var folders: Bool?
        /// Other apps are seen only when listed here (bundle ids). Empty means none.
        var apps: [String]?
        /// The desk saves itself every 10 minutes.
        var autoSave: Bool?
    }

    static var name: String {
        if let i = CommandLine.arguments.firstIndex(of: "--profile"), i + 1 < CommandLine.arguments.count {
            let chosen = CommandLine.arguments[i + 1]
            UserDefaults.standard.set(chosen, forKey: "profile")
            return chosen
        }
        return UserDefaults.standard.string(forKey: "profile") ?? "main"
    }

    static var isMain: Bool { name == "main" }

    /// Where this profile keeps its desks.
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EOU")
        return isMain ? support : support.appendingPathComponent("profiles/\(name)")
    }

    /// The scope of a named profile, from `scope.json` in its folder. The main profile sees everything.
    static var scope: Scope? {
        guard !isMain else { return nil }
        let url = folder.appendingPathComponent("scope.json")
        if let data = try? Data(contentsOf: url), let scope = try? JSONDecoder().decode(Scope.self, from: data) { return scope }
        // A named profile without a scope file sees nothing private: no agents, no notes, Chrome on this Desktop only.
        return Scope(agentsUnder: [], vaults: [], chromeWindows: "currentDesktop", folders: false, apps: [], autoSave: false)
    }

    static var autoSave: Bool { scope?.autoSave ?? true }

    /// Switches profile and relaunches EOU.
    static func switchTo(_ newName: String) {
        UserDefaults.standard.set(newName, forKey: "profile")
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--profile", newName]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
