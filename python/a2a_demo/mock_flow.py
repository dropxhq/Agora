"""Mock ReAct agent logic compatible with Agora A2A 1.0 client."""

from __future__ import annotations

import asyncio
import re
import uuid
from typing import Any, Optional

from a2a.helpers import (
    new_data_part,
    new_raw_part,
    new_task,
    new_task_from_user_message,
    new_text_part,
    new_url_part,
)
from a2a.server.agent_execution import RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
from a2a.types import TaskState

MULTI_TASK_TRIGGERS = ("multi task", "multi-task", "multitask", "多任务")
MARKDOWN_ARCH_TRIGGERS = (
    "mock-markdown-arch",
    "markdown-arch",
    "markdown arch",
    "markdown_arch",
    "架构文档",
    "markdown架构",
)
ALL_ARTIFACTS_TRIGGERS = (
    "mock-all-artifacts",
    "all-artifacts",
    "all artifacts",
    "all_artifacts",
    "全部artifact",
    "全部 artifact",
    "artifact类型",
    "artifact 类型",
)
DEFAULT_SUBTASKS = (
    "收集背景信息",
    "检索相关资料",
    "整理并输出总结",
)
# Minimal valid 1×1 PNG (red pixel) for raw binary file demos.
_PNG_1X1 = bytes.fromhex(
    "89504e470d0a1a0a0000000d494844520000000100000001080200000090"
    "7753de0000000c49444154789c63f8cfc0000003010100c9fe92ef0000000049454e44ae426082"
)


class MockAgent:
    """Mock agent that emits ReAct-style status and artifact updates."""

    async def run(self, user_text: str, task_updater: TaskUpdater) -> None:
        if is_all_artifacts_demo(user_text):
            await emit_all_artifacts_task(task_updater, user_text)
            return
        if is_markdown_arch_demo(user_text):
            await emit_markdown_arch_task(task_updater, user_text)
            return
        await emit_mock_task(task_updater, user_text)


def is_multi_task_demo(user_text: str) -> bool:
    lowered = user_text.strip().lower()
    return any(trigger in lowered for trigger in MULTI_TASK_TRIGGERS)


def is_markdown_arch_demo(user_text: str) -> bool:
    lowered = user_text.strip().lower()
    return any(trigger in lowered for trigger in MARKDOWN_ARCH_TRIGGERS)


def is_all_artifacts_demo(user_text: str) -> bool:
    lowered = user_text.strip().lower()
    return any(trigger in lowered for trigger in ALL_ARTIFACTS_TRIGGERS)


def _strip_multi_task_trigger(user_text: str) -> str:
    text = user_text.strip()
    for trigger in MULTI_TASK_TRIGGERS:
        pattern = re.compile(re.escape(trigger), re.IGNORECASE)
        text = pattern.sub("", text)
    return text.strip(" \t:：-—|")


def _parse_subtasks(user_text: str) -> list[str]:
    remainder = _strip_multi_task_trigger(user_text)
    if not remainder:
        return list(DEFAULT_SUBTASKS)

    for separator in (";", "；", "|", "\n"):
        if separator in remainder:
            parts = [part.strip() for part in remainder.split(separator)]
            labels = [part for part in parts if part]
            if len(labels) >= 2:
                return labels

    if "、" in remainder:
        parts = [part.strip() for part in remainder.split("、")]
        labels = [part for part in parts if part]
        if len(labels) >= 2:
            return labels

    return [remainder, *DEFAULT_SUBTASKS[1:]]


def _mock_steps(user_text: str, *, subtask_index: Optional[int] = None) -> list[dict[str, Any]]:
    query = user_text.strip() or "示例问题"
    prefix = f"子任务 {subtask_index}：" if subtask_index is not None else ""
    return [
        {"step": "task_start", "round": 0, "text": query},
        {
            "step": "reasoning",
            "round": 1,
            "text": f"{prefix}用户想了解「{query}」。我先检索相关信息，再整理成简明回答。",
        },
        {
            "step": "tool_call",
            "round": 1,
            "name": "web_search",
            "args": {"query": query, "limit": 3},
        },
        {
            "step": "tool_result",
            "round": 1,
            "name": "web_search",
            "result": f"找到 3 条与「{query}」相关的模拟结果。",
            "ok": True,
        },
        {
            "step": "reasoning",
            "round": 2,
            "text": f"{prefix}检索结果足够，接下来生成总结。",
        },
    ]


