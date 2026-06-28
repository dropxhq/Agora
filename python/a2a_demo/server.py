"""A2A 1.0 mock server for Agora client debugging."""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from a2a_demo.mock_flow import get_task_status, stream_mock_task

app = FastAPI(title="Agora A2A Demo Server", version="0.1.0")

# In-memory task store for GetTask
_tasks: dict[str, Any] = {}


@app.get("/")
async def health() -> dict[str, str]:
    return {
        "service": "Agora A2A Demo Server",
        "status": "ok",
        "protocolVersion": "1.0",
        "hint": (
            "POST JSON-RPC (SendStreamingMessage) to stream mock ReAct events. "
            "Send a message containing 'multi task' or '多任务' to run the multi-task demo."
        ),
    }


@app.get("/.well-known/agent-card.json")
async def agent_card() -> dict[str, Any]:
    return {
        "name": "Agora A2A Demo Agent",
        "description": "Mock A2A server for Agora client debugging.",
        "url": "http://localhost:8000",
        "version": "0.1.0",
        "protocolVersion": "1.0",
        "capabilities": {"streaming": True},
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain"],
        "skills": [
            {
                "id": "mock-react",
                "name": "Mock ReAct",
                "description": "Returns simulated reasoning, tool calls, and summary.",
            },
            {
                "id": "mock-multi-task",
                "name": "Multi-Task Demo",
                "description": (
                    "Orchestrates multiple sub-tasks in one context. "
                    "Trigger with a message containing 'multi task' or '多任务'."
                ),
                "examples": [
                    "multi task demo",
                    "多任务：收集背景信息；检索相关资料；整理总结",
                ],
            },
        ],
    }


@app.post("/", response_model=None)
async def jsonrpc_root(request: Request):
    body = await request.json()
    method = body.get("method")
    params = body.get("params") or {}
    rpc_id = body.get("id")

    if method == "SendStreamingMessage":
        params = {**params, "_tasks_store": _tasks, "_rpc_id": rpc_id}
        return StreamingResponse(
            stream_mock_task(params),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    if method == "GetTask":
        task_id = params.get("id")
        status = get_task_status(task_id, _tasks) if task_id else None
        if status is None:
            return JSONResponse(
                {
                    "jsonrpc": "2.0",
                    "id": rpc_id,
                    "error": {"code": -32001, "message": f"Task not found: {task_id}"},
                }
            )
        return JSONResponse(
            {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {"status": status},
            }
        )

    return JSONResponse(
        {
            "jsonrpc": "2.0",
            "id": rpc_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        },
        status_code=400,
    )


def main() -> None:
    import uvicorn

    uvicorn.run(
        "a2a_demo.server:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
        log_level="info",
    )


if __name__ == "__main__":
    main()
