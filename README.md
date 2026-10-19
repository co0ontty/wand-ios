# iOS 客户端

Wand 的 iOS **原生 SwiftUI 客户端**：会话列表、聊天、输入、权限审批全部原生实现，
直连 wand 服务端的 REST + WebSocket 协议；PTY 使用 UIKit/SwiftTerm 原生终端，不再挂载 WKWebView。
原生化避免整页 WebView 在移动端的键盘重叠、状态栏错位等问题。

## 与当前 Android 对齐的原生入口

- 默认首页为 IM；底部四入口为「聊天 / 通讯录 / 工作区 / 任务」，显式旧首页偏好保留。iPad 使用原生列表—详情分栏。
- `ConversationModels.swift` / `ConversationAPI.swift` / `ConversationStore.swift` / `ConversationViews.swift` 接入 `/api/conversations`：稳定员工私聊、独立群实例、成员邀请、任务/轮次目标、逐消息独立会话预览、置顶/解散/恢复/删除与请求核对。通讯录名字进入对话，不再自动创建旧式执行会话或直接开工。
- 草稿、附件和提交恢复继续归 `ComposerDraftState` / `SessionDraftStore`；执行协议归 `ChatStore`。IM 与执行页通过引用计数共享协议 owner，未知请求只按 request ID 读取回执，不自动重发。请求 ledger 只存哈希与 ID，不存提交正文或凭据。
- `SessionFiles.swift` 提供服务器目录、文件预览、文本编辑、下载/分享；保存使用 mtime + size CAS，冲突或未知回执保留草稿并阻止盲写。空白且未绑定任务、未锁定的结构化会话可以更换运行目录。
- `SessionCapabilities.swift` 区分 Pi CLI 与 Wand Agent（SDK）；创建、切换、员工候选、工作区与任务派发使用真实 provider + engine。`PiResources.swift` 按服务端实际能力配置 Skills / MCP、锁定、自动资源与 CodeMode；`ModelGroups.swift` 在管理认证后按原配置 CAS 保存分组，不把付费模型放进免费池。
- `TeamDispatch.swift` 先建议、再人工确认项目和名单开工，未知启动不重复执行。工作区顺序支持原生拖放、键盘/无障碍可用的上移/下移与保存重试。
- `NativeTerminal.swift` 使用固定 SwiftTerm 1.18.0、与 Android 同源 JetBrains Mono/ANSI 调色板；回放 Render checkpoint 的有序数据/resize，消费后 ACK，重连不重发输入。原生 IME、选择/复制/粘贴、50%–200%四分之一档缩放；远端 OSC52 不能读写剪贴板。
- `SessionActivityViews.swift` 与 WidgetKit 共用布局；灵动岛区分运行/后台收尾/等待输入/权限/失败/停止/完成与过期状态，多会话可精确链接，计时取服务端本轮锚点。完成停留12秒、失败30秒，标题/详情标记 privacySensitive，状态载荷有4KB预算保护。**信息密度约定**：展开态状态胶囊已说明「待授权/等你回复/已完成」，详情行不再复述，只显示真实在做的事；待授权时优先显示 escalation 的 scope+target（要授权什么）；计时器有界（`59:59` 后转 `1h02`、超 99 小时为 `99h+`），不会长到挤掉状态；已完成但仍在保留期的兄弟会话不再单独占一行。
- `ChatActivityTimeline.swift` 独立持有只读工具/思考时间线：稳定身份、真实时间排序、空思考轮过滤、唯一运行标记、按需调用详情、上翻不抢阅读位置；自动展开网络偏好位于设置。主界面灰白蓝 token 对齐当前 Android，终端保留两端共同的暖深色。

验证：`WandTests/CurrentAndroidParityTests.swift` 覆盖协议、竞态和原生渲染。安装服务只读验收必须显式提供私密测试输入，常规 CI 不访问用户服务；凭据不进入构建参数、环境变量值、仓库或附件。未签名 IPA与无连接真机是当前验收边界，不能因此宣称已完成签名真机验收或所有平台实现完全相同。

