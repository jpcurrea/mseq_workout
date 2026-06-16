"""
Tests for _execute_planning_tool_call — the agent's tool dispatcher.

These tests call the function directly (no HTTP), giving precise control
over inputs and clear visibility into what the DB state looks like after
each operation.

Bugs covered:
- Plan-scoped delete guardrail (403 when task not in plan)
- write_plan token validation (400 on unknown task IDs)
- Viewer role blocked from all write tools
- Dry-run returns metadata without mutating DB
"""
import pytest
from fastapi import HTTPException

from database import Task, Plan, ProjectMembership
from routers.agent import _execute_planning_tool_call


# ── Helpers ───────────────────────────────────────────────────────────────────

def _call(name, args, *, db, user, project, plan=None, dry_run=False):
    return _execute_planning_tool_call(
        name=name,
        args=args,
        project_id=project.id,
        default_plan_id=plan.id if plan else None,
        user_id=user.id,
        session=db,
        dry_run=dry_run,
    )


# ── create_task ───────────────────────────────────────────────────────────────

def test_create_task_persists(db, user, project):
    result = _call("create_task", {"title": "Write docs"}, db=db, user=user, project=project)
    assert result["ok"] is True
    assert result["action"] == "create_task"
    assert "task_id" in result
    row = db.query(Task).filter(Task.id == result["task_id"]).first()
    assert row is not None
    assert row.title == "Write docs"
    assert row.project_id == project.id
    assert row.user_id == user.id

def test_create_task_dry_run_does_not_persist(db, user, project):
    result = _call("create_task", {"title": "Ghost task"}, db=db, user=user, project=project, dry_run=True)
    assert result["dry_run"] is True
    assert db.query(Task).filter(Task.title == "Ghost task").first() is None

def test_create_task_requires_title(db, user, project):
    with pytest.raises(HTTPException) as exc:
        _call("create_task", {}, db=db, user=user, project=project)
    assert exc.value.status_code == 400

def test_create_task_with_due_date(db, user, project):
    result = _call(
        "create_task",
        {"title": "Deadline task", "due_date": "2026-07-01T09:00:00", "duration_minutes": 60},
        db=db, user=user, project=project,
    )
    assert result["ok"] is True
    row = db.query(Task).filter(Task.id == result["task_id"]).first()
    assert row.duration_minutes == 60
    assert row.due_date is not None


# ── update_task ───────────────────────────────────────────────────────────────

def test_update_task_changes_title(db, user, project, task):
    result = _call("update_task", {"task_id": task.id, "title": "Updated"}, db=db, user=user, project=project)
    assert result["ok"] is True
    db.refresh(task)
    assert task.title == "Updated"

def test_update_task_wrong_project_raises(db, user, project, task):
    with pytest.raises(HTTPException) as exc:
        _execute_planning_tool_call(
            name="update_task",
            args={"task_id": task.id, "title": "Hacked"},
            project_id=project.id + 9999,
            default_plan_id=None,
            user_id=user.id,
            session=db,
        )
    assert exc.value.status_code in (403, 404)

def test_update_task_missing_id_raises(db, user, project):
    with pytest.raises(HTTPException) as exc:
        _call("update_task", {"title": "No ID"}, db=db, user=user, project=project)
    assert exc.value.status_code == 400

def test_update_task_recurrence_rule(db, user, project, task):
    result = _call(
        "update_task",
        {"task_id": task.id, "is_recurring": True, "recurrence_rule": "WEEKDAYS"},
        db=db, user=user, project=project,
    )
    assert result["ok"] is True
    db.refresh(task)
    assert task.is_recurring is True
    assert task.recurrence_rule == "WEEKDAYS"


# ── delete_task ───────────────────────────────────────────────────────────────

def test_delete_task_no_plan_context(db, user, project, task):
    """Without an open plan, delete is always allowed."""
    result = _call("delete_task", {"task_id": task.id}, db=db, user=user, project=project)
    assert result["ok"] is True
    assert db.query(Task).filter(Task.id == task.id).first() is None

def test_delete_task_in_plan_is_allowed(db, user, project, task, plan):
    """Allowed when the task IS embedded in the open plan."""
    plan.content = f"Intro\n{{{{task:{task.id}}}}}\nOutro"
    db.flush()
    result = _call("delete_task", {"task_id": task.id}, db=db, user=user, project=project, plan=plan)
    assert result["ok"] is True
    assert db.query(Task).filter(Task.id == task.id).first() is None

def test_delete_task_not_in_plan_is_blocked(db, user, project, task, plan):
    """Blocked when plan is open but task has no {{task:ID}} token in it."""
    plan.content = "No task tokens here."
    db.flush()
    with pytest.raises(HTTPException) as exc:
        _call("delete_task", {"task_id": task.id}, db=db, user=user, project=project, plan=plan)
    assert exc.value.status_code == 403
    # The task must still exist — the guard prevented deletion.
    assert db.query(Task).filter(Task.id == task.id).first() is not None

def test_delete_task_dry_run_does_not_delete(db, user, project, task):
    result = _call("delete_task", {"task_id": task.id}, db=db, user=user, project=project, dry_run=True)
    assert result["dry_run"] is True
    assert db.query(Task).filter(Task.id == task.id).first() is not None

def test_delete_task_returns_title(db, user, project, task):
    result = _call("delete_task", {"task_id": task.id}, db=db, user=user, project=project)
    assert result["title"] == task.title

def test_delete_nonexistent_task_raises(db, user, project):
    with pytest.raises(HTTPException) as exc:
        _call("delete_task", {"task_id": 99999}, db=db, user=user, project=project)
    assert exc.value.status_code == 404


