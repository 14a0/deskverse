import AppKit

/// Plays a demo take inside the real app, so a screen recording needs no synthetic keystrokes:
/// the panel opens, the sentence is typed into it at human speed, the real Llama matches it,
/// and the real bring-back runs. Triggered by a distributed notification from a small CLI:
///   name "com.14a0.eou.demo", object "save" | "bring:<sentence>" | "ask:<sentence>" | "putaway" | "show" | "close"
@MainActor
final class DemoTake {
    private let launcher: LauncherController
    private let store: Store

    init(launcher: LauncherController, store: Store) {
        self.launcher = launcher
        self.store = store
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.14a0.eou.demo"), object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(command) }
        }
    }

    private func run(_ command: String) {
        Capture.debug("demo take: \(command)")
        if command == "save" {
            Task { _ = await store.capture(force: true) }
        } else if command == "show" {
            launcher.show()
        } else if command == "close" {
            launcher.model.close()
        } else if command == "putaway" {
            Task {
                launcher.show()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await type("put away")
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                launcher.model.activateSelected(allVersions: false)
            }
        } else if command.hasPrefix("bring:") || command.hasPrefix("ask:") {
            let bring = command.hasPrefix("bring:")
            let sentence = String(command.drop(while: { $0 != ":" }).dropFirst())
            Task {
                launcher.show()
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                await type(sentence)
                // Wait for Llama's answer (a desk understood by meaning, or "no match").
                for _ in 0..<80 {
                    let understood = launcher.model.rows.contains { $0.subtitle.contains("understood by") }
                    if understood || launcher.model.status.hasPrefix("No saved desk") { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if bring { launcher.model.activateSelected(allVersions: false) }
            }
        }
    }

    /// Types into the panel's field the way a person would.
    private func type(_ text: String) async {
        for ch in text {
            launcher.model.query.append(ch)
            try? await Task.sleep(nanoseconds: UInt64(60_000_000 + Int.random(in: 0...45_000_000)))
        }
    }
}
