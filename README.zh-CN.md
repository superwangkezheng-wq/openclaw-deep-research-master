# OpenClaw 深度研究主控工程

![OpenClaw Deep Research Master banner](docs/assets/openclaw-deep-research-master-banner.svg)

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

## 参考项目与定位

本项目参考了开源深度研究和多 agent 协作生态中的两个重要项目：

- [HKUDS/ClawTeam](https://github.com/HKUDS/ClawTeam)：面向 Claude Code、Codex、OpenClaw 和其他命令行 agent 的多 agent 协调框架，重点是 agent 派生、任务协同、worktree 隔离、状态汇报和团队式执行基础设施。
- [HKUDS/Auto-Deep-Research](https://github.com/HKUDS/Auto-Deep-Research)：基于 AutoAgent 的开源、低成本自动化深度研究助手，重点是开箱即用的自动研究、网页/来源探索、文件支持、多模型兼容和报告综合。

命名说明：[karpathy/autoresearch](https://github.com/karpathy/autoresearch) 是思想相邻的 autonomous ML experimentation loop，主要用于单 GPU nanochat 训练实验自动迭代。它不是上面所说的 `Auto-Deep-Research` 项目，也不是本 OpenClaw 工程包的直接依赖。本文档中如无额外说明，`Auto-Deep-Research` 均指 `HKUDS/Auto-Deep-Research`。

OpenClaw 深度研究主控工程的定位不同：它不是通用多 agent 框架，也不是零配置研究应用，而是一个用于商业研究交付的 OpenClaw workspace 工程包。它强调固定的 1 + 6 阶段合同、Stage 0/1 Prompt Optimizer、RAGFlow/MinerU 私有参考库对齐、搜索路由和证据台账、生命周期门控的进度汇报、Obsidian 同步、科学/业务图表路由，以及最终交付前的验收门禁。

因此，本项目的优势不在于替代 ClawTeam 或 Auto-Deep-Research，而在于把深度研究变成可重复、可审计、可结合私有知识库、可产出高质量视觉资产、可用于商业交付的 OpenClaw 生产工作流。

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

## 欢迎使用、反馈与共建

这个项目开源出来，是希望大家可以把它当成一个可运行的 OpenClaw 深度研究工程基线来试用、拆解、改造和继续完善。

欢迎大家：

- 在自己的 OpenClaw 运行时中试用这个工程；
- 通过 issue 反馈安装、模型路由、RAGFlow/MinerU、搜索后端、视觉工具链、阶段合同或验收门禁中的问题；
- 提出 prompt、流程、合同测试、搜索路由、证据台账、进度提醒、最终交付和科学制图方面的改进建议；
- 提交 PR，补充新的搜索/RAG/视觉工具适配、新 skill、新测试、新文档或更好的可移植实现；
- fork 后按自己的组织需求改造，但务必不要把私有配置、密钥、内部数据和本地路径提交到公开仓库。

贡献建议见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