# ── write_plan ────────────────────────────────────────────────────────────────

def test_write_plan_valid_token(db, user, project, task, plan):
    content = f"## Plan\n\n{{{{task:{task.id}}}}}\n\nDone."
    result = _call("write_plan", {"content": content}, db=db, user=user, project=project, plan=plan)
    assert result["ok"] is True
    db.refresh(plan)
    assert f"{{{{task:{task.id}}}}}" in plan.content

def test_write_plan_invalid_token_rejected(db, user, project, plan):
    """Token referencing a task that doesn't exist in the project → 400."""
    content = "## Plan\n\n{{task:999999}}\n"
    with pytest.raises(HTTPException) as exc:
        _call("write_plan", {"content": content}, db=db, user=user, project=project, plan=plan)
    assert exc.value.status_code == 400
    # Plan content must not have been changed.
    db.refresh(plan)
    assert "999999" not in (plan.content or "")

def test_write_plan_append_preserves_original(db, user, project, plan):
    plan.content = "Original"
    db.flush()
    result = _call("write_plan", {"content": "Appended", "append": True}, db=db, user=user, project=project, plan=plan)
    assert result["ok"] is True
    db.refresh(plan)
    assert "Original" in plan.content
    assert "Appended" in plan.content

def test_write_plan_overwrites_by_default(db, user, project, plan):
    plan.content = "Old content"
    db.flush()
    result = _call("write_plan", {"content": "New content"}, db=db, user=user, project=project, plan=plan)
    assert result["ok"] is True
    db.refresh(plan)
    assert plan.content == "New content"

def test_write_plan_empty_content_raises(db, user, project, plan):
    with pytest.raises(HTTPException) as exc:
        _call("write_plan", {"content": ""}, db=db, user=user, project=project, plan=plan)
    assert exc.value.status_code == 400

def test_write_plan_dry_run(db, user, project, plan):
    plan.content = "Original"
    db.flush()
    result = _call("write_plan", {"content": "Should not appear"}, db=db, user=user, project=project, plan=plan, dry_run=True)
    assert result["dry_run"] is True
    db.refresh(plan)
    assert plan.content == "Original"


# ── read_plan ─────────────────────────────────────────────────────────────────

def test_read_plan_returns_content(db, user, project, plan):
    plan.content = "# My Plan\nDetailed content."
    db.flush()
    result = _call("read_plan", {"plan_id": plan.id}, db=db, user=user, project=project)
    assert result["ok"] is True
    assert "My Plan" in result["content"]
    assert result["plan_id"] == plan.id

def test_read_plan_wrong_project_raises(db, user, project, plan):
    with pytest.raises(HTTPException) as exc:
        _execute_planning_tool_call(
            name="read_plan",
            args={"plan_id": plan.id},
            project_id=project.id + 9999,
            default_plan_id=None,
            user_id=user.id,
            session=db,
        )
    assert exc.value.status_code in (403, 404)

def test_read_plan_executes_in_dry_run_too(db, user, project, plan):
    """read_plan is read-only so it always executes, even in dry-run mode."""
    plan.content = "Readable"
    db.flush()
    result = _call("read_plan", {"plan_id": plan.id}, db=db, user=user, project=project, dry_run=True)
    assert result["ok"] is True
    assert "Readable" in result["content"]


# ── Viewer role ───────────────────────────────────────────────────────────────

def test_viewer_cannot_create_task(db, user, project):
    membership = db.query(ProjectMembership).filter_by(
        project_id=project.id, user_id=user.id
    ).first()
    membership.role = "viewer"
    db.flush()
    with pytest.raises(HTTPException) as exc:
        _call("create_task", {"title": "Viewer task"}, db=db, user=user, project=project)
    assert exc.value.status_code == 403

def test_viewer_cannot_delete_task(db, user, project, task):
    membership = db.query(ProjectMembership).filter_by(
        project_id=project.id, user_id=user.id
    ).first()
    membership.role = "viewer"
    db.flush()
    with pytest.raises(HTTPException) as exc:
        _call("delete_task", {"task_id": task.id}, db=db, user=user, project=project)
    assert exc.value.status_code == 403
    assert db.query(Task).filter(Task.id == task.id).first() is not None

def test_viewer_cannot_write_plan(db, user, project, plan):
    membership = db.query(ProjectMembership).filter_by(
        project_id=project.id, user_id=user.id
    ).first()
    membership.role = "viewer"
    db.flush()
    with pytest.raises(HTTPException) as exc:
        _call("write_plan", {"content": "Viewer write"}, db=db, user=user, project=project, plan=plan)
    assert exc.value.status_code == 403


# ── Non-member ────────────────────────────────────────────────────────────────

def test_non_member_cannot_access(db, user, project, task):
    """A user with no membership row at all should be blocked."""
    outsider = __import__("database").User(email="outsider@test.com", username="outsider")
    db.add(outsider)
    db.flush()
    with pytest.raises(HTTPException) as exc:
        _execute_planning_tool_call(
            name="create_task",
            args={"title": "Intruder task"},
            project_id=project.id,
            default_plan_id=None,
            user_id=outsider.id,
            session=db,
        )
    assert exc.value.status_code == 403


# ── Tool call batching sanity check ──────────────────────────────────────────

def test_tool_call_batch_constant_is_128():
    """The OpenAI limit is 128 — make sure the batch constant hasn't drifted."""
    import routers.agent as agent_module
    import inspect
    source = inspect.getsource(agent_module.agent_chat)
    assert "_TOOL_CALL_BATCH = 128" in source, (
        "Expected _TOOL_CALL_BATCH = 128 in agent_chat. "
        "OpenAI rejects tool_calls arrays longer than 128."
    )
