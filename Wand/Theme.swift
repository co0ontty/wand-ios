import SwiftUI
import UIKit

private struct TopicTitleRhythmModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active && !reduceMotion ? (phase ? 1 : 0.64) : 1)
            .offset(y: active && !reduceMotion && phase ? -1 : 0)
            .animation(
                active && !reduceMotion
                    ? .easeInOut(duration: 1.15).repeatForever(autoreverses: true)
                    : nil,
                value: phase
            )
            .onAppear { phase = active && !reduceMotion }
            .onChange(of: active) { _, next in phase = next && !reduceMotion }
            .onChange(of: reduceMotion) { _, reduced in phase = active && !reduced }
    }
}

extension View {
    func topicTitleRhythm(_ active: Bool) -> some View {
        modifier(TopicTitleRhythmModifier(active: active))
    }
}

enum WandAppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    static let storageKey = "wand.appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "明亮"
        case .dark: return "黑暗"
        case .system: return "跟随系统"
        }
    }

    var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return .unspecified
        }
    }

    static func resolved(from rawValue: String) -> WandAppearanceMode {
        WandAppearanceMode(rawValue: rawValue) ?? .system
    }
}

/// Claude 品牌配色与复用样式。颜色随系统明暗自适应。对称 macOS 的 Theme.swift，
/// 把 NSColor 换成 UIColor、外观判断换成 UITraitCollection。
/// 品牌主色取 Anthropic Claude 的珊瑚橙（#D97757），背景用暖米白（#FAF9F5）。
enum Theme {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// 按当前外观（light / dark）返回 light/dark 两套之一。
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: dynamicUI(light: light, dark: dark))
    }

    private static func dynamicUI(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }

    // 品牌色（与 Android / macOS / Web 共用同一组暖珊瑚 token）
    static let brand = dynamic(light: rgb(0.773, 0.396, 0.239), dark: rgb(0.831, 0.459, 0.314)) // #C5653D / #D47550
    static let brandStrong = dynamic(light: rgb(0.627, 0.306, 0.180), dark: rgb(0.725, 0.392, 0.263))
    /// Codex（OpenAI）标识蓝，与 Android 端 info 色对一致。
    static let codex = dynamic(light: rgb(0.290, 0.435, 0.647), dark: rgb(0.494, 0.612, 0.769)) // #4A6FA5 / #7E9CC4

    // 表面 / 文本（自适应）
    static let background = dynamic(light: rgb(0.961, 0.953, 0.933), dark: rgb(0.075, 0.067, 0.059)) // #F5F3EE / #13110F
    static let surface = dynamic(light: rgb(1.000, 0.992, 0.976), dark: rgb(0.129, 0.118, 0.102))    // #FFFDF9 / #211E1A
    static let border = dynamic(light: rgb(0.851, 0.824, 0.788), dark: rgb(0.239, 0.216, 0.188))     // #D9D2C9 / #3D3730
    static let textPrimary = dynamic(light: rgb(0.157, 0.137, 0.122), dark: rgb(0.953, 0.933, 0.906)) // #28231F / #F3EEE7
    static let textSecondary = dynamic(light: rgb(0.384, 0.353, 0.325), dark: rgb(0.780, 0.745, 0.706)) // #625A53 / #C7BEB4
    static let textMuted = dynamic(light: rgb(0.545, 0.510, 0.475), dark: rgb(0.584, 0.545, 0.506)) // #8B8279 / #958B81
    static let danger = dynamic(light: rgb(0.698, 0.310, 0.271), dark: rgb(0.878, 0.486, 0.447))

    /// WKWebView overscroll 区域底色，避免加载前/回弹时露出白底。
    static var uiBackground: UIColor {
        dynamicUI(light: rgb(0.961, 0.953, 0.933), dark: rgb(0.075, 0.067, 0.059))
    }
}

extension View {
    @ViewBuilder
    func wandGlassSurface() -> some View {
        modifier(WandGlassSurfaceModifier())
    }

    func wandGlassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(WandGlassCardModifier(cornerRadius: cornerRadius))
    }

    func wandPreferredAppearance() -> some View {
        modifier(WandPreferredAppearanceModifier())
    }

    /// 点击空白区域收起键盘。挂在滚动容器 / 背景层上：
    /// 输入框、按钮等可交互控件优先消费点击，不会被误伤；
    /// 与 scrollDismissesKeyboard 互补（滚动收起 + 点击收起）。
    func dismissKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
    }

    /// Wand 文本输入表面：静态时克制，聚焦时用品牌描边与柔和外环给即时反馈。
    /// 动画为临界阻尼弹簧；减少动态效果下直接切换，避免输入时产生不必要位移。
    func wandInputSurface(
        focused: Bool,
        invalid: Bool = false,
        cornerRadius: CGFloat = 14
    ) -> some View {
        modifier(
            WandInputSurfaceModifier(
                focused: focused,
                invalid: invalid,
                cornerRadius: cornerRadius
            )
        )
    }
}

