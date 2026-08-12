# AfterRay v1 总实现计划

> 状态：Draft 0.1  
> 基线 Spec：`608c4c9` (`docs: define AfterRay v1 product specification`)  
> 目标：交付一个可在 macOS 26、M3 及以上 Apple Silicon Mac 安装、长期运行和付费使用的 AfterRay v1  
> 读者：实现 Agent、集成 Agent、设计/产品负责人  
> 原则：任务可并行，集成必须通过阶段门；不以 demo 或 PoC 代替可持续运行的产品。

---

## 1. 交付结果

AfterRay v1 完成时，用户应该可以：

1. 从官网下载 Developer ID 签名并经 Notarization 的 App，完成安装和更新。
2. 在一次 onboarding 中理解并完成 Screen Recording、Microphone、Accessibility、Notifications 等必要授权。
3. 让 App 在后台根据用户活动自适应截图，但不持久化按键、鼠标事件或活动轨迹。
4. 对每个持久化 Moment 捕获前台 focused window 的完整 AX Tree，作为独立 zstd Snapshot 保存。
5. 从 Month 连续缩放到 Day、Session 和 Moment，快速 scrub 并查看截图、OCR、AX 和 Transcript。
6. 使用精确/短语、子串、近似拼写和语义检索找回内容，每个结果都能回到原始 Moment。
7. 在 onboarding 同意自动会议记录后，让 AfterRay 检测受支持的会议、自动开始双轨录音、转写并在会议结束后停止。
8. 安装后按设备能力下载 OCR、ASR、Embedding 等核心模型包，并可选下载本地 LLM 包，用受限的本地 Agent 做有证据引用的每日目标与总结。
9. 通过明确授权的 CLI/Context Gateway 让外部 Agent 只读检索特定日期、App 和证据类型。
10. 准确看到本地数据、模型包、录音、权限和删除状态；Free 历史滚动保留 30 天，Paid 不按年龄自动删除，原始音频默认保留 30 天。

### 1.1 v1 Done 的硬条件

v1 只有同时满足以下条件才可以发布：

- 一台干净的支持设备可完成下载、安装、权限引导、首次捕获、回看、搜索、会议转写和本地总结。
- 锁屏、睡眠、重启、低磁盘、断网、模型失败、权限撤销与 App 崩溃不会造成 Vault 损坏或未提示的隐私越界。
- 用户删除、Free 30 天到期与 raw audio 30 天到期能同时从 Timeline、FTS、向量索引、缓存、Agent context 和实体 blob 回收链路生效。
- 没有截图、音频、OCR、Transcript 或 AX 内容默认外发网络。
- 官网/社媒演示的 Month→Moment 效果使用真实产品代码，不存在只为视频维护的第二套 UI。
- 公开 v1 至少经历一个真实 30 天 Alpha 窗口；最终发布候选版另通过签名、Notarization、升级/回滚、第三方许可证、安全、恢复和连续 7 天无 blocker dogfood 验收。

---

## 2. 已冻结的实现边界

任何 Agent 不得在普通实现任务中重新打开以下决策：

| 边界 | 决定 |
|---|---|
| 首发平台 | macOS 26，Apple Silicon M3+ |
| 分发 | 官网直发，Developer ID + Hardened Runtime + Notarization；不做 v1 MAS 版 |
| 源码 | 私有，v1 不接受外部贡献 |
| UI | SwiftUI 产品外壳 + AppKit/Metal Timeline surface |
| 可复用核心 | Rust 管理 Vault、索引、保留、Evidence 查询与 Context Gateway |
| Accessibility | Required；每个 Moment 只读前台 focused window 完整 `AXChildren` Tree |
| AX 存储 | 每份 Snapshot 自包含、立即 zstd 压缩，不做增量链；1s deadline，2s 最大对齐偏差 |
| 截图活动 | 10s heartbeat + trailing settle + max-wait + 画面变化去重；不持久化输入事件 |
| 音频 | onboarding 可开启自动会议记录；平时不占用麦克风；不使用摄像头 |
| 保留 | Free Timeline 30 天；Paid 无时间到期；raw audio 默认 30 天 |
| 模型 | 安装 App 后按能力包下载；具体型号不冻结在实现计划 |
| 内置 Agent | 只读工具白名单，无 shell、无用户目录、无默认网络 |
| PII | v1 不做通用 PII 模型；保留排除、secure-field 禁读和显式外发预览 |

改变这些边界需要一个独立 Decision Record，并由产品负责人批准；Agent 不得以“更快完成”为由做隐性降级。

---

## 3. Agent Team 与所有权

建议使用 10 个稳定角色。当运行环境只允许 4 个并发 Agent 时，由 Lead 按当前 critical path 分批激活；角色和代码所有权不因分批改变。

| Agent | 主责 | 主要所有权 | 不应独立修改 |
|---|---|---|---|
| A0 Lead / Integrator | 任务图、接口冻结、集成、阶段门、release branch | workspace、CI 入口、ADR、跨域 schema | 未经 owner review 的子系统内部实现 |
| A1 macOS Shell | App lifecycle、菜单栏、onboarding、permissions、settings | `Apps/AfterRay`、`AfterRaySystemKit`、`AfterRayOnboardingKit` | Vault 格式、Metal renderer |
| A2 Capture + AX | ScreenCaptureKit、scheduler、多屏、AX Snapshot | `AfterRayCaptureKit`、`AfterRayAXKit` | 数据保留策略、Timeline 布局 |
| A3 Audio + Meetings | 双轨录音、VAD、会议 adapters、自动始停 | `AfterRayAudioKit`、`AfterRayMeetingKit` | ASR runtime、Vault compaction |
| A4 Rust Vault | schema、加密、blob packs、retention、deletion、crash recovery | `crates/vault-*`、DB migrations | Swift 权限与 UI |
| A5 Search + Evidence | FTS/子串/近似/向量融合、Evidence API、Swift/Rust bridge | `crates/search-*`、`crates/ffi`、shared schemas | 模型下载、Timeline shader |
| A6 Timeline + Visual | Timeline domain、AppKit/Metal surface、Visual Lab、overlays | `AfterRayTimeline*`、`AfterRayDesignSystem`、`Apps/AfterRayVisualLab` | Capture service、DB migrations |
| A7 Local AI Runtime | model catalog/download/runtime、OCR/ASR/Embedding/LLM adapters、enrichment scheduler | `AfterRayModelRuntime`、`crates/model-catalog`、model tools | 产品保留规则、Agent scope |
| A8 Agent + Reflection | 本地只读 loop、Context Gateway、CLI、daily goal/summary | `crates/context-gateway`、`crates/afterray-cli`、Reflection UI/domain | Vault raw access、未授权外部动作 |
| A9 Quality / Security / Release | threat tests、eval、dogfood、signing、notarization、updater、installer | `Tests`、`tools`、`scripts/release`、release checklist | 不经 owner 直接改业务逻辑 |

### 3.1 Agent 工作协议

1. 每个实现任务使用唯一 Task ID，只能有一个 Directly Responsible Agent。
2. 每个 Agent 使用独立 git worktree 与短生命周期 `agent/<task-id>-<slug>` 分支，目标 1–2 个工程日内通过 merge queue 合入始终可安装的 `main`；不建立长期角色分支。
3. 跨域修改先提交小型 ADR/schema PR，接口合并后再并行实现。
4. 一个 PR 只解决一个可验收任务；不把大量重构、格式化和功能混在一起。
5. 任务完成时必须附带：修改摘要、验证命令、已知限制、数据/权限变化、后续任务。
6. 任何会改变 Vault 格式、权限、网络出站、删除、录音或对外 Agent scope 的 PR，至少需要 A9 和对应 owner 复核。
7. A0 只在阶段门或所需 contract 通过后开放下一批依赖任务；schema、FFI 和 migration 使用串行合并队列，避免 Agent 在未冻结接口上同时扩张。

### 3.2 标准 Task Card

