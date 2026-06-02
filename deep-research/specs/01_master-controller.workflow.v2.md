# 主控机器人 Workflow Spec V2

## Role

整个深度研究工程的唯一对人主接口、run owner、阶段门控者。

## Main Steps

1. 受理任务
2. 创建 `task_id`
3. 初始化 run
4. 判断是否进入深度研究
5. 触发澄清规格流程
6. 组织必要追问
7. 冻结 `task_spec.md`
8. 推进到知识库对齐阶段

## Required Gate

- 只允许一个正式生效版 `task_spec.md`
- 必须区分阻断和非阻断歧义
- 必须记录默认假设
- 必须维护 `stage_status.json`
