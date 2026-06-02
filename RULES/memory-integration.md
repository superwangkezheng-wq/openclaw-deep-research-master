# A+B+C 三级记忆系统有机配合规则

## 系统定位

| 系统 | 代号 | 核心能力 | 记忆层级 |
|------|------|----------|----------|
| memory-tdai | A | 用户画像 + 场景语义提取 | L0-L4（对话→记录→场景→人格→向量） |
| memory-lancedb-pro | B | 长期语义向量检索 | 语义向量库（持久化） |
| lossless-claw (lcm) | C | 对话上下文压缩 | Summary DAG（d0 leaf → d1+ condensed） |

## 配合原则

1. **写入顺序**：任何新记忆先经 C 压缩，再经 A 提取，最后写入 B 建立语义索引。
2. **召回优先级**：HOT（C fresh tail）→ WARM（A scene blocks + persona）→ COLD（B 语义搜索）。
3. **数据一致性**：A 的 vectors.db 与 B 的 LanceDB 共享同一 embedding 空间；C 的 summary 文本应被 A 的 L1 extraction 捕获为 records。
4. **故障降级**：B 损坏时，降级为 A 的 vectors.db + C 的 summary；A 故障时，降级为 C 的 summary + B 的语义搜索。

## 写入流（Write Pipeline）

```
对话消息 → [C] lcm ingest → leaf summary (d0)
         → [C] afterTurn compaction → condensed summary (d1+)
         → [A] memory-tdai capture → L1 records / L2 scene_blocks
         → [A] persona update (L3, 每24h或每100条记忆)
         → [B] memory-lancedb-pro store → 语义向量索引
```

**硬性规则**：
- C 完成 compaction 后，必须将 summary 文本暴露给 A 的 extraction pipeline。
- A 的 L2 scene_blocks 更新后，必须同步写入 B 的 memory_store。
- A 的 L3 persona.md 更新后，必须作为全局 context 注入到所有新 session。

## 召回流（Read Pipeline）

```
用户提问 → [C] 组装 fresh tail + budget summaries
         → [A] recall persona.md (L3) + scene_blocks (L2, heat TOP3)
         → [B] memory_recall 语义搜索 (maxResults=3)
         → 按优先级合并去重 → 注入模型上下文
```

**硬性规则**：
- 召回时先查 C（保证当前对话连续性），再查 A（保证用户偏好和场景），最后查 B（保证长期知识）。
- B 的 recall 结果如果与 A 的 scene_blocks 重叠，优先使用 A 的更新版本（时间戳更近）。
- 如果 B 返回空（如数据损坏），立即告警并全量降级到 A+C。

## 监控与修复

| 检查项 | 正常状态 | 故障处理 |
|--------|----------|----------|
| B LanceDB 完整性 | manifest 与 data 文件一致 | 备份损坏目录，删除后由插件 auto-reinit |
| A vectors.db 大小 | >0 且持续增长 | 检查 extraction pipeline 是否卡住 |
| C lcm.db 大小 | >0 且 summary 深度正常 | 运行 `/compact` 手动压缩 |
| A-B 同步延迟 | scene_block 写入后 5 分钟内入 B | 超过 5 分钟启动补偿写入 |

## 当前已知问题与修复状态

- [x] default 实例 B 损坏：已清理，待 auto-reinit
- [x] AGENTS.md 过大截断：已拆分为核心 + RULES/
- [x] fs.workspaceOnly 危险配置：已修复为 true
- [ ] A 的 LEARNINGS/ERRORS 空转：待补充写入逻辑
- [ ] work 实例 A persona 老化（17天未更新）：待触发更新
