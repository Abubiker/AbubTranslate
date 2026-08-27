import SwiftUI

// MARK: - Design Tokens — calm premium system-first

enum DSTokens {
    // Spacing — 8px base + 20 as per system
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let lgPlus: CGFloat = 20
    static let xl: CGFloat = 24
    static let xlPlus: CGFloat = 32
    static let xxl: CGFloat = 40

    // Radius — 12 controls, 16 cards, 20 panels
    static let radiusCard: CGFloat = 16
    static let radiusCardSmall: CGFloat = 12
    static let radiusPill: CGFloat = 999
    static let radiusControl: CGFloat = 12
    static let radiusPanel: CGFloat = 20

    // Typography — tight scale
    static let overlineSize: CGFloat = 11
    static let metaSize: CGFloat = 12
    static let labelSize: CGFloat = 13
    static let bodySize: CGFloat = 14
    static let bodyLargeSize: CGFloat = 16
    static let sectionTitleSize: CGFloat = 18
    static let pageTitleSize: CGFloat = 26

    // Semantic colors — neutral-first OKLCH approximated
    enum Colors {
        static let border = Color.primary.opacity(0.09)
        static let borderStrong = Color.primary.opacity(0.14)
        static let highlight = Color.white.opacity(0.06)
        static let bgCard = Color(NSColor.controlBackgroundColor)
        static let bgCardElevated = Color(NSColor.controlBackgroundColor).opacity(0.95)
        static let shadow = Color.black.opacity(0.18)
        static let shadowSoft = Color.black.opacity(0.10)
        // status only
        static let orangeBg = Color.orange.opacity(0.08)
        static let orangeBorder = Color.orange.opacity(0.18)
    }

    // Shadow — layered soft
    static let shadowSoft: (Color, CGFloat, CGFloat, CGFloat) = (Colors.shadow, 12, 0, 8)
}

// MARK: - Card surfaces — depth over decoration

struct CardSurface: ViewModifier {
    var padding: CGFloat = DSTokens.lgPlus // 20 as per system: generous card padding
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                    .fill(DSTokens.Colors.bgCard)
            )
            // faint top highlight
            .overlay(
                RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                    .stroke(DSTokens.Colors.border, lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                    .stroke(DSTokens.Colors.highlight, lineWidth: 0.5)
                    .mask(
                        RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .opacity(0.6)
            )
            .shadow(color: DSTokens.Colors.shadow.opacity(0.08), radius: 12, x: 0, y: 4)
            .shadow(color: DSTokens.Colors.shadow.opacity(0.06), radius: 32, x: 0, y: 12)
    }
}

struct PanelCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                    .stroke(DSTokens.Colors.border, lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                    .stroke(DSTokens.Colors.highlight, lineWidth: 0.5)
                    .opacity(0.45)
            )
            .clipShape(RoundedRectangle(cornerRadius: DSTokens.radiusCard))
            .shadow(color: DSTokens.Colors.shadow.opacity(0.12), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Interaction

struct HoverLift: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered ? 1.01 : 1.0)
            .offset(y: hovered ? -1 : 0)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .onHover { hovered = $0 }
    }
}

extension View {
    func cardSurface(padding: CGFloat = DSTokens.lgPlus) -> some View {
        modifier(CardSurface(padding: padding))
    }
    func panelCardSurface() -> some View {
        modifier(PanelCardSurface())
    }
    func hoverLift() -> some View { modifier(HoverLift()) }

    // Typography helpers
    func overlineStyle() -> some View {
        font(.system(size: DSTokens.overlineSize, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary.opacity(0.85))
    }
    func sectionTitleStyle() -> some View {
        font(.system(size: DSTokens.sectionTitleSize, weight: .semibold))
            .foregroundStyle(.primary)
            .lineSpacing(-0.5)
    }
    func pageTitleStyle() -> some View {
        font(.system(size: DSTokens.pageTitleSize, weight: .bold))
            .foregroundStyle(.primary)
            .lineSpacing(-0.8)
    }
    func footnoteMuted() -> some View {
        font(.system(size: DSTokens.labelSize, weight: .regular))
            .foregroundStyle(.secondary)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
