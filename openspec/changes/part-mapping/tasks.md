## 1. 数据模型

- [ ] 1.1 在 `A2AModels.swift` 新增通用 `Part`（text / data / file 三态）与 `FilePart`（`bytes` base64 / `uri`, mimeType, name）
- [ ] 1.2 移除/降级 `ReActStep` 硬编码解码，DataPart 改为持有任意字典（`[String: JSONValue]`）
- [ ] 1.3 定义 `RenderItem`（lane + render 枚举）与 `ImageSource`（bytes/uri）、`ToolCardData`、`FileRef`

## 2. 规则引擎

- [ ] 2.1 定义映射规则数据模型 `MappingRule`（when: source/partType/match；then: lane/render/fields）及 JSON Codable
- [ ] 2.2 实现 `$.path` 简单路径取值器（支持 `$.a.b`，缺失返回空）
- [ ] 2.3 实现 `PartRouter.route(part, source, rules) -> RenderItem`：按规则顺序匹配（等值 AND），首条命中即用
- [ ] 2.4 实现默认兜底层：text→markdown、dict→pretty JSON、file→image/file，归类 message→thinking / artifact→result
- [ ] 2.5 内置 AgentScope 示例规则集（reasoning/tool_call/tool_result）

## 3. 归约器改造

- [ ] 3.1 改 `ConversationVM`：解码 StatusUpdateEvent → 提取 Parts(source=message) → PartRouter → RenderItem 列表
- [ ] 3.2 改 ArtifactUpdateEvent 处理：提取 Parts(source=artifact)，文本类 lastChunk 前累加，交 PartRouter
- [ ] 3.3 状态树由 `rounds/summary` 改为按 lane 分组的 `RenderItem` 列表（thinking[] / result[]）

## 4. 渲染视图

- [ ] 4.1 引入 Markdown 渲染依赖（swift-markdown-ui 或等价），封装 `MarkdownView`（含代码块高亮）
- [ ] 4.2 实现 `JSONCodeBlockView`（等宽、代码块样式）
- [ ] 4.3 实现 `ToolCardView`（名称 + args 折叠 + result + ok 状态）
- [ ] 4.4 实现 `ImageItemView`（bytes 解码 / uri 异步加载 / 失败占位）
- [ ] 4.5 实现 `FileChipView`（类型图标 + 文件名，点击打开/保存）
- [ ] 4.6 改 `ConversationView`：按 RenderItem.render 分发到上述子视图，hidden 跳过

## 5. 验证

- [ ] 5.1 单元测试 PartRouter：默认层 text/dict/file 三类、归类 message/artifact
- [ ] 5.2 单元测试规则层：等值匹配、AND、顺序优先、`$.path` 取值、缺失降级、hidden
- [ ] 5.3 用 AgentScope 示例规则跑一遍真实/模拟 SSE，确认 reasoning→markdown、tool→toolCard、artifact→result
- [ ] 5.4 验证图片（bytes+uri）与文件 chip 渲染；构建通过
