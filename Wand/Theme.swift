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

    // 品牌色（明暗下统一，便于辨识）
    static let brand = Color(red: 0.851, green: 0.467, blue: 0.341)        // #D97757
    static let brandStrong = Color(red: 0.741, green: 0.376, blue: 0.255)  // #BD6041
    /// Codex（OpenAI）标识蓝，与 Android 端 info 色对一致。
    static let codex = dynamic(light: rgb(0.290, 0.435, 0.647), dark: rgb(0.494, 0.612, 0.769)) // #4A6FA5 / #7E9CC4

    // 表面 / 文本（自适应）
    static let background = dynamic(light: rgb(0.980, 0.976, 0.961), dark: rgb(0.137, 0.137, 0.129)) // #FAF9F5 / #232321
    static let surface = dynamic(light: rgb(1, 1, 1), dark: rgb(0.184, 0.184, 0.173))                 // #FFFFFF / #2F2F2C
    static let border = dynamic(light: rgb(0.894, 0.886, 0.851), dark: rgb(0.290, 0.290, 0.271))      // #E4E2D9 / #4A4A45
    static let textPrimary = dynamic(light: rgb(0.137, 0.133, 0.122), dark: rgb(0.957, 0.953, 0.933)) // #232220 / #F4F3EE
    static let textSecondary = dynamic(light: rgb(0.435, 0.427, 0.400), dark: rgb(0.655, 0.647, 0.616))
    static let danger = Color(red: 0.776, green: 0.231, blue: 0.184)       // #C63B2F

    /// WKWebView overscroll 区域底色，避免加载前/回弹时露出白底。
    static var uiBackground: UIColor {
        dynamicUI(light: rgb(0.980, 0.976, 0.961), dark: rgb(0.137, 0.137, 0.129))
    }
}

extension View {
    @ViewBuilder
    func wandGlassSurface() -> some View {
        modifier(WandGlassSurfaceModifier())
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

/// 复用的品牌 logo：珊瑚渐变圆角方块 + 魔杖图标。
struct WandBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.brand, Theme.brandStrong],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: Theme.brand.opacity(0.35), radius: size * 0.18, y: size * 0.06)
            Image(systemName: "wand.and.stars")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundColor(.white)
        }
    }
}
