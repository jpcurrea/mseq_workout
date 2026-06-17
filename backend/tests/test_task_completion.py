"""
Tests for _mark_task_done and the /tasks/{id}/complete + /tasks/{id}/skip
HTTP endpoints.

Covers:
  - Non-recurring task → is_completed=True, TaskCompletion row created
  - Recurring DAILY task → is_completed=False, due_date advanced
  - Recurring WEEKDAYS task → date never lands on weekend
  - Note stored in TaskCompletion
  - Status "skipped" recorded correctly
  - Un-complete (toggle back) via HTTP endpoint
"""
import datetime
import pytest

from database import Task, Plan, TaskCompletion
from routers.tasks import _mark_task_done

MON, TUE, WED, THU, FRI = 0, 1, 2, 3, 4
SAT, SUN = 5, 6


# ── Helper ────────────────────────────────────────────────────────────────────

NOW = datetime.datetime(2026, 6, 16, 10, 0, 0)  # Tuesday


# ── Non-recurring tasks ───────────────────────────────────────────────────────

def test_nonrecurring_is_marked_completed(db, user, project, task):
    task.is_recurring = False
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="completed")
    db.flush()
    assert task.is_completed is True
    assert task.completed_at == NOW

def test_nonrecurring_creates_completion_row(db, user, project, task):
    task.is_recurring = False
    task.title = "Test Task"
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="completed")
    db.flush()
    completions = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).all()
    assert len(completions) == 1
    c = completions[0]
    assert c.status == "completed"
    assert c.title == "Test Task"
    assert c.completed_at == NOW

def test_nonrecurring_skipped_status(db, user, project, task):
    task.is_recurring = False
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="skipped")
    db.flush()
    c = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).first()
    assert c is not None
    assert c.status == "skipped"

def test_note_stored_in_completion(db, user, project, task):
    task.is_recurring = False
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="completed", note="Finished early!")
    db.flush()
    c = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).first()
    assert c.note == "Finished early!"

def test_note_none_when_not_provided(db, user, project, task):
    task.is_recurring = False
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="completed")
    db.flush()
    c = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).first()
    assert c.note is None


# ── Recurring DAILY ───────────────────────────────────────────────────────────

def test_recurring_daily_resets_completed_flag(db, user, project, task):
    task.is_recurring = True
    task.recurrence_rule = "DAILY"
    task.due_date = NOW
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="completed")
    db.flush()
    assert task.is_completed is False
    assert task.completed_at is None

def test_recurring_daily_advances_due_date_one_day(db, user, project, task):
    task.is_recurring = True
    task.recurrence_rule = "DAILY"
    task.due_date = NOW
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="completed")
    db.flush()
    assert task.due_date == NOW + datetime.timedelta(days=1)

def test_recurring_daily_creates_completion_row(db, user, project, task):
    task.is_recurring = True
    task.recurrence_rule = "DAILY"
    task.due_date = NOW
    db.flush()
    _mark_task_done(task, user.id, db, NOW, status="completed")
    db.flush()
    completions = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).all()
    assert len(completions) == 1

def test_recurring_daily_multiple_completions(db, user, project, task):
    task.is_recurring = True
    task.recurrence_rule = "DAILY"
    task.due_date = NOW
    db.flush()
    for i in range(3):
        _mark_task_done(task, user.id, db, NOW + datetime.timedelta(days=i), status="completed")
        db.flush()
    completions = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).all()
    assert len(completions) == 3
    assert task.is_completed is False


# ── Recurring WEEKDAYS ────────────────────────────────────────────────────────

def test_recurring_weekdays_friday_advances_to_monday(db, user, project, task):
    friday = datetime.datetime(2026, 6, 12)  # Fri
    assert friday.weekday() == FRI
    task.is_recurring = True
    task.recurrence_rule = "WEEKDAYS"
    task.due_date = friday
    db.flush()
    _mark_task_done(task, user.id, db, friday, status="completed")
    db.flush()
    assert task.due_date.weekday() == MON
    assert task.is_completed is False

