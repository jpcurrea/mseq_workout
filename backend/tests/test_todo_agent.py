"""
Tests for the todo-mode agent: tools schema, context builder, HTTP endpoint.

Coverage:
  - _todo_tools_schema returns exactly the 4 expected tools with no plan tools
  - _build_project_context(mode='todo') returns the right shape
  - _build_system_prompt(mode='todo') produces todo-flavoured content
  - GET /agent/conversation accepts mode=todo
  - DELETE /agent/conversation deletes the right thread
  - POST /agent/chat (mode=todo) validates membership, rejects viewer writes
  - _execute_planning_tool_call works for all 4 todo tools
  - create_task / update_task / delete_task / list_tasks via todo mode
"""
import json
import pytest
from unittest.mock import AsyncMock, patch
from fastapi import HTTPException

from database import Task, Plan, ProjectMembership, LLMConversation
from routers.agent import (
    _todo_tools_schema,
    _build_project_context,
    _build_system_prompt,
    _execute_planning_tool_call,
)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _call(name, args, *, db, user, project, dry_run=False):
    return _execute_planning_tool_call(
        name=name,
        args=args,
        project_id=project.id,
        default_plan_id=None,
        user_id=user.id,
        session=db,
        dry_run=dry_run,
    )


# ═══════════════════════════════════════════════════════════════════════════════
# Tool schema
# ═══════════════════════════════════════════════════════════════════════════════

class TestTodoToolsSchema:
    def test_returns_five_tools(self):
        tools = _todo_tools_schema()
        assert len(tools) == 5

    def test_tool_names(self):
        names = {t["function"]["name"] for t in _todo_tools_schema()}
        assert names == {
            "list_tasks",
            "create_task",
            "update_task",
            "delete_task",
            "get_current_datetime",
        }

    def test_no_plan_tools(self):
        names = {t["function"]["name"] for t in _todo_tools_schema()}
        assert "write_plan" not in names
        assert "create_plan" not in names
        assert "read_plan" not in names

    def test_all_entries_have_type_function(self):
        for t in _todo_tools_schema():
            assert t["type"] == "function"
            assert "function" in t
            assert "parameters" in t["function"]

    def test_create_task_requires_title(self):
        schema = next(t for t in _todo_tools_schema() if t["function"]["name"] == "create_task")
        assert "title" in schema["function"]["parameters"]["required"]

    def test_update_task_requires_task_id(self):
        schema = next(t for t in _todo_tools_schema() if t["function"]["name"] == "update_task")
        assert "task_id" in schema["function"]["parameters"]["required"]

    def test_delete_task_requires_task_id(self):
        schema = next(t for t in _todo_tools_schema() if t["function"]["name"] == "delete_task")
        assert "task_id" in schema["function"]["parameters"]["required"]

    def test_list_tasks_has_no_required_fields(self):
        schema = next(t for t in _todo_tools_schema() if t["function"]["name"] == "list_tasks")
        assert schema["function"]["parameters"].get("required", []) == []


# ═══════════════════════════════════════════════════════════════════════════════
# Context builder
# ═══════════════════════════════════════════════════════════════════════════════

