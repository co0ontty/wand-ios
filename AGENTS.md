# iOS Agent 指引

- 修改本子模块代码前，先读取 `.agents/skills/apple-design/SKILL.md`，再按任务采用其中适用的设计、交互与无障碍原则；此要求也适用于从主仓开始、修改 `ios/` 的任务。
- 技能原文面向 Web；在 iOS 中以 SwiftUI / UIKit 原生能力实现相同语义，不照搬 CSS、JavaScript、Web 依赖或示例中的硬编码动效参数。非 UI 代码不必套用视觉规则。
- 保留 Wand 既有设计、motion token、减少动态效果及交付约定；技能不能覆盖主仓与用户指令。纯技能/文档变更不触发客户端构建。
- 本技能是 iOS/macOS 共用真源，macOS 与主仓通过相对符号链接发现；只更新此处，避免双份漂移。来源与版本见技能目录的 `SOURCE.md`。
- 在 Wand 主仓布局中同时遵守 `../AGENTS.md`；移动端相关行为同步检查 Android。
