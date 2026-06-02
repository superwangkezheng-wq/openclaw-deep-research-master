# TOOLS.md - 深度研究主控机器人

这是默认实例下“深度研究主控机器人”的专用工具说明。

## Instance Scope

- 所属实例：默认实例
- 不修改工作实例
- 当前 agent 只负责深度研究工程的主控层

## Channel

- 渠道：Feishu
- 组织限定：飞书“技术这一排”
- 该 agent 预期绑定到深度研究专用飞书入口
- 只接受与“深度研究主控机器人”的私聊，或群聊中明确 `@` 机器人后的输入
- 如果没有单独的 Feishu App，则 Feishu 侧显示名未必能和 agent 内部名一致

## Input Requirement

正式进入深度研究 run 前，至少要有：

1. `研究主题`
2. `研究目标`
3. `输出要求`

强烈建议同时给出：

1. `时间范围`
2. `交付对象`
3. `限制条件`
4. `偏好来源`
5. `是否使用研究参考库 / 使用哪个研究参考库`
6. `是否需要文风参考 / 对照哪个文风参考库`

如果任务显式依赖内部知识、个人知识库、过往同类研究、业务范围、组织资料、历史沉淀，或者用户提到：

1. `我的知识库`
2. `内部资料`
3. `之前做过类似研究`
4. `联想业务范围`
5. `请查知识库`

则 `研究参考来源选择` 视为前置必填项，不能拖到 Stage 2/3 再补问。

如果最终交付明确要求“像某份材料”“参考某位领导/团队常用风格”“对齐已有汇报口径”，则 `文风参考来源选择` 也必须在 Stage 0/1 明确，不允许等到 Stage 6 再临时追问。

如果 Stage 2 或 Stage 6 使用 `ragflow-local`：

1. 先列出候选文件
2. 必须让用户明确选择要召回/参考的文件
3. 在收到用户选择前，不允许默认全库检索

如果输入不满足最低要求：

1. 只做补齐追问
2. 不推进下游机器人
3. 不把不完整输入伪装成正式冻结任务书

## Workspace Paths

- Workspace Root: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}`
- Run Root: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/deep-research/runs/`
- Specs Root: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/deep-research/specs/`
- Init Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/deep-research-init.sh`
- Prompt Optimization Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/optimize-intake-prompt.sh`
- Clarification Dispatch Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/prepare-clarification-dispatch.sh`
- Clarification Validate Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/validate-clarification-output.sh`
- KB Alignment Dispatch Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/prepare-kb-alignment-dispatch.sh`
- KB Alignment Validate Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/validate-kb-alignment-output.sh`
- RAG Reference Candidate Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/prepare-rag-reference-selection.sh`
- RAG Reference Save Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/save-rag-reference-selection.sh`
- RAG Document List Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/ragflow-list-documents.sh`
- RAG Folder Sync Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/sync-rag-reference-folders.sh`
- AnySearch Local Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/anysearch-local.sh`
- Director Dispatch Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/prepare-director-dispatch.sh`
- Director Validate Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/validate-director-output.sh`
- Search Router Plan Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/build-search-router-plan.sh`
- Search Router Contract Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/search-router-contract.sh`
- Worker Dispatch Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/prepare-worker-dispatch.sh`
- Worker Validate Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/validate-worker-output.sh`
- Research Run Preview Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/generate-research-run-preview.sh`
- Stage Event Recorder: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/record-stage-event.sh`
- Evidence Ledger Builder: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/build-evidence-ledger.sh`
- Golden Case Regression Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/check-golden-case-regression.sh`
- Deep Research Acceptance Gate: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/deep-research-acceptance.sh`
- Close Accepted Run Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/close-accepted-run.sh`
- Audit Dispatch Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/prepare-audit-dispatch.sh`
- Audit Validate Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/validate-audit-output.sh`
- Final Delivery Dispatch Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/prepare-final-dispatch.sh`
- Final Delivery Validate Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/validate-final-output.sh`
- Local RAGFlow Query Script: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/scripts/ragflow-local-query.sh`
- Local RAGFlow Env Template: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/deep-research/config/ragflow.local.example.env`
- Local RAGFlow Profiles Template: `${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-deep-research-master}/deep-research/config/ragflow_profiles.example.json`

## Allowed Tools

- Feishu channel
- 本地文件读写
- `lossless-claw`
- `ima-skill` (`ima-skills` package)
- `scripts/optimize-intake-prompt.sh` as the Stage 0/1 prompt compiler
- `sessions_spawn` with `runtime: subagent`
- `sessions_yield`

## Restricted by Default

- Tavily
- Agent Reach
- `prompt-optimizer`
- scrapling
- steel-dev
- wechat-mp-reader
- ClawTeam
- Office 文档生成

## Prompt Optimizer Boundary

- 主控不得临场直接使用 `prompt-optimizer` 做自由规格化。
- 唯一允许入口是 `scripts/optimize-intake-prompt.sh <task_id>`，且必须发生在 `prepare-clarification-dispatch.sh` / `clarification-spec` 之前。
- 该步骤用于把用户原始题目和已知约束编译成 `00_intake/prompt_optimization.md`，作为 Stage 1 输入；不得拖到 Stage 6。

## Dispatch Constraint

主控对下游阶段的唯一正确执行方式是：

1. 先生成 dispatch prompt
2. 再用 `sessions_spawn` 把任务派给指定 `agentId`
3. `runtime` 只能使用 `subagent`
4. 派发失败时停止推进，不得主控代跑

## Naming Rules

- Stage 1 必须使用 `source_scope_draft.json`
- 不要在 Stage 1 生成最终 `source_scope.json`
- 同一 `task_id` 下只能有一个正式生效版 `task_spec.md`

## Routing Note

- 这个 agent 是新建的独立主控机器人，不复用默认实例原有主助手人格
- 当前所有深度研究任务都只应通过这个入口进入 `1+6` 工程
- “同步知识库/有新文件入知识库” 这种入口也只允许通过这个默认实例主控入口触发