```text
ID / Title
Owner / Reviewers
Goal
In scope / Out of scope
Inputs and frozen decisions
Files/packages owned
Dependencies
Implementation notes
Acceptance criteria
Verification commands
Artifacts/screenshots/benchmarks
Risks and rollback
```

---

## 4. 代码库与依赖边界

实际目录可在 BOOT-001 中微调，但依赖方向必须保持：

```text
AfterRay.xcworkspace

Apps/
  AfterRay/
  AfterRayVisualLab/

Services/
  AfterRayModelRuntimeService/
  AfterRayModelDownloadService/
  AfterRayAgentHostService/

Packages/
  AfterRayCoreModels/
  AfterRaySystemKit/
  AfterRayCaptureKit/
  AfterRayAXKit/
  AfterRayAudioKit/
  AfterRayMeetingKit/
  AfterRayDesignSystem/
  AfterRayTimelineDomain/
  AfterRayMediaPipeline/
  AfterRayTimelineRenderer/
  AfterRayTimelineKit/
  AfterRayOnboardingKit/
  AfterRayModelRuntime/
  AfterRayMockData/
  AfterRayVisualTesting/

crates/
  afterray-core/
  afterray-schema/
  afterray-vault/
  afterray-index/
  afterray-retention/
  afterray-model-catalog/
  afterray-context-gateway/
  afterray-cli/
  afterray-ffi/

schemas/
  versions/
  fixtures/

Tests/
  Integration/
  Privacy/
  Recovery/
  Performance/
  Fixtures/

tools/
  corpus/
  benchmark/
  visual-regression/
  model-pack/

scripts/
  bootstrap/
  build-rust-xcframework/
  signing/
  release/

docs/
  adr/
  runbooks/
```

依赖规则：

- Swift system packages 可以依赖 `AfterRayCoreModels`，不能反向依赖 UI。
- Timeline 只通过 `TimelineDataSource` / `ImageProvider` 协议读取数据，不打开 SQLite 或 Vault 文件。
- Capture/Audio 只产生带时间的 ingest records，不直接修改搜索索引。
- Rust core 不调用 AppKit、ScreenCaptureKit、Accessibility 或 AVFoundation。
- Model Runtime 不直接获得 Vault 文件路径；只消费受限的 enrichment jobs 并返回 typed outputs。
- Model Runtime、Download Service 与 Agent Host 使用独立进程边界：Runtime 无网络、只读已安装模型且只收到单次任务输入；Download Service 是唯一允许访问模型 CDN 的进程且不能读 Vault；Agent Host 无 Vault 文件、shell、用户目录或默认网络权限。
- Capability Pack 只允许权重、词表、静态配置、许可证和 smoke fixture；所有 runtime、tokenizer 实现和自定义算子随签名 App 发布，禁止下载动态库、脚本、Python/Node 包或 remote code。
- Context Gateway 只调用 Evidence API，不绕过 scope 读原始 DB/blob。
- Production App 不得依赖 MockData、ShotScript 或 reference images。

---

## 5. 总体依赖图与并行策略

```text
P0 Repository + Contracts
        ↓
P1 Runnable Vertical Slice
        ↓
┌──────────────┬──────────────┬──────────────┬──────────────┐
↓              ↓              ↓              ↓
P2 Capture/AX  P2b Audio      P3 Vault/Search   P4 Timeline/Visual Lab
               Foundation
└──────────────┴──────────────┴──────────────┴───────┬───────┘
                                                     ↓
                                    P5 Model Delivery + Enrichment
                                        ┌──────────┴──────────┐
                                        ↓                     ↓
                              P6 Meeting Automation   P7 Local Agent/Reflection
                                        └──────────┬──────────┘
                                                   ↓
                         P8 Privacy/Commercial/Release
                                                   ↓
                           P9 Alpha Hardening + v1 RC
```

A9 的安全、恢复、CI、签名和评测工作从 P0 贯穿 P9，不是只在 P8 开始。

### 5.1 可并行矩阵

| 阶段 | 必须先完成 | 可同时运行 | 必须等待 |
|---|---|---|---|
| P0 | 无 | Swift shell、Rust workspace、Visual Lab shell、CI/signing/updater/model-pack skeleton | 跨域 schema/FFI 在各自 skeleton 存在后冻结 |
| P1 | P0 contracts | 单屏 Capture/AX、最小 Vault、单层 Timeline 可分三个 Agent | 最后 vertical slice 集成 |
| P2/P2b/P3/P4 | P1 Gate 与共同 contracts | Capture、Audio Foundation、Vault/Search、Timeline 四条主线并行 | 只在各自 contract 冻结后并行，不宣称完全独立 |
| P5 | P2b audio contract + P3 ingest/index contracts | 模型下载、OCR/ASR/Embedding adapters、enrichment scheduler | 真实模型产出进入 Evidence |
| P6 | P2/P2b + P5 ASR Evidence | 会议 adapters、自动始停、Transcript UI | 端到端会议自动化 |
| P7 | P3 Evidence API + P5 LLM runtime | 内置 loop、CLI/Gateway、Reflection UI | 带引用的完整总结 |
| P8 | 主要功能边界稳定 | license/entitlement、updater、privacy UX、notarization | 发布候选版 |
| P9 | P2–P8 gates | dogfood、stress、recovery、visual polish、docs | RC 只在 blocker 清零后产生 |

---

## 6. 阶段门总览

| Gate | 用户可见结果 | 开放的后续工作 |
|---|---|---|
| G0 Bootstrap | 两个 App target 启动，Swift↔Rust round-trip，CI 绿色 | P1 vertical slice |
| G1 First Memory | 真实截图 + AX 落盘并在 Timeline 打开 | P2/P2b/P3/P4 大规模并行 |
| G2 Reliable Recall | 长时捕获、Vault 恢复、Month→Moment、本地文本检索 | P5 enrichment |
| G3 Searchable Context | OCR/Transcript/Embedding 进入 Evidence，每个结果可回原始时刻 | P6/P7 完整集成 |
| G4 Useful Intelligence | 会议自动记录 + 带引用 Daily Reflection + 受限 CLI | P8 commercial/release |
| G5 Design Partner Alpha | 签名可安装 build，自动更新，20–50 名设计伙伴可日用 | P9 hardening |
| G6 v1 Release | 付费权益、隐私、恢复、性能、分发验收全部通过 | 公开发布 |

---

## 7. P0 — Repository、契约与可重复构建

**目标：** 在任何业务模块扩张前，先得到一套可编译、可测试、可签名、可由多个 Agent 安全并行修改的骨架。

### 7.1 任务

| ID | Owner | 工作 | 依赖 | 可并行 | 完成定义 |
|---|---|---|---|---|---|
| BOOT-001 | A0 | 创建 workspace、Swift packages、Rust workspace、基础目录和 CODEOWNERS | 无 | 起点 | `AfterRay.app` 与 `AfterRayVisualLab.app` 空壳均可启动；Cargo workspace 可编译 |
| BOOT-002 | A0+A5 | 冻结 `MomentV1`、`VisualFrameV1`、`AXSnapshotV1`、`EvidenceV1` 与错误码 | BOOT-001 | BOOT-003/004 | Protobuf/等价 IDL、Swift/Rust golden fixtures、版本规则合并 |
| BOOT-003 | A5 | 建立窄 C ABI、opaque handle、buffer ownership、panic 隔离 | BOOT-001 | BOOT-002/004 | Swift 调用 `core_open/core_close/core_version`；ASan/错误路径通过 |
| BOOT-004 | A9 | 建立 Swift/Rust lint、unit、fixture、archive smoke CI | BOOT-001 | BOOT-002/003 | 每个 PR 有统一必需检查；缓存不影响正确性 |
| BOOT-005 | A1+A9 | 建立 bundle IDs、xcconfig、entitlements、Developer ID archive skeleton | BOOT-001 | BOOT-002/003 | Development 和 Release archive 可生成；release 无调试 entitlement |
| BOOT-006 | A6 | 建立 Design System、Timeline package、MockData 和 Visual Lab 空壳 | BOOT-001 | BOOT-002—005 | Visual Lab 不请求权限；能选择一个确定性 scene |
| BOOT-007 | A0 | 写 ADR 模板、Task Card 模板、branch/worktree 脚本和集成 runbook | BOOT-001 | 其余任务 | 新 Agent 能在 15 分钟内领取任务并跑通验证 |
| BOOT-008 | A4+A9 | 固定 SQLite/SQLCipher/加密库版本与许可证策略 | BOOT-001 | BOOT-002—007 | 版本、编译选项、attribution 与升级策略写入 ADR |
| BOOT-009 | A1+A4 | 冻结 `EntitlementState`、age/space retention、删除回执有限状态模型 | BOOT-002 | BOOT-003—008 | Free/Paid/unknown/offline fixture 可执行，不等待支付接入 |
| BOOT-010 | A7+A9 | model-pack 签名、staging/active/rollback 和 updater feed 最小 spike | BOOT-001 | BOOT-002—009 | 小型测试包与测试 App 更新均能验签、原子切换和回滚 |
| QSR-001 | A9 | 建立 invariant registry 与 threat/permission/process matrix | Spec baseline | 所有 BOOT | 每条 v1 硬约束映射到自动测试或明确 release check |

