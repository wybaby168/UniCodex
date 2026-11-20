import AppKit
import SwiftUI

struct SessionTranscript: View {
    let session: WorkbenchSession
    @Environment(\.workbenchTheme) private var theme
    @Environment(\.uiStrings) private var strings

    var body: some View {
        NativeTranscript(
            session: session, revision: session.revision, expanded: session.expandedOperations,
            theme: theme, strings: strings)
    }
}

private struct NativeTranscript: NSViewRepresentable {
    let session: WorkbenchSession
    let revision: Int
    let expanded: Set<String>
    let theme: WorkbenchTheme
    let strings: UIStrings

    func makeCoordinator() -> TranscriptViewport { TranscriptViewport(session: session) }

    func makeNSView(context: Context) -> TranscriptScrollContainer {
        let view = TranscriptScrollContainer()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: TranscriptScrollContainer, context: Context) {
        context.coordinator.update(revision: revision, expanded: expanded, theme: theme, strings: strings)
    }

    static func dismantleNSView(_ view: TranscriptScrollContainer, coordinator: TranscriptViewport) {
        coordinator.detach()
    }
}

private final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class TranscriptScrollContainer: NSView {
    let scrollView = NSScrollView()
    let document = TranscriptDocumentView()
    private let progress = NSProgressIndicator()
    var onLayout: (() -> Void)?

    init() {
        super.init(frame: .zero)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.isHidden = true
        addSubview(scrollView)
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        addSubview(progress)
    }

    required init?(coder: NSCoder) { nil }

    func updateAccessibility(using strings: UIStrings) {
        scrollView.setAccessibilityLabel(strings.text("transcript.label"))
        progress.setAccessibilityLabel(strings.text("transcript.layout"))
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        scrollView.layoutSubtreeIfNeeded()
        progress.frame = NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        onLayout?()
    }

    func showTranscript() {
        progress.stopAnimation(nil)
        progress.isHidden = true
        scrollView.isHidden = false
    }
}

@MainActor
private final class TranscriptViewport: NSObject {
    private struct MountedRow {
        let id: String
        let host: NSHostingView<AnyView>
    }

    private let session: WorkbenchSession
    private weak var view: TranscriptScrollContainer?
    private var source: TranscriptSnapshot?
    private var rows: [TranscriptLayoutRow] = []
    private var mounted: [Int: MountedRow] = [:]
    private var reusable: [NSHostingView<AnyView>] = []
    private var worker: Task<[TranscriptLayoutRow], Never>?
    private var dirtyFrom: Int? = 0
    private var revision: Int?
    private var expanded: Set<String> = []
    private var shownExpansion: Set<String> = []
    private var theme = WorkbenchTheme.ocean
    private var strings: UIStrings?
    private var measuredWidth: CGFloat = 0
    private var viewportWidth: CGFloat = 0
    private var renderScheduled = false
    private var hasOpened = false

    init(session: WorkbenchSession) { self.session = session }

    func attach(_ view: TranscriptScrollContainer) {
        self.view = view
        view.onLayout = { [weak self] in self?.viewportResized() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: view.scrollView.contentView)
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        worker?.cancel()
        view?.onLayout = nil
        view = nil
    }

    func update(revision: Int, expanded: Set<String>, theme: WorkbenchTheme, strings: UIStrings) {
        if self.revision != revision {
            self.revision = revision
            if let changed = session.takeChangedTranscriptRange() { invalidate(from: changed) }
        }
        if self.expanded != expanded {
            for key in self.expanded.symmetricDifference(expanded) {
                let id = key.hasPrefix("tools:") ? String(key.dropFirst(6)) : key
                if let index = session.transcriptPosition(of: id) { invalidate(from: index) }
            }
            self.expanded = expanded
        }
        if self.theme != theme || self.strings != strings {
            self.theme = theme
            self.strings = strings
            view?.updateAccessibility(using: strings)
            removeRows(atOrAfter: 0)
            scheduleRender()
        }
        scheduleLayout()
    }

    private var contentWidth: CGFloat { min(750, max(90, viewportWidth - 52)) }

    private func viewportResized() {
        guard let view else { return }
        let width = floor(view.scrollView.contentView.bounds.width)
        guard width != viewportWidth, width > 0 else { return }
        viewportWidth = width
        if contentWidth != measuredWidth { invalidate(from: 0) }
        updateDocumentFrame()
        scheduleLayout()
        scheduleRender()
    }

    private func invalidate(from index: Int) { dirtyFrom = min(index, dirtyFrom ?? index) }

