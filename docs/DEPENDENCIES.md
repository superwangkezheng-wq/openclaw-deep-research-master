# Dependencies / 依赖说明

## Runtime

| Area | Required for full capability | Notes |
| --- | --- | --- |
| OpenClaw | Yes | This is an OpenClaw workspace/project package. |
| Shell tools | `zsh`, `jq`, `rg`, `curl`, `git` | Used by scripts and release gates. The setup wizard is bash-compatible and uses no sudo, but the core workflow scripts still require `zsh`. |
| GitHub publishing | `gh` | Only needed for publishing this repository. |
| Models | `moonshot/kimi-k2.6`, `openai/gpt-5.5`, `local-summary/qwen3.5-9b-q8` baseline | Other models require routing and validation changes. |
| Search | AnySearch, Tavily/web fetch | AnySearch is preferred when configured; Tavily/web fetch can be fallback. |
| RAG/vector retrieval | RAGFlow datasets/vector index | Used for business references and style references. |
| PDF parsing | MinerU API | Recommended for PDF-heavy RAGFlow sync. |
| Install/config wizard | `bash scripts/install-config-wizard.sh --mode cloud|local` | Prompts for search keys, RAGFlow, MinerU, business/style reference mappings, and model-service settings. Use `REMOTE_ONLY` for cloud runtimes that cannot see local folders. |
| Obsidian | local vault path | Used for final deliverable sync. |
| Messaging | Feishu/Lark or another OpenClaw delivery channel | Used for progress/stage reports. |

## Visual Toolchain

| Tool/skill | Purpose |
| --- | --- |
| `deep-research-visuals` | Deep research final-delivery visual router. |
| `nature-figure` | Publication-quality scientific figure contract and rendering patterns. |
| draw.io / `drawio` | Editable architecture/system/process diagrams. |
| Mermaid CLI / `mmdc` | Flowcharts, timelines, system maps. |
| PlantUML / `plantuml` | UML-like technical diagrams. |
| Graphviz / `dot` | Graph/network layouts. |
| Manim / `manim` | Animated or geometry-heavy explanatory scenes. |
| Python scientific stack | Matplotlib/Plotly-style figures and data visuals. |
| `diagrams` | Cloud/system infrastructure visuals. |
| `schemdraw` | Circuit/schematic-style drawings. |
| `bioicons` | Biology/chemistry icon support. |

## Local Config Files

Copy examples and fill them locally:

```bash
cp deep-research/config/runtime.local.example.env deep-research/config/runtime.local.env
cp deep-research/config/ragflow.local.example.env deep-research/config/ragflow.local.env
cp deep-research/config/ragflow_folder_mappings.example.json deep-research/config/ragflow_folder_mappings.json
```

Never commit private local configs. They may contain local folder paths, dataset IDs, account IDs, or tokens.

For cloud OpenClaw, no-sudo setup, `REMOTE_ONLY` reference libraries, and weaker models such as `qwen/qwen3.6`, see [INSTALLATION.md](INSTALLATION.md).

## 中文补充

完整功能不是“下载即跑”。使用者需要先有 OpenClaw 运行时，再根据自己的模型、RAGFlow、搜索服务、MinerU、Obsidian 和通知通道做本地配置。开源包只提供工程逻辑、脚本、模板、规则、skills 和 example 配置。

云端 OpenClaw 可以先运行：

```bash
bash scripts/install-config-wizard.sh --mode cloud
```

安装向导不使用 `sudo`，但核心脚本仍然需要 `zsh`。如果云端 runtime 看不到本地业务参考/风格匹配文件夹，使用 `REMOTE_ONLY`，并确保文件已经上传或同步到 RAGFlow。弱模型如 `qwen/qwen3.6` 应按 [INSTALLATION.md](INSTALLATION.md) 的清单执行，不要让模型自行猜配置。