def _mock_summary(
    user_text: str,
    *,
    subtask_index: Optional[int] = None,
    total: Optional[int] = None,
) -> str:
    query = user_text.strip() or "示例问题"
    header = ""
    if subtask_index is not None and total is not None:
        header = f"[子任务 {subtask_index}/{total}] "
    return (
        f"{header}关于「{query}」的模拟回答：\n\n"
        "这是 A2A Demo Server 返回的占位内容，用于调试 Agora 客户端的流式渲染。"
        "实际接入真实 Agent 后，此处会替换为模型生成的总结。"
    )


def _markdown_arch_topic(user_text: str) -> str:
    text = user_text.strip()
    for trigger in MARKDOWN_ARCH_TRIGGERS:
        text = re.compile(re.escape(trigger), re.IGNORECASE).sub("", text)
    text = text.strip(" \t:：-—|/").strip()
    return text or "Agora A2A Client"


def _markdown_arch_steps(topic: str) -> list[dict[str, Any]]:
    """Multi-tool rounds used before/after intermediate architecture drafts."""
    return [
        {"step": "task_start", "round": 0, "text": f"生成「{topic}」架构文档"},
        {
            "step": "reasoning",
            "round": 1,
            "text": (
                f"先摸清「{topic}」的边界与约束。本轮会并行做检索、组件盘点，"
                "并核对现有接口约定。"
            ),
        },
        {
            "step": "tool_call",
            "round": 1,
            "name": "web_search",
            "args": {"query": f"{topic} architecture overview", "limit": 5},
        },
        {
            "step": "tool_result",
            "round": 1,
            "name": "web_search",
            "result": f"检索到 5 篇与「{topic}」相关的架构综述。",
            "ok": True,
        },
        {
            "step": "tool_call",
            "round": 1,
            "name": "codebase_scan",
            "args": {"path": "agora/", "focus": ["A2AClient", "ConversationVM"]},
        },
        {
            "step": "tool_result",
            "round": 1,
            "name": "codebase_scan",
            "result": "识别模块：Transport / Session / UI Lane / Summary Renderer。",
            "ok": True,
        },
        {
            "step": "tool_call",
            "round": 1,
            "name": "api_catalog",
            "args": {"protocol": "A2A", "version": "1.0"},
        },
        {
            "step": "tool_result",
            "round": 1,
            "name": "api_catalog",
            "result": "已列出 message/stream、task/get、agent-card 三类接口。",
            "ok": True,
        },
        {
            "step": "reasoning",
            "round": 2,
            "text": (
                "第一轮材料足够画出草图。再补一层数据流与依赖检查，"
                "然后输出中间版 Markdown 架构文档。"
            ),
        },
        {
            "step": "tool_call",
            "round": 2,
            "name": "dependency_graph",
            "args": {"roots": ["SwiftUI", "UniFFI", "a2a-demo"]},
        },
        {
            "step": "tool_result",
            "round": 2,
            "name": "dependency_graph",
            "result": "SwiftUI → ConversationVM → A2AClient → Rust UniFFI → Demo Server。",
            "ok": True,
        },
        {
            "step": "tool_call",
            "round": 2,
            "name": "trace_sample",
            "args": {"scenario": "mock-react", "rounds": 2},
        },
        {
            "step": "tool_result",
            "round": 2,
            "name": "trace_sample",
            "result": "样本链路：reasoning → tool_call/result ×N → artifact(markdown)。",
            "ok": True,
        },
        # Marker consumed by emit_markdown_arch_task to insert draft artifact.
        {"step": "__emit_draft__", "round": 2},
        {
            "step": "reasoning",
            "round": 3,
            "text": (
                "中间稿已发出。继续核实风险与扩展点，再输出最终版 Markdown 架构文档。"
            ),
        },
        {
            "step": "tool_call",
            "round": 3,
            "name": "risk_checklist",
            "args": {"items": ["streaming cancel", "markdown tables", "skill routing"]},
        },
        {
            "step": "tool_result",
            "round": 3,
            "name": "risk_checklist",
            "result": "风险项已标注：流取消、表格渲染、slash skill 路由。",
            "ok": True,
        },
        {
            "step": "tool_call",
            "round": 3,
            "name": "diagram_render",
            "args": {"format": "mermaid", "views": ["context", "container"]},
        },
        {
            "step": "tool_result",
            "round": 3,
            "name": "diagram_render",
            "result": "已生成 context / container 两层示意图（文本形式）。",
            "ok": True,
        },
        {
            "step": "tool_call",
            "round": 3,
            "name": "doc_lint",
            "args": {"checks": ["heading hierarchy", "table syntax", "link targets"]},
        },
        {
            "step": "tool_result",
            "round": 3,
            "name": "doc_lint",
            "result": "文档 lint 通过：标题层级与表格语法可用。",
            "ok": True,
        },
        {
            "step": "reasoning",
            "round": 4,
            "text": "终检完成，准备发布最终 Markdown 架构文档。",
        },
    ]


