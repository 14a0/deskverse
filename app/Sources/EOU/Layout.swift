import AppKit
import ApplicationServices

/// Lays a restored desk out calmly: browser on the left, note top right, agents bottom right.
/// Moves windows only; never touches files. Needs Accessibility permission; without it, it does nothing.
@MainActor
enum Layout {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Asks for Accessibility once (macOS shows its own prompt).
    static func requestTrustIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Arranges the main window of each app that was just brought back.
    static func arrange(browser: AXUIElement?, notes: [AXUIElement], agents: AXUIElement?) {
        let note = notes.first
        guard trusted else { requestTrustIfNeeded(); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let full = screen.frame
        let visible = screen.visibleFrame
        let gap: CGFloat = 10
        // AX uses a top-left origin measured from the top of the primary screen.
        let primaryHeight = NSScreen.screens[0].frame.height
        let top = primaryHeight - visible.maxY + gap
        let left = visible.minX + gap
        let width = visible.width - gap * 3
        let height = visible.height - gap * 2
        let fullWidth = visible.width - gap * 2
        _ = full

        // Without a browser, the note and the agents share the screen: note left, agents right (or one fills it).
        guard let browser else {
            switch (note, agents) {
            case let (n?, a?):
                let half = ((fullWidth - gap) / 2).rounded()
                place(n, x: left, y: top, w: half, h: height)
                place(a, x: left + half + gap, y: top, w: fullWidth - half - gap, h: height)
            case let (n?, nil): place(n, x: left, y: top, w: fullWidth, h: height)
            case let (nil, a?): place(a, x: left, y: top, w: fullWidth, h: height)
            default: break
            }
            return
        }
        // The cockpit: browser on the left half, notes top right, the agents' panes bottom right.
        let rightColumn = note != nil || agents != nil
        let browserWidth = rightColumn ? (width * 0.5).rounded() : fullWidth
        let rightX = left + browserWidth + gap
        let rightWidth = width - browserWidth
        place(browser, x: left, y: top, w: browserWidth, h: height)
        switch (note, agents) {
        case let (n?, a?):
            let noteHeight = ((height - gap) * 0.42).rounded()
            place(n, x: rightX, y: top, w: rightWidth, h: noteHeight)
            place(a, x: rightX, y: top + noteHeight + gap, w: rightWidth, h: height - noteHeight - gap)
        case let (n?, nil):
            place(n, x: rightX, y: top, w: rightWidth, h: height)
        case let (nil, a?):
            place(a, x: rightX, y: top, w: rightWidth, h: height)
        default:
            break
        }
    }

    /// Extra note windows sit on the first like papers on a desk, each a little lower and to the right.
    static func stack(_ extra: [AXUIElement], over first: AXUIElement) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(first, kAXPositionAttribute as CFString, &value) == .success, let v = value else { return }
        var origin = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &origin)
        var sizeRef: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(first, kAXSizeAttribute as CFString, &sizeRef) == .success, let sv = sizeRef {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }
        for (i, window) in extra.enumerated() {
            let step = CGFloat(i + 1) * 28
            place(window, x: origin.x + step, y: origin.y + step, w: size.width - step, h: size.height - step)
        }
    }

    private static func place(_ window: AXUIElement, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        var origin = CGPoint(x: x, y: y)
        var size = CGSize(width: w, height: h)
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// All windows an app has, through Accessibility.
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// Windows of each app before a restore, so only the windows the restore opens get moved.
    static func snapshot(_ bundleIDs: [String]) -> [String: [AXUIElement]] {
        guard trusted else { return [:] }
        var out: [String: [AXUIElement]] = [:]
        for id in bundleIDs {
            let pid = id == Capture.chromeID ? Capture.humanChromePID() : self.pid(id)
            if let pid { out[id] = windows(of: pid) }
        }
        return out
    }

    /// Every window the app has now that it did not have before (waits for at least `count` of them, up to about 3 s).
    static func newWindows(_ bundleID: String, before: [String: [AXUIElement]], count: Int) async -> [AXUIElement] {
        var found: [AXUIElement] = []
        for _ in 0..<40 {
            let pid = bundleID == Capture.chromeID ? Capture.humanChromePID() : self.pid(bundleID)
            if let pid {
                let old = before[bundleID] ?? []
                found = windows(of: pid).filter { w in !old.contains { CFEqual($0, w) } }
                if found.count >= count { return found }
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return found
    }

    /// A window the app has now that it did not have before. Waits up to about 3 seconds for it to appear.
    static func newWindow(_ bundleID: String, before: [String: [AXUIElement]]) async -> AXUIElement? {
        for _ in 0..<40 {
            let pid = bundleID == Capture.chromeID ? Capture.humanChromePID() : self.pid(bundleID)
            if let pid {
                let old = before[bundleID] ?? []
                if let fresh = windows(of: pid).first(where: { w in !old.contains { CFEqual($0, w) } }) { return fresh }
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return nil
    }

    static func pid(_ bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }
}
