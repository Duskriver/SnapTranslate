# 框选遮罩内存基准

比较对象是框选组件的隔离进程，不读取屏幕像素、不读取 API Key、不调用 DeepSeek。测试会短暂显示遮罩，约 7 秒后自动退出。

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
