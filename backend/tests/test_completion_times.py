"""
Tests for the completion-dialog features:

Feature 1 — editable start/stop times:
  - custom start/stop record a work session and drive actual_minutes
  - the stop time becomes the completion timestamp
  - an active session's start/stop are overridden by supplied values
  - HTTP validation rejects future times and stop-before-start

Feature 2 — recurrence advancement mode:
  - "now" skips every missed occurrence (next iteration after the present)
  - "stop" advances to the first iteration after the selected stop time
  - the chosen mode is persisted on the task
  - default mode is "now"; skip reuses the stored mode
"""
import datetime

from database import Task, WorkSession, TaskCompletion
from routers.tasks import _mark_task_done, _advance_due_date

# A fixed "current moment" for deterministic assertions.
NOW = datetime.datetime(2026, 6, 16, 10, 0, 0)  # Tuesday


# ── _advance_due_date helper ──────────────────────────────────────────────────

def test_advance_always_moves_forward_at_least_once():
    due = NOW
    assert _advance_due_date(due, "DAILY", NOW - datetime.timedelta(days=5)) == NOW + datetime.timedelta(days=1)


def test_advance_now_skips_missed_daily_occurrences():
    due = NOW - datetime.timedelta(days=7)
    # Target = now → first daily occurrence strictly after now.
    assert _advance_due_date(due, "DAILY", NOW) == NOW + datetime.timedelta(days=1)


def test_advance_stop_lands_after_stop_time():
    due = NOW - datetime.timedelta(days=7)
    stop = NOW - datetime.timedelta(days=3)
    # First daily occurrence strictly after the stop time.
    assert _advance_due_date(due, "DAILY", stop) == NOW - datetime.timedelta(days=2)


# ── Feature 1: custom start/stop times ────────────────────────────────────────

def test_custom_times_record_work_session(db, user, project, task):
    task.is_recurring = False
    db.flush()
    started = NOW - datetime.timedelta(hours=2)
    ended = NOW - datetime.timedelta(hours=1)
    _mark_task_done(task, user.id, db, NOW, status="completed", started_at=started, ended_at=ended)
    db.flush()

    sessions = db.query(WorkSession).filter(WorkSession.task_id == task.id).all()
    assert len(sessions) == 1
    assert sessions[0].started_at == started
    assert sessions[0].ended_at == ended

    c = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).first()
    assert c.actual_minutes == 60.0
    # The stop time becomes the completion timestamp.
    assert c.completed_at == ended
    assert task.completed_at == ended


def test_active_session_times_overridden(db, user, project, task):
    task.is_recurring = False
    db.flush()
    # A session that started 5h ago is still running.
    sess = WorkSession(
        task_id=task.id,
        user_id=user.id,
        started_at=NOW - datetime.timedelta(hours=5),
    )
    db.add(sess)
    db.flush()

    started = NOW - datetime.timedelta(hours=2)
    ended = NOW - datetime.timedelta(hours=1)
    _mark_task_done(task, user.id, db, NOW, status="completed", started_at=started, ended_at=ended)
    db.flush()

    # The same session is reused, with overridden times.
    sessions = db.query(WorkSession).filter(WorkSession.task_id == task.id).all()
    assert len(sessions) == 1
    assert sessions[0].started_at == started
    assert sessions[0].ended_at == ended

    c = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).first()
    assert c.actual_minutes == 60.0


def test_no_times_completes_at_now(db, user, project, task):
    task.is_recurring = False
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="completed")
    db.flush()
    assert task.completed_at == NOW
    # No fabricated work session when no times supplied and none was running.
    assert db.query(WorkSession).filter(WorkSession.task_id == task.id).count() == 0


# ── Feature 1: HTTP validation ────────────────────────────────────────────────

def test_complete_rejects_future_ended(http_client):
    client, ctx = http_client
    task = ctx["task"]
    future = (datetime.datetime.utcnow() + datetime.timedelta(hours=2)).isoformat()
    resp = client.post(f"/tasks/{task.id}/complete", json={"ended_at": future})
    assert resp.status_code == 422


def test_complete_rejects_ended_before_started(http_client):
    client, ctx = http_client
    task = ctx["task"]
    now = datetime.datetime.utcnow()
    resp = client.post(
        f"/tasks/{task.id}/complete",
        json={
            "started_at": now.isoformat(),
            "ended_at": (now - datetime.timedelta(hours=1)).isoformat(),
        },
    )
    assert resp.status_code == 422


def test_complete_with_custom_times_via_http(http_client):
    client, ctx = http_client
    task = ctx["task"]
    now = datetime.datetime.utcnow()
    started = (now - datetime.timedelta(minutes=30)).isoformat()
    ended = (now - datetime.timedelta(minutes=10)).isoformat()
    resp = client.post(
        f"/tasks/{task.id}/complete",
        json={"started_at": started, "ended_at": ended, "note": "done early"},
    )
    assert resp.status_code == 200
    c = (
        ctx["db"].query(TaskCompletion)
        .filter(TaskCompletion.task_id == task.id)
        .first()
    )
    assert c.note == "done early"
    assert c.actual_minutes == 20.0


# ── Feature 2: recurrence advancement mode ────────────────────────────────────

def _recurring_daily(db, user, project, due):
    t = Task(
        user_id=user.id,
        project_id=project.id,
        title="Daily task",
        is_recurring=True,
        recurrence_rule="DAILY",
        due_date=due,
    )
    db.add(t)
    db.flush()
    return t


def test_advance_mode_now_is_default(db, user, project):
    task = _recurring_daily(db, user, project, NOW - datetime.timedelta(days=7))
    _mark_task_done(task, user.id, db, NOW, status="completed")
    db.flush()
    assert task.is_completed is False
    assert task.recurrence_advance_mode == "now"
    assert task.due_date == NOW + datetime.timedelta(days=1)


def test_advance_mode_stop_uses_stop_time(db, user, project):
    task = _recurring_daily(db, user, project, NOW - datetime.timedelta(days=7))
    ended = NOW - datetime.timedelta(days=3)
    _mark_task_done(
        task, user.id, db, NOW,
        status="completed", ended_at=ended, advance_mode="stop",
    )
    db.flush()
    assert task.recurrence_advance_mode == "stop"
    assert task.due_date == NOW - datetime.timedelta(days=2)


def test_advance_mode_persisted_and_reused_by_skip(db, user, project):
    task = _recurring_daily(db, user, project, NOW - datetime.timedelta(days=7))
    # First completion selects "stop" and persists it.
    _mark_task_done(
        task, user.id, db, NOW,
        status="completed", ended_at=NOW - datetime.timedelta(days=3), advance_mode="stop",
    )
    db.flush()
    assert task.recurrence_advance_mode == "stop"

    # A later skip with no explicit mode reuses the stored "stop" preference.
    new_due = task.due_date  # NOW - 2 days
    _mark_task_done(
        task, user.id, db, NOW,
        status="skipped", ended_at=NOW - datetime.timedelta(days=1),
    )
    db.flush()
    # Stop target = NOW - 1 day → first daily occurrence after it = NOW.
    assert task.recurrence_advance_mode == "stop"
    assert task.due_date == NOW
    assert new_due == NOW - datetime.timedelta(days=2)


def test_advance_mode_invalid_falls_back_to_now(db, user, project):
    task = _recurring_daily(db, user, project, NOW - datetime.timedelta(days=2))
    _mark_task_done(task, user.id, db, NOW, status="completed", advance_mode="bogus")
    db.flush()
    assert task.recurrence_advance_mode == "now"
    assert task.due_date == NOW + datetime.timedelta(days=1)
