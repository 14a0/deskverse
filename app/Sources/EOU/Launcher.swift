import AppKit
import Combine
import SwiftUI

/// A borderless floating panel like Spotlight. It joins whichever Desktop you are on.
final class LauncherPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 120),
                   styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { queryChanged() } }
    @Published private(set) var rows: [ResultRow] = []
    @Published var selected = 0
    @Published var status = ""
    @Published var focusRequest = 0

    let store: Store
    var onClose: ((Bool) -> Void)?
    private var files: [URL] = []
    private var meaningTopic: String?
    private var meaningBy: String?
    private var pending: Task<Void, Never>?

    init(store: Store) { self.store = store }

    func prepare() {
        query = ""
        selected = 0
        files = []
        meaningTopic = nil
        meaningBy = nil
        status = defaultStatus()
        recompute()
        // Read what is open now right after the panel shows, so the panel itself appears at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.store.refreshLive()
            self.recompute()
        }
    }

    func defaultStatus() -> String {
        guard let latest = store.snapshots.first else { return "No desks yet. Type save to keep this one." }
        return "Desk #\(latest.number) saved \(Fmt.short(latest.createdAt))"
    }

    private func queryChanged() {
        files = []
        meaningTopic = nil
        meaningBy = nil
        selected = 0
        recompute()
        pending?.cancel()
        let q = query
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            // No file results: Spotlight already finds files, and they are noise next to desks.
            guard !Task.isCancelled, let self, self.query == q else { return }
            // A whole sentence that keywords cannot place: ask the on-device model which topic it means.
            let deskHits = self.rows.contains { if case .desk = $0.kind { return true } else { return false } }
            if !deskHits, Search.tokens(q).count >= 2 {
                self.status = "Understanding that on this Mac..."
                let match = await Search.meaning(of: q, desks: self.store.desks)
                guard !Task.isCancelled, self.query == q else { return }
                self.meaningTopic = match?.topic
                self.meaningBy = match?.by
                self.status = match == nil ? "No saved desk matches that yet." : self.defaultStatus()
                self.recompute()
            }
        }
    }

    func recompute() {
        rows = Search.rows(query: query, store: store, files: files, meaningTopic: meaningTopic, meaningBy: meaningBy)
        if selected >= rows.count { selected = max(0, rows.count - 1) }
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
    }

    func activateSelected(allVersions: Bool) {
        guard rows.indices.contains(selected) else { return }
        activate(rows[selected], allVersions: allVersions)
    }

    func activate(_ row: ResultRow, allVersions: Bool) {
        switch row.kind {
        case .command(.save):
            status = "Saving this desk..."
            Task {
                let snapshot = await store.capture(force: true)
                status = snapshot.map { "Saved desk #\($0.number): \($0.items.count) items in \(Set($0.items.compactMap(\.topic)).count) topics." } ?? "Nothing to save."
                recompute()
            }
        case .command(.putAway):
            onClose?(false)
            Task {
                await store.capture(force: false)
                Restore.putAway()
                let number = store.snapshots.first?.number ?? 0
                Toast.show(title: "Desk put away", detail: "Saved as #\(number). Nothing was closed.")
            }
        case .desk(let desk):
            onClose?(false)
            let items = allVersions ? desk.allVersionsItems : desk.items
            let versions = allVersions && !desk.earlier.isEmpty ? " and \(desk.earlier.count) earlier" : ""
            bringBackOnBlankDesktop(items, title: "\(desk.title) is back", detail: desk.receipt.map { "Left off: \($0)" }
                                    ?? "Desk #\(desk.snapshotNumber)\(versions) · \(desk.countsLine)")
        case .whole(let snapshot):
            onClose?(false)
            bringBackOnBlankDesktop(snapshot.items.filter { $0.kind != .app }, title: "Desk #\(snapshot.number) is back",
                                    detail: "\(snapshot.items.count) items")
        case .live(let item):
            onClose?(false)
            _ = Restore.open(item)
        case .file(let url):
            onClose?(false)
            NSWorkspace.shared.open(url)
        }
    }

    /// Saves the desk you are leaving, finds an empty Desktop (or clears this one by hiding windows),
    /// then lays the chosen desk out there.
    func bringBackOnBlankDesktop(_ items: [DeskItem], title: String = "Desk is back", detail: String? = nil) {
        Task {
            await store.capture(force: false)
            if await !Spaces.goToEmptyDesktop() {
                Restore.putAway()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            _ = Restore.bringBack(items)
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            Toast.show(title: title, detail: detail, note: "Not kept: scroll positions and typed text")
        }
    }

    func close() { onClose?(true) }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var fieldFocused: Bool

    private var listHeight: CGFloat {
        let base = CGFloat(model.rows.count) * 54 + 12
        let selectedHasDetail = model.rows.indices.contains(model.selected) && model.rows[model.selected].detail != nil
        return min(460, base + (selectedHasDetail ? 18 : 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField("What were you working on?", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .regular))
                    .focused($fieldFocused)
                    .onSubmit { model.activateSelected(allVersions: NSEvent.modifierFlags.contains(.option)) }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 17)

            if !model.rows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                RowView(row: row, selected: index == model.selected)
                                    .id(row.id)
                                    .onTapGesture {
                                        model.selected = index
                                        model.activateSelected(allVersions: NSEvent.modifierFlags.contains(.option))
                                    }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.never)
                    .frame(height: listHeight)
                    .onChange(of: model.selected) { _, newValue in
                        if model.rows.indices.contains(newValue) { proxy.scrollTo(model.rows[newValue].id) }
                    }
                }
                .animation(.snappy(duration: 0.18), value: model.selected)
                .animation(.easeOut(duration: 0.15), value: model.rows.map(\.id))
            }

            if !model.status.isEmpty {
                HStack {
                    Text(model.status).lineLimit(1)
                    Spacer()
                    Text("↩ bring back   ⌥↩ every version")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
                .padding(.top, model.rows.isEmpty ? 0 : 2)
            }
        }
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45)), in: .rect(cornerRadius: 26))
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusRequest) { _, _ in fieldFocused = true }
    }
}

