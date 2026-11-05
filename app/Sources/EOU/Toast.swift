import AppKit
import SwiftUI

/// A quiet confirmation at the top of the screen, gone after a few seconds. Never takes focus or clicks.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0

    static func show(title: String, detail: String?, note: String? = nil) {
        generation += 1
        let mine = generation
        let host = NSHostingView(rootView: ToastView(title: title, detail: detail, note: note))
        let size = host.fittingSize
        let toast = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toast.level = .statusBar
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = true
        toast.ignoresMouseEvents = true
        toast.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        toast.contentView = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        toast.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 18, width: size.width, height: size.height), display: true)
        toast.alphaValue = 0
        toast.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; toast.animator().alphaValue = 1 }
        panel = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            guard mine == generation else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; toast.animator().alphaValue = 0 },
                                                 completionHandler: { if mine == generation { toast.orderOut(nil) } })
        }
    }
}

struct ToastView: View {
    let title: String
    let detail: String?
    var note: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .fixedSize()
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45)), in: .rect(cornerRadius: 20))
    }
}
