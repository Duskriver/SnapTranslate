# 资源开销基准

框选基准比较框选组件的隔离进程，不读取屏幕像素、不读取 API Key、不调用 DeepSeek。测试会短暂显示遮罩，约 7 秒后自动退出。请求编码的独立基准与后续优化方向见本文末尾。

## 两种工作负载

```sh
# 保留最初的测试程序：显示遮罩，30 次强制失效/重绘，每次间隔 80 ms。
./scripts/measure-selection-memory.sh

# 30 步实际选区变化，从 (320, 360) 拖动至 (920, 610)。
./scripts/measure-selection-memory.sh --drag
```

默认模式使用原始 `MemoryProbe.swift`；拖动模式使用 `DragMemoryProbe.swift`。后者在测试进程内部调用组件的鼠标处理方法，不向系统事件队列注入输入。它验证返回的本地选区为 600×250 点，且只刷新拖动所在窗口。每次运行都是新进程。

与优化前的源码比较：

```sh
git show 327d523:Sources/SnapTranslate/RegionSelector.swift > /tmp/SnapTranslate-before.swift
SELECTOR_SOURCE=/tmp/SnapTranslate-before.swift ./scripts/measure-selection-memory.sh
SELECTOR_SOURCE=/tmp/SnapTranslate-before.swift ./scripts/measure-selection-memory.sh --drag
```

基线来自本仓库首个提交 `327d523`。脚本对新旧源码使用相同的 `swiftc -O`、同一个测试程序和应用配置。临时应用在脚本退出时清理。请依次运行，不要同时运行多个遮罩；比较时保持显示器配置和后台负载一致。

## 2026-10-23 本机结果

Apple Silicon、macOS 27.0.1、Swift 6.4；测试进程报告单屏 2560×1440 points，backing scale 为 1。使用 Mach `task_vm_info.phys_footprint` 和 `ledger_phys_footprint_peak`，单位 MiB，与 RSS 不同。下表峰值包含该次测试进程直到关闭后 2 秒的生命周期。

| 场景 | 优化前峰值 | 优化后峰值 | 说明 |
| --- | ---: | ---: | --- |
| 原始 30 次重绘程序 | 22.03 | 14.55 | 本轮各 1 次，同一原始程序 |
| 相同轨迹拖动 30 步 | 111.78 | 13.50 | 各 3 次的中位数，下降约 87.9% |
| 拖动测试峰值范围 | 111.72–118.95 | 13.34–13.56 | 全部 3 次结果 |

逐阶段数据保存在 [results/2026-10-23.csv](results/2026-10-23.csv)。拖动模式 6 次运行均验证了选区坐标与尺寸。

此前原始重绘程序曾出现单次 202.72 MiB 的峰值，但本轮未稳定复现；它不是稳定基线。因此不以「203 → 14」计算或宣传固定降幅。保留原重绘测试用于追踪绘制路径，另用真实选区变化防止 hosted layers 将 `needsDisplay` 变成无实际工作而造成误导。

## 测量边界

- 当前优化将 `NSView.draw` 的全屏绘制替换为托管的 `CAShapeLayer`，只更新路径；禁用隐式动画，取消时释放视图和图层。
- 数据只覆盖测试进程的物理内存，不包括整台机器、GPU 或 WindowServer 的总资源变化；合成器仍可能使用屏幕大小的缓冲。
- 以上不是完整应用内存上限。截图、PNG 编码和网络请求另有开销，完整应用实测见 [VALIDATION.md](../VALIDATION.md)。
- 尚未覆盖 Retina、多显示器、不同系统版本、长时间反复使用或其他选区尺寸。不同机器和系统绘制状态会改变结果。

## 主进程与辅助服务

在活动监视器找到当前 SnapTranslate 的 PID 后运行：

```sh
python3 scripts/inspect-memory.py <PID>
```

脚本通过 `ps` 查找子进程，并查询 `launchctl print pid/<PID>` 和 `vmmap -summary`，递归列出工作进程、已启动的关联 XPC 服务及各自的当前/峰值 physical footprint，不访问密钥、不修改进程。各进程值相加未去重共享页，也不包含 WindowServer、GPU 和其他共享守护进程，不能当作整机新增物理内存。进程在测量中退出时会报告错误并返回非零状态。

需要检查普通窗口访问是否引入自动填充或缩放菜单服务时，可加 `--check-ui-services`；发现这两种服务或采样错误时返回非零。测试前启动新进程，保持已保存的密钥，不编辑密钥，也不使用界面自动化工具检查或截取窗口。此次使用的检查工具在本机 macOS 27.0.1 上会启动 `ThemeWidgetControlViewService`，包括没有标题栏的隔离对照窗口，窗口检查截图中可见系统窗口共享指示器。这是观察行为引入的系统开销，不能笼统推断所有辅助功能客户端都会触发，也不能当作应用保留了已关闭窗口的证据。

窗口控件、事件监听和热键资源是否释放由 `swift test` 中的生命周期测试检查；进程快照补充检查系统服务，二者不能互相代替。

## 设置关闭后的待机占用

```sh
./scripts/compare-settings-memory.sh 0304cb2c01f49856ea4e7e679dd594fc619dd1ac
```

