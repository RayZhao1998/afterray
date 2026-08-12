# AfterRay V0 实现计划

> 状态：Active  
> 目标用户：开发者本人  
> 目标：先在一台本机上跑通完整闭环，不按可公开发布产品的标准建设  
> 原则：能删就删、能写死就写死，只保留未来不会立刻推翻的最小边界。

## 1. V0 的唯一目标

V0 只回答一个问题：

> AfterRay 能否在本机持续记录屏幕和声音，用本地模型理解这些内容，并提供一个有感觉的左右拖拽回溯体验？

V0 完成时，应能跑通：

```text
启动 AfterRay
→ 手动开始一次 Recording Session
→ 本地记录屏幕、系统音频和麦克风
→ 保存截图与音频片段
→ OCR、ASR、Embedding 和 LLM 各跑通一条真实路径
→ 打开 Recall View
→ 左右拖拽回到任意已记录时刻
→ 查看当时截图并播放对应音频
→ 收藏某个时刻
→ 达到内部保留阈值时，删除最旧的未收藏内容
→ 退出并重新启动后仍能继续回放和检索
```

V0 不是 Alpha，也不是给普通用户安装的正式版本。它可以依赖开发者手动下载模型、手动授权权限和手动开始录制。

## 2. 冻结需求

### V0-R001：本地录制

WHEN 开发者点击 Start Recording，AfterRay SHALL 在本机开始记录当前显示器、系统音频和麦克风。

WHEN 开发者点击 Stop Recording，AfterRay SHALL 结束当前 Session，并让已提交内容可以立即回放。

V0 使用固定采样策略，不做键鼠活动触发、会议检测或自适应 throttle。

### V0-R002：本地保存与恢复

WHEN 一个画面或音频片段产生，AfterRay SHALL 将它保存到本地应用数据目录，并在 SQLite 中记录时间、文件位置和处理状态。

WHEN App 重启，AfterRay SHALL 重新打开已有数据库，并展示之前的 Session。

V0 不实现自研 blob pack、SQLCipher、per-blob key、复杂 migration 或故障注入框架。

### V0-R003：删除最旧内容

WHEN 未收藏 Moment 数量超过开发配置中的 `maxUnstarredMoments`，AfterRay SHALL 删除最旧的未收藏 Moment 及其派生数据，直到未收藏数量回到阈值以内。

IF 最旧 Moment 已收藏，AfterRay SHALL 跳过它，继续寻找下一条最旧的未收藏内容。

收藏 Moment 不计入 `maxUnstarredMoments`，因此收藏可以无限越过这个开发阈值，且不会阻止继续录制。

V0 只实现按 Moment 数量删除的策略，不读取磁盘占用，不做空间设置页、容量预测、Free/Paid 差异或动态扩容。

### V0-R004：模型基础链路

V0 SHALL 为以下能力各接通一个真实本地实现：

1. OCR：从截图得到文字。
2. ASR：从录音片段得到 Transcript。
3. Embedding：为 OCR 和 Transcript 生成向量，并完成一次语义检索。
4. LLM：读取选定时间范围的 OCR/Transcript，生成一段本地回答或摘要。

模型由开发者通过脚本手动下载到固定目录。Adapter 可以先使用 Swift runtime 或本地子进程，选择最先跑通真实结果的方式。V0 不做模型商店、CDN、签名 catalog、断点续传、多版本回滚或硬件档位推荐。

### V0-R005：初始回溯

WHEN Recall View 打开，AfterRay SHALL 按时间顺序展示已经记录的 Moment。

WHEN 用户左右拖拽，AfterRay SHALL 连续改变当前时间，并显示离该时间最近的截图。

WHEN 当前 Moment 有音频，用户 SHALL 能从对应时间播放或暂停。

V0 只做一个水平时间轴，不做 Month/Day/Session 多层缩放。

### V0-R006：收藏

WHEN 用户收藏当前 Moment，AfterRay SHALL 持久化收藏状态。

WHILE Moment 被收藏，自动保留任务 SHALL 跳过该 Moment 及回放它所需的文件。

WHEN 用户取消收藏，该 Moment SHALL 重新成为可删除内容。

## 3. 明确不做

以下内容全部移出 V0，不为它们提前建设抽象：

- Accessibility Tree。
- 键盘、鼠标活动触发截图。
- 自动会议检测与会议 App adapters。
- 自动开始录音；V0 只允许手动 Start/Stop。
- 正式 onboarding 和一次完成所有权限的流程。
- App Store、Developer ID、Notarization、自动更新和安装包。
- Free/Paid、订阅、退订、退款、宽限期和历史迁移。
- 面向用户的空间限制、空间预测和容量设置。
- 加密 Vault、Keychain root key 和安全导出。
- Context Gateway、CLI、MCP 和外部 Agent 集成。
- 内置 Agent harness、Daily Goal、Daily/Weekly Reflection。
- PII 检测和外部模型审批。
- Month/Day/Session 缩放、复杂 shader 和完整视觉语言。
- Windows、iOS、P2P、Enterprise 和开源流程。
- 模型自动下载、模型升级、多模型选择和资源智能调度。
- 遥测、崩溃上报和普通用户支持工具。

