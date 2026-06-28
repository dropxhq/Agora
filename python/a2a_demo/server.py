"""A2A v0.3-style mock server for Agora client debugging."""

from __future__ import annotations

import json
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from a2a_demo.mock_flow import get_task_status, stream_mock_task

app = FastAPI(title="Agora A2A Demo Server", version="0.1.0")

# In-memory task store for tasks/get
_tasks: dict[str, Any] = {}


@app.get("/")
async def health() -> dict[str, str]:
    return {
        "service": "Agora A2A Demo Server",
        "status": "ok",
        "hint": "POST JSON-RPC (tasks/sendSubscribe) to stream mock ReAct events.",
    }


@app.get("/.well-known/agent.json")
async def agent_card() -> dict[str, Any]:
    return {
        "name": "Agora A2A Demo Agent",
        "description": "Mock A2A server for Agora client debugging.",
        "url": "http://localhost:8000",
        "version": "0.1.0",
        "capabilities": {"streaming": True},
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain"],
        "skills": [
            {
                "id": "mock-react",
                "name": "Mock ReAct",
                "description": "Returns simulated reasoning, tool calls, and summary.",
            }
        ],
    }


@app.post("/", response_model=None)
async def jsonrpc_root(request: Request):
    body = await request.json()
    method = body.get("method")
    params = body.get("params") or {}
    rpc_id = body.get("id")

    if method == "tasks/sendSubscribe":
        params = {**params, "_tasks_store": _tasks}
        return StreamingResponse(
            stream_mock_task(params),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    if method == "tasks/get":
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