脚本对基线和工作区源码各运行三个新进程，每个通过真实 AppKit 控件打开/关闭设置五次，覆盖取消、标题栏关闭和保存语言。使用独立偏好域及模拟密钥状态，不访问用户密钥、屏幕或网络，需要桌面会话及已有签名配置。观察器记录主进程、设置子进程和关闭后的关联服务。

2026-10-24 本机结果：第五次关闭后的主进程 physical footprint 中位数 30.53 → 13.56 MiB，最终静置五秒为 29.42 → 13.27 MiB；代价是打开期间主/子进程之和中位数 30.52 → 38.97 MiB。此和未去重共享页，也不含 GPU/WindowServer。完整采样阶段、范围、进程数量、呈现观测时间、方法修正及原始数据见 [本轮记录](results/2026-10-24-settings-worker.md)。

## 请求编码基准与后续优化方向

`RequestEncodingProbe.swift` 单独测量 `DeepSeekClient.makeRequest`：合成字节代表已经编码好的图片，保留输入和请求到采样点。当前 probe 还会将请求体完整消费到 64 KiB 缓冲，让惰性编码的全部工作计入耗时；旧版的完整 Data 和新版的输入流使用相同消费方式。它不执行 PNG 编码、截图、钥匙串读取或网络请求，也不代表完整应用峰值。每次测量启动新进程，耗时包含 Foundation 首次使用开销。下列历史两组结果使用尚未添加消费步骤的原始 probe，本轮流式上传对照见文末。

```sh
REQUEST_PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snaptranslate-request-probe.XXXXXX")"
swiftc -O -swift-version 6 -parse-as-library Sources/TranslationCore/*.swift \
  benchmarks/RequestEncodingProbe.swift -o "$REQUEST_PROBE_DIR/request-probe"
for input_bytes in 65536 1048576 10485760; do
  for run in 1 2 3; do
    "$REQUEST_PROBE_DIR/request-probe" "$input_bytes"
  done
done
```

以下保留 2026-10-23 优化前实现的历史基线：Apple Silicon、macOS 27.0.1、Swift 6.4，三次独立运行的中位数；峰值为进程 physical footprint，包含输入、输出、临时编码缓冲与运行时，启动基线约 1.72 MiB：

| 合成图片数据 | 请求体字节数 | 构造耗时 | 进程峰值 |
| --- | ---: | ---: | ---: |
| 64 KiB | 88,195 | 4.18 ms | 2.69 MiB |
| 1 MiB | 1,398,915 | 5.83 ms | 7.38 MiB |
| 10 MiB | 13,981,827 | 26.60 ms | 52.39 MiB |

原始数据见 [results/2026-10-23-request-encoding.csv](results/2026-10-23-request-encoding.csv)。这组历史数据不是优化前后对比，也不能与框选峰值相加推算完整应用峰值；正式的同轮对照见下文。

### 分块组装请求体的对照结果

后续将完整 Base64 字符串、data URL 字符串再交给 JSONEncoder 的路径，改为预留最终 `Data` 容量，按 48 KiB 输入块生成最多 64 KiB 的临时 Base64，再追加到请求体。分块大小是 3 的倍数，只有最后一块可能补齐 `=`。文本仍由 JSONEncoder 转义，MIME 类型仍经白名单校验；每块前检查取消。没有更改图片数据、模型、提示词、输出上限或网络会话策略。

下面是同一轮的新旧对照，不使用上面的历史单侧数据计算收益。环境与编译参数相同，完全复用未改动的 `RequestEncodingProbe.swift`，每个尺寸新旧各 5 次独立进程，交替先后顺序；耗时不含输入合成，包含请求构造和 Foundation 首次使用开销。

```sh
git show 999fe4e:benchmarks/RequestEncodingProbe.swift > /tmp/request-encoding-original-probe.swift
REQUEST_AFTER_REF=999fe4e REQUEST_PROBE_SOURCE=/tmp/request-encoding-original-probe.swift \
  ./scripts/compare-request-encoding.sh ab94ff46aa81dc162429d2ccac5511ac9f8ece87 \
  > /tmp/request-encoding-comparison.csv
```

脚本将测量时的源码快照与二进制保留在忽略的 `build/request-encoding-comparison.*` 目录，标准输出为 CSV，编译环境等元数据写到标准错误。比较期间应保持后台负载稳定，不同时构建或运行其他基准。

2026-10-23 测量中位数；下列内存为独立进程的 physical footprint 峰值，包含输入、最终请求体和运行时，基线约 1.72 MiB：

| 合成图片数据 | 旧版峰值 | 新版峰值 | 旧版耗时 | 新版耗时 |
| --- | ---: | ---: | ---: | ---: |
| 64 KiB | 2.67 MiB | 2.48 MiB | 2.45 ms | 2.04 ms |
| 1 MiB | 7.34 MiB | 4.72 MiB | 3.41 ms | 1.63 ms |
| 10 MiB | 52.45 MiB | 25.73 MiB | 23.06 ms | 5.20 ms |

