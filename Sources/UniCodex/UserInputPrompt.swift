import SwiftUI

struct UserInputPrompt: View {
    @Environment(\.uiStrings) private var strings
    @Environment(\.workbenchTheme) private var theme
    let request: UserInputRequest
    let submitting: Bool
    let submit: ([String: String]) -> Void

    private enum Choice: Hashable {
        case option(String)
        case custom
    }
    @State private var choices: [String: Choice] = [:]
    @State private var written: [String: String] = [:]

    private var answers: [String: String] {
        request.questions.reduce(into: [:]) { result, question in
            if case .option(let value) = choices[question.id] {
                result[question.id] = value
            } else if question.choices.isEmpty || choices[question.id] == .custom {
                result[question.id] = written[question.id]
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(strings.text("question.title"), systemImage: "questionmark.bubble")
                .font(.callout.weight(.semibold))
            ViewThatFits(in: .vertical) {
                questions.fixedSize(horizontal: false, vertical: true)
                ScrollView { questions }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: 210, alignment: .top)
            HStack {
                Spacer()
                if submitting { ProgressView().controlSize(.small) }
                Button(strings.text("question.submit")) { submit(answers) }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.actionTint)
                    .disabled(submitting || request.response(to: answers) == nil)
            }
        }
        .padding(14)
        .accessibilityIdentifier("codex-question")
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 5) {
                    Text(question.question).font(.callout)
                    if !question.choices.isEmpty {
                        Picker(
                            question.header,
                            selection: Binding(
                                get: { choices[question.id] },
                                set: { choices[question.id] = $0 }
                            )
                        ) {
                            Text(strings.text("question.choose")).tag(nil as Choice?)
                            ForEach(question.choices) { option in
                                Text(option.label).tag(Optional(Choice.option(option.label)))
                            }
                            if question.isOther {
                                Text(strings.text("question.other")).tag(Optional(Choice.custom))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        if case .option(let label) = choices[question.id],
                            let detail = question.choices.first(where: { $0.label == label })?.description,
                            !detail.isEmpty
                        {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if question.choices.isEmpty || choices[question.id] == .custom {
                        let value = Binding(
                            get: { written[question.id] ?? "" },
                            set: { written[question.id] = $0 })
                        if question.isSecret {
                            SecureField(strings.text("question.answer"), text: value)
                        } else {
                            TextField(strings.text("question.answer"), text: value)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(submitting)
    }
}
