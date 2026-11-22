import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

struct AppPalette: Equatable {
    let canvas: Color
    let sidebar: Color
    let panel: Color
    let raised: Color
    let hairline: Color
    let hairlineStrong: Color
    let text: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let accentDeep: Color
    let applied: Color
    let warning: Color
    let danger: Color

    var accentWash: Color { accent.opacity(0.12) }
}

struct AppThemeDefinition: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let colorScheme: ColorScheme
    let cardCorner: CGFloat
    let palette: AppPalette

    static func == (lhs: AppThemeDefinition, rhs: AppThemeDefinition) -> Bool {
        lhs.id == rhs.id
    }

    static let darkroom = AppThemeDefinition(
        id: "darkroom",
        name: "深夜暗房",
        subtitle: "石墨、黄铜与接触印相表",
        colorScheme: .dark,
        cardCorner: 6,
        palette: AppPalette(
            canvas: Color(hex: 0x0F1011),
            sidebar: Color(hex: 0x131416),
            panel: Color(hex: 0x17181A),
            raised: Color(hex: 0x1E2023),
            hairline: Color(hex: 0x2B2D30),
            hairlineStrong: Color(hex: 0x3A3C3F),
            text: Color(hex: 0xEDE9E2),
            textSecondary: Color(hex: 0x9C9992),
            textTertiary: Color(hex: 0x6E6B65),
            accent: Color(hex: 0xC8A468),
            accentDeep: Color(hex: 0x8C7247),
            applied: Color(hex: 0x8FAE7A),
            warning: Color(hex: 0xD1A25A),
            danger: Color(hex: 0xC97F76)
        )
    )

    static let midnight = AppThemeDefinition(
        id: "midnight",
        name: "午夜",
        subtitle: "纯黑、银白与最高对比",
        colorScheme: .dark,
        cardCorner: 3,
        palette: AppPalette(
            canvas: Color(hex: 0x000000),
            sidebar: Color(hex: 0x050505),
            panel: Color(hex: 0x0A0A0A),
            raised: Color(hex: 0x121212),
            hairline: Color(hex: 0x242424),
            hairlineStrong: Color(hex: 0x3A3A3A),
            text: Color(hex: 0xF4F4F1),
            textSecondary: Color(hex: 0xA3A3A0),
            textTertiary: Color(hex: 0x70706E),
            accent: Color(hex: 0xE6E6E1),
            accentDeep: Color(hex: 0xB8B8B2),
            applied: Color(hex: 0x9DBE9D),
            warning: Color(hex: 0xD0B078),
            danger: Color(hex: 0xD08A84)
        )
    )

    static let morning = AppThemeDefinition(
        id: "morning",
        name: "晨光",
        subtitle: "冷白纸面、墨色与深青",
        colorScheme: .light,
        cardCorner: 8,
        palette: AppPalette(
            canvas: Color(hex: 0xF4F5F2),
            sidebar: Color(hex: 0xE9EBE6),
            panel: Color(hex: 0xFBFCFA),
            raised: Color(hex: 0xEEF1EB),
            hairline: Color(hex: 0xD3D7CE),
            hairlineStrong: Color(hex: 0xB9BFB4),
            text: Color(hex: 0x1B1E1A),
            textSecondary: Color(hex: 0x5C625B),
            textTertiary: Color(hex: 0x8A9087),
            accent: Color(hex: 0x2F5D62),
            accentDeep: Color(hex: 0x23474B),
            applied: Color(hex: 0x3F7D5A),
            warning: Color(hex: 0xA66A2E),
            danger: Color(hex: 0xA64B45)
        )
    )

    static let blueHour = AppThemeDefinition(
        id: "blueHour",
        name: "蓝调时刻",
        subtitle: "深海蓝、冰蓝与夜色",
        colorScheme: .dark,
        cardCorner: 6,
        palette: AppPalette(
            canvas: Color(hex: 0x0B1320),
            sidebar: Color(hex: 0x0E1726),
            panel: Color(hex: 0x111C2C),
            raised: Color(hex: 0x182538),
            hairline: Color(hex: 0x26364D),
            hairlineStrong: Color(hex: 0x354A66),
            text: Color(hex: 0xE7EDF5),
            textSecondary: Color(hex: 0x9AA9BC),
            textTertiary: Color(hex: 0x6B7C91),
            accent: Color(hex: 0x7FB4D9),
            accentDeep: Color(hex: 0x5B8FB5),
            applied: Color(hex: 0x8FBFA8),
            warning: Color(hex: 0xD6A96C),
            danger: Color(hex: 0xD98B8B)
        )
    )

    static let noon = AppThemeDefinition(
        id: "noon",
        name: "正午",
        subtitle: "明亮中性灰、钴蓝与清晰边界",
        colorScheme: .light,
        cardCorner: 8,
        palette: AppPalette(
            canvas: Color(hex: 0xF1F2EF),
            sidebar: Color(hex: 0xE6E8E3),
            panel: Color(hex: 0xFAFBF8),
            raised: Color(hex: 0xEDEFEA),
            hairline: Color(hex: 0xD0D4CC),
            hairlineStrong: Color(hex: 0xB6BCB2),
            text: Color(hex: 0x181A18),
            textSecondary: Color(hex: 0x5A6058),
            textTertiary: Color(hex: 0x858B81),
            accent: Color(hex: 0x1F5F8B),
            accentDeep: Color(hex: 0x164766),
            applied: Color(hex: 0x3B7D5A),
            warning: Color(hex: 0xA66A2E),
            danger: Color(hex: 0xA64B45)
        )
    )

    static let ember = AppThemeDefinition(
        id: "ember",
        name: "余烬",
        subtitle: "深棕、铜色与暖光",
        colorScheme: .dark,
        cardCorner: 6,
        palette: AppPalette(
            canvas: Color(hex: 0x14100E),
            sidebar: Color(hex: 0x181311),
            panel: Color(hex: 0x1E1815),
            raised: Color(hex: 0x291F1A),
            hairline: Color(hex: 0x3A2D25),
            hairlineStrong: Color(hex: 0x4D3A2F),
            text: Color(hex: 0xF1E8DC),
            textSecondary: Color(hex: 0xB6A797),
            textTertiary: Color(hex: 0x7E7164),
            accent: Color(hex: 0xC98A5E),
            accentDeep: Color(hex: 0xA06A44),
            applied: Color(hex: 0x9DAE7A),
            warning: Color(hex: 0xD6A15E),
            danger: Color(hex: 0xC97B72)
        )
    )

    static let all: [AppThemeDefinition] = [
        .darkroom,
        .midnight,
        .morning,
        .blueHour,
        .noon,
        .ember
    ]

    static func theme(withID id: String) -> AppThemeDefinition? {
        all.first { $0.id == id }
    }
}