### 7.2 G0 验收

- 干净 clone 后，一条 bootstrap 命令能准备 Swift/Rust 工具链并构建两个 App target。
- Swift→Rust round-trip 使用真实 release 链接方式，不以测试专用动态库掩盖签名问题。
- schema、database、pack format 分别版本化；未知必需字段明确拒绝，未知可选字段可忽略。
- entitlement、permission、retention、deletion、meeting、model activation 和 Agent scope 均有可执行的有限状态 fixture。
- Visual Lab 只依赖 mock fixtures，不连接真实 Vault、不请求 Screen Recording/Accessibility/Microphone。
- CI 同时检查格式、unit、协议 golden fixture、Rust/Swift link、Release archive smoke。
- Notarization、signed updater 和 signed model-pack 各自至少完成一次小型端到端 smoke；后续只扩充内容，不在 P8 才首次接触签名链。

---

## 8. P1 — 第一条可运行 Memory Vertical Slice

**目标：** 先做一条非常窄、但从真实权限到加密恢复都是真的路径。G1 之前不接 OCR、ASR、Embedding、LLM、会议检测或华丽的 Month Timeline。

```text
启动 App
→ 完成 Screen Recording + Accessibility 授权
→ 菜单栏显示 Ready
→ 获取一张当前屏幕截图
→ 读取前台 focused window 完整 AX Tree
→ 组装同一个 MomentEnvelope
→ Rust 对 AX 独立 zstd、对 payload 加密并提交
→ Debug Timeline 打开该 Moment 与 AX overlay
→ 重启 App
→ 再次打开并用 AX 文字精确搜索到该 Moment
→ 删除后立即不可见、不可检索
```

### 8.1 三条并行 lane

| ID | Owner | 工作 | 依赖 | 完成定义 |
|---|---|---|---|---|
| VS-MAC-001 | A1 | Permission Center 最小状态机、菜单栏 pause/resume、锁屏/唤醒 | G0 | granted/denied/revoked/restart 有确定性测试 |
| VS-CAP-001 | A2 | 单屏 ScreenCaptureKit frame source，输出 monotonic timestamp | G0 | 能捕获完整 frame；错误和 stale frame 不伪装成功 |
| VS-AX-001 | A2 | frontmost App、focused window、完整 AXChildren traversal、secure value 过滤 | G0 | 自包含 Tree；循环安全；1 秒后保存 partial；不阻塞下一 Moment |
| VS-DATA-001 | A4 | SQLCipher metadata、单 `.open` pack、AEAD blob、commit/recover | G0 | DB 无明文；kill/restart 后 committed Moment 可读 |
| VS-DATA-002 | A5 | `ingest_moment/query_timeline/query_search/delete_scope` 最小 FFI | BOOT-002/003 | 请求幂等；Rust panic 不越过 ABI；exact search 可用 |
| VS-UI-001 | A6 | Debug Timeline/Inspector、截图显示、AX bounds overlay | BOOT-006 | 用 mock 和真实 datasource 都能打开同一 UI |
| VS-INT-001 | A0 | 将三条 lane 合为真实 signed build | 上述全部 | 在干净测试账号从授权走到重启检索与删除 |

### 8.2 G1 验收

- 截图、AX Tree、前台 App、focused window 与 monotonic timestamp 属于同一 Moment。
- AX 保存 `complete | partial | unavailable`；只有偏差不超过 2 秒时绑定截图。
- AX 每份完整、自包含、独立 zstd；不引用前一 Snapshot。
- secure text field 不读取 value；bounds 不可靠只标记节点/窗口，不丢截图或整棵 Tree。
- Vault commit 顺序是 blob durable 后 DB 引用；重启恢复可重复执行且幂等。
- 删除事务后 Timeline 和 FTS 立即不再返回，物理空间回收可异步完成。
- 真实签名 build 跑通。若这条路径不成立，暂停 P2–P7 的扩张并修复根因。

---

## 9. P2 — 生产级 Screen Capture 与 Accessibility

**目标：** 将单次捕获升级为能长期后台运行、正确处理多屏和系统生命周期的捕获服务。

| ID | Owner | 工作 | 依赖 | 可并行/备注 | 验收 |
|---|---|---|---|---|---|
| CAP-001 | A2 | ActivitySignal；优先系统 idle-time，只保留内存状态 | G1 | CAP-002 | 不记录键值、点击、轨迹或原始事件；日志不泄露事件 |
| CAP-002 | A2 | 10s heartbeat + trailing settle + continuous-input max-wait + idle 回退 | G1 | CAP-001/003 | 虚拟时钟覆盖 active/idle/burst/pause/backpressure |
| CAP-003 | A2 | `SCStream` 与 hybrid 方案做限时 spike并写 ADR | G1 | 最多 2 个工程日 | 选择一条生产实现；不建立第二套长期路径 |
| CAP-004 | A2 | 多屏 topology epoch、Retina scale、坐标变换、插拔 | VS-CAP/AX | CAP-001—003 | 拓扑变化后旧坐标不套到新屏幕；各屏 frame 可追溯 |
| CAP-005 | A2 | dirty rect/画面变化 gate、latest-frame 合并和 backpressure | CAP-002/003 | CAP-004 | 无变化不重复落相同 blob；队列满有 gap 状态而非静默丢失 |
| CAP-006 | A2+A1 | 锁屏、睡眠、快速用户切换、权限撤销、崩溃 supervisor | CAP-002 | CAP-004/005 | 相应状态立即停止；恢复后不重复提交 |
| AX-101 | A2 | 完整 focused-window AX traversal、批量属性、循环与失效节点处理 | G1 | CAP lane | 无 node cap；1 秒 deadline；partial 内容有效 |
| AX-102 | A2 | Tree schema、bounds、角色、文字、secure-field 状态、压缩输入 | AX-101 | CAP lane | 相同 fixture 跨版本解码；不含 secure value |
| AX-103 | A2+A6 | 截图/AX 2 秒对齐与 overlay datasource | AX-102,CAP-004 | Timeline lane | complete/partial/unavailable/skew 在 UI 可见且不误导 |
| CAP-007 | A1+A2 | 全局快捷键、菜单栏状态、立即暂停/恢复、排除 App/窗口 | CAP-006 | Timeline lane | AfterRay 不形成镜像递归；暂停状态跨重启符合设置 |

不再进行“AX 整棵 Tree 到底耗时多少”的开放研究。测试只验证冻结行为：1 秒截止、可取消、partial 保存、2 秒对齐、不会拖住后续 Moment。

### 9.1 G2-Capture 验收

- 连续运行期间不发生静默停止；每个 gap 有原因与时间范围。
- 多屏插拔、缩放、Spaces、全屏、锁屏、睡眠、权限撤销均有集成 fixture 或真实机用例。
- Capture actor 永不等待 OCR、Embedding、LLM 或 Timeline 渲染。
- 队列压力时保住原始 Moment 元数据与最新画面，enrichment 可以积压但不反向阻塞采集。

