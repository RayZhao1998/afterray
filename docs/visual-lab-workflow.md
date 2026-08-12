# AfterRay Visual Lab 工作流

> 状态：Draft 0.2  
> 目的：让 Timeline、shader、motion 和传播素材可以脱离真实捕获链路快速迭代。

## 1. 定位

`AfterRayVisualLab.app` 是 AfterRay 原生 UI 的场景浏览器，相当于 Storybook，但直接运行生产 SwiftUI/AppKit/Metal 组件。

它解决四件事：

1. 不申请权限、不等待真实历史数据就能开发所有视觉状态。
2. 用虚拟时钟重复调试 Month→Moment 的连续动画。
3. 用同一套 scene 生成设计评审、官网和社媒 demo。
4. 在视觉参数进入正式 App 前完成可读性、Reduce Motion 和性能回归。

Xcode Preview 负责单个组件附近的秒级反馈；Visual Lab 负责组合场景和时间行为。Web/Figma 原型可以探索概念，但最终参数必须回到 Visual Lab 验证。

## 2. 工程边界

```text
Packages/
  AfterRayDesignSystem/
  AfterRayTimelineKit/
  AfterRayMockData/

Apps/
  AfterRay/
  AfterRayVisualLab/

VisualLab/
  Scenes/
  Presets/
  Scripts/
  References/
```

Visual Lab 可以依赖 production UI packages；production App 不得依赖 Visual Lab、mock data 或 reference images。

Visual Lab 中禁止：

- Screen Recording、Microphone、Accessibility 和 Input Monitoring 请求。
- 打开用户真实 Vault。
- 网络下载模型或运行真实 LLM。
- 使用开发者个人截图作为默认 fixture。

## 3. Scene 合约

每个 scene 至少定义：

```swift
struct VisualSceneDescriptor {
    let id: String
    let title: String
    let viewport: CGSize
    let seed: UInt64
    let initialTime: Duration
    let supportedModes: Set<VisualLabMode>
    let presetID: String
    let fixtureID: String
}
```

Scene ID 一旦进入 reference 或传播脚本就保持稳定。Fixture 使用确定性生成器，必须覆盖正常状态和失败状态。

首批 scene：

```text
onboarding.permission-center
timeline.month.overview
timeline.month-to-moment.hero
timeline.day.attention-river
timeline.session.fast-scrub
timeline.moment.semantic-overlay
timeline.moment.transcript
audio.meeting-possible
audio.meeting-auto-started
audio.meeting-recording-active
audio.meeting-suppressed
audio.meeting-ended
timeline.retention.free-30-day-edge
timeline.retention.paid-no-expiry
audio.retention.30-day-expiry
timeline.state.loading-partial-gap
timeline.state.secure-redaction
timeline.state.dual-display
timeline.accessibility.reduce-motion
timeline.stress.30-days
```

## 4. Mock Data

Fixture 不只是“几张假截图”，而是完整时间层级：

```text
MockMonth
  → MockDay[]
    → MockEpisode[]
      → MockMoment[]
        → VisualFrame[]
        → OCR / AX / Transcript / Cursor / Gap
```

必须包含：

- 中文、英文、中英混排、emoji 和超长文本。
- IDE、Terminal、会议、聊天、网页、PDF 和设计工具。
- 单屏、双屏、Retina/1x。
- AX complete/partial/timeout/skew。
- OCR 低置信度、Transcript 缺轨、图片已回收。
- 模型未安装、处理中、失败和热降级。
- Secure-field redaction 与未能可靠遮盖的警告状态。
- 会议 App 仅后台运行、可能会议、确认会议后自动开始、本次 suppressed、正在录音与会议结束。
- 麦克风权限已授予但录音未开始的状态，防止视觉上把“有权限”误表达成“正在录音”。

## 5. 可调参数

所有可调值通过 typed `VisualPreset` 暴露：

```text
Timeline
  lodThresholds, cardSpacing, depth, perspective, parallax

Light
  afterglow, bloom, blur, grain, vignette, highlight

Shader
  warp, distortion, chromaticOffset, maxSampleOffset

Motion
  zoomCurve, spring, settleDuration, scrubMapping

Legibility
  foregroundOpacity, neighboringFrameBlur, labelDensity

Accessibility
  reduceMotion, reduceTransparency, highContrast
```

UI slider 只修改 working preset。点击 Save 生成可读、可 diff、带 schema version 的 JSON。只有评审通过的 preset 才复制到 production resources。

## 6. 每次视觉迭代

1. 选择或新增一个 scene；不要直接在正式 App 中造临时数据。
2. 写清这次要改善的单一判断，例如“Month→Moment 下钻是否保持时间位置感”。
3. 固定 fixture、seed、viewport 和 reference machine profile。
4. 在 Interactive mode 调整组件与 preset。
5. 在 Shot mode 运行固定 virtual-time script，输出关键帧和 5–10 秒 clip。
6. 检查文字可读性、旁观隐私、Reduce Motion 和键盘路径。
7. 在 Stress mode 检查 frame time、内存和 dropped frames。
8. 评审通过后提升 preset，并写 snapshot/keyframe regression。

每次改动的评审包包括：

- Scene ID、fixture ID、preset diff。
- Before/after 关键帧。
- 固定脚本生成的短视频。
- reference Mac/OS、平均与 P95 frame time、dropped-frame ratio。
- Reduce Motion 版本。

## 7. Shot Script

传播素材必须由脚本重放，不能靠手工碰运气：

```text
t=0.0  show Month overview
t=0.8  focus Aug 12
t=1.2  zoom Month → Day
t=2.4  zoom Day → Meeting Episode
t=3.6  settle on Moment
t=4.2  reveal Transcript
t=5.2  reveal AX/OCR overlay
t=6.5  return to clean screen
```

脚本驱动虚拟时间、zoom anchor 和 overlay state。录制工具只负责输出，不参与动画逻辑。

## 8. 回归与 CI

- PR：preset schema、scene load、关键状态和少量 reference keyframes。
- Nightly/reference Mac：完整 shader scene、动画 frame-time、30-day stress 和 demo clip。
- 静态比较允许小范围 perceptual tolerance；不同 GPU/OS 不做全局逐像素等价承诺。
- 动画回归同时检查最终状态、关键时间点、布局不变量和性能，不能只比较一张截图。
- 失败产物作为 Xcode test attachment 保留，方便直接查看 diff。

## 9. 第一阶段完成标准

Visual Lab v0 完成时应满足：

- 无任何系统权限即可运行。
- 至少包含 Month、Day、Session、Moment 和 Permission Center。
- Month→Moment hero shot 可以稳定重放和导出。
- 至少两个视觉 preset 可切换比较。
- 支持 Reduce Motion。
- 能展示 OCR/AX/Transcript、gap 和 redaction。
- 30 天 mock dataset 下可以记录 frame-time 和 dropped-frame 指标。