支持付费 Apple Developer 的 Ad Hoc 签名与自建服务器更新，同时保留免费 Apple ID 侧载用途。付费签名与一次配置说明见 [ADHOC.md](ADHOC.md)。

## 新建对话与员工消息

- 通讯录的「发消息」进入该员工的稳定私聊；输入区可临时选择工具（区分 Pi CLI 与 Wand Agent）、模型与思考深度，也可恢复员工默认。选择只影响本页后续新消息，不修改员工定义；已有运行的续聊、群聊与团队派发不套用该覆盖。
- 全局、工作区与目录的新建入口打开同一待发送对话页。默认不归属任务；可显式新建任务或绑定已有任务。看板「新建任务」使用同一页并预选新建任务；新任务可显式选择隔离 worktree（默认共用工作区）。新建或绑定任务的会话沿用服务端确认的真实工作目录。
- 打开页面、选择本地附件、取消或返回均不创建服务器资源。首次提交才依次创建所需任务与空会话，上传附件并把冻结草稿交给现有输入 owner 首发一次；PTY / Shell 可显式打开空终端。
- 已接受的任务或会话 ID 用于续接；读取或上传失败不重新创建。创建或上传送达未知时保留防重状态，不能靠关闭重开或修改模型自动重试。明确未接受的失败才允许修正重试。
- 工作区任务直接展示选中的聊天或终端，不再先经过工作窗口目录；多窗口任务通过「切换工作窗口」选择，一次返回回到原列表。

## 约定

- 工程代码放在 `ios/Wand/`
- `.app` / `.ipa` 构建产物**不要提交到仓库**（已在 `.gitignore`）
- 与 Android/macOS 客户端共享连接协议：连接码（base64 `url#token`）→ `/api/login` 拿 cookie；
  原生界面用 endpoint-scoped cookie 调 `/api/*` 与 `/ws`，终端直连同一服务器，不注入网页凭据。

## 客户端更新

`AppUpdateController` 在连接成功、回到前台和前台每5分钟请求公开接口 `GET /api/ios-ipa-update?currentVersion=`，发现同应用身份的可安装签名包后显示更新横幅，设置页共用同一状态并保留手动检查。点击「安装更新」直接跳转服务端 `/ios/install` 安装页，由浏览器发起 `itms-services` 交接（iOS 26+ 从 App 内直接交接会等待本 App 退出而卡住）；仅无合法安装页时回退 App 内交接。**需要用户确认，不会静默装包**；后台不承诺持续轮询或实时推送。

- 已配置本机 Ad Hoc 时正常 `IPA_DIST_DIR="$HOME/.wand/ios" ./build.sh` 自动归档、签名、校验、发布并切换服务器选择器。升级须保持同团队/Bundle ID；首次改用新身份请用 Safari 的 `/ios/install` 安装，不要先删旧App。
- 未签名包只能被检查到；系统安装会失败，仍可用 SideStore / AltStore / Sideloadly。
- 网页版关于页的「安装」走同一套 OTA 协议。

---

## 错误反馈与任务评论

- 更新检查/安装器打开失败、API 5xx 与关键 WebSocket 错误通过当前连接的 `POST /api/feedback/client` 尽力上报，沿用端点认证；仅 HTTPS 或精确 loopback HTTP，禁止反馈请求重定向。远端明文 HTTP 不发送诊断。
- 保留原始错误消息与 NSError domain/code、失败原因及底层错误摘要，过滤 token/cookie 等凭据，不采集请求/响应正文、聊天或环境。只有错误自身携带的真实堆栈才上传；普通 NSError 无原始栈时省略，绝不用当前线程栈冒充。姓名由服务端读取个人名称，不从设备获取。
- 上报独立于业务，无重试/重放，绝对 5 秒截止，最多 2 个并发、每分钟 10 条、相同错误 5 分钟去重；取消不报。iOS 系统托管安装没有结果回调，只能确认安装器是否打开，不能据此判断安装成功/失败。
- 任务详情在有内容时原位只读展示最近评论；旧服务端评论接口 404 视为空，切换任务后的迟到响应不能覆盖当前任务。

