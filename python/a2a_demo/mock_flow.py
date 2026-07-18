"""Mock ReAct agent logic compatible with Agora A2A 1.0 client."""

from __future__ import annotations

import asyncio
import re
import uuid
from typing import Any

from a2a.helpers import (
    new_data_part,
    new_raw_part,
    new_text_part,
    new_url_part,
)
from a2a.server.tasks import TaskUpdater
from a2a.types import TaskState

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


def is_markdown_arch_demo(user_text: str) -> bool:
    lowered = user_text.strip().lower()
    return any(trigger in lowered for trigger in MARKDOWN_ARCH_TRIGGERS)


def is_all_artifacts_demo(user_text: str) -> bool:
    lowered = user_text.strip().lower()
    return any(trigger in lowered for trigger in ALL_ARTIFACTS_TRIGGERS)


def _reasoning(text: str) -> dict[str, Any]:
    return {"type": "reasoning", "text": text}


def _tool_call(
    call_id: str,
    tool: str,
    desc: str,
    args: dict[str, Any],
) -> dict[str, Any]:
    return {
        "type": "tool_call",
        "id": call_id,
        "tool": tool,
        "desc": desc,
        "args": args,
    }


def _tool_result(
    call_id: str,
    tool: str,
    result: str,
    *,
    ok: bool = True,
) -> dict[str, Any]:
    return {
        "type": "tool_result",
        "id": call_id,
        "tool": tool,
        "result": result,
        "ok": ok,
    }


def _marker(name: str) -> dict[str, Any]:
    """Internal emit marker; never sent to clients."""
    return {"type": name}


def _mock_steps(user_text: str) -> list[dict[str, Any]]:
    query = user_text.strip() or "示例问题"
    search_id = "tc_search_0"
    return [
        _reasoning(
            f"## 理解问题\n\n用户想了解 **「{query}」**。"
            f"我先检索相关信息，再整理成简明回答。"
        ),
        _tool_call(
            search_id,
            "web_search",
            f"检索「{query}」的背景资料",
            {"query": query, "limit": 3},
        ),
        _tool_result(
            search_id,
            "web_search",
            f"找到 3 条与「{query}」相关的模拟结果。",
        ),
        _reasoning("检索结果足够，接下来生成总结。"),
    ]