enum SystemAppearance {
    /// Captured before the app applies a theme so wallpaper windows keep the
    /// system appearance instead of following the app chrome.
    static var current: NSAppearance?
}

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var activeTheme: AppThemeDefinition

    private init() {
        SystemAppearance.current = NSApp.effectiveAppearance
        let savedID = UserDefaults.standard.string(forKey: SettingsKey.appearanceTheme) ?? ""
        let theme = AppThemeDefinition.theme(withID: savedID) ?? .darkroom
        activeTheme = theme
        AppTheme.current = theme
        Self.applyAppAppearance(theme)
    }

    func select(_ theme: AppThemeDefinition) {
        guard theme.id != activeTheme.id else { return }
        AppTheme.current = theme
        activeTheme = theme
        UserDefaults.standard.set(theme.id, forKey: SettingsKey.appearanceTheme)
        Self.applyAppAppearance(theme)
    }

    private static func applyAppAppearance(_ theme: AppThemeDefinition) {
        NSApp.appearance = NSAppearance(named: theme.colorScheme == .light ? .aqua : .darkAqua)
    }
}

enum AppTheme {
    static var current: AppThemeDefinition = .darkroom

    enum Palette {
        static var canvas: Color { current.palette.canvas }
        static var sidebar: Color { current.palette.sidebar }
        static var panel: Color { current.palette.panel }
        static var raised: Color { current.palette.raised }
        static var hairline: Color { current.palette.hairline }
        static var hairlineStrong: Color { current.palette.hairlineStrong }
        static var text: Color { current.palette.text }
        static var textSecondary: Color { current.palette.textSecondary }
        static var textTertiary: Color { current.palette.textTertiary }
        static var accent: Color { current.palette.accent }
        static var accentDeep: Color { current.palette.accentDeep }
        static var accentWash: Color { current.palette.accentWash }
        static var applied: Color { current.palette.applied }
        static var warning: Color { current.palette.warning }
        static var danger: Color { current.palette.danger }
    }

    enum Typography {
        static func display(_ size: CGFloat = 23) -> Font {
            .system(size: size, weight: .semibold, design: .serif)
        }

