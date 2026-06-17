"""
Tests for editing a completion's work-session intervals via
PATCH /tasks/completions/{completion_id}/sessions.
"""
import datetime
import json

import pytest

from database import TaskCompletion


def _make_completion(db, project, task, sessions=None, completed_at=None):
    c = TaskCompletion(
        task_id=task.id,
        user_id=task.user_id,
        project_id=project.id,
        title="Test Task",
        completed_at=completed_at or datetime.datetime(2026, 6, 16, 12, 0, 0),
        status="completed",
        actual_minutes=sum(s.get("duration_minutes", 0) for s in (sessions or [])) or None,
        work_sessions_json=json.dumps(sessions) if sessions else None,
    )
    db.add(c)
    db.flush()
    return c


def test_update_sessions_recomputes_actual_minutes(http_client):
    client, ctx = http_client
    db, project, task = ctx["db"], ctx["project"], ctx["task"]
    c = _make_completion(db, project, task, sessions=[
        {"started_at": "2026-06-16T10:00:00", "ended_at": "2026-06-16T10:30:00", "duration_minutes": 30},
    ])
    db.commit()

    resp = client.patch(
        f"/tasks/completions/{c.id}/sessions",
        json={"sessions": [
            {"started_at": "2026-06-16T10:00:00", "ended_at": "2026-06-16T11:00:00"},
            {"started_at": "2026-06-16T13:00:00", "ended_at": "2026-06-16T13:15:00"},
        ]},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["actual_minutes"] == pytest.approx(75.0)
    assert len(body["work_sessions"]) == 2
    # completed_at follows the latest stop time.
    assert body["completed_at"].startswith("2026-06-16T13:15:00")


def test_update_sessions_persists_json(http_client):
    client, ctx = http_client
    db, project, task = ctx["db"], ctx["project"], ctx["task"]
    c = _make_completion(db, project, task)
    db.commit()

    resp = client.patch(
        f"/tasks/completions/{c.id}/sessions",
        json={"sessions": [
            {"started_at": "2026-06-16T09:00:00", "ended_at": "2026-06-16T09:45:00", "notes": "morning"},
        ]},
    )
    assert resp.status_code == 200, resp.text
    db.refresh(c)
    stored = json.loads(c.work_sessions_json)
    assert len(stored) == 1
    assert stored[0]["duration_minutes"] == pytest.approx(45.0)
    assert stored[0]["notes"] == "morning"
    assert c.actual_minutes == pytest.approx(45.0)


def test_update_sessions_rejects_end_before_start(http_client):
    client, ctx = http_client
    db, project, task = ctx["db"], ctx["project"], ctx["task"]
    c = _make_completion(db, project, task)
    db.commit()

    resp = client.patch(
        f"/tasks/completions/{c.id}/sessions",
        json={"sessions": [
            {"started_at": "2026-06-16T11:00:00", "ended_at": "2026-06-16T10:00:00"},
        ]},
    )
    assert resp.status_code == 422


def test_update_sessions_rejects_future(http_client):
    client, ctx = http_client
    db, project, task = ctx["db"], ctx["project"], ctx["task"]
    c = _make_completion(db, project, task)
    db.commit()

    future = datetime.datetime.utcnow() + datetime.timedelta(days=2)
    resp = client.patch(
        f"/tasks/completions/{c.id}/sessions",
        json={"sessions": [
            {"started_at": future.isoformat(), "ended_at": (future + datetime.timedelta(minutes=10)).isoformat()},
        ]},
    )
    assert resp.status_code == 422


def test_update_sessions_empty_clears(http_client):
    client, ctx = http_client
    db, project, task = ctx["db"], ctx["project"], ctx["task"]
    c = _make_completion(db, project, task, sessions=[
        {"started_at": "2026-06-16T10:00:00", "ended_at": "2026-06-16T10:30:00", "duration_minutes": 30},
    ])
    db.commit()

    resp = client.patch(
        f"/tasks/completions/{c.id}/sessions",
        json={"sessions": []},
    )
    assert resp.status_code == 200, resp.text
    db.refresh(c)
    assert c.work_sessions_json is None
    assert c.actual_minutes is None


def test_update_sessions_404_for_missing(http_client):
    client, _ = http_client
    resp = client.patch(
        "/tasks/completions/999999/sessions",
        json={"sessions": []},
    )
    assert resp.status_code == 404
