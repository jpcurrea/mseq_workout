"""
Tests for subtask duration/progress roll-up and parent auto-completion.

Covers:
  - _effective_duration_minutes: inherit (sum of subtasks) vs custom (own)
  - _tree_actual_minutes: parent own work + recursive subtask work
  - _autocomplete_parent: parent completes once all subtasks are complete
  - recurring parents are NOT auto-completed
"""
import datetime

from database import Task, WorkSession, TaskCompletion
from routers.tasks import (
    _mark_task_done,
    _effective_duration_minutes,
    _tree_actual_minutes,
    _inherits_duration,
)

NOW = datetime.datetime(2026, 6, 16, 10, 0, 0)  # Tuesday


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_task(db, user, project, **kwargs):
    t = Task(user_id=user.id, project_id=project.id, title=kwargs.pop("title", "T"), **kwargs)
    db.add(t)
    db.flush()
    return t


def _add_session(db, user, task, start, end):
    ws = WorkSession(task_id=task.id, user_id=user.id, started_at=start, ended_at=end)
    db.add(ws)
    db.flush()
    return ws


# ── Effective duration ────────────────────────────────────────────────────────

def test_leaf_uses_own_duration(db, user, project):
    t = _make_task(db, user, project, duration_minutes=30)
    assert _effective_duration_minutes(t) == 30
    assert _inherits_duration(t) is False


def test_parent_inherits_sum_when_flag_none(db, user, project):
    parent = _make_task(db, user, project, duration_minutes=999)
    _make_task(db, user, project, duration_minutes=20, parent_task_id=parent.id)
    _make_task(db, user, project, duration_minutes=15, parent_task_id=parent.id)
    db.refresh(parent)
    assert _inherits_duration(parent) is True
    assert _effective_duration_minutes(parent) == 35


def test_parent_inherits_explicit_true(db, user, project):
    parent = _make_task(db, user, project, duration_minutes=999, inherit_subtask_duration=True)
    _make_task(db, user, project, duration_minutes=10, parent_task_id=parent.id)
    _make_task(db, user, project, duration_minutes=5, parent_task_id=parent.id)
    db.refresh(parent)
    assert _effective_duration_minutes(parent) == 15


def test_parent_custom_duration_when_flag_false(db, user, project):
    parent = _make_task(db, user, project, duration_minutes=120, inherit_subtask_duration=False)
    _make_task(db, user, project, duration_minutes=10, parent_task_id=parent.id)
    db.refresh(parent)
    assert _inherits_duration(parent) is False
    assert _effective_duration_minutes(parent) == 120


def test_nested_inherit_sums_recursively(db, user, project):
    grandparent = _make_task(db, user, project)
    parent = _make_task(db, user, project, parent_task_id=grandparent.id)
    _make_task(db, user, project, duration_minutes=8, parent_task_id=parent.id)
    _make_task(db, user, project, duration_minutes=12, parent_task_id=parent.id)
    db.refresh(parent)
    db.refresh(grandparent)
    assert _effective_duration_minutes(parent) == 20
    assert _effective_duration_minutes(grandparent) == 20


# ── Tree actual minutes ───────────────────────────────────────────────────────

def test_tree_actual_none_when_no_work(db, user, project):
    parent = _make_task(db, user, project)
    _make_task(db, user, project, parent_task_id=parent.id)
    db.refresh(parent)
    assert _tree_actual_minutes(parent) is None


def test_tree_actual_sums_own_and_subtasks(db, user, project):
    parent = _make_task(db, user, project)
    child = _make_task(db, user, project, parent_task_id=parent.id)
    # parent's own work: 10 minutes
    _add_session(db, user, parent, NOW, NOW + datetime.timedelta(minutes=10))
    # child work: 25 minutes
    _add_session(db, user, child, NOW, NOW + datetime.timedelta(minutes=25))
    db.refresh(parent)
    assert _tree_actual_minutes(parent) == 35
    # child alone reports only its own
    assert _tree_actual_minutes(child) == 25


# ── Auto-complete parents ─────────────────────────────────────────────────────

def test_parent_autocompletes_when_all_subtasks_done(db, user, project):
    parent = _make_task(db, user, project)
    c1 = _make_task(db, user, project, parent_task_id=parent.id)
    c2 = _make_task(db, user, project, parent_task_id=parent.id)
    db.refresh(parent)

    _mark_task_done(c1, user.id, db, NOW, status="completed")
    db.flush()
    db.refresh(parent)
    assert parent.is_completed is False  # one subtask still open

    _mark_task_done(c2, user.id, db, NOW, status="completed")
    db.flush()
    db.refresh(parent)
    assert parent.is_completed is True
    # parent's own completion-history row recorded
    pc = db.query(TaskCompletion).filter(TaskCompletion.task_id == parent.id).all()
    assert len(pc) == 1


def test_autocomplete_bubbles_up_chain(db, user, project):
    grandparent = _make_task(db, user, project)
    parent = _make_task(db, user, project, parent_task_id=grandparent.id)
    child = _make_task(db, user, project, parent_task_id=parent.id)
    db.refresh(grandparent)
    db.refresh(parent)

    _mark_task_done(child, user.id, db, NOW, status="completed")
    db.flush()
    db.refresh(parent)
    db.refresh(grandparent)
    assert parent.is_completed is True
    assert grandparent.is_completed is True


def test_recurring_parent_not_autocompleted(db, user, project):
    parent = _make_task(
        db, user, project,
        is_recurring=True, recurrence_rule="DAILY",
        due_date=NOW + datetime.timedelta(days=1),
    )
    child = _make_task(db, user, project, parent_task_id=parent.id)
    db.refresh(parent)

    _mark_task_done(child, user.id, db, NOW, status="completed")
    db.flush()
    db.refresh(parent)
    assert parent.is_completed is False


def test_skipped_subtask_counts_toward_parent_completion(db, user, project):
    parent = _make_task(db, user, project)
    c1 = _make_task(db, user, project, parent_task_id=parent.id)
    c2 = _make_task(db, user, project, parent_task_id=parent.id)
    db.refresh(parent)

    _mark_task_done(c1, user.id, db, NOW, status="completed")
    _mark_task_done(c2, user.id, db, NOW, status="skipped")
    db.flush()
    db.refresh(parent)
    assert parent.is_completed is True
