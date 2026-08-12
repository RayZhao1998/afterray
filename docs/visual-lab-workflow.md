# AfterRay V0 Visual Lab

> 状态：Active  
> 目标：像 Storybook 一样，用 mock 数据快速迭代 V0 的水平回溯组件。

## 1. 只解决一个问题

Visual Lab 只用于调试：

> 左右拖拽时，用户能否清楚、顺滑且有视觉记忆点地回到另一个时刻？

它不实现 Month/Day 层级、onboarding、会议检测、权限流程、付费状态或完整产品导航。

## 2. 工程关系

```text
AfterRayRecall
   ↑          ↑
主 App     Visual Lab
真实数据     MockData
```

- 主 App 与 Visual Lab 使用同一个 Recall component。
- Visual Lab 不请求 Screen Recording 或 Microphone 权限。
- Visual Lab 不打开真实用户数据，不运行模型。
- MockData 不能进入主 App 的 production composition root。

## 3. V0 场景

首批只保留五个场景：

1. `recall.empty`
2. `recall.short-session`
3. `recall.long-session`
4. `recall.processing-models`
5. `recall.favorite-moments`

每个场景使用固定 seed、固定窗口尺寸和固定时间范围。Mock Moment 包含截图、时间、OCR、Transcript、收藏状态和可选音频引用。

## 4. 可调参数

V0 只暴露会直接影响水平回溯手感的参数：

- drag-to-time 比例。
- 惯性与停止速度。
- 当前截图尺寸。
- 前后截图间距、缩放和透明度。
- thumbnail preload 数量。
- red glow 强度和衰减。
- 截图切换动画时间。

参数先存在代码里的 `RecallTuning`，不做 JSON preset 系统、版本管理或 Settings UI。

## 5. 每轮迭代

```text
复制一个 RecallTuning 变体
→ 在同一 long-session fixture 上左右拖拽
→ 录制 5–10 秒视频
→ 并排比较 3–5 个方向
→ 选择一个方向进入主 App
→ 使用真实 Session 一天
→ 记录迷失、卡顿和 wow moment
→ 开始下一轮
```

每轮只回答一个具体问题，例如：

- 拖快时是否仍知道自己到了哪里？
- 停下后当前画面是否足够稳定？
- 前后截图是否能表达时间方向？
- 红色光效是否增强时间感，而不是遮挡内容？

## 6. V0 Done

- Visual Lab 无权限即可启动。
- 五个场景都能打开。
- 鼠标和触控板可以左右拖拽。
- 主 App 与 Visual Lab 使用同一个 Recall component。
- 能快速切换至少三个 `RecallTuning` 变体。
- 可以录制固定尺寸的对比视频。

V0 不建设自动截图回归、完整性能基准、Shot Script DSL 或 shader preset 管线。这些只有在 Recall 方向选定后才值得加入。
