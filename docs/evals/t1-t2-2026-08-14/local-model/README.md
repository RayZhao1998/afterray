# 本地模型 T2 实跑（Ollama qwen3.6:latest）

走产品推理路径：`ModelQueue` → `LlmRouterAdapter` → Ollama。
输入为 17:00–17:30 真实槽的 T1 卡片（171 帧，prompt ≈26.8KB）。

复现：

```sh
cargo run -p afterrayd --example t2_eval -- \
    --at-ms 1786698000000 --provider ollama --model qwen3.6:latest --language "简体中文"
```

| | 第 1 轮 English | 第 2 轮 简体中文 |
|---|---|---|
| 延迟 | 51.8 s | 78.9 s |
| JSON 解析 | ✓ | ✓ |
| anchors 接地 | 3/3 | 4/4 |
| category | `other`（错，应为 coding） | `coding` ✓ |
| 专名 | `Loly`（错拼 Lody） | `Lody` ✓ |

第 2 轮在 system prompt 加入 LANGUAGE 段之后产出：

```json
{
  "artifacts": ["127.0.0.1:5175", "loro-dev/lody/pull/3309", "mactop", "#features"],
  "title": "官网预览迭代与 Lody 自动摘要推演",
  "bullets": [
    "本地站页（127.0.0.1:5175）界面视觉与功能区块的反复预览微调，停在首页 #features 区域。",
    "在 Lody 内起草自动工作总结架构（T1/T2 双链路策略）与搜索呈现方案，停留在提示词草稿中。",
    "查阅 loro-dev/lody 仓库 PR 对比页并核对终端资源监控数据，结束于 mactop 性能面板。"
  ],
  "category": "coding",
  "confidence": 0.95
}
```

## 已知未解

- **字段顺序无法靠 prompt 保证**：模型按字母序输出，`artifacts` 先于 `title`
  的"强制接地"设计因此失效。只有约束解码能锁死顺序 —— builtin 走 GBNF，
  Ollama 走原生 `format` 传 JSON schema。
- **anchor 校验只覆盖 `artifacts`**：`title` / `bullets` 内的专名与编号无人核对，
  第 1 轮的 `Loly` 与更早一轮 Claude 编的 "PR #1" 都从这个洞里漏出去。
