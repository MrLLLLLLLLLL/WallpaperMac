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

enum AppTheme {
    enum Palette {
        static let canvas = Color(hex: 0x0F1011)
        static let sidebar = Color(hex: 0x131416)
        static let panel = Color(hex: 0x17181A)
        static let raised = Color(hex: 0x1E2023)
        static let hairline = Color(hex: 0x2B2D30)
        static let hairlineStrong = Color(hex: 0x3A3C3F)
        static let text = Color(hex: 0xEDE9E2)
        static let textSecondary = Color(hex: 0x9C9992)
        static let textTertiary = Color(hex: 0x6E6B65)
        static let brass = Color(hex: 0xC8A468)
        static let brassDeep = Color(hex: 0x8C7247)
        static let brassWash = Color(hex: 0xC8A468, opacity: 0.12)
        static let applied = Color(hex: 0x8FAE7A)
        static let warning = Color(hex: 0xD1A25A)
        static let danger = Color(hex: 0xC97F76)
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
        static let cardCorner: CGFloat = 6
        static let controlCorner: CGFloat = 6
        static let panelCorner: CGFloat = 8
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

struct BrassActionButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        BrassActionBody(configuration: configuration, compact: compact)
    }

    private struct BrassActionBody: View {
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
                        .fill(configuration.isPressed ? AppTheme.Palette.brassDeep : AppTheme.Palette.brass)
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
                .stroke(isFocused ? AppTheme.Palette.brass : AppTheme.Palette.hairline, lineWidth: 1)
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
                .foregroundStyle(layout == mode ? AppTheme.Palette.brass : AppTheme.Palette.textSecondary)
                .frame(width: 28, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(layout == mode ? AppTheme.Palette.brassWash : Color.clear)
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
                        ? AppTheme.Palette.brass
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