class TestBuildProjectContextTodo:
    def test_mode_key(self, db, user, project):
        ctx = _build_project_context(
            mode="todo", user_id=user.id, project_id=project.id, plan_id=None, session=db
        )
        assert ctx["mode"] == "todo"

    def test_tasks_list_present(self, db, user, project):
        t = Task(user_id=user.id, project_id=project.id, title="Buy milk")
        db.add(t)
        db.flush()
        ctx = _build_project_context(
            mode="todo", user_id=user.id, project_id=project.id, plan_id=None, session=db
        )
        assert any(item["title"] == "Buy milk" for item in ctx["tasks"])

    def test_no_plan_content_returned(self, db, user, project):
        ctx = _build_project_context(
            mode="todo", user_id=user.id, project_id=project.id, plan_id=None, session=db
        )
        # Todo context must not leak full plan content (keep context small)
        assert "plans" not in ctx

    def test_overdue_count_field_present(self, db, user, project):
        ctx = _build_project_context(
            mode="todo", user_id=user.id, project_id=project.id, plan_id=None, session=db
        )
        assert "overdue_count" in ctx

    def test_overdue_count_correct(self, db, user, project):
        import datetime
        past = datetime.datetime(2020, 1, 1)
        future = datetime.datetime(2099, 1, 1)
        db.add(Task(user_id=user.id, project_id=project.id, title="Past", due_date=past))
        db.add(Task(user_id=user.id, project_id=project.id, title="Future", due_date=future))
        db.flush()
        ctx = _build_project_context(
            mode="todo", user_id=user.id, project_id=project.id, plan_id=None, session=db
        )
        assert ctx["overdue_count"] >= 1  # at least the past task

    def test_plan_titles_listed(self, db, user, project, plan):
        ctx = _build_project_context(
            mode="todo", user_id=user.id, project_id=project.id, plan_id=None, session=db
        )
        assert any(p["id"] == plan.id for p in ctx["plan_titles"])


# ═══════════════════════════════════════════════════════════════════════════════
# System prompt
# ═══════════════════════════════════════════════════════════════════════════════

class TestBuildSystemPromptTodo:
    def test_does_not_contain_planning_language(self):
        prompt = _build_system_prompt("todo", project_id=1)
        # Should not mention "planning assistant" — different persona
        assert "planning assistant" not in prompt.lower()

    def test_mentions_todo(self):
        prompt = _build_system_prompt("todo", project_id=1)
        assert "todo" in prompt.lower() or "task assistant" in prompt.lower()

    def test_mentions_tts_friendliness(self):
        prompt = _build_system_prompt("todo", project_id=1)
        # Should mention voice / spoken / TTS brevity guidance
        assert "spoken" in prompt.lower() or "text-to-speech" in prompt.lower() or "brief" in prompt.lower()

    def test_planning_prompt_unchanged(self):
        prompt = _build_system_prompt("planning", project_id=1)
        assert "planning assistant" in prompt.lower()

    def test_project_id_embedded_in_todo_prompt(self):
        prompt = _build_system_prompt("todo", project_id=42)
        assert "42" in prompt


# ═══════════════════════════════════════════════════════════════════════════════
# Tool execution — todo mode tools
# ═══════════════════════════════════════════════════════════════════════════════

