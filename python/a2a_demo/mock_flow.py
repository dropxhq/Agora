"""Mock ReAct agent logic compatible with Agora A2A 1.0 client."""

from __future__ import annotations

import asyncio
import re
import uuid
from typing import Any, Optional

from a2a.helpers import new_data_part, new_task, new_task_from_user_message, new_text_part
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
DEFAULT_SUBTASKS = (
    "收集背景信息",
    "检索相关资料",
    "整理并输出总结",
)


class MockAgent:
    """Mock agent that emits ReAct-style status and artifact updates."""

    async def run(self, user_text: str, task_updater: TaskUpdater) -> None:
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
        if step.get("step") == "__emit_draft__":
            continue
        message = updater.new_agent_message(
            [new_data_part(step, media_type="application/json")]
        )
        await updater.update_status(
            TaskState.TASK_STATE_WORKING,
            message=message,
        )
        await asyncio.sleep(step_delay)


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
