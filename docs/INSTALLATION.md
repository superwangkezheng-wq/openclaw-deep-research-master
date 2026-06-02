# Installation / 安装指南

This project is an OpenClaw workspace package. It is not a standalone application and it is not installed with `pip install` or `npm install`.

本工程是 OpenClaw workspace 工程包，不是独立应用，也不是 pip/npm 包。

## Quick Path

For cloud OpenClaw, run the bash-compatible setup wizard:

```bash
bash scripts/install-config-wizard.sh --mode cloud
```

For a local operator machine:

```bash
bash scripts/install-config-wizard.sh --mode local
```

The wizard uses **no sudo**. It writes private config files under `deep-research/config/`, all of which are gitignored.

Important boundary: the installer can run under bash, but the core workflow scripts still require `zsh`. If your cloud OpenClaw runtime does not provide `zsh`, do not run the core scripts with bash. Choose a runtime image that includes `zsh` or ask the platform/provider to enable it.

## What The Wizard Configures

The wizard asks for:

- primary model and fallback model chain;
- AnySearch API key;
- Tavily API key;
- RAGFlow base URL, API key, and retrieval endpoint path;
- business-reference folder or `REMOTE_ONLY`;
- style-reference folder or `REMOTE_ONLY`;
- business/style RAGFlow dataset IDs and profile names;
- MinerU API endpoints for PDF parsing;
- optional local/external OpenAI-compatible model service URL and embedding/chat model names used by RAGFlow.

It writes:

- `deep-research/config/runtime.local.env`
- `deep-research/config/ragflow.local.env`
- `deep-research/config/ragflow_folder_mappings.json`
- `deep-research/config/ragflow_profiles.json`
- `deep-research/config/install.summary.local.json`

Do not commit these files.

## Cloud OpenClaw And REMOTE_ONLY

Cloud OpenClaw often cannot see folders on your desktop or laptop. In that case, use:

```text
REMOTE_ONLY
```

for the business-reference and style-reference folder fields.

`REMOTE_ONLY` means the documents must already be uploaded to RAGFlow, or synced by another machine that can see those folders. The deep-research workflow will use the RAGFlow dataset IDs and document selections, but it will not try to scan a local folder that the cloud runtime cannot access.

If you want folder sync in cloud mode, the folder path must be mounted or otherwise visible inside the OpenClaw runtime.

## Vector Database, MinerU, And Local Model Service

RAGFlow is the vector database/retrieval layer for this project. The project calls RAGFlow; it does not embed documents by itself.

MinerU is used for PDF-heavy parsing when documents are ingested into RAGFlow. If your reference folders contain PDFs, configure the RAGFlow dataset/parser pipeline with MinerU before syncing or relying on those documents.

Embeddings and local model processing depend on your RAGFlow setup. If RAGFlow uses a local or external OpenAI-compatible service, fill in:

- `LOCAL_MODEL_BASE_URL`
- `RAGFLOW_EMBEDDING_MODEL`
- `RAGFLOW_CHAT_MODEL`

For example, a local deployment might use LM Studio, Ollama, vLLM, or another OpenAI-compatible endpoint. In cloud OpenClaw, this service must be reachable from the cloud runtime or from the RAGFlow deployment.

## Weaker Model Guidance

The validated baseline used `moonshot/kimi-k2.6` with stronger fallbacks. If your OpenClaw runtime uses a weaker model such as `qwen/qwen3.6`, make setup more explicit:

- run the setup wizard instead of asking the model to infer config files;
- keep `docs/INSTALLATION.md`, `docs/DEPENDENCIES.md`, and `deep-research/config/install.summary.local.json` visible to the model/operator;
- do not skip AnySearch/Tavily keys unless you accept weaker web/source coverage;
- do not skip RAGFlow dataset IDs if you need business-reference or style-reference alignment;
- do not skip MinerU if PDFs are part of the reference library;
- run `zsh scripts/v1-release-check.sh` before treating the workspace as ready;
- run `zsh scripts/local-runtime-smoke.sh` only on a machine/runtime where live external services are reachable.

## 中文说明

云端 OpenClaw 常见限制是不能 `sudo`、看不到本地文件夹、模型能力弱于商业基线。这个项目现在提供 bash 安装向导：

```bash
bash scripts/install-config-wizard.sh --mode cloud
```

安装向导不会使用 `sudo`，但核心工作流脚本仍然需要 `zsh`。如果云端 runtime 没有 `zsh`，不要把核心脚本改成 bash 跑；应该换带 `zsh` 的运行环境，或让平台方启用。

安装向导会明确要求填写：

- AnySearch / Tavily API key；
- RAGFlow URL、API key、retrieval endpoint；
- 业务参考库和风格匹配库的文件夹或 `REMOTE_ONLY`；
- 业务参考库和风格匹配库的 RAGFlow dataset ID；
- MinerU API；
- RAGFlow 使用的本地/外部 embedding 和模型服务。

`REMOTE_ONLY` 表示云端 runtime 不扫描本地文件夹，而是使用已经上传/同步到 RAGFlow 的数据集。业务参考和风格匹配功能最终依赖 RAGFlow 的向量检索；本工程本身不负责把文件 embedding 到向量库，embedding 和解析由 RAGFlow / MinerU / 你配置的本地或外部模型服务完成。
