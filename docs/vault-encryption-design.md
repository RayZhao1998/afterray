# AfterRay Vault 加密设计

> 状态：Accepted  
> 决策日期：2026-08-13  
> 适用范围：V0 及后续桌面版本

## 1. 决策

AfterRay 的正式产品采用应用级静态加密，FileVault 只作为额外的设备级保护，不能替代 AfterRay 自己的加密层。

Vault 分成两类数据，并分别处理：

- Metadata、OCR、Transcript、全文索引和其他结构化记录保存在 SQLCipher 数据库中。
- 截图、音频和其他大型 artifact 独立保存；每个 artifact 都使用带认证的加密算法加密，不使用一个巨大的加密容器。

Swift UI 不直接读取数据库、artifact 文件或密钥。Rust daemon 是 Vault 的唯一所有者，负责加密、解密、查询、保留策略和删除；UI 只通过有版本的本地 IPC 获取必要的 read model 或当前需要展示的解密结果。

## 2. 密钥结构

每个 Vault 使用一个随机生成的主密钥。主密钥由 macOS Keychain 保存，使用 `ThisDeviceOnly` 类型的保护，默认不随普通系统备份迁移到其他设备。

正式版本中，每个 artifact 使用独立随机数据密钥（DEK）：

1. artifact 内容使用 DEK 和 AEAD 加密。
2. DEK 由 Vault 主密钥包裹后保存。
3. immutable metadata（artifact id、类型、版本等）作为 authenticated data 参与校验，防止密文被替换到错误记录。

数据库由从 Vault 主密钥派生的独立数据库密钥保护。数据库密钥和 artifact 加密密钥必须使用不同的派生上下文，不能直接复用同一段 key bytes。

V0 当前允许先使用单一 Vault key 配合每个 artifact 的唯一 nonce 完成独立 AEAD 加密；在对外发布前必须升级为 wrapped per-artifact DEK。该升级不能改变 Swift/Rust 的所有权边界。

## 3. 算法与文件组织

- 数据库：SQLCipher。
- artifact：XChaCha20-Poly1305，或经过安全评审后等价的 AEAD。
- 文件粒度：一张截图或一个有界音频 segment 对应一个独立密文 artifact。
- 禁止把所有媒体放进一个需要整体解密或整体重写的大容器。
- nonce 必须对同一密钥保持唯一；随机数必须来自系统安全随机源。
- artifact header 必须带格式版本，便于后续迁移算法或密钥结构。

独立 artifact 的结构符合 Timeline 的随机访问方式：回溯时只读取和解密当前帧及少量相邻帧，收藏或删除某条记录也不需要重写全部历史。

## 4. 运行时规则

- 用户登录且设备已解锁时，daemon 才能取得 Vault 密钥并开始捕获。
- 锁屏、睡眠、退出登录或用户切换时，暂停捕获，结束正在写入的事务，并尽快从内存清理密钥、解密图片、音频缓冲、模型上下文和临时明文。
- 解密后的截图只进入有上限的内存缓存，不写入磁盘预览缓存。
- 如确实需要落盘缓存，它必须和原 artifact 使用同等级加密，并进入统一删除范围。
- 崩溃恢复不得留下明文临时文件；写入使用临时密文文件、同步必要数据后原子 rename。

## 5. 删除与恢复

删除分成两个可观察状态：

1. 逻辑删除：立即从 Timeline、搜索索引和 Agent 查询结果中移除，同时删除或撤销对应 wrapped DEK。
2. 物理回收：清理独立 artifact、数据库记录、WAL、派生摘要、导出文件和其他副本。

独立 artifact 不需要 pack compaction。数据库仍需验证 WAL、free page 和 vacuum 策略，产品不能在物理回收完成前宣称字节已经彻底清除。

`ThisDeviceOnly` 密钥意味着：设备或 Keychain 条目损坏后，Vault 默认不可恢复。这是安全性与可恢复性的明确取舍。正式发布前应提供由用户主动创建的恢复包：使用用户口令派生的密钥包裹 Vault 恢复密钥；AfterRay 不持有服务器端后门或托管副本。

## 6. 威胁边界

这套结构主要防护：

- 磁盘被离线读取。
- Vault 目录被单独复制或通过未加密备份泄露。
- 用户离开电脑后，AfterRay 仍保留可直接读取的明文历史。
- 只拿到 artifact 文件但没有 Keychain 密钥的攻击者。

它不承诺防护：

- 已控制当前登录会话、可读取 AfterRay 进程内存的恶意软件。
- 用户主动把解密内容复制、截图或发送给外部服务。
- macOS、固件或硬件信任根已经失陷的设备。

因此应用级加密不能替代 App 排除、暂停捕获、权限最小化、外部 Agent scope、导出确认和安全更新。

## 7. 性能原则

不能为了修复 CPU 或滚动延迟而删除静态加密。已知的高 CPU 问题来自周期性全量数据库查询，而不是 artifact 加密。

性能优化按以下顺序进行：

1. 避免全量读取，使用增量 Timeline 查询和正确索引。
2. 当前帧优先，取消已经过期的解密与图片解码任务。
3. 使用有界的密文缓存和解密图片内存缓存。
4. 记录数据库查询、磁盘读取、AEAD、IPC、JPEG 解码和呈现各阶段耗时，再优化真实瓶颈。

不采用“为了性能把截图明文落盘”或“把整个 Vault 一次性解密到临时目录”的方案。

## 8. V0 与正式版出口

V0 必须满足：

- SQLCipher 保护结构化数据和索引。
- 每个截图、音频 artifact 独立使用 AEAD 加密。
- Vault key 存在 Keychain，Swift UI 不接触 key。
- 重启后使用同一 Vault 和同一 Keychain key 恢复历史。
- 运行目录和 staging 不遗留明文媒体。

对外发布前还必须满足：

- wrapped per-artifact DEK 和版本化 header。
- 锁屏、睡眠、用户切换时的暂停与内存清理经过验证。
- 数据库 WAL、删除和崩溃恢复经过验证。
- 可选的用户持有恢复包与恢复流程。
- 安全评审覆盖随机数、nonce、key derivation、文件替换和 downgrade 风险。

## 9. 明确不采用的方案

- 仅依赖 FileVault。
- 截图加密，但 OCR、Transcript 或搜索索引明文保存。
- Swift UI 直接打开 SQLCipher 或访问 Keychain key。
- 一个包含全部历史的巨大加密容器。
- 服务器保存主密钥或可绕过用户密钥的恢复后门。

