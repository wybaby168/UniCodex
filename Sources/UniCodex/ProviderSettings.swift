import SwiftUI

struct ProviderSettings: View {
    @Environment(\.uiStrings) private var strings
    let workbench: Workbench
    @AppStorage(WorkbenchTheme.preference) private var theme = WorkbenchTheme.ocean
    @State private var editing: ProviderProfile
    @State private var key = ""
    @State private var result: String?
    @State private var failed = false
    @State private var saving = false
    @State private var confirmingClear = false

    init(workbench: Workbench) {
        self.workbench = workbench
        _editing = State(initialValue: workbench.providers.profile(workbench.providers.defaultProfileID) ?? .original)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(strings.text("provider.heading")).font(.headline)
                    Spacer()
                    Menu {
                        ForEach(ProviderKind.allCases) { kind in
                            Button {
                                add(kind)
                            } label: {
                                Label {
                                    Text(kind.title)
                                } icon: {
                                    ProviderMark.menuImage(for: kind)
                                }
                                .labelStyle(.titleAndIcon)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel(strings.text("provider.add"))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(strings.text("provider.add_help"))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)

                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(workbench.providers.profiles) { profile in
                            profileButton(profile)
                        }
                        if workbench.providers.profile(editing.id) == nil { profileButton(editing) }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: 212)
            Divider()
            Form {
                Section {
                    Label {
                        Text(editing.kind.title)
                    } icon: {
                        ProviderMark(kind: editing.kind, size: 20)
                    }
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    TextField(strings.text("provider.profile_name"), text: $editing.name)
                    if editing.kind == .kimiCode {
                        Picker(strings.text("provider.region"), selection: $editing.region) {
                            ForEach(ProviderProfile.Region.allCases) { region in
                                Text(region.title).tag(region)
                            }
                        }
                    }
                    if editing.kind == .compatible {
                        TextField(
                            "HTTPS Base URL", text: $editing.customURL, prompt: Text("https://api.example.com/v1"))
                        TextField(
                            strings.text("provider.model_ids"), text: customModels,
                            prompt: Text(strings.text("provider.model_separator")))
                        Text(strings.text("provider.responses_hint")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent(strings.text("provider.endpoint")) {
                            Text(editing.endpoint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }

                Section("API Key") {
                    if editing.isOriginal {
                        LabeledContent(
                            strings.text("provider.original_key"),
                            value: configured ? strings.text("provider.loaded") : strings.text("provider.not_loaded"))
                    } else {
                        SecureField(
                            configured ? strings.text("provider.keep_key") : strings.text("provider.enter_key"),
                            text: $key
                        )
                        .accessibilityLabel("API Key")
                        Text(strings.text("provider.keychain")).font(.caption).foregroundStyle(.secondary)
                        if configured {
                            Button(strings.text("keychain.restore")) { Task { await restoreKey() } }
                                .controlSize(.small)
                        }
                    }
                }

                Section(strings.text("provider.models")) {
                    let available = workbench.models(for: editing)
                    if !editing.isOriginal && !available.isEmpty {
                        Picker(strings.text("provider.default_model"), selection: modelSelection(available: available))
                        {
                            ForEach(available) { model in Text(model.name).tag(model.id) }
                        }
                    }
                    HStack(spacing: 8) {
                        Button(strings.text("provider.new_default")) { workbench.providers.setDefault(editing.id) }
                            .disabled(!savedAndConfigured || workbench.providers.defaultProfileID == editing.id)
                        Button(strings.text("provider.use_today")) {
                            workbench.useProfile(editing.id, in: workbench.selected)
                        }
                        .disabled(!savedAndConfigured || available.isEmpty)
                    }
                    Text(strings.text("provider.applies_next")).font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if let result {
                        Label(result, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.callout).foregroundStyle(failed ? .orange : .secondary)
                    }
                    HStack {
                        if !editing.isOriginal && configured {
                            Button(strings.text("provider.remove_key"), role: .destructive) { confirmingClear = true }
                        }
                        Spacer()
                        if saving {
                            ProgressView().controlSize(.small).accessibilityLabel(strings.text("provider.verify"))
                        }
                        Button(strings.text("provider.save")) { Task { await save() } }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.actionTint)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .disabled(saving)
        .confirmationDialog(
            strings.text("provider.remove_question"), isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button(strings.text("provider.remove_key"), role: .destructive) { clearKey() }
        } message: {
            Text(strings.text("provider.remove_details"))
        }
    }

    private var configured: Bool {
        workbench.providers.profile(editing.id).map(workbench.providers.configured) ?? false
    }
    private var savedAndConfigured: Bool {
        configured && workbench.providers.profile(editing.id) == editing && key.isEmpty
    }

    private var customModels: Binding<String> {
        Binding(
            get: { editing.customModels.joined(separator: ", ") },
            set: {
                editing.customModels = $0.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            })
    }

    private func modelSelection(available: [ModelChoice]) -> Binding<String> {
        Binding(
            get: {
                available.contains { $0.id == editing.defaultModel }
                    ? editing.defaultModel : (available.first?.id ?? "")
            }, set: { editing.defaultModel = $0 })
    }

    private func profileButton(_ profile: ProviderProfile) -> some View {
        Button {
            editing = profile
            key = ""
            result = nil
        } label: {
            HStack(spacing: 9) {
                ProviderMark(kind: profile.kind, size: 17)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.callout.weight(profile.id == editing.id ? .semibold : .medium)).lineLimit(
                        1)
                    Text(
                        workbench.providers.configured(profile)
                            ? strings.text("provider.configured") : strings.text("provider.not_configured")
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                if profile.id == workbench.providers.defaultProfileID {
                    Text(strings.text("common.default")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(.rect)
            .background {
                if editing.id == profile.id { RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.10)) }
            }
        }
        .buttonStyle(.plain)
    }

    private func add(_ kind: ProviderKind) {
        editing = ProviderProfile(
            name: kind.title, kind: kind,
            defaultModel: kind.builtInModels.first?.id ?? workbench.openAICatalog.first(where: \.isDefault)?.id ?? "")
        key = ""
        result = nil
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            if editing.kind == .gemini, !key.isEmpty {
                editing.verifiedModelIDs = try await GeminiAPI.availableModelIDs(using: key)
            }
            let available = workbench.models(for: editing)
            if editing.defaultModel.isEmpty, let first = available.first { editing.defaultModel = first.id }
            try workbench.providers.save(editing, key: key.isEmpty ? nil : key)
            editing = workbench.providers.profile(editing.id) ?? editing
            key = ""
            workbench.providerConfigurationChanged()
            failed = false
            result = strings.text("provider.saved")
        } catch {
            failed = true
            result = error.localizedDescription
        }
    }

    private func clearKey() {
        do {
            try workbench.providers.clearKey(for: editing.id)
            editing = workbench.providers.profile(editing.id) ?? editing
            key = ""
            workbench.providerConfigurationChanged()
            failed = false
            result = strings.text("provider.removed")
        } catch {
            failed = true
            result = error.localizedDescription
        }
    }

    private func restoreKey() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let id = editing.id
        do {
            try await Task.detached(priority: .userInitiated) {
                let keys = KeychainProfileKeys()
                do { _ = try keys.read(id) } catch { try keys.restore(id) }
            }.value
            result = strings.text("keychain.restored")
            failed = false
        } catch {
            result = error.localizedDescription
            failed = true
        }
    }
}
