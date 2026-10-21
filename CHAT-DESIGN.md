# iOS 聊天

本轮基准为 Android 的 `CHAT-DESIGN.md` 与根 `DESIGN.md`。SwiftUI 的 Theme、NativeComposerShell、ChatView/ChatStore 仍是本端所有者，不新建发送锁或恢复链。

用户最新反馈覆盖旧顶栏方案：动态伙伴悬浮在输入框上方，不显示顶栏大头像或单独头像卡片。已只读截取安装服务的实际Web输入区，核对72px头像、top=-60px、left=0、pointer-events:none，状态/文本右侧84px避让。iOS FloatingComposerCompanion同样72/60/84关系，处于底部布局栈，预留真实空间，跟随KeyboardObserver和安全区，不覆盖最后消息或吞触摸。历史28pt静态头像；作者/时间同一行；实色输入表面、48pt操作命中区；状态与最近轮用量在头像右侧。安全区、UIKit IME、多行输入、Dynamic Type、VoiceOver、阅读滚动和恢复沿用原实现。

输入状态：编辑/有草稿/附件/IME组字保持完整；原发送入口确认接收且没有期间新草稿后才失焦并进入紧凑补充/继续输入表面。等待键盘收起后换紧凑表面；流式更新不决定布局。补充与停止原动作可达；补充立即恢复完整输入。失败/未知送达取消收起状态，不清空或隐藏草稿。VoiceCall继续复用原发送锁。

头像只消费 Web 当前 renderer 与固定身份编码，离线打包、有源文件 hash，无远程脚本或网络权限。前台/可见才运行动效，reduced-motion 静态，失败展示同形 PNG。读写只由本轮真实 activity.kind 与未完成 tool ID 驱动，错误/审批/取消归待机，书本和笔来自共同 3D 几何。


可审阅预览由 Debug 专用本地示例界面生成，使用真实共享头像和输入组件，无网络/AI/凭据操作；最终功能验收另以已安装服务的只读会话核对。只构建本地模拟器与未签名 Beta 包，不部署。


## 输入区域整体设计（覆盖此前正文84pt缩进）

仅伙伴状态行保留84pt避让；展开编辑正文、附件与错误说明恢复满宽。伙伴仍72pt悬浮在输入边缘，完整编辑表面顶端14pt避让其重叠，不让角色覆盖文字。输入自然增长至180pt，长稿（240字、6行或达到高度边界）提供「展开编辑长消息」，用相同draft binding和UIKit IME编辑，不另复制草稿；完成/下滑关闭保留全部内容，不发送。回车换行，显式发送和原硬件快捷键提交；展开编辑期间聊天发送快捷键禁用。

主操作行只保留附件、上下文、需要时的长稿展开与原发送/停止。模型、思考、执行模式、目录与提示词优化在原生上下文选择面板逐步展开，复用原控制器与限制。目录固定时提示新建会话。编辑、草稿、附件、失败及unknown保持完整输入，只有原确认回执后空稿非编辑才紧凑。流式状态不决定是否展开。

ChatDesignPreview为可操作DEBUG离线原生夹具，包含空态、键盘、12段多行长稿、展开编辑、附件添加/取消、确认后执行紧凑、unknown错误保稿；按钮和真实UIKit编辑器可操作。演示回执、附件与执行均为夹具，不调用真实AI或上传。

用户最新决定：移动端输入区状态行不重复显示员工名字，只展示状态。聊天标题/员工选择继续承载身份，状态行保留员工身份的VoiceOver标签；不改iOS系统状态栏。