---

## 9A. P2b — Audio Foundation

**目标：** 在会议自动检测之前先得到可独立验证的双轨音频基础，为 P5 ASR 提供真实输入，消除 Transcript 的依赖环。P2b 只提供内部手动测试入口，不承诺自动会议体验。

| ID | Owner | 工作 | 依赖 | 可并行 | 验收 |
|---|---|---|---|---|---|
| AUD-FND-001 | A3 | `off/starting/recording/stopping/failure` 双轨状态机与手动 debug trigger | G1 contracts | P2/P3/P4 | 虚拟时钟覆盖重入、取消、失败；production UI 不暴露误导性常驻录音 |
| AUD-FND-002 | A3 | ScreenCaptureKit system audio track，排除 AfterRay 自身音频 | AUD-FND-001 | AUD-FND-003 | 独立 sample stream，monotonic timestamp 可映射到 Moment |
| AUD-FND-003 | A3 | microphone track，不申请 Camera；保留等能力 provider | AUD-FND-001 | AUD-FND-002 | 与 system 分轨；设备切换不崩溃 |
| AUD-FND-004 | A3+A4 | 时钟归一、segment codec、加密 spool、crash finalization | AUD-FND-002/003,P3 ingest contract | P5 runtime skeleton | crash 只损失最后有界 segment；没有未登记明文临时文件 |
| AUD-FND-005 | A4 | raw audio 30 天 retention hook、立即删除和低空间状态 | AUD-FND-004,P3 retention | P5 ASR | 删除由 Vault 唯一执行；ASR 不自行删除文件 |
| AUD-FND-006 | A9 | 权限、无会议不启麦、设备切换、强杀与泄漏 fixture | AUD-FND-001—005 | P2 QA | 未显式 debug trigger 时麦克风关闭；测试产物不含真实用户音频 |

P2b 结束时，ASR Agent 能消费稳定的双轨 segment contract；会议自动开始仍然禁止，直到 P6 的 detector 和用户控制完整接入。

---

## 10. P3 — Encrypted Vault、Search 与 Retention

**目标：** 得到唯一数据真相源。Swift、CLI、Agent 均不能直接打开数据库或 blob pack。

### 10.1 Crate 边界

```text
afterray-types       IDs、时间、Moment/Evidence、纯状态机
afterray-protocol    schema 生成、兼容性 fixtures
afterray-ffi         窄 C ABI、panic/ownership/error boundary
afterray-crypto      AEAD、DEK wrap、zeroize、Keychain broker contract
afterray-pack        append/seal/scan/recover/compact
afterray-store       SQLCipher、migration、job queue、single writer
afterray-vault       pack + DB commit coordinator
afterray-search      FTS5、trigram、候选融合
afterray-vector      exact/ANN backend、generation、rebuild
afterray-retention   age/space/delete state machines
afterray-testkit     synthetic Moment、virtual clock、failpoints
```

### 10.2 并行任务

| ID | Owner | 工作 | 依赖 | 可并行 | 验收 |
|---|---|---|---|---|---|
| VAULT-001 | A4 | Keychain root key broker、SQLCipher DB key、per-blob DEK/AEAD | G1 | PACK/STORE | 普通 SQLite/`strings` 无法读正文；全 Vault 删除先撤销 root key |
| PACK-001 | A4 | `.open` append、fsync、sealed pack、TOC/checksum、orphan recovery | G1 | VAULT/STORE | 每个持久化步骤 failpoint 后重启不丢 committed blob |
| STORE-001 | A4 | schema、single writer、WAL、migration、enrichment job queue | G1 | VAULT/PACK | canonical rows 与索引变更同事务；writer/checkpoint 单一 |
| STORE-002 | A4 | Moment/Frame/AX/Transcript/Evidence 完整 schema | BOOT-002,STORE-001 | SEARCH | 多屏、partial AX、双轨音频、模型版本均可表达 |
| FFI-101 | A5 | 文件描述符/byte slice bulk path、request ID、cancel、错误映射 | G1 | DATA lanes | 大 blob 不经多次复制；重复请求幂等 |
| SEARCH-001 | A5 | FTS5 phrase/prefix/BM25 + trigram + 两字符 fallback | STORE-002 | VECTOR | AX/OCR/Transcript 共用 Evidence ID；中英文 fixture 通过 |
| SEARCH-002 | A5 | typo candidate、Evidence dedupe、Moment/Episode 聚合、scope/filter | SEARCH-001 | VECTOR | exact/substring/typo 的结果与证据一致 |
| VECTOR-001 | A5 | `VectorIndex` contract + exact scan baseline | STORE-002 | SEARCH | 不等待 ANN 就可验证语义 ranking；索引可全量重建 |
| VECTOR-002 | A5 | 对候选 ANN 做限时 contract spike，选定按日/generation 方案 | VECTOR-001 | 最多 3 个工程日 | 模型版本不混写；删除 tombstone 不泄漏结果 |
| RET-001 | A4 | age policy、space policy、persistent watermark、virtual clock | STORE-002 | SEARCH/VECTOR | Free 30 天、Paid 无年龄到期、raw audio 30 天边界准确 |
| RET-002 | A4+A5 | logical delete、key revoke、index tombstone、physical compaction | PACK/SEARCH/VECTOR | MIGRATION | 删除后任何查询入口均不能复活；回收状态可观察 |
| MIG-001 | A4 | DB/pack/protocol 独立版本、N-2/N-1 fixtures、升级/降级保护 | STORE/PACK | RET | 旧 Vault 可升级；旧 App 拒绝写未知新格式 |

### 10.3 必须保持的写入顺序

```text
validate envelope
→ compress where applicable
→ encrypt blob with independent DEK
→ append to .open pack
→ fsync pack bytes
→ one SQL transaction writes blob location + wrapped DEK + Moment + Evidence
→ commit SQL
→ return committed
```

数据库不得先引用未 durable 的 blob。向量索引、缩略图、summary 都是可重建派生数据，不能成为打开 Vault 的前置条件。

### 10.4 G2-Data 验收

- 截图、AX、音频、OCR、Transcript、FTS、WAL、tmp、日志均没有非预期明文副本。
- kill 可以插在 pack append、fsync、SQL commit、seal、rename、compaction 的每一步；重启不出现“DB 指向不存在 blob”。
- 精确、短语、子串、两字符中文 fallback 与 typo lookup 均有可重复 corpus。
- logical delete、密钥撤销、physical reclaim 是三个明确状态，UI 不混用文案。
- 10GB、20GB 和 custom 是空间策略，不是最低硬件门槛；低空间有用户可理解的处理状态。

---

## 11. P4 — Timeline、视觉语言与 Visual Lab

**目标：** 同一套产品代码实现从一整月的“光谱总览”连续进入某一 Moment，并建立可快速迭代、可回归、可用于官网录制的视觉流程。

### 11.1 固定 LOD

```text
Month  →  Day  →  Session  →  Moment
密度       时间块     活动段        原始证据
```

`Session` 只表示视觉时间段；会议域使用 `MeetingEpisode`，避免同名概念污染 schema。

### 11.2 任务

