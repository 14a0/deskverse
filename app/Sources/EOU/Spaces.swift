import AppKit
import CoreGraphics

/// Uses the Mac's own Desktops: a desk you bring back lands on an empty Desktop.
/// Apple has no public API to create Desktops, so EOU moves right through the ones you have
/// (Control+Right, a standard macOS shortcut) until it finds one with nothing on it.
@MainActor
enum Spaces {
    /// The screen you are working on (the one with the pointer), in CoreGraphics coordinates (top-left origin).
    static func activeScreenRect() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let primaryHeight = NSScreen.screens[0].frame.height
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    /// True when the Desktop on the active screen shows any normal window other than EOU's own panel.
    /// Each screen has its own Desktops, so windows on other screens do not count.
    static func currentHasWindows() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let me = Int(getpid())
        let screen = activeScreenRect()
        return list.contains { window in
            let layer = window[kCGWindowLayer as String] as? Int ?? -1
            let owner = window[kCGWindowOwnerPID as String] as? Int ?? -1
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            let b = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            return layer == 0 && owner != me && alpha > 0 && rect.width > 60 && rect.height > 60 && screen.contains(center)
        }
    }

    /// How many Desktops the busiest display has, read from macOS's own Spaces preferences.
    static func desktopCount() -> Int {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.spaces.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let config = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let management = config["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]] else { return 1 }
        return monitors.map { ($0["Spaces"] as? [Any])?.count ?? 0 }.max() ?? 1
    }

    /// Presses Control+Right Arrow, the standard "Move right a space" shortcut.
    static func moveRight() {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        let down = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Goes to an empty Desktop. Returns false when every Desktop to the right has windows.
    static func goToEmptyDesktop() async -> Bool {
        Capture.debug("spaces: current has windows=\(currentHasWindows()), desktops=\(desktopCount()), trusted=\(Layout.trusted)")
        if !currentHasWindows() { return true }
        guard Layout.trusted else { Layout.requestTrustIfNeeded(); return false }
        for _ in 0..<max(0, desktopCount() - 1) {
            moveRight()
            try? await Task.sleep(nanoseconds: 750_000_000)
            if !currentHasWindows() { Capture.debug("spaces: found an empty Desktop"); return true }
        }
        Capture.debug("spaces: no empty Desktop to the right")
        return false
    }
}
