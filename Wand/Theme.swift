import SwiftUI
import UIKit

private struct TopicTitleRhythmModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active && !reduceMotion ? (phase ? 1 : 0.64) : 1)
            .animation(
                active && !reduceMotion
                    ? WandMotion.topicPulse
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

/// Shared motion/feedback tokens; views never author per-page timings.
enum WandMotion {
    static let stateSwap = Animation.easeInOut(duration: 0.18)
    static let expansion = Animation.interactiveSpring(response: 0.32, dampingFraction: 1, blendDuration: 0)
    static let topicPulse = Animation.easeInOut(duration: 1.15).repeatForever(autoreverses: true)
    static let submittedDwell: UInt64 = 720_000_000
    static let failedDwell: UInt64 = 1_500_000_000
    static let searchDebounce: UInt64 = 240_000_000
    static var disclosure: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : stateSwap }
    static var scroll: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.22) }
    static var keyboard: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.2) }
    static var detail: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.18, extraBounce: 0) }
    static let scan = Animation.linear(duration: 2.2).repeatForever(autoreverses: false)
    static let activityPulse = Animation.smooth(duration: 1.2, extraBounce: 0).repeatForever(autoreverses: true)
    static let activityTick: TimeInterval = 0.05
    static func keyboard(duration: Double) -> Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: max(0, duration)) }
}

/// Content rhythm shared by native lists and forms; text itself follows Dynamic Type.
enum WandLayout {
    static let pageInset: CGFloat = 16
    static let fieldGap: CGFloat = 12
    static let sectionGap: CGFloat = 24
    static let controlTouch: CGFloat = 44
}

/// Persistent labels for inline editors outside a native Form. The actual inputs
/// remain system TextField/TextEditor/Picker controls, with no separate draft state.
struct WandFormField<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.hint = hint; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
            content
                .font(.body)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: WandLayout.controlTouch, alignment: .leading)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Immediate color feedback without moving or resizing the target.
struct WandQuietButtonStyle: ButtonStyle {
    var tint: Color = Theme.brandText
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: WandLayout.controlTouch, minHeight: WandLayout.controlTouch)
            .foregroundStyle(enabled ? tint : Theme.textMuted)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(configuration.isPressed ? Theme.brandSoft : Color.clear))
            .contentShape(Rectangle())
    }
}

/// Body text follows native Dynamic Type; fixed logo/terminal-grid dimensions stay explicit.
extension Font {
    static func wand(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let style: Font.TextStyle
        switch size {
        case ...11: style = .caption2
        case ...12: style = .caption
        case ...13: style = .footnote
        case ...15: style = .subheadline
        case ...17: style = .body
        case ...20: style = .title3
        case ...24: style = .title2
        case ...29: style = .title
        default: style = .largeTitle
        }
        return .system(style, design: design).weight(weight)
    }
}

