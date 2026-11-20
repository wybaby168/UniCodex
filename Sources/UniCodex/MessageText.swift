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

struct MessageTextSize: Equatable, Sendable {
    let viewportWidth: CGFloat
    let documentWidth: CGFloat
    let height: CGFloat

    var scrollsHorizontally: Bool { documentWidth > viewportWidth }
}

enum MessageTextLayout {
    private static let codePadding: CGFloat = 10
    private static let minimumColumnWidth: CGFloat = 94
    private static let blockGap: CGFloat = 9

    static func measure(
        _ blocks: [MessageDocument.Block], width: CGFloat, muted: Bool = false, fitsContent: Bool = false
    ) -> MessageTextSize {
        let documentWidth = blocks.reduce(width) { result, block in
            switch block {
            case .code(let text, let indent):
                let font = TranscriptTypography.nativeFont(for: .init(text: "", code: true), muted: muted)
                var widest: CGFloat = 0
                text.enumerateLines { line, _ in
                    widest = max(widest, (line as NSString).size(withAttributes: [.font: font]).width)
                }
                return max(result, min(1_000_000, ceil(widest) + 2 + 2 * codePadding + indent.leading))
            case .table(let table, let indent):
                return max(result, minimumColumnWidth * CGFloat(table.columns.count) + indent.leading)
            default:
                return result
            }
        }
        let preview = MessageTextSize(viewportWidth: width, documentWidth: documentWidth, height: 0)
        let storage = NSTextStorage(attributedString: attributed(blocks, size: preview, muted: muted))
        let manager = NSLayoutManager()
        manager.backgroundLayoutEnabled = false
        let container = NSTextContainer(size: .init(width: documentWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let height = max(18, ceil(used.maxY) + 1)
        if fitsContent && !preview.scrollsHorizontally
            && blocks.allSatisfy({
                if case .paragraph(_, let style) = $0 { return style.indent.quotes == 0 }
                return false
            })
        {
            let fitted = min(width, max(1, ceil(used.maxX) + 2))
            return .init(viewportWidth: fitted, documentWidth: fitted, height: height)
        }
        return .init(viewportWidth: width, documentWidth: documentWidth, height: height)
    }

    static func attributed(
        _ blocks: [MessageDocument.Block], size: MessageTextSize, muted: Bool
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for block in blocks {
            if output.length > 0 { separateBlocks(in: output) }
            let indent = block.indent
            let quoteWidth: CGFloat
            switch block {
            case .code, .table: quoteWidth = size.documentWidth
            case .paragraph, .divider: quoteWidth = size.viewportWidth
            }
            let quote = quoteBlocks(indent.quotes, width: quoteWidth)
            let leading = indent.leading - indent.quoteWidth
            let style = paragraph()
            style.firstLineHeadIndent = leading
            style.headIndent = leading
            style.textBlocks = quote
            switch block {
            case .paragraph(let runs, let markdown):
                if quote.isEmpty { style.tailIndent = size.viewportWidth - size.documentWidth }
                if let marker = indent.marker {
                    style.firstLineHeadIndent = indent.markerX - indent.quoteWidth
                    style.tabStops = [NSTextTab(textAlignment: .left, location: leading)]
                    append([.init(text: marker + "\t")], to: output, muted: muted, paragraph: style)
                }
                append(runs, to: output, muted: muted, paragraph: style, heading: markdown.heading)
            case .code(let raw, _):
                let code = NSTextBlock()
                code.setContentWidth(max(1, size.documentWidth - indent.leading - 2 * codePadding), type: .absolute)
                code.setWidth(codePadding, type: .absolute, for: .padding)
                code.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                style.textBlocks.append(code)
                style.lineBreakMode = .byCharWrapping
                let text = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
                append(
                    [.init(text: text.isEmpty ? "\u{00a0}" : text, code: true)], to: output, muted: muted,
                    paragraph: style)
            case .table(let table, _):
                appendTable(
                    table, to: output, leading: leading, quotes: quote,
                    width: max(
                        size.viewportWidth - indent.leading, minimumColumnWidth * CGFloat(table.columns.count)),
                    muted: muted)
            case .divider:
                let line = NSTextBlock()
                line.setContentWidth(max(1, size.viewportWidth - indent.leading), type: .absolute)
                setEdge(line, border: 1, padding: 0, at: .minYEdge)
                line.setBorderColor(.separatorColor)
                style.textBlocks.append(line)
                style.minimumLineHeight = 4
                style.maximumLineHeight = 4
                output.append(
                    NSAttributedString(
                        string: "\u{00a0}",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style,
                        ]))
            }
        }
        return output
    }

    private static func paragraph() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = TranscriptTypography.lineSpacing
        return style
    }

