## Context

MVP 阶段客户端把 A2A `Part` 解码写死为 AgentScope 私有约定 `ReActStep{step, round}`，并只认 text/data 两种 Part。这导致：(1) 只能接自家后端；(2) 无法展示图片/文件；(3) 思考过程/结果的归类依赖后端必须发 `step` 字段。

本设计把映射重构为两层：一层**默认规则**（任何 A2A server 都能渲染，永远兜底），一层**per-backend 自定义规则引擎**（把私有约定从代码降级为配置）。协议版本仍锁定 A2A v0.3。

## Goals / Non-Goals

**Goals:**
- 默认规则下，不做任何配置也能渲染任意 A2A server 的 text/dict/file Part
- 自定义规则可按后端覆盖归类（lane）、渲染方式（render）、字段重映射（`$.path`）
- 新增 FilePart，支持图片内联与文件 chip
- AgentScope `{step, round}` 表达为一份示例规则，而非硬编码

**Non-Goals:**
- 可视化规则编辑器（先 JSON 配置/粘贴）
- 规则的复杂表达式 / 完整 JSONPath（只做等值匹配 + 简单路径取值）
- 多后端持久化（由后续 backend-registry 变更承载，本变更先用内存 + 内置默认规则集）
- A2A v1.0 / gRPC 兼容
- 用户向 agent 发送图片/文件（多模态输入）——仅做展示

## Decisions

### 1. 两层映射：默认兜底 + 规则覆盖
`PartRouter.route(part, source) -> RenderItem`。先尝试匹配 backend 的规则列表（首条命中即用），未命中则落默认层。
- 默认层（写死）：text→markdown；dict→pretty JSON 代码块；file→image(`image/*`)/file。
- 默认归类：source 为 `message` → `.thinking`；`artifact` → `.result`。

**为何**：保证「接任何 server 不崩、有内容看」是基线能力，私有约定只是增强。备选（纯硬编码识别 step）被否，因为绑死后端。

### 2. 规则结构：匹配 → 变换
```jsonc
{
  "when": {
    "source": "message | artifact | any",
    "partType": "text | dict | file | any",
    "match": { "step": "tool_call" }      // dict 字段等值，AND 关系
  },
  "then": {
    "lane": "thinking | result",          // 可选，覆盖默认归类
    "render": "markdown | json | toolCard | image | file | hidden",
    "fields": { "name": "$.name", "args": "$.args" }  // $.path 取值重映射
  }
}
```
匹配表达力锁定「中档」：dict 字段等值匹配 + `$.a.b` 简单路径取值。`hidden` 用于丢弃噪音 Part。

**为何**：等值 + 简单路径足以表达 AgentScope 约定，又不至于做成一门 DSL。完整 JSONPath/条件表达式被否（工作量与维护成本过高）。

### 3. RenderItem：归约器与视图之间的统一中间表示
```
RenderItem {
  lane:   .thinking | .result
  render: .markdown(String) | .json(String) | .toolCard(ToolCardData)
          | .image(ImageSource) | .file(FileRef) | .hidden
}
ImageSource = .bytes(Data, mime) | .uri(URL)
```
`ConversationVM` 归约器只消费 `RenderItem`，不再读 `step`。视图按 `render` 分发到子视图。

**为何**：把「协议/规则」与「UI 渲染」解耦，规则变化不波及视图，反之亦然。

### 4. AgentScope 约定 = 内置示例规则集
随包附带一份命名规则集（reasoning→thinking/markdown 取 `$.text`；tool_call→thinking/toolCard；tool_result→thinking/toolCard），用户可一键套用或改写。

**为何**：兑现「方案A + 自定义规则」，且不丢失 MVP 已有的工具卡片体验。

### 5. FilePart 与 Markdown 渲染
- FilePart 解码 `{file:{bytes|uri, mimeType, name}}`（v0.3）。`bytes` 直接解码 Data；`uri` 异步加载（鉴权/缓存留待 backend-registry）。
- Markdown 渲染引入第三方库（如 swift-markdown-ui + 高亮），**打破零依赖原则**——这是有意识的取舍，代码块/语法高亮自研成本过高。

## Risks / Trade-offs

- **打破零依赖** → 引入 markdown 库增加体积与维护面。缓解：仅此一处依赖，封装在渲染子视图内，可替换。
- **规则与后端结构漂移** → 后端改了 dict 结构，规则静默不命中、降级为 json 代码块。缓解：降级行为本身可读（仍显示原始 json），不崩溃。
- **bytes 大图撑爆内存/消息** → base64 大图解码占内存。缓解：设大小阈值，超限提示或转存；uri 优先。
- **规则只挂内存** → 本变更未做持久化，重启丢失自定义规则。缓解：内置默认 + AgentScope 示例规则集随包；持久化由 backend-registry 接手。
- **首条命中即用的顺序敏感** → 规则顺序影响结果。缓解：文档说明「具体规则在前、宽泛规则在后」。

## Open Questions

- `uri` 类型图片/文件的鉴权与缓存策略（与 backend-registry 的 auth 一并定）。
- 规则集是否需要「全局默认 + 后端覆盖」两级，还是只 per-backend（当前设计：只 per-backend + 内置默认兜底）。
- `match` 是否需要支持非 string 值（数字/布尔）等值匹配。