def _markdown_arch_draft(topic: str) -> str:
    return f"""# {topic} 架构文档（中间稿）

> 草图阶段：结构完整但细节仍待补全。

## 目标

为「{topic}」梳理一套可调试的客户端/Agent 协作架构，覆盖：

1. 连接与会话
2. ReAct 过程可视化
3. Markdown 结果渲染

## 组件草图

| 层级 | 组件 | 职责 |
| --- | --- | --- |
| UI | ConversationView | 展示过程泳道与总结 |
| State | ConversationVM | 归约 stream 事件 |
| Transport | A2AClient / UniFFI | JSON-RPC + SSE |
| Mock | a2a-demo | 输出模拟 ReAct / Markdown |

## 初步数据流

```text
User → InputBar → ConversationVM.send
                 → A2AClient.stream
                 → status(DataPart) / artifact(TextPart)
                 → rounds + summary(Markdown)
```

## 待补充

- 取消流与局部失败恢复
- 表格/代码块渲染边界情况
- Skill 路由与 slash 命令一致性
"""


def _markdown_arch_final(topic: str) -> str:
    return f"""# {topic} 架构文档（最终版）

## 一句话定义

`{topic}` 采用 **A2A Streaming + ReAct Lane + Markdown Summary** 的三层结构：过程走 status，结论走 artifact。

## 系统上下文

| Actor | 交互 |
| --- | --- |
| 用户 | 在 Agora 中提问 / 选择 Skill |
| Agora Client | 管理 Backend、Session，渲染过程与 Markdown |
| A2A Demo Agent | 回放 reasoning / tool / markdown 架构 |

## 容器视图

### 1. Conversation Shell

- `MainView`：Backend / Session 导航
- `ConversationView`：消息区 + 输入栏
- `GlassInputBar`：发送、停止、Skill（含 `/new`）

### 2. Execution Lane

每个 round：

1. **reasoning**（可展开）
2. 多个 **tool_call**
3. 对应 **tool_result**（嵌套在 call 下）

### 3. Summary Surface

- Artifact 以 Markdown 写入 `summary`
- 不同 artifact 各自保留，互不覆盖；同 artifact 内 `append=true` 追加流式块
- `MarkdownText`（MarkdownUI）渲染标题 / 列表 / 表格

## 关键时序

```text
1) message/stream
2) status: reasoning
3) status: tool_call / tool_result (×N)
4) artifact: markdown draft (中间稿)
5) status: more tools
6) artifact: markdown final (最终版, lastChunk)
7) task completed
```

## 关键决策

| 主题 | 决策 |
| --- | --- |
| 过程事件 | `DataPart.step` + `round` |
| 最终答案 | Text artifact + Markdown 渲染 |
| 中间稿 | 草稿与终稿为不同 artifact，客户端按序保留 |
| Skill | `/mock-markdown-arch` 触发本流程 |

## 验收清单

- [x] 单 round 多 tool call/result
- [x] 中间返回 Markdown 架构稿
- [x] 最终返回 Markdown 架构终稿
- [x] Agora 侧可折叠展示工具链

---

如需继续扩展（多子任务 / 真实 Agent），可在此架构上替换 `a2a-demo` 执行器。
"""


