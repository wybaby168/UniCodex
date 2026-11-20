import AppKit
import SwiftUI

struct TranscriptHostedRow: View {
    @Environment(\.uiStrings) private var strings
    let row: TranscriptLayoutRow
    let source: TranscriptSnapshot
    let session: WorkbenchSession
    let expanded: Set<String>
    @Environment(\.workbenchTheme) private var theme

    var body: some View {
        Group {
            switch source.records[row.items.lowerBound].kind {
            case .activity:
                tools
            case .reasoning:
                DisclosureGroup(isExpanded: expansion(row.id)) {
                    if expanded.contains(row.id), let entry = source.entry(row.items.lowerBound) {
                        messageBody(entry, muted: true).padding(.top, TranscriptLayout.disclosureGap)
                    }
                } label: {
                    label(strings.text("transcript.summary"), icon: "sparkle")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reasoning-disclosure")
            case .user, .answer, .progress:
                if let entry = source.entry(row.items.lowerBound) { message(entry) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func message(_ entry: TranscriptEntry) -> some View {
        if entry.kind == .user {
            HStack {
                Spacer(minLength: TranscriptLayout.leadingBubbleSpace)
                messageBody(entry)
                    .frame(width: row.bodyWidth)
                    .padding(TranscriptLayout.bubblePadding)
                    .background(theme.accent.opacity(0.10), in: .rect(cornerRadius: 13))
            }
        } else {
            VStack(alignment: .leading, spacing: TranscriptLayout.headerGap) {
                HStack {
                    Text(entry.kind == .progress ? strings.text("transcript.progress") : "Codex").font(
                        .callout.weight(.semibold))
                    Spacer()
                    if entry.kind == .answer {
                        Button(strings.text("transcript.copy"), systemImage: "document.on.document") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.text, forType: .string)
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }.frame(height: TranscriptLayout.headerHeight)
                messageBody(entry)
            }
        }
    }

    private func messageBody(_ entry: TranscriptEntry, muted: Bool = false) -> some View {
        TranscriptMessageBody(
            blocks: TranscriptLayout.blocks(for: entry, in: source.folder),
            sizes: row.textSizes, muted: muted)
    }

    private var tools: some View {
        Group {
            if row.items.count == 1 {
                operation(at: row.items.lowerBound)
            } else {
                DisclosureGroup(isExpanded: expansion(row.id)) {
                    if expanded.contains(row.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(row.items, id: \.self) { operation(at: $0) }
                        }.padding(.top, TranscriptLayout.disclosureGap)
                    }
                } label: {
                    label(toolGroupTitle, icon: "terminal")
                }
                .accessibilityIdentifier("tool-group")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var toolGroupTitle: String {
        let entries = source.records[row.items]
        let failed = entries.count { $0.activity?.state == .failed }
        let running = entries.count { $0.activity?.state == .running }
        var labels = [strings.text("transcript.operations", entries.count)]
        if running > 0 { labels.append(strings.text("transcript.running", running)) }
        if failed > 0 { labels.append(strings.text("transcript.failed", failed)) }
        return labels.joined(separator: " · ")
    }

    @ViewBuilder private func operation(at index: Int) -> some View {
        let record = source.records[index]
        if let activity = record.activity {
            if activity.logLines > 0 {
                DisclosureGroup(isExpanded: expansion(record.id)) {
                    if expanded.contains(record.id), let entry = source.entry(index) {
                        LogExcerpt(text: entry.detail, maximumLines: 11).padding(.top, TranscriptLayout.disclosureGap)
                    }
                } label: {
                    label(strings.activityTitle(activity.title), icon: "terminal")
                }
                .accessibilityIdentifier("operation-disclosure")
                .frame(minHeight: TranscriptLayout.disclosureHeight, alignment: .topLeading)
            } else {
                label(strings.activityTitle(activity.title), icon: "terminal")
                    .frame(height: TranscriptLayout.disclosureHeight, alignment: .topLeading)
            }
        }
    }

    private func label(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).frame(height: 17, alignment: .leading)
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(
            get: { session.expandedOperations.contains(key) },
            set: { open in
                if open { session.expandedOperations.insert(key) } else { session.expandedOperations.remove(key) }
            })
    }
}

struct LogExcerpt: View {
    let text: String
    let maximumLines: Int

    var body: some View {
        let lines = min(maximumLines, text.lazy.filter(\.isNewline).prefix(maximumLines - 1).count + 1)
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.vertical, 5)
        }
        .frame(height: CGFloat(lines) * 16 + 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptMessageBody: View {
    let blocks: [MessageDocument.Block]
    let sizes: [CGSize]
    let muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.bodySpacing) {
            ForEach(0..<min(blocks.count, sizes.count), id: \.self) { index in
                let size = sizes[index]
                let block = blocks[index]
                rendered(block, size: size)
                    .padding(.leading, block.indent.leading)
                    .overlay(alignment: .topLeading) { indentation(block.indent, height: size.height) }
            }
        }
    }

    @ViewBuilder
    private func rendered(_ block: MessageDocument.Block, size: CGSize) -> some View {
        switch block {
        case .paragraph(let runs, let style):
            MessageParagraph(content: .runs(runs, heading: style.heading), muted: muted)
                .frame(height: size.height)
                .accessibilityAddTraits(style.heading == nil ? [] : .isHeader)
        case .code(let code, let indent):
            ScrollView(.horizontal) {
                MessageParagraph(content: .runs([.init(text: code, code: true)]), muted: muted)
                    .frame(width: max(1, size.width - indent.leading - 20), height: size.height - 20)
                    .padding(10)
            }
            .frame(height: size.height)
            .background(.quaternary, in: .rect(cornerRadius: 8))
        case .table(let table, let indent):
            ScrollView(.horizontal) {
                MessageParagraph(content: .table(table), muted: muted)
                    .frame(width: max(1, size.width - indent.leading), height: size.height)
            }
            .frame(height: size.height)
            .clipShape(.rect(cornerRadius: 7))
        case .divider:
            Rectangle().fill(.quaternary).frame(height: 1).frame(height: size.height)
                .accessibilityHidden(true)
        }
    }

    private func indentation(_ indent: MarkdownIndent, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 10) {
                ForEach(0..<indent.quotes, id: \.self) { _ in
                    Capsule().fill(.secondary.opacity(0.34)).frame(width: 2, height: height)
                }
            }
            if let marker = indent.marker {
                Text(marker).font(
                    .system(size: muted ? TranscriptTypography.summarySize : TranscriptTypography.textSize)
                )
                .foregroundStyle(.secondary)
                .frame(width: indent.markerWidth - 7, alignment: .trailing)
                .padding(.leading, indent.markerX)
            }
        }
        .allowsHitTesting(false)
    }
}
