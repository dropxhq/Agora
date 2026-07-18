"""Entry point for the Agora A2A demo server (FastAPI + a2a-sdk)."""

from __future__ import annotations

import uvicorn
from fastapi import FastAPI
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.request_handlers.response_helpers import agent_card_to_dict
from a2a.server.routes import add_a2a_routes_to_fastapi, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill

from a2a_demo.agent_executor import MockAgentExecutor

SERVER_HOST = "0.0.0.0"
SERVER_PORT = 8000
SERVER_URL = f"http://localhost:{SERVER_PORT}"


def _build_skills() -> tuple[AgentSkill, AgentSkill, AgentSkill]:
    mock_react = AgentSkill(
        id="mock-react",
        name="Mock ReAct",
        description=(
            "Returns simulated reasoning / tool_call / tool_result (status), "
            "then a streamed summary artifact."
        ),
        input_modes=["text/plain"],
        output_modes=["text/plain"],
        tags=["a2a", "mock", "react"],
    )
    markdown_arch = AgentSkill(
        id="mock-markdown-arch",
        name="Markdown Architecture",
        description=(
            "Thinking demo covering shell/web_search/read/write/load_skill, "
            "streams an intermediate Markdown architecture draft, "
            "then appends a final Markdown architecture document without overwriting the draft."
        ),
        input_modes=["text/plain"],
        output_modes=["text/markdown", "text/plain"],
        tags=["a2a", "mock", "markdown", "architecture"],
        examples=[
            "mock-markdown-arch Agora Client",
            "markdown arch 交易策略服务",
            "架构文档：A2A Streaming",
        ],
    )
    all_artifacts = AgentSkill(
        id="mock-all-artifacts",
        name="All Artifact Types",
        description=(
            "Like mock-markdown-arch, but mid-stream emits every A2A 1.0 Part kind as artifacts: "
            "text, data, raw (file bytes), url (file URI), plus a mixed multi-part artifact, "
            "then finishes with a Markdown catalog."
        ),
        input_modes=["text/plain"],
        output_modes=[
            "text/markdown",
            "text/plain",
            "application/json",
            "text/csv",
            "image/png",
            "application/pdf",
        ],
        tags=["a2a", "mock", "artifact", "file", "raw", "url"],
        examples=[
            "mock-all-artifacts Agora Client",
            "all artifacts demo",
            "全部 artifact 类型",
        ],
    )
    return mock_react, markdown_arch, all_artifacts


def _build_public_agent_card() -> AgentCard:
    mock_react, markdown_arch, all_artifacts = _build_skills()
    return AgentCard(
        name="Agora A2A Demo Agent",
        description="Mock A2A server for Agora client debugging.",
        version="0.1.0",
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        capabilities=AgentCapabilities(streaming=True),
        supported_interfaces=[
            AgentInterface(
                protocol_binding="JSONRPC",
                url=SERVER_URL,
                protocol_version="1.0",
            )
        ],
        skills=[mock_react, markdown_arch, all_artifacts],
    )


def _create_agent_card_routes(agent_card: AgentCard) -> list[Route]:
    """Agent card route with Agora legacy fields on the JSON response."""

    async def _get_agent_card(_: Request) -> JSONResponse:
        card = agent_card_to_dict(agent_card)
        card.setdefault("url", SERVER_URL)
        card.setdefault("protocolVersion", "1.0")
        return JSONResponse(card)

    return [
        Route(
            path="/.well-known/agent-card.json",
            endpoint=_get_agent_card,
            methods=["GET"],
        )
    ]


if __name__ == "__main__":
    public_agent_card = _build_public_agent_card()

    request_handler = DefaultRequestHandler(
        agent_executor=MockAgentExecutor(),
        task_store=InMemoryTaskStore(),
        agent_card=public_agent_card,
    )

    app = FastAPI(
        title="Agora A2A Demo Server",
        version="0.1.0",
    )
    add_a2a_routes_to_fastapi(
        app,
        agent_card_routes=_create_agent_card_routes(public_agent_card),
        jsonrpc_routes=create_jsonrpc_routes(request_handler, "/", enable_v0_3_compat=True),
    )

    uvicorn.run(app, host=SERVER_HOST, port=SERVER_PORT, log_level="info")