无需设备安装/启动的定点单测：`bash scripts/test-feedback.sh`。

模拟器 XCTest 统一用 `./scripts/run-tests.sh [测试过滤]`，不要各处手拼 `xcodebuild`：

```bash
./scripts/run-tests.sh                                   # 全部 WandTests
./scripts/run-tests.sh WandTests/FocusComposerTests       # 单个测试类
./scripts/run-tests.sh FocusComposerTests/testExpandedEditorUsesFullWidthForEmptySingleAndMultilineDrafts
BUILD_ONLY=1 ./scripts/run-tests.sh                      # 只编译测试 target，不需要模拟器
SIMULATOR_ID=<udid> ./scripts/run-tests.sh               # 指定模拟器
DERIVED_DATA=/path ./scripts/run-tests.sh                # 自定义派生数据
```

脚本固定传 `-parallel-testing-enabled NO`：`Wand.xcscheme` 的 `parallelizable` 已是 `NO`，但命令行参数能重新打开并行，那样 xcodebuild 会克隆多个模拟器把整机 CPU/IO 打满（曾实测克隆 5 个、约 1086 个模拟器子进程、load average 877）。脚本先 `build-for-testing` 再 `test-without-building`，编译失败立即退出、不复用旧产物；模拟器设备集不可用时编译仍会完成并明确报错，不会假装测试通过。

Release 构建遵循上方本机 Ad Hoc 签名配置；未配置签名时产物未签名，不代表可 OTA 安装。

## 免费安装方案调研（不需要付费 Apple 账号）

iOS 不像 Android 能直接装 APK，必须借道 Apple 的「开发者签名」机制。下面三条路线**都不需要 $99/年 的付费账号**，按推荐度排序：

> 当前工程的 deployment target 是 **iOS 26.0**，构建使用 **Xcode 26+**。旧系统即使具备其它侧载方式，也无法运行当前产物。

### 方案 A：AltStore / SideStore（推荐，免费 Apple ID 自签名）

这就是你说的「通过 UUID 自签名的方案」。原理：工具用你的**免费 Apple ID** 登录 Apple 开发者门户，按你设备的 **UDID** 生成一个临时描述文件（provisioning profile），把 IPA 重新签上你的个人开发证书再装进手机。

| 工具 | 是否需要电脑 | 自动刷新 | 说明 |
|------|------------|---------|------|
| **SideStore** | 仅首次安装需要 | ✅ 设备上后台刷新 | AltStore 的分支，不需要常驻的 AltServer。装好后用内置 VPN(StosVPN) + on-device minimuxer 在本机完成刷新，**脱离电脑也能续签**。iOS 26 推荐它。 |
| **AltStore (Classic)** | 需要同局域网常开一台跑 AltServer 的电脑 | ✅ 但要电脑在线 | 临过期时由 AltServer 经 Wi-Fi/USB 自动续签。 |
| **Sideloadly** | 每次都要插电脑 | ❌ 手动 | Windows/macOS 桌面工具，拖 IPA + 登 Apple ID + Start。无自动续签，过期得重装。 |

**免费 Apple ID 的硬限制（Apple 定的，所有工具都一样）：**
- **证书 7 天过期** → 到期前必须刷新，否则 App 打不开（这就是「7 天签名」）
- **同时最多 3 个自签 App**（含 sideload 工具本身）；配合 SideStore 的 **LiveContainer** 可绕过 3 个上限
- 每周最多注册 10 个 App ID
- 用免费 Apple ID 做个人开发签名**不会封号**；介意的话可以单独注册一个小号 Apple ID

