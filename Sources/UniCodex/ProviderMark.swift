import SwiftUI

struct ProviderMark: View {
    let kind: ProviderKind
    var size: CGFloat = 15

    var body: some View {
        Self.menuImage(for: kind)
            .font(.system(size: size, weight: .medium))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func menuImage(for kind: ProviderKind) -> Image {
        let symbol: String
        switch kind {
        case .openAI: symbol = "brain"
        case .deepSeek: symbol = "water.waves"
        case .kimiCode: symbol = "moon.stars"
        case .gemini: symbol = "sparkles"
        case .compatible: symbol = "link"
        }
        return Image(systemName: symbol)
    }
}
