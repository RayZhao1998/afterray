**Verdict**

这份设计现在还不能按文档里的 PR 顺序推进到产品代码。主要问题不是“想法不够好”，而是它把几件还没被代码证明的事，当成了可分阶段上线的前提，尤其是 `PR 0`、`PR 4`、`PR 7`、`PR 8`。按当前代码看，最可能的结果是：锁屏行为先出回归，Recall 时间轴先出错误显示，随后再被协议和解码链卡住。

**Critical**

1. `PR 0` 的“锁屏停捕获，不停 daemon + 时间轴 idle gap”不是增量改动，文档低估了现有行为耦合，先做很容易直接改坏产品。
设计节：`锁屏 / 休眠：停捕获，不停 daemon`、`PR 0 — 锁屏停捕获 + 时间轴 idle gap`。
真实代码里，锁屏现在不是“停 shim”，而是直接 `stop()` 整个 daemon：[`DaemonSupervisor.suspendForSystemLock()`](</Users/zxch3n/Code/afterray/apps/AfterRay/Sources/DaemonSupervisor.swift:212>) 调 [`stop()`](</Users/zxch3n/Code/afterray/apps/AfterRay/Sources/DaemonSupervisor.swift:215>)，而 `AfterRayApp` 还在每秒拉活 daemon：[`keepDaemonAlive()`](</Users/zxch3n/Code/afterray/apps/AfterRay/Sources/AfterRayApp.swift:892>)。同时 Recall 的“锁屏后清空画面”依赖的是 UI 侧直接清状态：[`clearSensitiveState()` 调用链](</Users/zxch3n/Code/afterray/apps/AfterRay/Sources/AfterRayApp.swift:847>)。你文档里要求 PR 0 同时改成“daemon 继续活着、时间轴出现 gap、playhead 在 gap 返回 nil”，但当前时间轴根本没有 gap 模型，[`TimelineLayout.makeRuns`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/TimelineLayout.swift:170>) 只按 app 切段，[`RecallPlayhead.resolveIndex`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/TimelineLayout.swift:202>) 永远取“最后一个 <= playhead 的 moment”。这不是一个安全的“先做锁屏、后做 GOP”的独立 PR。

2. `PR 4` 把 AV1 冷路径当成“只做 fixture 的技术验证”，但代码里的显示栈没有任何 GOP 入口，验不过也无法判断 PR 7 是否真能成立。
设计节：`RecallAV1Decoder（PR 4，只对 fixture）`、`PR 4 — Recall AV1 VT，只打 fixture`。
真实代码里，Recall 只有两条路径：JPEG 走 [`RecallJPEGDecoder`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallYUVDisplay.swift:239>)，非 JPEG 一律掉到 [`decodeWithImageIO`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallYUVDisplay.swift:232>)。也就是说，今天不是“冷路径还没接产品”，而是“任何 `DKIF`/IVF 数据都会被错误送去 ImageIO”。同时主画面只认 [`selectedMoment.imageArtifactId`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallView.swift:107>)，prefetch 也只拉这一个 id：[`prefetchAroundSelection()`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallView.swift:360>)。所以 PR 4 即使本地 fixture 解出来，也没有证明“PR 7 的 FrameRef 策略可接到真实产品流里”，因为当前产品流根本没有 segment/index 的读模型。

3. `PR 8` 之前把 `image_artifact_id` 保持必填是对的，但文档同时又安排了 `PR 2/7` 先把 GOP 读模型加进协议和 UI；这会制造一个长期“写得出、读不到、线上无法覆盖验证”的死区。
设计节：`生命周期`、`API / Interface Changes`、`PR 2`、`PR 7`、`PR 8`。
今天的协议和客户端都硬编码 `image_artifact_id` 必填：Rust [`Moment.image_artifact_id: String`](</Users/zxch3n/Code/afterray/crates/afterray-protocol/src/lib.rs:141>)，Swift [`RecallMoment.imageArtifactId: String`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallModels.swift:25>)，客户端还要求协议版本精确相等：[`version == 2`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/DaemonClient.swift:154>)。文档自己也承认 Dual 期 Recall “继续只读 `image_artifact_id`，不走 GOP 解码”。这意味着 `PR 7` 在真实数据上基本不可验，只能靠 fixture 或“强制无 still 的测试行”。这对播放器策略可以接受，但对上线顺序不安全，因为一旦 PR 6 写入了真实 GOP 元数据，却没有真实 UI 消费路径，你观察不到最重要的生产问题：协议演进、缓存行为、真实时序。

