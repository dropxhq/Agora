## Context

从 Xcode SwiftData 空模板开始，实现 A2A 协议客户端 MVP。后端为 AgentScope Runtime A2A 适配器（v0.3 风格），运行 ReActLoop Agent。核心需求是实时渲染 Agent 执行过程（reasoning → 工具调用 → 工具结果 → 总结）。

## Goals / Non-Goals

**Goals:**
- SSE 流式接收 A2A 事件，实时渲染执行过程
- 按 round 分组展示 ReAct 步骤（双泳道 UI）
- 纯 URLSession + SwiftUI，零第三方依赖

**Non-Goals:**
- 多会话管理、持久化（SwiftData 留待后续）
- 认证 / 推送通知
- 支持 A2A v1.0 或 gRPC binding
- 后台断线重连（切前台后用 GetTask 对账）

## Decisions

### 1. 协议版本锁定 v0.3
后端 AgentScope 输出 v0.3 风格（有 `kind` 字段，`context_id` 等），客户端锁定 v0.3 解码。不做版本协商，MVP 不需要。

### 2. DataPart 私有约定承载过程信息
A2A 标准不规定 status.message 内容。用 `DataPart(mediaType: application/json)` 携带 `{step, round, ...}`，客户端按此解码进度泳道。这是客户端与后端的口头约定，后续可升级为 AgentExtension。

### 3. Summary 等 lastChunk 才显示
Artifact 分 chunk 累加，`lastChunk=true` 时一次性显示，避免流式打字机实现复杂度。进度泳道已提供足够的实时感。

### 4. 归约器模式（Reducer）
`ConversationVM` 是纯归约器：`apply(SSEEvent)` → 更新状态树。状态树：
```
rounds: [Round]   ← StatusUpdateEvent → 按 round 分组
summary: String?  ← ArtifactUpdateEvent(lastChunk) 定稿
state: TaskState
```
`@Observable` 自动驱动 SwiftUI 重绘，无需手动 `objectWillChange`。

### 5. 文件结构
```
A2AModels.swift     — Codable 数据模型
SSEClient.swift     — URLSession.bytes 逐行解析 SSE
A2AClient.swift     — sendStreamingMessage / getTask
ConversationVM.swift — @Observable 归约器
ConversationView.swift — 双泳道 SwiftUI 视图
```

## Risks / Trade-offs

- **后端约定不稳定** → DataPart 结构若后端改动，客户端解码静默失败；缓解：解码失败时降级显示原始文本
- **v0.3 绑定** → 接其他 A2A v1.0 server 需改解码层；缓解：模型层隔离，改动局限于 A2AModels.swift
- **前台限定** → 切后台 SSE 断开，task 继续跑；缓解：回前台调 GetTask 对账（MVP 可暂不实现）