聊天页最新简化：正常聊天隐藏占整行的导航表面，沿用NavigationStack的返回栈；左侧48pt悬浮返回，另由 `SessionBackSwipeEnabler` 补一条左边缘右滑返回（隐藏导航栏时系统 interactivePopGestureRecognizer 不会启动，只改它的 delegate 无效，故用导航视图上的普通 pan 自判 48pt 边缘起点、与内部滚动同时识别、松手 ≥72pt 才 pop，嵌套导航栈只让最内层响应）；返回带跟手动画：当前页与上一页各渲染成快照图层，当前页 1:1 右移并带投影、上一页按 `backSwipeParallaxRatio` 视差跟进由暗转亮，松手按已拖比例判定（`sessionSwipeShouldCommit`，过半返回、不到一半 spring 回弹、快速右甩例外）并从当前位置补完位移再无动画 pop，`reduceMotion` 下不做位移；不能改 SwiftUI 托管页面的 frame/transform（下次布局会抹掉），右侧文件/更多（36pt圆形视觉）。更多保留当前员工与目录辨认、原模型/模式/目录入口、Pi资源和Git；换员工回原会话选择，不改历史目标。消息视口顶部56pt避让，首条和滚动文字均不被图标遮住；按钮实色Theme.surface保证浅深色可读。顶端不忽略刘海安全区，键盘/底部安全区维持原owner。嵌入任务页时整屏仍只有一条栏：会话可见就由会话独占这条栏（`showsNavigationChrome=true`），宿主任务页用`taskPresentsSession`隐藏自己的系统导航栏，并把任务动作（新建工作窗口、打开聊天、并行任务、任务管理、刷新、复制目录）经`hostActions`并进会话「更多」菜单的「任务」分区，不因单层化丢入口；未呈现会话、快照未到位或切到别的任务时任务栏照旧保留。系统返回手势、VoiceOver与手动阅读仍须实机/可操作系统验收，锁屏宿主未人工操作。

辅助无障碍大字号时上下文入口只呈图标，完整accessibilityLabel保留，48pt触控不缩，避免文字挤掉发送/停止。最终完整XCTest357通过、2跳过、0失败；真实深色accessibility-large像素已核对，操作行完整可见。

紧凑垂直尺寸下输入高度预算降为132pt，键盘出现时64pt，保持操作行可达；达到当前预算即显示长稿展开入口，完整草稿不截断。

身份编码说明：初二的plush-cat:v1:orange及plush_cat_orange资源名是兼容编码；当前真实造型为brown-tabby-white棕黑虎斑、白嘴、长毛，不能按orange字面恢复橘色。交付参考图也使用当前造型。

## 最新独立猫头与对侧胶囊（2026-10-11，覆盖以上旧布局）

已读取并实际查看最新两张批准设计图：Library b294062e2ad88191bc9d46be2e9e16a1 与 abf232ebf6348191bc571aa0101f12f8。猫头独立无圆面，96pt真实共享3D场景；对侧胶囊保留键盘动作。只有非空文字才出现第三项发送箭头，运行时替换为实心停止；运行但空稿不出现第三项，从顶部更多停止任务。附件而无文字时展开区明确提供“发送附件”，不让附件改变胶囊第三项规则。

同一手势处理短按编辑与水平拖动；释放水平拖动左右吸附，用本机AppStorage/UserDefaults跨会话与重启持久保存，胶囊内部顺序不镜像。键盘关闭可保留草稿微提示，失败/unknown粘性展开；ACK仅清本次提交。

底部始终预留152pt角色/状态行，无障碍字号182pt；读写、思考不改变消息视口高度。读写道具沿用Web最终真实3D书页与笔纸接触契约，位于下巴下；头顶思考沿用Web八瓣漫画orbit锚点。仅当前未完成thinking末块显示思考，流式文本与读写关闭orbit。背景暂停与reduced-motion沿用共享场景契约。

当前无合法签名身份或app/widget描述文件；本轮授权产物为明确标识的unsigned iPhoneOS包，不能称作可直接安装包，不申请证书或注册设备。最终验证与新版本证据见output/architecture-stage2/ios-cat-composer/PROGRESS.md；旧正文测试计数与旧预览不代表本轮最终证据。

失败粘性依据归原ComposerDraftState.submissionFailed，不随短暂sendPhase反馈定时消失；下一次显式发送开始/成功后清除，unknown仍由原unconfirmedInput保护。胶囊错误全文不重复弹浮卡，展开编辑区保留完整反馈；发送项保持箭头与实际发送忙碌，旧ACK不投影成新草稿的按钮状态。

### 最终验证（2026-10-11）