def test_recurring_weekdays_never_lands_on_weekend(db, user, project, task):
    task.is_recurring = True
    task.recurrence_rule = "WEEKDAYS"
    for offset in range(7):
        start = datetime.datetime(2026, 6, 1) + datetime.timedelta(days=offset)
        task.due_date = start
        task.is_completed = False
        db.flush()
        _mark_task_done(task, user.id, db, start, status="completed")
        db.flush()
        assert task.due_date.weekday() < SAT, (
            f"After completing on {start.strftime('%A')} ({start.date()}), "
            f"next due is {task.due_date.strftime('%A')} ({task.due_date.date()})"
        )
        # Reset for next iteration.
        db.query(TaskCompletion).delete()
        db.flush()

def test_recurring_weekdays_tuesday_to_wednesday(db, user, project, task):
    tuesday = datetime.datetime(2026, 6, 16)
    assert tuesday.weekday() == TUE
    task.is_recurring = True
    task.recurrence_rule = "WEEKDAYS"
    task.due_date = tuesday
    db.flush()
    _mark_task_done(task, user.id, db, tuesday, status="completed")
    db.flush()
    assert task.due_date.weekday() == WED
    assert task.due_date == datetime.datetime(2026, 6, 17)


# ── HTTP endpoint: POST /tasks/{id}/complete ──────────────────────────────────

def test_http_complete_non_recurring(http_client):
    client, ctx = http_client
    task = ctx["task"]
    task.is_recurring = False
    ctx["db"].commit()
    resp = client.post(f"/tasks/{task.id}/complete")
    assert resp.status_code == 200
    data = resp.json()
    assert data["is_completed"] is True

def test_http_complete_idempotent_toggle(http_client):
    """Posting complete twice should un-complete the task."""
    client, ctx = http_client
    task = ctx["task"]
    task.is_recurring = False
    ctx["db"].commit()
    client.post(f"/tasks/{task.id}/complete")
    resp = client.post(f"/tasks/{task.id}/complete")
    assert resp.status_code == 200
    data = resp.json()
    assert data["is_completed"] is False

def test_http_complete_with_note(http_client):
    client, ctx = http_client
    db = ctx["db"]
    task = ctx["task"]
    task.is_recurring = False
    db.commit()
    resp = client.post(f"/tasks/{task.id}/complete", json={"note": "All done!"})
    assert resp.status_code == 200
    c = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).first()
    assert c is not None
    assert c.note == "All done!"

def test_http_complete_nonexistent_task(http_client):
    client, _ = http_client
    resp = client.post("/tasks/999999/complete")
    assert resp.status_code == 404


# ── HTTP endpoint: POST /tasks/{id}/skip ──────────────────────────────────────

def test_http_skip_records_skipped_status(http_client):
    client, ctx = http_client
    db = ctx["db"]
    task = ctx["task"]
    task.is_recurring = True
    task.recurrence_rule = "DAILY"
    task.due_date = datetime.datetime(2026, 6, 16)
    db.commit()
    resp = client.post(f"/tasks/{task.id}/skip")
    assert resp.status_code == 200
    c = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).first()
    assert c is not None
    assert c.status == "skipped"

def test_http_skip_advances_recurring_task(http_client):
    client, ctx = http_client
    db = ctx["db"]
    task = ctx["task"]
    task.is_recurring = True
    task.recurrence_rule = "DAILY"
    # An overdue daily occurrence (yesterday).
    task.due_date = datetime.datetime.utcnow() - datetime.timedelta(days=1)
    db.commit()
    resp = client.post(f"/tasks/{task.id}/skip")
    assert resp.status_code == 200
    db.refresh(task)
    # Default "now" advancement: skip missed occurrences to the next one after now.
    assert task.due_date > datetime.datetime.utcnow()
    assert task.is_completed is False

def test_http_skip_nonrecurring_marks_completed(http_client):
    client, ctx = http_client
    db = ctx["db"]
    task = ctx["task"]
    task.is_recurring = False
    db.commit()
    resp = client.post(f"/tasks/{task.id}/skip")
    assert resp.status_code == 200
    db.refresh(task)
    assert task.is_completed is True
    c = db.query(TaskCompletion).filter(TaskCompletion.task_id == task.id).first()
    assert c.status == "skipped"
