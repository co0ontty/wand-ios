import Darwin
import Foundation
import UIKit

/// iOS 没有公开 API 可直接读取或请求「本地网络」权限。按 Apple TN3179 的建议，
/// 启动后对局域网地址执行一次无数据 UDP connect：未决定时系统会弹授权框，已经
/// 允许或拒绝时不会重复弹框。连接失败后可引导用户到 App 设置手动打开权限。
enum LocalNetworkPermission {
    private static var triggered = false

    static func triggerPromptIfNeeded() {
        guard !triggered else { return }
        triggered = true

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        _ = "192.168.0.1".withCString {
            inet_pton(AF_INET, $0, &addr.sin_addr)
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(fd)
    }

    static func isLikelyLanHost(_ host: String?) -> Bool {
        guard let raw = host?.lowercased(), !raw.isEmpty else { return false }
        if raw == "localhost" || raw == "127.0.0.1" || raw == "::1" { return false }
        if raw.hasSuffix(".local") { return true }
        if raw.hasPrefix("10.") || raw.hasPrefix("192.168.")
            || raw.hasPrefix("169.254.") || raw.hasPrefix("fe80:") { return true }
        if raw.hasPrefix("172.") {
            let parts = raw.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
