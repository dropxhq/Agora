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
DEFAULT_SUBTASKS = (
    "收集背景信息",
    "检索相关资料",
    "整理并输出总结",
)


class MockAgent:
    """Mock agent that emits ReAct-style status and artifact updates."""

    async def run(self, user_text: str, task_updater: TaskUpdater) -> None:
        await emit_mock_task(task_updater, user_text)


def is_multi_task_demo(user_text: str) -> bool:
    lowered = user_text.strip().lower()
    return any(trigger in lowered for trigger in MULTI_TASK_TRIGGERS)


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
