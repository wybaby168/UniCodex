import AppKit
import SwiftUI

enum WorkbenchTheme: String, CaseIterable, Identifiable {
    case ocean
    case indigo
    case system

    static let preference = "workbenchTheme"
    var id: Self { self }

    func title(using strings: UIStrings) -> String {
        switch self {
        case .ocean: strings.text("appearance.ocean")
        case .indigo: strings.text("appearance.indigo")
        case .system: strings.text("common.system")
        }
    }

    var accent: Color { Color(nsColor: accentColor) }
    var glassTint: Color? { self == .system ? nil : accent.opacity(0.14) }
    var actionTint: Color {
        switch self {
        case .ocean: Color(nsColor: Self.oceanAction)
        case .indigo: Color(nsColor: Self.indigoAction)
        case .system: accent
        }
    }

    var accentColor: NSColor {
        switch self {
        case .ocean: Self.oceanAccent
        case .indigo: Self.indigoAccent
        case .system: .controlAccentColor
        }
    }

    var linkColor: NSColor { self == .system ? .linkColor : accentColor }

    fileprivate var swatchImage: NSImage {
        let color = accentColor
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { bounds in
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        // AppKit menus recolor template images, which would hide the option's own color.
        image.isTemplate = false
        return image
    }

    private static let oceanAction = NSColor(srgbRed: 0.035, green: 0.37, blue: 0.46, alpha: 1)
    private static let indigoAction = NSColor(srgbRed: 0.26, green: 0.28, blue: 0.65, alpha: 1)
    private static let oceanAccent = adaptive(
        light: oceanAction,
        dark: NSColor(srgbRed: 0.44, green: 0.84, blue: 0.89, alpha: 1)
    )
    private static let indigoAccent = adaptive(
        light: indigoAction,
        dark: NSColor(srgbRed: 0.66, green: 0.69, blue: 1.00, alpha: 1)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

private struct WorkbenchThemeKey: EnvironmentKey {
    static let defaultValue = WorkbenchTheme.ocean
}

extension EnvironmentValues {
    var workbenchTheme: WorkbenchTheme {
        get { self[WorkbenchThemeKey.self] }
        set { self[WorkbenchThemeKey.self] = newValue }
    }
}

struct AppearanceSettings: View {
    @Environment(\.uiStrings) private var strings
    @AppStorage(WorkbenchTheme.preference) private var theme = WorkbenchTheme.ocean
    @AppStorage(UIStrings.preference) private var language = UIStrings.system

    var body: some View {
        Form {
            Section {
                Picker(strings.text("appearance.accent"), selection: $theme) {
                    ForEach(WorkbenchTheme.allCases) { option in
                        Label {
                            Text(option.title(using: strings))
                        } icon: {
                            if option == .system {
                                Image(systemName: "circle.lefthalf.filled")
                            } else {
                                Image(nsImage: option.swatchImage).renderingMode(.original)
                            }
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("theme-picker")
                .id(strings.selection)
            }
            Section(strings.text("appearance.preview")) {
                preview
                    .accessibilityHidden(true)
            }
            Section {
                Picker(strings.text("language.application"), selection: $language) {
                    Text(strings.text("common.system")).tag(UIStrings.system)
                    ForEach(UIStrings.availableLanguages, id: \.self) { id in
                        Text(verbatim: UIStrings.languageName(id)).tag(id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var preview: some View {
        let chat = Label(strings.text("sidebar.chats"), systemImage: "bubble.left")
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.accent.opacity(0.11), in: .rect(cornerRadius: 8))
        let send = Label(strings.text("common.send"), systemImage: "arrow.up")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

        HStack(spacing: 12) {
            chat
            Spacer(minLength: 0)
            if #available(macOS 26, *) {
                send.glassEffect(.regular.tint(theme.glassTint), in: .capsule)
            } else {
                send.background(.regularMaterial, in: .capsule)
            }
        }
        .font(.callout.weight(.medium))
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
    }
}
