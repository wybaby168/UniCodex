import AppKit
import SwiftUI

struct MessageRun: Equatable, Sendable {
    var text: String
    var code = false
    var bold = false
    var italic = false
    var strike = false
    var link: URL?
}

enum TranscriptTypography {
    static let textSize: CGFloat = 13
    static let summarySize: CGFloat = 11
    static let lineSpacing: CGFloat = 2.5

    static func font(code: Bool = false, bold: Bool = false, muted: Bool = false) -> Font {
        .system(
            size: muted ? summarySize : textSize, weight: bold ? .semibold : .regular,
            design: code ? .monospaced : .default)
    }

    static func nativeFont(for run: MessageRun, muted: Bool = false, heading: Int? = nil, emphasized: Bool = false)
        -> NSFont
    {
        let weight: NSFont.Weight = run.bold || heading != nil || emphasized ? .semibold : .regular
        let body = muted ? summarySize : textSize
        let adjustment = heading.map { CGFloat(4 - min(4, max(1, $0))) * 1.5 } ?? 0
        let size = body + adjustment
        let font =
            run.code
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        guard run.italic else { return font }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits([.italic]), size: size) ?? font
    }
}

enum MessageMarkup {
    // Resolve paths lexically. Consult the filesystem only when the user opens a link.
    static func fileURL(_ reference: String, in folder: URL) -> URL? {
        let target = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target.utf8.count <= 4096,
            !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        let decoded: String
        if target.lowercased().hasPrefix("file:") {
            guard let url = URL(string: target), url.isFileURL else { return nil }
            let host = url.host?.lowercased() ?? ""
            guard host.isEmpty || host == "localhost" else { return nil }
            decoded = url.path
        } else {
            guard !target.contains("://") else { return nil }
            guard
                URLComponents(string: target)?.scheme == nil || target.hasPrefix("/") || target.hasPrefix("~")
                    || target.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) != nil
            else { return nil }
            decoded = target.removingPercentEncoding ?? target
        }
        guard !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let suffix = decoded.range(of: #"(?:#L\d+(?:C\d+)?|:\d+(?::\d+)?)$"#, options: .regularExpression)
        let path = suffix.map { String(decoded[..<$0.lowerBound]) } ?? decoded
        guard !path.isEmpty else { return nil }
        return candidate(path, in: folder)
    }

    static func existingFile(_ url: URL) -> URL? {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func runs(for text: String, in folder: URL) -> [MessageRun] {
        let parsed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        guard let parsed else { return references(in: MessageRun(text: text), folder: folder) }
        return parsed.runs.flatMap { run in
            runs(from: run, text: String(parsed[run.range].characters), in: folder, preserveLineBreaks: false)
        }
    }

    static func runs(
        from run: AttributedString.Runs.Run, text: String, in folder: URL,
        preserveLineBreaks: Bool
    ) -> [MessageRun] {
        let intent = run.inlinePresentationIntent
        var base = MessageRun(
            text: preserveLineBreaks && intent?.contains(.softBreak) == true ? "\n" : text,
            code: intent?.contains(.code) == true,
            bold: intent?.contains(.stronglyEmphasized) == true,
            italic: intent?.contains(.emphasized) == true,
            strike: intent?.contains(.strikethrough) == true
        )
        if let link = run.link ?? run.imageURL {
            if let scheme = link.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                base.link = link
            } else {
                base.link = fileURL(link.absoluteString, in: folder)
            }
            return [base]
        }
        return references(in: base, folder: folder)
    }

