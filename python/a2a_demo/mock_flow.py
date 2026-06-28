"""Mock ReAct execution flow compatible with Agora A2A client."""

from __future__ import annotations

import asyncio
import json
import uuid
from collections.abc import AsyncIterator
from typing import Any, Optional


def _status_event(
    task_id: str,
    context_id: str,
    state: str,
    *,
    step: Optional[dict[str, Any]] = None,
    final: bool = False,
) -> dict[str, Any]:
    message: Optional[dict[str, Any]] = None
    if step is not None:
        message = {
            "parts": [
                {
                    "data": step,
                    "mediaType": "application/json",
                }
            ]
        }
    return {
        "id": task_id,
        "context_id": context_id,
        "status": {"state": state, "message": message},
        "final": final,
    }


def _artifact_event(
    task_id: str,
    context_id: str,
    text: str,
    *,
    last_chunk: bool = False,
) -> dict[str, Any]:
    return {
        "id": task_id,
        "context_id": context_id,
        "artifact": {"name": "summary", "parts": [{"text": text}]},
        "append": True,
        "lastChunk": last_chunk,
    }


def _extract_user_text(params: dict[str, Any]) -> str:
    message = params.get("message") or {}
    parts = message.get("parts") or []
    for part in parts:
        if isinstance(part, dict) and part.get("text"):
            return str(part["text"])
    return "（空消息）"


def _mock_steps(user_text: str) -> list[dict[str, Any]]:
    query = user_text.strip() or "示例问题"
    return [
        {
            "step": "reasoning",
            "round": 1,
            "text": f"用户想了解「{query}」。我先检索相关信息，再整理成简明回答。",
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
            "text": "检索结果足够，接下来生成总结。",
        },
    ]


def _mock_summary(user_text: str) -> str:
    query = user_text.strip() or "示例问题"
    return (
        f"关于「{query}」的模拟回答：\n\n"
        "这是 A2A Demo Server 返回的占位内容，用于调试 Agora 客户端的流式渲染。"
        "实际接入真实 Agent 后，此处会替换为模型生成的总结。"
    )


async def stream_mock_task(params: dict[str, Any]) -> AsyncIterator[str]:
    """Yield SSE `data:` payloads for a mock ReAct task."""
    task_id = str(uuid.uuid4())
    context_id = params.get("contextId") or str(uuid.uuid4())
    user_text = _extract_user_text(params)

    tasks_store = params.get("_tasks_store")
    if isinstance(tasks_store, dict):
        tasks_store[task_id] = {
            "id": task_id,
            "context_id": context_id,
            "state": "working",
            "user_text": user_text,
        }

    yield _sse(_status_event(task_id, context_id, "working"))
    await asyncio.sleep(0.4)

    for step in _mock_steps(user_text):
        yield _sse(_status_event(task_id, context_id, "working", step=step))
        await asyncio.sleep(0.5)

    summary = _mock_summary(user_text)
    mid = len(summary) // 2
    yield _sse(_artifact_event(task_id, context_id, summary[:mid]))
    await asyncio.sleep(0.3)
    yield _sse(_artifact_event(task_id, context_id, summary[mid:], last_chunk=True))
    await asyncio.sleep(0.2)

    yield _sse(_status_event(task_id, context_id, "completed", final=True))

    if isinstance(tasks_store, dict):
        tasks_store[task_id]["state"] = "completed"
        tasks_store[task_id]["summary"] = summary


def _sse(payload: dict[str, Any]) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


def get_task_status(task_id: str, tasks_store: dict[str, Any]) -> Optional[dict[str, Any]]:
    task = tasks_store.get(task_id)
    if task is None:
        return None
    return {
        "state": task.get("state", "completed"),
        "message": None,
    }
