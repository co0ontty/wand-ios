import Foundation

/// 应用内轻量级环形日志缓冲。
///
/// 把会话加载、WebSocket、API 错误等关键事件存进**内存环**，供「导出最近 N 分钟日志」
/// 排查偶发问题（典型：会话打开后空白）。刻意不写文件、不走 NSLog/os_log——
/// 既消除 Console 噪声，也不占磁盘；只在用户导出时拼成文本。
///
/// 线程安全：所有读写都在一个串行队列上，可从任意线程调用。
final class WandLog {
    static let shared = WandLog()

    struct Entry {
        let time: Date
        let category: String
        let message: String
    }

    /// 环形容量上限。一条约几十字节，2000 条在内存里可忽略；超出后丢最旧的。
    /// 5 分钟内的事件量远小于此，容量只是「App 长期前台」的兜底护栏。
    private let maxEntries = 2000
    private let queue = DispatchQueue(label: "com.wand.app.log")
    private var entries: [Entry] = []

    private init() {}

    /// 追加一条日志（异步入队，不阻塞调用方）。
    func log(_ category: String, _ message: String) {
        let entry = Entry(time: Date(), category: category, message: message)
        queue.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    /// 最近 `minutes` 分钟内的日志条数（用于「窗口内是否有内容」判断）。
    func recentCount(within minutes: Int = 5) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return queue.sync { entries.filter { $0.time >= cutoff }.count }
    }

    /// 导出最近 `minutes` 分钟的日志为纯文本（时间正序，便于阅读）。
    func export(within minutes: Int = 5) -> String {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        let snapshot: [Entry] = queue.sync { entries }
        let recent = snapshot.filter { $0.time >= cutoff }

        let stamp = Self.lineFormatter
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let buildStamp = Bundle.main.object(forInfoDictionaryKey: "WandBuildStamp") as? String

        var lines: [String] = []
        lines.append("Wand iOS 日志导出")
        let displayVersion = buildStamp.flatMap { $0.isEmpty ? nil : "\(appVersion)+\($0)" } ?? appVersion
        lines.append("App 版本: v\(displayVersion) (\(build))")
        lines.append("系统: iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("导出时间: \(Self.headerFormatter.string(from: Date()))")
        lines.append("时间窗口: 最近 \(minutes) 分钟，共 \(recent.count) 条")
        lines.append(String(repeating: "—", count: 32))
        if recent.isEmpty {
            lines.append("（窗口内没有日志。打开会话、收发消息后再导出可捕获更多上下文。）")
        } else {
            for e in recent {
                lines.append("\(stamp.string(from: e.time)) [\(e.category)] \(e.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 把导出文本写入临时 .txt 文件，返回可分享的 URL（失败返回 nil）。
    func exportToFile(within minutes: Int = 5) -> URL? {
        let text = export(within: minutes)
        let name = "Wand-日志-\(Self.fileFormatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// 打点便捷入口：`wlog("session", "…")`。
func wlog(_ category: String, _ message: String) {
    WandLog.shared.log(category, message)
}
