# Contributing / 参与共建

Thank you for trying OpenClaw Deep Research Master. This project is published as a working OpenClaw engineering baseline, and feedback from real deployments is especially valuable.

感谢你试用 OpenClaw Deep Research Master。这个项目是一个真实可运行的 OpenClaw 深度研究工程基线，来自真实部署环境的反馈非常重要。

## Good Issues

Please open an issue when you find:

- installation or OpenClaw workspace setup problems;
- model-routing differences when you do not use `moonshot/kimi-k2.6`;
- RAGFlow dataset/vector retrieval problems;
- MinerU PDF parsing or sync failures;
- AnySearch/Tavily/search-routing problems;
- `deep-research-visuals`, `nature-figure`, draw.io, Mermaid, PlantUML, Graphviz, Manim, or Python visual toolchain failures;
- unclear stage contracts, missing evidence, weak acceptance gates, or progress-reporting issues.

## Issue Template

When possible, include:

```text
Environment:
- OpenClaw version:
- OS:
- primary model:
- search backend:
- RAGFlow/MinerU status:
- visual toolchain status:

What happened:

Expected behavior:

Relevant command:

Relevant logs or artifacts:
```

Do not paste API keys, private folder mappings, internal documents, local customer data, or secrets.

## Pull Requests

Useful PRs include:

- portability fixes;
- stronger contract tests;
- clearer bilingual docs;
- new search/RAG/visual adapters;
- prompt and stage-contract improvements;
- reproducible fixtures for bugs;
- improvements to progress reporting, fallback alerts, acceptance gates, and release checks.

Before opening a PR, run:

```bash
zsh tests/test-contracts.sh
zsh scripts/v1-release-check.sh
```

If your change depends on live external services, also run:

```bash
zsh scripts/local-runtime-smoke.sh
```

## 中文说明

欢迎通过 issue 或 PR 反馈和更新：

- 安装和 OpenClaw workspace 配置问题；
- 不使用 `moonshot/kimi-k2.6` 时的模型适配问题；
- RAGFlow 向量库、MinerU PDF 解析、AnySearch/Tavily 搜索路由问题；
- `deep-research-visuals`、`nature-figure`、draw.io、Mermaid、PlantUML、Graphviz、Manim、Python 制图链路问题；
- prompt、阶段合同、证据台账、进度提醒、验收门禁、发布门禁的改进建议。

提交公开 issue/PR 时，请不要包含密钥、私有路径、内部文件、客户数据或任何敏感信息。
