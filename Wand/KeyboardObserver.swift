import Combine
import SwiftUI
import UIKit

/// 手动跟踪键盘高度，驱动聊天输入栏抬升。
///
/// ChatView 原本把输入栏放在 safeAreaInset(edge: .bottom) 里、依赖系统自动键盘避让，
/// 但「NavigationView push 页面 + safeAreaInset + 多行 TextField」组合下系统避让
/// 不可靠（输入栏不抬升或只抬一半，被键盘盖住）。这里直接监听
/// keyboardWillChangeFrame / keyboardWillHide，把键盘与窗口的重叠高度换算成
/// 输入栏所需的额外底部 padding；配合 .ignoresSafeArea(.keyboard) 关掉系统避让，
/// 行为在 iOS 15+ 上完全确定，不再依赖系统启发式。
final class KeyboardObserver: ObservableObject {
    /// 输入栏需要额外抬升的高度 = 键盘遮挡高度 − 底部安全区（home 指示条）。
    /// 键盘收起 / 外接键盘时为 0。
    @Published private(set) var lift: CGFloat = 0

    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.update(with: note)
        })
        tokens.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.apply(0, note: note)
        })
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func update(with note: Notification) {
        guard
            let endValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
            let window = Self.activeWindow()
        else { return }
        // 键盘 frame 在屏幕坐标系；转换到窗口坐标后取与窗口的重叠高度，
        // 兼容 iPad 分屏 / Stage Manager 窗口不满屏、以及收起时 frame 移出屏幕的情况。
        let frame = window.convert(endValue.cgRectValue, from: window.screen.coordinateSpace)
        let intersection = window.bounds.intersection(frame)
        let overlap = intersection.isNull ? 0 : intersection.height
        apply(max(0, overlap - window.safeAreaInsets.bottom), note: note)
    }

    private func apply(_ newLift: CGFloat, note: Notification) {
        guard abs(newLift - lift) > 0.5 else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        withAnimation(.easeOut(duration: max(duration, 0.2))) {
            lift = newLift
        }
    }

    private static func activeWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first
    }
}
