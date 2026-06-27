## Why

当前 MVP 把 A2A `Part` 的解码写死成 AgentScope 私有约定（`DataPart` 里必须有 `{step, round}`），只能接自家后端，且只认 text/data 两种 Part，无法展示图片与文件。要让 Agora 成为「能连任何 A2A server」的通用客户端，需要一个**默认即可渲染、又能按后端自定义重映射**的字段映射层。

## What Changes

- 新增**默认渲染规则**（对任何 A2A server 都成立，永远兜底）：
  - 文本 Part → Markdown 渲染
  - 字典/结构化 Part（DataPart）→ pretty-print 的 ```json 代码块
  - 文件 Part（FilePart）→ 图片卡片（`image/*`）或文件 chip（其他 MIME）
- 新增**默认归类**：`status.message` 内容 → 思考过程区；`artifact` 内容 → 最终结果区
- 新增**自定义映射规则引擎**（per-backend、可选、JSON 配置）：
  - 匹配条件：source（message/artifact/any）+ partType + dict 字段等值匹配
  - 变换动作：覆盖 lane（thinking/result）、指定 render（markdown/json/toolCard/image/file/hidden）、用 `$.path` 重映射字段
  - AgentScope 的 `{step, round}` 约定降级为「一份示例规则配置」，不再写死在代码里
- **BREAKING** 移除客户端对 `ReActStep`（`{step, round}`）的硬编码解码，改为通用 `Part` 解码 + 规则层
- 新增 `FilePart` 数据模型（`bytes` base64 / `uri` 两种来源）

## Capabilities

### New Capabilities
- `part-mapping`: A2A `Part` 到 UI 语义的映射层——默认渲染规则（text→markdown、dict→json、file→媒体）+ 默认归类（message/artifact→思考过程/结果）+ per-backend 自定义规则引擎（匹配→变换→字段重映射）

### Modified Capabilities
- `a2a-streaming`: 事件解码从「硬编码 ReActStep DataPart 按 step/round 归组」改为「通用 Part 解码（text/data/file），归组交给 part-mapping 层」；新增 FilePart 解码
- `conversation-ui`: 进度泳道/总结区的内容渲染从「纯文本 + 写死的 reasoning/tool 分组」改为「按 part-mapping 输出的 render 类型渲染（markdown/json/toolCard/image/file）」，lane 归类按 message/artifact + 规则覆盖

## Impact

- 新增 `PartRouter`（规则引擎）与映射规则数据模型
- 修改 `A2AModels.swift`：新增 `FilePart`、通用 `Part`，移除/降级 `ReActStep` 硬编码
- 修改 `ConversationVM.swift`：归约器改为消费 `PartRouter` 输出，而非直接读 `step` 字段
- 修改 `ConversationView.swift`/`RoundView`：按 render 类型分发到不同子视图（Markdown/JSON/ToolCard/Image/File）
- 引入 Markdown 渲染依赖（代码块/语法高亮）——打破现有「零第三方依赖」原则
- 映射规则挂在「后端」对象上，依赖后续 backend-registry 变更承载持久化（本变更先用内存/默认规则）
- 协议版本仍锁定 A2A v0.3；FilePart 结构按 v0.3