/// 四端共用的低透明度环境色域；它提供玻璃背后的层次，但不会形成明显渐变带。
struct WandAmbientBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.background
                Circle()
                    .fill(Theme.brand.opacity(0.034))
                    .frame(width: max(proxy.size.width, proxy.size.height) * 0.84)
                    .offset(x: -proxy.size.width * 0.38, y: -proxy.size.height * 0.38)
                Circle()
                    .fill(Theme.textMuted.opacity(0.024))
                    .frame(width: max(proxy.size.width, proxy.size.height) * 0.60)
                    .offset(x: proxy.size.width * 0.48, y: -proxy.size.height * 0.04)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct WandPathWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 完整路径从根目录向末级目录揭示一次，最后停在最有辨识度的尾部。
struct WandPathRevealText: View {
    let path: String
    var fontSize: CGFloat = 10
    var color: Color = Theme.textMuted
    var initialDelay: Double = 1.8
    var staggerWindow: Double = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var revealed = false

    var body: some View {
        GeometryReader { proxy in
            let overflow = max(0, textWidth - proxy.size.width)
            Text(path.replacingOccurrences(of: "\\", with: "/"))
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { textProxy in
                        Color.clear.preference(key: WandPathWidthKey.self, value: textProxy.size.width)
                    }
                )
                .offset(x: (reduceMotion || revealed) ? -overflow : 0)
                .accessibilityLabel(path)
                .task(id: "\(path)-\(Int(proxy.size.width))-\(Int(textWidth))") {
                    revealed = reduceMotion
                    guard !reduceMotion, overflow > 0 else { return }
                    let hash = UInt64(bitPattern: Int64(path.hashValue))
                    let stagger = staggerWindow > 0 ? Double(hash % 1_000) / 1_000 * staggerWindow : 0
                    try? await Task.sleep(nanoseconds: UInt64((initialDelay + stagger) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: min(8, max(1.2, Double(overflow / 28))))) {
                        revealed = true
                    }
                }
        }
        .clipped()
        .frame(height: ceil(fontSize * 1.45))
        .onPreferenceChange(WandPathWidthKey.self) { textWidth = $0 }
    }
}

private struct WandGlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 0, style: .continuous)
        let highContrast = contrast == .increased

        if reduceTransparency || highContrast {
            content
                .background(shape.fill(Theme.surface))
                .overlay(shape.stroke(Theme.border, lineWidth: highContrast ? 1.5 : 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(Theme.brand.opacity(0.035)), in: shape)
        } else {
            content
                .background(shape.fill(Theme.surface))
                .overlay(shape.stroke(Theme.border, lineWidth: 1))
        }
    }
}

private struct WandGlassCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(shape.fill(Theme.surface))
                .overlay(shape.stroke(Theme.border, lineWidth: contrast == .increased ? 1.5 : 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(Theme.brand.opacity(0.035)), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(shape.fill(Theme.surface.opacity(0.72)))
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.75))
        }
    }
}

private struct WandInputSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let focused: Bool
    let invalid: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let highContrast = contrast == .increased
        let stroke = invalid ? Theme.danger : (focused ? Theme.brand : Theme.border)

        content
            .background {
                shape.fill(
                    reduceTransparency || highContrast
                        ? Theme.surface
                        : Theme.surface.opacity(focused ? 0.98 : 0.86)
                )
            }
            .overlay {
                shape.stroke(
                    stroke,
                    lineWidth: highContrast ? 2 : (focused || invalid ? 1.5 : 1)
                )
            }
            .shadow(
                color: focused && !highContrast ? Theme.brand.opacity(0.12) : .clear,
                radius: 10,
                y: 4
            )
    }
}

private struct WandPreferredAppearanceModifier: ViewModifier {
    @AppStorage(WandAppearanceMode.storageKey) private var appearanceModeRaw = WandAppearanceMode.system.rawValue

    func body(content: Content) -> some View {
        content
            .onAppear { applyAppearanceOverride() }
            .onChange(of: appearanceModeRaw) { _, _ in applyAppearanceOverride() }
    }

    private func applyAppearanceOverride() {
        let style = WandAppearanceMode.resolved(from: appearanceModeRaw).interfaceStyle
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}

/// 实心珊瑚色主按钮，禁用态自动变淡。跨平台 SwiftUI，与 macOS 端一致。
struct WandPrimaryButtonStyle: ButtonStyle {
    @MainActor
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 13)
                .padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isEnabled ? Theme.brand : Theme.brand.opacity(0.45))
                )
                .brightness(configuration.isPressed ? -0.06 : 0)
                .contentShape(Rectangle())
        }
    }
}

/// 描边次按钮，用于「重新连接 / 取消」等次要动作。
struct WandSecondaryButtonStyle: ButtonStyle {
    @MainActor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(Theme.textPrimary)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// 复用的品牌 logo：克制的品牌色圆角方块 + 魔杖图标。
struct WandBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.brand)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                )
                .shadow(color: Theme.brand.opacity(0.10), radius: 1, y: 1)
            Image(systemName: "wand.and.stars")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundColor(.white)
        }
    }
}