这些项目在 V0 证明核心体验成立后重新排序；当前不建立占位代码。

## 4. 最小技术结构

V0 使用 Swift 原生单体，不引入 Rust、FFI 或独立服务。只保留两个 target：

```text
AfterRay.app
├─ Recorder          ScreenCaptureKit + audio capture
├─ Store             SQLite + ordinary media files
├─ Recall            SwiftUI/AppKit horizontal scrub UI
├─ Models            OCR / ASR / Embedding / LLM adapters
└─ AppState           composition root

AfterRayVisualLab.app
└─ mock Moments + Recall component states
```

建议目录：

```text
Apps/
  AfterRay/
  AfterRayVisualLab/

Modules/
  Recorder/
  Store/
  Models/
  Recall/
  MockData/

scripts/
  download-models/
  run-v0/
```

这些首先只是目录与 Xcode targets 内的代码边界，不提前拆 Swift packages。V0 跑通后再根据真实耦合决定是否拆包。

## 5. 最小数据模型

```text
RecordingSession
  id
  startedAt
  endedAt?

Moment
  id
  sessionId
  capturedAt
  imagePath
  isFavorite

AudioSegment
  id
  sessionId
  track            system | microphone
  startedAt
  endedAt
  audioPath

TextEvidence
  id
  sessionId
  momentId?
  audioSegmentId?
  source           ocr | transcript
  text
  startedAt
  endedAt?
  modelVersion

Embedding
  evidenceId
  vector
  modelVersion
```

约束：

- SQLite 是 metadata source of truth。
- 图片和音频直接作为普通文件保存；V0 不做 pack。
- 删除 Moment 时同步删除图片、OCR 和 Embedding。AudioSegment 只有在不再与任何存活 Moment 时间范围重叠时才删除，避免破坏收藏内容的回放。
- 时间统一保存 wall-clock timestamp；音频同步可额外保存 monotonic offset。
- schema 只支持 V0；自用阶段允许删除本地数据后重建，不承诺 migration。

## 6. 实现阶段

### Phase 0：工程启动，1–2 天

目标：两个 App target 能启动，并读写同一组数据结构。

- `V0-001`：创建 AfterRay.app、AfterRayVisualLab.app 和最小模块目录。
- `V0-002`：建立 SQLite schema、Store API 和本地媒体目录。
- `V0-003`：生成 20 个 mock Moments 和两条 mock 音轨。
- `V0-004`：Visual Lab 显示最小水平 Recall View。
- `V0-005`：增加一条本地 build/test 命令，不做云 CI。

出口：

- `run-v0` 可以启动主 App。
- Visual Lab 可以用 mock 数据左右拖拽。
- App 重启后 SQLite 仍能读取 fixture。

### Phase 1：录制与保存，3–5 天

目标：先得到不含模型的真实本地 recorder。

- `V0-101`：手动 Start/Stop Recording Session。
- `V0-102`：ScreenCaptureKit 固定频率取帧并编码到本地。
- `V0-103`：系统音频与麦克风分轨录制，写成分段文件。
- `V0-104`：把 Moment/AudioSegment metadata 写入 SQLite。
- `V0-105`：主 App 列出 Session 和 Moment。
- `V0-106`：退出、重启、再次打开同一 Session。

出口：

- 能手动录制至少 10 分钟。
- 重启后截图和两条音轨仍可打开。
- Stop 后不继续写入新文件。

### Phase 2：模型链路，3–5 天

目标：四类模型各跑通一次，不做模型产品化。

- `V0-201`：模型下载脚本和固定本地目录。
- `V0-202`：截图 → OCR → TextEvidence。
- `V0-203`：AudioSegment → ASR → TextEvidence。
- `V0-204`：TextEvidence → Embedding → 语义搜索。
- `V0-205`：选定时间范围 → LLM 回答/摘要。
- `V0-206`：简单 job 状态：pending/running/done/failed。

出口：

- 一张真实截图能产生可见 OCR。
- 一段真实双轨录音能产生 Transcript。
- 自然语言查询能返回至少一个相关 Moment。
- 本地 LLM 能根据选定内容生成结果。
- 模型失败不会让录制数据消失。

### Phase 3：初始 Recall 效果，3–5 天

目标：做出第一个可以感受到产品方向的回溯界面。

