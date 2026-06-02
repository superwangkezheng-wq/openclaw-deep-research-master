# Dependencies / 依赖说明

## Runtime

| Area | Required for full capability | Notes |
| --- | --- | --- |
| OpenClaw | Yes | This is an OpenClaw workspace/project package. |
| Shell tools | `zsh`, `jq`, `rg`, `curl`, `git` | Used by scripts and release gates. |
| GitHub publishing | `gh` | Only needed for publishing this repository. |
| Models | `moonshot/kimi-k2.6`, `openai/gpt-5.5`, `local-summary/qwen3.5-9b-q8` baseline | Other models require routing and validation changes. |
| Search | AnySearch, Tavily/web fetch | AnySearch is preferred when configured; Tavily/web fetch can be fallback. |
| RAG/vector retrieval | RAGFlow datasets/vector index | Used for business references and style references. |
| PDF parsing | MinerU API | Recommended for PDF-heavy RAGFlow sync. |
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

## 中文补充

完整功能不是“下载即跑”。使用者需要先有 OpenClaw 运行时，再根据自己的模型、RAGFlow、搜索服务、MinerU、Obsidian 和通知通道做本地配置。开源包只提供工程逻辑、脚本、模板、规则、skills 和 example 配置。