| ID | Owner | 工作 | 依赖 | 可并行 | 验收 |
|---|---|---|---|---|---|
| VIS-001 | A6 | Design tokens：色彩、排版、spacing、motion、material、red-ray shader 参数 | G0 | VIS-002/003 | production 与 Visual Lab 共用同一 token source |
| VIS-002 | A6 | 确定性 MockData：Month/Day/Session/Moment、缺口、会议、partial AX、搜索结果 | G0 | VIS-001/003 | 固定 seed/timezone/locale/scale；不含真实用户数据 |
| VIS-003 | A6 | Visual Lab scene registry、controls、shot scripts、snapshot/视频导出 | G0 | VIS-001/002 | 单命令重放 hero path；App target 不依赖 MockData |
| TL-001 | A6 | TimelineDomain、camera、LOD thresholds、selection、query window | G1 | VIS lane | 连续 zoom 保持 anchor；边界状态可用纯单测验证 |
| TL-002 | A6 | AppKit `NSView` input shell + Metal render surface | TL-001 | MEDIA-001 | trackpad/wheel/drag/keyboard 有统一 interaction model |
| MEDIA-001 | A6 | thumbnail atlas、decode queue、prefetch、memory pressure cache | G1 | TL-001/002 | 渲染热路径不等 Vault、OCR 或模型；低内存可恢复 |
| TL-003 | A6 | Moment filmstrip、Day/Session 聚合、Month density/light field | TL-001/002 | MEDIA | 四层 LOD 使用同一 domain 与 selection |
| TL-004 | A6+A5 | 真实 `TimelineDataSource`、窗口查询、取消和 stale result 保护 | P3 query API | TL-003 | 快速 scrub 时旧请求不会覆盖新 selection |
| TL-005 | A6+A2 | AX overlay、OCR box、Transcript rail、Evidence inspector | AX-103,P3 schema | TL-003/004 | source、confidence、partial/skew 可理解；可关闭 overlay |
| TL-006 | A6 | Month→Moment hero transition、red-ray shader、reduce motion | TL-003 | TL-004/005 | hero scene 与产品路径相同；Reduce Motion 不丢信息 |
| TL-007 | A6+A9 | visual regression、interaction replay、参考设备性能 gate | TL-002—006 | 可与功能收尾并行 | 固定场景无非预期像素/行为漂移 |
| ONB-001 | A1+A6 | onboarding 复用 hero scene，接 Permission Center 状态 | VIS-001,VS-MAC | Timeline | 权限请求前解释价值与用途；返回设置后可继续 |

### 11.3 Timeline 性能门

- 目标 60 fps；参考设备 P95 frame time 不超过 16.7ms，连续交互 dropped frames 不超过 2%。
- 快捷键进入回溯 P95 小于 500ms。
- 已缓存随机 seek 先在 200ms 内显示可辨认缩略图，再在 500ms 内替换高清画面。
- 性能语料、Mac 型号、分辨率、缓存冷热和录制方式固定在 `TIM-PERF-PROFILE-v1`，避免数字失去上下文。

### 11.4 G2-Visual 验收

- Month→Day→Session→Moment 是连续交互，不是四个互不相干页面。
- 任意快速 zoom/scrub 不等待 OCR、ASR、Embedding 或 LLM。
- 缺失、已删除、尚未 enrich、partial AX、模型未安装都有明确视觉状态。
- 官网可直接录制 Visual Lab 中由 production components 组成的 hero shot。

### 11.5 G2 Reliable Recall 联合验收

- 签名 build 连续 8 小时经历锁屏、睡眠、显示器切换、权限撤销/恢复和低磁盘，既不静默停止也不损坏 Vault。
- 使用 30 天确定性合成数据完整跑通 Month→Moment、精确/子串检索、删除 gap 和重启恢复。
- 任一 pack 局部损坏被隔离为可见 gap，不阻止其余 Vault 打开。
- G2 不依赖任何模型安装或推理结果；原始 Memory 和 AX 文本召回先成立。

---

## 12. P5 — Model Delivery 与异步 Enrichment

**目标：** App 安装后按设备能力下载模型包；OCR、ASR、Embedding、LLM 共享资源调度，但各自失败不会破坏原始 Memory。

本计划只固定能力和接口，不冻结具体模型名称；模型选择与版本进入 model manifest 和独立评测记录。

| ID | Owner | 工作 | 依赖 | 可并行 | 验收 |
|---|---|---|---|---|---|
| MODEL-001 | A7 | signed manifest：id/version/license/size/hash/RAM/OS/runtime/capability | G1 | MODEL-002/003 | manifest 可签名验证；不兼容包不会展示或启动 |
| MODEL-002 | A7+A1 | 下载队列、断点续传、磁盘预检、原子安装、回滚、卸载 | MODEL-001 | RUNTIME | 中断/损坏/空间不足均不留下“已安装”假状态 |
| MODEL-003 | A7 | hardware profiler 与能力档位 | G1 | MODEL-001/002 | 只决定推荐和并发，不阻止 10GB/20GB 用户使用基础 App |
| RUNTIME-001 | A7 | 签名 Model Runtime service，无 Python、无 remote code、无网络 | MODEL-001 | 下载 | runtime crash 不带走主 App/Capture；release build 在干净机跑固定 smoke fixtures |
| RUNTIME-002 | A7+A9 | Download/Runtime/Agent Host 进程权限与 IPC caller validation | BOOT-010,RUNTIME-001 | adapters | 最终二进制 entitlement 与设计矩阵一致；跨服务伪造调用被拒绝 |
| ENRICH-001 | A7+A4 | 持久化 job queue、priority、retry、cancel、model version、backfill | P3 store,RUNTIME | adapters | capture first；重启续跑；同 job 幂等 |
| OCR-001 | A7 | 快速屏幕 OCR adapter + boxes/language/confidence | RUNTIME,ENRICH | EMB/ASR | 真实 UI corpus 达到冻结门槛；结果写 Evidence |
| OCR-002 | A7 | Deep OCR/VLM adapter，只处理候选帧与重解析请求 | OCR-001 | EMB/ASR | 不进入每帧热路径；可独立卸载 |
| EMB-001 | A7+A5 | Embedding adapter、batch、dimension/model generation | RUNTIME,ENRICH | OCR/ASR | 新旧向量不混写；全量 rebuild 可中断恢复 |
| ASR-001 | A7 | 双轨 ASR adapter、时间戳/aligner、语言信息 | RUNTIME,ENRICH | OCR/EMB | 音频 fixture 可重复；不无证据编造人名 |
| ASR-002 | A3+A7+A4 | Audio segment→VAD→ASR chunks→幂等 stitch→Transcript Evidence | ASR-001,P2b,P3 | LLM/SCHED | 一小时双轨音频可分块恢复；尾段失败不重跑整场；结果可回原始时间 |
| LLM-001 | A7 | LLM adapter、context budget、structured output、cancel | RUNTIME,ENRICH | OCR/ASR/EMB | 固定 eval 可跑；无 tool 权限时不能访问 Vault |
| SCHED-001 | A7+A2 | GPU/RAM/thermal/电池-aware resource arbiter | adapters | Timeline lane | Capture 与 Timeline 优先；高负载时 enrichment 延迟而非抢占 |
| MODEL-004 | A7+A9 | 许可证/Notice/SBOM、更新兼容性、包撤回 | MODEL-001/002 | 持续 | 每个已发布包可追踪来源并远端禁用新安装，不删除本地用户数据 |

### 12.1 G3 验收

- 全部模型包删除后，截图+AX+FTS 基础产品仍可运行；这不是 ASR 主路径的产品降级，而是用户未安装可选能力包时的清晰状态。
- 模型运行、下载和更新不向模型作者或第三方发送用户内容。
- 下载服务只能接触 catalog/shard/staging；Runtime 和 Agent Host 没有默认网络，任何 Capability Pack 都不含可执行代码。
- OCR/ASR/Embedding/LLM 输出带 model ID/version，能重建或失效。
- Enrichment 失败可见、可重试、可取消，不改变原始 Moment 的 committed 状态。
- 搜索结果至少带 Evidence ID、来源、时间和原始 Moment 跳转。
- OCR、Transcript 和 Embedding 都必须在签名 build 中产生真实 versioned Evidence；ASR 主路径失败则 G3 不通过，不能以移除 Transcript 的“精简版”发布。

---

## 13. P6 — 会议检测与自动始停

**目标：** 在已经通过 P2b/P5 验证的双轨录音与 Transcript 基础上，增加稳定会议检测和自动始停。平时不占用麦克风；在 onboarding 获得总开关同意后，只在确认会议时录音，并立即让用户知情和控制。