10 MiB 负载的进程峰值下降约 **50.9%**，请求构造耗时下降约 **77.4%**。该负载峰值范围：旧版 52.41–52.45 MiB、新版 25.73–25.77 MiB；耗时范围：旧版 21.88–23.70 ms、新版 5.00–5.52 ms。64 KiB 耗时范围重叠（旧版 1.60–4.80 ms、新版 1.33–5.27 ms），不据此声称小输入有稳定提速。

三个尺寸新旧生成的请求体字节数分别一致，为 88,195、1,398,915、13,981,827。回归测试另验证二进制数据完整往返、分块边界、非零起始索引、JSON 特殊字符、四种 MIME、大小限制和取消。JSON 对象键顺序不作为协议要求。

原始数据：[results/2026-10-23-request-encoding-comparison.csv](results/2026-10-23-request-encoding-comparison.csv)。测量源码 SHA-256：旧 `DeepSeekClient.swift` 为 `0101cd6abafa67fe8e00a4c46ed8a7536194bd719798b93400ea34871c5cafa7`，新文件为 `dcbc502f04f9e3a8103b6d3e0ca8f6ab774e4520fe058d011f566daa50949f4f`；共用 probe 为 `fa3bd9439a39c8ae75da9464979b97e2c29447fdf3c929385b2d1d45a50ec58b`。

这只证明请求构造阶段的改善，不代表完整应用峰值或端到端翻译延迟下降同样比例。本轮没有实际截图、PNG 编码、上传或模型请求，也未测量图形/XPC 服务；没有改变 10 MiB 图片上限或以降低画质换取结果。

后续优先考虑：

- 上传阶段：已完成按需编码请求体，不再保留完整 JSON Data；新增 URLSession 本地 HTTP 上传对照，见文末「流式上传内存对照」。原始图片仍保留以支持重发，后续可继续分析响应开始后的持有时间。
- 快速重复截图：已改为后台串行 PNG 编码，并在创建截图位图前排队；效果、取消语义及延迟代价见下文「PNG 串行编码对照」。
- 图片策略：800 万像素的 BGRA 像素数据本身约 30.5 MiB，另有编码开销。降低像素上限或尝试 JPEG 前，应先测小字、表格和代码截图的翻译质量；不直接把更低清晰度当成无损优化。

## 流式显示增量更新对照

网络客户端由发送累计全文改为发送尚未显示的增量，仍约每 90 ms 合并；完成或失败时补发未发布部分，取消不补发。结果窗口直接追加文本、缓存字体和段落属性、只检查增量中是否有非空白字符；移除成功结束时的重复全文刷新。

`StreamingDisplayProbe.swift` 使用真实 `ResultPanelController` 和 TextKit 文本存储。固定 440×354 点的结果窗口设为透明，按 32、128、512 次刷新生成相同的中文、代码、组合字符和 Emoji 文本；每次刷新先向 `TranslationStream` 输入四段合成 JSON，再以对应版本的 API 更新界面，并强制完成文本布局。新旧最终文本均按 UTF-8 字节与预期结果比较。

每次刷新使用独立 autoreleasepool，模拟各次 UI 事件的临时对象释放边界。计时从首批文本处理到完成状态及最终布局，包含 JSON 解码、流式累积、文本控件更新与 TextKit 排版；不包含应用启动、输入生成、SSE 字节分帧、实际网络等待或 90 ms 的时间间隔，也不测量绘图合成器。

```sh
./scripts/compare-streaming-display.sh > /tmp/streaming-display-comparison.csv
```

脚本复制当前相关源码到忽略的 `build/streaming-display-comparison.*` 目录，使用 [fixtures/streaming-display-before.patch](fixtures/streaming-display-before.patch) 在隔离副本中恢复本次优化前的实现。该副本已与开始优化前保存的源码逐文件比较一致；已有请求编码优化和窗口权限处理在两侧相同。后续源码变化若使补丁不能准确应用，脚本应失败，需要明确更新基线后再比较。源码快照和二进制保留用于复核。

2026-10-23，Apple Silicon、macOS 27.0.1、Swift 6.4，`-O -swift-version 6`；每个负载新旧各 5 次新进程，交替先后顺序，表格为中位数：

| 刷新次数 | 译文 UTF-8 字节数 | 旧版处理与排版耗时 | 新版耗时 | 旧版峰值 | 新版峰值 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 32 | 2,656 | 15.58 ms | 11.12 ms | 17.06 MiB | 17.20 MiB |
| 128 | 10,624 | 99.36 ms | 28.26 ms | 17.34 MiB | 17.34 MiB |
| 512 | 42,496 | 1196.49 ms | 97.29 ms | 17.83 MiB | 17.77 MiB |

512 次刷新的处理与排版耗时约下降 **91.9%**，范围为旧版 1189.47–1204.80 ms、新版 96.52–97.76 ms。这反映累计全文遍历开销的减少，不能用于声称真实翻译速度提高同样比例。正常应用仍受网络及模型生成速度影响。