class TestTodoToolExecution:
    # ── create_task ─────────────────────────────────────────────────────────────
    def test_create_task_persists(self, db, user, project):
        r = _call("create_task", {"title": "Buy milk"}, db=db, user=user, project=project)
        assert r["ok"] is True
        row = db.query(Task).filter(Task.id == r["task_id"]).first()
        assert row.title == "Buy milk"

    def test_create_task_dry_run(self, db, user, project):
        r = _call("create_task", {"title": "Ghost"}, db=db, user=user, project=project, dry_run=True)
        assert r["dry_run"] is True
        assert db.query(Task).filter(Task.title == "Ghost").first() is None

    def test_create_task_no_title_raises(self, db, user, project):
        with pytest.raises(HTTPException) as exc:
            _call("create_task", {}, db=db, user=user, project=project)
        assert exc.value.status_code == 400

    # ── update_task ─────────────────────────────────────────────────────────────
    def test_update_task_title(self, db, user, project, task):
        r = _call("update_task", {"task_id": task.id, "title": "Renamed"}, db=db, user=user, project=project)
        assert r["ok"] is True
        db.refresh(task)
        assert task.title == "Renamed"

    def test_update_task_mark_completed(self, db, user, project, task):
        r = _call("update_task", {"task_id": task.id, "is_completed": True}, db=db, user=user, project=project)
        assert r["ok"] is True
        db.refresh(task)
        assert task.is_completed is True

    def test_update_task_wrong_project_raises(self, db, user, project, task):
        other_project_id = project.id + 9999
        with pytest.raises(HTTPException) as exc:
            _execute_planning_tool_call(
                name="update_task",
                args={"task_id": task.id, "title": "Hack"},
                project_id=other_project_id,
                default_plan_id=None,
                user_id=user.id,
                session=db,
                dry_run=False,
            )
        assert exc.value.status_code in (403, 404)

    def test_update_task_nonexistent_raises(self, db, user, project):
        with pytest.raises(HTTPException) as exc:
            _call("update_task", {"task_id": 999999, "title": "x"}, db=db, user=user, project=project)
        assert exc.value.status_code == 404

    # ── delete_task ─────────────────────────────────────────────────────────────
    def test_delete_task_removes_row(self, db, user, project, task):
        task_id = task.id
        r = _call("delete_task", {"task_id": task_id}, db=db, user=user, project=project)
        assert r["ok"] is True
        assert db.query(Task).filter(Task.id == task_id).first() is None

    def test_delete_task_wrong_project_raises(self, db, user, project, task):
        with pytest.raises(HTTPException) as exc:
            _execute_planning_tool_call(
                name="delete_task",
                args={"task_id": task.id},
                project_id=project.id + 9999,
                default_plan_id=None,
                user_id=user.id,
                session=db,
                dry_run=False,
            )
        assert exc.value.status_code in (403, 404)

    def test_delete_task_nonexistent_raises(self, db, user, project):
        with pytest.raises(HTTPException) as exc:
            _call("delete_task", {"task_id": 999999}, db=db, user=user, project=project)
        assert exc.value.status_code == 404

    # ── list_tasks ───────────────────────────────────────────────────────────────
    def test_list_tasks_returns_list(self, db, user, project, task):
        r = _call("list_tasks", {}, db=db, user=user, project=project)
        assert r["ok"] is True
        assert isinstance(r["tasks"], list)
        assert any(t["id"] == task.id for t in r["tasks"])

    def test_list_tasks_excludes_completed_by_default(self, db, user, project):
        done = Task(user_id=user.id, project_id=project.id, title="Done task", is_completed=True)
        pending = Task(user_id=user.id, project_id=project.id, title="Pending task")
        db.add_all([done, pending])
        db.flush()
        r = _call("list_tasks", {}, db=db, user=user, project=project)
        ids = {t["id"] for t in r["tasks"]}
        assert pending.id in ids
        assert done.id not in ids

    def test_list_tasks_include_completed(self, db, user, project):
        done = Task(user_id=user.id, project_id=project.id, title="Done task", is_completed=True)
        db.add(done)
        db.flush()
        r = _call("list_tasks", {"include_completed": True}, db=db, user=user, project=project)
        ids = {t["id"] for t in r["tasks"]}
        assert done.id in ids

    def test_list_tasks_search_filter(self, db, user, project):
        db.add(Task(user_id=user.id, project_id=project.id, title="Buy groceries"))
        db.add(Task(user_id=user.id, project_id=project.id, title="Read book"))
        db.flush()
        r = _call("list_tasks", {"search": "groceries"}, db=db, user=user, project=project)
        titles = [t["title"] for t in r["tasks"]]
        assert any("groceries" in t.lower() for t in titles)
        assert not any("Read book" == t for t in titles)

    def test_list_tasks_tag_filter(self, db, user, project):
        from database import Tag
        tag = Tag(name="urgent", user_id=user.id)
        db.add(tag)
        db.flush()
        tagged = Task(user_id=user.id, project_id=project.id, title="Tagged task")
        untagged = Task(user_id=user.id, project_id=project.id, title="Plain task")
        db.add_all([tagged, untagged])
        db.flush()
        tagged.tags.append(tag)
        db.flush()
        r = _call("list_tasks", {"tag": "urgent"}, db=db, user=user, project=project)
        ids = {t["id"] for t in r["tasks"]}
        assert tagged.id in ids
        assert untagged.id not in ids

    # ── unsupported tool ─────────────────────────────────────────────────────────
    def test_write_plan_not_in_todo_tools(self):
        """write_plan must not be advertised to the todo agent.

        Prevention is at the schema level — the tool is simply not
        in _todo_tools_schema(), so the LLM never learns it exists.
        This complements test_no_plan_tools in TestTodoToolsSchema.
        """
        names = {t["function"]["name"] for t in _todo_tools_schema()}
        assert "write_plan" not in names