    private static func separateBlocks(in output: NSMutableAttributedString) {
        let last = output.length - 1
        if output.mutableString.character(at: last) != 10 {
            output.append(
                NSAttributedString(string: "\n", attributes: output.attributes(at: last, effectiveRange: nil)))
        }
        let gap = NSMutableParagraphStyle()
        gap.minimumLineHeight = blockGap
        gap.maximumLineHeight = blockGap
        output.append(
            NSAttributedString(
                string: "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: gap,
                ]))
    }

    private static func quoteBlocks(_ count: Int, width: CGFloat) -> [NSTextBlock] {
        (0..<count).map { index in
            let quote = NSTextBlock()
            let inset = MarkdownIndent(quotes: index + 1).quoteWidth
            quote.setContentWidth(max(1, width - inset), type: .absolute)
            setEdge(quote, border: 2, padding: 10, at: .minXEdge)
            quote.setBorderColor(.separatorColor)
            return quote
        }
    }

    private static func setEdge(_ block: NSTextBlock, border: CGFloat, padding: CGFloat, at edge: CGRectEdge) {
        if #available(macOS 27, *) {
            block.setWidth(border, type: .absolute, for: .border, rectEdge: edge)
            block.setWidth(padding, type: .absolute, for: .padding, rectEdge: edge)
        } else {
            let legacy: NSRectEdge = edge == .minXEdge ? .minX : .minY
            block.setWidth(border, type: .absolute, for: .border, edge: legacy)
            block.setWidth(padding, type: .absolute, for: .padding, edge: legacy)
        }
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

    private static func appendTable(
        _ model: MarkdownTable, to output: NSMutableAttributedString, leading: CGFloat, quotes: [NSTextBlock],
        width: CGFloat, muted: Bool
    ) {
        let table = NSTextTable()
        table.numberOfColumns = model.columns.count
        table.layoutAlgorithm = .fixed
        table.collapsesBorders = true
        table.setContentWidth(width, type: .absolute)
        for (rowNumber, row) in model.rows.enumerated() {
            for (column, typed) in row.enumerated() where model.columns.indices.contains(column) {
                let style = paragraph()
                style.firstLineHeadIndent = leading
                style.headIndent = leading
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
                style.textBlocks = quotes + [cell]
                let runs = typed.isEmpty ? [MessageRun(text: "\u{00a0}")] : typed
                append(runs, to: output, muted: muted, paragraph: style, emphasized: rowNumber == 0)
                append([MessageRun(text: "\n")], to: output, muted: muted, paragraph: style)
            }
        }
    }
}

struct LinkedMessageText: NSViewRepresentable {
    let blocks: [MessageDocument.Block]
    let size: MessageTextSize
    let theme: WorkbenchTheme
    let muted: Bool

    func makeNSView(context: Context) -> LinkedTextView {
        LinkedTextView.readOnly()
    }

    func updateNSView(_ view: LinkedTextView, context: Context) {
        if view.theme != theme || view.muted != muted {
            view.theme = theme
            view.linkTextAttributes = [
                .foregroundColor: muted ? NSColor.secondaryLabelColor : theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
            view.needsDisplay = true
        }
        view.update(blocks, size: size, muted: muted)
    }
}

final class LinkedTextView: NSTextView, NSTextViewDelegate {
    private var blocks: [MessageDocument.Block]?
    private var size: MessageTextSize?
    var theme: WorkbenchTheme?
    private(set) var muted = false

    static func readOnly() -> LinkedTextView {
        let view = LinkedTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.delegate = view
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        _ = view.layoutManager
        return view
    }

    func update(_ blocks: [MessageDocument.Block], size: MessageTextSize, muted: Bool) {
        guard self.blocks != blocks || self.size != size || self.muted != muted else { return }
        self.blocks = blocks
        self.size = size
        self.muted = muted

        let attributed = MessageTextLayout.attributed(blocks, size: size, muted: muted)
        let previous = string as NSString
        let current = attributed.string as NSString
        let selection = selectedRanges
        let canRestore =
            selection.contains { $0.rangeValue.length > 0 }
            && selection.allSatisfy { value in
                let range = value.rangeValue
                guard range.location != NSNotFound, NSMaxRange(range) <= min(previous.length, current.length) else {
                    return false
                }
                let prefix = NSRange(location: 0, length: NSMaxRange(range))
                return previous.substring(with: prefix) == current.substring(with: prefix)
            }
        textContainer?.containerSize = NSSize(width: size.documentWidth, height: .greatestFiniteMagnitude)
        textStorage?.setAttributedString(attributed)
        if canRestore { selectedRanges = selection }
    }

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
        if selectedRanges.contains(where: { $0.rangeValue.length > 0 }) {
            menu.addItem(.separator())
            let copy = NSMenuItem(
                title: UIStrings.current.text("transcript.copy_selection"),
                action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
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