当前独立猫头方案最终XCTest全量369项、2既有跳过、0失败；包括原生SwiftUI固定视口与失败反馈到期后保稿检查。真实原生离线录像与八项审阅材料已记录于output/architecture-stage2/ios-cat-composer/DELIVERY.md。主线程临时让窗排查Mac Wand启动，未启动最终unsigned Release，未写安装目录；服务稳定后恢复。真实麦克风、人工VoiceOver/触控和实机中断仍未验收，签名条件缺失不可宣称直接安装。

最终包完成：4.89.3-debug.10111130，Release arm64，unsigned；更新接口与实际下载字节/SHA一致，unsigned-ipa阻塞保留。上述临时打包暂停已解除并完成。交付与全部Library ID见DELIVERY.md；无设备安装或签名变更。

### 运行态只留顶部一处（2026-10-19）

输入框上方原有一份状态小字（处理中/发送中…/等待确认），与顶部身份区文案同义重复，且占掉一条本可给消息的垂直空间。现删掉输入区状态行：发送态由原提交按钮的发送中/停止形态承担，确认与连接异常由权限卡与连接横幅承担（会话顶栏自 2026-10-19 起不再显示状态文案，见下节）；运行态的细粒度进度由待办进度条与子 Agent 状态坞承载。顶部头像与状态文案曾共用同一份读/写 activity 判定，避免两处各算一次。会话状态文案真源为 `identityWorkStatus`，判定与 Android 一致性由 `CurrentAndroidParityTests` 覆盖。

### 会话顶栏改成身份栏：任务名 + 员工·目录（2026-10-19）

会话顶栏原先是「头像 + 员工名 + 一句状态」，读起来像「赛博虎妞 正在处理」：主位被员工名占走，而这条栏真正要回答的是「我在做哪件事」；状态那句又和权限卡、连接横幅、待办进度条重复。现按 Mac/Web 已有的形态收敛（Mac `SessionHeaderView` 与 Web 顶栏都不放头像，标题即会话/任务名，目录只显示末级名）：

- 主标题 = 任务名（宿主任务页注入的 `hostTitle`），独立会话没有归属任务时回落会话标题 `store.displayTitle`；`currentTaskTitle` 仍不参与顶栏，遵守「响应期间不能替换标题」的既有约束。
- 小字 = 「员工名 · 目录缩写」，目录只取末级路径名（`abbreviatedDirectory`），根目录或空路径不显示，缺项自动省掉分隔符。
- 头像取消：`ChatView` 不再画 `TopChatCompanion`/`WorkingAvatar`，随之删掉顶部伙伴的左右拖动与点按聚焦入口（`catSideRaw`/`catDragOffset`/`catGesture`），点输入区聚焦的原有路径不变。IM 私聊仍以头像为身份，继续用 `TopChatCompanion`。
- 运行与异常只以一个 6pt 状态点呈现（品牌色=运行、permission=等待确认、danger=异常，静止表示空闲），复用 `topicTitleRhythm` 呼吸而不是自起定时器；文案不进视觉，但 `chatTopReadback` 仍把「标题，小字，状态」完整交给读屏，`chat-visible-identity` 标识保留。
- 高度改为两行文字的 `identityClearance`（56pt 起，随 Dynamic Type 增长），不再为头像占 114pt，消息视口相应变长。
- 水平位置不再按屏幕居中：`ChatTopLayout.identityBand` 用返回键（60pt）与文件/更多两枚按钮（112pt）算出可用带子，身份区在带子里居中，长标题的省略号不会压到右侧按钮；Android 侧同一份几何是 `FloatingControlsBackInset`/`FloatingControlsActionsInset`。
- 结构化会话与终端会话（`PtySessionView.titleStatus`）走同一个 `chatTopIdentity`，两条链路都不再画头像；终端顶栏原来的完整路径 `WandPathRevealText` 换成同一条「员工名 · 目录缩写」。

判定与归属由 `CurrentAndroidParityTests`（`chatTopIdentity`/`ChatTopAttention`/源码单一归属）与 `ChatComposerCatTests`（`testSessionIdentityBarKeepsStableHeightAndFullReadback` 高度不随标题长度变化、盖住控件触控安全区；`testIdentityBandStaysBetweenTopControls` 带子左右边界）覆盖。模拟器实机验收：已安装服务 + 真实任务会话，顶栏为「状态点 + 任务名 / 赛博虎妞 · wand」单层，读屏标签为 `iOS对话界面多项布局与交互优化，赛博虎妞 · wand`，身份区右边界 278pt、`会话文件` 按钮左边界 308pt 不重叠；IM 私聊仍为头像版。