async def _emit_steps(
    updater: TaskUpdater,
    steps: list[dict[str, Any]],
    *,
    step_delay: float,
) -> None:
    for step in steps:
        if step.get("step") in {"__emit_draft__", "__emit_artifacts__"}:
            continue
        message = updater.new_agent_message(
            [new_data_part(step, media_type="application/json")]
        )
        await updater.update_status(
            TaskState.TASK_STATE_WORKING,
            message=message,
        )
        await asyncio.sleep(step_delay)


def _all_artifacts_topic(user_text: str) -> str:
    text = user_text.strip()
    for trigger in ALL_ARTIFACTS_TRIGGERS:
        text = re.compile(re.escape(trigger), re.IGNORECASE).sub("", text)
    text = text.strip(" \t:：-—|/").strip()
    return text or "A2A Artifact Types"


def _all_artifacts_steps(topic: str) -> list[dict[str, Any]]:
    """ReAct rounds around a mid-stream emission of every A2A Part kind."""
    return [
        {"step": "task_start", "round": 0, "text": f"演示「{topic}」全部 artifact 类型"},
        {
            "step": "reasoning",
            "round": 1,
            "text": (
                f"目标是把 A2A 1.0 可能的 Part 形态都作为独立 artifact 发出："
                f"text / data / raw(file bytes) / url(file uri)。先核对协议字段。"
            ),
        },
        {
            "step": "tool_call",
            "round": 1,
            "name": "protocol_lookup",
            "args": {"spec": "A2A", "version": "1.0", "focus": "Part oneof"},
        },
        {
            "step": "tool_result",
            "round": 1,
            "name": "protocol_lookup",
            "result": "Part content: text | data | raw | url；可附带 mediaType / filename。",
            "ok": True,
        },
        {
            "step": "tool_call",
            "round": 1,
            "name": "sample_fixture",
            "args": {
                "kinds": ["text", "data", "raw", "url"],
                "include_binary": True,
            },
        },
        {
            "step": "tool_result",
            "round": 1,
            "name": "sample_fixture",
            "result": "已准备 Markdown、JSON、PNG bytes、远程 URL 四类样例。",
            "ok": True,
        },
        {
            "step": "reasoning",
            "round": 2,
            "text": "材料齐了。先发出中间批次的全类型 artifact，再做一次校验并给出终稿说明。",
        },
        {
            "step": "tool_call",
            "round": 2,
            "name": "payload_pack",
            "args": {"topic": topic, "bundle": "mid-stream-artifacts"},
        },
        {
            "step": "tool_result",
            "round": 2,
            "name": "payload_pack",
            "result": "中间批次打包完成：4 个独立 artifact + 1 个混合 parts artifact。",
            "ok": True,
        },
        # Marker consumed by emit_all_artifacts_task.
        {"step": "__emit_artifacts__", "round": 2},
        {
            "step": "reasoning",
            "round": 3,
            "text": "中间 artifact 已发出。再核对客户端是否能按 artifactId 保留各类型，并输出终稿索引。",
        },
        {
            "step": "tool_call",
            "round": 3,
            "name": "client_compat_check",
            "args": {
                "expects": [
                    "text summary markdown",
                    "data structured json",
                    "raw file bytes",
                    "url file reference",
                    "mixed multi-part",
                ]
            },
        },
        {
            "step": "tool_result",
            "round": 3,
            "name": "client_compat_check",
            "result": "协议侧字段齐全；客户端可按需扩展非 text 渲染。",
            "ok": True,
        },
        {
            "step": "tool_call",
            "round": 3,
            "name": "doc_index",
            "args": {"format": "markdown", "sections": ["catalog", "wire format"]},
        },
        {
            "step": "tool_result",
            "round": 3,
            "name": "doc_index",
            "result": "终稿索引已生成。",
            "ok": True,
        },
        {
            "step": "reasoning",
            "round": 4,
            "text": "校验完成，发布最终 Markdown 目录。",
        },
    ]