内存指标是测试进程的 physical footprint，峰值包含该进程窗口初始化等阶段，不是整机增量，也不能与请求编码峰值相加。512 次刷新峰值范围为旧版 17.72–17.92 MiB、新版 17.64–17.86 MiB，明显重叠；32 次刷新新版中位数还略高。因此本轮结论为**耗时下降，进程内存基本持平，没有测得稳定内存收益**。128 次负载两侧均出现约 20.64 MiB 的单次峰值，原始数据完整保留。

原始数据：[results/2026-10-23-streaming-display-comparison.csv](results/2026-10-23-streaming-display-comparison.csv)。共用 probe 的 SHA-256 为 `2df02ca14ef92b31ed9a7df1fab1b9458d33721da261d57b4d98f4c36bc46213`；新版 `ResultPanelController.swift` 为 `9c38ea2b4ed894942dd3b8f9fd54a8bf718a9286efbd6464f4a20db18ba3560b`，`SSEParser.swift` 为 `594e75f6d410ef2db7717a8828605ab6b69fb6445c5c8738a63b7f3969b01b14`，`DeepSeekClient.swift` 为 `947a4479c5a22f6bb87493e0bb380162ec70cecbc1746bf785f532edbc87f972`。

运行时不截屏、不读取密钥、不调用 API，不使用外部 UI 检查工具。这里不覆盖实际绘制、WindowServer/GPU、关联 XPC 服务或真实使用后的长期资源占用；每轮对照需保持显示器和系统负载一致，并避免与构建或其他基准并行。

## PNG 串行编码对照

`PNGEncoder` 用专用串行队列执行 ImageIO。等待名额发生在 `SCScreenshotManager.captureImage` 之前，取消的等待者不会创建位图。已经开始的同步编码无法被中断，必须等其结束并丢弃结果后，才释放名额给下一次截图。仅将编码串行化而继续提前创建位图，会让排队图片继续占用内存，因此实现同时控制位图创建时机。连续操作时实际截图时刻可能后移。

```sh
./scripts/compare-png-encoding.sh > /tmp/png-encoding-comparison.csv
```

脚本复制当前源码，在隔离的 `build/png-encoding-comparison.*` 中应用 [fixtures/png-encoding-before.patch](fixtures/png-encoding-before.patch)，恢复本轮开始时的 `ScreenCapture.swift`。已用 `cmp` 确认恢复结果与优化前保存的原文件完全一致。基线使用原来的 detached task、取消传播与完整 PNG 编码实现；新版使用当前 `PNGEncoder`。基线副本中的新版编码器没有被调用。补丁使用零模糊匹配，后续源码改变导致无法准确应用时应停止并重新确认基线。

`PNGEncodingProbe.swift` 在两侧以同一个合成位图回调代替 ScreenCaptureKit：创建 1000×1000 或 3200×2500、sRGB BGRA 的不透明图像，包含固定的字形状图案和渐变，不降低像素数或压缩质量。脚本在隔离副本中公开原编码代码块，在两侧 ImageIO 函数入口/出口加入相同计数器，记录实际编码数量及最大并发数。两侧最终 PNG 字节数相同；计时和内存采样结束后解码最终图片，逐字节比较还原后的像素。

单次请求与连续 3/8 次请求使用相同输入规则。连续负载每次等待 20 ms，再取消前一次并提交下一次，真实提交间隔会受系统调度影响；这是用于触发重叠的压力负载，不代表通常的人工框选速度。位图在捕获回调实际执行时才创建，跳过已取消的回调正是本轮优化的一部分。

计时从首次提交到最新结果和旧任务全部结束，**包含合成位图创建、排队、PNG 编码及请求间等待**，不含程序启动与之后的解码验证。`latest_ms` 单独记录最后一次提交到结果返回的时间。`cpu_ms` 是进程所有线程累计的用户态加内核态 CPU 时间，允许高于墙钟耗时，不能当成用户等待时长。内存是进程 physical footprint 的生命周期峰值，在解码验证前采样，包含合成输入及编码缓冲；不是完整应用或整机增量，也不能与请求编码、流式排版的峰值相加。

2026-10-23，Apple Silicon、macOS 27.0.1、Swift 6.4，`-O -swift-version 6`，每个负载新旧各 5 次新进程，交替先后顺序；下表均为中位数，数值为旧版 → 新版：

| 负载 | 内存峰值 | 总流程耗时 | CPU 时间 | 最新请求耗时 |
| --- | ---: | ---: | ---: | ---: |
| 100 万像素，单次 | 7.95 → 8.05 MiB | 7.75 → 7.72 ms | 6.94 → 6.94 ms | 7.75 → 7.72 ms |
| 800 万像素，单次 | 35.39 → 35.52 MiB | 47.51 → 47.08 ms | 46.61 → 46.17 ms | 47.51 → 47.08 ms |
| 800 万像素，连续 3 次 | 98.81 → 43.25 MiB | 93.10 → 94.06 ms | 140.76 → 92.75 ms | 46.11 → 47.92 ms |
| 800 万像素，连续 8 次 | 114.22 → 43.38 MiB | 206.80 → 225.56 ms | 356.88 → 224.97 ms | 42.99 → 60.73 ms |

