"""
Tests for work-session endpoints:
  - POST /tasks/{id}/start  (now idempotent — adopts an existing active session)
  - POST /tasks/{id}/session/restart  (modes: session / task / custom)
  - active_session_started_at surfaced in the serialized task
"""
import datetime

from database import WorkSession


def _active(db, task_id):
    return (
        db.query(WorkSession)
        .filter(WorkSession.task_id == task_id, WorkSession.ended_at.is_(None))
        .all()
    )


# ── start idempotency ─────────────────────────────────────────────────────────

def test_start_creates_session(http_client):
    client, ctx = http_client
    task = ctx["task"]
    resp = client.post(f"/tasks/{task.id}/start")
    assert resp.status_code == 200
    assert resp.json()["started_at"] is not None
    assert len(_active(ctx["db"], task.id)) == 1


def test_start_twice_is_idempotent(http_client):
    """A second start (e.g. from another device) must not error or duplicate."""
    client, ctx = http_client
    task = ctx["task"]
    first = client.post(f"/tasks/{task.id}/start").json()
    resp = client.post(f"/tasks/{task.id}/start")
    assert resp.status_code == 200
    # Same session adopted, not a new one.
    assert resp.json()["session_id"] == first["session_id"]
    assert len(_active(ctx["db"], task.id)) == 1


def test_serialized_task_exposes_active_session(http_client):
    client, ctx = http_client
    task = ctx["task"]
    client.post(f"/tasks/{task.id}/start")
    rows = client.get("/tasks", params={"project_id": ctx["project"].id}).json()
    match = next(t for t in rows if t["id"] == task.id)
    assert match["active_session_started_at"] is not None


# ── restart: session mode ─────────────────────────────────────────────────────

def test_restart_session_moves_start_forward(http_client):
    client, ctx = http_client
    db, task = ctx["db"], ctx["task"]
    client.post(f"/tasks/{task.id}/start")
    # Backdate the active session.
    sess = _active(db, task.id)[0]
    sess.started_at = datetime.datetime.utcnow() - datetime.timedelta(hours=2)
    db.commit()

    resp = client.post(f"/tasks/{task.id}/session/restart", json={"mode": "session"})
    assert resp.status_code == 200
    db.refresh(sess)
    assert (datetime.datetime.utcnow() - sess.started_at).total_seconds() < 60
    assert len(_active(db, task.id)) == 1


def test_restart_session_with_no_active_creates_one(http_client):
    client, ctx = http_client
    db, task = ctx["db"], ctx["task"]
    resp = client.post(f"/tasks/{task.id}/session/restart", json={"mode": "session"})
    assert resp.status_code == 200
    assert len(_active(db, task.id)) == 1


# ── restart: task mode ────────────────────────────────────────────────────────

def test_restart_task_wipes_history_and_starts_fresh(http_client):
    client, ctx = http_client
    db, task = ctx["db"], ctx["task"]
    # One completed session + one active session.
    now = datetime.datetime.utcnow()
    db.add(WorkSession(
        task_id=task.id, user_id=ctx["user"].id,
        started_at=now - datetime.timedelta(hours=3),
        ended_at=now - datetime.timedelta(hours=2),
    ))
    db.commit()
    client.post(f"/tasks/{task.id}/start")

    resp = client.post(f"/tasks/{task.id}/session/restart", json={"mode": "task"})
    assert resp.status_code == 200
    all_sessions = db.query(WorkSession).filter(WorkSession.task_id == task.id).all()
    assert len(all_sessions) == 1
    assert all_sessions[0].ended_at is None


# ── restart: custom mode ──────────────────────────────────────────────────────

def test_restart_custom_sets_provided_start(http_client):
    client, ctx = http_client
    db, task = ctx["db"], ctx["task"]
    client.post(f"/tasks/{task.id}/start")
    custom = (datetime.datetime.utcnow() - datetime.timedelta(minutes=45))
    resp = client.post(
        f"/tasks/{task.id}/session/restart",
        json={"mode": "custom", "started_at": custom.isoformat()},
    )
    assert resp.status_code == 200
    sess = _active(db, task.id)[0]
    assert abs((sess.started_at - custom).total_seconds()) < 2


