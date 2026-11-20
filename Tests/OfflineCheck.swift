import Darwin
import Foundation

@main
struct OfflineCheck {
    @MainActor
    static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let credential = scratch.appendingPathComponent("test-credentials.json")
        let aFolder = scratch.appendingPathComponent("Project A", isDirectory: true)
        let bFolder = scratch.appendingPathComponent("Project B", isDirectory: true)
        for folder in [aFolder, bFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "apikey", "OPENAI_API_KEY": "sk-offline-synthetic-fixture",
        ])
        .write(to: credential)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        let base = String(CommandLine.arguments[2].dropLast(3))
        let binary =
            ProcessInfo.processInfo.environment["WORKBENCH_TEST_CODEX_BINARY"]
            .map { URL(fileURLWithPath: $0) } ?? CodexEngineFiles.bundled
        let paths = EnginePaths(
            codexHome: scratch.appendingPathComponent("engine", isDirectory: true),
            credentialFile: credential, binary: binary, endpoint: CommandLine.arguments[2],
            modelCatalog: URL(fileURLWithPath: CommandLine.arguments[3]),
            providerTestEndpoints: [
                .deepSeek: base + "/deepseek", .kimiCode: base + "/kimi/coding/v1", .gemini: base + "/google",
            ]
        )
        let suite = "local.codex-api-workbench.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let desk = Workbench(paths: paths, defaults: defaults)
        defer { desk.close() }
        desk.connect()
        try await waitFor("startup") { desk.connection == .ready }
        try require(
            Set(desk.models.map(\.id)) == Set(["gpt-6.1-sol", "gpt-6-luna", "gpt-6.2-sol", "gpt-6.2-astra"]),
            "API model filtering changed")

        let a = desk.newConversation(in: aFolder)
        try await desk.rename(a, to: "会话管理验收 A")
        let disposableDraft = desk.newConversation()
        try require(desk.sessions.contains { $0 === a }, "Creating a draft discarded an explicitly named draft")
        try await desk.delete(disposableDraft)
        try require(desk.selected === a && a.title == "会话管理验收 A", "Deleting a draft did not select a valid session")
        desk.selectReasoning("high", in: a)
        a.draft = "OFFLINE_PARALLEL_A"
        desk.send(in: a)
        try await waitFor("A streamed output") {
            a.runState.turnID != nil && a.entries.contains { $0.text.contains("stream A") }
        }
        a.draft = "保留 A 的未发送草稿"
        let b = desk.newConversation(in: bFolder)
        desk.selectModel("gpt-6-luna", in: b)
        desk.selectReasoning("ultra", in: b)
        try require(
            !desk.reasoningChoices(for: b).contains { $0.id == "ultra" } && desk.reasoning(for: b)?.id == "medium",
            "Luna accepted an unsupported effort")
        desk.selectModel("gpt-6.2-sol", in: b)
        desk.selectReasoning("ultra", in: b)
        b.draft = "OFFLINE_PARALLEL_B"
        desk.send(in: b)
        try await waitFor("Both threads stream at once") {
            a.isActive && b.runState.turnID != nil && b.entries.contains { $0.text.contains("stream B") }
        }
        try require(
            a.threadID != nil && b.threadID != nil && a.threadID != b.threadID && desk.numberRunning == 2,
            "The two tasks did not get distinct live threads")
        try require(
            !desk.canMoveOrDelete(a) && !desk.canMoveOrDelete(b),
            "A running test conversation could be removed")
        try require(
            a.modelID == "gpt-6.1-sol" && desk.reasoning(for: a)?.id == "high" && a.folder.path == aFolder.path
                && b.modelID == "gpt-6.2-sol" && b.folder.path == bFolder.path && a.draft == "保留 A 的未发送草稿",
            "Session folder, model, effort or draft leaked across sessions")
        try require(
            !a.entries.contains { $0.text.contains("stream B") }
                && !b.entries.contains { $0.text.contains("stream A") },
            "Stream events were routed to the wrong session")
        desk.focus(a)
        desk.interrupt(in: a)
        try await waitFor("Only A is interrupted") { !a.isActive && a.finalStatus == .stopped }
        try require(
            b.isActive && desk.selected === a && desk.numberRunning == 1,
            "Interrupt affected a separate thread")
        try Data().write(to: scratch.appendingPathComponent("release-B"))
        try await waitFor("B finishes in the background") { !b.isActive && b.finalStatus == .completed }
        try require(
            b.hasUnreadResult && desk.selected === a && b.entries.filter { $0.kind == .user }.count == 1
                && b.entries.contains { $0.kind == .answer && $0.text == "stream B complete" },
            "The background completion was lost or selected itself")
        desk.focus(b)
        try require(!b.hasUnreadResult, "Opening the result did not clear its unread marker")
        try await waitFor("Completed text has its formatted document") {
            b.entries.contains { $0.kind == .answer && $0.document != nil }
        }
        let preparedMarkdown = b.entries.first { $0.kind == .answer }?.document
        desk.focus(a)
        desk.focus(b)
        try require(
            b.entries.first { $0.kind == .answer }?.document == preparedMarkdown,
            "Switching sessions discarded formatting for a finished message")
        let bThread = b.threadID
        let aThread = a.threadID
        try await desk.rename(b, to: "  会话管理验收 B  ")
        try require(b.title == "会话管理验收 B", "The thread name was not updated")

        let localFile = bFolder.appendingPathComponent("report preview.svg")
        let bareFile = bFolder.appendingPathComponent("pelican-on-a-bike.svg")
        try Data().write(to: localFile)
        try Data().write(to: bareFile)
        let markdown = "文件：\u{60}pelican-on-a-bike.svg\u{60}、report%20preview.svg 和 [预览](./report%20preview.svg:12)。"
        let links = MessageMarkup.runs(for: markdown, in: bFolder).compactMap(\.link).map(\.path)
        try require(
            links == [bareFile.path, localFile.path, localFile.path],
            "Bare, inline and Markdown file references did not resolve")
        try require(
            MessageMarkup.fileURL(localFile.absoluteString, in: bFolder)?.path == localFile.path
                && MessageMarkup.fileURL("pelican-on-a-bike.svg", in: aFolder).flatMap(MessageMarkup.existingFile)
                    == nil
                && MessageMarkup.fileURL("file://other-host/tmp/pelican-on-a-bike.svg", in: bFolder) == nil,
            "A reference resolved outside its session context")
        let blocksWithFile = MessageDocument(
            markdown + "\n\n\u{60}\u{60}\u{60}sh\nprintf ok\n\u{60}\u{60}\u{60}", in: bFolder)
        try require(
            blocksWithFile.blocks.count == 2
                && blocksWithFile.blocks.first == .paragraph(MessageMarkup.runs(for: markdown, in: bFolder))
                && blocksWithFile.blocks.last == .code("printf ok\n")
                && TranscriptTypography.nativeFont(for: .init(text: "normal")).pointSize
                    == TranscriptTypography.nativeFont(for: .init(text: "code", code: true)).pointSize,
            "Preparing a document changed its links, code or text size")
        try checkMarkdown(in: bFolder)

        try checkApprovalOptions()
        try checkStagedGeminiSetup()
        let approvalSession = desk.newConversation(in: bFolder)
        desk.selectModel("gpt-6.1-sol", in: approvalSession)
        let commandTurn = "OFFLINE_APPROVAL_RULE"
        approvalSession.draft = commandTurn
        desk.send(in: approvalSession)
        try await waitFor("Command needs an initial approval") { !approvalSession.approvals.isEmpty }
        guard let first = approvalSession.approvals.first else { throw WorkbenchError("Missing approval") }
        try require(
            first.detail.contains("permission-rule.txt") && first.options.contains { $0.scope == .rule },
            "The command offered \(first.options.map(\.scope.rawValue)) and details: \(first.detail)")
        try require(a.approvals.isEmpty && b.approvals.isEmpty, "Approval appeared in another session")
        desk.resolve(first, in: approvalSession, choosing: .rule)
        try await waitFor("The repeated command runs under the saved rule") {
            !approvalSession.isActive || approvalSession.approvals.contains { $0.id != first.id }
        }
        try require(
            approvalSession.approvals.isEmpty && approvalSession.finalStatus == .completed
                && FileManager.default.fileExists(atPath: scratch.appendingPathComponent("permission-rule.txt").path),
            "The accepted action re-prompted or failed")
        let approvalSnapshot = approvalSession.transcriptSnapshot()
        let blocks = TranscriptLayout.rows(
            in: approvalSnapshot, startingAt: 0,
            top: TranscriptLayout.padding, width: 700, expanded: [])
        try require(
            approvalSession.entries.contains { $0.kind == .reasoning && $0.text.hasPrefix("先核对") }
                && blocks.contains { $0.id.hasPrefix("tools:") && $0.items.count == 2 },
            "Reasoning summary or grouped tool activity was lost")

        desk.selectPermissionMode(.alwaysApprove, in: approvalSession)
        try require(
            approvalSession.permissionMode == .alwaysApprove && b.permissionMode == .workspace,
            "Permission mode leaked into another conversation")
        approvalSession.draft = "OFFLINE_APPROVAL_FULL"
        desk.send(in: approvalSession)
        try await waitFor("Full-access mode finishes without a prompt") {
            !approvalSession.isActive || !approvalSession.approvals.isEmpty
        }
        try require(
            approvalSession.approvals.isEmpty && approvalSession.finalStatus == .completed
                && FileManager.default.fileExists(atPath: scratch.appendingPathComponent("permission-full.txt").path),
            "Always approve did not apply full access to the next turn of the same thread")
        desk.selectPermissionMode(.workspace, in: approvalSession)
        approvalSession.draft = "OFFLINE_APPROVAL_RETURN"
        desk.send(in: approvalSession)
        try await waitFor("Returning to workspace restores manual approvals") { !approvalSession.approvals.isEmpty }
        if let request = approvalSession.approvals.first {
            desk.resolve(request, in: approvalSession, choosing: .decline)
        }
        try await waitFor("Decline completes") { !approvalSession.isActive }
        try require(
            !FileManager.default.fileExists(atPath: scratch.appendingPathComponent("permission-return.txt").path),
            "The denied action was executed")
        let approvalThread = approvalSession.threadID
        desk.selectPermissionMode(.alwaysApprove, in: approvalSession)
        desk.focus(b)

        desk.close()
        let reopened = Workbench(paths: paths, defaults: defaults)
        defer { reopened.close() }
        reopened.connect()
        try await waitFor("Persisted thread restores") {
            reopened.selected.threadID == bThread && reopened.selected.loadState == .ready
                && reopened.selected.entries.contains { $0.text == "stream B complete" }
        }
        try require(
            reopened.selected.folder.path == bFolder.path
                && reopened.selected.entries.first { $0.kind == .answer }?.document == preparedMarkdown
                && reopened.selected.title == "会话管理验收 B"
                && reopened.sessions.first { $0.threadID == aThread }?.title == "会话管理验收 A"
                && reopened.selected.permissionMode == .workspace
                && reopened.sessions.first { $0.threadID == approvalThread }?.permissionMode == .alwaysApprove
                && !FileManager.default.fileExists(atPath: paths.codexHome.appendingPathComponent("auth.json").path),
            "Per-conversation permissions, history or independent auth changed after restart")

        let oldB = reopened.selected
        try await checking("archive active thread") { try await reopened.setArchived(oldB, true) }
        try require(
            oldB.isArchived && !reopened.sessions.contains { $0 === oldB }
                && reopened.archivedSessions.contains { $0 === oldB } && reopened.selected !== oldB,
            "Archiving did not move the thread and select a valid conversation")
        reopened.close()

        let archiveDesk = Workbench(paths: paths, defaults: defaults)
        defer { archiveDesk.close() }
        archiveDesk.connect()
        try await waitFor("Active list after archive reconnect") {
            archiveDesk.connection == .ready && archiveDesk.sessions.contains { $0.threadID == aThread }
        }
        await archiveDesk.loadArchivedConversations()
        guard let savedB = archiveDesk.archivedSessions.first(where: { $0.threadID == bThread }),
            let savedA = archiveDesk.sessions.first(where: { $0.threadID == aThread })
        else {
            throw WorkbenchError("The independent archived list did not restore the saved thread")
        }
        try require(
            archiveDesk.archiveError == nil && savedB.isArchived && savedB.title == "会话管理验收 B"
                && !archiveDesk.sessions.contains { $0.threadID == bThread }, "Archive state was not authoritative")
        try await checking("unarchive saved thread") { try await archiveDesk.setArchived(savedB, false) }
        archiveDesk.focus(savedB)
        try await waitFor("Unarchived conversation can load existing history") {
            savedB.loadState == .ready && savedB.entries.contains { $0.text == "stream B complete" }
        }
        try await checking("rename restored thread") {
            try await archiveDesk.rename(savedB, to: "会话管理验收 B 已恢复")
        }
        try require(
            !savedB.isArchived && savedB.title == "会话管理验收 B 已恢复" && savedB.folder.path == bFolder.path,
            "Unarchive lost history, title or workspace")
        try await checking("delete restored thread") { try await archiveDesk.delete(savedB) }
        try await waitFor("Other test conversation can be archived") { archiveDesk.canMoveOrDelete(savedA) }
        try await checking("archive other thread") { try await archiveDesk.setArchived(savedA, true) }
        try await checking("delete archived thread") { try await archiveDesk.delete(savedA) }
        await archiveDesk.loadArchivedConversations()
        let visibleIDs = Set((archiveDesk.sessions + archiveDesk.archivedSessions).compactMap(\.threadID))
        let rolloutPaths = FileManager.default.enumerator(atPath: paths.codexHome.path)?.allObjects as? [String] ?? []
        for id in [aThread, bThread].compactMap({ $0 }) {
            try require(
                !visibleIDs.contains(id) && !rolloutPaths.contains { $0.hasSuffix("\(id).jsonl") },
                "A deleted disposable fixture appeared in the list or on disk")
        }
        try require(
            FileManager.default.fileExists(atPath: localFile.path), "Deleting a conversation removed a workspace file")
        print(
            "PASS: rename saved and draft conversations; archive and restore across restart; permanently delete active and archived fixture records; existing regressions"
        )
        try await checkLongTranscript(in: archiveDesk, folder: bFolder)
        try await checkAgentDispatch(in: archiveDesk, paths: paths, folder: bFolder)
        archiveDesk.close()
        try await checkProviderHandoff(paths: paths, scratch: scratch, folder: bFolder, defaults: defaults)
    }

    private static func checkMarkdown(in folder: URL) throws {
        let markdown = """
            # 发布说明

            内容包括 **加粗**、*斜体*、~~删除~~ 和 \u{60}行内代码\u{60}。

            3. 第一项
               - [x] 验收通过
               - \\[x] 按原文显示
            4. 第二项

            > 引用
            > > 内层引用

            | 项目 | 结果 | 数量 |
            | :--- | :---: | ---: |
            | Alpha | [预览](./report%20preview.svg:4) | 10 |
            | Beta | | 20 |

            ---

            \u{60}\u{60}\u{60}swift
            let count = 3
            \u{60}\u{60}\u{60}
            """
        let document = MessageDocument(markdown, in: folder)
        guard case .paragraph(let heading, let title)? = document.blocks.first else {
            throw WorkbenchError("Missing native Markdown heading")
        }
        let runs = document.blocks.flatMap { block -> [MessageRun] in
            if case .paragraph(let runs, _) = block { return runs }
            return []
        }
        let numbered = document.blocks.compactMap(\.indent.marker)
        try require(
            title.heading == 1 && heading.map(\.text).joined() == "发布说明" && numbered == ["3.", "☑", "◦", "4."]
                && document.blocks.contains { $0.indent.quotes == 2 } && runs.contains { $0.text.contains("[x] 按原文显示") }
                && runs.contains { $0.bold && $0.text == "加粗" } && runs.contains { $0.italic && $0.text == "斜体" }
                && runs.contains { $0.strike && $0.text == "删除" } && runs.contains { $0.code && $0.text == "行内代码" },
            "Markdown heading, visual lists, quote levels, or inline traits were lost")
        guard
            let table = document.blocks.compactMap({ block -> MarkdownTable? in
                if case .table(let table, _) = block { return table }
                return nil
            }).first
        else { throw WorkbenchError("Markdown table was left as source") }
        try require(
            table.columns == [.left, .center, .right] && table.rows.count == 3
                && table.rows[1][1].first?.link?.path == folder.appendingPathComponent("report preview.svg").path
                && table.rows[2][1].isEmpty && MessageTextLayout.measure(.table(table), width: 330).height > 55
                && document.blocks.contains(.divider(MarkdownIndent()))
                && document.blocks.last == .code("let count = 3\n"),
            "Markdown tables, links, thematic breaks, or fences did not render correctly")
        let partial = TranscriptEntry(id: "markdown-stream", kind: .answer, text: "# 流式标题\n\n- 项目", isStreaming: true)
        let user = TranscriptEntry(id: "markdown-user", kind: .user, text: "# 用户标题\n\n- 项目")
        try require(
            TranscriptLayout.blocks(for: partial, in: folder).count == 2
                && TranscriptLayout.blocks(for: user, in: folder).count == 2,
            "Streaming replies or user messages still display raw block markers")
        print("PASS: native Markdown headings, nested task lists, block quotes, tables, links, fences, and streaming")
    }

    @MainActor
    private static func checkLongTranscript(in desk: Workbench, folder: URL) async throws {
        let probe = WorkbenchSession(folder: folder, modelID: "gpt-6.2-sol", reasoningByModel: [:])
        probe.threadID = "buffer-fixture"
        probe.upsert(.init(id: "stream", kind: .answer, text: "The active output", isStreaming: true))
        let largeDetail = String(repeating: "x", count: 100_000)
        for index in 0..<180 {
            probe.upsert(.init(id: "entry-\(index)", kind: .activity, text: "Fixture log", detail: largeDetail))
        }
        try require(
            probe.transcriptSnapshot().records.count == 181 && probe.entry("stream")?.isStreaming == true
                && probe.entry("entry-179") != nil
                && probe.entries.reduce(0) { $0 + $1.estimatedBytes } <= WorkbenchSession.recentEstimatedByteLimit,
            "Recent buffer exceeded its byte budget or lost an in-progress item")

        let long = desk.newConversation(in: folder)
        long.draft = "OFFLINE_LONG_TIMELINE"
        desk.send(in: long)
        try await waitFor("Long turn completes") { !long.isActive && long.finalStatus == .completed }
        try require(
            long.entries.count <= WorkbenchSession.recentEntryLimit
                && long.entries.last?.text.hasPrefix("Long timeline item 0671") == true,
            "The single long turn did not stay bounded or dropped the latest message")
        long.draft = "保留长对话的草稿"

        func offsets(in snapshot: TranscriptSnapshot, indices: [Int]) -> [Int] {
            indices.compactMap { index in
                guard let text = snapshot.entry(index)?.text, text.hasPrefix("Long timeline item ") else { return nil }
                return Int(text.dropFirst(19).prefix(4))
            }
        }
        let live = long.transcriptSnapshot()
        let expected = Array(0..<672)
        try require(
            offsets(in: live, indices: Array(live.records.indices)) == expected
                && offsets(in: live, indices: Array(live.records.indices.reversed())) == expected.reversed(),
            "The disk-backed timeline lost or reordered finalized items while trimming the live buffer")
        let wide = TranscriptLayout.rows(
            in: live, startingAt: 0, top: TranscriptLayout.padding, width: 700, expanded: [])
        long.upsert(.init(id: "local-timeline-append", kind: .progress, text: "New live activity"))
        let appended = TranscriptLayout.rows(
            in: long.transcriptSnapshot(), startingAt: 0,
            top: TranscriptLayout.padding, width: 700, expanded: [])
        try require(
            appended.count == wide.count + 1
                && zip(wide, appended).allSatisfy { $0.id == $1.id && $0.top == $1.top && $0.height == $1.height },
            "Appending output changed the coordinates of an existing message")

        long.releaseTranscript()
        desk.openHistory(in: long)
        try await waitFor("The long conversation reloads from the App Server") { long.loadState == .ready }
        let reopened = long.transcriptSnapshot()
        try require(
            offsets(in: reopened, indices: Array(reopened.records.indices)) == expected
                && long.entries.count <= WorkbenchSession.recentEntryLimit && long.draft == "保留长对话的草稿",
            "Reopening the long transcript lost history or the unsent draft")
        print(
            "PASS: 672 items in one turn; complete disk-backed indexing and reopen; fixed prior coordinates after append"
        )
    }

    @MainActor
    private static func checkProviderHandoff(
        paths: EnginePaths, scratch: URL, folder: URL,
        defaults: UserDefaults
    ) async throws {
        let keys = FixtureKeys()
        let desk = Workbench(paths: paths, defaults: defaults, profileKeys: keys)
        defer { desk.close() }
        desk.connect()
        try await waitFor("Provider test startup") { desk.connection == .ready }
        let deep = desk.providers.profiles.first { $0.kind == .deepSeek }!
        let kimi = desk.providers.profiles.first { $0.kind == .kimiCode }!
        let gemini = desk.providers.profiles.first { $0.kind == .gemini }!
        try desk.providers.save(deep, key: "sk-offline-deepseek-only")
        try desk.providers.save(kimi, key: "sk-offline-kimi-only")
        try desk.providers.save(gemini, key: "offline-synthetic-google")

        let chat = desk.newConversation(in: folder)
        try await desk.rename(chat, to: "跨供应商会话验收")
        chat.draft = "OFFLINE_SWITCH_ROOT"
        desk.send(in: chat)
        try await waitFor("OpenAI emits while a new selection is pending") {
            chat.isActive && chat.entries.contains { $0.text == "switch ROOT" }
        }
        let root = chat.threadID!
        desk.selectRoute(.init(profileID: deep.id, modelID: "deepseek-v4-pro"), in: chat)
        try require(
            chat.runningRoute?.profileID == ProviderProfile.originalID && chat.profileID == deep.id && chat.isActive,
            "A model selection interfered with the active turn")
        try Data().write(to: scratch.appendingPathComponent("release-ROOT"))
        try await waitFor("Original turn completes with original provider") {
            !chat.isActive && chat.finalStatus == .completed
        }

        func assertReply(_ stage: String) async throws {
            chat.draft = "OFFLINE_SWITCH_" + stage
            desk.send(in: chat)
            try await waitFor("Response from " + stage) { !chat.isActive }
            try require(
                chat.entries.contains { $0.text == "switch " + stage + " complete" } && chat.threadID == root
                    && chat.finalStatus == .completed,
                "Direct route " + stage + " did not continue the thread: "
                    + (chat.error ?? chat.finalStatus?.rawValue ?? ""))
        }

        try await assertReply("DEEPSEEK")
        desk.selectRoute(.init(profileID: kimi.id, modelID: "k3.1-pro"), in: chat)
        try require(
            desk.reasoningChoices(for: chat).map(\.id) == ["low", "high", "max"],
            "Kimi's actual reasoning choices were not shown")
        try await assertReply("KIMI")
        desk.selectRoute(.init(profileID: gemini.id, modelID: "gemini-4-hydrogen"), in: chat)
        try require(
            desk.reasoningChoices(for: chat).map(\.id) == ["low", "medium", "high", "xhigh"],
            "Gemini Hydrogen's actual reasoning choices were not shown")
        desk.selectReasoning("xhigh", in: chat)
        try await assertReply("GEMINI")
        try require(
            chat.entries.contains { $0.kind == .reasoning && $0.text.contains("Gemini fixture thought") },
            "Gemini thought summaries did not reach the workbench")
        try await assertReply("GEMINI_REUSE")
        desk.selectRoute(.init(profileID: ProviderProfile.originalID, modelID: "gpt-6.2-sol"), in: chat)
        try await assertReply("BACK")
        desk.selectRoute(.init(profileID: ProviderProfile.originalID, modelID: "gpt-6.2-astra"), in: chat)
        try await assertReply("SAME")
        let saved = desk.providers.routes(for: root)!
        try require(
            saved.segments.count == 5 && Set(saved.segments.map(\.threadID)).count == 5
                && saved.segments[1].route.profileID == deep.id && saved.segments[2].route.profileID == kimi.id
                && saved.segments[3].route.profileID == gemini.id,
            "Provider-native continuation segments were missing")
        desk.providers.setDefault(kimi.id)
        desk.close()

        var noOpenAI = paths
        noOpenAI = EnginePaths(
            codexHome: paths.codexHome, credentialFile: scratch.appendingPathComponent("absent-key"),
            binary: paths.binary, endpoint: paths.endpoint, modelCatalog: paths.modelCatalog,
            providerTestEndpoints: paths.providerTestEndpoints)
        let restored = Workbench(paths: noOpenAI, defaults: defaults, profileKeys: keys)
        defer { restored.close() }
        restored.connect()
        try await waitFor("Multi-provider transcript loads even with no original API Key") {
            restored.selected.threadID == root && restored.selected.loadState != .loading
        }
        let reopened = restored.selected
        let tape = reopened.transcriptSnapshot()
        let items = tape.records.indices.compactMap(tape.entry).filter { $0.kind == .user || $0.kind == .answer }
        try require(
            reopened.loadState == .ready && reopened.title == "跨供应商会话验收" && reopened.route == saved.selection
                && restored.providers.defaultProfileID == kimi.id && items.filter { $0.kind == .user }.count == 7
                && items.filter { $0.kind == .answer }.count == 7
                && restored.sessions.filter { saved.segments.map(\.threadID).contains($0.threadID ?? "") }.count == 1,
            "Reopening lost or duplicated conversation history: " + (reopened.error ?? String(items.count)))
        try await checking("archive linked conversation") { try await restored.setArchived(reopened, true) }
        try await checking("unarchive linked conversation") { try await restored.setArchived(reopened, false) }
        try await checking("delete linked conversation and its segments") { try await restored.delete(reopened) }
        let retained = FileManager.default.enumerator(atPath: paths.codexHome.path)?.allObjects as? [String] ?? []
        try require(
            !saved.segments.contains { segment in retained.contains { $0.hasSuffix(segment.threadID + ".jsonl") } },
            "Deleting the logical conversation retained a backing segment")
        let standalone = restored.newConversation(in: folder)
        try require(
            standalone.profileID == kimi.id && standalone.modelID == "k3.1-pro",
            "New conversations ignored the default provider")
        standalone.draft = "OFFLINE_SWITCH_STANDALONE"
        restored.send(in: standalone)
        try await waitFor("Kimi-only route can start a fresh turn without an OpenAI key") { !standalone.isActive }
        try require(
            standalone.entries.contains { $0.text == "switch STANDALONE complete" },
            "Kimi-only execution failed: " + (standalone.error ?? standalone.finalStatus?.rawValue ?? ""))
        let standaloneID = standalone.threadID
        restored.close()
        let kimiOnly = Workbench(paths: noOpenAI, defaults: defaults, profileKeys: keys)
        defer { kimiOnly.close() }
        kimiOnly.connect()
        try await waitFor("Kimi-only conversation reloads") {
            kimiOnly.selected.threadID == standaloneID
                && kimiOnly.selected.entries.contains { $0.text == "switch STANDALONE complete" }
        }
        print(
            "PASS: provider keys, native tools, portable context, Gemini streaming and same-model continuation, Kimi without OpenAI, and logical archive/delete"
        )
    }

    @MainActor
    private static func checkAgentDispatch(in desk: Workbench, paths: EnginePaths, folder: URL) async throws {
        let scratch = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("workbench-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("mcp.sock").path
        let service = try AgentSocketServer(path: socket) { name, args in
            try await desk.callAgentTool(name, arguments: args)
        }
        defer { service.stop() }
        let caller = AgentRPCClient(path: socket, launchBundle: nil)
        func call(_ name: String, _ arguments: RPCObject) async throws -> RPCObject {
            try await Task.detached { try caller.call(name, arguments: arguments) }.value
        }
        let original = desk.selected
        let models = try await call("list_models", ["provider": ProviderProfile.originalID])
        try require(
            (models["providers"] as? [RPCObject])?.count == 1 && models["default_provider"] as? String != nil,
            "MCP did not list available models")
        let args: RPCObject = [
            "prompt": "OFFLINE_MCP_TASK", "workspace": folder.path, "request_id": "mcp-test",
            "model": "gpt-6.2-sol", "effort": "low",
        ]
        let receipt = try await call("dispatch_task", args)
        guard let id = receipt["task_id"] as? String else { throw WorkbenchError("Missing MCP task receipt") }
        let repeatReceipt = try await call("dispatch_task", args)
        try require(
            repeatReceipt["task_id"] as? String == id && desk.selected === original,
            "MCP retries duplicated or refocused the task")
        var conflict = args
        conflict["prompt"] = "A different task"
        do {
            _ = try await call("dispatch_task", conflict)
            throw WorkbenchError("MCP accepted a reused request_id for a different task")
        } catch let error as WorkbenchError {
            try require(error.localizedDescription.contains("request_id 已用于"), error.localizedDescription)
        }
        let terminal = try await call("task_status", ["task_id": id, "wait_seconds": 20, "max_chars": 8])
        guard let thread = terminal["session_id"] as? String, let revision = terminal["revision"] as? Int else {
            throw WorkbenchError("MCP did not link the completed task to a session")
        }
        try require(
            terminal["status"] as? String == "completed" && terminal["answer"] as? String == "stream B"
                && terminal["next_offset"] as? Int == 8 && desk.selected === original
                && desk.sessions.first(where: { $0.threadID == thread })?.permissionMode == .workspace,
            "MCP did not return a compact result for the background workspace task")
        let page = try await call("task_status", ["task_id": id, "offset": 8])
        let unchanged = try await call("task_status", ["task_id": id, "after_revision": revision])
        let stored = try AgentTaskStore(state: paths.state).existing(id)
        try require(
            page["answer"] as? String == " complete" && unchanged["unchanged"] as? Bool == true
                && unchanged["answer"] == nil && stored?.status == .completed && stored?.sessionID == thread,
            "MCP result pagination, revision, or persistence failed")

        let stopping = try await call(
            "dispatch_task",
            [
                "prompt": "OFFLINE_MCP_STOP", "workspace": folder.path,
                "request_id": "mcp-stop",
            ])
        guard let stopID = stopping["task_id"] as? String else { throw WorkbenchError("Missing cancellable MCP task") }
        try await waitFor("MCP turn has started streaming") {
            desk.sessions.contains { $0.agentTaskID == stopID && $0.entries.contains { $0.text == "stream MCP_STOP" } }
        }
        let acknowledgement = try await call("cancel_task", ["task_id": stopID])
        let cancelled = try await call("task_status", ["task_id": stopID, "wait_seconds": 20])
        try require(
            acknowledgement["status"] as? String == "stopping" && cancelled["status"] as? String == "cancelled"
                && desk.selected === original,
            "MCP cancellation failed: \(acknowledgement["status"] ?? "missing") -> \(cancelled["status"] ?? "missing")")
        print("PASS: local MCP dispatch, idempotency, default permissions, compact results, and cancellation")
    }

    @MainActor
    private static func checkStagedGeminiSetup() throws {
        let suite = "local.codex-api-workbench.gemini-setup." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = FixtureKeys()
        let fresh = ProviderConfiguration(defaults: defaults, keys: keys)
        let legacyProfiles = fresh.profiles.filter { $0.kind != .gemini }
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyProfiles))
        let preference = "directProviderConfiguration"
        func previousState(defaultID: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "profiles": legacy, "defaultProfileID": defaultID, "conversations": [:],
            ])
        }
        let base = try previousState(defaultID: ProviderProfile.originalID)
        defaults.set(base, forKey: preference)
        let pending = ProviderConfiguration(defaults: defaults, keys: keys)
        var gemini = pending.profiles.first { $0.kind == .gemini }!
        gemini.verifiedModelIDs = ["gemini-3.8-flash"]
        try pending.save(gemini, key: "offline-staged-gemini", activateOnLaunch: true)
        try require(
            defaults.data(forKey: preference) == base, "Staging overwrote preferences used by the current process")
        let priorDefault = legacyProfiles.first(where: { $0.kind == .kimiCode })!.id
        defaults.set(try previousState(defaultID: priorDefault), forKey: preference)
        let launched = ProviderConfiguration(defaults: defaults, keys: keys)
        let saved = launched.profile(gemini.id)!
        let secret = try launched.secret(for: saved, using: .local)
        try require(
            launched.defaultProfileID == priorDefault && launched.configured(saved)
                && saved.definitions.map(\.id) == ["gemini-3.8-flash"] && secret == "offline-staged-gemini",
            "The new version failed to merge Gemini setup without reverting the previous configuration")
    }

    private static func checkApprovalOptions() throws {
        let approvalMethod = "item/commandExecution/requestApproval"
        let raw: RPCObject = [
            "turnId": "test",
            "command": "/usr/bin/printf ok",
            "availableDecisions": [
                "accept", "decline",
                [
                    "acceptWithExecpolicyAmendment": [
                        "execpolicy_amendment": ["/usr/bin/printf", "ok"]
                    ]
                ],
            ] as [Any],
        ]
        let options = Approval(wireID: "1", method: approvalMethod, params: raw, itemDetail: nil)?.options ?? []
        let rule = options.first { $0.scope == .rule }?.result["decision"] as? RPCObject
        try require(
            rule?["acceptWithExecpolicyAmendment"] != nil && !options.contains { $0.scope == .session },
            "The client did not respect the server's offered decisions")
        let extra = Approval(
            wireID: 1, method: "item/permissions/requestApproval",
            params: ["turnId": "test", "permissions": ["network": ["enabled": true]]],
            itemDetail: nil)
        try require(
            extra?.options.first { $0.scope == .session }?.result["scope"] as? String == "session"
                && Approval.key(for: 1) != Approval.key(for: "1"), "Permission scope or request identity was lost")
        try require(
            TranscriptEntry([
                "type": "reasoning", "id": "private", "summary": [],
                "content": ["fixture-only private reasoning"],
            ]) == nil,
            "An entry used raw reasoning instead of the public summary")
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw WorkbenchError(message) }
    }

    @MainActor
    private static func checking(_ name: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { throw WorkbenchError("\(name): \(error.localizedDescription)") }
    }

    @MainActor
    private static func waitFor(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw WorkbenchError("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}

private final class FixtureKeys: ProfileKeyStore {
    private var values: [String: String] = [:]
    func read(_ id: String) throws -> String {
        guard let value = values[id] else { throw WorkbenchError("Missing test key.") }
        return value
    }
    func write(_ value: String, id: String) throws { values[id] = value }
    func remove(_ id: String) throws { values.removeValue(forKey: id) }
}