连续 3 次的实际 PNG 编码数量从 3 降到 2，连续 8 次从 8 降到 5；这两种负载的旧版最大同时编码数均为 2，新版均为 1。8 次负载内存峰值中位数下降 **62.0%**、CPU 时间下降 **37.0%**，但总流程耗时增加 **9.1%**，最新请求增加 **17.74 ms**。本轮优化控制重复操作的内存与无用计算，不能描述为全面提速。

8 次负载的峰值范围为旧版 83.61–121.83 MiB、新版 43.38–43.41 MiB；总流程耗时范围为旧版 201.40–213.21 ms、新版 220.40–232.75 ms，最新请求为旧版 42.95–44.63 ms、新版 52.07–64.28 ms。3 次负载峰值为旧版 75.86–98.89 MiB、新版 43.22–43.28 MiB。单次请求没有稳定提速，峰值增加约 0.1 MiB；小输入首次使用时有更明显耗时波动，原始数据全部保留。

原始数据：[results/2026-10-23-png-encoding-comparison.csv](results/2026-10-23-png-encoding-comparison.csv)，共 40 条。共用 probe 的 SHA-256 为 `66c6142a7901774b9e085bc5380b100311f41875427722ace4c46015696c0bb1`；旧版 `ScreenCapture.swift` 为 `64aaf56938eebd080a55d1bd6dc7a74be1a2eb7e993b78cb74f7647ca7fc57f9`；新版为 `55631106e92cd26abaf4e123622532d8d3bac9e412fa81df909e2714c7bf5121`；新版 `PNGEncoder.swift` 为 `ea88ee8be3abdcb949234fc1aa701622fd215bc6df176170258779c8ba982617`。这些是加入基准适配器前的生产源码哈希，运行时副本保留在脚本输出的目录中。

运行不读取屏幕、密钥或网络，也不启动界面检查工具；未覆盖真实 ScreenCaptureKit、显示器/权限变化、WindowServer/GPU、XPC、上传或模型响应。合成图像的可压缩性不同于任意真实截图，具体数值与收益不能直接推广到完整应用。复测时不要并行运行构建、测试或其他基准。

## 流式上传内存对照

### 开销定位与本轮选择

此前框选、流式文本和重复截图已分别优化。现有分阶段测量显示，大块内存主要来自截图位图以及上传图片/请求体：800 万像素 BGRA 原始像素本身约 30.5 MiB，单次 PNG 编码隔离进程峰值约 35.5 MiB，连续取消压力下约 43.4 MiB；这些是上节 PNG 基准的结果。本轮本地 HTTP 测得旧版 10 MiB 输入在请求准备完成时约 26.0 MiB、上传和等待期间峰值约 31.7 MiB。结果窗口 512 次更新的历史隔离峰值约 17.8 MiB。

这些峰值属于不同进程和工作负载，不能相加或据此计算完整应用的内存构成比例。2026-10-23 对运行中应用的一次 `inspect-memory.py` 只读快照为 25.3 MiB、历史峰值 28.5 MiB，未发现活动的关联 XPC；未控制该进程的使用历史，因此不用于优化前后比较。

在保持分辨率与 PNG 无损数据不变的前提下，优先移除可明确归因的 **完整 Base64 JSON 请求体**：10 MiB 图片生成 13,981,827 字节请求体，旧版在上传和等待时同时持有它与原图，网络设施还会有额外缓冲。新版 `RequestBodyStream` 根据 URLSession 的读取进度生成最多 64 KiB 的编码块（48 KiB 输入），不生成完整 JSON Data，也不创建临时文件或生产线程。保留原图用于请求重发，设置精确 Content-Length，提示词、模型、格式、图像质量与请求上限均未改变。

使用 Foundation 支持的 [请求体流与异步字节响应](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:))；需要重发时由 [task delegate 提供新流](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:neednewbodystream:))。编码在网络消费者线程按需执行，取消仍由原有 URLSession 失效路径处理，不添加常驻任务或定时器。

### 复跑与测量口径

旧版为本轮优化前的提交 `999fe4ec18d562a29f806a00db1da50660e27d06`，新版取工作区；两侧使用相同 probe、输入、`swiftc -O -swift-version 6` 和新进程。Apple Silicon、macOS 27.0.1、Swift 6.4；每个尺寸新旧各 5 次，交替先后顺序，以下为中位数。不要同时运行构建、测试或其他基准。

```sh
# 请求构造 + 完整消费，包含新版延迟到读取时发生的全部 Base64 编码。
./scripts/compare-request-encoding.sh 999fe4e > /tmp/streamed-request-encoding.csv

# 真实 URLSession 上传至本机 HTTP 服务，保留 SSE 响应读取路径。
./scripts/compare-upload-memory.sh 999fe4e > /tmp/upload-memory-comparison.csv
```

脚本在忽略的 `build/*-comparison.*` 下保留源码副本与二进制，CSV 写至 stdout，环境与校验信息写至 stderr。上传脚本只在这些副本中把 URL 改为 `127.0.0.1` 的随机端口，生产 URL 保持不变。所有请求使用合成字节和占位密钥。

编码 probe 将两种请求体都读入相同的 64 KiB 消费缓冲；计时从构造请求到消费完毕，包含运行时首次使用，不包含输入生成。保留输入及请求到采样点，不把创建输入流的时间冒充完整编码时间。原始数据：[streamed-request-encoding.csv](results/2026-10-23-streamed-request-encoding.csv)，共 30 条。

