---
version: alpha
name: Wand iOS
description: 消息优先，顶部真实伙伴与随焦点展开的原生输入胶囊。
colors:
  primary: "#0076D6"
  background: "#F2F3F7"
  surface: "#FFFFFF"
  text: "#1C1D21"
  secondaryText: "#60636B"
  border: "#E3E5EB"
typography:
  sans:
    fontFamily: '-apple-system, "PingFang SC", sans-serif'
    fontSize: 17px
rounded:
  composer: 20px
  capsule: 26px
omitted:
  - section: spacing
    reason: 原生安全区及共享组件持有尺寸；不引入第二套间距标尺。
  - section: components
    reason: SwiftUI 和 UIKit 组件为运行时真源。
---

## Overview

遵循批准的 iOS 顶部猫头主图及焦点三态稿。手机阅读区优先，唯一动态身份留在顶部，不在单聊每条回复重复姓名和头像。群聊保留作者，目录头像保留。本文限定原生聊天；根 DESIGN.md 中 Web 底部伙伴的几何不适用于此处。

## Colors

`Wand/Theme.swift` 是颜色与动态字体的真源，本文镜像浅色值。深色由同一 Theme 映射：背景 #101114、表面 #1C1D21、正文 #F4F5F7、次要文字 #C4C7CF、品牌 #63B4FF。消息与输入沿用原语义色，不为设计稿覆盖应用主题。

## Typography

正文使用系统 body，输入 UIKit preferredFont 随 Dynamic Type 更新；设置标签 subheadline，说明 caption。长模型名在选择器完整可读，窄屏允许辅助文案折行。字号不通过缩放整个页面解决。

## Layout

顶部正常 100pt 安全槽包含 88pt 伙伴；紧凑高度使用 56pt 槽和 48pt 伙伴。返回、文件和更多保留 48pt 目标。伙伴默认在返回与右侧两按钮之间居中，因此略偏视口左侧，键盘不改变其位置。`ChatTopLayout` 统一聊天、IM与预览的安全槽和控件尺寸；消息区域裁剪到自身阅读视口，首条消息、上翻与键盘变化均不能绘制到顶部控件下方。

底部 `FocusComposerSurface` 持有同一编辑节点与表面。点击收起胶囊正文即聚焦；展开使用可用宽度和统一 12pt 边距，文字单独整行，下方加号与发送图标，最底部设置。语音始终留在胶囊内，与发送/停止独立。右侧独立 48pt 圆形操作槽由同一个按钮承载：空输入且空闲时隐藏（不可点击、不进入无障碍树）；有文字或附件显示发送；运行态优先显示停止，即使输入已清空或又有新草稿。加载/回执沿用原位短暂反馈。槽位几何保留，显隐不挤压输入宽度；收起或打开键盘不影响停止可达。停止沿用原确认与服务入口，不清草稿/附件、不顺带提交。文字高度有界，长文由原生文本区域滚动；横屏优先保留消息空间。附件预览与移除是分开的 44pt 目标。

## Elevation & Depth

只使用实色表面和 Theme.border 细边框。系统 sheet 负责模态遮罩、拖拽和焦点，不复制第二套弹层。顶部没有整行背景或大型标题卡。

## Shapes

胶囊收起 26pt、展开 20pt；原生 SF Symbols 提供功能图标。共享真实 3D 场景和身份规则保持唯一来源，禁止用静态图摇动冒充读写。背景暂停、减动效和实际 TTS 活动沿用已有宿主。

## Components

| 能力 | 所有者 | 验证 |
| --- | --- | --- |
| 胶囊与焦点借用 | FocusComposer.swift | VoiceCallTests.swift 中 FocusComposerTests；模拟器键盘/弹层/草稿 |
| 文本和中文组字 | NativeComposer.swift / IMEAwareComposerTextView | ComposerToolParityTests；原生输入 |
| 草稿、附件与发送 | ComposerDraftState / ChatStore / ConversationStore | 原有发送回执、未知送达和 revision 回归 |
| 当前会话三项设置 | SessionComposerSettings / SearchableChoiceSheet | 真模型目录、权限边界与思考元数据 |
| 真实伙伴 | SharedPlushScene.swift / WorkingAvatar | 真实原生连续帧 |

`ComposerFocusController` 只拥有呈现状态。点消息空白或显式关闭键盘收起，不清草稿和附件。附件、模型、录音暂借焦点时保持编辑；子层关闭返回原编辑节点。用户显式退出优先于迟到的子层回调。发送成功只清对应 submission；失败或未知送达保留输入并等待核对。

执行会话提供模型、权限模式和思考深度三个独立入口；按真实目录显示能力，未知元数据不能当作不支持。Codex 固定权限明确说明，扩大权限必须明确确认作用于当前会话。会话设置队列仍由 ChatStore 持有。

聚合私聊的服务协议每条消息按员工候选新建执行上下文，暂不支持单条覆盖。因此其底部明确命名“员工默认配置”，展示真实首选模型、权限、思考及“后续新工作”范围，按需进入原员工配置。不得把历史回复设置伪装为下一条设置，也不得自动修改员工或服务端默认。值缺失时说明不可用原因。

顶部原长按语音继续使用 300ms 互斥手势，上滑取消、松手只进 revision 绑定草稿；点击或拖动不同时触发录音。左右拖动限制在顶部安全槽，仅微调位置，并保留本机偏好与更多菜单的非拖动入口。语音、任务停止与权限确认保持独立。

## Do's and Don'ts

适用业务边界来自根 AGENTS.md 的数据/Session 输入契约及 `src/conversation-service.ts`。不新建发送锁、不重建编辑节点、不用 onBlur 清稿、不自动重发未知送达、不为预览发送真实 AI。离线样例、真实已安装服务和设备证据分别标明。

本次有意演进：旧底部猫头/键盘图标入口移到顶部稳定伙伴与直接点击胶囊；每条单聊回复的重复头像姓名移除；旧长文 180pt 输入上限收紧为常规 112pt、键盘下 96pt、紧凑高度键盘下 44pt。颜色、身份资产和发送契约不变。
