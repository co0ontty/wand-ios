import SwiftUI

/// 原生玻璃背景与透明头像是兄弟图层。头像可以自然伸出胶囊，不套上层边框或蒙版。
/// 3D 场景按至少48pt真实渲染，只缩小布局占位，不缩放或裁剪角色。
struct TopCapsuleTitle: View {
    let title: String
    var subtitle: String? = nil
    let avatarID: String
    var avatarName: String = ""
    var avatarValue: String = ""
    var avatarSize: CGFloat = 30
    var titleColor: Color = Theme.textPrimary
    var subtitleColor: Color = Theme.textSecondary
    var titleSize: CGFloat = 15
    var subtitleSize: CGFloat = 11
    var titleWidth: CGFloat? = nil
    var subtitleTruncation: Text.TruncationMode = .tail
    /// 头像活动效果：思考落定、查看文件、编写文件（与 Web `fileActivity` / `thinking` 同口径）。
    var activity: AvatarFileActivity = .idle
    var thinking = false
    var speaking = false

    /// Shared scene viewport; the header never clips this viewport to the smaller layout slot.
    private static let sceneMinimumSize: CGFloat = 48

    /// 系统导航栏按「压缩提议」量标题视图：只报内容宽度时 UIKit 会把胶囊缩到文字宽度再居中，
    /// 窄屏（Duo 最小屏）左侧就空出一大段。报一个超过任何标题槽的理想宽度，UIKit 会把标题
    /// 视图钳到槽宽，胶囊因此占满整条槽；文字仍从左侧开始排，长标题在槽内缩放、截断。
    private static let titleSlotIdealWidth: CGFloat = 2400

    private var renderedAvatarSize: CGFloat { max(Self.sceneMinimumSize, avatarSize) }
    private var avatarOverhang: CGFloat { max(0, renderedAvatarSize - avatarSize) / 2 }

    private var capsuleInset: CGFloat { 6 }

    var body: some View {
        HStack(spacing: 0) {
            avatarPortrait
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.wand(size: titleSize, weight: .semibold))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .truncationMode(.tail)
                    .frame(maxWidth: titleWidth, alignment: .leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.wand(size: subtitleSize, weight: .medium))
                        .foregroundColor(subtitleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(subtitleTruncation)
                        .frame(maxWidth: titleWidth, alignment: .leading)
                }
            }
            .padding(.leading, 8 + avatarOverhang)
            .padding(.trailing, 14)
        }
        .padding(.leading, capsuleInset).padding(.vertical, capsuleInset)
        // 先占满父布局提供的净宽，再绘制玻璃；短标题也保持同一颗完整胶囊。
        .frame(minWidth: 0, idealWidth: Self.titleSlotIdealWidth, maxWidth: .infinity, alignment: .leading)
        .background {
            Color.clear.wandGlassCapsule().allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
    }

    private var avatarPortrait: some View {
        avatarContent.frame(width: avatarSize, height: avatarSize)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    private var avatarContent: some View {
        Group {
            if PlushAvatarIdentity.asset(id: avatarID, name: avatarName, avatar: avatarValue) != nil {
                WorkingAvatar(id: avatarID, name: avatarName, avatar: avatarValue,
                    activity: activity, thinking: thinking, speaking: speaking, size: renderedAvatarSize)
            } else {
                ContactAvatar(id: avatarID, avatar: avatarValue, size: renderedAvatarSize, name: avatarName, floating: true)
            }
        }
    }
}