### 工具时间线用窄轨道 + 行内时钟（2026-10-19）

时间线每行原先用固定 64pt 时钟列，再排圆点和正文，正文从约 86pt 起，长参数摘要被压得很窄；而 iOS 只读 `activity.occurredAt`，块级 `occurredAt` 被丢弃，历史条目没有 activity 时整列空白，左侧空得更明显。现按 Android `ToolActivitySummary.kt` 的几何对齐：圆点占 12pt 轨道槽、轨道竖线走槽中心，正文从轨道右侧 8pt 起（相对轨道中心 14pt，与 Android 的 `ACTIVITY_RAIL_X`/`ACTIVITY_CONTENT_START` 等距），展开详情同基准；时钟只在有真实发生时间时以 `caption2` 等宽内联在圆点之后，无时间的条目不预留列。折叠头同样以圆点对齐轨道，顺序为「圆点 → 时钟 → 摘要」，与每行一致。数据侧 `ContentBlock` 解码补上 `activity.occurredAt ?: 块级 occurredAt` 回落，不伪造时间；回归见 `ComposerToolParityTests`。

### 任务模式单层顶栏与队列计数单一归属（2026-10-19）

任务模式进入会话时，宿主任务页原先无条件保留系统导航栏，会话又画自己那条悬浮栏，整屏出现两条栏（「Web 性能优化 / wand」+「正在执行」）。Android 侧会话是独立路由，只有一条栏，iOS 现按同一语义收敛：会话独占那条栏，任务页在 `taskPresentsSession` 为真时隐藏自己的系统栏，任务级动作改由 `SessionHostAction` 注入会话「更多」菜单的「任务」分区；加载态、无会话态或切到别的任务时任务栏不变。底部「查看执行进度」行也不再重复 `待发 N`，排队条数只由输入框上方的 `QueueBar`「待发送 N 条」呈现，与 Android `ChatScreen` 的单一归属一致；回归见 `CurrentAndroidParityTests.testQueuedCountHasSingleOwnerAboveComposer`。

### 图片自适应放大与全屏查看器翻页（2026-10-19）

聊天内联图片原先固定 240×200 上限，横图和竖图都只用到框的一角，实际显示偏小；全屏查看器只接单个 `path`，一条消息里多张图必须关掉再开下一张。现按 Android `WandImage` 同步为共享常量 `WandImageLayout.thumbnailMaxWidth/Height = 320/360`：图片在框内按比例完整显示，横图吃满宽度、竖图吃满高度、小图不放大，缩略图各调用点不再各写像素值。`WandImageThumbnail` 与 `WandToolImageThumbnail` 增加 `group`/`groupIndex`，全屏查看器改为 `sources` + `startIndex`（越界钳制到首张，见 `wandImageViewerStart`），同一条消息或同一张卡片里的图片一起传入，多张时右下角显示 `n / N`。查看器为自绘的按需翻页容器：未放大时横向拖动翻页（超过 28% 宽或同向甩动），纵向拖动 >90pt 下滑关闭，双指或双击缩放至 1–5×，放大后横向手势改判为平移并停翻页，边缘仍有 0.35 阻尼；轴在 10pt 处锁定，避免斜向拖动同时翻页和位移。相邻页只在手指拖向该方向时加载，`accessibilityHidden` 出树，当前页报「图片 n，共 N 张」，VoiceOver 可用转子左右滑翻页。几何与分组回归见 `CurrentAndroidParityTests.testToolImageLoadingAlwaysHasVisibleGeometry`、`testInlineImagesPageWithinTheirGroup`；真机（模拟器）已核对缩略图 AX 帧为 320×120 / 320×360、`1 / 3 → 3 / 3` 钳制、下滑关闭与右上角关闭。捏合缩放依赖真实多点触控，模拟器合成手势未覆盖。

### 全屏图片按需左右切换（2026-10-21）

