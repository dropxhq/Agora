## 1. 数据模型

- [x] 1.1 创建 `A2AModels.swift`：定义 TextPart、DataPart、ReActStep、Message、TaskStatus、TaskStatusUpdateEvent、TaskArtifactUpdateEvent、Artifact（v0.3 Codable）
- [x] 1.2 定义 `Round`、`ToolCall`、`ToolResult` 客户端状态模型

## 2. 网络层

- [x] 2.1 创建 `SSEClient.swift`：`URLSession.bytes` 逐行解析，返回 `AsyncThrowingStream<String>`
- [x] 2.2 创建 `A2AClient.swift`：实现 `sendStreamingMessage` 和 `getTask`

## 3. 归约器

- [x] 3.1 创建 `ConversationVM.swift`：`@Observable` 类，含 `rounds`、`summary`、`state`、`summaryBuffer`
- [x] 3.2 实现 `apply(_ event: String)`：解码 StatusUpdateEvent → upsertRound，解码 ArtifactUpdateEvent → 累加/定稿 summary
- [x] 3.3 实现 `upsertRound`：按 round 索引找/建 Round，按 step 填字段

## 4. UI

- [x] 4.1 创建 `ConversationView.swift`：输入框 + TurnView
- [x] 4.2 实现进度泳道 `DisclosureGroup`：ForEach rounds，显示 reasoning/toolCalls
- [x] 4.3 实现总结区：`summary != nil` 才渲染
- [x] 4.4 实现状态图标：working → `circle.dotted`，completed → `checkmark.circle`

## 5. 收尾

- [x] 5.1 替换 `ContentView.swift` 入口为 `ConversationView`
- [x] 5.2 删除 `Item.swift` 模板文件
- [x] 5.3 配置 `agoraApp.swift` 注入 `A2AClient`（hardcode 本地 server URL 供调试）
