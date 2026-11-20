import AppKit
import SwiftUI

struct SessionSidebar: View {
    @Environment(\.uiStrings) private var strings
    let workbench: Workbench
    @State private var showingArchives = false
    @FocusState private var focusedConversation: UUID?
    @Environment(\.workbenchTheme) private var theme

    var body: some View {
        ScrollViewReader { scroll in
            List {
                Section {
                    ForEach(workbench.sessions) { session in
                        ConversationRow(
                            workbench: workbench, session: session, selected: workbench.selected === session,
                            sidebarFocus: $focusedConversation
                        ) { direction in
                            moveFocus(from: session, direction: direction, scroll: scroll)
                        }
                        .id(session.id)
                    }
                    if workbench.moreConversations {
                        Button(strings.text("sidebar.more")) { workbench.loadMoreConversations() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(strings.text("sidebar.chats"))
                        Spacer()
                        if workbench.numberRunning > 0 {
                            Text(strings.text("sidebar.running", workbench.numberRunning)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
        .sheet(isPresented: $showingArchives) { ArchivedConversations(workbench: workbench) }
    }

    private func moveFocus(from session: WorkbenchSession, direction: MoveCommandDirection, scroll: ScrollViewProxy) {
        guard let index = workbench.sessions.firstIndex(where: { $0 === session }) else { return }
        let adjacent: Int
        switch direction {
        case .up: adjacent = index - 1
        case .down: adjacent = index + 1
        default: return
        }
        guard workbench.sessions.indices.contains(adjacent) else { return }
        let next = workbench.sessions[adjacent]
        withoutSessionAnimation {
            scroll.scrollTo(next.id)
            workbench.focus(next)
            focusedConversation = next.id
        }
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit()
                    .frame(width: 35, height: 35)
                    .accessibilityHidden(true)
                Text("UniCodex")
                    .font(.title3.weight(.semibold))
            }
            sidebarControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var sidebarControls: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 10) {
                    newConversation.buttonStyle(.glassProminent).tint(theme.actionTint)
                    archivesButton.buttonStyle(.glass).tint(.clear)
                }
                .buttonBorderShape(.capsule)
            }
        } else {
            HStack(spacing: 10) {
                newConversation.buttonStyle(.borderedProminent).tint(theme.actionTint)
                archivesButton.buttonStyle(.bordered)
            }
        }
    }

    private var newConversation: some View {
        Button {
            withoutSessionAnimation { workbench.newConversation() }
        } label: {
            Label(strings.text("common.new_chat"), systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .help(strings.text("sidebar.shortcut"))
    }

    private var archivesButton: some View {
        Button {
            showingArchives = true
        } label: {
            Image(systemName: "archivebox").foregroundStyle(theme.accent)
        }
        .accessibilityLabel(strings.text("sidebar.archived"))
        .controlSize(.regular)
        .help(strings.text("sidebar.archived_help"))
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: connectionSymbol).foregroundStyle(.tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connectionTitle).font(.caption.weight(.medium))
                    Text(strings.text("sidebar.direct", workbench.profile(for: workbench.selected).name))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 2)
                if workbench.connection == .unavailable {
                    Button(strings.text("connection.reconnect")) { workbench.connect() }.controlSize(.small)
                }
                SettingsLink {
                    Label(strings.text("settings.title"), systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(strings.text("settings.title"))
                .help(strings.text("settings.title") + " (⌘,)")
                .accessibilityIdentifier("sidebar-preferences")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var connectionTitle: String {
        switch workbench.connection {
        case .connecting: strings.text("connection.connecting")
        case .ready:
            workbench.providers.configured(workbench.profile(for: workbench.selected))
                ? strings.text("connection.loaded") : strings.text("connection.need_key")
        case .unavailable: strings.text("connection.offline")
        }
    }

    private var connectionSymbol: String {
        switch workbench.connection {
        case .connecting: "circle.dotted"
        case .ready:
            workbench.providers.configured(workbench.profile(for: workbench.selected)) ? "checkmark.circle.fill" : "key"
        case .unavailable: "exclamationmark.circle"
        }
    }
}

private struct ConversationRow: View {
    @Environment(\.uiStrings) private var strings
    let workbench: Workbench
    let session: WorkbenchSession
    var selected = false
    var sidebarFocus: FocusState<UUID?>.Binding?
    var move: ((MoveCommandDirection) -> Void)?
    @State private var hovered = false
    @State private var renaming = false
    @State private var confirmingDelete = false
    @State private var actionError: String?
    @Environment(\.workbenchTheme) private var theme

    private var showActions: Bool { selected || session.isArchived || hovered }

    var body: some View {
        HStack(spacing: 6) {
            rowDestination
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
            .accessibilityHidden(!showActions)
            .accessibilityLabel(strings.text("chat.actions"))
            .accessibilityIdentifier("conversation-actions")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(selected ? theme.accent.opacity(0.11) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help("\(session.displayTitle(using: strings))\n\(session.folder.path)")
        .accessibilityIdentifier("session-row")
        .contextMenu { actions }
        .sheet(isPresented: $renaming) { RenameConversation(workbench: workbench, session: session) }
        .alert(
            session.threadID == nil ? strings.text("chat.delete_draft_question") : strings.text("chat.delete_question"),
            isPresented: $confirmingDelete
        ) {
            Button(strings.text("common.cancel"), role: .cancel) {}
            Button(
                session.threadID == nil ? strings.text("chat.delete_draft") : strings.text("chat.delete_forever"),
                role: .destructive
            ) {
                perform { try await workbench.delete(session) }
            }
        } message: {
            Text(
                strings.text(
                    session.threadID == nil ? "chat.delete_draft_detail" : "chat.delete_detail",
                    session.displayTitle(using: strings)))
        }
        .alert(
            strings.text("chat.action_failed"),
            isPresented: Binding(
                get: { actionError != nil },
                set: {
                    if !$0 { actionError = nil }
                })
        ) {
            Button(strings.text("common.ok")) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder private var rowDestination: some View {
        if let sidebarFocus {
            Button {
                withoutSessionAnimation {
                    workbench.focus(session)
                    sidebarFocus.wrappedValue = session.id
                }
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
            .focused(sidebarFocus, equals: session.id)
            .onMoveCommand(perform: move)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            rowLabel
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isArchived ? "archivebox" : "bubble.left")
                .font(.callout)
                .foregroundStyle(selected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 17)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle(using: strings))
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary).lineLimit(1)
                Text(
                    session.threadID == nil && !session.isActive
                        ? strings.text("chat.draft_path", session.folder.lastPathComponent)
                        : session.folder.lastPathComponent
                )
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var status: some View {
        if session.isManaging || (session.isActive && session.approvals.isEmpty) {
            ProgressView().controlSize(.mini)
                .accessibilityLabel(session.isManaging ? strings.text("chat.managing") : strings.text("chat.running"))
        } else if !session.approvals.isEmpty {
            Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                .accessibilityLabel(strings.text("approval.pending", session.approvals.count))
        } else if session.hasUnreadResult {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.tint)
                .accessibilityLabel(strings.text("chat.unread"))
        }
    }

    @ViewBuilder private var actions: some View {
        if !session.isArchived {
            Button(strings.text("chat.rename_action"), systemImage: "pencil") { renaming = true }
                .disabled(!workbench.canRename(session))
        }
        if session.threadID != nil {
            Button(
                session.isArchived ? strings.text("chat.unarchive") : strings.text("chat.archive"),
                systemImage: session.isArchived ? "arrow.uturn.backward" : "archivebox"
            ) {
                let archived = !session.isArchived
                perform { try await workbench.setArchived(session, archived) }
            }
            .disabled(!workbench.canMoveOrDelete(session))
        }
        Divider()
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            Label(
                session.threadID == nil ? strings.text("chat.delete_draft_action") : strings.text("chat.delete_action"),
                systemImage: "trash")
        }
        .disabled(!workbench.canMoveOrDelete(session))
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { actionError = redact(error.localizedDescription) }
        }
    }
}

private struct ArchivedConversations: View {
    @Environment(\.uiStrings) private var strings
    let workbench: Workbench
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(strings.text("sidebar.archived"), systemImage: "archivebox").font(.title3.weight(.semibold))
                Spacer()
                Button(strings.text("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()
            content
        }
        .frame(minWidth: 440, idealWidth: 490, minHeight: 320, idealHeight: 440)
        .task { await workbench.loadArchivedConversations() }
    }

    @ViewBuilder private var content: some View {
        if let error = workbench.archiveError {
            ContentUnavailableView {
                Label(strings.text("archive.failure"), systemImage: "exclamationmark.circle")
            } description: {
                Text(error)
            } actions: {
                Button(strings.text("common.retry")) { Task { await workbench.loadArchivedConversations() } }
            }
        } else if workbench.archivedSessions.isEmpty {
            if workbench.loadingArchives {
                ProgressView(strings.text("archive.loading")).controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(strings.text("archive.empty"), systemImage: "archivebox")
            }
        } else {
            List {
                ForEach(workbench.archivedSessions) { session in
                    ConversationRow(workbench: workbench, session: session)
                }
                if workbench.moreArchives {
                    Button(strings.text("archive.more")) {
                        Task { await workbench.loadArchivedConversations(append: true) }
                    }
                    .disabled(workbench.loadingArchives)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct RenameConversation: View {
    @Environment(\.uiStrings) private var strings
    let workbench: Workbench
    let session: WorkbenchSession
    @State private var name: String
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workbenchTheme) private var theme

    init(workbench: Workbench, session: WorkbenchSession) {
        self.workbench = workbench
        self.session = session
        _name = State(initialValue: session.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.text("chat.rename")).font(.headline)
            TextField(strings.text("chat.name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(saving)
            if let failure {
                Text(failure).foregroundStyle(.secondary).font(.callout)
            }
            HStack(spacing: 8) {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(strings.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(strings.text("common.save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.actionTint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || ThreadSummary.cleanedName(name).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 384)
        .onAppear { focused = true }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await workbench.rename(session, to: name)
                dismiss()
            } catch { failure = redact(error.localizedDescription) }
        }
    }
}
