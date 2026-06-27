# Agora 探索笔记

> 这是一份 **explore 模式** 的思考记录，不是最终设计。用于跨会话续接讨论。
> 最后更新：2026-05-31
> 状态：仍在探索，**尚未**形成 OpenSpec proposal，**尚未**写任何应用代码。

---

## 0. 一句话背景

Agora = A2A 协议的原生 macOS & iOS 客户端。当前代码库还是 Xcode SwiftData 空模板
（`Item` + 时间戳列表），没有任何 A2A 相关实现。OpenSpec 已初始化但零变更。

**定位澄清：Agora 是 A2A *Client*（代表用户向远程 agent 发请求的一方），不是 agent/server。**

---

## 1. 目标 MVP（用户拍板）

用户明确选择做 MVP，期望效果：

1. 用户提问后，能**实时渲染** Agent 后台的执行过程
2. 不要求 token 级流式输出，但**一个子任务完成就出一段输出**
3. 表现上**一段一段地**输出内容

具体场景：后端是一个 **ReActLoop Agent**，每轮 ReAct 输出
`reasoning → 选择的工具 → 工具执行结果`，直到最后一轮输出**总结**。
Agora 要展示「每轮的过程」+「最终总结」。

> 关键认知：这三个要求把 MVP 的核心钉在了 **streaming（流式）** 上，
> 不是"发一条消息→拉一个完成的 task"那种最薄骨架。流式是这个产品的核心价值。

---

## 2. A2A 协议关键事实（已核实，来自 a2a-protocol.org 官方 spec）

### 数据模型层级
```
Context (contextId)  ── 逻辑会话，归组多个 task
  └─ Task (taskId)   ── 有状态的工作单元，服务端生成 id
       ├─ status     ── TaskStatus { state, message?, timestamp }
       ├─ artifacts  ── 任务"输出"（结果）
       └─ history    ── Message 列表（多轮交互）
```

### 三种更新机制
| 机制 | 操作 | 特点 | 对原生 app |
|------|------|------|-----------|
| 轮询 | `GetTask` / `ListTasks` | 到处能用、延迟高 | ✅ 适合回前台对账 |
| 流式 SSE | `SendStreamingMessage` / `SubscribeToTask` | 低延迟、切后台就断 | ✅ MVP 首选 |
| 推送 webhook | `Create/Get/List/Delete PushNotificationConfig` | 断线也收、**需客户端有公网 HTTPS 端点** | ❌ 原生 app 做不到（NAT/挂起），除非加中继 server |

**Agora 的现实更新模型：前台流式、回前台轮询补齐。**
```
前台   → SendStreamingMessage / SubscribeToTask (SSE)
切后台 → 流断，task 在服务端继续
回前台 → GetTask / ListTasks(statusTimestampAfter) 对账
```

### 协议语义切分（重要！）
- **Message = 过程沟通**（task 发起、澄清、状态消息、追加输入）
- **Artifact = 任务输出**（结果）
- spec 明确："Messages SHOULD NOT 用来传递任务输出；结果用 Artifact 返回"

→ 映射到 ReAct：reasoning/工具 = 过程（走 status message），summary = 输出（走 artifact）

### 三种 binding + 版本分叉
- binding：JSON-RPC / HTTP+JSON(REST) / gRPC。Swift 首选 HTTP+JSON 或 JSON-RPC（都是 URLSession+SSE）；gRPC 太重，先放。
- **版本分叉（坑）：v1.0 移除了 `kind` 判别字段，v0.3 仍在用。** `Part` 这种最常见对象在两个版本结构不同：
  - v0.3：`{ "kind": "text", "text": "hi" }`
  - v1.0：`{ "text": "hi" }`
  - AgentCard 会声明接口版本，解码器需按版本分支。MVP 建议**锁定一个版本**。

### 流式事件类型
- `TaskStatusUpdateEvent` { taskId, contextId, status, final, metadata }
- `TaskArtifactUpdateEvent` { taskId, contextId, artifact, append, lastChunk, metadata }
- "一段一段输出"机制 = `artifactUpdate(append=true)` 累加 + `lastChunk=true` 定稿才显示

---

## 3. 我们设计的客户端归约器思路（概念，未实现）

每个回合维护：
```
rounds:  [ { round, reasoning, toolCalls[], results[] }, ... ]   // 喂进度泳道
summary: Artifact?                                                // 喂最终输出
state:   SUBMITTED / WORKING / COMPLETED / ...
```
收到 `statusUpdate` → 更新 state，从 message.parts 的 DataPart 按 `step`/`round` 归组；
收到 `artifactUpdate` → 累加/定稿 summary（lastChunk 时显示）。

### 设想的 DataPart 约定（轻量"扩展"）
每个 status 消息塞一个 `DataPart`（mediaType: application/json）：
```jsonc
{ "step": "reasoning",  "round": 1, "text": "..." }
{ "step": "tool_call",  "round": 1, "name": "web_search", "args": {...} }
{ "step": "tool_result","round": 1, "name": "web_search", "result": "...", "ok": true }
```
最终 summary 走普通 TextPart artifact。`round` 用于客户端归组同一轮。

> 正规做法是把约定登记成带 URI 的 `AgentExtension` 写进 AgentCard；MVP 先口头约定。

### UI 形态：双泳道
```
你: <问题>
─────────────────────
▾ 执行过程 (working ●)        ← 可折叠进度泳道，status 实时滚动
  💭 reasoning...
  🔧 tool_call(...)
  📥 ▸ tool_result (可折叠)
─────────────────────
📝 总结                       ← artifact 正文（lastChunk 时出现）
✓ 已完成
```