**用本仓库产物走这条路：**
1. 在 Mac 上 `./build.sh <version>` → 得到 `dist/wand-v<version>.ipa`（未签名）
2. 把 IPA 传到手机/电脑，用 SideStore（或 AltStore/Sideloadly）打开并安装
3. 安装时登录你的免费 Apple ID，工具自动签名
4. 首次打开后，到 **设置 → 通用 → VPN与设备管理** 里**信任**你这个开发者描述文件

### 方案 B：TrollStore（历史参考，当前产物不可用）

这就是你说的「安装证书的方案」一类里最省心的——它利用系统签名校验的一个缺陷做到**永久签名、不用 7 天续期、不占 3 App 名额、不用电脑续签**。装一次就一直能用。

**代价：只支持部分旧系统，而 Wand 当前最低要求 iOS 26。** 因此本仓库当前构建不能使用这条路线；本节只保留历史背景，不再作为安装建议。

TrollStore 的安装入口取决于具体旧系统版本，需按其官方指引操作。它只适用于 deployment target 与对应旧系统兼容的历史构建，**不适用于本仓库当前 `build.sh` 产物**。

### 方案 C（不推荐）：第三方「企业证书」签名站

网上有些站点用**企业证书（Enterprise Certificate）** 帮你签名安装（不用电脑、不用 7 天续）。但这类证书是别人盗用/共享的，Apple 一旦吊销，所有用它签的 App 当场全部失效，且证书可能被植入风险。**不建议**，这里只为完整性提及。

---

## 决策速查

```
iPhone 是 iOS 26+？
├─ 是 → 用 SideStore / AltStore 安装并续签
└─ 否 → 当前 Wand iOS 产物无法运行
```

## 端到端操作手册（iOS 26+，云端编译 + Mac 装机）

**第一步：拿到 IPA**（见下文「云端构建」——Actions 手动跑一次，下载 artifact 解压出 `wand-v*.ipa`）

**第二步：装机。两条路按需选一：**

### 路线 1：AltStore（步骤最少；要求 Mac 经常开机在同一 Wi-Fi）

