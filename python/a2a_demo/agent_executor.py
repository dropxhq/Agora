"""Mock AgentExecutor (helloworld-style)."""

from __future__ import annotations

from a2a.helpers import get_message_text, new_task_from_user_message
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater

from a2a_demo.mock_flow import MockAgent


class MockAgentExecutor(AgentExecutor):
    """Routes client requests to the mock ReAct agent."""

    def __init__(self) -> None:
        self.agent = MockAgent()

    async def execute(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        message = context.message
        user_text = get_message_text(message) if message else "（空消息）"

        if context.current_task:
            task = context.current_task
        else:
            task = new_task_from_user_message(message)
            await event_queue.enqueue_event(task)

        task_updater = TaskUpdater(
            event_queue=event_queue,
            task_id=task.id,
            context_id=task.context_id,
        )
        # mock-react / mock-markdown-arch / mock-all-artifacts route inside MockAgent.run
        await self.agent.run(user_text, task_updater)

    async def cancel(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        raise NotImplementedError("Cancel is not supported.")
