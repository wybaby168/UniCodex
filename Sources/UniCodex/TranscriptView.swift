import AppKit
import SwiftUI

struct TranscriptHostedRow: View {
    @Environment(\.uiStrings) private var strings
    let row: TranscriptLayoutRow
    let source: TranscriptSnapshot
    let session: WorkbenchSession
    let expanded: Set<String>
    @Environment(\.workbenchTheme) private var theme
    @State private var copied: UUID?

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
            case .user, .answer, .plan, .progress:
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
                    .padding(TranscriptLayout.bubblePadding)
                    .background(theme.accent.opacity(0.10), in: .rect(cornerRadius: 13))
            }
        } else {
            VStack(alignment: .leading, spacing: TranscriptLayout.headerGap) {
                HStack {
                    switch entry.kind {
                    case .plan:
                        Label(strings.text("mode.proposed_plan"), systemImage: "list.bullet.clipboard")
                            .foregroundStyle(theme.accent)
                    case .progress:
                        Text(strings.text("transcript.progress"))
                    default:
                        Text("Codex")
                    }
                    Spacer()
                    copyButton(for: entry)
                }
                .font(.callout.weight(.semibold))
                .frame(height: TranscriptLayout.headerHeight)
                messageBody(entry)
            }
        }
    }

    private func copyButton(for entry: TranscriptEntry) -> some View {
        let key =
            switch entry.kind {
            case .plan: "mode.copy_plan"
            case .progress: "transcript.copy_progress"
            default: "transcript.copy"
            }
        return Button {
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            if clipboard.setString(entry.text, forType: .string) { copied = UUID() }
        } label: {
            Image(systemName: copied == nil ? "document.on.document" : "checkmark")
                .frame(width: 24, height: TranscriptLayout.headerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(strings.text(copied == nil ? key : "transcript.copied"))
        .help(strings.text(copied == nil ? key : "transcript.copied"))
        .task(id: copied) {
            guard copied != nil else { return }
            do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
            copied = nil
        }
    }

    @ViewBuilder
    private func messageBody(_ entry: TranscriptEntry, muted: Bool = false) -> some View {
        if let size = row.textSize {
            let text = LinkedMessageText(
                blocks: TranscriptLayout.blocks(for: entry, in: source.folder),
                size: size, theme: theme, muted: muted
            )
            .frame(width: size.documentWidth, height: size.height)
            if size.scrollsHorizontally {
                ScrollView(.horizontal) { text }
                    .frame(width: size.viewportWidth, height: size.height)
            } else {
                text
            }
        }
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
