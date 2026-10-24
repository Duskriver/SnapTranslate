# SnapTranslate · 轻译

一个只做截屏翻译的原生 macOS 菜单栏应用。默认按 **⌥⇧T**（可自定义），框选区域，将截图交给 DeepSeek，译文显示在小浮窗中。默认目标语言为简体中文。

Swift + AppKit，零第三方依赖；优先控制待机资源占用，不包含历史记录、本地 OCR、自动更新或模型选择。

SnapTranslate 是独立开源项目，**不是 DeepSeek 官方客户端**，与 DeepSeek 无隶属关系。使用需要自己的 DeepSeek API Key；API 调用由 DeepSeek 计费。

*A minimal native macOS screenshot translator built with Swift and AppKit. Select a region with a keyboard shortcut, send it directly to DeepSeek, and read the streamed translation in a floating panel. No third-party dependencies.*

## 下载

在 [GitHub Releases](https://github.com/Duskriver/SnapTranslate/releases) 下载应用包。目前提供 **macOS 14 或更高版本、Apple Silicon（arm64）** 的预编译版本，不适用于 Intel Mac。解压后将 `SnapTranslate.app` 拖入「应用程序」文件夹，再打开应用；使用需要自己的 DeepSeek API Key。

当前下载包使用固定的本机自签名，**尚无 Apple Developer ID 签名或 Apple 公证**。macOS 可能拦截首次启动；确认来源和完整性后，可按 [Apple 的说明](https://support.apple.com/zh-cn/102445) 在「系统设置 → 隐私与安全性」选择「仍要打开」。不需要关闭系统的安全检查。

每个版本附有 `SHA256SUMS`。将它与应用 ZIP 下载到同一目录后，可校验下载完整性：

```sh
shasum -a 256 -c SHA256SUMS
```

## 从源码运行

需要 **macOS 14 或更高版本**、**Xcode 16 或更新版本提供的 Swift 6 工具链**。构建脚本生成本机架构的应用，不生成通用二进制。

```sh
git clone https://github.com/Duskriver/SnapTranslate.git
cd SnapTranslate
swift test
./scripts/setup-signing.sh # 本机首次构建时执行一次
./scripts/build.sh
open build/SnapTranslate.app
```

首次运行 `setup-signing.sh` 会创建可重复使用的本机签名证书，并将私钥保存在登录钥匙串。若 macOS 提示 `codesign` 访问签名私钥，请在系统弹窗中允许；选择「始终允许」可避免每次构建询问。后续构建使用同一证书，保持跨版本的应用签名身份。这种本机自签名不等同于 Apple 开发者签名或公证，也不能保证 API Key 的钥匙串授权跨代码更新保留，具体见下文「开发与构建」。

## 使用

1. 打开 `SnapTranslate.app`（源码构建时位于 `build/`）。它显示在菜单栏中，没有 Dock 图标。
2. 在首次打开的设置窗口中填入自己的 DeepSeek API Key 并保存。也可以从菜单栏进入「设置」。密钥只保存在本机系统钥匙串中；再次打开设置只显示已保存状态，留空保留原密钥，输入新值替换，点击「删除密钥」后保存才会删除。
3. 按 **Option + Shift + T** 或自己设置的快捷键。首次使用时，按系统提示允许「屏幕录制」权限；如果系统要求，请退出并重开应用。
4. 在任意一块显示器上拖动框选。松开鼠标后开始翻译。一次框选限制在单个显示器内。
5. 译文可以选择或用「复制译文」复制。可以继续框选，保留多个独立结果窗口；**Esc** 关闭当前结果，翻译中关闭只取消该窗口的请求。

框选时 **Esc**、右键或再次按快捷键可以取消，已有结果不受影响。新的截图翻译会创建新结果窗口；框选后先读取截图，同时最多执行两个网络请求，其余等待，关闭等待中的窗口会取消该任务。也可随时从菜单栏选择「截屏翻译」。

如果框选后提示「需要屏幕录制权限」（旧版可能显示「用户拒绝了应用程序、窗口、显示器捕捉的 TCC」），点击结果窗口的「打开系统设置…」，在「隐私与安全性 → 屏幕与系统音频录制」中允许 SnapTranslate。部分系统将该页面称为「屏幕录制」。如果开关已开启，先退出并重新打开当前构建的应用，尤其是在应用运行期间重新构建之后；仍失败时，再移除该列表中的旧条目、添加当前使用的 `SnapTranslate.app` 并开启权限。截图前的权限检查通过，不保证实际捕获时一定获准。

自定义快捷键：打开「设置」，点击「截屏快捷键」右侧的组合键按钮，再按下新组合。需包含 **⌘ Command、⌥ Option、⌃ Control** 中至少一个，可同时加 ⇧ Shift；支持字母、数字、标点、方向键和 F1–F20 等功能键。**Esc** 取消录制，「恢复默认」可改回 ⌥⇧T；点击「保存」后立即生效，重启后仍会保留。取消设置不改变原快捷键。若系统报告组合被占用，保存会提示错误并保留原组合；请避开 macOS 或其他应用的快捷键。

DeepSeek API 按调用计费，需要自己的可用 API Key 和账户余额。设置中的「获取 API Key」会打开[官方控制台](https://platform.deepseek.com/api_keys)。应用没有内置密钥，也不会在启动时发起模型请求。

## 资源设计

- Swift + AppKit，零第三方依赖。原生文本控件，不加载浏览器或本地 OCR / AI 模型。
- 待机只有系统热键与菜单事件，不轮询键盘、剪贴板或屏幕。
- 设置窗口在独立临时进程中按需创建，关闭后进程退出，回收原生控件和界面缓存。已有 API Key 时默认聚焦语言选项，避免仅查看设置就唤起系统密码自动填充。打开期间两个进程的合计占用会增加，优化的是关窗后的待机内存。
- 启动和查看设置只检查密钥是否存在，不读取密钥内容；修改语言、快捷键不会重写未改动的密钥。开始截图翻译时才读取已有密钥。
- 设置和结果窗口不提供绿色缩放菜单，保留原生关闭与结果窗口边缘缩放。系统仍可能因辅助功能查询启动窗口服务，其退出时机由 macOS 管理。
- ScreenCaptureKit 按需截取一帧，只请求选区。框选遮罩使用托管矢量图层更新路径，避免拖动时由 AppKit 反复绘制整屏位图；系统合成仍会使用绘图缓冲。
- 单张截图最长边 4096 像素、最多 800 万像素；普通小选区保留原始分辨率。PNG 数据限制为 10 MiB，过大时提示重新缩小选区。
- 所有截图、PNG 编码、网络请求和结果浮窗共用一个临时工作进程，支持多个结果同时保留。每个窗口独立取消与释放，最后一个结果关闭后工作进程退出；退出期间到达的新任务等待旧进程回收后再启动新进程。主进程保留菜单栏、热键、框选、设置持久化及钥匙串访问；设置界面使用另一个短时进程，已有密钥不发送到设置界面，新输入的密钥和翻译凭据通过匿名管道传递，不放入命令行参数。网络请求最多并行两个，PNG 编码仍使用后台串行队列；等待上传的任务只保留压缩 PNG，结束或取消后释放，不降低图片清晰度。
- 位图所有权转交给编码任务，完成后结果只持有 PNG 存储；直接共享已完成的 PNG 缓冲，避免转换为 Swift Data 时复制整份结果。分辨率、色彩、透明度和 ImageIO 无损编码策略保持不变。
- 请求体按网络读取进度生成，每次最多编码 48 KiB 图片为 64 KiB Base64，不保留完整 JSON body，也不创建临时文件或编码线程；保留精确 Content-Length，并为系统重发提供独立的新流。取消通过 URLSession 停止上传。
- 每次请求使用短期 `URLSession`，关闭磁盘 HTTP 缓存与 Cookie 存储；不保存截图或翻译历史，不记录密钥、图片和译文。
- 流式文本约每 90 ms 合并新增片段，界面直接追加并复用文本样式，不反复比较或截取累计全文；停止后不保留刷新定时器。

这里的「不保存」指应用不主动把这些内容写成文件。系统可能有正常的交换内存、诊断或网络设施开销；发送的选区图片由 DeepSeek 服务处理。开始框选前等待设置进程完全退出；截图读取像素期间的新设置请求会延后到捕获完成，避免新出现的密钥输入框进入截图，等待模型响应期间仍可打开设置。截图也排除本应用窗口。

本机同轨迹框选隔离基准中，进程内存峰值中位数从 **111.8 MiB 降至 13.5 MiB**（新旧版本各 3 次）。此前单结果版本的真实截图与本地固定翻译响应对照中，翻译并关窗后的主进程待机占用由 **23.89 MiB 降至 14.52 MiB**，新版冷启动为 **13.36 MiB**。代价是每次启动工作进程，以及翻译期间更高的进程占用之和；不同测试范围不能直接相加。复测方法、代价和原始数据见 [本轮记录](benchmarks/results/2026-10-23-idle-worker.md)。

当前多结果版本另以 3 个全新进程、共 42 次真实截图与本地模拟翻译响应复测：保留 1 / 3 / 5 / 10 个结果时，主进程与唯一工作进程的占用之和中位数为 **40.33 / 44.30 / 47.11 / 53.75 MiB**。三次完整关窗周期后为 **15.09 MiB**，冷启动 **13.22 MiB**；全部关窗后的工作进程及已检查的关联服务均退出。这些和没有去重共享页，不含 XPC/GPU，也不代表大量截图同时上传的峰值。方法、范围和原始数据见 [多窗口记录](benchmarks/results/2026-10-23-multi-window.md)。

后续使用已有密钥执行 7 次真实 DeepSeek 翻译：保留 1 / 3 / 5 个结果时，两进程合计为 **39.55 / 43.97 / 47.33 MiB**；两轮全部关窗均退出工作进程，最终主进程回落至 **14.53 MiB**，同一进程冷启动 **13.97 MiB**。这是一次短文本会话的实测值，合计不含 XPC/GPU。完整方法和逐阶段数据见 [真实 API 记录](benchmarks/results/2026-10-23-real-api-multi-window.md)。

资源验证方法与已知边界见 [VALIDATION.md](VALIDATION.md)。资源占用会随选区、显示器和系统版本变化，项目不承诺固定的内存上限或相对其他应用的节省比例。

## 模型与请求

直接请求 `https://api.deepseek.com/chat/completions`，使用 `deepseek-flash`、图片 `detail: original`、关闭思考模式、启用流式返回。只发送当前截图和翻译指令，没有历史上下文或代理服务器。

- [DeepSeek 图像输入文档](https://api-docs.deepseek.com/guides/vision/)
- [DeepSeek 模型与计费](https://api-docs.deepseek.com/quick_start/pricing/)

## 开发与构建

打开 `Package.swift` 可以在 Xcode 中编辑；日常运行请使用打包后的 `.app`，以保证菜单栏、图标与系统权限身份一致。

```sh
swift test
./scripts/build.sh
open build/SnapTranslate.app
```

首次构建前运行一次 `./scripts/setup-signing.sh`，重复运行会复用现有身份。签名私钥只存入本机默认钥匙串，导入为不可导出，仅为 `/usr/bin/codesign` 配置免询问访问；生成过程中的临时私钥会删除。证书指纹保存在 `~/Library/Application Support/SnapTranslate/Signing/identity.sha1`，不会提交到仓库，也不随清理 `build/` 丢失。请保留钥匙串中的 **SnapTranslate Local Signing** 证书和私钥；删除或更换它们、换机、重置隐私权限后，可能仍需重新授权。初始化不修改全局证书信任设置，不授予屏幕录制权限。

已有 Apple Development / Developer ID 证书时，也可通过 `SIGN_IDENTITY` 指定证书名称或 SHA-1 指纹。构建脚本拒绝 ad-hoc 签名；证书缺失或新旧版本的签名身份不兼容时会报错并保留当前应用，不会自动换身份。验证更新兼容性可运行 `./scripts/verify-signing.sh`：它修改隔离副本的内容，验证新旧签名互相匹配，并确认同名临时签名不能冒充原应用。[Apple 关于跨版本签名身份的说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。

**自签名与 API Key 授权是两个检查层次。** macOS 的文件钥匙串还按签名分区检查访问。本机自签名应用会归到 `cdhash` 分区，代码变更后即使证书相同，也可能再次要求密码；「始终允许」记录的是该构建的分区。Apple 开发者签名可使用团队分区，但仍受具体钥匙串访问策略约束。[Apple Security 源码](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)说明了这一区别。应用不修改访问控制来绕过系统检查，也不把密钥移到明文文件。普通启动、查看设置和修改非密钥设置均不读取密钥；新自签名构建首次使用翻译时仍可能需要授权。

从旧版 ad-hoc 签名迁移到固定证书时，可能需要重新授权屏幕录制；钥匙串也可能询问是否允许新版读取已保存的 API Key。请先退出应用，在系统设置中移除旧的 SnapTranslate 屏幕录制条目，再添加当前 `build/SnapTranslate.app` 并开启。单纯重开开关有时不能清理旧构建的签名记录。以后使用同一证书构建可保留签名身份，但不保证运行中的旧实例在应用被替换后仍能通过系统检查。打包脚本会在签名成功后替换应用目录；正在运行的旧实例需退出并重新打开。

图标源代码在 `scripts/generate-icon.swift`，生成方式：

```sh
swift scripts/generate-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

代码结构：

- `Sources/SnapTranslate/`：AppKit 界面、系统热键、区域选择、截图与钥匙串。
- `Sources/TranslationCore/`：DeepSeek 请求、流式解析、取消与错误处理。
- `Tests/TranslationCoreTests/`：无需真实密钥的请求与流式网络测试。
- `Tests/SnapTranslateTests/`：首次拖动框选、快捷键录制与持久化、系统热键冲突及替换的回归测试。
- `VALIDATION.md`：本机验证结果及尚未验证的边界。

`.build/` 是开发编译缓存，`build/` 是应用产物，都不进入 Git。它们不属于应用运行时的数据目录；可用 `swift package clean` 清理编译产物。

GitHub Actions 在 macOS 上运行 `swift test` 和 Release 构建，不需要 API Key，不调用真实模型，也不上传本地签名应用。自动化测试不替代屏幕权限、框选、多显示器和真实 API 的人工验证。

## 贡献与许可

欢迎提交问题和小范围改进；开发约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

代码使用 [MIT License](LICENSE)，Copyright © 2026 Duskriver。DeepSeek 服务的使用与计费遵循其自身条款。
