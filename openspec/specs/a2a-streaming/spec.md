## ADDED Requirements

### Requirement: SSE 流式连接
客户端 SHALL 通过 `URLSession.bytes` 建立 SSE 连接，逐行解析 `data:` 前缀的事件，空行视为事件分隔符。

#### Scenario: 正常接收事件
- **WHEN** SSE 连接建立后服务端推送 `data: {...}\n\n`
- **THEN** 客户端解析为 SSEEvent 并传递给归约器

#### Scenario: 连接错误
- **WHEN** 网络中断或服务端返回非 2xx
- **THEN** AsyncThrowingStream 抛出错误，UI 显示错误状态

### Requirement: TaskStatusUpdateEvent 解码
客户端 SHALL 解码 `TaskStatusUpdateEvent`，从 `status.message.parts` 中提取 `DataPart`，按 `step` 字段（`reasoning`/`tool_call`/`tool_result`）和 `round` 字段归组。

#### Scenario: 接收 reasoning 步骤
- **WHEN** 收到 DataPart `{step: "reasoning", round: 1, text: "..."}`
- **THEN** 归约器将 text 写入 rounds[0].reasoning

#### Scenario: 接收 tool_call 步骤
- **WHEN** 收到 DataPart `{step: "tool_call", round: 1, name: "web_search", args: {...}}`
- **THEN** 归约器追加到 rounds[0].toolCalls

#### Scenario: DataPart 解码失败
- **WHEN** DataPart 缺少 step 字段或格式不符
- **THEN** 静默忽略该 Part，不崩溃

### Requirement: TaskArtifactUpdateEvent 解码
客户端 SHALL 解码 `TaskArtifactUpdateEvent`，累加 artifact 文本到 summaryBuffer；当 `lastChunk=true` 时将 summaryBuffer 写入 summary。

#### Scenario: lastChunk 触发 summary 显示
- **WHEN** 收到 `lastChunk=true` 的 ArtifactUpdateEvent
- **THEN** summaryBuffer 内容赋值给 summary，UI 显示总结区

### Requirement: 任务完成检测
客户端 SHALL 在收到 `final=true` 的 StatusUpdateEvent 时将 state 置为 completed。

#### Scenario: 任务正常完成
- **WHEN** 收到 `{state: "completed", final: true}`
- **THEN** ConversationVM.state = .completed，进度泳道显示完成标记