    private static func candidate(_ path: String, in folder: URL) -> URL {
        let path = (path as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return folder.appendingPathComponent(path).standardizedFileURL
    }

    private static let pathPattern = try! NSRegularExpression(
        pattern:
            #"(?<![\p{L}\p{N}_:/@.-])(?:file:///|~/|/|(?:\.\.?/)*)?(?:[\p{L}\p{N}_@%+.-]+/)*[\p{L}\p{N}_@%+.-]+\.[A-Za-z0-9]{1,16}(?::[0-9]+(?::[0-9]+)?|#L[0-9]+(?:C[0-9]+)?)?(?![\p{L}\p{N}_/])"#
    )

    private static func inferredFile(_ reference: String, in folder: URL) -> URL? {
        guard let path = fileURL(reference, in: folder) else { return nil }
        let explicitPath = ["file:///", "/", "~/", "./", "../"].contains { reference.hasPrefix($0) }
        if explicitPath { return path }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-./@%+:\\#()"))
        guard reference.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let commonNames = ["README", "LICENSE", "Makefile", "Dockerfile", "Gemfile", "Package.swift"]
        if commonNames.contains(path.lastPathComponent) { return path }
        let ext = path.pathExtension.lowercased()
        guard ext.range(of: #"[a-z]"#, options: .regularExpression) != nil,
            !["com", "net", "org", "edu", "gov"].contains(ext)
        else { return nil }
        return path
    }

    private static func references(in base: MessageRun, folder: URL) -> [MessageRun] {
        if base.code, let file = inferredFile(base.text, in: folder) {
            var run = base
            run.link = file
            return [run]
        }
        let text = base.text as NSString
        let matches = pathPattern.matches(in: base.text, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return [base] }
        var parts: [MessageRun] = []
        var offset = 0
        for match in matches.prefix(64) {
            let range = match.range
            guard let file = inferredFile(text.substring(with: range), in: folder) else { continue }
            if range.location > offset {
                parts.append(
                    MessageRun(
                        text: text.substring(with: NSRange(location: offset, length: range.location - offset)),
                        code: base.code, bold: base.bold, italic: base.italic, strike: base.strike
                    ))
            }
            parts.append(
                MessageRun(
                    text: text.substring(with: range), code: base.code,
                    bold: base.bold, italic: base.italic, strike: base.strike, link: file))
            offset = NSMaxRange(range)
        }
        if offset == 0 { return [base] }
        if offset < text.length {
            parts.append(
                MessageRun(
                    text: text.substring(from: offset), code: base.code,
                    bold: base.bold, italic: base.italic, strike: base.strike))
        }
        return parts
    }
}

enum MessageTextContent: Equatable {
    case runs([MessageRun], heading: Int? = nil)
    case table(MarkdownTable)
}

struct MessageParagraph: View {
    let content: MessageTextContent
    var muted = false
    @Environment(\.workbenchTheme) private var theme

    var body: some View {
        LinkedMessageText(content: content, theme: theme, muted: muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MessageTextLayout {
    static func attributed(_ content: MessageTextContent, muted: Bool) -> NSAttributedString {
        switch content {
        case .runs(let runs, let heading):
            let output = NSMutableAttributedString()
            append(runs, to: output, muted: muted, paragraph: paragraph(), heading: heading)
            return output
        case .table(let table):
            return attributedTable(table, muted: muted)
        }
    }

    private static func paragraph() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = TranscriptTypography.lineSpacing
        return style
    }

    private static func append(
        _ runs: [MessageRun], to result: NSMutableAttributedString, muted: Bool,
        paragraph: NSParagraphStyle, heading: Int? = nil, emphasized: Bool = false
    ) {
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: TranscriptTypography.nativeFont(
                    for: run, muted: muted, heading: heading, emphasized: emphasized),
                .foregroundColor: muted ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if let link = run.link { attributes[.link] = link }
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
    }

    private static func attributedTable(_ model: MarkdownTable, muted: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = model.columns.count
        table.layoutAlgorithm = .fixed
        table.collapsesBorders = true
        table.setValue(100, type: .percentage, for: .width)
        for (rowNumber, row) in model.rows.enumerated() {
            for (column, typed) in row.enumerated() where model.columns.indices.contains(column) {
                let style = paragraph()
                switch model.columns[column] {
                case .left: style.alignment = .left
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                }
                style.lineBreakMode = .byCharWrapping
                let cell = NSTextTableBlock(
                    table: table, startingRow: rowNumber, rowSpan: 1,
                    startingColumn: column, columnSpan: 1)
                cell.setWidth(6, type: .absolute, for: .padding)
                cell.setWidth(0.5, type: .absolute, for: .border)
                cell.setBorderColor(.separatorColor)
                if rowNumber == 0 { cell.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.09) }
                style.textBlocks = [cell]
                let runs = typed.isEmpty ? [MessageRun(text: "\u{00a0}")] : typed
                append(runs, to: output, muted: muted, paragraph: style, emphasized: rowNumber == 0)
                append([MessageRun(text: "\n")], to: output, muted: muted, paragraph: style)
            }
        }
        return output
    }

    static func measure(_ content: MessageTextContent, width: CGFloat, muted: Bool = false) -> CGSize {
        let storage = NSTextStorage(attributedString: attributed(content, muted: muted))
        let manager = NSLayoutManager()
        manager.backgroundLayoutEnabled = false
        let container = NSTextContainer(size: .init(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: min(width, max(1, ceil(used.maxX) + 2)), height: height(of: used))
    }

    static func height(of rect: CGRect) -> CGFloat {
        max(18, ceil(rect.maxY) + 1)
    }
}

private struct LinkedMessageText: NSViewRepresentable {
    let content: MessageTextContent
    let theme: WorkbenchTheme
    let muted: Bool

    func makeNSView(context: Context) -> LinkedTextView {
        let view = LinkedTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.delegate = view
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        _ = view.layoutManager
        return view
    }

    func updateNSView(_ view: LinkedTextView, context: Context) {
        let toneChanged = view.muted != muted
        if view.theme != theme || toneChanged {
            view.theme = theme
            view.muted = muted
            view.linkTextAttributes = [
                .foregroundColor: muted ? NSColor.secondaryLabelColor : theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
            view.needsDisplay = true
        }
        guard view.renderedContent != content || toneChanged else { return }
        view.renderedContent = content
        view.textStorage?.setAttributedString(MessageTextLayout.attributed(content, muted: muted))
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkedTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
            let container = nsView.textContainer, let manager = nsView.layoutManager
        else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: MessageTextLayout.height(of: manager.usedRect(for: container)))
    }
}

private final class LinkedTextView: NSTextView, NSTextViewDelegate {
    var renderedContent: MessageTextContent?
    var theme: WorkbenchTheme?
    var muted = false

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        if !url.isFileURL { return NSWorkspace.shared.open(url) }
        openFile(url)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let file = localLink(at: convert(event.locationInWindow, from: nil)) else {
            return super.menu(for: event)
        }
        let menu = NSMenu()
        let open = NSMenuItem(
            title: UIStrings.current.text("files.open"), action: #selector(openSelectedFile(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = file
        menu.addItem(open)
        let show = NSMenuItem(
            title: UIStrings.current.text("files.reveal"), action: #selector(revealSelectedFile(_:)), keyEquivalent: "")
        show.target = self
        show.representedObject = file
        menu.addItem(show)
        return menu
    }

    private func localLink(at point: NSPoint) -> URL? {
        guard let container = textContainer, let layout = layoutManager, let storage = textStorage,
            storage.length > 0, layout.numberOfGlyphs > 0
        else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs,
            layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local)
        else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL,
            url.isFileURL
        else { return nil }
        return url
    }

    private func openFile(_ file: URL) {
        guard let file = MessageMarkup.existingFile(file), NSWorkspace.shared.open(file) else {
            NSSound.beep()
            return
        }
    }

    @objc private func openSelectedFile(_ item: NSMenuItem) {
        if let file = item.representedObject as? URL { openFile(file) }
    }

    @objc private func revealSelectedFile(_ item: NSMenuItem) {
        guard let file = item.representedObject as? URL,
            let existing = MessageMarkup.existingFile(file)
        else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([existing])
    }
}
