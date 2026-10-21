import SwiftUI

/// 顶栏胶囊标题：左侧是圆圈里的头像（允许略微探出胶囊边缘），右侧是当前标题与副标题。
///
/// 头像优先用 3D 场景（WorkingAvatar），但场景最小渲染尺寸是 48pt，
/// 小尺寸改用同一角色的静态立绘，保证小胶囊里既清晰又不裁切。
struct TopCapsuleTitle: View {
    let title: String
    var subtitle: String? = nil
    let avatarID: String
    var avatarName: String = ""
    var avatarValue: String = ""
    var avatarSize: CGFloat = 30
    var fill: Color = Theme.surfaceSoft
    var stroke: Color = Theme.border
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

    /// 3D 场景的最小渲染边长，小于此值时静态立绘更稳。
    private static let sceneMinimumSize: CGFloat = 48

    /// 胶囊高度：头像直径 + 四周等宽的边距（头像圆心与胶囊左端圆弧同心）。
    private var capsuleHeight: CGFloat { avatarSize + 2 * capsuleInset }
    /// 头像圆与胶囊边框之间四周等宽的留白。
    private var capsuleInset: CGFloat { 6 }

    var body: some View {
        HStack(spacing: 0) {
            // 圆心落在胶囊左端圆弧的圆心上，圆弧与圆圈同形、留白等宽。
            Color.clear.frame(width: capsuleHeight / 2 - avatarSize / 2)
            avatarCircle
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.wand(size: titleSize, weight: .semibold))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: titleWidth, alignment: .leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.wand(size: subtitleSize, weight: .medium))
                        .foregroundColor(subtitleColor)
                        .lineLimit(1)
                        .truncationMode(subtitleTruncation)
                        .frame(maxWidth: titleWidth, alignment: .leading)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
        }
        .frame(height: capsuleHeight)
        .background {
            Capsule(style: .continuous).fill(fill)
        }
        .overlay {
            Capsule(style: .continuous).stroke(stroke, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var avatarCircle: some View {
        ZStack {
            // 透明头像贴在胶囊上时需要一层落地阴影：否则角色像浮在胶囊上，没有重量。
            // 阴影只落在胶囊底色上，不给角色本体加轮廓描边。
            groundingShadow
            avatarContent
        }
        .frame(width: avatarSize, height: avatarSize)
        .accessibilityHidden(true)
    }

    /// 落地阴影：角色脚下一小片柔光椭圆，随头像尺寸等比缩放。
    private var groundingShadow: some View {
        Ellipse()
            .fill(Theme.textPrimary.opacity(0.18))
            .frame(width: avatarSize * 0.66, height: avatarSize * 0.16)
            .blur(radius: avatarSize * 0.09)
            .offset(y: avatarSize * 0.38)
            .accessibilityHidden(true)
    }

    private var avatarContent: some View {
        Group {
            if let asset = PlushAvatarIdentity.asset(id: avatarID, name: avatarName, avatar: avatarValue) {
                // 3D 场景最小渲染 48pt，小胶囊里按最小尺寸渲染再缩放，不裁切角色。
                if avatarSize < Self.sceneMinimumSize {
                    ZStack {
                        WorkingAvatar(id: avatarID, name: avatarName, avatar: avatarValue,
                            activity: activity, thinking: thinking, speaking: speaking,
                            size: Self.sceneMinimumSize)
                            .scaleEffect(avatarSize / Self.sceneMinimumSize)
                    }
                    .frame(width: avatarSize, height: avatarSize)
                } else {
                    WorkingAvatar(id: avatarID, name: avatarName, avatar: avatarValue,
                        activity: activity, thinking: thinking, speaking: speaking,
                        size: avatarSize)
                }
            } else {
                ContactAvatar(id: avatarID, avatar: avatarValue, size: avatarSize, name: avatarName)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
    }
}
