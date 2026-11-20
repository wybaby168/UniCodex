import Foundation

struct TranscriptLayoutRow: Sendable {
    let id: String
    let items: Range<Int>
    let top: CGFloat
    let height: CGFloat
    var textSize: MessageTextSize? = nil

    var bottom: CGFloat { top + height }
}

enum TranscriptLayout {
    static let padding: CGFloat = 20
    static let spacing: CGFloat = 15
    static let disclosureHeight: CGFloat = 23
    static let disclosureGap: CGFloat = 5
    static let headerHeight: CGFloat = 21
    static let headerGap: CGFloat = 7
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
                rows.append(.init(id: groupID, items: items, top: nextTop, height: height))
                index = end
                nextTop += height + spacing
                continue
            }

            let isCollapsed = record.kind == .reasoning && !expanded.contains(record.id)
            let entry = isCollapsed ? nil : snapshot.entry(index)
            let available = record.kind == .user ? max(25, width - leadingBubbleSpace - 2 * bubblePadding) : width
            let size = entry.map {
                MessageTextLayout.measure(
                    blocks(for: $0, in: snapshot.folder), width: available,
                    muted: record.kind == .reasoning, fitsContent: record.kind == .user)
            }
            let body = size?.height ?? 0
            let height: CGFloat
            switch record.kind {
            case .user: height = 2 * bubblePadding + body
            case .answer, .plan, .progress: height = headerHeight + headerGap + max(18, body)
            case .reasoning: height = disclosureHeight + (size == nil ? 0 : disclosureGap + body)
            case .activity: height = disclosureHeight
            }
            rows.append(.init(id: record.id, items: index..<(index + 1), top: nextTop, height: height, textSize: size))
            index += 1
            nextTop += height + spacing
        }
        return rows
    }

    static func blocks(for entry: TranscriptEntry, in folder: URL) -> [MessageDocument.Block] {
        return entry.document?.blocks ?? MessageDocument(entry.text, in: folder).blocks
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
