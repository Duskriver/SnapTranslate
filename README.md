# SnapTranslate · 轻译

一个只做截屏翻译的原生 macOS 菜单栏应用。按 **⌥⇧T**，框选区域，将截图交给 DeepSeek，译文显示在小浮窗中。默认目标语言为简体中文。

Swift + AppKit，零第三方依赖；优先控制待机资源占用，不包含历史记录、本地 OCR、自动更新或模型选择。

SnapTranslate 是独立开源项目，**不是 DeepSeek 官方客户端**，与 DeepSeek 无隶属关系。使用需要自己的 DeepSeek API Key；API 调用由 DeepSeek 计费。

*A minimal native macOS screenshot translator built with Swift and AppKit. Select a region with a keyboard shortcut, send it directly to DeepSeek, and read the streamed translation in a floating panel. No third-party dependencies.*

## 从源码运行

需要 **macOS 14 或更高版本**、**Xcode 16 或更新版本提供的 Swift 6 工具链**。当前项目以源码构建为主；构建脚本生成本机架构的应用，不生成通用二进制。

```sh
git clone https://github.com/Duskriver/SnapTranslate.git
cd SnapTranslate
swift test
./scripts/build.sh
open build/SnapTranslate.app
```

构建脚本生成 Release 应用并进行本地 ad-hoc 签名。该签名用于本机运行，不等同于 Developer ID 签名或 Apple 公证；如需分发给其他用户，应另行配置正式签名和公证。

## 使用

1. 打开 `build/SnapTranslate.app`。它显示在菜单栏中，没有 Dock 图标。
2. 在首次打开的设置窗口中填入自己的 DeepSeek API Key 并保存。也可以从菜单栏进入「设置」。密钥只保存在本机系统钥匙串中。
3. 按 **Option + Shift + T**。首次使用时，按系统提示允许「屏幕录制」权限；如果系统要求，请退出并重开应用。
4. 在任意一块显示器上拖动框选。松开鼠标后开始翻译。一次框选限制在单个显示器内。
5. 译文可以选择或用「复制译文」复制。**Esc** 关闭结果；翻译中关闭浮窗会取消请求。

框选时 **Esc**、右键或再次按快捷键可以取消。新的截图翻译会取消上一条尚未完成的请求。快捷键固定为 ⌥⇧T；如果被其他应用占用，可从菜单栏选择「截屏翻译」。

DeepSeek API 按调用计费，需要自己的可用 API Key 和账户余额。设置中的「获取 API Key」会打开[官方控制台](https://platform.deepseek.com/api_keys)。应用没有内置密钥，也不会在启动时发起模型请求。

## 资源设计

- Swift + AppKit，零第三方依赖。原生文本控件，不加载浏览器或本地 OCR / AI 模型。
- 待机只有系统热键与菜单事件，不轮询键盘、剪贴板或屏幕。
- ScreenCaptureKit 按需截取一帧，只请求选区。框选遮罩使用托管矢量图层更新路径，避免拖动时由 AppKit 反复绘制整屏位图；系统合成仍会使用绘图缓冲。
- 单张截图最长边 4096 像素、最多 800 万像素；普通小选区保留原始分辨率。PNG 数据限制为 10 MiB，过大时提示重新缩小选区。
- 图片编码在后台执行，原始图片只存在于当前任务。关闭浮窗取消网络请求并释放结果窗口。
- 每次请求使用短期 `URLSession`，关闭磁盘 HTTP 缓存与 Cookie 存储；不保存截图或翻译历史，不记录密钥、图片和译文。
- 流式文本约每 90 ms 合并更新一次，停止后不保留刷新定时器。

这里的「不保存」指应用不主动把这些内容写成文件。系统可能有正常的交换内存、诊断或网络设施开销；发送的选区图片由 DeepSeek 服务处理。设置窗口在开始框选前关闭，截图也排除本应用窗口。

本机同轨迹框选基准中，进程内存峰值中位数从 **111.8 MiB 降至 13.5 MiB**（新旧版本各 3 次）；优化后的完整应用在一次包含两次小区域真实翻译的运行中峰值为 **27.0 MiB**。两者是不同测试范围。复测方法和原始数据见 [benchmarks](benchmarks/README.md)。

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

可设置 `SIGN_IDENTITY` 来使用自己的签名身份。重新构建后的本地签名变化可能需要重新授权屏幕录制或钥匙串。

本地开发时建议使用自己的 Apple Development 签名身份保持授权稳定。若重新构建后出现「屏幕录制开关已开启但仍未授权」，请先退出应用，在系统设置中移除旧的 SnapTranslate 权限条目，再添加当前 `build/SnapTranslate.app` 并开启。单纯重开开关有时不能清理旧构建的签名记录。打包脚本会在签名成功后替换应用目录；正在运行的旧实例需退出并重新打开。

图标源代码在 `scripts/generate-icon.swift`，生成方式：

```sh
swift scripts/generate-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

代码结构：

- `Sources/SnapTranslate/`：AppKit 界面、系统热键、区域选择、截图与钥匙串。
- `Sources/TranslationCore/`：DeepSeek 请求、流式解析、取消与错误处理。
- `Tests/TranslationCoreTests/`：无需真实密钥的请求与流式网络测试。
- `VALIDATION.md`：本机验证结果及尚未验证的边界。

`.build/` 是开发编译缓存，`build/` 是应用产物，都不进入 Git。它们不属于应用运行时的数据目录；可用 `swift package clean` 清理编译产物。

GitHub Actions 在 macOS 上运行 `swift test` 和 Release 构建，不需要 API Key，不调用真实模型，也不上传本地签名应用。自动化测试不替代屏幕权限、框选、多显示器和真实 API 的人工验证。

## 贡献与许可

欢迎提交问题和小范围改进；开发约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

代码使用 [MIT License](LICENSE)，Copyright © 2026 Duskriver。DeepSeek 服务的使用与计费遵循其自身条款。
