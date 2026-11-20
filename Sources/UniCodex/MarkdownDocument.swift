import Foundation

struct MarkdownIndent: Equatable, Sendable {
    var quotes = 0
    var lists = 0
    var marker: String?

    var quoteWidth: CGFloat { CGFloat(quotes) * 12 }
    var markerX: CGFloat { quoteWidth + CGFloat(max(0, lists - 1)) * 17 }
    var markerWidth: CGFloat { lists == 0 ? 0 : max(24, CGFloat(marker?.count ?? 0) * 8 + 6) }
    var leading: CGFloat { markerX + markerWidth }
}

struct MarkdownStyle: Equatable, Sendable {
    var heading: Int?
    var indent = MarkdownIndent()
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case left, center, right }
    let columns: [Alignment]
    let rows: [[[MessageRun]]]
}

struct MessageDocument: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case paragraph([MessageRun], style: MarkdownStyle = MarkdownStyle())
        case code(String, indent: MarkdownIndent = MarkdownIndent())
        case table(MarkdownTable, indent: MarkdownIndent)
        case divider(MarkdownIndent)

        var indent: MarkdownIndent {
            switch self {
            case .paragraph(_, let style): style.indent
            case .code(_, let indent), .table(_, let indent), .divider(let indent): indent
            }
        }
    }

    let blocks: [Block]

    init(_ text: String, in folder: URL) {
        let taskMarkers = text.contains("[ ]") || text.contains("[x]") || text.contains("[X]")
        guard
            let parsed = try? AttributedString(
                markdown: text,
                options: .init(
                    interpretedSyntax: .full, appliesSourcePositionAttributes: taskMarkers
                ))
        else {
            blocks = [.paragraph(MessageMarkup.runs(for: text, in: folder))]
            return
        }
        var builder = MarkdownBuilder(sourceLines: taskMarkers ? text.components(separatedBy: .newlines) : [])
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let value = String(parsed[run.range].characters)
            let isCode: Bool
            if case .codeBlock = components.first?.kind { isCode = true } else { isCode = false }
            let runs =
                isCode
                ? [MessageRun(text: value, code: true)]
                : MessageMarkup.runs(from: run, text: value, in: folder, preserveLineBreaks: true)
            builder.append(runs, components: components, line: run.markdownSourcePosition?.startLine)
        }
        builder.finish()
        blocks = builder.blocks
    }
}

private struct MarkdownBuilder {
    typealias Component = PresentationIntent.IntentType

    private struct Leaf {
        let components: [Component]
        let line: Int?
        var runs: [MessageRun] = []
    }

    private struct Table {
        let id: Int
        let columns: [MarkdownTable.Alignment]
        let indent: MarkdownIndent
        var rows: [[[MessageRun]]] = []

        mutating func append(row: Int, column: Int, runs: [MessageRun]) {
            guard columns.indices.contains(column), row >= 0 else { return }
            while rows.count <= row { rows.append(Array(repeating: [], count: columns.count)) }
            rows[row][column].append(contentsOf: runs)
        }
    }

    let sourceLines: [String]
    private(set) var blocks: [MessageDocument.Block] = []
    private var current: Leaf?
    private var table: Table?
    private var listedItems = Set<Int>()

    init(sourceLines: [String]) { self.sourceLines = sourceLines }

    mutating func append(_ runs: [MessageRun], components: [Component], line: Int?) {
        if current?.components.first?.identity != components.first?.identity { flushLeaf() }
        if current == nil { current = Leaf(components: components, line: line) }
        current?.runs.append(contentsOf: runs)
    }

    mutating func finish() {
        flushLeaf()
        flushTable()
    }

    private mutating func flushLeaf() {
        guard let leaf = current else { return }
        current = nil
        if case .tableCell(let column) = leaf.components.first?.kind,
            let tableComponent = leaf.components.first(where: { if case .table = $0.kind { true } else { false } }),
            case .table(let columns) = tableComponent.kind
        {
            if table?.id != tableComponent.identity {
                flushTable()
                table = Table(
                    id: tableComponent.identity, columns: columns.map(Self.alignment),
                    indent: indentation(leaf.components))
            }
            let row =
                leaf.components.compactMap { component -> Int? in
                    switch component.kind {
                    case .tableHeaderRow: return 0
                    case .tableRow(let number): return number
                    default: return nil
                    }
                }.first ?? 0
            table?.append(row: row, column: column, runs: leaf.runs)
            return
        }
        flushTable()
        var indent = indentation(leaf.components)
        switch leaf.components.first?.kind {
        case .header(let level):
            blocks.append(.paragraph(leaf.runs, style: MarkdownStyle(heading: level, indent: indent)))
        case .codeBlock:
            blocks.append(.code(leaf.runs.map(\.text).joined(), indent: indent))
        case .thematicBreak:
            blocks.append(.divider(indent))
        default:
            var runs = leaf.runs
            if indent.marker != nil, let line = leaf.line, let checked = taskMarker(at: line),
                let first = runs.first, first.text.count >= 3, first.text.first == "[",
                first.text.dropFirst(2).first == "]", !first.code, first.link == nil
            {
                indent.marker = checked ? "☑" : "☐"
                let remainder = first.text.dropFirst(3).drop(while: { $0 == " " || $0 == "\t" })
                runs[0].text = String(remainder)
            }
            if !runs.isEmpty { blocks.append(.paragraph(runs, style: MarkdownStyle(indent: indent))) }
        }
    }

    private mutating func flushTable() {
        guard let table else { return }
        self.table = nil
        if !table.columns.isEmpty && !table.rows.isEmpty {
            blocks.append(.table(MarkdownTable(columns: table.columns, rows: table.rows), indent: table.indent))
        }
    }

    private mutating func indentation(_ components: [Component]) -> MarkdownIndent {
        var indent = MarkdownIndent()
        var item: (id: Int, ordinal: Int)?
        var firstListIsOrdered: Bool?
        for component in components {
            switch component.kind {
            case .blockQuote: indent.quotes += 1
            case .listItem(let ordinal):
                if item == nil { item = (component.identity, ordinal) }
            case .orderedList, .unorderedList:
                indent.lists += 1
                if firstListIsOrdered == nil {
                    if case .orderedList = component.kind {
                        firstListIsOrdered = true
                    } else {
                        firstListIsOrdered = false
                    }
                }
            default: break
            }
        }
        if let item, listedItems.insert(item.id).inserted {
            indent.marker = firstListIsOrdered == true ? "\(item.ordinal)." : (indent.lists > 1 ? "◦" : "•")
        }
        indent.quotes = min(indent.quotes, 4)
        indent.lists = min(indent.lists, 5)
        return indent
    }

    private func taskMarker(at line: Int) -> Bool? {
        let index = line - 1
        guard sourceLines.indices.contains(index) else { return nil }
        let original = sourceLines[index]
        guard
            let match = original.range(
                of: #"^\s*(?:>\s*)*(?:[-+*]|\d+[.)])\s+\[[ xX]\](?=\s|$)"#,
                options: .regularExpression)
        else { return nil }
        return original[match].contains("[x]") || original[match].contains("[X]")
    }

    private static func alignment(_ column: PresentationIntent.TableColumn) -> MarkdownTable.Alignment {
        switch column.alignment {
        case .center: .center
        case .right: .right
        default: .left
        }
    }
}
