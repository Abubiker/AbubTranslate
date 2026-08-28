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
        // Settings: чуть более видимая рамка без декоративного стекла
        static let borderSettings = Color.primary.opacity(0.18)
        static let borderStrong = Color.primary.opacity(0.14)
        static let highlight = Color.white.opacity(0.06)
        static let bgCard = Color(NSColor.controlBackgroundColor)
        static let bgCardElevated = Color(NSColor.controlBackgroundColor).opacity(0.95)
        // для Settings — плоский фон, привязанный к appearanceMode
        static let bgSettings = Color(NSColor.windowBackgroundColor)
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
    // Плотнее прежних 20 — карточки должны читаться почти слитным блоком,
    // не набором отдельных коробок с большими воздушными полями.
    var padding: CGFloat = DSTokens.lg
    func body(content: Content) -> some View {
        // Liquid Glass — только macOS 26+, .glassEffect() на более старых
        // системах не существует. Применяется прямо к контенту (не вложен
        // в .background{}) — так его рендерит система, включая свою кромку
        // и подсветку, поэтому ручные border/highlight/shadow ниже для этой
        // ветки убраны — дублировали бы то, что уже рисует стекло, и
        // выглядели бы шумно поверх него. Без .tint()/.interactive():
        // это статичный контейнер, не кнопка — попросили сдержанно.
        if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DSTokens.radiusCard))
        } else {
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                        .fill(DSTokens.Colors.bgCard)
                )
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
}

struct SettingsCardSurface: ViewModifier {
    var padding: CGFloat = DSTokens.lg
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DSTokens.radiusCard))
        } else {
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: DSTokens.radiusCardSmall)
                        .fill(DSTokens.Colors.bgSettings)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DSTokens.radiusCardSmall)
                        .stroke(DSTokens.Colors.borderSettings, lineWidth: 1)
                )
        }
    }
}

/// Liquid Glass фон для Settings на macOS 26+.
/// Стеклу карточек нужен цветной фон — без него .glassEffect() почти не виден.
@available(macOS 26.0, *)
struct SettingsBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ZStack {
            colorScheme == .dark
                ? Color(red: 0.08, green: 0.08, blue: 0.13)
                : Color(red: 0.92, green: 0.94, blue: 0.98)
            RadialGradient(
                colors: [
                    colorScheme == .dark
                        ? Color(red: 0.22, green: 0.32, blue: 0.72).opacity(0.38)
                        : Color(red: 0.45, green: 0.55, blue: 0.95).opacity(0.22),
                    .clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 480
            )
            RadialGradient(
                colors: [
                    colorScheme == .dark
                        ? Color(red: 0.46, green: 0.20, blue: 0.62).opacity(0.24)
                        : Color(red: 0.76, green: 0.50, blue: 0.92).opacity(0.18),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 400
            )
        }
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
    /// Минимальный flat-фон для Settings: тонкая рамка + цвет окна, без glass/shadow.
    /// Радиус 12 (radiusCardSmall) для компактного вида.
    func settingsCardSurface(padding: CGFloat = DSTokens.lg) -> some View {
        modifier(SettingsCardSurface(padding: padding))
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