| ID | Owner | 工作 | 依赖 | 可并行 | 验收 |
|---|---|---|---|---|---|
| MEET-001 | A3 | evidence contract 与 `possible→confirmed→recording/suppressed→cooldown` | P2 AX/App signals,P2b state machine | adapters | 单一 reducer；信号抖动不重复启动 |
| MEET-002 | A3 | Zoom/Teams/FaceTime adapters | MEET-001 | MEET-003/004 | 多语言、版本差异 fixtures |
| MEET-003 | A3 | 飞书/腾讯会议/企业微信 adapters | MEET-001 | MEET-002/004 | 同上 |
| MEET-004 | A3 | Slack Huddle 与浏览器会议 adapters | MEET-001 | MEET-002/003 | 浏览器运行或单个 tab 标题不足以确认会议 |
| MEET-005 | A3+A1 | 自动始停 orchestrator、通知、菜单栏红色状态、Stop/本次不录 | P2b,MEET adapters | Transcript UI | confirmed 后自动开始；用户可立即停止；cooldown 防重启 |
| TRANS-001 | A3+A7 | 将 P5 Transcript 绑定 MeetingEpisode、speaker class 与会议边界 | ASR-002,MEET-005 | UI | microphone=`self`；system=`remote/unknown`；无证据不命名人物 |
| TRANS-002 | A6 | Transcript rail、会议边界、音频保留和转写状态 UI | TRANS-001,Timeline | — | 可从文本跳回 Moment；清楚显示 raw audio 30 天 |

`confirmed` 不是用户可调的“阈值数字”，而是内部状态：至少一个会议 adapter 给出强证据，或多个相互独立的中等证据在同一 episode 内成立。每个 adapter 的规则由 fixture 固定，通过 ADR 调整。

### 13.1 G4-Meeting 验收

- 受支持会议自动开始和自动结束；误启动和漏启动有可观察指标，但指标不包含正文。
- 麦克风只有在 `recording` 状态打开；菜单栏和通知在同一状态转换立即更新。
- 用户选择“本次不录”后，本 episode 内不会因新信号再次开启。
- 双轨原始音频均加密、均受 30 天策略控制，Transcript 可长期随 Timeline 保留；P2b/P5 的手动测试入口不能绕过 production meeting consent。

---

## 14. P7 — Context Gateway、本地 Agent 与 Daily Reflection

**目标：** 将“记录工具”变成主动帮助用户的本地 Context Layer，同时让权限边界先于第三方集成存在。

| ID | Owner | 工作 | 依赖 | 可并行 | 验收 |
|---|---|---|---|---|---|
| EVID-001 | A5 | 统一 Evidence API：time/app/source/result cap/citation | G3 | GATEWAY/REFLECT | AX/OCR/Transcript 一套返回结构；结果可回 Moment |
| GATE-001 | A8 | Unix socket service、capability hash、scope、expiry、revocation、audit | EVID-001 | CLI/Agent loop | 每次调用重新鉴权；默认 text-only/read-only |
| CLI-001 | A8 | `afterray` CLI client、授权创建/查看/撤销 | GATE-001 | MCP | 不直接读 DB/blob；机器可读 JSON 与人类输出分离 |
| MCP-001 | A8 | stdio MCP adapter：search/get text/get transcript/explain access | GATE-001 | CLI | 无任意 SQL、path、blob 枚举、shell、write tool |
| AGENT-001 | A8+A7 | 轻量本地 loop、四个只读 lookup tools、context/token budget | EVID-001,LLM-001 | Gateway | 无用户目录、无 shell、无默认网络；工具调用均有引用 |
| REF-001 | A8+A6 | 每日目标输入、日末候选总结、证据引用、确认/编辑 | AGENT-001 | CLI/MCP | 每个重要判断链接证据；无法判断时明确说明 |
| REF-002 | A8 | 周复盘聚合、待办候选，不自动执行外部动作 | REF-001 | hardening | 待办必须用户确认；不伪造“已完成” |
| GATE-002 | A1+A6 | 外部 Agent 授权 sheet、范围预览、访问记录、撤销 UI | GATE-001 | CLI/MCP | 用户在发放前看到日期/App/数据种类/截图权限/有效期 |
| AGENT-002 | A9 | prompt injection、scope bypass、citation、删除后访问 eval | AGENT/GATE/REF | 持续 | 越界、被删、过期、撤销 capability 全部拒绝 |

### 14.1 G4-Agent 验收

- 内置 Agent 的任何结论都能返回 Evidence 引用或明确标记为推断。
- 外部 Agent 默认只能获得文本；截图需要单独 scope，永不获得 Vault 文件路径。
- capability 撤销和 Evidence 删除立即影响下一次调用。
- Daily Reflection 在模型离线、被取消、context 不足时保持可恢复状态，不生成无来源结论。

---

## 15. P8 — Onboarding、权益、隐私控制与分发

**目标：** 把完整能力做成可以交给设计伙伴安装、理解、信任和更新的产品。

| ID | Owner | 工作 | 依赖 | 可并行 | 验收 |
|---|---|---|---|---|---|
| ONB-101 | A1+A6 | 一次 onboarding：价值演示→权限说明→逐项系统授权→模型包→完成 | G2 visual,capture | ENT/REL | 每一步可恢复；系统弹窗只能逐个出现，产品流程一次完成 |
| ONB-102 | A1 | Permission Center 常驻页、权限撤销/修复/系统设置返回 | ONB-101 | REL | 实际系统状态是唯一真相；缺 Required 权限时停止真实捕获 |
| ENT-001 | A1+A4 | entitlement contract：Free 30 天、Paid 无年龄到期 | P3 retention | Billing 可后接 | 无付费服务时也能用 fixture 模拟并验证两个状态 |
| ENT-002 | A1 | 购买/恢复购买 provider 抽象与权益缓存 | ENT-001 | REL | 离线宽限、失效、恢复有明确状态；不影响 Vault 可读性 |
| PRIV-001 | A1+A9 | Privacy dashboard：捕获/音频/模型/磁盘/Agent grants/audit | P2—P7 | REL | 用户能解释“现在采什么、为什么、保存多久、谁能读” |
| PRIV-002 | A4+A1 | 按时间/App/Episode 删除、全 Vault 删除、export、回收状态 | P3 APIs | PRIV-001 | 删除语义精确；export 不留下未跟踪明文临时文件 |
| REL-001 | A9 | 冻结 executable/entitlements、Hardened Runtime、嵌套 binary 签名 | target 图稳定 | REL-002/003 | 无多余 entitlement、无 `get-task-allow`、无 ad-hoc nested binary |
| REL-002 | A9 | archive→DMG/ZIP→notarytool→staple→verify 自动化 | BOOT-005 | REL-001/003 | 一条 release 命令产生可验证 artifact 与 checksum |
| REL-003 | A9 | 签名 update feed、增量/完整更新、rollback | BOOT-005 | REL-001/002 | 验签失败拒装；上一可用版本可恢复；Vault 不降级写坏 |
| REL-004 | A9 | clean-machine 安装、升级、权限保留/撤销、卸载 runbook | REL-001—003 | PRIV | 从未装过 AfterRay 的 Mac 上全流程通过 |
| LEGAL-001 | A9 | 第三方库/模型/字体/素材 Notice、SBOM、隐私与录音提示审查 | P5 catalog | REL | 每个 shipped artifact 可追溯许可证和来源 |

说明：付费服务商和最终 checkout 可以后置，但 Free/Paid 数据语义必须在 v1 数据层实现并测试，不能等商业接入时临时改 retention。

### 15.1 G5 验收

- 设计伙伴拿到一个经签名、Notarization、可自动更新的构建，不需要 Xcode、Python、Homebrew 或命令行。
- onboarding 一条路径完成所有授权与选择；macOS 必须逐项弹出系统权限框，但不要求用户日后重新寻找入口。
- 模型按需下载，失败不破坏 App；每个包可暂停、继续、校验、卸载和回滚。
- 权限、录音、数据保留、Agent scope 和磁盘占用在产品内可见、可控制。

---

## 16. P9 — Alpha Hardening 与 v1 Release Candidate