**Major**

1. 文档对锁屏问题的根因判断有一半是推断，不是代码事实。
设计节：`锁屏 / 休眠：停捕获，不停 daemon`。
代码里确实只监听了 [`sessionDidResignActive` / `screensDidSleep` / `willSleep`](</Users/zxch3n/Code/afterray/apps/AfterRay/Sources/AfterRayApp.swift:101>)，这支持“`Ctrl+Cmd+Q` 可能漏”的判断；但文档进一步断言“`screenIsLocked` 之后最多再漏 1 帧”，这个在当前代码里完全没有证据，因为 capture 调度是固定 interval：[`AFTERRAY_CAPTURE_INTERVAL_SECONDS` 默认 10 秒](</Users/zxch3n/Code/afterray/crates/afterrayd/src/main.rs:109>)，shim 的一次截图和 AX 抓取是串行做的：[`captureScreen`](</Users/zxch3n/Code/afterray/apps/AfterRayCaptureShim/Sources/AfterRayCaptureShim/main.swift:564>)。现在没有任何现成指标能证明“最多 1 帧”。

2. 文档把 `jobs` 表“不得复用”说得很绝对，这点方向对，但它没有正视当前 daemon 根本没有 packer 生命周期容器。
设计节：`Background & Motivation`、`PR 6`。
代码中 `jobs` 表确实只是 schema 残留，模型任务走内存 [`ModelQueue`](</Users/zxch3n/Code/afterray/crates/afterrayd/src/main.rs:96>)，`JobsList` 也是读内存：[`Request::JobsList => state.models.list()`](</Users/zxch3n/Code/afterray/crates/afterrayd/src/main.rs:350>)。但文档提出 `gop_pack_jobs + JoinHandle watchdog + 启动恢复`，这要求 daemon 先有长期后台 worker 框架。当前 `afterrayd` 只有 capture scheduler、event consumer、model wait；没有任何类似 pack loop 的基础设施。也就是说，问题不只是“别复用旧表”，而是 PR 6 的工作量和风险被明显写小了。

3. 延迟预算里最关键的“冷拖拽 poster / settle exact”没有被当前接口大小和缓存策略证明。
设计节：`Recall 解码、playhead 与 prefetch`、`Observability`。
Swift 端现在 `exchangeArtifact` 允许单个 artifact 到 64 MiB：[`meta.byteLength <= 64 * 1024 * 1024`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/DaemonClient.swift:225>)；文档建议图像路径降到 8 MiB，但这还没在代码里存在。更重要的是，当前编码字节缓存是按 artifact id 的 [`NSCache` 128 / 512MB](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallStore.swift:176>)，解码缓存是另一层 [`48 / 1.5GB`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallView.swift:418>)。文档假设“按 segment 合并 prefetch、最多 16 段 encoded cache、2 个 VT session”，但现有实现完全没有对应结构，现有缓存淘汰策略也没证明能承受 segment 级数据。

4. 存储收益口径前后虽有自我修正，但仍把“Dual 可安全观察”说得过于轻松。
设计节：`Overview`、`存储模型`。
文档前面明确说 PR 0–7 `KEEP_STILLS=1` 时“磁盘只增不减”，后面也承认本机整库可能从 1892 MiB 涨到 1960 MiB。这是对的。但代码里 retention 是每次 `insert_moment()` 都同步触发的：[`insert_moment` -> `enforce_retention()`](</Users/zxch3n/Code/afterray/crates/afterray-store/src/lib.rs:518>)，而 `enforce_retention()` 今天会直接删旧 moment 和 artifact：[`DELETE FROM moments` / `DELETE FROM artifacts`](</Users/zxch3n/Code/afterray/crates/afterray-store/src/lib.rs:1086>)。也就是说，Dual 期不是单纯“多存一份看看”，而是“在老的 retention 机制上叠新引用关系”。这比文档表达的风险更高。

