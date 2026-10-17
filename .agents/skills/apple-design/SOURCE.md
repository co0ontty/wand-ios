# Apple Design 来源

- 上游：https://github.com/emilkowalski/skills/blob/main/skills/apple-design/SKILL.md
- 固定版本：https://github.com/emilkowalski/skills/blob/2d228630ba1446365f614a108cb8252f1feda202/skills/apple-design/SKILL.md
- Git blob：`adf68c517f2d7d2781587d619de07f4de286da57`
- `SKILL.md` 保持上游原文；上游该技能目录仅包含此文件，没有配套脚本或资源。

## 本仓入口

- 正文：`ios/.agents/skills/apple-design/SKILL.md`。
- 主仓 `.agents/skills/apple-design` 与 `macos/.agents/skills/apple-design` 均通过相对符号链接共享此目录；必须保留同级 iOS 检出。
- 主仓、iOS、macOS 的 `AGENTS.md` 要求修改双端代码前读取，原生适配与项目约束以这些指引为准。
- Pi 支持项目 `.agents/skills` 发现及技能目录符号链接。现有 Pi 会话执行 `/reload` 刷新技能列表；也可显式输入 `/skill:apple-design <具体任务>`。