| 合成输入 | 峰值 MiB：旧 → 新 | 完整编码/消费 ms：旧 → 新 |
| --- | ---: | ---: |
| 64 KiB | 2.58 → 2.55 | 2.33 → 2.00 |
| 1 MiB | 4.81 → 3.50 | 1.76 → 1.80 |
| 10 MiB | 25.86 → 12.52 | 5.33 → 4.35 |

10 MiB 编码/消费的峰值下降 **51.6%**，耗时下降 **18.4%**；峰值范围旧版 25.83–25.89 MiB、新版 12.52–12.55 MiB，耗时范围旧版 5.26–5.41 ms、新版 4.28–4.48 ms。三个尺寸输出字节数分别为 88,195、1,398,915、13,981,827，新旧一致。小输入主要受首次使用与调度影响，不宣称稳定提速。

上传 probe 实际执行 `DeepSeekClient.translate`，只有测试中将刷新间隔设为零以准确采样首段响应。服务器接收完整请求后立即返回第一段 SSE，然后等待 100 ms，再发送完成事件；所有运行使用相同等待。JSON 与图片解码校验放在发送完成事件之后，服务器不计入客户端内存/CPU。计时不含输入生成和进程启动，包含请求构造、URLSession 初始化、上传与响应解析。输入保留到采样点。

| 合成输入 | 上传流程峰值 MiB：旧 → 新 | 请求开始至首段 SSE ms：旧 → 新 | 含等待的总耗时 ms：旧 → 新 | 客户端 CPU ms：旧 → 新 |
| --- | ---: | ---: | ---: | ---: |
| 64 KiB | 4.50 → 4.49 | 12.34 → 11.44 | 117.41 → 116.66 | 10.76 → 9.80 |
| 1 MiB | 7.97 → 5.61 | 13.43 → 13.43 | 118.76 → 118.76 | 11.98 → 12.53 |
| 10 MiB | 31.67 → 14.80 | 14.88 → 11.27 | 119.27 → 116.23 | 14.01 → 13.04 |

10 MiB 上传流程峰值下降 **53.3%**，峰值范围旧版 30.61–33.17 MiB、新版 14.56–15.36 MiB；等待首段译文后的当前占用中位数为 31.66 → 14.74 MiB。请求开始至首段 SSE 的范围为旧版 12.48–23.50 ms、新版 10.95–15.29 ms，含等待总耗时为 114.35–128.51 → 116.14–120.03 ms，均有重叠。耗时无明显整体退化，但不由这组本地结果推断公网或模型翻译提速比例。原始数据：[upload-memory-comparison.csv](results/2026-10-23-upload-memory-comparison.csv)，共 30 条。

正式采样前，脚本分别验证新旧版本的 HTTP 307/308 重发、上传中取消、响应中取消和提前 HTTP 401。取消上传时服务器确认收到的字节少于 Content-Length，取消响应时确认连接关闭。全部正常请求及重发的 body SHA-256 一致，JSON 结构、Base64、原图字节和返回译文均验证通过。重定向仍使用系统原有的 Authorization 处理行为，脚本不在重定向中补发认证头。

内存统一为 Mach `phys_footprint` / `ledger_phys_footprint_peak`，不是 RSS；峰值包含客户端启动、合成输入及运行时。这些隔离测量不覆盖真实屏幕捕获、PNG 编码、完整界面、WindowServer/GPU、XPC、TLS、公网和模型推理，也不代表完整应用峰值降低同样比例。服务端仅用于模拟 SSE 与验证数据，其进程开销未纳入数字；没有真实 DeepSeek 请求或凭据读取。

测量文件 SHA-256：

- `DeepSeekClient.swift`：`48ea3a4cf9fcb4826fe4c0e1be721182877289a27d4881ec8dd95b43dd8b7e3e`
- `RequestBodyStream.swift`：`77740d3d0bb1733294a735224c54c50f0fb99469e6cabd91df33772cf0549d8e`
- `RequestEncodingProbe.swift`：`93c02ba87b644b96f27aab098164151bb9ab6efda56aefebf05ae312925734b0`
- `UploadMemoryProbe.swift`：`1652206a807287692ab3c201bfa3443fbc1ae037598898ea2a8b350179cccb25`
- `upload_memory_server.py`：`731fd0ce954254020cf58afb83e5c0805f8513006f5dc841cfef7a6b24105184`

## PNG 存储共享与位图所有权对照

### 定位与实现

本轮基线为上一轮提交 `2df215618a6d8f6be4aabb6c97f2ed7dd1be679e`。800 万像素的 BGRA 位图本体约 30.5 MiB，继续保持原尺寸、色彩空间和透明度。本机分阶段测量定位到大输出的额外副本：ImageIO 写入 `CFMutableData` 后，`as Data` 转换会在源位图和 PNG 都仍存活时复制完整 PNG。