def _all_artifacts_text_doc(topic: str) -> str:
    return f"""# {topic} — Text Artifact

> A2A `Part.text` 样例（`mediaType=text/markdown`）。

## 本批次将发出的类型

| Part | Artifact name | 说明 |
| --- | --- | --- |
| text | `artifact-text` | 本 Markdown |
| data | `artifact-data` | 结构化 JSON |
| raw | `artifact-raw-text` / `artifact-raw-png` | 内嵌文件 bytes |
| url | `artifact-url` | 远端文件引用 |
| mixed | `artifact-mixed` | 同一 artifact 含多种 Part |

```text
status(DataPart ReAct) → artifacts(text|data|raw|url) → status → artifact(text final)
```
"""


def _all_artifacts_data_payload(topic: str) -> dict[str, Any]:
    return {
        "kind": "a2a.data",
        "topic": topic,
        "protocolVersion": "1.0",
        "partTypes": [
            {"field": "text", "mediaType": "text/markdown"},
            {"field": "data", "mediaType": "application/json"},
            {"field": "raw", "mediaType": "text/csv|image/png", "filename": True},
            {"field": "url", "mediaType": "image/png", "filename": True},
        ],
        "notes": [
            "raw 携带 base64 bytes + 可选 filename",
            "url 指向可下载资源，不内嵌内容",
        ],
    }


def _all_artifacts_csv(topic: str) -> bytes:
    body = (
        "part,artifact,media_type,filename\n"
        f"text,artifact-text,text/markdown,\n"
        f"data,artifact-data,application/json,\n"
        f"raw,artifact-raw-text,text/csv,parts-catalog.csv\n"
        f"raw,artifact-raw-png,image/png,pixel.png\n"
        f"url,artifact-url,image/png,w3c-png-logo.png\n"
        f"mixed,artifact-mixed,multi,mixed-parts\n"
        f"topic,{topic},,\n"
    )
    return body.encode("utf-8")


def _all_artifacts_final(topic: str) -> str:
    return f"""# {topic} — Artifact 类型目录（最终版）

## 一句话

本 skill 在 ReAct 过程中间发出 **A2A 1.0 全部 Part 形态** 的 artifact，终稿仅做索引，不覆盖中间产物。

## Wire Format 对照

| Part field | JSON 形态 | 本 demo artifact |
| --- | --- | --- |
| `text` | `{{ "text": "...", "mediaType": "..." }}` | `artifact-text` |
| `data` | `{{ "data": {{...}}, "mediaType": "application/json" }}` | `artifact-data` |
| `raw` | `{{ "raw": "<base64>", "filename": "...", "mediaType": "..." }}` | `artifact-raw-text` / `artifact-raw-png` |
| `url` | `{{ "url": "https://...", "filename": "...", "mediaType": "..." }}` | `artifact-url` |

## 时序

```text
1) status: reasoning / tool_*
2) artifact-text (markdown)
3) artifact-data (json)
4) artifact-raw-text (csv bytes)
5) artifact-raw-png (png bytes)
6) artifact-url (remote file)
7) artifact-mixed (text + data + raw + url in one artifact)
8) status: more tools
9) artifact-catalog (final markdown)
10) task completed
```

## Skill

触发：`/mock-all-artifacts`

---

中间各类型 artifact 应仍保留在会话中；若客户端尚未渲染 `raw`/`url`，至少应能在协议层看到对应字段。
"""