从任意附件/工具图片进入全屏时，按当前已加载对话的消息顺序建立轻量地址索引，跨消息与工具返回切图，不再局限同一次返回。文件路径和工具直链分别保留各自认证加载模式；不额外拉取历史或一次性下载整组图片。图片静止时只挂载当前页，拖向上一张/下一张时才加载那张图片，取消滑动即卸载邻页。打开期间索引快照固定，迟到消息/历史插入不能挤错当前页。缩放后单指拖动用于平移，恢复1倍后翻页；保留页码、首尾边界、下拉关闭、关闭按钮与VoiceOver翻页。复用WandMotion和减动效规则；翻页时当前页及邻页使用同一跟手位移。

### 工具图片预览占比（2026-10-21）

工具返回/Read 的图片继续直出，不恢复工具调用外壳；图片按自身比例完整显示，宽不超过当前可用区域的 80%、高不超过聊天阅读视口的 40%，同时受 320×360pt 硬上限约束。细边框与原有文件名区分截图和真实应用页面；点击仍进入原有分组全屏查看器。高度复用聊天容器的 `chatViewportHeight`，键盘/横屏改变阅读区时重新布局；未注入视口的独立展示退回 360pt 高上限。上传附件缩略图与待发送预览保持原规则，不扩大本轮影响面。Android 同语义实现。

### 空任务直接内嵌空白对话（2026-10-20）

任务详情在没有任何会话时，原先显示一套独立的欢迎页（项目 caption、terminal 图标、任务名、执行对象/CLI 工具列表），与「新建对话」并列成第二个创建入口。用户要求清空这个页面：新建任务只有默认空白聊天一个入口，另加员工对话派发。现 `WorkspaceTaskView.emptyTask` 直接承载 `NewConversationView(embedded: true, boundTask:)`：

- 内嵌模式不套 `NavigationStack`、不画取消/完成工具栏，也不显示「所属任务」选择区；任务页仍是唯一一条导航栏，正文就是输入框和可选的员工/模型/引擎配置。输入、员工候选、草稿继承与未知送达核对全部复用 `NewConversationView` / `NewConversationCoordinator`，没有另写一套创建状态机。
- `NewConversationBoundTask` 用进入任务时的 id/workspaceId/name/cwd 锁定归属；`pendingConversationTaskAvailable` 在任务列表未加载、分页未包含该任务时仍视为可用，避免误建未分组会话。配置加载时若快照缺该任务，只补一条用于归属校验的任务摘要，创建仍使用进入任务时的真实 cwd/workspace。
- 归档会话浏览/恢复只在工作区列表，不在空白聊天或已有对话上方放入口；发送成功后刷新任务并直接打开新会话。`WorkspaceTargetPicker` 的 embedded 分支随之删除。

回归见 `WorkspaceTests.testEmptyTaskHostsTheBoundPendingConversation` 与 `testBoundTaskStaysSelectableBeforeTaskListLoads`。

### 对话顶部不叠宿主附加条

用户明确要求取消对话最上方的归档条，今后也不在这个位置添加内容。`WorkspaceTaskView` 不再在空白聊天或已有会话上方渲染归档会话栏；归档浏览与恢复留在工作区列表。会话呈现后，顶部完全交给 `SessionDestinationView` 的既有导航/身份控件，宿主不叠归档、切换、任务摘要或状态条；布局警告仅在尚未呈现会话时显示。此约束不删除归档历史，不改变归档行为。

回归：`WorkspaceTests.testTaskHostDoesNotAddArchivedSessionChromeAboveConversation`。

### 派发取消不转发草稿

「取消」与「取消派发」先由会话草稿所有者原子丢弃未发送正文、附件及待发送意图，使迟到上传失效，再退出派发模式；不能保留同一负载并降级为可发送的普通消息。取消不调用发送/创建会话。已明确提交或送达未知时禁用取消并保留核对入口，不能将其伪装成未发送。附件菜单、目录设置及键盘的普通收起仍只改变展示，不等同取消派发。只有明确「确认派发任务」可提交任务；关闭面板不能触发派发。Android 同语义。

回归：`CurrentAndroidParityTests` 的取消/迟到上传/明确确认/未知送达用例；真实按钮触控用 `scripts/test-dispatch-cancellation.py`（spy 隔离真实执行）。
