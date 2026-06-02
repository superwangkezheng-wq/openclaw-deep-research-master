# OpenClaw 深度研究主控工程

这是一个基于 OpenClaw 的深度研究工程包，用于把用户输入的粗糙研究题目，逐步转成可交付的商业研究成果：澄清需求、对齐内部知识库、规划多路研究、派发 worker 搜索与阅读、审计质量、生成终稿，并在全过程中保留证据、进度汇报、视觉资产和验收门禁。

> 重要：本工程不是独立应用，也不是 pip/npm 包。它是 OpenClaw workspace/project，需要放到 OpenClaw 运行时里使用。使用者必须自行配置模型、搜索、RAGFlow、MinerU、Obsidian、飞书或其他交付通道。

## 核心功能

- **Prompt Optimizer 前置优化**：在 Stage 1 澄清前，先用 `scripts/optimize-intake-prompt.sh` 把用户原始输入整理成结构化任务提示，再交给澄清机器人。
- **1 + 6 深度研究链路**：主控、澄清规格、知识库对齐、研究导演、研究 worker、审计、最终交付。
- **本地知识库/RAG 对齐**：通过 RAGFlow dataset/vector index 支持“业务参考库”和“风格匹配库”，让研究既能用内部材料，也能对齐既有文风。
- **搜索路由与证据台账**：支持 AnySearch、Tavily、web fetch 等搜索后端；记录 source discovery、reading queue、extraction log、worker checkpoint、evidence ledger。
- **科学制图与业务图表**：通过 `deep-research-visuals`、`nature-figure`、draw.io、Mermaid、PlantUML、Graphviz、Manim、Python Diagrams、Schemdraw、Bioicons 等组合生成或校验视觉资产。
- **PDF 参考材料解析**：RAGFlow 同步 PDF-heavy 文件夹时建议使用 MinerU parser/API，避免纯文本抽取损失版面与图表信息。
- **进度提醒与阶段汇报**：生命周期门控的 progress heartbeat、stage report、模型 fallback 告警、飞书幂等 key、完成后自动关闭 routine cron。
- **商业交付门禁**：合同测试、runtime doctor、heartbeat smoke、local runtime smoke、acceptance gate、Obsidian sync、便携路径/密钥扫描。

## 默认模型链

本工程商业基线使用：

- 主模型：`moonshot/kimi-k2.6`
- CodePlan fallback：`openai/gpt-5.5`
- 本地摘要 fallback：`local-summary/qwen3.5-9b-q8`

如果使用者不是 K2.6，需要重点调整：

- OpenClaw 里每个 agent/account 的模型路由。
- OpenClaw cron jobs 中的 `payload.model` 与 `payload.fallbacks`。
- `scripts/deep-research-runtime-doctor.sh` 中对模型链的检查。
- Stage 1/3/4/6 的提示词和质量门槛，尤其是长上下文规划、证据纪律、中文商业写作、图表说明能力。

调整后必须重跑：

```bash
zsh tests/test-contracts.sh
zsh scripts/v1-release-check.sh
zsh scripts/local-runtime-smoke.sh
```

## 完整能力依赖

基础依赖：

- OpenClaw runtime
- `zsh`, `jq`, `rg`, `curl`, `git`
- 模型供应商/API 或本地模型配置
- AnySearch 或 Tavily/web search
- RAGFlow dataset/vector index
- MinerU API
- Obsidian vault
- 飞书/Lark 通道或其他 OpenClaw 可用通知通道

视觉依赖：

- `deep-research-visuals` skill
- `nature-figure` skill
- draw.io CLI: `drawio`
- Mermaid CLI: `mmdc`
- PlantUML: `plantuml`
- Graphviz: `dot`
- Manim: `manim`
- Python 科学绘图库，以及 `diagrams`, `schemdraw`, `bioicons`

详见 [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)。

## 安装与配置

推荐安装到 OpenClaw workspace：

```bash
$HOME/.openclaw/workspace-deep-research-master
```

复制本地配置模板：

```bash
cp deep-research/config/runtime.local.example.env deep-research/config/runtime.local.env
cp deep-research/config/ragflow.local.example.env deep-research/config/ragflow.local.env
cp deep-research/config/ragflow_folder_mappings.example.json deep-research/config/ragflow_folder_mappings.json
```

然后填写本地路径、RAGFlow dataset ID、模型配置、Obsidian vault、搜索 API 等。不要提交这些私有配置。

## 验证

发布前：

```bash
zsh scripts/v1-release-check.sh
```

真实运行机：

```bash
zsh scripts/local-runtime-smoke.sh
```

单独合同测试：

```bash
zsh tests/test-contracts.sh
```

2026-06-02 商业基线验证：

- 合同测试：`PASS 30/30`
- 运行时 release gate：`PASS`
- 无 Git 分发目录 release gate：`PASS`
- live runtime smoke：`PASS 11 checks`

## 不应开源或打包的内容

- `deep-research/runs/`
- `deep-research/reports/`
- `.openclaw/`
- `.progress_report_log.json`
- `.fallback_alert_log.json`
- `.stage_report_outbox/`
- `deep-research/config/*.env`
- `deep-research/config/*profiles.json`
- `deep-research/config/ragflow_folder_mappings.json`

## 许可证

MIT，见 [LICENSE](LICENSE)。
