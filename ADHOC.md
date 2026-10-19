# Ad Hoc 签名与自建服务器更新

普通 Apple Developer Program 的已登记测试设备可使用 Ad Hoc 分发；不等于 Enterprise 企业分发，不支持任意未登记手机。系统安装需要用户确认，不会静默安装。

## 准备

- 本机钥匙串中有有效的 Apple Distribution 证书及对应私钥。用 `security find-identity -v -p codesigning` 检查；不要导出私钥、关闭证书校验或随意吊销证书。
- 主 App、Widget 各有一份明确 App ID 的 Ad Hoc `.mobileprovision`，两者团队/分发证书一致，并包含目标 iPhone 的 UDID。
- 无界面进程与登录桌面可能处于不同安全会话：即使用户钥匙串已解锁，无界面进程仍可能报 CMS 不可写或看不到签名身份。先用只读检查区分锁定与会话上下文；需要时通过受信本机认证入口，使用 `launchctl asuser <uid>` 并明确降回原用户，在其 GUI 会话中执行原构建。不能把整套构建以 root 身份运行；密码不进入命令参数、日志、仓库或临时文件，不换签名身份、不自动扩大私钥 ACL 或修改自动锁定策略。
- 主 App 和 Widget 的标识从 profile 读取，Widget 必须位于主 App 的标识前缀下。签名参数只写入本次构建的 xcconfig，不修改共享 Xcode 工程或写死团队信息。
- 缺少 Apple 中间证书时，只从 Apple 官方 PKI 获取并验证；不能设置自定义“始终信任”或将分发证书作为根证书。证书/描述文件不要提交到源码库。

## 本机一次配置与手机更新

可信本机配置 `~/.config/wand-build/ios-adhoc.env` 可保存 `IOS_APP_PROFILE`、`IOS_WIDGET_PROFILE`、`IOS_TARGET_UDID` 和可选的 `IOS_DISTRIBUTION_CONFIG`（服务端 config.json 路径），权限设为0600；描述文件保存到该目录的私密子目录，不依赖 Downloads 长期保留。私钥仍留在钥匙串，不能写进该文件。配置后正常 `IPA_DIST_DIR="$HOME/.wand/ios" ./build.sh` 会自动使用 Ad Hoc 流程；显式 `CODE_SIGNING_ALLOWED=NO` 保留未签名验证用途。不完整或无效的签名配置会报错，不静默发布未签名包。

首次用 Safari 安装同一团队/Bundle ID 的签名版后，App 在连接成功、回到前台时自动检查，并在前台使用期间每5分钟检查。可安装新版本显示原位横幅，点“安装更新”直接跳转同一更新来源的 HTTPS 安装页，在页面确认系统提示即开始安装，无需连接电脑或运行侧载工具。iOS 26+ 上从 App 内直接交给 `itms-services` 时系统不再让位，安装会等待该 App 退出而卡住，因此安装统一从浏览器发起；仅当服务端未提供合法安装页时才回退 App 内交接（旧系统可用）。后台不会轮询或承诺实时推送；失败不打断聊天，设置保留手动检查/重试。只提示同 Bundle ID 的已签名 HTTPS 安装包，不自动安装另一个身份的 App，也不把安装器打开当作安装成功。

点击后会保留安装页交接说明；系统未响应时解除等待，允许手动重试。交接反馈不代表已下载或安装完成，App 不会自动重复发起安装。

每个新版本仍需构建/签名/发布，但本机配置完成后正常交付命令会自动完成这些步骤，不需要手机用户逐次续签。证书/profile/会员仍需到期维护，新增设备也需要更新profile。

## 本机固定入口

这台已配置机器使用用户主目录的 `~/ios.sh`，无需在外层加 sudo：

```bash
~/ios.sh --check                  # GUI 用户签名环境检查，不构建/分发
~/ios.sh                          # 原 Ad Hoc 流程，默认带时间版本 Beta
~/ios.sh 4.96.0-debug.10171333     # 可选显式版本
```

