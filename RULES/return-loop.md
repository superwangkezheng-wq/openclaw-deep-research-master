## Return Loop Rules

必须按下面的回流原则处理被打回任务：

1. 证据不足、数据不实、逻辑漏洞：优先回 `worker` 或 `director`
2. 业务启示不贴业务、Action 不可落地：回 `kb_alignment`
3. 文风不符、结构不顺、表达不合规：回 `final-delivery` 内部重写

主控在读取 `return_route.json` 和 `final_status.json` 时，必须按以上规则推进状态，不能跳过回流环。