async def _emit_all_part_artifacts(
    updater: TaskUpdater,
    topic: str,
    *,
    artifact_delay: float,
) -> None:
    """Emit one artifact per A2A Part kind, plus a mixed multi-part artifact."""
    text_id = str(uuid.uuid4())
    data_id = str(uuid.uuid4())
    raw_text_id = str(uuid.uuid4())
    raw_png_id = str(uuid.uuid4())
    url_id = str(uuid.uuid4())
    mixed_id = str(uuid.uuid4())

    await updater.add_artifact(
        [new_text_part(_all_artifacts_text_doc(topic), media_type="text/markdown")],
        artifact_id=text_id,
        name="artifact-text",
        append=False,
        last_chunk=True,
    )
    await asyncio.sleep(artifact_delay)

    data_payload = _all_artifacts_data_payload(topic)
    await updater.add_artifact(
        [new_data_part(data_payload, media_type="application/json")],
        artifact_id=data_id,
        name="artifact-data",
        append=False,
        last_chunk=True,
        metadata={"partKind": "data", "topic": topic},
    )
    await asyncio.sleep(artifact_delay)

    await updater.add_artifact(
        [
            new_raw_part(
                _all_artifacts_csv(topic),
                media_type="text/csv",
                filename="parts-catalog.csv",
            )
        ],
        artifact_id=raw_text_id,
        name="artifact-raw-text",
        append=False,
        last_chunk=True,
        metadata={"partKind": "raw", "role": "text-file"},
    )
    await asyncio.sleep(artifact_delay)

    await updater.add_artifact(
        [
            new_raw_part(
                _PNG_1X1,
                media_type="image/png",
                filename="pixel.png",
            )
        ],
        artifact_id=raw_png_id,
        name="artifact-raw-png",
        append=False,
        last_chunk=True,
        metadata={"partKind": "raw", "role": "binary-file"},
    )
    await asyncio.sleep(artifact_delay)

    await updater.add_artifact(
        [
            new_url_part(
                "https://www.w3.org/Icons/w3c_home.png",
                media_type="image/png",
                filename="w3c-png-logo.png",
            )
        ],
        artifact_id=url_id,
        name="artifact-url",
        append=False,
        last_chunk=True,
        metadata={"partKind": "url", "role": "remote-file"},
    )
    await asyncio.sleep(artifact_delay)

    # Single artifact whose parts cover every content field at once.
    await updater.add_artifact(
        [
            new_text_part(
                f"Mixed artifact for「{topic}」: text + data + raw + url in one `parts` array.",
                media_type="text/plain",
            ),
            new_data_part(
                {"bundle": "mixed", "topic": topic, "parts": ["text", "data", "raw", "url"]},
                media_type="application/json",
            ),
            new_raw_part(
                b"mixed-sidecar.txt from mock-all-artifacts\n",
                media_type="text/plain",
                filename="mixed-sidecar.txt",
            ),
            new_url_part(
                "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf",
                media_type="application/pdf",
                filename="dummy.pdf",
            ),
        ],
        artifact_id=mixed_id,
        name="artifact-mixed",
        append=False,
        last_chunk=True,
        metadata={"partKind": "mixed"},
    )
    await asyncio.sleep(artifact_delay)


async def emit_all_artifacts_task(
    updater: TaskUpdater,
    user_text: str,
    *,
    step_delay: float = 0.35,
    artifact_delay: float = 0.25,
) -> None:
    topic = _all_artifacts_topic(user_text)
    steps = _all_artifacts_steps(topic)
    final = _all_artifacts_final(topic)

    await updater.start_work()
    await asyncio.sleep(0.3)

    emit_index = next(
        (i for i, step in enumerate(steps) if step.get("step") == "__emit_artifacts__"),
        len(steps),
    )

    await _emit_steps(updater, steps[:emit_index], step_delay=step_delay)
    await _emit_all_part_artifacts(updater, topic, artifact_delay=artifact_delay)
    await _emit_steps(updater, steps[emit_index + 1 :], step_delay=step_delay)

    await updater.add_artifact(
        [new_text_part(final, media_type="text/markdown")],
        artifact_id=str(uuid.uuid4()),
        name="artifact-catalog",
        append=False,
        last_chunk=True,
    )
    await asyncio.sleep(0.2)
    await updater.complete()


