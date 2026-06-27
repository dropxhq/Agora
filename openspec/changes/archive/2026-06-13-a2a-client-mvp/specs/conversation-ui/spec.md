## ADDED Requirements

### Requirement: 双泳道对话界面
界面 SHALL 包含两个区域：可折叠进度泳道（执行过程）和总结区，顺序展示，不同时滚动。

#### Scenario: 进度泳道实时更新
- **WHEN** 归约器收到新的 Round 数据
- **THEN** 进度泳道立即显示新内容，无需用户操作

#### Scenario: 总结区延迟出现
- **WHEN** summary 为 nil
- **THEN** 总结区不渲染；summary 有值后才出现

### Requirement: Round 分组展示
进度泳道 SHALL 按 round 编号分组，每组依序显示 reasoning → toolCalls → toolResults。

#### Scenario: 多轮展示
- **WHEN** 收到 round=1 和 round=2 的事件
- **THEN** UI 显示两个分组，各自包含对应步骤

### Requirement: 进度泳道可折叠
用户 SHALL 能折叠/展开进度泳道，折叠后只显示标题行。

#### Scenario: 折叠操作
- **WHEN** 用户点击进度泳道标题
- **THEN** 步骤内容折叠隐藏，再次点击展开

### Requirement: 任务状态指示
进度泳道标题 SHALL 显示当前状态：working 时显示动态指示，completed 时显示完成图标。

#### Scenario: working 状态
- **WHEN** state = .working
- **THEN** 标题显示 `circle.dotted` 图标

#### Scenario: completed 状态
- **WHEN** state = .completed
- **THEN** 标题显示 `checkmark.circle` 图标
