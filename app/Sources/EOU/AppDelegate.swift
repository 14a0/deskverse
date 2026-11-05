import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var launcher: LauncherController!
    private var hotKey: HotKey?
    private var timer: Timer?
    private var demoTake: DemoTake?
    private let store = Store.shared
    private let summaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Capture.watchFrontmost()
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, front != Bundle.main.bundleIdentifier {
            Capture.lastOtherFrontmost = front
        }
        launcher = LauncherController(store: store)
        hotKey = HotKey.registerLauncher { [weak self] in self?.launcher.toggle() }
        demoTake = DemoTake(launcher: launcher, store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: Profile.isMain ? "rectangle.stack" : "rectangle.stack.fill", accessibilityDescription: "EOU")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open EOU (\(hotKey?.label ?? "no hotkey"))", action: #selector(openLauncher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save this desk now", action: #selector(saveNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Put this desk away", action: #selector(putAway), keyEquivalent: "").target = self
        menu.addItem(.separator())
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(withTitle: "Show saved desks in Finder", action: #selector(showFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: Profile.isMain ? "Switch to demo profile" : "Switch to main profile", action: #selector(switchProfile), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit EOU", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu

        // Ask for Accessibility up front (moving restored windows and switching Desktops), unless already allowed.
        if !Layout.trusted { Layout.requestTrustIfNeeded() }
        // Test hook: --restore "<desk topic>" does exactly what Return does on that desk in the panel.
        if let i = CommandLine.arguments.firstIndex(of: "--restore"), i + 1 < CommandLine.arguments.count {
            let topic = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let desk = self.store.desks.first(where: { $0.topic == topic }) else {
                    Capture.debug("restore: no desk named \(topic)"); return
                }
                Capture.debug("restore: \(topic), \(desk.items.count) items, accessibility=\(Layout.trusted)")
                self.launcher.model.bringBackOnBlankDesktop(desk.items)
            }
        }
        // Test hook: --restore-file <items.json> brings back a desk described in a file, without saving it.
        if let i = CommandLine.arguments.firstIndex(of: "--restore-file"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let data = try? Data(contentsOf: url),
                      let items = try? JSONDecoder().decode([DeskItem].self, from: data) else {
                    Capture.debug("restore-file: could not read \(url.path)"); return
                }
                Capture.debug("restore-file: \(items.count) items, accessibility=\(Layout.trusted)")
                self.launcher.model.bringBackOnBlankDesktop(items, title: "Rehearsal desk is back", detail: "3 tabs, 1 note, 1 agent")
            }
        }
        if CommandLine.arguments.contains("--capture-now") {
            Task { await store.capture(force: true) }
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.launcher.show() }
        }

        // Save the desk by itself: shortly after launch, then every 10 minutes when something changed.
        // A scoped profile (the demo) never saves by itself, so it cannot pick up a private window.
        if Profile.autoSave {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                Task { await self?.store.capture(force: false) }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { Task { await self?.store.capture(force: false) } }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        let profile = Profile.isMain ? "" : "\(Profile.name.capitalized) profile: "
        if let latest = store.snapshots.first {
            summaryItem.title = "\(profile)\(store.snapshots.count) desks saved, last #\(latest.number) \(Fmt.when(latest.createdAt))"
        } else {
            summaryItem.title = "\(profile)No desks saved yet"
        }
    }

    @objc private func openLauncher() { launcher.show() }

    @objc private func saveNow() {
        Task { await store.capture(force: true) }
    }

    @objc private func putAway() {
        Task {
            await store.capture(force: false)
            Restore.putAway()
        }
    }

    @objc private func showFolder() { NSWorkspace.shared.open(store.folder) }

    @objc private func switchProfile() { Profile.switchTo(Profile.isMain ? "demo" : "main") }

    @objc private func quit() { NSApp.terminate(nil) }
}
