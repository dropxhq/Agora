## ADDED Requirements

### Requirement: 默认文本渲染
PartRouter SHALL 在无自定义规则命中时，将文本 Part（TextPart）渲染为 Markdown 内容。

#### Scenario: 纯文本渲染为 Markdown
- **WHEN** 收到 `{text: "## 标题\n- 项目"}` 的 TextPart 且无规则命中
- **THEN** 输出 RenderItem(render: .markdown) 交由视图按 Markdown 渲染

#### Scenario: 文本内含代码块
- **WHEN** 文本含 ```` ```swift ... ``` ````
- **THEN** Markdown 渲染器渲染该代码块，无需额外处理

### Requirement: 默认字典渲染
PartRouter SHALL 在无自定义规则命中时，将字典/结构化 Part（DataPart）渲染为 pretty-print 的 JSON 代码块。

#### Scenario: 字典渲染为 JSON 代码块
- **WHEN** 收到 `{data: {a: 1, b: "x"}}` 的 DataPart 且无规则命中
- **THEN** 输出 RenderItem(render: .json)，内容为带缩进的 JSON 字符串

#### Scenario: 嵌套字典
- **WHEN** DataPart 含嵌套对象/数组
- **THEN** JSON 序列化保留层级，按缩进展示

### Requirement: 默认文件渲染
PartRouter SHALL 将文件 Part（FilePart）按 MIME 类型渲染：`image/*` 渲染为图片，其他渲染为文件 chip。

#### Scenario: 图片文件
- **WHEN** FilePart 的 mimeType 为 `image/png`
- **THEN** 输出 RenderItem(render: .image)

#### Scenario: 非图片文件
- **WHEN** FilePart 的 mimeType 为 `application/pdf`
- **THEN** 输出 RenderItem(render: .file)

### Requirement: 默认泳道归类
PartRouter SHALL 在无规则覆盖 lane 时，按来源归类：`status.message` 的 Part 归 thinking，`artifact` 的 Part 归 result。

#### Scenario: message 归思考过程
- **WHEN** Part 来自 status.message
- **THEN** RenderItem.lane = .thinking

#### Scenario: artifact 归最终结果
- **WHEN** Part 来自 artifact
- **THEN** RenderItem.lane = .result

### Requirement: 自定义规则匹配
PartRouter SHALL 支持 per-backend 的有序规则列表，按 source、partType、dict 字段等值（AND）匹配，首条命中即应用。

#### Scenario: 字段等值命中
- **WHEN** 规则 `when{partType:dict, match{step:"tool_call"}}` 且 DataPart 含 `step="tool_call"`
- **THEN** 应用该规则的 then 动作

#### Scenario: 多条件 AND
- **WHEN** 规则要求 `source:message` 且 `match{step:"reasoning"}`，但 Part 来自 artifact
- **THEN** 该规则不命中，继续尝试后续规则

#### Scenario: 顺序优先
- **WHEN** 多条规则均可命中
- **THEN** 采用列表中第一条命中的规则

### Requirement: 规则字段重映射
命中规则的 then SHALL 支持用 `$.path` 从 Part 数据取值，重映射为目标渲染所需字段。

#### Scenario: 路径取值
- **WHEN** 规则 `fields{ name:"$.name", args:"$.args" }` 命中含 `{name:"web_search", args:{q:"x"}}` 的 DataPart
- **THEN** RenderItem 的目标字段 name="web_search"，args={q:"x"}

#### Scenario: 路径缺失
- **WHEN** `$.path` 在 Part 数据中不存在
- **THEN** 该字段取空值，不崩溃

### Requirement: 规则覆盖渲染与泳道
命中规则 SHALL 能覆盖默认的 render 类型与 lane 归类，render 取值范围为 markdown/json/toolCard/image/file/hidden。

#### Scenario: 覆盖为工具卡片
- **WHEN** 规则 `then{ render:"toolCard", lane:"thinking" }` 命中
- **THEN** 输出 RenderItem(render: .toolCard, lane: .thinking)

#### Scenario: 隐藏噪音 Part
- **WHEN** 规则 `then{ render:"hidden" }` 命中
- **THEN** 该 Part 不产生任何可见输出

### Requirement: 未命中降级兜底
PartRouter SHALL 在无任何规则命中时回落到默认渲染规则，保证渲染不中断。

#### Scenario: 陌生后端无规则
- **WHEN** 某后端未配置任何规则
- **THEN** 所有 Part 按默认规则（text→markdown、dict→json、file→媒体）渲染

### Requirement: 内置 AgentScope 示例规则集
系统 SHALL 随包提供一份可套用的 AgentScope 示例规则集，将 `{step}` 约定映射为思考过程与工具卡片。

#### Scenario: 套用示例规则
- **WHEN** 用户为某后端套用 AgentScope 示例规则集
- **THEN** `step=reasoning` 渲染为 thinking 区 Markdown（取 `$.text`），`step=tool_call`/`tool_result` 渲染为 toolCard