入口只复用 `~/start.sh` 的受信 askpass 认证方式，不执行服务生命周期；进入原用户 GUI 安全会话后明确以原用户构建，沿用本节以下的原签名、外盘守卫、校验及分发流程。不会自动解锁、改私钥 ACL/签名身份、登记设备或安装客户端，也不会降级为 unsigned。固定入口只支持签名构建，未签名验证仍使用项目原入口。

`--check` 通过只表示当前环境和现有身份/描述文件匹配，不代表已构建新包。默认分发到 `~/.wand/ios/`。同一固定入口以 `~/.config/wand-build/ios-build.lock` 防重复构建；正常结束清自己的锁，中断则保留锁，须先核对实际构建/后代进程再处理，不自动删遗留锁或强停。其他机器/CI 未配置本机入口时仍按下列通用命令操作。

## 构建与本地分发

```bash
IOS_APP_PROFILE="$HOME/Downloads/App.mobileprovision" \
IOS_WIDGET_PROFILE="$HOME/Downloads/Widgets.mobileprovision" \
IOS_TARGET_UDID="目标设备的UDID" \
IPA_DIST_DIR="$HOME/.wand/ios" \
./build-adhoc.sh
```

可传显式版本，例如 `./build-adhoc.sh 4.96.0-debug.10162050`；默认按主仓最高语义 tag 加当前时间生成 debug 版本。每次使用新的输出目录，不清除旧构建；`WAND_ADHOC_BUILD_DIR` 可指定一个尚不存在的绝对路径，本机外盘构建守卫仍适用。

脚本先验证 profile/UDID/有效签名身份，使用手动签名执行 Xcode `archive` + `exportArchive`（release-testing），不调用 `-allowProvisioningUpdates`，不隐式登记设备或创建证书。脚本只向 Xcode 用户描述文件目录添加缺失文件，不覆盖不同内容的同 UUID 文件。

导出后检查主 App 和 Widget 的严格嵌套代码签名、证书链/叶证书、嵌入 profile、团队/App ID、entitlements、设备名额与期限、版本/build。验证失败不部署；验证成功才通过同文件系统无覆盖的原子操作发布到 `IPA_DIST_DIR`，保留旧包。省略 `IPA_DIST_DIR` 只构建，不分发。配置 `IOS_DISTRIBUTION_CONFIG` 后，发布工具核对已启用的服务器分发目录，以原子、检测并发冲突的方式只更新 `ios.currentIpaFile`，保留其他配置和旧包，并拒绝同身份的build降级；无需每次手工切换。没有该配置时只发布文件，服务如固定选择旧包仍需同步选择器。不要为触发选择而删除旧包或混用未签名包。

产物与证据位于构建目录：`Wand.xcarchive`、`wand-v<version>.ipa`、`Signing.xcconfig`、`ExportOptions.plist`、`verified-ipa.json`。保留现有 `build.sh` 的未签名构建用途。

## 更新验收

1. 在实际运行服务检查 `/api/ios-ipa-update?currentVersion=0.0.0`，确认新版本、正确 Bundle ID 和 `signed=true / otaReady=true`。
2. 核对 `/ios/manifest.plist` 的标识、版本和 IPA URL；从实际下载端点完整下载并核对大小/SHA-256。
3. 在目标手机 Safari 打开相同服务的 `/ios/install`，或在 App 设置中触发更新。清单和 IPA 必须通过设备信任的 HTTPS 下载；App 内放行自签证书不影响系统安装器。
4. 新 profile 使用不同 Bundle ID / Team 时可能是新的 App，不能承诺覆盖旧侧载安装，也不能先卸载旧版以“修复”；先确认身份与数据迁移。

服务端现有 `signed/otaReady` 仅为基础标记/HTTPS 检查，不会验证 profile 设备、期限或密码学签名。不能绕过构建脚本的完整验证，也不能把接口就绪当作真机安装成功。到期前用有效证书和新 profile 重新导出、分发。

## 离线检查

```bash
bash -n build-adhoc.sh
python3 scripts/test-adhoc-signing.py
```

检查不访问 Apple 门户、不修改钥匙串、不安装设备。此签名/分发链路是 iOS 平台专有，不改变 Android 的应用更新行为。
