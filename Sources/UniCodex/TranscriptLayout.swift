import Foundation

struct TranscriptLayoutRow: Sendable {
    let id: String
    let items: Range<Int>
    let top: CGFloat
    let height: CGFloat
    let textSizes: [CGSize]
    var bodyWidth: CGFloat? = nil

    var bottom: CGFloat { top + height }
}

enum TranscriptLayout {
    static let padding: CGFloat = 20
    static let spacing: CGFloat = 15
    static let disclosureHeight: CGFloat = 23
    static let disclosureGap: CGFloat = 5
    static let headerHeight: CGFloat = 21
    static let headerGap: CGFloat = 7
    static let bodySpacing: CGFloat = 9
    static let bubblePadding: CGFloat = 11
    static let leadingBubbleSpace: CGFloat = 54
    private static let maxToolGroup = 24

    static func rows(
        in snapshot: TranscriptSnapshot, startingAt start: Int, top: CGFloat, width: CGFloat,
        expanded: Set<String>
    ) -> [TranscriptLayoutRow] {
        var rows: [TranscriptLayoutRow] = []
        var nextTop = top
        var index = start
        while index < snapshot.records.count && !Task.isCancelled {
            let record = snapshot.records[index]
            if record.kind == .activity {
                var end = index + 1
                while end < snapshot.records.count && end - index < maxToolGroup
                    && snapshot.records[end].kind == .activity
                {
                    end += 1
                }
                let items = index..<end
                let groupID = "tools:\(record.id)"
                let height = toolHeight(snapshot.records[items], groupID: groupID, expanded: expanded)
                rows.append(.init(id: groupID, items: items, top: nextTop, height: height, textSizes: []))
                index = end
                nextTop += height + spacing
                continue
            }

            let isCollapsed = record.kind == .reasoning && !expanded.contains(record.id)
            let entry = isCollapsed ? nil : snapshot.entry(index)
            let sizes = entry.map { textSizes(for: $0, width: width, folder: snapshot.folder) } ?? []
            let body = sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * bodySpacing
            let height: CGFloat
            switch record.kind {
            case .user: height = 2 * bubblePadding + body
            case .answer, .progress: height = headerHeight + headerGap + max(18, body)
            case .reasoning: height = disclosureHeight + (sizes.isEmpty ? 0 : disclosureGap + body)
            case .activity: height = disclosureHeight
            }
            let bodyWidth =
                record.kind == .user
                ? min(
                    messageWidth(for: .user, width: width),
                    sizes.map(\.width).max() ?? 1) : nil
            rows.append(
                .init(
                    id: record.id, items: index..<(index + 1), top: nextTop, height: height,
                    textSizes: sizes, bodyWidth: bodyWidth))
            index += 1
            nextTop += height + spacing
        }
        return rows
    }

    static func blocks(for entry: TranscriptEntry, in folder: URL) -> [MessageDocument.Block] {
        return entry.document?.blocks ?? MessageDocument(entry.text, in: folder).blocks
    }

    private static func messageWidth(for kind: TranscriptEntry.Kind, width: CGFloat) -> CGFloat {
        kind == .user ? max(25, width - leadingBubbleSpace - 2 * bubblePadding) : width
    }

    private static func textSizes(for entry: TranscriptEntry, width: CGFloat, folder: URL) -> [CGSize] {
        let available = messageWidth(for: entry.kind, width: width)
        let muted = entry.kind == .reasoning
        return blocks(for: entry, in: folder).map { block in
            let leading = block.indent.leading
            let textWidth = max(1, available - leading)
            switch block {
            case .paragraph(let runs, let style):
                let size = MessageTextLayout.measure(
                    .runs(runs, heading: style.heading), width: textWidth, muted: muted)
                return .init(width: size.width + leading, height: size.height)
            case .code(let text, _):
                let size = MessageTextLayout.measure(
                    .runs([.init(text: text, code: true)]),
                    width: 1_000_000, muted: muted)
                return .init(width: size.width + leading + 20, height: size.height + 20)
            case .table(let table, _):
                let width = max(textWidth, CGFloat(table.columns.count) * 94)
                let size = MessageTextLayout.measure(.table(table), width: width, muted: muted)
                return .init(width: width + leading, height: size.height)
            case .divider:
                return .init(width: available, height: 8)
            }
        }
    }

    private static func toolHeight(
        _ tools: ArraySlice<TranscriptRecord>, groupID: String,
        expanded: Set<String>
    ) -> CGFloat {
        if tools.count > 1 && !expanded.contains(groupID) { return disclosureHeight }
        let height =
            tools.reduce(0) { total, tool in
                let lines = tool.activity?.logLines ?? 0
                let detail = lines > 0 && expanded.contains(tool.id) ? CGFloat(lines * 16 + 10) + disclosureGap : 0
                return total + disclosureHeight + detail
            } + CGFloat(max(0, tools.count - 1)) * 4
        return tools.count > 1 ? height + disclosureHeight + disclosureGap : height
    }
}