### 16.1 持续质量 lane

| ID | Owner | 开始点 | 工作 | Release blocking 标准 |
|---|---|---|---|---|
| QA-001 | A9 | G0 | unit/contract/golden/fixture coverage | 所有状态机和协议边界有确定性测试 |
| QA-002 | A9+A4 | G1 | fsync/commit/rename/compaction failpoint + kill recovery | committed Moment 不指向缺失 blob；删除内容不复活 |
| QA-003 | A9+A2 | G1 | 权限、锁屏、睡眠、用户切换、多屏、磁盘满 | 无静默捕获、静默停机或数据结构损坏 |
| QA-004 | A9+A6 | G1 | Visual Lab snapshots、interaction replay、Timeline perf | hero path 稳定；性能门通过 |
| QA-005 | A9+A7 | G3 | OCR/ASR/search/agent 固定 corpus 与版本回归 | shipped model 对冻结 corpus 达标；版本变化可解释 |
| QA-006 | A9+A8 | G4 | capability/prompt injection/scope/delete/access log | 无越权、无删除后泄漏、无 raw Vault 绕过 |
| QA-007 | A9 | G5 | clean-machine、update/rollback、notarization、license | 分发链完整；失败可恢复 |
| QA-008 | A0+A9 | G5 | 7 天 design-partner dogfood 与 blocker triage | 无 P0/P1 blocker；后台静默失败为 0 |

### 16.2 测试层次

1. **Pure unit**：scheduler、meeting reducer、retention、scope、LOD、ranking，全部使用虚拟时钟。
2. **Contract/golden**：Swift↔Rust schema、FFI ownership、pack header、AX zstd、model manifest、Gateway response。
3. **Component**：每个 package/crate 用 fake system/Vault/runtime 验证失败和取消。
4. **Integration**：真实 ScreenCaptureKit/AX/Audio → Vault → Search → Timeline；在专用测试 Mac 跑。
5. **Recovery/property/fuzz**：pack/parser/FFI/query/migration、磁盘满、截断、随机重复提交与删除。
6. **Visual/performance**：Visual Lab 固定数据、交互 replay、Metal frame capture、冷热 cache profile。
7. **Clean-machine/release**：首次安装、权限、模型下载、升级、回滚、卸载和 Gatekeeper。
8. **Dogfood**：长时间真实使用，只上传用户明确同意的去内容化健康指标与手工 bug report。

### 16.3 G6 Release 判定

- 所有 G0–G5 验收项通过，未关闭的 issue 只有明确接受的 P2/P3 非阻塞项。
- 7 天连续 dogfood 没有 Vault corruption、隐私越界、无提示录音、删除内容复活或静默停止。
- 参考设备上的 Timeline、capture 资源预算和本地模型运行满足冻结 profile。
- Release artifact、update feed、manifest、SBOM、Notice、checksum 和 rollback 包全部归档。
- 发布版本的 schema/DB/pack/model manifest 版本冻结，并生成下一版本 migration fixture。

---

## 17. Agent 调度：10 个角色，4 并发槽位

角色保持稳定，执行按 wave 轮换。A0 始终占一个集成槽，剩余三个槽优先给 critical path；研究 Agent 完成 ADR 后立即退出，不长期占槽。

| Wave | 并行 Agent | 主要输出 | 退出条件 |
|---|---|---|---|
| W0 Bootstrap | A0、A1、A4、A6 | workspace、App shells、Rust skeleton、Visual Lab | G0 |
| W1 First Memory | A0、A2、A4/A5、A6 | Capture+AX、最小加密 Vault/FTS、Debug Timeline | G1 |
| W2A 基础主线 | A0、A2、A3、A4 | production capture、Audio Foundation、pack/store | 各自 contract tests 通过 |
| W2B Recall 主线 | A0、A5、A6、A9 | Search/Vector、Timeline renderer、持续恢复/隐私测试 | G2 |
| W3 Enrichment | A0、A5、A7、A9 | model delivery/runtime、OCR/ASR/Embedding、搜索评测 | G3 |
| W4 Context | A0、A3、A7、A8 | Audio/Meeting、OCR/ASR、Gateway/Agent/Reflection | G3/G4 |
| W5 Productization | A0、A1、A6、A9 | onboarding、privacy、entitlement、visual polish、release | G5 |
| W6 RC | A0、A4、A7、A9 | corruption/model/update fixes、dogfood、RC | G6 |

如果可用并发升至 10，可让 A1–A9 常驻，但以下工作仍不得并行改同一所有权：

- 只有 A0 修改 workspace/CI required checks 和跨域 schema 入口。
- 只有 A4 编写 DB migration、pack format 和 commit ordering。
- 只有 A6 改 Timeline renderer 核心与 Visual Lab scene schema。
- 只有 A7 改 model manifest/runtime ABI。
- 只有 A9 生成 release artifact、签名 feed 和发布 checklist。

### 17.1 每日集成节奏

1. 09:30 A0 发布当天可领取 Task Cards 与冻结依赖。
2. Agent 先同步基线、运行目标模块测试，再开始修改。
3. 中午前提交接口变更；跨域协议变更当天只合一个版本。
4. 每个 Agent 在 PR 前运行自己的验证命令，并附 fixture/截图/trace。
5. A0 每天下午通过 merge queue 把已绿 PR 合到 `main`，运行 current vertical slice 并产出可安装构建。
6. 未通过集成的 PR 当天回到原 owner，不把修复债务转给下一 wave。
7. 每日结束更新 Gate checklist、风险和下一批已解锁任务。

### 17.2 合并顺序

```text
schema/trait PR
→ owner implementations in parallel
→ contract/golden tests
→ vertical-slice integration PR
→ stage gate
→ next dependent tasks
```

不允许三条 lane 各自开发数周后一次性合并，也不允许多个 Agent 同时手改 `.xcodeproj`、同一 migration 或同一 shader core。

---

## 18. 关键路径、估算与里程碑

以下是 10 个稳定角色、实际 4 个并发槽位下的规划区间。它是排程预算，不是承诺日期；每个 Gate 结束后基于真实吞吐重估。

| 里程碑 | 预计累计时间 | 关键路径 |
|---|---:|---|
| G0 Bootstrap | 1–2 周 | workspace → schema/FFI → signed archive smoke |
| G1 First Memory | 3–4 周 | Permission/Capture/AX → Vault commit/recover → Debug Timeline |
| G2 Reliable Recall | 7–10 周 | production capture + encrypted store/search + Month→Moment |
| G3 Searchable Context | 10–14 周 | model delivery/runtime → OCR/Embedding/ASR Evidence |
| G4 Useful Intelligence | 13–18 周 | meeting/audio + Gateway/Agent + Daily Reflection |
| G5 Design Partner Alpha | 16–22 周 | onboarding/privacy/update/notarization + clean machine |
| G6 v1 Release | 26–34 周 | 至少 30 天 Alpha → recovery/security/perf fixes → 7 天 RC dogfood |

真正的 critical path 是：

```text
schema/FFI
→ real Screen + full AX Moment
→ crash-safe encrypted Vault
→ production Timeline datasource
→ signed model runtime + Evidence
→ meeting/ASR and cited Reflection
→ privacy/update/notarization
→ 7-day dogfood
```

增加 Agent 主要能加速会议 adapters、Visual Lab scenes、corpus、模型 adapters 和测试；不能线性加速 schema、Vault commit ordering、Timeline renderer core、签名链和最终集成。

---

## 19. 前 72 小时启动清单

### Day 1

- A0 创建 workspace、ownership map、Task Card/ADR 模板和 required checks。
- A1 创建两个 App target 与最小 menu bar shell。
- A4 创建 Rust workspace，验证 SQLCipher/crypto 最小链接。
- A6 创建 DesignSystem/Timeline/MockData/VisualLab package skeleton。

### Day 2

- A0+A5 冻结 Moment/Frame/AX/Evidence v1 schema 和 golden fixtures。
- A5 建 `core_open/core_close/core_version` C ABI。
- A9 建 Swift/Rust CI、Release archive smoke、secret-free logging rules。
- A1 冻结权限状态模型；A6 交付第一个 mock Moment scene。