        static let pageTitle = Font.system(size: 23, weight: .semibold, design: .serif)
        static let inspectorTitle = Font.system(size: 20, weight: .semibold, design: .serif)
        static let section = Font.system(size: 11, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let caption = Font.system(size: 11)
        static let micro = Font.system(size: 10)

        static func mono(_ size: CGFloat = 10, weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    enum Metrics {
        static let sidebarWidth: CGFloat = 220
        static let inspectorWidth: CGFloat = 340
        static let headerHeight: CGFloat = 76
        static let libraryHeaderMinimumWidth: CGFloat = 680
        static var cardCorner: CGFloat { current.cardCorner }
        static var controlCorner: CGFloat { max(3, current.cardCorner - 1) }
        static var panelCorner: CGFloat { current.cardCorner + 2 }
    }
}

enum MainWindowMetrics {
    static let sidebarWidth = AppTheme.Metrics.sidebarWidth
    static let inspectorWidth = AppTheme.Metrics.inspectorWidth
    static let libraryHeaderHeight = AppTheme.Metrics.headerHeight
    static let libraryHeaderMinimumWidth = AppTheme.Metrics.libraryHeaderMinimumWidth
    static let minimumWindowWidth =
        sidebarWidth + inspectorWidth + libraryHeaderMinimumWidth + 2
}

struct ThemeHairline: View {
    var color: Color = AppTheme.Palette.hairline

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

struct ThemeVerticalHairline: View {
    var color: Color = AppTheme.Palette.hairline

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

struct ThemeSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppTheme.Typography.section)
                .tracking(0.6)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension ThemeSectionHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

struct ThemeStatusDot: View {
    var color: Color = AppTheme.Palette.applied
    var size: CGFloat = 5

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

struct AccentActionButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        AccentActionBody(configuration: configuration, compact: compact)
    }

    private struct AccentActionBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        let compact: Bool

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.canvas)
                .padding(.horizontal, compact ? 9 : 12)
                .padding(.vertical, compact ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                        .fill(configuration.isPressed ? AppTheme.Palette.accentDeep : AppTheme.Palette.accent)
                )
                .opacity(isEnabled ? 1 : 0.36)
                .contentShape(Rectangle())
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    var compact = false
    var tone: Color = AppTheme.Palette.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, compact: compact, tone: tone)
    }

    private struct QuietButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        let compact: Bool
        let tone: Color

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(configuration.isPressed ? AppTheme.Palette.text : tone)
                .padding(.horizontal, compact ? 9 : 11)
                .padding(.vertical, compact ? 4 : 5)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                        .fill(configuration.isPressed ? AppTheme.Palette.raised : AppTheme.Palette.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                        .stroke(AppTheme.Palette.hairline, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.36)
                .contentShape(Rectangle())
        }
    }
}

struct ThemeIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? AppTheme.Palette.text : AppTheme.Palette.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? AppTheme.Palette.raised : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

struct ThemeGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(AppTheme.Typography.section)
                .tracking(0.6)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            configuration.content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                .fill(AppTheme.Palette.raised.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                .stroke(AppTheme.Palette.hairline, lineWidth: 1)
        )
    }
}

struct ThemeSearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 150
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.text)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 26)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                .fill(AppTheme.Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                .stroke(isFocused ? AppTheme.Palette.accent : AppTheme.Palette.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .accessibilityLabel(placeholder)
    }
}

struct ThemeViewModeSwitch: View {
    @Binding var layout: LibraryLayout

    var body: some View {
        HStack(spacing: 2) {
            segment(.grid)
            segment(.list)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                .fill(AppTheme.Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                .stroke(AppTheme.Palette.hairline, lineWidth: 1)
        )
    }

    private func segment(_ mode: LibraryLayout) -> some View {
        Button {
            layout = mode
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(layout == mode ? AppTheme.Palette.accent : AppTheme.Palette.textSecondary)
                .frame(width: 28, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(layout == mode ? AppTheme.Palette.accentWash : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .grid ? "网格视图" : "列表视图")
        .accessibilityLabel(mode == .grid ? "网格视图" : "列表视图")
        .accessibilityAddTraits(layout == mode ? .isSelected : [])
    }
}

struct ThemeMenuLabel: View {
    let title: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
            if let title {
                Text(title)
                    .font(AppTheme.Typography.caption)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.textTertiary)
        }
        .foregroundStyle(AppTheme.Palette.textSecondary)
    }
}

extension View {
    func themeCardBorder(
        isSelected: Bool = false,
        isHovering: Bool = false,
        cornerRadius: CGFloat = AppTheme.Metrics.cardCorner,
        lineWidth: CGFloat = 1
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    isSelected
                        ? AppTheme.Palette.accent
                        : (isHovering ? AppTheme.Palette.hairlineStrong : AppTheme.Palette.hairline),
                    lineWidth: isSelected ? max(1.5, lineWidth) : lineWidth
                )
        )
    }

    func themeInsetSurface(
        cornerRadius: CGFloat = AppTheme.Metrics.cardCorner,
        fill: Color = AppTheme.Palette.raised.opacity(0.45)
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppTheme.Palette.hairline, lineWidth: 1)
        )
    }
}
