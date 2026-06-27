## MODIFIED Requirements

### Requirement: Round 分组展示
进度泳道（thinking 区）SHALL 按到达顺序渲染 PartRouter 输出的 RenderItem，每个 RenderItem 依其 render 类型分发到对应子视图。round 分组不再由解码层固定产生，而是由规则层（如 AgentScope 示例规则）在生成 toolCard 时携带。

#### Scenario: 按 RenderItem 顺序渲染
- **WHEN** thinking 区依次收到 markdown、toolCard 两个 RenderItem
- **THEN** UI 按顺序渲染 Markdown 块与工具卡片

#### Scenario: 无规则时的过程展示
- **WHEN** 后端未配置规则，思考过程为 text/dict Part
- **THEN** thinking 区按 Markdown 与 JSON 代码块渲染，仍可阅读

## ADDED Requirements

### Requirement: 按 render 类型分发渲染
对话视图 SHALL 根据 RenderItem 的 render 类型分发：markdown→Markdown 视图、json→代码块视图、toolCard→工具卡片、image→图片视图、file→文件 chip、hidden→不渲染。

#### Scenario: Markdown 渲染
- **WHEN** RenderItem.render = .markdown
- **THEN** 使用 Markdown 渲染器显示，含代码块语法高亮

#### Scenario: JSON 代码块渲染
- **WHEN** RenderItem.render = .json
- **THEN** 以等宽字体的代码块样式显示 JSON 内容

#### Scenario: hidden 不渲染
- **WHEN** RenderItem.render = .hidden
- **THEN** 不产生任何可见 UI

### Requirement: 图片展示
对话视图 SHALL 内联展示图片型 RenderItem，支持 bytes 与 uri 两种来源。

#### Scenario: 展示 bytes 图片
- **WHEN** image RenderItem 携带 Data 与 mimeType
- **THEN** 解码并内联显示图片卡片

#### Scenario: 展示 uri 图片
- **WHEN** image RenderItem 携带 URL
- **THEN** 异步加载并显示，加载中显示占位

#### Scenario: 图片加载失败
- **WHEN** 图片数据损坏或 URL 加载失败
- **THEN** 显示失败占位，不崩溃

### Requirement: 文件展示
对话视图 SHALL 以文件 chip 展示非图片文件，显示文件名与类型图标。

#### Scenario: 展示文件 chip
- **WHEN** file RenderItem 携带文件名与 mimeType
- **THEN** 显示带类型图标与文件名的 chip

#### Scenario: 点击文件 chip
- **WHEN** 用户点击文件 chip
- **THEN** 触发打开/保存操作（bytes 写出或 uri 打开）