    private func scheduleLayout() {
        guard worker == nil, viewportWidth > 0, let dirtyFrom else { return }
        self.dirtyFrom = nil
        let width = contentWidth
        let snapshot = session.transcriptSnapshot()
        let expansion = expanded
        let first = width == measuredWidth ? rebuildStart(for: dirtyFrom) : 0
        let start = first < rows.count ? rows[first].items.lowerBound : rows.last?.items.upperBound ?? 0
        let top =
            first < rows.count
            ? rows[first].top
            : rows.last.map { $0.bottom + TranscriptLayout.spacing } ?? TranscriptLayout.padding
        let task = Task.detached(priority: .userInitiated) {
            TranscriptLayout.rows(in: snapshot, startingAt: start, top: top, width: width, expanded: expansion)
        }
        worker = task
        Task { [weak self] in
            let measured = await task.value
            guard let self, !task.isCancelled, let view = self.view else { return }
            self.worker = nil
            if width == self.contentWidth {
                self.rows.replaceSubrange(first..., with: measured)
                self.source = snapshot
                self.shownExpansion = expansion
                self.measuredWidth = width
                self.updateDocumentFrame()
                if !self.hasOpened && !self.rows.isEmpty {
                    self.hasOpened = true
                    let scroll = view.scrollView
                    let bottom = max(0, view.document.frame.height - scroll.contentView.bounds.height)
                    // Set the initial position while the new document is still hidden.
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    view.showTranscript()
                }
                self.render(refreshFrom: first)
            } else {
                self.invalidate(from: 0)
            }
            self.scheduleLayout()
        }
    }

    private func rebuildStart(for index: Int) -> Int {
        let row = firstRow { $0.items.upperBound > index }
        // An appended tool may join the previous group. Ordinary rows can keep their text view and selection.
        if row > 0 && rows[row - 1].id.hasPrefix("tools:") { return row - 1 }
        return row
    }

    private func updateDocumentFrame() {
        guard let view else { return }
        let height = (rows.last?.bottom ?? 0) + TranscriptLayout.padding
        let size = CGSize(width: viewportWidth, height: height)
        if view.document.frame.size != size { view.document.setFrameSize(size) }
    }

    @objc private func clipChanged(_ notification: Notification) { scheduleRender() }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    private func render(refreshFrom: Int? = nil) {
        guard let view, let source, let strings else { return }
        let viewport = view.scrollView.documentVisibleRect
        let overscan = min(480, viewport.height * 0.7)
        let first = firstRow { $0.bottom >= viewport.minY - overscan }
        let end = firstRow { $0.top > viewport.maxY + overscan }
        let visible = first..<max(first, end)

        // Scrolling only changes the mounted cells. The document rectangle and
        // AppKit's clip view position are untouched on this path.
        for index in Array(mounted.keys) where !visible.contains(index) { recycle(index) }
        for index in visible {
            let row = rows[index]
            let host: NSHostingView<AnyView>
            if let existing = mounted[index], existing.id == row.id {
                host = existing.host
                if let refreshFrom, index >= refreshFrom {
                    host.rootView = rowContent(row, source: source, strings: strings)
                }
            } else {
                recycle(index)
                host = reusable.popLast() ?? NSHostingView(rootView: AnyView(EmptyView()))
                host.sizingOptions = []
                host.rootView = rowContent(row, source: source, strings: strings)
                mounted[index] = MountedRow(id: row.id, host: host)
                view.document.addSubview(host)
            }
            let frame = NSRect(
                x: (viewportWidth - measuredWidth) / 2, y: row.top, width: measuredWidth, height: row.height)
            if host.frame != frame { host.frame = frame }
        }
    }

    private func rowContent(_ row: TranscriptLayoutRow, source: TranscriptSnapshot, strings: UIStrings) -> AnyView {
        AnyView(
            TranscriptHostedRow(row: row, source: source, session: session, expanded: shownExpansion)
                .environment(\.workbenchTheme, theme)
                .environment(\.uiStrings, strings)
                .environment(\.locale, strings.locale)
                .tint(theme.accent)
                .id(row.id))
    }

    private func firstRow(where predicate: (TranscriptLayoutRow) -> Bool) -> Int {
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if predicate(rows[middle]) { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }

    private func removeRows(atOrAfter index: Int) {
        for key in Array(mounted.keys) where key >= index { recycle(key) }
    }

    private func recycle(_ index: Int) {
        guard let host = mounted.removeValue(forKey: index)?.host else { return }
        host.removeFromSuperview()
        host.rootView = AnyView(EmptyView())
        if reusable.count < 12 { reusable.append(host) }
    }
}
