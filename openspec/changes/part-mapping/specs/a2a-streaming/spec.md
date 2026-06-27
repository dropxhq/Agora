## MODIFIED Requirements

### Requirement: TaskStatusUpdateEvent 解码
客户端 SHALL 解码 `TaskStatusUpdateEvent`，从 `status.message.parts` 中提取所有 Part（TextPart / DataPart / FilePart）并以 source=`message` 交由 PartRouter 处理，不再在解码层按 `step`/`round` 归组。

#### Scenario: 接收文本 Part
- **WHEN** 收到 status.message 含 TextPart
- **THEN** 解码为通用 Part 并以 source=message 传给 PartRouter

#### Scenario: 接收字典 Part
- **WHEN** 收到 status.message 含 DataPart（任意字典结构）
- **THEN** 解码为通用 Part 传给 PartRouter，由规则层决定归类与渲染

#### Scenario: Part 解码失败
- **WHEN** 某个 Part 结构无法识别为 text/data/file
- **THEN** 静默忽略该 Part，不崩溃

### Requirement: TaskArtifactUpdateEvent 解码
客户端 SHALL 解码 `TaskArtifactUpdateEvent`，从 `artifact.parts` 提取所有 Part 并以 source=`artifact` 交由 PartRouter 处理；文本类 artifact 在 `lastChunk=true` 前累加。

#### Scenario: lastChunk 触发结果定稿
- **WHEN** 收到 `lastChunk=true` 的 ArtifactUpdateEvent
- **THEN** 累加的文本 Part 定稿并以 source=artifact 交由 PartRouter（默认归 result 区）

#### Scenario: artifact 内含文件 Part
- **WHEN** artifact.parts 含 FilePart
- **THEN** 以 source=artifact 交由 PartRouter，按 image/file 渲染

## ADDED Requirements

### Requirement: FilePart 解码
客户端 SHALL 解码 A2A v0.3 的 FilePart：`{file:{bytes(base64)|uri, mimeType, name}}`，支持 bytes 与 uri 两种来源。

#### Scenario: 解码 bytes 文件
- **WHEN** FilePart 含 base64 `bytes` 与 `mimeType`
- **THEN** 解码为 Data 并携带 mimeType 供渲染

#### Scenario: 解码 uri 文件
- **WHEN** FilePart 含 `uri` 与 `mimeType`
- **THEN** 解码为 URL 引用，渲染时再异步加载

#### Scenario: bytes 与 uri 缺失
- **WHEN** FilePart 既无 bytes 也无 uri
- **THEN** 静默忽略该 Part，不崩溃