def _mock_summary(user_text: str) -> str:
    query = user_text.strip() or "示例问题"
    return (
        f"关于「{query}」的模拟回答：\n\n"
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
    """Multi-tool flow covering all ToolKind values before/after draft artifact."""
    return [
        _reasoning(
            f"## 边界摸底\n\n先摸清 **「{topic}」** 的边界与约束。"
            f"本轮会并行做检索、读代码、加载 Skill。"
        ),
        _tool_call(
            "arch_search",
            "web_search",
            "检索架构综述与最佳实践",
            {"query": f"{topic} architecture overview", "limit": 5},
        ),
        _tool_result(
            "arch_search",
            "web_search",
            f"检索到 5 篇与「{topic}」相关的架构综述。",
        ),
        _tool_call(
            "arch_read",
            "read",
            "阅读客户端核心模块源码",
            {"path": "agora/agora/ConversationVM.swift"},
        ),
        _tool_result(
            "arch_read",
            "read",
            "识别模块：Transport / Session / Thinking Lane / Result Renderer。",
        ),
        _tool_call(
            "arch_skill",
            "load_skill",
            "加载架构文档写作 Skill",
            {"skill": "architecture-doc", "version": "1.0"},
        ),
        _tool_result(
            "arch_skill",
            "load_skill",
            "已加载 Skill：标题层级、表格、时序图模板。",
        ),
        _reasoning(
            "第一轮材料足够画出草图。再补一层 shell 探查与依赖检查，"
            "然后输出中间版 Markdown 架构文档。"
        ),
        _tool_call(
            "arch_shell",
            "shell",
            "列出工程目录结构",
            {"command": "ls agora/agora | head -20"},
        ),
        _tool_result(
            "arch_shell",
            "shell",
            "ConversationVM.swift\nA2AClient.swift\nConversationView.swift\n…",
        ),
        _tool_call(
            "arch_write_notes",
            "write",
            "写下中间稿提纲到工作区",
            {"path": "/tmp/arch-outline.md", "content": f"# {topic} outline"},
        ),
        _tool_result(
            "arch_write_notes",
            "write",
            "已写入 /tmp/arch-outline.md。",
        ),
        _marker("__emit_draft__"),
        _reasoning(
            "## 终稿准备\n\n中间稿已发出。继续核实风险与扩展点，再输出最终版 Markdown 架构文档。"
        ),
        _tool_call(
            "arch_read_risk",
            "read",
            "核对风险清单文件",
            {"path": "docs/risks.md"},
        ),
        _tool_result(
            "arch_read_risk",
            "read",
            "风险项已标注：流取消、表格渲染、slash skill 路由。",
        ),
        _tool_call(
            "arch_write_final",
            "write",
            "写出终稿草案",
            {"path": "/tmp/arch-final.md", "format": "markdown"},
        ),
        _tool_result(
            "arch_write_final",
            "write",
            "终稿草案已落盘。",
        ),
        _tool_call(
            "arch_shell_lint",
            "shell",
            "对文档做简易 lint",
            {"command": "wc -l /tmp/arch-final.md"},
        ),
        _tool_result(
            "arch_shell_lint",
            "shell",
            "文档 lint 通过：行数与标题层级可用。",
        ),
        _reasoning("终检完成，准备发布最终 Markdown 架构文档。"),
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
| UI | ConversationView | 展示思考过程与结果 |
| State | ConversationVM | 归约 stream 事件 |
| Transport | A2AClient / UniFFI | JSON-RPC + SSE |
| Mock | a2a-demo | 输出模拟 ReAct / Markdown |

## 初步数据流

```text
User → InputBar → ConversationVM.send
                 → A2AClient.stream
                 → status(DataPart) / artifact(TextPart)
                 → thinking + resultBlocks(Markdown)
```

## 待补充

- 取消流与局部失败恢复
- 表格/代码块渲染边界情况
- Skill 路由与 slash 命令一致性
"""


def _markdown_arch_final(topic: str) -> str:
    return f"""# {topic} 架构文档（最终版）

## 一句话定义

`{topic}` 采用 **A2A Streaming + Thinking Lane + Markdown Result** 的三层结构：过程走 status，结论走 artifact。

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

### 2. Thinking Lane

扁平 thinking 列表：

1. **reasoning**（Markdown）
2. **tool_call**（`tool` + `desc` + `id`）
3. 对应 **tool_result**（按 `id` 挂到 call）

### 3. Result Surface

- Artifact 以 Markdown 写入 `resultBlocks`
- 不同 artifact 各自保留，互不覆盖；同 artifact 内 `append=true` 追加流式块
- `MarkdownText`（MarkdownUI）渲染标题 / 列表 / 表格

## 关键时序

```text
1) message/stream
2) status: reasoning
3) status: tool_call / tool_result (×N, paired by id)
4) artifact: markdown draft (中间稿)
5) status: more tools
6) artifact: markdown final (最终版, lastChunk)
7) task completed
```

## 关键决策

| 主题 | 决策 |
| --- | --- |
| 过程事件 | `DataPart.type`（reasoning / tool_call / tool_result） |
| 工具类型 | `tool`: shell / web_search / read / write / load_skill |
| 最终答案 | Text artifact + Markdown 渲染 |
| 中间稿 | 草稿与终稿为不同 artifact，客户端按序保留 |
| Skill | `/mock-markdown-arch` 触发本流程 |

## 验收清单

- [x] 多 tool call/result（按 id 配对）
- [x] 中间返回 Markdown 架构稿
- [x] 最终返回 Markdown 架构终稿
- [x] Agora 侧可折叠展示工具链

---

如需继续扩展（真实 Agent），可在此架构上替换 `a2a-demo` 执行器。
"""


async def _emit_steps(
    updater: TaskUpdater,
    steps: list[dict[str, Any]],
    *,
    step_delay: float,
) -> None:
    for step in steps:
        if step.get("type") in {"__emit_draft__", "__emit_artifacts__"}:
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
    """Thinking steps around a mid-stream emission of every A2A Part kind."""
    return [
        _reasoning(
            f"## 目标\n\n把 A2A 1.0 可能的 Part 形态都作为独立 artifact 发出："
            f"**text / data / raw / url**。先核对协议字段。"
        ),
        _tool_call(
            "art_skill",
            "load_skill",
            "加载 artifact 演示 Skill",
            {"skill": "mock-all-artifacts"},
        ),
        _tool_result(
            "art_skill",
            "load_skill",
            "Part content: text | data | raw | url；可附带 mediaType / filename。",
        ),
        _tool_call(
            "art_read",
            "read",
            "读取样例 fixture 清单",
            {"path": "fixtures/artifacts.json"},
        ),
        _tool_result(
            "art_read",
            "read",
            "已准备 Markdown、JSON、PNG bytes、远程 URL 四类样例。",
        ),
        _reasoning("材料齐了。先发出中间批次的全类型 artifact，再做一次校验并给出终稿说明。"),
        _tool_call(
            "art_write",
            "write",
            "打包中间批次描述文件",
            {"path": "/tmp/artifact-bundle.json", "topic": topic},
        ),
        _tool_result(
            "art_write",
            "write",
            "中间批次打包完成：4 个独立 artifact + 1 个混合 parts artifact。",
        ),
        _marker("__emit_artifacts__"),
        _reasoning(
            "中间 artifact 已发出。再核对客户端是否能按 artifactId 保留各类型，并输出终稿索引。"
        ),
        _tool_call(
            "art_shell",
            "shell",
            "检查客户端兼容清单",
            {"command": "echo ok"},
        ),
        _tool_result(
            "art_shell",
            "shell",
            "协议侧字段齐全；客户端可按需扩展非 text 渲染。",
        ),
        _tool_call(
            "art_search",
            "web_search",
            "检索 A2A Part 渲染参考",
            {"query": "A2A artifact parts rendering", "limit": 3},
        ),
        _tool_result(
            "art_search",
            "web_search",
            "终稿索引参考已收集。",
        ),
        _reasoning("校验完成，发布最终 Markdown 目录。"),
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
        (i for i, step in enumerate(steps) if step.get("type") == "__emit_artifacts__"),
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
        (i for i, step in enumerate(steps) if step.get("type") == "__emit_draft__"),
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
    step_delay: float = 0.5,
    artifact_delay: float = 0.3,
) -> None:
    summary = _mock_summary(user_text)

    await updater.start_work()
    await asyncio.sleep(0.4)

    for step in _mock_steps(user_text):
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
    await updater.complete()
