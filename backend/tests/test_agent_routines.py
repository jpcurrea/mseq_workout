"""
Tests for agent routines and on-demand tool documentation.

Covers:
  - Built-in routines are seeded per user on first use.
  - list_routines / get_routine / save_routine dispatcher tools.
  - Guardrail: the agent cannot modify a built-in (system) routine.
  - save_routine dry-run does not persist.
  - get_help returns documentation.
  - The routine/help tools appear in both planning and todo schemas.
  - REST CRUD endpoints for routines.
"""
import pytest
from fastapi import HTTPException

from database import AgentRoutine, ProjectMembership
from routers.agent import (
    _execute_planning_tool_call,
    _ensure_default_routines,
    _planning_tools_schema,
    _todo_tools_schema,
    _DEFAULT_ROUTINES,
)


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


# ── Defaults seeding ──────────────────────────────────────────────────────────

def test_ensure_default_routines_seeds_once(db, user):
    _ensure_default_routines(db, user.id)
    rows = db.query(AgentRoutine).filter(AgentRoutine.user_id == user.id).all()
    assert len(rows) == len(_DEFAULT_ROUTINES)
    assert all(r.is_system for r in rows)
    # Idempotent: calling again does not duplicate.
    _ensure_default_routines(db, user.id)
    rows2 = db.query(AgentRoutine).filter(AgentRoutine.user_id == user.id).all()
    assert len(rows2) == len(_DEFAULT_ROUTINES)


# ── list_routines / get_routine ───────────────────────────────────────────────

def test_list_routines_returns_defaults(db, user, project):
    result = _call("list_routines", {}, db=db, user=user, project=project)
    assert result["ok"] is True
    assert result["count"] == len(_DEFAULT_ROUTINES)
    names = {r["name"] for r in result["routines"]}
    assert "Daily triage" in names


def test_get_routine_by_name_includes_steps(db, user, project):
    _call("list_routines", {}, db=db, user=user, project=project)  # seed
    result = _call("get_routine", {"name": "Daily triage"}, db=db, user=user, project=project)
    assert result["ok"] is True
    assert "steps" in result["routine"]
    assert result["routine"]["steps"]


def test_get_routine_missing_404(db, user, project):
    with pytest.raises(HTTPException) as exc:
        _call("get_routine", {"name": "no such routine"}, db=db, user=user, project=project)
    assert exc.value.status_code == 404


def test_get_routine_requires_identifier(db, user, project):
    with pytest.raises(HTTPException) as exc:
        _call("get_routine", {}, db=db, user=user, project=project)
    assert exc.value.status_code == 400


# ── save_routine ──────────────────────────────────────────────────────────────

def test_save_routine_creates_new(db, user, project):
    result = _call(
        "save_routine",
        {"name": "My workflow", "steps": "1. do a\n2. do b", "description": "d"},
        db=db, user=user, project=project,
    )
    assert result["ok"] is True
    assert result["updated"] is False
    row = db.query(AgentRoutine).filter(AgentRoutine.id == result["routine_id"]).first()
    assert row is not None
    assert row.created_by == "agent"
    assert row.is_system is False
    assert row.project_id is None  # default global


def test_save_routine_project_scope(db, user, project):
    result = _call(
        "save_routine",
        {"name": "Scoped", "steps": "x", "scope": "project"},
        db=db, user=user, project=project,
    )
    row = db.query(AgentRoutine).filter(AgentRoutine.id == result["routine_id"]).first()
    assert row.project_id == project.id


def test_save_routine_updates_own_by_name(db, user, project):
    r1 = _call("save_routine", {"name": "Dup", "steps": "first"}, db=db, user=user, project=project)
    r2 = _call("save_routine", {"name": "Dup", "steps": "second"}, db=db, user=user, project=project)
    assert r2["updated"] is True
    assert r1["routine_id"] == r2["routine_id"]
    row = db.query(AgentRoutine).filter(AgentRoutine.id == r2["routine_id"]).first()
    assert row.steps == "second"


def test_save_routine_cannot_modify_system(db, user, project):
    _ensure_default_routines(db, user.id)
    with pytest.raises(HTTPException) as exc:
        _call("save_routine", {"name": "Daily triage", "steps": "hijacked"},
              db=db, user=user, project=project)
    assert exc.value.status_code == 403


def test_save_routine_dry_run_does_not_persist(db, user, project):
    result = _call("save_routine", {"name": "Ghost routine", "steps": "x"},
                   db=db, user=user, project=project, dry_run=True)
    assert result["dry_run"] is True
    assert db.query(AgentRoutine).filter(AgentRoutine.name == "Ghost routine").first() is None