async def emit_markdown_arch_task(
    updater: TaskUpdater,
    user_text: str,
    *,
    step_delay: float = 0.35,
    artifact_delay: float = 0.25,
) -> None:
    topic = _markdown_arch_topic(user_text)
    steps = _markdown_arch_steps(topic)
    draft = _markdown_arch_draft(topic)
    final = _markdown_arch_final(topic)

    await updater.start_work()
    await asyncio.sleep(0.3)

    draft_index = next(
        (i for i, step in enumerate(steps) if step.get("step") == "__emit_draft__"),
        len(steps),
    )

    await _emit_steps(updater, steps[:draft_index], step_delay=step_delay)

    draft_id = str(uuid.uuid4())
    final_id = str(uuid.uuid4())
    # Intermediate markdown architecture (kept separately from the final doc).
    await updater.add_artifact(
        [new_text_part(draft)],
        artifact_id=draft_id,
        name="architecture-draft",
        append=False,
        last_chunk=True,
    )
    await asyncio.sleep(artifact_delay)

    await _emit_steps(updater, steps[draft_index + 1 :], step_delay=step_delay)

    # Final markdown architecture is a new artifact; must not overwrite the draft.
    await updater.add_artifact(
        [new_text_part(final)],
        artifact_id=final_id,
        name="architecture",
        append=False,
        last_chunk=True,
    )
    await asyncio.sleep(0.2)
    await updater.complete()


async def emit_mock_task(
    updater: TaskUpdater,
    user_text: str,
    *,
    subtask_index: Optional[int] = None,
    total_subtasks: Optional[int] = None,
    step_delay: float = 0.5,
    artifact_delay: float = 0.3,
    start_work: bool = True,
    finish_task: bool = True,
) -> None:
    summary = _mock_summary(
        user_text,
        subtask_index=subtask_index,
        total=total_subtasks,
    )

    if start_work:
        await updater.start_work()
        await asyncio.sleep(0.4)

    for step in _mock_steps(user_text, subtask_index=subtask_index):
        message = updater.new_agent_message(
            [new_data_part(step, media_type="application/json")]
        )
        await updater.update_status(
            TaskState.TASK_STATE_WORKING,
            message=message,
        )
        await asyncio.sleep(step_delay)

    mid = len(summary) // 2
    artifact_id = str(uuid.uuid4())
    await updater.add_artifact(
        [new_text_part(summary[:mid])],
        artifact_id=artifact_id,
        name="summary",
        append=False,
    )
    await asyncio.sleep(artifact_delay)
    await updater.add_artifact(
        [new_text_part(summary[mid:])],
        artifact_id=artifact_id,
        name="summary",
        append=True,
        last_chunk=True,
    )
    await asyncio.sleep(0.2)

    if finish_task:
        await updater.complete()


async def run_multi_task_demo(
    context: RequestContext,
    event_queue: EventQueue,
    user_text: str,
) -> None:
    message = context.message
    if context.current_task:
        task = context.current_task
    elif message is not None:
        task = new_task_from_user_message(message)
        await event_queue.enqueue_event(task)
    else:
        task_id = context.task_id or str(uuid.uuid4())
        context_id = context.context_id or str(uuid.uuid4())
        task = new_task(task_id, context_id, TaskState.TASK_STATE_SUBMITTED)
        await event_queue.enqueue_event(task)

    subtasks = _parse_subtasks(user_text)
    total = len(subtasks)
    updater = TaskUpdater(event_queue, task.id, task.context_id)

    for index, subtask in enumerate(subtasks, start=1):
        await emit_mock_task(
            updater,
            subtask,
            subtask_index=index,
            total_subtasks=total,
            step_delay=0.35,
            artifact_delay=0.2,
            start_work=index == 1,
            finish_task=index == total,
        )
        if index < total:
            await asyncio.sleep(0.3)
