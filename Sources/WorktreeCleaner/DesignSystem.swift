import SwiftUI

/// 严格遵循 macOS HIG + Tahoe Liquid Glass 范式的统一组件体系：
/// - 90% 克制灰阶 + 10% 语义点亮（单视图仅 1 处主强调色）
/// - 同心圆角法则（R_outer = R_inner + padding）
/// - 深浅色自适应微光内描边（Inner Specular Rim）
/// - 桌面精准控件尺度（28pt 图标/胶囊按钮，13pt 正文，tabular-nums）

// MARK: - 1. 圆形 Liquid Glass 图标按钮

struct GlassCircleButton: View {
    let systemName: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 12
    var helpText: String? = nil
    var isSpinning: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isSpinning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundStyle(isHovered ? .primary : .secondary)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(CircleGlassSurface(colorScheme: colorScheme))
        .onHover { isHovered = $0 }
        .help(helpText ?? "")
    }
}

private struct CircleGlassSurface: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                        lineWidth: 0.5
                    )
                )
        }
    }
}

// MARK: - 2. 桌面级胶囊 Liquid Glass 按钮（高度 28pt，支持窗口失焦褪色）

struct GlassPillButton: View {
    let title: String
    var systemName: String? = nil
    var isProminent: Bool = false
    var tint: Color? = nil
    var isLoading: Bool = false
    let action: () -> Void

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme

    private var isWindowActive: Bool {
        activeState != .inactive
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 11.5, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(foregroundColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(CapsuleGlassSurface(
            isProminent: isProminent,
            tint: tint,
            isWindowActive: isWindowActive,
            colorScheme: colorScheme
        ))
    }

    private var foregroundColor: Color {
        if isProminent {
            return isWindowActive ? .white : .secondary
        }
        return .primary.opacity(isWindowActive ? 0.88 : 0.55)
    }
}

private struct CapsuleGlassSurface: ViewModifier {
    let isProminent: Bool
    let tint: Color?
    let isWindowActive: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isProminent && isWindowActive {
                content.glassEffect(.regular.tint(tint ?? .accentColor).interactive(), in: .capsule)
            } else {
                content.glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            if isProminent && isWindowActive {
                content.background(tint ?? Color.accentColor, in: Capsule())
            } else {
                content
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                            lineWidth: 0.5
                        )
                    )
            }
        }
    }
}

// MARK: - 3. 带下拉箭头的 Liquid Glass 胶囊菜单按钮

struct GlassMenuPill<MenuContent: View>: View {
    let systemName: String
    var label: String? = nil
    var helpText: String = ""
    @ViewBuilder let menuContent: () -> MenuContent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .regular))
                if let label {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary.opacity(0.84))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(CapsuleGlassSurface(isProminent: false, tint: nil, isWindowActive: true, colorScheme: colorScheme))
        .help(helpText)
    }
}

// MARK: - 4. Liquid Glass 组合容器

struct AdaptiveGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - 5. 现代分组卡片（深浅模式自适应 + 0.5pt 微光内描边）

struct InsetGroupCard<Content: View>: View {
    var cornerRadius: CGFloat = 10
    var padding: CGFloat = 0
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
            )
    }
}

// MARK: - 6. 菜单栏悬浮卡片（同心圆角 12pt + 深浅模式微光边缘）

struct FloatingCard<Content: View>: View {
    var cornerRadius: CGFloat = 12
    var padding: CGFloat = 12
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color(white: 0.16).opacity(0.76)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.82)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.045), radius: 6, y: 2)
    }
}

// MARK: - 7. 竖线刻度进度条

struct SegmentedTickBar: View {
    let ratio: Double
    let color: Color
    var segments: Int = 34
    var height: CGFloat = 8

    var body: some View {
        let clamped = min(max(ratio, 0), 1)
        let activeCount = Int(round(clamped * Double(segments)))

        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                Capsule()
                    .fill(index < activeCount ? color : Color.primary.opacity(0.10))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
    }
}

// MARK: - 8. 多段比例胶囊条

struct MultiSegmentBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        let active = segments.filter { $0.value > 0 }
        let total = max(active.map(\.value).reduce(0, +), 0.0001)
        GeometryReader { geo in
            let gaps = CGFloat(max(0, active.count - 1)) * 2
            let avail = max(0, geo.size.width - gaps)
            HStack(spacing: 2) {
                ForEach(active) { seg in
                    Capsule()
                        .fill(seg.color)
                        .frame(width: max(4, avail * (seg.value / total)), height: height)
                }
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}