def test_save_routine_requires_steps(db, user, project):
    with pytest.raises(HTTPException) as exc:
        _call("save_routine", {"name": "Empty"}, db=db, user=user, project=project)
    assert exc.value.status_code == 400


# ── get_help ──────────────────────────────────────────────────────────────────

def test_get_help_overview(db, user, project):
    result = _call("get_help", {}, db=db, user=user, project=project)
    assert result["ok"] is True
    assert result["topic"] == "overview"
    assert "topics" in result


def test_get_help_topic(db, user, project):
    result = _call("get_help", {"topic": "plans"}, db=db, user=user, project=project)
    assert result["topic"] == "plans"
    assert "{{task:ID}}" in result["content"]
    assert "tasklist" in result["content"]


# ── Schemas include the shared tools ──────────────────────────────────────────

def test_planning_schema_has_routine_and_help_tools():
    names = {t["function"]["name"] for t in _planning_tools_schema()}
    assert {"get_help", "list_routines", "get_routine", "save_routine"} <= names


def test_todo_schema_has_routine_and_help_tools():
    names = {t["function"]["name"] for t in _todo_tools_schema()}
    assert {"get_help", "list_routines", "get_routine", "save_routine"} <= names


# ── REST CRUD ─────────────────────────────────────────────────────────────────

def test_rest_list_seeds_and_returns(http_client):
    client, ctx = http_client
    resp = client.get(f"/agent/routines?project_id={ctx['project'].id}")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= len(_DEFAULT_ROUTINES)
    assert all("steps" in r for r in data)


def test_rest_create_update_delete(http_client):
    client, ctx = http_client
    # Create
    resp = client.post("/agent/routines", json={"name": "UI routine", "steps": "do things"})
    assert resp.status_code == 200, resp.text
    rid = resp.json()["id"]
    assert resp.json()["is_system"] is False
    # Update
    resp = client.put(f"/agent/routines/{rid}", json={"steps": "do other things"})
    assert resp.status_code == 200
    assert resp.json()["steps"] == "do other things"
    # Delete
    resp = client.delete(f"/agent/routines/{rid}")
    assert resp.status_code == 200
    # It no longer appears in the list.
    remaining = client.get(f"/agent/routines?project_id={ctx['project'].id}").json()
    assert all(r["name"] != "UI routine" for r in remaining)


def test_rest_create_requires_steps(http_client):
    client, ctx = http_client
    resp = client.post("/agent/routines", json={"name": "No steps", "steps": ""})
    assert resp.status_code == 400


# ── Searchable {{tasklist ...}} block support ─────────────────────────────────

def test_write_plan_accepts_valid_tasklist_block(db, user, project, plan, task):
    content = (
        "# Plan\n\n"
        "{{tasklist sort=manual\n"
        f"- task:{task.id}  {task.title}\n"
        "}}\n"
    )
    result = _call(
        "write_plan",
        {"plan_id": plan.id, "content": content},
        db=db, user=user, project=project, plan=plan,
    )
    assert result["ok"] is True


def test_write_plan_rejects_unknown_tasklist_member(db, user, project, plan):
    content = "{{tasklist sort=manual\n- task:999999  Ghost\n}}"
    with pytest.raises(HTTPException) as exc:
        _call(
            "write_plan",
            {"plan_id": plan.id, "content": content},
            db=db, user=user, project=project, plan=plan,
        )
    assert exc.value.status_code == 400


def test_write_plan_auto_annotates_missing_tasklist_titles(db, user, project, plan, task):
    # A bare `- task:ID` line (no label) should get the task title appended.
    content = "{{tasklist sort=manual\n" f"- task:{task.id}\n" "}}"
    _call(
        "write_plan",
        {"plan_id": plan.id, "content": content},
        db=db, user=user, project=project, plan=plan,
    )
    db.refresh(plan)
    assert f"- task:{task.id}  {task.title}" in plan.content


def test_write_plan_preserves_existing_tasklist_label(db, user, project, plan, task):
    # An explicit custom label must NOT be overwritten.
    content = "{{tasklist sort=manual\n" f"- task:{task.id}  My custom note\n" "}}"
    _call(
        "write_plan",
        {"plan_id": plan.id, "content": content},
        db=db, user=user, project=project, plan=plan,
    )
    db.refresh(plan)
    assert "My custom note" in plan.content
    assert f"task:{task.id}  {task.title}" not in plan.content