### Day 3

- Swift 调用真实 Rust XCFramework 完成 round-trip。
- Visual Lab 跑通固定 scene 与 snapshot。
- Development/Release 配置均编译，签名 skeleton 不含错误 entitlement。
- A0 召开 G0 review，只开放 VS-MAC/VS-CAP/VS-DATA/VS-UI 四张 Task Card。

---

## 20. 风险登记与预设处置

| 风险 | 早期信号 | Owner | 预设处置 |
|---|---|---|---|
| AX 在部分 App 返回失败/partial | `kAXErrorCannotComplete`、节点失效 | A2 | 保存 partial/unavailable 和截图，不阻塞下一 Moment；持续补 adapter/fixture |
| ScreenCaptureKit/音频 API 在 macOS 26 变化 | SDK beta diff、设备切换失败 | A2/A3 | 隔离 provider contract；麦克风保留 AVAudioEngine 等能力备用实现 |
| Vault 跨文件提交损坏 | DB 引用缺 blob、orphan 增长 | A4 | blob-first durable ordering、single writer、failpoint recovery |
| 加密/搜索导致明文旁路 | WAL/tmp/log/crash report 命中正文 | A4/A9 | leak scan 设为 release blocker；禁止 CLI/Model 直接读文件 |
| Timeline 为视觉牺牲响应 | scrub 等 I/O/模型、GPU hitch | A6 | 预计算 LOD、thumbnail-first、取消 stale request、冻结 perf profile |
| 模型包不成熟或许可变化 | runtime crash、manifest 撤回 | A7/A9 | signed catalog、可撤回新安装、版本固定、能力 adapter 可替换 |
| 会议误录/漏录 | adapter 信号漂移、版本/语言变化 | A3 | evidence reducer + fixtures + 可见通知 + 本次 suppress；不以常开麦克风兜底 |
| Agent 越权读取 | scope 绕过、prompt injection | A8/A9 | Gateway 单入口、每次重新鉴权、text-only default、删除/撤销实时生效 |
| Free retention 与空间冲突 | 30 天前先达到 cap | A4/A1 | 由待决产品规则决定；实现必须显示预测和处理状态，不静默删/停 |
| 多 Agent 合并冲突 | 同一工程/迁移/schema 多人修改 | A0 | 单 owner、先 contract PR、worktree、每日 integration |
| 发布包无法通过 Gatekeeper | nested binary/entitlement/signing 错 | A9 | 从 G0 做 archive smoke；G5 前 clean-machine 常态化 |

---

## 21. 尚未冻结、但不阻塞 G0/G1 的问题

以下问题不能由 Agent 静默决定。它们有明确最晚决策点；在此前使用接口抽象或 fixture 继续推进。

| 决策 | 最晚时间 | 默认实现准备 | 需要产品负责人确认 |
|---|---|---|---|
| Free 用户 30 天内先碰到空间 cap | RET-001 合并前 | `SpacePolicy` 同时支持“删最旧”和“暂停” | 选择默认行为与文案 |
| Free 收藏是否越过 30 天 | RET-001 合并前 | 收藏与 retention 分离建模 | 是否允许免费永久 pinned |
| Paid 取消后历史如何处理 | ENT-001 合并前 | 支持 grace/read-only/重新进入 Free cutoff | 宽限期与删除规则 |
| 默认 10GB/20GB/custom 初始值 | onboarding storage 页冻结前 | 容量选择器与预测接口 | 推荐值及自动增长策略 |
| raw audio 在空间 cap 前先满 | RET-001 合并前 | audio 与 Timeline 分账并支持“提前删/暂停录音” | 选择默认行为和警告时机 |
| Keychain root key 丢失或重置 | VAULT-001 合并前 | 默认 fail-closed，不建立后门恢复 | 是否提供用户主动创建的 recovery export |
| Screen stream 最终实现 | CAP-003 后 | 同一 `ScreenFrameSource` | 接受 ADR 结论 |
| Input Monitoring 是否必要 | CAP-001 后 | 默认不申请 | idle-time 信号不足时是否新增权限 |
| 默认捕获所有显示器或焦点显示器 | CAP-004 前 | topology schema 同时支持两者 | 默认值与 onboarding 文案 |
| 是否默认保存截图瞬间光标点 | CAP-004 前 | 字段 optional，默认不写 | 找回价值与隐私感受取舍 |
| 音频 codec/container | AUD-FND-004 前 | `AudioSegmentCodec` 抽象 | 结合容量/恢复测试确认 |
| 第一批受支持会议 App | MEET adapters 开始前 | adapter registry | 按目标用户排序 |
| Model capability pack 组合 | MODEL-001 前 | manifest 支持独立/组合包 | onboarding 展示几个选项 |
| DMG 或 ZIP、updater provider | REL-002 前 | release pipeline 抽象 | 最终下载/升级体验 |
| 购买渠道与 entitlement provider | ENT-002 前 | provider protocol | 官网 checkout/许可证服务选择 |
| 诊断反馈路径 | G5 前 | 默认完全本地、用户预览后手动导出 | 是否提供显式 opt-in 上传及保留期 |
| 地区性会议录音提示 | G5 前 | onboarding 与首次自动录音说明用户责任 | 首发地区和法务文案 |

这些问题之外，OCR/ASR/Embedding/LLM 的具体候选继续留在独立评测记录和对话决策中，不写死在本实现计划。

---

## 22. Task 完成与阶段交接标准

### 22.1 单个 Task Done

- 只修改约定所有权内文件；跨域变更有 owner approval。
- acceptance criteria 全部可由命令、fixture、截图或可重复手测证明。
- 正常、取消、权限拒绝、资源不足和失败路径都有覆盖。
- 新增数据字段有版本、migration/兼容性说明和删除语义。
- 新增权限、网络、日志、临时文件或第三方代码已在 PR 中显式列出。
- 不引入未登记的 fallback、遥测、云服务、自动外部动作或长期研究分支。
- 文档、runbook 和 Visual Lab scene 与实现同步。

### 22.2 阶段 Gate Review

A0 为每个 Gate 建一份 checklist，A9 提供独立验证结果。只有满足以下条件才通过：

1. 用户可见 vertical slice 可在 `main` 的可安装构建中完整演示。
2. 必需 CI 与真实机用例绿色。
3. 数据/权限/网络差异已审计。
4. 新风险有 owner、早期信号和处置。
5. 下一阶段依赖接口已冻结。
6. 未完成项明确延期，不能用“后续优化”掩盖 v1 硬条件。

### 22.3 缺陷等级

- **S0，不可豁免：** 隐私越界、错误录音、删除后仍可访问、Vault 损坏、签名/更新绕过、远程代码或密钥泄漏。
- **S1，公开发布不可豁免：** onboarding、捕获、回看、搜索、会议、更新任一核心路径不可完成或高频崩溃。
- **S2：** 有明确可见状态，且不损害数据、隐私和核心证据；只能由产品负责人书面接受延期。
- **S3：** 不影响正确性的视觉或文案问题。

---

## 23. 计划维护规则

- 本文件是实现计划唯一入口；产品行为以 `docs/afterray-v1-spec.md` 为准。
- 阶段状态使用 `Not started | In progress | Blocked | Passed`，并记录负责人、日期和证据链接。
- Task 拆分或顺序变化可直接更新；冻结产品边界变化必须附 Decision Record。
- 每个 Gate 后更新真实周期、缺陷密度和下一阶段估算，不保留已经失真的日期。
- 发布后仍保留本计划作为 v1 migration、恢复和安全审计的索引。

### 23.1 当前状态

| 项目 | 状态 | 证据 |
|---|---|---|
| Product Spec baseline | Passed | commit `608c4c9` |
| P0 Repository | Not started | 待 BOOT-001 |
| P1 First Memory | Not started | 等待 G0 |
| P2–P9 | Not started | 按依赖图解锁 |
