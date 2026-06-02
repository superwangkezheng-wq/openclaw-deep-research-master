# Local RAGFlow Contract

这份契约用于把本地 `RAGFlow + 本地模型` 接到深度研究工程，而不是只靠人工记忆或临时文件检索。

## Two Reference Layers

1. `研究参考库`
   - 服务 Stage 2
   - 作用是补齐本轮研究的历史沉淀、内部语境、过往同类研究、业务边界和术语口径
   - 它不是只服务“业务启示”，而是服务整轮研究

2. `文风参考库`
   - 服务 Stage 6
   - 作用是对齐最终交付的表达风格、章节结构、汇报口径和常用措辞

## Stage 0/1 Required Decisions

如果任务依赖内部沉淀或历史研究，Stage 1 必须明确：

- `selected research reference source`
- `selected research reference base / folder`
- `research reference purpose`

如果最终交付需要对照既有风格，Stage 1 必须明确：

- `selected style reference source`
- `selected style reference base / folder`
- `style reference purpose`

## Supported Source Values

推荐统一使用以下来源值：

- `none`
- `ima`
- `obsidian`
- `ragflow-local`
- `hybrid`

## Local Model Note

当前这台机器已经存在本地 LM Studio API 服务，`http://127.0.0.1:1234/v1/models` 可见本地 embedding 模型。

推荐接法：

1. RAGFlow 负责数据集管理、切分、索引和检索
2. LM Studio 负责本地 embedding 服务
3. OpenClaw 深度研究机器人负责推理、编排、审计和终稿

## Output Expectations

如果 Stage 2 使用 `ragflow-local`，必须额外产出：

- `research_reference_context.md`
- `research_reference_log.json`

如果 Stage 6 使用 `ragflow-local`，必须额外产出：

- `style_alignment.md`
- `style_reference_log.json`