enum WandFeedback {
    static let storageKey = "wand.hapticEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
#if targetEnvironment(simulator)
        return
#else
        guard isEnabled() else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
#endif
    }

    static func success() {
#if targetEnvironment(simulator)
        return
#else
        guard isEnabled() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
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

/// 品牌配色与复用样式。颜色随系统明暗自适应。
/// 与当前 Android WandColors 共用灰白蓝色板；终端独立保留暖深色。
enum Theme {
    // Approved workspace v5: semantic regions, native dark-mode equivalents.
    static let workspaceCanvas = dynamic(light: hex(0xEAEFF4), dark: hex(0x10151C))
    static let workspaceContext = dynamic(light: hex(0xDBE6F0), dark: hex(0x202E3C))
    static let workspaceReading = dynamic(light: hex(0xFFFFFF), dark: hex(0x181D24))
    static let workspaceInputDock = dynamic(light: hex(0xF0F3F7), dark: hex(0x242B34))
    static let workspaceSelection = dynamic(light: hex(0xEAF2FA), dark: hex(0x263C51))

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

    private static func hex(_ value: UInt32) -> UIColor {
        rgb(Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
    // Android LightTokens / DarkTokens are the visual baseline, including solid-container ink.
    static let brand = dynamic(light: hex(0x0076D6), dark: hex(0x63B4FF))
    static let brandText = dynamic(light: textInk(0x0076D6, dark: false), dark: textInk(0x63B4FF, dark: true))
    static let brandStrong = brandText
    static let onBrand = dynamic(light: hex(0xFFFFFF), dark: hex(0x101114))
    private static func textInk(_ value: UInt32, dark: Bool) -> UIColor {
        let color = hex(value)
        let containers = dark ? [hex(0x101114), hex(0x17181C), hex(0x1C1D21), hex(0x27282D)]
            : [hex(0xF2F3F7), hex(0xFFFFFF), hex(0xEDEEF2)]
        func channels(_ color: UIColor) -> [CGFloat] { var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; color.getRed(&r, green: &g, blue: &b, alpha: &a); return [r, g, b] }
        func luminance(_ values: [CGFloat]) -> Double {
            let v = values.map { Double($0) <= 0.04045 ? Double($0) / 12.92 : pow((Double($0) + 0.055) / 1.055, 2.4) }
            return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
        }
        let base = channels(color), backgrounds = containers.map { luminance(channels($0)) }
        for step in 0...48 {
            let t = CGFloat(step) / 48, pole: CGFloat = dark ? 1 : 0
            let candidate = base.map { $0 + (pole - $0) * t }, l = luminance(candidate)
            if backgrounds.allSatisfy({ (max(l, $0) + 0.05) / (min(l, $0) + 0.05) >= 4.5 }) { return UIColor(red: candidate[0], green: candidate[1], blue: candidate[2], alpha: 1) }
        }
        return dark ? .white : .black
    }
    /// Codex（OpenAI）标识蓝，与 Android / Web info 色对一致。
    static let codex = dynamic(light: rgb(0.290, 0.435, 0.647), dark: rgb(0.494, 0.612, 0.769)) // #4A6FA5 / #7E9CC4
    static let info = dynamic(light: hex(0x4A6FA5), dark: hex(0x8FB0DC))

    /// provider → 徽标色。与 macOS `Theme.providerColor(_:)` 同构。
    /// 认不出的 provider 落回品牌色（中性「无品牌」信号），不要伪装成某个已知 provider 的颜色。
    static func providerColor(_ provider: String?) -> Color {
        switch WandProvider.normalizedID(provider) {
        case WandProvider.codex.rawValue: return codex
        default: return brand
        }
    }

    // 表面 / 文本（自适应）
    static let background = dynamic(light: hex(0xF2F3F7), dark: hex(0x101114))
    static let elevated = dynamic(light: hex(0xFFFFFF), dark: hex(0x17181C))
    static let surface = dynamic(light: hex(0xFFFFFF), dark: hex(0x1C1D21))
    static let border = dynamic(light: hex(0xE3E5EB), dark: hex(0x34363D))
    static let textPrimary = dynamic(light: hex(0x1C1D21), dark: hex(0xF4F5F7))
    static let textSecondary = dynamic(light: hex(0x60636B), dark: hex(0xC4C7CF))
    static let textMuted = dynamic(light: hex(0x6A6D75), dark: hex(0x989BA5))
    static let textPlaceholderUI = dynamicUI(light: hex(0x6A6D75), dark: hex(0x989BA5))
    static let success = dynamic(light: rgb(0.310, 0.478, 0.345), dark: rgb(0.545, 0.729, 0.580)) // #4F7A58 / #8BBA94
    static let brandSoft = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? hex(0x63B4FF).withAlphaComponent(0.18) : hex(0x0076D6).withAlphaComponent(0.08) })
    static let successSoft = success.opacity(0.14)
    static let surfaceSoft = dynamic(light: hex(0xEDEEF2), dark: hex(0x27282D))
    static let warning = dynamic(light: rgb(0.663, 0.416, 0.184), dark: rgb(0.851, 0.631, 0.361)) // #A96A2F / #D9A15C
    static let danger = dynamic(light: hex(0xB24F45), dark: hex(0xE4887E))
    static let permission = dynamic(light: hex(0xA87317), dark: hex(0xE6B75A))
    static let thinking = dynamic(light: rgb(0.435, 0.427, 0.639), dark: rgb(0.659, 0.647, 0.831)) // #6F6DA3 / #A8A5D4
    static let teal = dynamic(light: rgb(0.227, 0.541, 0.561), dark: rgb(0.420, 0.702, 0.718)) // #3A8A8F / #6BB3B7

    /// PTY / 工具终端卡 / diff 共用的固定暖深色，不跟随亮暗主题。
    static let terminalBackground = Color(red: 0.090, green: 0.071, blue: 0.059) // #17120F
    static let terminalText = Color(uiColor: hex(0xF4EEE6))
    static let terminalError = Color(red: 0.949, green: 0.549, blue: 0.510) // #F28C82

    /// WKWebView overscroll 区域底色，避免加载前/回弹时露出白底。
    static var uiBackground: UIColor {
        dynamicUI(light: hex(0xF2F3F7), dark: hex(0x101114))
    }

    static var uiTerminalBackground: UIColor {
        rgb(0.090, 0.071, 0.059)
    }
}

func wandNoticeIsLong(_ message: String) -> Bool {
    message.contains("失败") || message.contains("错误") || message.contains("断开")
}

func wandNoticeDuration(_ message: String) -> TimeInterval {
    wandNoticeIsLong(message) ? 4.0 : 2.6
}

extension View {
    @ViewBuilder
    func wandGlassSurface() -> some View {
        modifier(WandGlassSurfaceModifier(shape: RoundedRectangle(cornerRadius: 0, style: .continuous)))
    }

    func wandGlassCapsule(tint: Color? = nil) -> some View {
        modifier(WandGlassSurfaceModifier(shape: Capsule(), tint: tint))
    }

    func wandGlassSurface<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(WandGlassSurfaceModifier(shape: shape, tint: tint))
    }

    func wandGlassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(WandGlassCardModifier(cornerRadius: cornerRadius))
    }

    /// Native controls own their thumb/track, gestures, focus and accessibility.
    /// Child selection toggles can explicitly retain .button rather than becoming switches.
    func wandNativeFormControls() -> some View {
        toggleStyle(.switch).controlSize(.regular).tint(Theme.brand)
    }

    func wandPreferredAppearance() -> some View {
        modifier(WandPreferredAppearanceModifier())
    }

    /// 给系统导航栏一块不透明表面，避免 iOS 26 液态玻璃把标题/路径洗成浅色残影。
    @ViewBuilder
    func wandToolbarSurface(enabled: Bool = true, colorScheme: ColorScheme? = nil) -> some View {
        if enabled {
            if let colorScheme {
                self
                    .toolbarBackground(
                        colorScheme == .dark ? Theme.terminalBackground : Theme.elevated,
                        for: .navigationBar
                    )
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
            } else {
                self
                    .toolbarBackground(Theme.elevated, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
        } else {
            self
        }
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
        cornerRadius: CGFloat = 14,
        fill: Color? = nil
    ) -> some View {
        modifier(
            WandInputSurfaceModifier(
                focused: focused,
                invalid: invalid,
                cornerRadius: cornerRadius,
                fill: fill
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

/// Stable path label: retain its location while showing the useful root and leaf.
/// Full content remains available to VoiceOver and explicit native copy, without a timed marquee.
struct WandPathRevealText: View {
    let path: String
    var fontSize: CGFloat = 10
    var color: Color = Theme.textMuted
    var body: some View {
        Text(path.replacingOccurrences(of: "\\", with: "/"))
            .font(.wand(size: fontSize, design: .monospaced))
            .foregroundStyle(color).lineLimit(1).truncationMode(.middle)
            .accessibilityLabel(path)
            .contextMenu { Button("复制完整路径") { UIPasteboard.general.string = path } }
    }
}

private struct WandGlassSurfaceModifier<SurfaceShape: InsettableShape>: ViewModifier {
    let shape: SurfaceShape
    var tint: Color? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let highContrast = contrast == .increased

        if reduceTransparency || highContrast {
            content
                .background(shape.fill(Theme.surface))
                .overlay(shape.stroke(Theme.border, lineWidth: highContrast ? 1.5 : 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint?.opacity(0.12) ?? Theme.brand.opacity(0.035)), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(shape.fill(Theme.surface.opacity(0.56)))
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.75))
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
        content
            .background(shape.fill(Theme.surface.opacity(reduceTransparency || contrast == .increased ? 1 : 0.92)))
            .overlay(
                shape.stroke(
                    contrast == .increased ? Theme.textMuted : Theme.border,
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
            )
    }
}

private struct WandInputSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let focused: Bool
    let invalid: Bool
    let cornerRadius: CGFloat
    let fill: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let highContrast = contrast == .increased
        let stroke = invalid ? Theme.danger : (focused ? Theme.brand : Theme.border)

        content
            .background {
                shape.fill(fill ?? (
                    reduceTransparency || highContrast
                        ? Theme.surface
                        : Theme.surface.opacity(focused ? 0.98 : 0.86)
                ))
            }
            .overlay {
                shape.stroke(
                    stroke,
                    lineWidth: highContrast ? 2 : (focused || invalid ? 1.5 : 1)
                )
            }
            .shadow(
                color: focused && !highContrast ? Theme.brand.opacity(0.05) : .clear,
                radius: 6,
                y: 2
            )
    }
}

private struct WandPreferredAppearanceModifier: ViewModifier {
    @AppStorage(WandAppearanceMode.storageKey) private var appearanceModeRaw = WandAppearanceMode.system.rawValue

    func body(content: Content) -> some View {
        content
            .wandNativeFormControls()
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

/// 品牌色主按钮，原生按压与禁用反馈；文字随 Dynamic Type 增长。
struct WandPrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            .tint(configuration.role == .destructive ? Theme.danger : Theme.brand)
            .controlSize(.large)
    }
}

/// 描边次按钮，用于「重新连接 / 取消」等次要动作。
struct WandSecondaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.glass).buttonBorderShape(.capsule)
            .tint(configuration.role == .destructive ? Theme.danger : Theme.brand)
            .controlSize(.large)
    }
}

/// 与 Android 启动图标同源的像素猫；保留原色，不随按钮 tint 改色。
struct WandBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image("WandLogo")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
