# Architecture / 架构说明

## English

OpenClaw Deep Research Master is organized as a staged OpenClaw workflow.

### Reference Projects And Positioning

| Project | Primary Focus | Relationship To This Project |
| --- | --- | --- |
| [HKUDS/ClawTeam](https://github.com/HKUDS/ClawTeam) | Multi-agent coordination for CLI agents, including spawning, worktree isolation, status reporting, inbox/task coordination, and team execution. | Inspiration for agent coordination patterns. This project does not try to become a general coordination framework; it packages a specific OpenClaw deep-research delivery workflow. |
| [HKUDS/Auto-Deep-Research](https://github.com/HKUDS/Auto-Deep-Research) | Automated deep-research assistant built on AutoAgent, with multi-model support, web/source exploration, file support, and report synthesis. | Inspiration for open-source deep-research automation. This project adds OpenClaw-specific staged contracts, private RAGFlow/MinerU alignment, evidence ledgers, visual routing, lifecycle reports, Obsidian sync, and commercial acceptance gates. |

Naming note: [karpathy/autoresearch](https://github.com/karpathy/autoresearch) is an adjacent autonomous ML experimentation loop for single-GPU nanochat training. It is not the `HKUDS/Auto-Deep-Research` project and is not a direct dependency of this repository.

The practical advantage of this repository is delivery governance: research is not only automated, but also constrained by auditable stages, local/private reference alignment, explicit evidence artifacts, visual deliverable contracts, and completion gates.

### Stage Map

1. **Stage 0 Intake**: stores raw intake, intake gate, and prompt optimization artifacts.
2. **Stage 1 Clarification**: asks or confirms ambiguity, search depth, delivery type, assumptions, source scope, and user follow-ups.
3. **Stage 2 Knowledge Alignment**: maps the task to local RAGFlow business/style references and produces knowledge packets.
4. **Stage 3 Director Planning**: produces research lanes, source strategy, search-router plan, worker handoff, and research run preview.
5. **Stage 4 Worker Execution**: executes lane-specific search, source discovery, reading, extraction, checkpoints, and evidence ledger records.
6. **Stage 5 Audit**: reviews quality, must-fix items, risk register, and return route.
7. **Stage 6 Final Delivery**: writes business insights, action plan, executive summary, final report, visual asset plan, and final status.

### Key Seams

- **Prompt optimization seam**: `scripts/optimize-intake-prompt.sh` compiles raw user input into a structured prompt before clarification.
- **RAG seam**: `scripts/ragflow-local-query.sh`, `scripts/ragflow-list-documents.sh`, and `scripts/sync-rag-reference-folders.sh` connect local RAGFlow datasets to the workflow.
- **Search-router seam**: director plans search budgets and routes; workers receive executable search-route contracts.
- **Visual seam**: final delivery must use `deep-research-visuals` routing for requested figures and can use `nature-figure`, draw.io, Mermaid, PlantUML, Graphviz, Manim, and Python figure tools.
- **Acceptance seam**: `scripts/deep-research-acceptance.sh` and `scripts/close-accepted-run.sh` prevent a `DELIVERABLE_READY` run from being treated as completed without stage reports, visual assets, evidence, and Obsidian sync.
- **Monitoring seam**: `scripts/sync-deep-research-cron-state.sh`, `scripts/generate-progress-report.sh`, `scripts/emit-stage-report.sh`, and `scripts/generate-fallback-alert.sh` keep routine monitoring lifecycle-gated.

## 中文

本工程是一个 OpenClaw 分阶段工作流，不是单个脚本。核心设计是把“研究质量”拆成可验证的阶段合同。

### 参考项目与定位

| 项目 | 主要定位 | 与本项目的关系 |
| --- | --- | --- |
| [HKUDS/ClawTeam](https://github.com/HKUDS/ClawTeam) | 面向命令行 agent 的多 agent 协调框架，包含 agent 派生、worktree 隔离、状态汇报、inbox/task 协调和团队执行。 | 提供多 agent 协调模式参考。本项目不做通用协调框架，而是封装一个具体的 OpenClaw 深度研究交付工作流。 |
| [HKUDS/Auto-Deep-Research](https://github.com/HKUDS/Auto-Deep-Research) | 基于 AutoAgent 的自动化深度研究助手，包含多模型支持、网页/来源探索、文件支持和报告综合。 | 提供开源深度研究自动化参考。本项目进一步加入 OpenClaw 阶段合同、私有 RAGFlow/MinerU 对齐、证据台账、视觉路由、生命周期汇报、Obsidian 同步和商业验收门禁。 |

命名说明：[karpathy/autoresearch](https://github.com/karpathy/autoresearch) 是相邻的 autonomous ML experimentation loop，主要用于单 GPU nanochat 训练实验自动迭代。它不是 `HKUDS/Auto-Deep-Research`，也不是本仓库的直接依赖。

本项目的实际优势是交付治理：研究不仅要自动化，还要被可审计阶段、本地/私有参考库、显式证据资产、视觉交付合同和完成门禁约束住。

### 阶段链路

1. **Stage 0 输入接收**：保存原始输入、准入检查、Prompt Optimizer 输出。
2. **Stage 1 澄清规格**：确认歧义、搜索深度、交付形态、默认假设、来源范围、用户追问。
3. **Stage 2 知识库对齐**：把任务映射到本地 RAGFlow 业务参考库和风格参考库，输出知识包。
4. **Stage 3 研究导演**：规划研究 lane、搜索策略、search router、worker handoff、research run preview。
5. **Stage 4 Worker 执行**：按 lane 搜索、发现来源、阅读、抽取、checkpoint、写 evidence ledger。
6. **Stage 5 审计**：输出 audit report、scorecard、must-fix、risk register、return route。
7. **Stage 6 最终交付**：输出洞察、行动计划、执行摘要、终稿、视觉资产计划、最终状态。

### 关键接口

- **Prompt Optimizer 接口**：先结构化用户题目，再进入澄清。
- **RAGFlow 接口**：用本地 dataset/vector index 承接业务参考与风格匹配。
- **搜索路由接口**：导演给 worker 下发可执行搜索预算与后端路线。
- **视觉接口**：最终交付中有图表需求时，必须走 `deep-research-visuals`，并按图表类型选择 draw.io、Mermaid、PlantUML、Graphviz、Manim、Python/nature-figure 等工具。
- **验收接口**：只有 acceptance gate 通过，才能 close run。
- **监控接口**：进度提醒和 fallback 告警只在 active run 存在时打开，完成后关闭。
