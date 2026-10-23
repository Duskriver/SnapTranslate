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

脚本仅查询 `launchctl print pid/<PID>` 和 `vmmap -summary`，递归列出已启动的关联 XPC 服务及各自的当前/峰值 physical footprint，不访问密钥、不修改进程。各进程值相加未去重共享页，也不包含 WindowServer、GPU 和其他共享守护进程，不能当作整机新增物理内存。进程在测量中退出时会报告错误并返回非零状态。

需要检查普通窗口访问是否引入自动填充或缩放菜单服务时，可加 `--check-ui-services`；发现这两种服务或采样错误时返回非零。测试前启动新进程，保持已保存的密钥，不编辑密钥，也不使用界面自动化工具检查或截取窗口。此次使用的检查工具在本机 macOS 27.0.1 上会启动 `ThemeWidgetControlViewService`，包括没有标题栏的隔离对照窗口，窗口检查截图中可见系统窗口共享指示器。这是观察行为引入的系统开销，不能笼统推断所有辅助功能客户端都会触发，也不能当作应用保留了已关闭窗口的证据。

窗口控件、事件监听和热键资源是否释放由 `swift test` 中的生命周期测试检查；进程快照补充检查系统服务，二者不能互相代替。

## 请求编码基准与后续优化方向

`RequestEncodingProbe.swift` 单独测量现有 `DeepSeekClient.makeRequest`：合成字节代表已经编码好的图片，保留输入和生成的 HTTP body 到采样点。它不执行 PNG 编码、截图、钥匙串读取或网络请求，也不代表完整应用峰值。每次测量启动新进程，耗时包含 Foundation 首次使用开销。

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

- 上传阶段：请求构造的完整字符串中间副本已移除；进一步检查原始图片 Data 与最终 JSON body 在上传、等待结果时的存活时间。当前基准未覆盖 URLSession 持有请求体的开销。
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
