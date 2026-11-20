import SwiftUI

struct ProviderMark: View {
    let kind: ProviderKind
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let asset = Self.asset(for: kind) {
                Image(asset)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "link").font(.system(size: size, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func menuImage(for kind: ProviderKind) -> Image {
        if let asset = asset(for: kind) {
            return Image(asset).renderingMode(.original)
        }
        return Image(systemName: "link")
    }

    private static func asset(for kind: ProviderKind) -> String? {
        switch kind {
        case .openAI: "ProviderOpenAI"
        case .deepSeek: "ProviderDeepSeek"
        case .kimiCode: "ProviderKimi"
        case .gemini: "ProviderGemini"
        case .compatible: nil
        }
    }
}
