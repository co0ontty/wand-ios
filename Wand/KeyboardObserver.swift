import Combine
import SwiftUI
import UIKit

/// 手动跟踪键盘高度，驱动聊天输入栏抬升。
///
/// ChatView 原本把输入栏放在 safeAreaInset(edge: .bottom) 里、依赖系统自动键盘避让，
/// 但「NavigationView push 页面 + safeAreaInset + 多行 TextField」组合下系统避让
/// 不可靠（输入栏不抬升或只抬一半，被键盘盖住）。这里直接监听
/// keyboardWillChangeFrame / keyboardWillHide，把贴底键盘与窗口的重叠高度换算成
/// 输入栏所需的额外底部 padding；配合 .ignoresSafeArea(.keyboard) 关掉系统避让，
/// 行为在 iOS 15+ 上完全确定，不再依赖系统启发式。
final class KeyboardObserver: ObservableObject {
    /// 输入栏需要额外抬升的高度。safeAreaInset 已消费底部安全区，因此这里只
    /// 使用键盘在安全区上方的高度；浮动键盘不推动整条输入栏。
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
        // 键盘 frame 在屏幕坐标系；转换到窗口坐标后只处理贴住窗口底边的键盘。
        // 浮动键盘若按普通交集计算，会把整条输入栏异常推到页面上方。
        let frame = window.convert(endValue.cgRectValue, from: window.screen.coordinateSpace)
        let touchesBottom = frame.maxY >= window.bounds.maxY - 1
        let overlap = touchesBottom ? max(0, window.bounds.maxY - frame.minY) : 0
        let lift = max(0, overlap - window.safeAreaInsets.bottom)
        apply(lift, note: note)
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
