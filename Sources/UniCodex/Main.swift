import AppKit
import Darwin
import SwiftUI

@MainActor
final class WorkbenchDelegate: NSObject, NSApplicationDelegate {
    weak var workbench: Workbench?
    private var agentServer: AgentSocketServer?
    private weak var preferencesMenuItem: NSMenuItem?
    private var preferencesMenuTitle = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        localizePreferencesMenu(using: .current)
        if !CommandLine.arguments.contains("--agent-launch") { NSApp.activate() }
    }

    func applicationDidUpdate(_ notification: Notification) {
        applyPreferencesMenuTitle()
    }

    func localizePreferencesMenu(using strings: UIStrings) {
        preferencesMenuTitle = strings.text("settings.title") + "…"
        applyPreferencesMenuTitle()
    }

    private func applyPreferencesMenuTitle() {
        guard !preferencesMenuTitle.isEmpty, let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        // Keep the Settings scene's own menu action and shortcut.
        if preferencesMenuItem?.menu !== appMenu {
            preferencesMenuItem = appMenu.items.first {
                $0.keyEquivalent == ","
                    && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
            }
        }
        if let item = preferencesMenuItem, item.title != preferencesMenuTitle {
            item.title = preferencesMenuTitle
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentServer?.stop()
        workbench?.close()
    }

    func startAgentServer(workbench: Workbench) {
        guard agentServer == nil else { return }
        do {
            agentServer = try AgentSocketServer { [weak workbench] name, arguments in
                guard let workbench else { throw AgentSocketError.unavailable }
                return try await workbench.callAgentTool(name, arguments: arguments)
            }
            workbench.agentServiceError = nil
        } catch {
            workbench.agentServiceError = UIStrings.current.text("mcp.start_failed", error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workbench?.hasRunningWork == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = UIStrings.current.text("window.busy")
        alert.informativeText = UIStrings.current.text("window.quit_detail")
        alert.addButton(withTitle: UIStrings.current.text("window.keep_running"))
        alert.addButton(withTitle: UIStrings.current.text("window.quit"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !WORKBENCH_UI_FIXTURE
    @main
    @MainActor
    enum WorkbenchEntry {
        static func main() {
            switch Array(CommandLine.arguments.dropFirst()) {
            case ["--import-provider-keys"]: exit(ProviderKeyImport.run())
            case ["--restore-provider-keys"]: exit(ProviderKeyImport.restore())
            case ["--mcp"]: AgentMCPStdio().run()
            case ["--mcp-config"]: print(WorkbenchMCPConfiguration.json)
            default: WorkbenchApp.main()
            }
        }
    }

    @MainActor
    struct WorkbenchApp: App {
        @NSApplicationDelegateAdaptor(WorkbenchDelegate.self) private var delegate
        @State private var workbench: Workbench
        @State private var engineUpdate: CodexEngineUpdate
        @AppStorage(UIStrings.preference) private var language = UIStrings.system
        private var strings: UIStrings { UIStrings(selection: language) }

        init() {
            signal(SIGPIPE, SIG_IGN)
            let paths = EnginePaths.local
            _workbench = State(initialValue: Workbench(paths: paths))
            _engineUpdate = State(initialValue: CodexEngineUpdate(paths: paths))
        }

        var body: some Scene {
            Window("UniCodex", id: "workbench") {
                WorkbenchWindow(workbench: workbench)
                    .environment(\.uiStrings, strings)
                    .environment(\.locale, strings.locale)
                    .onAppear {
                        delegate.workbench = workbench
                        workbench.connect()
                        delegate.startAgentServer(workbench: workbench)
                    }
                    .task { await engineUpdate.monitor() }
            }
            .defaultSize(width: 1140, height: 760)
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(strings.text("common.new_chat")) { withoutSessionAnimation { workbench.newConversation() } }
                        .keyboardShortcut("n", modifiers: [.command])
                }
            }
            Settings {
                TabView {
                    preferencesTab("settings.providers", systemImage: "point.3.connected.trianglepath.dotted") {
                        ProviderSettings(workbench: workbench)
                    }
                    preferencesTab("settings.appearance", systemImage: "paintpalette") {
                        AppearanceSettings()
                    }
                    preferencesTab("settings.engine", systemImage: "arrow.trianglehead.clockwise.rotate.90") {
                        EngineUpdateSettings(update: engineUpdate)
                    }
                    preferencesTab("settings.agent", systemImage: "terminal") {
                        AgentSettings(workbench: workbench)
                    }
                }
                .environment(\.uiStrings, strings)
                .environment(\.locale, strings.locale)
                .onChange(of: strings) { _, value in delegate.localizePreferencesMenu(using: value) }
            }
        }

        private func preferencesTab<Content: View>(
            _ key: String, systemImage: String,
            @ViewBuilder content: () -> Content
        ) -> some View {
            content()
                .frame(width: 734, height: 530, alignment: .topLeading)
                .navigationTitle(strings.text("settings.title"))
                .tabItem { Label(strings.text(key), systemImage: systemImage) }
        }
    }
#endif

struct AgentSettings: View {
    @Environment(\.uiStrings) private var strings
    let workbench: Workbench
    @State private var copied: String?

    var body: some View {
        Form {
            Section(strings.text("mcp.local")) {
                LabeledContent(strings.text("mcp.transport"), value: "stdio")
                LabeledContent(strings.text("mcp.name"), value: WorkbenchMCPConfiguration.name)
                if let error = workbench.agentServiceError {
                    Text(error).foregroundStyle(.orange)
                }
            }
            Section(strings.text("mcp.connect")) {
                Text(strings.text("mcp.instructions"))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(strings.text("mcp.copy_config")) {
                        copy(WorkbenchMCPConfiguration.json, notice: strings.text("mcp.config_copied"))
                    }
                    .buttonStyle(.borderedProminent)
                    Button(strings.text("mcp.copy_command")) {
                        copy(WorkbenchMCPConfiguration.codexCommand, notice: strings.text("mcp.command_copied"))
                    }
                }
                if let copied { Label(copied, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func copy(_ value: String, notice: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(value, forType: .string) { copied = notice }
    }
}

struct EngineUpdateSettings: View {
    @Environment(\.uiStrings) private var strings
    let update: CodexEngineUpdate

    var body: some View {
        Form {
            Section(strings.text("engine.title")) {
                LabeledContent(
                    strings.text("engine.running_version"),
                    value: update.activeVersion?.description ?? strings.text("engine.reading"))
                if let latest = update.latestVersion {
                    LabeledContent(strings.text("engine.latest"), value: latest.description)
                }
                if let pending = update.pendingVersion {
                    LabeledContent(strings.text("engine.on_restart"), value: pending.description)
                }
                if let checked = update.lastChecked {
                    LabeledContent(strings.text("engine.last_checked")) {
                        Text(checked, format: .dateTime.month().day().hour().minute())
                    }
                }
            }
            Section {
                HStack {
                    if update.working { ProgressView().controlSize(.small) }
                    Text(update.status(using: strings))
                        .font(.callout)
                        .foregroundStyle(update.failed ? .orange : .secondary)
                    Spacer()
                    Button(strings.text("engine.check")) { Task { await update.check() } }
                        .disabled(update.working)
                }
                Text(strings.text("engine.schedule"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

func withoutSessionAnimation(_ action: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction, action)
}

struct WorkbenchWindow: View {
    let workbench: Workbench
    @AppStorage(WorkbenchTheme.preference) private var theme = WorkbenchTheme.ocean

    var body: some View {
        NavigationSplitView {
            SessionSidebar(workbench: workbench)
                .navigationSplitViewColumnWidth(min: 205, ideal: 236, max: 320)
        } detail: {
            SessionPane(workbench: workbench, session: workbench.selected)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.workbenchTheme, theme)
        .tint(theme.accent)
        .frame(minWidth: 840, minHeight: 560)
    }
}

private struct SessionPane: View {
    @Environment(\.uiStrings) private var strings
    let workbench: Workbench
    @Bindable var session: WorkbenchSession
    @FocusState private var composerFocused: Bool
    @State private var showingSessionInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchTheme) private var theme
    @Namespace private var bottomGlass

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerDock
                    .frame(maxWidth: 800)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle(workbench.folderName(for: session))
            .toolbar {
                ToolbarItemGroup {
                    modelPicker
                    reasoningPicker
                }
                if #available(macOS 26, *) {
                    ToolbarSpacer(.fixed)
                }
                ToolbarItem {
                    permissionPicker
                }
                ToolbarItem {
                    sessionInfo
                }
                ToolbarItem {
                    Button(
                        strings.text("session.choose_folder"), systemImage: "folder.badge.plus", action: selectFolder
                    )
                    .help(strings.text("session.choose_hint"))
                }
            }
            .onAppear { composerFocused = true }
            .onChange(of: session.id) { _, _ in showingSessionInfo = false }
    }

    private var sessionInfo: some View {
        Button(strings.text("session.info"), systemImage: "info.circle") { showingSessionInfo.toggle() }
            .labelStyle(.iconOnly)
            .help(session.folder.path)
            .popover(isPresented: $showingSessionInfo, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.displayTitle(using: strings)).font(.headline).lineLimit(2)
                    Label(strings.text("session.directory"), systemImage: "folder").font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(verbatim: session.folder.path)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(strings.text("session.copy_path"), systemImage: "document.on.document") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.folder.path, forType: .string)
                    }
                    .controlSize(.small)
                }
                .frame(width: 330, alignment: .leading)
                .padding(16)
            }
    }

    private var canConfigure: Bool { workbench.connection == .ready && !session.isActive && !session.isLoading }

    private var canSelectRoute: Bool { !session.isArchived && !session.isManaging }

    private var modelPicker: some View {
        let profile = workbench.profile(for: session)
        return Menu {
            ForEach(workbench.providers.profiles) { candidate in
                let models = workbench.models(for: candidate)
                Menu {
                    ForEach(models) { model in
                        let route = ModelRoute(profileID: candidate.id, modelID: model.id)
                        Button {
                            workbench.selectRoute(route, in: session)
                        } label: {
                            if route == session.route {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                    if !workbench.providers.configured(candidate) { Text(strings.text("provider.require_key")) }
                } label: {
                    Label {
                        Text(candidate.name)
                    } icon: {
                        ProviderMark.menuImage(for: candidate.kind)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .disabled(models.isEmpty || !workbench.providers.configured(candidate))
            }
            Divider()
            SettingsLink { Label(strings.text("provider.settings"), systemImage: "gear") }
        } label: {
            Label {
                Text(session.modelID)
            } icon: {
                ProviderMark(kind: profile.kind)
            }
            .labelStyle(.titleAndIcon)
        }
        .disabled(!canSelectRoute)
        .accessibilityLabel(strings.text("models.details", session.modelID, profile.name))
        .help(strings.text("models.choose"))
    }

    private var reasoningPicker: some View {
        let level = workbench.reasoning(for: session)
        let choices = workbench.reasoningChoices(for: session)
        return Menu {
            Picker(
                strings.text("models.reasoning"),
                selection: Binding(
                    get: { level?.id ?? "" },
                    set: {
                        workbench.selectReasoning($0, in: session)
                    })
            ) {
                ForEach(choices) { Text($0.menuTitle).tag($0.id) }
            }.pickerStyle(.inline)
        } label: {
            Label(
                level?.id == "ultra" ? "Ultra" : level?.name ?? strings.text("common.default"),
                systemImage: "gauge.with.dots.needle.50percent"
            )
            .labelStyle(.titleAndIcon)
        }
        .disabled(!canSelectRoute || choices.isEmpty)
        .accessibilityLabel(strings.text("models.reasoning_detail", level?.name ?? strings.text("common.default")))
        .help(strings.text("models.reasoning_help"))
    }

    private var permissionPicker: some View {
        Menu {
            Picker(
                strings.text("permission.label"),
                selection: Binding(
                    get: { session.permissionMode },
                    set: {
                        workbench.selectPermissionMode($0, in: session)
                    })
            ) {
                ForEach(workbench.permissionModes) { mode in
                    if mode == .alwaysApprove {
                        Label(strings.text("permission.full"), systemImage: mode.symbol).tag(mode)
                    } else {
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
            }.pickerStyle(.inline)
            Divider()
            Text(session.permissionMode.description)
        } label: {
            Label(session.permissionMode.title, systemImage: session.permissionMode.symbol)
                .labelStyle(.titleAndIcon)
        }
        .disabled(!canConfigure || workbench.permissionModes.isEmpty)
        .accessibilityLabel(strings.text("permission.description", session.permissionMode.title))
        .help(session.permissionMode.description)
    }

    @ViewBuilder private var content: some View {
        if session.hasVisibleEntries {
            SessionTranscript(session: session).id(session.id)
        } else if session.isLoading || session.loadState == .unloaded {
            ProgressView(strings.text("session.loading")).controlSize(.small)
        } else if session.loadState == .failed {
            Button(strings.text("session.reload")) { workbench.openHistory(in: session) }
        } else {
            ContentUnavailableView {
                Label(strings.text("session.start"), systemImage: "terminal")
            } description: {
                Text(strings.text("session.empty_text"))
            } actions: {
                Button(strings.text("session.example_action")) {
                    session.draft = strings.text("session.example_prompt")
                    composerFocused = true
                }
            }
        }
    }

    // Follow the Landmarks sample: a shared container and identified system glass surfaces.
    @ViewBuilder private var composerDock: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 14) {
                    if let approval = session.approvals.first {
                        approvalPrompt(approval)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                            .glassEffectID("approval", in: bottomGlass)
                            .glassEffectTransition(.materialize)
                    }
                    composer
                        .glassEffect(.regular.tint(theme.glassTint), in: .rect(cornerRadius: 23))
                        .glassEffectID("composer", in: bottomGlass)
                }
            }
            .animation(reduceMotion ? nil : .default, value: session.approvals.isEmpty)
        } else {
            VStack(spacing: 10) {
                if let approval = session.approvals.first {
                    approvalPrompt(approval)
                    Divider()
                }
                composer
            }
            .background(.background)
        }
    }

    private func approvalPrompt(_ approval: Approval) -> some View {
        ApprovalPrompt(
            approval: approval, count: session.approvals.count,
            submitting: session.answeringApprovalIDs.contains(approval.id)
        ) { scope in
            workbench.resolve(approval, in: session, choosing: scope)
        }
        .id(approval.id)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let failure = session.error ?? workbench.connectionError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(failure).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 6)
                    Button(strings.text("session.dismiss"), systemImage: "xmark") {
                        if session.error != nil { session.error = nil } else { workbench.dismissConnectionError() }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .padding(.horizontal, 5)
            }
            if !workbench.providers.configured(workbench.profile(for: session)) {
                SettingsLink { Label(strings.text("provider.configure"), systemImage: "key") }
                    .buttonStyle(.link).font(.caption)
            } else if session.runningRoute.map({ $0 != session.route }) == true
                || workbench.routeWillContinueHistory(in: session)
            {
                Label(
                    strings.text("session.next_provider", workbench.profile(for: session).name),
                    systemImage: "arrow.triangle.branch"
                )
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if session.contextLimited {
                Label(strings.text("session.limited_context"), systemImage: "text.alignleft")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $session.draft)
                .font(TranscriptTypography.font()).scrollContentBackground(.hidden)
                .frame(height: 62)
                .focused($composerFocused)
                .accessibilityLabel(strings.text("session.task"))
                .overlay(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text(session.isActive ? strings.text("session.next_task") : strings.text("session.prompt"))
                            .font(TranscriptTypography.font()).foregroundStyle(.secondary)
                            .padding(.leading, 5).padding(.top, 1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            HStack(spacing: 8) {
                if (session.isActive && session.approvals.isEmpty) || session.isLoading {
                    ProgressView().controlSize(.small)
                }
                let status = session.status(using: strings)
                Text(status.isEmpty ? strings.text(workbench.connectionStatus) : status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if session.isActive {
                    Button(strings.text("common.stop"), systemImage: "stop.fill") { workbench.interrupt(in: session) }
                        .buttonStyle(.bordered)
                        .disabled(!workbench.canStop(in: session))
                        .help(strings.text("session.stop_help"))
                } else {
                    Button(strings.text("common.send"), systemImage: "arrow.up") { workbench.send(in: session) }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.actionTint)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!workbench.canSend(in: session))
                }
            }
            .controlSize(.regular)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 15)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = strings.text("session.select_folder")
        panel.prompt = strings.text("common.select")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.folder
        let finished: (NSApplication.ModalResponse) -> Void = { result in
            if result == .OK, let location = panel.url {
                withoutSessionAnimation { workbench.changeFolder(location, in: session) }
                composerFocused = true
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }
}

private struct ApprovalPrompt: View {
    @Environment(\.uiStrings) private var strings
    let approval: Approval
    let count: Int
    let submitting: Bool
    let choose: (ApprovalOption.Scope) -> Void
    @State private var ruleToConfirm: ApprovalOption?
    @Environment(\.workbenchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(strings.text(approval.title), systemImage: "lock.shield")
                    .font(.callout.weight(.semibold))
                Spacer()
                if count > 1 {
                    Text(strings.text("approval.pending", count)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !approval.reason.isEmpty {
                Text(approval.reason).font(.callout).lineLimit(3).textSelection(.enabled)
            }
            if !approval.detail.isEmpty {
                DisclosureGroup {
                    LogExcerpt(text: approval.detail, maximumLines: 7)
                } label: {
                    Text(
                        approval.detail.split(whereSeparator: \.isNewline).first.map(String.init)
                            ?? strings.text("approval.details")
                    )
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityIdentifier("approval-details")
            }
            HStack(spacing: 8) {
                if submitting {
                    ProgressView().controlSize(.small)
                    Text(strings.text("approval.submitting")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let decline = option(.decline) {
                    Button(strings.text(decline.title), role: .cancel) { choose(.decline) }
                }
                if let rule = option(.rule) {
                    Button(strings.text("approval.always")) { ruleToConfirm = rule }
                        .help(strings.text(rule.title))
                }
                if let session = option(.session) {
                    Button(strings.text(session.title)) { choose(.session) }
                }
                if let once = option(.once) {
                    Button(strings.text(once.title)) { choose(.once) }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.actionTint)
                }
            }
            .controlSize(.regular)
            .disabled(submitting)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .alert(
            strings.text(ruleToConfirm?.title ?? "approval.rule_title"),
            isPresented: Binding(
                get: { ruleToConfirm != nil }, set: { if !$0 { ruleToConfirm = nil } }
            ), presenting: ruleToConfirm
        ) { option in
            Button(strings.text("common.cancel"), role: .cancel) {}
            Button(strings.text("approval.save")) { choose(option.scope) }
        } message: { option in
            Text(strings.text("approval.rule_text", option.ruleDescription.map { "\n\n" + $0 } ?? ""))
        }
    }

    private func option(_ scope: ApprovalOption.Scope) -> ApprovalOption? {
        approval.options.first { $0.scope == scope }
    }
}
