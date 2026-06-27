## Why

Agora 是一个原生 macOS/iOS 客户端，目标是作为通用 A2A 协议客户端，让用户能实时观察 Agent 的执行过程（reasoning、工具调用、结果），而不只是收到最终答案。现有代码库是空模板，需要从零实现核心功能。

## What Changes

- 新增 A2A 数据模型（Codable）：Task、Message、Part、事件类型
- 新增 SSE 流式客户端（基于 URLSession.bytes）
- 新增 A2AClient：封装 sendStreamingMessage / getTask
- 新增 ConversationVM：归约器，将 SSE 事件流映射为 UI 状态
- 新增 ConversationView：双泳道 UI（进度泳道 + 总结区）
- 替换 Xcode 模板占位代码（Item.swift / ContentView.swift）

## Capabilities

### New Capabilities

- `a2a-streaming`: 通过 SSE 接收 TaskStatusUpdateEvent / TaskArtifactUpdateEvent，实时渲染 ReAct 执行过程
- `conversation-ui`: 双泳道对话界面——可折叠进度泳道（按 round 分组）+ 总结区（lastChunk 后显示）

### Modified Capabilities

（无，从空模板开始）

## Impact

- 替换 `agora/agora/Item.swift`、`ContentView.swift`
- 新增 5 个 Swift 文件：`A2AModels.swift`、`SSEClient.swift`、`A2AClient.swift`、`ConversationVM.swift`、`ConversationView.swift`
- 无第三方依赖，纯 URLSession + SwiftUI
- 协议版本锁定 A2A v0.3（与 AgentScope 后端一致）
- DataPart 约定（step/round 字段）为客户端与后端的私有扩展协议
