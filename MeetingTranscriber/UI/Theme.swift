import SwiftUI

enum Theme {
    static let cornerRadius: CGFloat = 16
    static let innerPadding: CGFloat = 20

    // "Obsidian Flux" palette — deep monochrome canvas + a single warm violet accent.
    static let accent  = Color(red: 0.545, green: 0.361, blue: 0.965)   // #8B5CF6 — active/focus/selection
    static let record  = Color(red: 0.953, green: 0.376, blue: 0.424)   // rose — record/stop only
    static let canvas  = Color(red: 0.059, green: 0.059, blue: 0.059)   // #0F0F0F
    static let surface = Color(red: 0.102, green: 0.102, blue: 0.102)   // #1A1A1A
    static let hairline = Color.white.opacity(0.08)                     // ~#2A2A2A on the dark canvas
    static let subtle  = Color.primary.opacity(0.65)

    static let monoFont = Font.system(.body, design: .monospaced)
    static let titleFont = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let sectionTitleFont = Font.system(size: 15, weight: .medium, design: .rounded)
}

/// A card with Liquid Glass background. Deployment target is macOS 26,
/// so we can use `glassEffect` directly.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerRadius
    var padding: CGFloat = Theme.innerPadding
    let content: () -> Content

    init(cornerRadius: CGFloat = Theme.cornerRadius,
         padding: CGFloat = Theme.innerPadding,
         @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