1. Mac 上从 [altstore.io](https://altstore.io) 下载 **AltServer**，拖进「应用程序」并打开（它住在菜单栏，没有窗口）
2. iPhone 用 USB 线连 Mac，解锁并「信任此电脑」
3. 菜单栏 AltServer 图标 → **Install AltStore** → 选你的 iPhone → 输入 Apple ID（介意可注册个小号）
4. iPhone：**设置 → 通用 → VPN与设备管理** → 信任你 Apple ID 对应的开发者 App
5. iPhone：**设置 → 隐私与安全性 → 开发者模式** 打开并重启（iOS 16+ 必须）
6. 装 wand：把 IPA AirDrop 到 iPhone，用 **AltStore → My Apps → ＋** 选中安装；或在 Mac 上按住 **Option 点 AltServer 菜单图标 → Sideload .ipa**
7. 续期：只要 iPhone 和跑着 AltServer 的 Mac 在同一 Wi-Fi，AltStore 会在 7 天到期前自动后台刷新

### 路线 2：SideStore（首次配置多几步；之后完全脱离电脑自动续签）

1. 先按路线 1 的第 1、2、5 步装好 AltServer、连好手机、开好开发者模式
2. 从 [docs.sidestore.io](https://docs.sidestore.io) 下载 **SideStore.ipa**，Mac 上 **Option 点 AltServer 菜单图标 → Sideload .ipa** 装进手机，并在「VPN与设备管理」里信任
3. 用 [iDevice Pair](https://docs.sidestore.io/docs/advanced/pairing-file) 生成**配对文件**（`.mobiledevicepairing`）导入 SideStore（USB 连接状态下生成）
4. iPhone 装 **StosVPN**（App Store 免费），按 SideStore 提示启用
5. SideStore 里登录 Apple ID，然后用 SideStore 打开/导入 wand IPA 安装
6. 之后续签全在手机上后台自动完成，不再需要电脑；iOS 系统升级后配对文件会失效，重做第 3 步即可

> 两条路线装好后，免费 Apple ID 的「3 个自签 App」名额都包含 AltStore/SideStore 本身 + wand，共占 2 个，还剩 1 个富余。

---

## 云端构建（无需 Mac，推荐）

没有 Mac 也能出 IPA：用 GitHub Actions 的免费 `macos-latest` runner 在线编译。

工作流：`.github/workflows/ios-build.yml`

1. GitHub 仓库 → **Actions** → 左侧选 **iOS IPA Build** → **Run workflow**（可填版本号，默认 `0.0.0-dev`）
2. 等几分钟跑完，进入这次 run 的页面，最下方 **Artifacts** 里下载 `wand-ios-ipa-<版本>`
3. 解压得到 `wand-v<版本>.ipa`（GitHub artifact 是个 zip，里面才是 IPA）

> 用**手动触发（Run workflow）**出包即可，不要为了编译去打 tag——打 `v*` tag 会同时触发 npm/Android/macOS 的正式发布。tag push 时本工作流也会把 IPA 顺带传到对应 Release。

## 本地构建（仅 macOS）

```bash
./build.sh 1.16.0
# 产物：build/Wand.app + dist/wand-v1.16.0.ipa（未签名）
```

要求：

- 能够运行 Xcode 26 的 macOS 版本
- 安装了 Xcode 26+（命令行工具 `xcodebuild` 足够）
- **不需要 Apple Developer 账号**（产物未签名，签名在安装时完成）

构建产物是**未签名 IPA**，直接交给 AltStore/SideStore/Sideloadly 安装即可。

## 工程结构

```
ios/
├── README.md                  # 本文件
├── build.sh                   # 构建未签名 IPA
├── scripts/
│   └── generate-icons.swift   # 生成 1024 单尺寸 App 图标
└── Wand/
    ├── App.swift              # @main 入口（WindowGroup）
    ├── ContentView.swift      # 容器：已连接→NativeRootView / 未连接→ConnectView
    ├── ConnectView.swift      # 连接界面（连接码 / 地址 + 最近连接）
    ├── NativeRootView.swift   # 原生根视图：token 登录引导 + 列表导航
    ├── SessionListView.swift  # 会话列表（/api/sessions 轮询 + 下拉刷新 + 滑动删除）
    ├── ChatView.swift         # 聊天视图：消息块渲染 + 原生输入栏+ 权限审批卡片
    ├── ChatStore.swift        # 单会话状态机：WS 订阅、增量合流、发送/停止/权限决策
    ├── NewSessionView.swift   # 新建会话（Claude/Codex/OpenCode / 最近路径 / 类型与模式）
    ├── WandAPI.swift          # REST 客户端（401 自动用 appToken 重登重试）
    ├── WandSocket.swift       # /ws 客户端：seq 间隙 resync、心跳看门狗、退避重连
    ├── WandModels.swift       # 协议 Codable 模型（SessionSnapshot / ConversationTurn / WS 消息）
    ├── NativeTerminal.swift   # UIKit/SwiftTerm PTY 回放、ACK、原生输入与选择
    ├── ServerStore.swift      # UserDefaults 持久化连接状态
    ├── WandAuth.swift         # 连接码解码 / token 登录 / 可达性探测（与 macOS 共享逻辑）
    ├── SelfSignedSession.swift# 放行 wand 自签名 HTTPS 的 URLSession（REST/WS 共用）
    ├── Theme.swift            # Android 同源灰白蓝主题 + 原生复用样式
    ├── Info.plist             # ATS 放行任意加载 + 本地网络权限说明
    └── Assets.xcassets/       # AppIcon / AccentColor
```

## 原生客户端协议对接（速查）

- 登录：`POST /api/login` `{appToken}` → session cookie（ephemeral 存储，冷启动后由
  `NativeRootView` 重新登录一次；REST 401 时 `WandAPI` 也会自动重登重试）
- 会话列表：`GET /api/sessions`（slim，无 messages）；详情 `GET /api/sessions/:id?format=chat`
- 新建会话：结构化会话 `POST /api/structured-sessions`，终端会话 `POST /api/commands`；
  两者均显式传 `provider: claude|codex|opencode|grok|qoder`
- 模型目录：只读 `GET /api/models`，消费服务端持久化的最新目录；CLI 探测和目录刷新
  仅由服务端自动任务或管理员操作触发。
- 发消息：`POST /api/sessions/:id/input` —— 结构化会话发原文；PTY 原生输入先发文本，再发 `"\r"`，并带 `shortcutKey:"enter_text"`
- 停止回复：结构化 `POST /api/sessions/:id/stop`；PTY 发 Esc（`` + `shortcutKey:"esc"`）
- 权限：`pendingEscalation` → `POST /api/sessions/:id/escalations/:requestId/resolve`
  `{resolution: approve_once|approve_turn|deny}`；PTY 旧式提示走 `approve-permission`/`deny-permission`
- WebSocket：`/ws` + cookie，发 `{type:"subscribe",sessionId}` 收 `init` 全量快照；
  `output` 增量按浏览器端同款规则合流（全量 `messages` 优先，`incremental+lastMessage` 末条同 role 替换）；
  `seq` 出现间隙或收到 `resync_required` 时发 `{type:"resync"}` 要全量
- 聊天视图对 PTY 会话同样可用：服务端 `ClaudePtyBridge` 已把 PTY 输出解析成结构化消息推送

## 设计要点

- **自签名 HTTPS 放行**：wand 默认用 `cert.ts` 生成自签名证书，REST/WS 复用 `SelfSignedSession` 的 endpoint cookie/自签名证书处理，等价 Android 的自签 HTTPS 支持。
- **ATS**：`NSAllowsArbitraryLoads = true`，因为要连局域网 HTTP 地址和自签名 HTTPS。
- **本地网络权限**：`NSLocalNetworkUsageDescription`；应用完成启动后主动用无数据 UDP connect 触发一次授权检查，局域网连接失败时提供 App 设置入口。
- **切换服务器入口**：iOS 没有菜单栏，连接后在右上角放一个低调的半透明悬浮按钮，点击弹出切换面板（macOS 是用菜单 + 通知，二者共用 `.wandRequestSwitchServer` 通知）。
- **bundle id**：`com.wand.app`，与 macOS 端一致。免费签名时工具可能会改写它，不影响使用。
- **entitlements**：刻意**不带**特殊 entitlements（推送 / App Groups 等），保持最干净，最大化兼容免费账号签名——带了反而可能签名失败。

## 模拟器验收

Debug 构建可显式设置 `SIMCTL_CHILD_WAND_DEBUG_ACCEPTANCE_PROFILE=1`，从应用私有
`Documents/.wand-acceptance-profile.json` 读取一个 `ServerProfile`（`baseUrl`、`token`）。
文件最多16 KiB，读取后通过正常 `ServerStore.saveProfile` 登录状态入口保存并删除临时文件；
Release 不包含这个入口。凭据不放进启动参数、环境变量、日志或截图。
可同时设置既有 `SIMCTL_CHILD_WAND_DEBUG_OPEN_SESSION=<验收会话ID>` 打开真实服务的会话。
验收后恢复原有服务器偏好；不要用 mock 服务代替最终验收。

## 注意

- 客户端更新检查：`GET /api/ios-ipa-update`；安装经 `/ios/install` 页面发起 `itms-services` + `/ios/manifest.plist`。不要在 App 内自己解包安装 IPA。
- 不要随意更换 bundle id 或签名身份的预期：用同一工具、同一 Apple ID 续签才能平滑升级；换了就要先删旧 App 再装。
