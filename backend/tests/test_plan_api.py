"""
Integration tests for plan-related HTTP endpoints.

These exercise the actual FastAPI routing layer via TestClient, with the
database overridden to an in-memory SQLite instance via conftest.http_client.

Critical regression covered:
  - GET /plans/{id} must populate task_map using project_id, NOT user_id.
    A task belonging to a different user but the same project MUST appear.
  - Task IDs that appear as tokens but don't exist should be omitted gracefully.
"""
import pytest
from database import Task, Plan, User, ProjectMembership


# ── GET /plans/{plan_id} ─────────────────────────────────────────────────────

def test_get_plan_returns_task_map(http_client):
    client, ctx = http_client
    plan = ctx["plan"]
    embedded_task = ctx["task"]
    resp = client.get(f"/plans/{plan.id}")
    assert resp.status_code == 200
    data = resp.json()
    # The API returns the task dict under the key 'tasks'
    assert "tasks" in data, f"Response must include 'tasks' key. Got keys: {list(data.keys())}"
    task_map = data["tasks"]
    assert str(embedded_task.id) in task_map or embedded_task.id in task_map, (
        f"Embedded task {embedded_task.id} not found in tasks: {task_map}"
    )


def test_get_plan_task_map_uses_project_id_not_user_id(http_client):
    """
    A task created by a *different* user but belonging to the same project
    must still appear in the task_map.

    This is the regression test for the bug where get_plan filtered by
    user_id (showing only the requesting user's tasks) instead of project_id.
    """
    client, ctx = http_client
    db = ctx["db"]
    project = ctx["project"]
    user = ctx["user"]

    # Create a second user with no membership (or separate membership).
    other_user = User(email="other@test.com", username="otheruser")
    db.add(other_user)
    db.flush()

    # Task owned by other_user but assigned to the same project.
    other_task = Task(
        user_id=other_user.id,
        project_id=project.id,
        title="Other User's Task",
    )
    db.add(other_task)
    db.flush()

    # New plan embedding other_task.
    plan = Plan(
        user_id=user.id,
        project_id=project.id,
        title="Cross-user plan",
        content=f"{{{{task:{other_task.id}}}}}",
    )
    db.add(plan)
    db.commit()

    resp = client.get(f"/plans/{plan.id}")
    assert resp.status_code == 200
    data = resp.json()
    task_map = data["tasks"]
    assert str(other_task.id) in task_map or other_task.id in task_map, (
        f"Task from other user ({other_task.id}) missing from tasks — "
        f"get_plan may be filtering by user_id instead of project_id. "
        f"tasks keys: {list(task_map.keys())}"
    )
    titles = [v.get("title") for v in task_map.values()]
    assert "Other User's Task" in titles


def test_get_plan_omits_nonexistent_task_token(http_client):
    """Tokens for deleted / nonexistent tasks must not cause a 500."""
    client, ctx = http_client
    db = ctx["db"]
    project = ctx["project"]
    user = ctx["user"]

    plan = Plan(
        user_id=user.id,
        project_id=project.id,
        title="Stale token plan",
        content="{{task:999999}}",
    )
    db.add(plan)
    db.commit()

    resp = client.get(f"/plans/{plan.id}")
    assert resp.status_code == 200
    task_map = resp.json()["tasks"]
    # Should not contain the nonexistent ID.
    assert "999999" not in task_map


def test_get_plan_nonexistent_returns_404(http_client):
    client, _ = http_client
    resp = client.get("/plans/99999")
    assert resp.status_code == 404


def test_get_plan_contains_content(http_client):
    client, ctx = http_client
    plan = ctx["plan"]
    resp = client.get(f"/plans/{plan.id}")
    assert resp.status_code == 200
    data = resp.json()
    assert "content" in data


# ── GET /plans (list) ─────────────────────────────────────────────────────────

def test_list_plans_returns_array(http_client):
    client, ctx = http_client
    project = ctx["project"]
    resp = client.get(f"/plans?project_id={project.id}")
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    ids = [p["id"] for p in data]
    assert ctx["plan"].id in ids


# ── POST /plans ───────────────────────────────────────────────────────────────

def test_create_plan(http_client):
    client, ctx = http_client
    project = ctx["project"]
    payload = {"title": "New Plan", "project_id": project.id, "content": ""}
    resp = client.post("/plans", json=payload)
    assert resp.status_code in (200, 201)
    data = resp.json()
    assert data["title"] == "New Plan"
    assert "id" in data


# ── PATCH /plans/{id} ─────────────────────────────────────────────────────────

def test_update_plan_content(http_client):
    client, ctx = http_client
    plan = ctx["plan"]
    # Update endpoint uses PUT, not PATCH.
    resp = client.put(f"/plans/{plan.id}", json={"content": "Updated content"})
    assert resp.status_code == 200
    data = resp.json()
    # PUT response returns id, project_id, title, updated_at (not content)
    assert data["id"] == plan.id


# ── DELETE /plans/{id} ────────────────────────────────────────────────────────

def test_delete_plan(http_client):
    client, ctx = http_client
    db = ctx["db"]
    project = ctx["project"]
    user = ctx["user"]

    spare = Plan(user_id=user.id, project_id=project.id, title="Spare", content="")
    db.add(spare)
    db.commit()

    resp = client.delete(f"/plans/{spare.id}")
    assert resp.status_code in (200, 204)

    # Should be gone.
    check = client.get(f"/plans/{spare.id}")
    assert check.status_code == 404