# ═══════════════════════════════════════════════════════════════════════════════
# HTTP endpoint integration — /agent/conversation (todo mode)
# ═══════════════════════════════════════════════════════════════════════════════

class TestConversationEndpointTodo:
    def test_get_conversation_todo_mode_empty(self, http_client):
        client, ctx = http_client
        project = ctx["project"]
        resp = client.get(
            "/agent/conversation",
            params={"mode": "todo", "project_id": project.id},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert "messages" in data
        assert data["messages"] == []
        assert data["has_memory"] is False

    def test_delete_conversation_nonexistent_ok(self, http_client):
        """Deleting when no thread exists should still return 200 ok."""
        client, ctx = http_client
        project = ctx["project"]
        resp = client.delete(
            "/agent/conversation",
            params={"mode": "todo", "project_id": project.id},
        )
        assert resp.status_code == 200
        assert resp.json()["ok"] is True

    def test_delete_conversation_removes_thread(self, http_client):
        client, ctx = http_client
        db = ctx["db"]
        user = ctx["user"]
        project = ctx["project"]

        # Manually create a conversation thread.
        convo = LLMConversation(
            user_id=user.id,
            mode="todo",
            project_id=project.id,
            messages=json.dumps([{"role": "user", "content": "hi"}]),
        )
        db.add(convo)
        db.commit()

        # Verify it exists via GET.
        resp = client.get(
            "/agent/conversation",
            params={"mode": "todo", "project_id": project.id},
        )
        assert resp.status_code == 200
        assert len(resp.json()["messages"]) == 1

        # Delete it.
        del_resp = client.delete(
            "/agent/conversation",
            params={"mode": "todo", "project_id": project.id},
        )
        assert del_resp.status_code == 200
        assert del_resp.json()["ok"] is True

        # Now it should be gone.
        resp2 = client.get(
            "/agent/conversation",
            params={"mode": "todo", "project_id": project.id},
        )
        assert resp2.json()["messages"] == []

    def test_get_conversation_restores_saved_messages(self, http_client):
        client, ctx = http_client
        db = ctx["db"]
        user = ctx["user"]
        project = ctx["project"]

        convo = LLMConversation(
            user_id=user.id,
            mode="todo",
            project_id=project.id,
            messages=json.dumps([
                {"role": "user", "content": "What's due today?"},
                {"role": "assistant", "content": "Nothing urgent."},
            ]),
        )
        db.add(convo)
        db.commit()

        resp = client.get(
            "/agent/conversation",
            params={"mode": "todo", "project_id": project.id},
        )
        assert resp.status_code == 200
        messages = resp.json()["messages"]
        assert len(messages) == 2
        assert messages[0]["role"] == "user"
        assert messages[1]["role"] == "assistant"

    def test_todo_conversation_isolated_from_planning(self, http_client):
        """A todo thread must not bleed into a planning thread."""
        client, ctx = http_client
        db = ctx["db"]
        user = ctx["user"]
        project = ctx["project"]

        todo_convo = LLMConversation(
            user_id=user.id, mode="todo", project_id=project.id,
            messages=json.dumps([{"role": "user", "content": "todo message"}]),
        )
        planning_convo = LLMConversation(
            user_id=user.id, mode="planning", project_id=project.id,
            messages=json.dumps([{"role": "user", "content": "planning message"}]),
        )
        db.add_all([todo_convo, planning_convo])
        db.commit()

        todo_resp = client.get(
            "/agent/conversation",
            params={"mode": "todo", "project_id": project.id},
        )
        assert any(m["content"] == "todo message" for m in todo_resp.json()["messages"])
        assert not any(m["content"] == "planning message" for m in todo_resp.json()["messages"])


# ═══════════════════════════════════════════════════════════════════════════════
# HTTP endpoint integration — POST /agent/chat (todo mode) with mocked LLM
# ═══════════════════════════════════════════════════════════════════════════════

class TestAgentChatTodoMode:
    @pytest.fixture
    def mock_llm_text(self):
        """Patch _call_llm_message to return a plain text reply without tools."""
        async def _fake_llm(messages, model="gpt-4o", tools=None, runtime=None):
            return {"role": "assistant", "content": "Here are your tasks.", "_usage": {}}
        with patch("routers.agent._call_llm_message", side_effect=_fake_llm):
            yield

    @pytest.fixture
    def mock_llm_create_task(self):
        """Simulate LLM calling create_task then giving a text reply."""
        calls = []

        async def _fake_llm(messages, model="gpt-4o", tools=None, runtime=None):
            nonlocal calls
            calls.append(len(messages))
            if len(calls) == 1:
                # First call: return a tool call
                return {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [{
                        "id": "tc_001",
                        "type": "function",
                        "function": {
                            "name": "create_task",
                            "arguments": json.dumps({"title": "Agent Created Task"}),
                        },
                    }],
                    "_usage": {},
                }
            # Subsequent call: text summary
            return {"role": "assistant", "content": "Created your task.", "_usage": {}}

        with patch("routers.agent._call_llm_message", side_effect=_fake_llm):
            yield

    def test_todo_chat_returns_reply(self, http_client, mock_llm_text):
        client, ctx = http_client
        project = ctx["project"]
        resp = client.post("/agent/chat", json={
            "mode": "todo",
            "project_id": project.id,
            "messages": [{"role": "user", "content": "What tasks do I have?"}],
            "require_approval": False,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert "reply" in data
        assert data["reply"] != ""
        assert data["mode"] == "todo"

    def test_todo_chat_nonmember_rejected(self, http_client, mock_llm_text):
        client, ctx = http_client
        resp = client.post("/agent/chat", json={
            "mode": "todo",
            "project_id": 999999,
            "messages": [{"role": "user", "content": "hi"}],
            "require_approval": False,
        })
        assert resp.status_code == 403

    def test_todo_chat_executes_create_task(self, http_client, mock_llm_create_task):
        client, ctx = http_client
        project = ctx["project"]
        db = ctx["db"]
        resp = client.post("/agent/chat", json={
            "mode": "todo",
            "project_id": project.id,
            "messages": [{"role": "user", "content": "Add a task: Agent Created Task"}],
            "require_approval": False,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["reply"] != ""
        # Task should have been created in the DB.
        task = db.query(Task).filter(Task.title == "Agent Created Task").first()
        assert task is not None
        assert task.project_id == project.id

    def test_todo_chat_no_pending_approval(self, http_client, mock_llm_create_task):
        """Todo mode never uses approval flow."""
        client, ctx = http_client
        project = ctx["project"]
        resp = client.post("/agent/chat", json={
            "mode": "todo",
            "project_id": project.id,
            "messages": [{"role": "user", "content": "Add a task"}],
            "require_approval": False,
        })
        assert resp.status_code == 200
        assert resp.json()["pending_approval"] is False

    def test_todo_chat_saves_conversation(self, http_client, mock_llm_text):
        client, ctx = http_client
        project = ctx["project"]
        db = ctx["db"]
        resp = client.post("/agent/chat", json={
            "mode": "todo",
            "project_id": project.id,
            "messages": [{"role": "user", "content": "hello"}],
            "require_approval": False,
        })
        assert resp.status_code == 200
        saved = db.query(LLMConversation).filter(
            LLMConversation.mode == "todo",
            LLMConversation.project_id == project.id,
        ).first()
        assert saved is not None
        stored = json.loads(saved.messages or "[]")
        assert any(m["role"] == "user" for m in stored)
        assert any(m["role"] == "assistant" for m in stored)

    def test_todo_thread_separate_from_planning_thread(self, http_client, mock_llm_text):
        """Chatting in todo mode must not overwrite a planning thread."""
        client, ctx = http_client
        project = ctx["project"]
        db = ctx["db"]
        user = ctx["user"]

        planning_convo = LLMConversation(
            user_id=user.id, mode="planning", project_id=project.id,
            messages=json.dumps([{"role": "user", "content": "plan msg"}]),
        )
        db.add(planning_convo)
        db.commit()
        plan_convo_id = planning_convo.id

        # Send a todo chat
        resp = client.post("/agent/chat", json={
            "mode": "todo",
            "project_id": project.id,
            "messages": [{"role": "user", "content": "todo msg"}],
            "require_approval": False,
        })
        assert resp.status_code == 200

        # Planning thread untouched.
        db.expire_all()
        planning_convo_after = db.query(LLMConversation).filter(
            LLMConversation.id == plan_convo_id
        ).first()
        stored = json.loads(planning_convo_after.messages or "[]")
        assert all(m["content"] != "todo msg" for m in stored)

    def test_viewer_cannot_create_task_via_todo_chat(self, http_client, mock_llm_create_task):
        """A viewer-role member's tool calls must return ok=False.

        The endpoint protects non-members with 403, but for viewers the
        write-guard is inside _execute_planning_tool_call, which raises
        HTTPException(403). That exception is caught by the per-tool handler
        and surfaced as {ok: False} in `actions`. The HTTP response is still
        200 so the reply message can explain what happened.
        """
        client, ctx = http_client
        db = ctx["db"]
        user = ctx["user"]
        project = ctx["project"]

        # Downgrade membership to viewer.
        membership = db.query(ProjectMembership).filter(
            ProjectMembership.project_id == project.id,
            ProjectMembership.user_id == user.id,
        ).first()
        membership.role = "viewer"
        db.commit()

        resp = client.post("/agent/chat", json={
            "mode": "todo",
            "project_id": project.id,
            "messages": [{"role": "user", "content": "Add a task"}],
            "require_approval": False,
        })
        assert resp.status_code == 200
        data = resp.json()
        # The tool call must have failed.
        assert any(
            not a.get("ok") for a in data["actions"]
        ), f"Expected a failed action but got: {data['actions']}"
        # And the task must NOT have been created.
        task = db.query(Task).filter(Task.title == "Agent Created Task").first()
        assert task is None, "Viewer should not be able to create tasks"


# ═══════════════════════════════════════════════════════════════════════════════
# Regression: approval-mode loop must not duplicate proposed tool calls
# ═══════════════════════════════════════════════════════════════════════════════

class TestApprovalModeDuplicationRegression:
    """
    Regression for the bug where the agent loop continued after collecting
    proposed tool calls in approval mode, causing the model to re-propose the
    same actions on each iteration (up to 8×).

    The LLM mock always returns a tool call on every invocation so that the
    bug would trigger if the early-break guard is missing.
    """

    @pytest.fixture
    def mock_llm_always_calls_tool(self):
        """LLM that always returns a write_plan tool call (never a text reply).

        write_plan is a mutating tool that goes through the approval queue, so
        it exercises the early-break guard. (create_task is intentionally
        excluded: it now executes immediately so the model gets a real id to
        embed in the same turn, and therefore is never queued for approval.)
        """
        call_count = [0]

        async def _fake_llm(messages, model="gpt-4o", tools=None, runtime=None):
            call_count[0] += 1
            return {
                "role": "assistant",
                "content": "",
                "tool_calls": [{
                    "id": f"tc_{call_count[0]:03d}",
                    "type": "function",
                    "function": {
                        "name": "write_plan",
                        "arguments": json.dumps({"content": f"Plan revision {call_count[0]}"}),
                    },
                }],
                "_usage": {},
            }

        with patch("routers.agent._call_llm_message", side_effect=_fake_llm):
            yield call_count

    def test_planning_approval_no_duplicate_proposals(self, http_client, mock_llm_always_calls_tool):
        """
        In planning + require_approval mode, proposed_tool_calls must contain
        exactly one entry per unique LLM tool-call batch, not N copies where N
        is the number of loop iterations the model kept returning tool calls.
        """
        client, ctx = http_client
        project = ctx["project"]
        plan = ctx["plan"]
        call_count = mock_llm_always_calls_tool

        resp = client.post("/agent/chat", json={
            "mode": "planning",
            "project_id": project.id,
            "plan_id": plan.id,
            "messages": [{"role": "user", "content": "Create 1 task"}],
            "require_approval": True,
        })
        assert resp.status_code == 200
        data = resp.json()

        proposed = data["proposed_tool_calls"]

        # The loop must have stopped after the first batch of tool calls was
        # collected, so there should be exactly 1 proposed action — not
        # call_count[0] copies of it.
        assert len(proposed) == 1, (
            f"Expected exactly 1 proposed tool call but got {len(proposed)} "
            f"(LLM was called {call_count[0]} time(s)). "
            "The approval-mode loop likely did not break early."
        )
        assert proposed[0]["name"] == "write_plan"

    def test_planning_approval_llm_called_exactly_once_for_tool_batch(
        self, http_client, mock_llm_always_calls_tool
    ):
        """The LLM should be called exactly once when approval mode breaks early."""
        client, ctx = http_client
        project = ctx["project"]
        plan = ctx["plan"]
        call_count = mock_llm_always_calls_tool

        client.post("/agent/chat", json={
            "mode": "planning",
            "project_id": project.id,
            "plan_id": plan.id,
            "messages": [{"role": "user", "content": "Create a task"}],
            "require_approval": True,
        })

        # With the fix: 1 call for tool call collection + 1 final "summarise"
        # call (no-tool). Without the fix: up to 8 calls + 1 summarise = 9.
        assert call_count[0] <= 2, (
            f"LLM was called {call_count[0]} times; expected ≤ 2 in approval mode. "
            "Approval-mode loop is not breaking early."
        )


class TestApprovalModeImmediateCreateTask:
    """
    In planning + require_approval mode, create_task must execute immediately
    (not as a dry-run) so the model gets a real task_id to embed into the plan
    in the SAME turn. It must NOT be queued for approval, and the loop must keep
    going so a follow-up write_plan can run.
    """

    def test_create_task_executes_immediately_under_approval(self, http_client):
        client, ctx = http_client
        project = ctx["project"]
        plan = ctx["plan"]
        db = ctx["db"]

        calls = [0]

        async def _fake_llm(messages, model="gpt-4o", tools=None, runtime=None):
            calls[0] += 1
            if calls[0] == 1:
                return {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [{
                        "id": "tc_001",
                        "type": "function",
                        "function": {
                            "name": "create_task",
                            "arguments": json.dumps({"title": "Imported Task"}),
                        },
                    }],
                    "_usage": {},
                }
            return {"role": "assistant", "content": "Created the task.", "_usage": {}}

        with patch("routers.agent._call_llm_message", side_effect=_fake_llm):
            resp = client.post("/agent/chat", json={
                "mode": "planning",
                "project_id": project.id,
                "plan_id": plan.id,
                "messages": [{"role": "user", "content": "Create a task"}],
                "require_approval": True,
            })

        assert resp.status_code == 200
        data = resp.json()

        # The task is really created (not a dry-run) and is NOT pending approval.
        assert data["pending_approval"] is False
        assert all(tc["name"] != "create_task" for tc in data["proposed_tool_calls"])
        create_actions = [a for a in data["actions"] if a.get("action") == "create_task"]
        assert len(create_actions) == 1
        assert create_actions[0].get("dry_run") is not True
        assert isinstance(create_actions[0].get("task_id"), int)

        # The row exists in the database.
        created = db.query(Task).filter(
            Task.project_id == project.id, Task.title == "Imported Task"
        ).first()
        assert created is not None