/// The real icons of the apps a desk will open, slightly overlapping, like a small stack of papers.
struct IconStack: View {
    let bundleIDs: [String]

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(bundleIDs.enumerated()), id: \.offset) { index, id in
                if let image = AppIcons.icon(id) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                        .offset(x: CGFloat(index) * 15)
                        .zIndex(Double(bundleIDs.count - index))
                }
            }
        }
        .frame(width: 30 + CGFloat(max(0, bundleIDs.count - 1)) * 15, height: 30, alignment: .leading)
    }
}

struct RowView: View {
    let row: ResultRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if row.icons.isEmpty {
                    Image(systemName: row.symbol)
                        .font(.system(size: 17))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                } else {
                    IconStack(bundleIDs: row.icons)
                }
            }
            .frame(width: 75, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                if selected, let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 8)
            Text(row.accessory)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
    }
}

/// Shows and hides the panel, and handles the arrow and escape keys.
@MainActor
final class LauncherController: NSObject, NSWindowDelegate {
    let model: LauncherModel
    let panel: LauncherPanel
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var hosting: NSHostingView<LauncherView>!
    private var rowsWatch: AnyCancellable?

    init(store: Store) {
        model = LauncherModel(store: store)
        let host = NSHostingView(rootView: LauncherView(model: model))
        panel = LauncherPanel(content: host)
        super.init()
        hosting = host
        // Keep the window exactly as tall as its content, growing downward from a fixed top edge.
        rowsWatch = model.$rows.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent() }
        }
        panel.delegate = self
        model.onClose = { [weak self] restoreFocus in self?.hide(restoreFocus: restoreFocus) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 125: self.model.move(1); return nil        // down
            case 126: self.model.move(-1); return nil       // up
            case 53: self.hide(restoreFocus: true); return nil // escape
            default: return event
            }
        }
    }

    func toggle() {
        if panel.isVisible { hide(restoreFocus: true) } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
            Capture.lastOtherFrontmost = front?.bundleIdentifier
        }
        model.prepare()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if let frame = screen?.visibleFrame {
            let top = frame.maxY - frame.height * 0.22
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: false)
        }
        NSApp.activate()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        model.focusRequest += 1
    }

    private func fitToContent() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.height > 0, abs(size.height - panel.frame.height) > 0.5 || abs(size.width - panel.frame.width) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
        if restoreFocus { previousApp?.activate() }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide(restoreFocus: false)
    }
}