- `V0-301`：水平时间轴和当前 playhead。
- `V0-302`：左右拖拽改变当前时间。
- `V0-303`：离 playhead 最近截图的 thumbnail-first 加载。
- `V0-304`：截图切换的第一版 scale/opacity/red glow 过渡。
- `V0-305`：播放/暂停对应系统音频和麦克风音轨。
- `V0-306`：显示当前 OCR/Transcript。
- `V0-307`：收藏/取消收藏。
- `V0-308`：Visual Lab 加入空数据、短/长 Session、模型处理中和收藏场景。

出口：

- 用鼠标或触控板左右拖拽，可以从 Session 开头回到结尾。
- 拖拽不触发模型推理。
- 当前截图、时间和 Transcript 保持一致。
- Visual Lab 和主 App 使用同一个 Recall component。

### Phase 4：删除与本机闭环，2–3 天

目标：让 V0 可以反复自用，而不是一次性 demo。

- `V0-401`：开发配置中加入 `maxUnstarredMoments`。
- `V0-402`：超过阈值后按时间删除最旧未收藏 Moment。
- `V0-403`：同步清理图片、文本、Embedding 和无引用音频。
- `V0-404`：验证收藏不计入阈值，全部历史被收藏时仍可继续新增未收藏 Moment。
- `V0-405`：完成一次 60 分钟录制、停止、处理、回放、搜索、收藏和清理。

出口：

- 小阈值测试证明删除顺序正确。
- 收藏 Moment 不会被自动删除。
- 删除内容不再出现在 Recall 或搜索里。
- 完整流程只依赖主 App、模型目录和本地数据目录。

## 7. 并行方式

Phase 0 完成后，只使用 3 个实现 Agent：

| Agent | 所有权 | 第一批任务 |
|---|---|---|
| A — Recorder/Store | ScreenCaptureKit、音频、SQLite、retention | Phase 1，随后 Phase 4 |
| B — Models/Search | OCR、ASR、Embedding、LLM、模型脚本 | Phase 2 |
| C — Recall/Visual | Recall View、拖拽、播放、Visual Lab | Phase 3 |

Lead 只负责：

1. 冻结最小 Swift 数据结构和 Store API。
2. 每天把三个短分支合到可运行的 `main`。
3. 在同一台 Mac 上运行当前闭环。
4. 删除任何不属于 V0 的提前设计。

```text
Phase 0
  ├─ A: Recorder writes Moment/AudioSegment
  ├─ B: Models consume fixture Moment/AudioSegment
  └─ C: Recall consumes mock Moment/AudioSegment
          ↓
     每日合入同一真实 Session
          ↓
     Phase 4 retention + final self-run
```

模型和 UI Agent 在真实录制完成前使用同一组 fixtures，不等待 Recorder。

## 8. V0 Done

- 在开发机上可以从源码构建并启动 AfterRay。
- 可以手动开始和停止一次本地 Recording Session。
- Session 同时包含屏幕、系统音频和麦克风内容。
- OCR、ASR、Embedding、LLM 各有一条真实本地路径成功运行。
- 可以通过左右拖拽回到 Session 中任意已记录时刻。
- 可以播放该时刻对应音频，并查看 OCR/Transcript。
- 可以收藏 Moment，重启后收藏状态仍存在。
- 未收藏内容达到内部数量阈值后，最旧未收藏内容被删除；收藏内容不计入阈值。
- App 重启后已有内容仍可回放和搜索。
- 完成一次至少 60 分钟的本机自用闭环。

V0 不要求签名分发、长期稳定运行、正式安全保证、商业逻辑、自动会议检测或普通用户 onboarding。

## 9. V0 后的第一轮迭代：只优化 Recall

V0 跑通后，第一个独立迭代周期只处理回溯效果，不并行加入其他产品功能。

```text
Visual Lab 制作 3–5 个 Recall 方向
→ 用同一份真实 Session 录制对比视频
→ 选择一个方向
→ 调整拖拽手感、画面层次、过渡和红色光线
→ 放回主 App 自用
→ 记录哪里迷失、哪里卡顿、哪里产生 wow moment
→ 继续下一轮
```

可以研究：

- 截图薄片、景深和遮挡关系。
- 拖拽速度与时间移动比例。
- 惯性、吸附和停止时的画面稳定。
- 当前画面和前后画面的清晰度层级。
- 红色余辉、光线和 shader。
- 长 Session 的缩略与快速跳转。

这一阶段仍不加入 Month/Day 多层视图、会议检测、Agent、支付或正式分发。

## 10. 仅保留的开发参数

以下参数放在开发配置中，不制作 Settings UI：

- 截图采样间隔。
- 图片 codec/quality。
- 音频 segment 长度与 codec。
- 内部保留阈值。
- 模型目录。
- Recall 拖拽灵敏度和 thumbnail cache 大小。

参数变化只要不改变本计划的可观察行为，就不需要 ADR。