新版在 `CGImageDestinationFinalize` 成功且输出大小合法之后，通过 `Data(bytesNoCopy:)` 共享完成的缓冲，用一个只负责保活的所有者延长 CFData 的生命周期。ImageIO 此后不再写入，所有者不访问像素或 PNG 内容，Swift Data 负责后续写时复制。不会同时保留另一份完整 PNG，也不把源位图或 ImageIO destination 带入上传阶段。位图使用 `consuming` 明确转交给编码 Job，减少挂起调用者的所有权；截图前排队、串行执行与取消语义保持不变。

另外试验了 [CGImageDestination 的 data consumer 输出方式](https://developer.apple.com/documentation/imageio/cgimagedestinationcreatewithdataconsumer(_:_:_:_:))。本机这些 PNG 输入触发的是一次完整 PNG 写入回调，而非逐行或分块输出；回调拒绝超限数据时，ImageIO 已持有完整编码。因此本轮没有采用它来声称消除了 ImageIO 内部缓冲，也没有更换 PNG 编码器或降低图像质量。

### 原基准复测

完全复用 **未改动的 `PNGEncodingProbe.swift`**、原来的四组输入及 20 ms 取消/重提间隔。两侧都使用当前的串行截图/编码流程，仅比较本轮的所有权与 PNG 存储变化；不是与最初的并发编码版本比较。

```sh
./scripts/compare-png-encoding.sh 2df2156 > /tmp/png-storage-comparison.csv
```

脚本现在支持指定基线提交；省略参数仍可恢复历史的 detached 编码路径。两侧使用相同的合成截图适配器和计数器，最终图片解码后逐字节核对。每个负载新旧各 5 次新进程，交替顺序，Apple Silicon、macOS 27.0.1、Swift 6.4，`-O -swift-version 6`。下表为中位数，旧 → 新：

| 原负载 | 峰值 MiB | 总流程 ms | CPU ms | 最新请求 ms |
| --- | ---: | ---: | ---: | ---: |
| 100 万像素，单次 | 8.11 → 8.09 | 9.10 → 9.46 | 7.99 → 8.22 | 9.10 → 9.45 |
| 800 万像素，单次 | 35.52 → 35.52 | 47.62 → 48.43 | 46.62 → 47.41 | 47.62 → 48.43 |
| 800 万像素，连续 3 次 | 43.23 → 43.25 | 91.34 → 95.27 | 90.62 → 94.52 | 46.34 → 46.01 |
| 800 万像素，连续 8 次 | 43.44 → 43.39 | 229.83 → 231.45 | 227.62 → 230.76 | 69.09 → 66.05 |

原负载最终 PNG 约 0.10/0.76 MiB，四组内存范围均重叠，**没有测得稳定的内存下降或提速**。800 万像素单次峰值范围旧版 35.48–35.53、新版 35.50–35.58 MiB；连续 8 次为 43.39–44.30 → 43.36–43.42 MiB。对应总耗时范围为 47.32–52.45 → 47.89–51.71 ms，以及 224.81–249.17 → 226.97–235.10 ms。小幅中位数变化不能用作固定收益。

四组实际编码次数分别为 1、1、2、5，两侧最大并发始终为 1；连续 3/8 次负载分别有 2/7 个任务取消。该计时包含合成位图生成、排队、PNG 编码及请求间等待，不能当作单个 ImageIO 函数的耗时。原始数据：[png-storage-comparison.csv](results/2026-10-23-png-storage-comparison.csv)，40 条。

### 大输出与超限输入补充对照

另加 `PNGOutputMemoryProbe.swift` 检查压缩结果较大的情况。它使用相同截图/编码适配器、像素格式与测量方式，每次只提交一张图片；改变的是输入内容，不把结果与原文字图负载混算。三种确定性输入：

- `noise`：1000×1000，不透明 sRGB BGRA，固定种子的 RGB 噪声。
- `mixed`：3200×2500，前 800 行为同一噪声生成器，其余为原基准的字形状图案和渐变。
- `oversized`：3200×2500，全图固定种子噪声，最终 PNG 超过原有 10 MiB 限制；两侧都必须返回 `imageTooLarge`。

```sh
./scripts/compare-png-encoding.sh 2df2156 --output-sizes > /tmp/png-output-memory-comparison.csv
```

同一轮每种输入新旧各 5 次新进程交替运行；以下为中位数，旧 → 新：

| 补充负载 | PNG 字节数 | 峰值 MiB | 总流程 ms | CPU ms |
| --- | ---: | ---: | ---: | ---: |
| 100 万像素噪声 | 3,519,563 | 16.69 → 13.34 | 71.53 → 71.06 | 70.70 → 70.29 |
| 800 万像素混合内容 | 9,464,180 | 54.83 → 45.77 | 231.20 → 230.07 | 230.01 → 229.11 |
| 800 万像素噪声，超限拒绝 | 不返回 PNG | 63.34 → 63.38 | 547.60 → 545.58 | 546.11 → 544.22 |

两种成功负载的峰值分别减少 **3.35 MiB（20.1%）** 和 **9.06 MiB（16.5%）**，与移除一份最终 PNG 的量级一致。峰值范围为 16.66–16.70 → 13.31–13.36 MiB，以及 54.80–54.84 → 45.75–45.80 MiB，没有重叠。成功 PNG 的 SHA-256 新旧各次运行都一致，且解码后所有像素均与原输入逐字节相同；哈希和解码在测量结束后执行。

耗时范围仍有重叠：100 万像素为 70.92–88.04 → 70.59–89.87 ms，800 万像素混合内容为 230.19–237.87 → 226.96–234.03 ms。因此本轮收益是大 PNG 输出的内存下降，不宣称稳定提速。

超限图在转换为 Data 之前已经被拒绝，本轮优化不减少它的内部编码缓冲；峰值范围为 63.31–63.36 → 63.34–63.39 MiB，没有改善。总耗时范围为 546.53–614.90 → 542.27–625.08 ms，范围重叠。原始数据：[png-output-memory-comparison.csv](results/2026-10-23-png-output-memory-comparison.csv)，30 条。

### 验证与边界

新增回归测试验证 sRGB/Display P3、透明度和行填充下输出 PNG 与原实现完全一致，以及大 PNG 在源位图释放后仍能读取、解码、复制、修改和扩容。61 项测试通过，Release 打包与严格签名验证通过。

测量使用 Mach physical footprint 及截至采样时刻的生命周期峰值，不是 RSS；包含合成输入和运行时，不含之后的解码验证与 SHA-256 计算。原图生成规则和编码调用在每组新旧版本之间一致，全部输入都是合成图，没有降低分辨率或使用有损压缩。未覆盖真实 ScreenCaptureKit、物理多屏、GPU/WindowServer、XPC、上传、模型服务或完整应用峰值；也没有重新测量真实截图质量或 macOS 14。不要与构建或其他基准并行运行。

原始 probe SHA-256 为 `66c6142a7901774b9e085bc5380b100311f41875427722ace4c46015696c0bb1`，与上一轮 PNG 基准完全一致；补充 probe 为 `84568bf79af4b9749f96ea30251d1d3362ff5ca850e40a61200fd04cbfbb4298`。新版生产 `PNGEncoder.swift` 为 `ac0f28317aa7f8c4368a7f59337542348c09b76f87744ebc3422d61d129afb8f`；`ScreenCapture.swift` 未修改，仍为 `55631106e92cd26abaf4e123622532d8d3bac9e412fa81df909e2714c7bf5121`。脚本输出保存了加入相同计数器后的两侧源码快照和二进制。

## 翻译关窗后的待机占用

`./scripts/compare-idle-memory.sh 8867c76` 使用独立公开文本窗口、真实截图/PNG、loopback HTTP 和固定 SSE 响应比较旧版与当前源码。无需用户密钥或真实 API，先退出 SnapTranslate 以避免热键冲突；需要已有屏幕录制授权。新旧各 3 个新进程、每进程 5 次，交替顺序；成功后关闭实际结果窗口并采样。

本轮待机中位数 23.89 → 14.52 MiB（新版冷启动 13.36 MiB），代价是启动延迟以及翻译期间更高的主/子进程占用之和。方法、完整数据、失败试跑与范围见 [2026-10-23 记录](results/2026-10-23-idle-worker.md)。该基准不使用 UI 自动化查询被测窗口，不测真实 API、关联 XPC、WindowServer/GPU 或整机新增物理内存。

## 多个结果共用一个工作进程

`./scripts/measure-multi-window-memory.sh` 运行三个全新进程，每个保留最多 10 个结果并执行三轮完整关闭/重开；实际执行截图、PNG、HTTP/SSE 和 AppKit 窗口，使用公开测试内容、本地固定响应和占位密钥，不读取用户凭据或调用真实 API。外部观察器采样主/工作进程的 physical footprint，阶段确认确保测量时窗口数稳定，另检查第一组的关联 XPC。

保留 1 / 3 / 5 / 10 个已完成结果的占用之和中位数为 40.33 / 44.30 / 47.11 / 53.75 MiB；第三轮全部关窗后 15.09 MiB，冷启动 13.22 MiB，所有结束采样无工作进程。该和未去重共享页，不含 XPC/GPU，也不是大量截图同时上传的严格峰值。详情、范围和原始数据见 [多窗口记录](results/2026-10-23-multi-window.md)。

## 多结果的真实 API 与原生关窗验证

显式运行 `./scripts/measure-multi-window-memory.sh --real-api`，会使用应用正常钥匙串流程和生产 API 地址发出 7 次真实计费请求；默认不带参数仍使用本地模拟响应。测量副本校验选区必须与已知公开英文截图的 PNG 哈希相同，完成后通过原生窗口关闭路径逐个关窗，分别观察保留多个结果、全部关闭后静置和再次重开。公开图校验绑定本次显示环境，不一致会在上传前中止。

本轮 5 个完成结果时两进程合计 47.33 MiB，最后关窗后 14.53 MiB，同一主进程冷启动 13.97 MiB。两轮工作进程都正常退出，第一轮额外确认其关联 SetStore 退出。指标不含 XPC/GPU、未去重共享页，也不是多组中位数。详细方法、边界、实际等待时间与逐阶段数据见 [真实 API 记录](results/2026-10-23-real-api-multi-window.md)。
