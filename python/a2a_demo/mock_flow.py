"""Mock ReAct execution flow compatible with Agora A2A 1.0 client."""

from __future__ import annotations

import asyncio
import json
import re
import uuid
from collections.abc import AsyncIterator
from typing import Any, Optional

MULTI_TASK_TRIGGERS = ("multi task", "multi-task", "multitask", "多任务")
DEFAULT_SUBTASKS = (
    "收集背景信息",
    "检索相关资料",
    "整理并输出总结",
)


def _status_update(
    task_id: str,
    context_id: str,
    state: str,
    *,
    step: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    message: Optional[dict[str, Any]] = None
    if step is not None:
        message = {
            "messageId": str(uuid.uuid4()),
            "role": "ROLE_AGENT",
            "parts": [
                {
                    "data": step,
                    "mediaType": "application/json",
                }
            ],
        }
    return {
        "statusUpdate": {
            "taskId": task_id,
            "contextId": context_id,
            "status": {"state": state, "message": message},
        }
    }


def _artifact_update(
    task_id: str,
    context_id: str,
    text: str,
    *,
    artifact_id: str,
    last_chunk: bool = False,
) -> dict[str, Any]:
    return {
        "artifactUpdate": {
            "taskId": task_id,
            "contextId": context_id,
            "artifact": {
                "artifactId": artifact_id,
                "name": "summary",
                "parts": [{"text": text}],
            },
            "append": True,
            "lastChunk": last_chunk,
        }
    }


def _task_event(task_id: str, context_id: str, state: str) -> dict[str, Any]:
    return {
        "task": {
            "id": task_id,
            "contextId": context_id,
            "status": {"state": state},
        }
    }


def _extract_user_text(params: dict[str, Any]) -> str:
    message = params.get("message") or {}
    parts = message.get("parts") or []
    for part in parts:
        if isinstance(part, dict) and part.get("text"):
            return str(part["text"])
    return "（空消息）"


def _extract_context_id(params: dict[str, Any]) -> Optional[str]:
    message = params.get("message") or {}
    return message.get("contextId") or params.get("contextId")


def _is_multi_task_demo(user_text: str) -> bool:
    lowered = user_text.strip().lower()
    return any(trigger in lowered for trigger in MULTI_TASK_TRIGGERS)


def _strip_multi_task_trigger(user_text: str) -> str:
    text = user_text.strip()
    for trigger in MULTI_TASK_TRIGGERS:
        pattern = re.compile(re.escape(trigger), re.IGNORECASE)
        text = pattern.sub("", text)
    return text.strip(" \t:：-—|")


def _parse_subtasks(user_text: str) -> list[str]:
    """Parse sub-task labels from user text after removing the multi-task trigger."""
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
        {
            "step": "task_start",
            "round": 0,
            "text": query,
        },
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


def _mock_summary(user_text: str, *, subtask_index: Optional[int] = None, total: Optional[int] = None) -> str:
    query = user_text.strip() or "示例问题"
    header = ""
    if subtask_index is not None and total is not None:
        header = f"[子任务 {subtask_index}/{total}] "
    return (
        f"{header}关于「{query}」的模拟回答：\n\n"
        "这是 A2A Demo Server 返回的占位内容，用于调试 Agora 客户端的流式渲染。"
        "实际接入真实 Agent 后，此处会替换为模型生成的总结。"
    )


async def _emit_single_task(
    *,
    user_text: str,
    context_id: str,
    rpc_id: Any,
    tasks_store: Optional[dict[str, Any]],
    subtask_index: Optional[int] = None,
    total_subtasks: Optional[int] = None,
    step_delay: float = 0.5,
    artifact_delay: float = 0.3,
) -> AsyncIterator[str]:
    """Yield SSE payloads for one mock ReAct task."""
    task_id = str(uuid.uuid4())
    artifact_id = str(uuid.uuid4())
    summary = _mock_summary(user_text, subtask_index=subtask_index, total=total_subtasks)

    if isinstance(tasks_store, dict):
        tasks_store[task_id] = {
            "id": task_id,
            "context_id": context_id,
            "state": "TASK_STATE_WORKING",
            "user_text": user_text,
        }

    yield _sse(_task_event(task_id, context_id, "TASK_STATE_WORKING"), rpc_id)
    await asyncio.sleep(0.4)

    for step in _mock_steps(user_text, subtask_index=subtask_index):
        yield _sse(
            _status_update(task_id, context_id, "TASK_STATE_WORKING", step=step),
            rpc_id,
        )
        await asyncio.sleep(step_delay)

    mid = len(summary) // 2
    yield _sse(_artifact_update(task_id, context_id, summary[:mid], artifact_id=artifact_id), rpc_id)
    await asyncio.sleep(artifact_delay)
    yield _sse(
        _artifact_update(task_id, context_id, summary[mid:], artifact_id=artifact_id, last_chunk=True),
        rpc_id,
    )
    await asyncio.sleep(0.2)

    yield _sse(_status_update(task_id, context_id, "TASK_STATE_COMPLETED"), rpc_id)

    if isinstance(tasks_store, dict):
        tasks_store[task_id]["state"] = "TASK_STATE_COMPLETED"
        tasks_store[task_id]["summary"] = summary


async def stream_mock_task(params: dict[str, Any]) -> AsyncIterator[str]:
    """Yield SSE `data:` payloads for a mock ReAct task (A2A 1.0 StreamResponse)."""
    user_text = _extract_user_text(params)
    if _is_multi_task_demo(user_text):
        async for event in stream_multi_task_demo(params):
            yield event
        return

    context_id = _extract_context_id(params) or str(uuid.uuid4())
    rpc_id = params.get("_rpc_id")
    tasks_store = params.get("_tasks_store")

    async for event in _emit_single_task(
        user_text=user_text,
        context_id=context_id,
        rpc_id=rpc_id,
        tasks_store=tasks_store if isinstance(tasks_store, dict) else None,
    ):
        yield event


async def stream_multi_task_demo(params: dict[str, Any]) -> AsyncIterator[str]:
    """Yield SSE payloads for a multi-task orchestration demo within one context."""
    rpc_id = params.get("_rpc_id")
    context_id = _extract_context_id(params) or str(uuid.uuid4())
    user_text = _extract_user_text(params)
    subtasks = _parse_subtasks(user_text)
    tasks_store = params.get("_tasks_store")
    store = tasks_store if isinstance(tasks_store, dict) else None
    total = len(subtasks)

    for index, subtask in enumerate(subtasks, start=1):
        async for event in _emit_single_task(
            user_text=subtask,
            context_id=context_id,
            rpc_id=rpc_id,
            tasks_store=store,
            subtask_index=index,
            total_subtasks=total,
            step_delay=0.35,
            artifact_delay=0.2,
        ):
            yield event

        if index < total:
            await asyncio.sleep(0.3)


def _sse(payload: dict[str, Any], rpc_id: Any = None) -> str:
    envelope = {
        "jsonrpc": "2.0",
        "id": rpc_id,
        "result": payload,
    }
    return f"data: {json.dumps(envelope, ensure_ascii=False)}\n\n"


def get_task_status(task_id: str, tasks_store: dict[str, Any]) -> Optional[dict[str, Any]]:
    task = tasks_store.get(task_id)
    if task is None:
        return None
    return {
        "state": task.get("state", "TASK_STATE_COMPLETED"),
        "message": None,
    }