def test_restart_custom_requires_started_at(http_client):
    client, ctx = http_client
    task = ctx["task"]
    client.post(f"/tasks/{task.id}/start")
    resp = client.post(f"/tasks/{task.id}/session/restart", json={"mode": "custom"})
    assert resp.status_code == 422


def test_restart_custom_rejects_future_start(http_client):
    client, ctx = http_client
    task = ctx["task"]
    client.post(f"/tasks/{task.id}/start")
    future = (datetime.datetime.utcnow() + datetime.timedelta(hours=1)).isoformat()
    resp = client.post(
        f"/tasks/{task.id}/session/restart",
        json={"mode": "custom", "started_at": future},
    )
    assert resp.status_code == 422


def test_restart_unknown_mode_rejected(http_client):
    client, ctx = http_client
    task = ctx["task"]
    resp = client.post(f"/tasks/{task.id}/session/restart", json={"mode": "bogus"})
    assert resp.status_code == 422


# ── list / edit a task's work sessions ────────────────────────────────────────

def _add_completed_session(db, task, user_id, start, end):
    ws = WorkSession(task_id=task.id, user_id=user_id, started_at=start, ended_at=end)
    db.add(ws)
    db.commit()
    return ws


def test_list_task_sessions_includes_active_and_completed(http_client):
    client, ctx = http_client
    db, task = ctx["db"], ctx["task"]
    now = datetime.datetime.utcnow()
    _add_completed_session(
        db, task, ctx["user"].id,
        now - datetime.timedelta(hours=3), now - datetime.timedelta(hours=2),
    )
    client.post(f"/tasks/{task.id}/start")  # one active session

    resp = client.get(f"/tasks/{task.id}/sessions")
    assert resp.status_code == 200
    rows = resp.json()
    assert len(rows) == 2
    active = [r for r in rows if r["active"]]
    assert len(active) == 1
    completed = [r for r in rows if not r["active"]]
    assert completed[0]["duration_minutes"] == 60.0


def test_update_task_sessions_replaces_completed_keeps_active(http_client):
    client, ctx = http_client
    db, task = ctx["db"], ctx["task"]
    now = datetime.datetime.utcnow()
    _add_completed_session(
        db, task, ctx["user"].id,
        now - datetime.timedelta(hours=5), now - datetime.timedelta(hours=4),
    )
    client.post(f"/tasks/{task.id}/start")  # active session must survive

    new_start = (now - datetime.timedelta(hours=2)).isoformat()
    new_end = (now - datetime.timedelta(hours=1)).isoformat()
    resp = client.patch(
        f"/tasks/{task.id}/sessions",
        json={"sessions": [{"started_at": new_start, "ended_at": new_end}]},
    )
    assert resp.status_code == 200
    rows = resp.json()
    # One replaced completed session + the still-active one.
    assert len([r for r in rows if not r["active"]]) == 1
    assert len([r for r in rows if r["active"]]) == 1
    edited = next(r for r in rows if not r["active"])
    assert edited["duration_minutes"] == 60.0


def test_update_task_sessions_rejects_inverted_interval(http_client):
    client, ctx = http_client
    task = ctx["task"]
    now = datetime.datetime.utcnow()
    resp = client.patch(
        f"/tasks/{task.id}/sessions",
        json={"sessions": [{
            "started_at": now.isoformat(),
            "ended_at": (now - datetime.timedelta(hours=1)).isoformat(),
        }]},
    )
    assert resp.status_code == 422


def test_update_task_sessions_rejects_future_times(http_client):
    client, ctx = http_client
    task = ctx["task"]
    now = datetime.datetime.utcnow()
    resp = client.patch(
        f"/tasks/{task.id}/sessions",
        json={"sessions": [{
            "started_at": now.isoformat(),
            "ended_at": (now + datetime.timedelta(hours=2)).isoformat(),
        }]},
    )
    assert resp.status_code == 422