---

## 4. 关键发现：AgentScope 调研结论（已读源码，结论确定）

用户计划用 **AgentScope Runtime** 部署的 A2A server 做后端。调研结论：

### AgentScope Runtime 有"两套协议"（同一 agent，多个适配器）
```
ReActAgent → stream_printing_messages (yield reasoning/tool/text)
   ├─ A2AFastAPIDefaultAdapter   → A2A 端点（标准 A2A 事件）
   ├─ ResponseAPIDefaultAdapter  → /process 端点（AgentScope 自有 Response-API 协议）
   └─ AGUIDefaultAdapter         → AG-UI 前端协议
```

### ⚠️ 致命结论：现成的 A2A 适配器**丢掉了执行过程**
读了源码 `engine/deployers/adapter/a2a/a2a_adapter_utils.py`，白纸黑字：

1. **status 消息硬编码为 None** —— `response_to_task_status_update_event()` 里
   `TaskStatus(state=state, message=None, ...)`。
   → 状态泳道只有 `working→completed`，agent 想什么/调什么工具**一个字都不传**。

2. **reasoning/tool_call/tool_result 全压成扁平 artifact** ——
   转换只认 `TextContent/ImageContent/DataContent`（ContentType），
   完全没读 ReAct 的 `REASONING`/`FUNCTION_CALL`（MessageType）。
   reasoning 和最终答案都变成 `name="text"` 的 TextPart artifact，**客户端区分不了**。

3. 该 server 用 `kind="task"`/`kind="status-update"`/`context_id` → **A2A v0.3 风格**。

→ **印证了 AgentScope 客户端文档原话："A2A 只支持 chatbot 场景，不支持 agentic structured output"。这不是 bug，是当前实现的刻意取舍。**

### 参考价值（仍然有，分两层）
- **概念层（高度可参考）**：AgentScope 内部 `MessageType` 切分
  `REASONING / FUNCTION_CALL / FUNCTION_CALL_OUTPUT / MESSAGE / HEARTBEAT / ERROR`
  + `delta→completed` + `index`/`msg_id` 关联，
  **几乎一一对应我们设计的 `{step: reasoning/tool_call/tool_result}` 约定**——验证了思路正确。
- **A2A 线缆层（已证实有损）**：现成适配器透传不了过程，只给最终文本。

---

## 5. 待用户拍板的根本抉择（下次续接的核心议题）

用户目标（展示 ReAct 过程）与"现成 AgentScope A2A server"**冲突**。出路四选一：

| 方案 | 做什么 | 代价 | Agora 定位 |
|------|--------|------|-----------|
| **A. 自定义 A2A 适配器** | 继承 `ProtocolAdapter` 重写转换：reasoning→DataPart 进 `status.message`，工具→带类型 artifact | 改后端，产出合规 A2A | 仍是"通用 A2A 客户端" ✅ |
| **B. 直连 `/process`** | Agora 解析 AgentScope Response-API（原生带 reasoning/function_call/delta） | 放弃 A2A，绑死 AgentScope | 变成"AgentScope 客户端" |
| **C. 后端把过程当 artifact 发** | 不改适配器，agent 主动把每个 ReAct 步骤作为 `DataContent` yield，data 自带 `{step,round}` | 改 agent 代码 | 半通用 A2A |
| **D. AG-UI 适配器** | 用 `AGUIDefaultAdapter`（专为展示 agent 过程设计） | 放弃 A2A，偏 Web | 变成"AG-UI 客户端" |

**核心问题：Agora 到底是什么？**
- "任何 A2A agent 都能连的通用客户端" → 走 **A**（约定保持在 A2A 内，最正统）
- "我自己 AgentScope 后端的好用前端、想最快出效果" → **B** 更省事
  （Response-API 天生为展示 agent 过程设计，信息比 A2A 丰富；强行走 A2A 是把丰富信息挤过会丢语义的窄门）

> 我的倾向（待用户确认）：若灵魂是"通用 A2A 客户端"选 A；若主要配自己后端、求快选 B。

---

## 6. 下次续接的建议入口

1. **先回答第 5 节的 A/B/C/D 抉择**——这决定整个 MVP 数据契约。
2. 选定后可固化为 OpenSpec proposal（design 写死事件映射契约 + 归约器；tasks 拆步骤）。
3. 若想用真实数据校准：把 AgentScope Runtime 用 `A2AFastAPIDefaultAdapter` 跑起来，
   `curl -N` 抓 A2A 流式端点原始 SSE，确认 v0.3 结构细节。
4. 仍待定的次要决策：协议版本锁定（建议 0.3，因后端是 0.3）、binding（看 AgentCard）、
   MVP 无认证、持久化先内存（SwiftData 以后）、webhook 中继是否永久非目标。

## 7. 已确认的技术支撑点（实现时用）
- SSE 解析：`URLSession.bytes` 逐行读，无需第三方库。
- 设想的最小组件集：`A2AModels`(Codable) / `SSEClient` / `A2AClient` / `ConversationVM`(@Observable reducer) / `ConversationView`。
- 关键源码位置（AgentScope Runtime, 供方案 A/C 参考）：
  `src/agentscope_runtime/engine/deployers/adapter/a2a/a2a_adapter_utils.py`
  `.../a2a/a2a_protocol_adapter.py`（A2AFastAPIDefaultAdapter 入口）