5. `FavoriteSet` 的设计目标和当前 UI/daemon 语义差得太远，不能只放到 PR 8 再补。
设计节：`Favorites`、`PR 8`。
今天后端收藏就是同步改位：[`Vault::set_favorite`](</Users/zxch3n/Code/afterray/crates/afterray-store/src/lib.rs:678>)，daemon 直接返回 `{moment_id, is_favorite}`：[`dispatch(Request::FavoriteSet)`](</Users/zxch3n/Code/afterray/crates/afterrayd/src/main.rs:334>)，前端还是乐观翻转：[`RecallStore.toggleFavorite()`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallStore.swift:135>)。文档要把它改成“可能异步抽帧、可能 extracting、成功体要带最新读模型”，这其实会改动整个交互语义，不只是“PR 8 才允许 still 为空”。如果等到 schema 7 再一起做，风险会集中爆发。

**Minor/nit**

1. 文档说 `insert_moment` “额外解析 JPEG SOF，写入 width/height（不解码像素）”，这和当前 [`insert_moment`](</Users/zxch3n/Code/afterray/crates/afterray-store/src/lib.rs:518>) 的职责差别很大，建议在文档里直接承认这是热路径改动，不要写得像顺手补字段。

2. `ReadArtifact` “若 id 指向 GOP artifact 则整段 IVF（仅 CLI / 调试）”这个约定容易误伤，因为今天 daemon 根本没有 artifact kind 隔离，只有通用 [`read_artifact`](</Users/zxch3n/Code/afterray/crates/afterray-store/src/lib.rs:861>)。如果以后有人把 GOP id 误传给旧显示路径，现象会很差。

3. `PR 5` 要求“pack 6、retention index 2、decode index 5 成功”，但当前仓库里并没有任何 segment 级解码测试支架，现有 Recall 测试基本只覆盖时间轴映射和 JPEG 显示，例如 [`TimelineLayoutTests`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Tests/TimelineLayoutTests.swift:4>)。这个测试成本被文档写轻了。

4. 文档最后一行 `Auth 不变：Swift 不持钥。锁屏停 daemon，packer 一并消失。` 和上文“锁屏不停 daemon”自相矛盾。前文设计要改成不停 daemon，这里却写回了旧模型，内部不一致。

**What still holds**

1. `image_artifact_id` 在 Dual 期保持 `NOT NULL` 是对的，这和当前 store/protocol/Swift 三层实现一致，也避免了 `timeline_list` 在版本 2 下直接炸掉。见 [`moments.image_artifact_id TEXT NOT NULL`](</Users/zxch3n/Code/afterray/crates/afterray-store/src/lib.rs:1300>)、[`Moment.image_artifact_id: String`](</Users/zxch3n/Code/afterray/crates/afterray-protocol/src/lib.rs:141>)、[`UnixSocketDaemonClient.protocolVersion = 2`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/DaemonClient.swift:44>)。

2. “不要重新引入 `bytes_base64`，继续 framed header + raw bytes”是对的。当前 daemon 就是 [`write_artifact_response`](</Users/zxch3n/Code/afterray/crates/afterrayd/src/main.rs:277>)，协议也明确了 [`ArtifactPayload::header_line()`](</Users/zxch3n/Code/afterray/crates/afterray-protocol/src/lib.rs:196>) 这条路径。

3. “capture shim 继续薄，编码不要进 10 秒热路径”是对的。当前 shim 只负责截图、JPEG 落 staging、顺手抓 AX：[`captureScreen`](</Users/zxch3n/Code/afterray/apps/AfterRayCaptureShim/Sources/AfterRayCaptureShim/main.swift:564>)。如果把 rav1e 塞进去，风险会非常高。

4. “不要复用 `jobs` 表承载 packer 状态”也是对的。当前 `jobs` 表和 daemon 处理路径明显是模型任务语义，不适合视频归档状态机。见 schema [`jobs`](</Users/zxch3n/Code/afterray/crates/afterray-store/src/lib.rs:1337>) 和 daemon [`Request::JobsList`](</Users/zxch3n/Code/afterray/crates/afterrayd/src/main.rs:350>)。

5. 文档对 Recall 当前限制的判断基本准确：主画面只按 [`moment.imageArtifactId`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallView.swift:107>) 取图，prefetch 也是按这个 id 展开：[`prefetchAroundSelection`](</Users/zxch3n/Code/afterray/swift/AfterRayRecall/Sources/RecallView.swift:360>)。所以如果以后真要做 GOP，必须先改读模型，而不是偷偷把 GOP artifact 塞到旧字段里。