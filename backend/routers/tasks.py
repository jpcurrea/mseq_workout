"""
Task management routes: tasks, tags, work sessions, plans, and analytics.
"""
import datetime
import csv
import difflib
import io
import json
import math
import re
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, File, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel
from sqlalchemy.orm import Session, selectinload

from database import (
    get_session,
    Task,
    TaskCompletion,
    Tag,
    WorkSession,
    Plan,
    PlanRevision,
    Project,
    ProjectMembership,
    task_tag_link,
)
from dependencies import get_current_user_id

tasks_router = APIRouter(prefix="/tasks", tags=["tasks"])
plans_router = APIRouter(prefix="/plans", tags=["plans"])


def _assert_project_member(project_id: int, user_id: int, session: Session):
    """Raise 403 if the user is not a member of the project."""
    m = session.query(ProjectMembership).filter(
        ProjectMembership.project_id == project_id,
        ProjectMembership.user_id == user_id,
    ).first()
    if not m:
        raise HTTPException(status_code=403, detail="Not a member of this project")
    return m


def _assert_can_write(project_id: int, user_id: int, session: Session):
    """Raise 403 if the user has viewer-only access."""
    m = _assert_project_member(project_id, user_id, session)
    if m.role == "viewer":
        raise HTTPException(status_code=403, detail="Viewer role cannot modify tasks")

# ── Urgency constants ──────────────────────────────────────────────────────────

# Time window over which pre-deadline urgency ramps 0→1
_URGENCY_HORIZON_MINUTES = 7 * 24 * 60  # 7 days


# ── Urgency helpers ────────────────────────────────────────────────────────────

def _start_by(task: Task) -> Optional[datetime.datetime]:
    if task.due_date is None:
        return None
    if task.duration_minutes:
        return task.due_date - datetime.timedelta(minutes=task.duration_minutes)
    return task.due_date


def _own_urgency(task: Task, now: datetime.datetime) -> float:
    """Urgency [0, 1] based on this task's deadline only.

    • 0   – no deadline, or completed
    • 0→1 – pre-deadline: ramps linearly over URGENCY_HORIZON
    • 1   – overdue (start_by <= now)
    """
    if task.is_completed or task.due_date is None:
        return 0.0
    sb = _start_by(task)
    if sb is None:
        return 0.0
    time_remaining = (sb - now).total_seconds() / 60.0
    if time_remaining <= 0:
        return 1.0
    return 1.0 - min(time_remaining / _URGENCY_HORIZON_MINUTES, 1.0)


def _tree_urgency(task: Task, now: datetime.datetime) -> float:
    """Max urgency across this task and all descendants."""
    own = _own_urgency(task, now)
    if not task.subtasks:
        return own
    return max(own, *[_tree_urgency(st, now) for st in task.subtasks])


def _actual_duration_minutes(task: Task) -> Optional[float]:
    completed = [s for s in task.work_sessions if s.ended_at is not None]
    if not completed:
        return None
    return sum(
        (s.ended_at - s.started_at).total_seconds() / 60.0 for s in completed
    )


def _active_session(task: Task) -> Optional["WorkSession"]:
    """Return the task's currently-active work session (ended_at is None), if any."""
    return next((s for s in task.work_sessions if s.ended_at is None), None)


def _serialize_task(task: Task, now: datetime.datetime) -> Dict[str, Any]:
    """Recursively serialize a Task (loads subtasks via relationship)."""
    return {
        "id": task.id,
        "project_id": task.project_id,
        "title": task.title,
        "description": task.description,
        "due_date": task.due_date.isoformat() if task.due_date else None,
        "duration_minutes": task.duration_minutes,
        "start_by": _start_by(task).isoformat() if _start_by(task) else None,
        "is_completed": task.is_completed,
        "completed_at": task.completed_at.isoformat() if task.completed_at else None,
        "is_recurring": task.is_recurring,
        "recurrence_rule": task.recurrence_rule,
        "recurrence_advance_mode": task.recurrence_advance_mode or "now",
        "tags": [{"id": t.id, "name": t.name, "color": t.color} for t in task.tags],
        "subtasks": [_serialize_task(st, now) for st in task.subtasks],
        "urgency_score": _tree_urgency(task, now),
        "actual_duration_minutes": _actual_duration_minutes(task),
        "active_session_started_at": (
            _utc_iso(_active_session(task).started_at)
            if _active_session(task) else None
        ),
        "parent_task_id": task.parent_task_id,
        "created_at": task.created_at.isoformat(),
        "updated_at": task.updated_at.isoformat() if task.updated_at else task.created_at.isoformat(),
    }


def _load_task(task_id: int, user_id: int, session: Session) -> Task:
    task = (
        session.query(Task)
        .filter(Task.id == task_id)
        .options(selectinload(Task.tags), selectinload(Task.work_sessions))
        .first()
    )
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    # Verify user is a member of the task's project
    _assert_project_member(task.project_id, user_id, session)
    return task


def _next_due_date(due_date: datetime.datetime, rule: str) -> datetime.datetime:
    rule = rule.upper()
    if rule == "DAILY":
        return due_date + datetime.timedelta(days=1)
    if rule == "WEEKDAYS":
        # Advance by at least 1 day, then skip over Saturday (5) and Sunday (6)
        next_dt = due_date + datetime.timedelta(days=1)
        while next_dt.weekday() >= 5:
            next_dt += datetime.timedelta(days=1)
        return next_dt
    if rule == "WEEKLY":
        return due_date + datetime.timedelta(weeks=1)
    if rule == "MONTHLY":
        month = due_date.month + 1
        year = due_date.year
        if month > 12:
            month, year = 1, year + 1
        return due_date.replace(year=year, month=month)
    return due_date + datetime.timedelta(days=1)


def _advance_due_date(
    due_date: datetime.datetime, rule: str, target: datetime.datetime
) -> datetime.datetime:
    """Advance ``due_date`` by whole recurrence intervals until it lands strictly
    after ``target``.  Always advances at least once (completing an occurrence
    must move the deadline forward), then skips over any iterations that fall on
    or before ``target``.  A guard caps the loop to avoid runaway iteration."""
    nxt = _next_due_date(due_date, rule)
    guard = 0
    while nxt <= target and guard < 100000:
        nxt = _next_due_date(nxt, rule)
        guard += 1
    return nxt


def _to_naive_utc(dt: Optional[datetime.datetime]) -> Optional[datetime.datetime]:
    """Normalize an optional datetime to naive UTC (matching stored values)."""
    if dt is None:
        return None
    if dt.tzinfo is not None:
        return dt.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    return dt


def _utc_iso(dt: Optional[datetime.datetime]) -> Optional[str]:
    """Serialize a stored (naive) UTC datetime with an explicit 'Z' suffix.

    Stored work-session timestamps are real UTC instants but kept tz-naive.
    Emitting them without a marker makes clients (e.g. Dart's DateTime.parse)
    interpret them as *local* time, shifting them by the UTC offset. Appending
    'Z' lets the client parse them as UTC and convert to local correctly.
    """
    if dt is None:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    return dt.isoformat() + "Z"


def _utc_session_list(raw: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Mark naive UTC timestamps in a stored work-session list as explicit UTC.

    Covers both legacy rows (saved without a marker) and new ones, so clients
    consistently receive UTC-aware ``started_at`` / ``ended_at`` strings.
    """
    out: List[Dict[str, Any]] = []
    for entry in raw:
        s = dict(entry)
        for key in ("started_at", "ended_at"):
            v = s.get(key)
            if isinstance(v, str) and v and "Z" not in v and "+" not in v:
                s[key] = v + "Z"
        out.append(s)
    return out


def _norm_col(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (name or "").strip().lower())


def _csv_get(row: Dict[str, Any], aliases: set[str]) -> Optional[str]:
    for key, value in row.items():
        if _norm_col(str(key)) in aliases:
            text = "" if value is None else str(value).strip()
            if text:
                return text
    return None


def _parse_due_date(value: str) -> Optional[datetime.datetime]:
    val = (value or "").strip()
    if not val:
        return None

    normalized = val.replace("Z", "+00:00")
    try:
        return datetime.datetime.fromisoformat(normalized)
    except ValueError:
        pass

    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%Y/%m/%d", "%d-%m-%Y"):
        try:
            return datetime.datetime.strptime(val, fmt)
        except ValueError:
            continue
    return None


def _parse_duration_minutes(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    val = value.strip().lower()
    if not val:
        return None

    # Org-mode effort often appears as H:MM
    hm = re.fullmatch(r"(\d{1,3}):(\d{1,2})", val)
    if hm:
        return int(hm.group(1)) * 60 + int(hm.group(2))

    # Plain number is interpreted as minutes
    if re.fullmatch(r"\d+(\.\d+)?", val):
        return int(round(float(val)))

    # Supports variants like "1h 30m", "2 hours", "45 min"
    unit_match = re.fullmatch(
        r"\s*(?:(\d+(?:\.\d+)?)\s*h(?:ours?)?)?\s*(?:(\d+(?:\.\d+)?)\s*m(?:in(?:utes?)?)?)?\s*",
        val,
    )
    if unit_match and (unit_match.group(1) or unit_match.group(2)):
        hours = float(unit_match.group(1) or 0)
        mins = float(unit_match.group(2) or 0)
        return int(round(hours * 60 + mins))

    return None


def _parse_tags(value: Optional[str]) -> List[str]:
    if not value:
        return []
    text = value.strip()
    if not text:
        return []

    # Org-style tags: :work:deep:
    if text.startswith(":") and text.endswith(":"):
        parts = [p.strip() for p in text.split(":") if p.strip()]
    else:
        parts = [p.strip() for p in re.split(r"[,;|]", text) if p.strip()]

    seen = set()
    deduped = []
    for p in parts:
        key = p.lower()
        if key not in seen:
            seen.add(key)
            deduped.append(p)
    return deduped


CSV_TITLE_ALIASES = {"title", "task", "name", "heading", "todo", "summary", "item"}
CSV_DESC_ALIASES = {"description", "notes", "detail", "body"}
CSV_DUE_ALIASES = {"duedate", "due", "deadline", "scheduled", "date"}
CSV_DURATION_ALIASES = {"duration", "durationminutes", "estimate", "effort", "minutes", "time"}
CSV_STATUS_ALIASES = {"status", "state", "done", "completed", "todo"}
CSV_TAG_ALIASES = {"tags", "tag", "labels", "categories"}
CSV_PARENT_ALIASES = {"parent", "parenttask", "parenttitle", "parentname"}


@tasks_router.get("/import-csv/schema")
async def import_csv_schema():
    """Return accepted CSV columns and examples for client-side help UI."""
    return {
        "required_any_of": {
            "title": sorted(CSV_TITLE_ALIASES),
        },
        "optional": {
            "description": sorted(CSV_DESC_ALIASES),
            "due_date": sorted(CSV_DUE_ALIASES),
            "duration": sorted(CSV_DURATION_ALIASES),
            "status": sorted(CSV_STATUS_ALIASES),
            "tags": sorted(CSV_TAG_ALIASES),
            "parent": sorted(CSV_PARENT_ALIASES),
        },
        "examples": {
            "due_date": ["2026-06-20", "2026-06-20T14:30:00", "06/20/2026"],
            "duration": ["90", "1:30", "1h 30m", "45m"],
            "status": ["todo", "done", "completed"],
            "tags": [":work:deep:", "work,deep", "work;deep"],
        },
    }


# ── Pydantic schemas ───────────────────────────────────────────────────────────

class TaskCreate(BaseModel):
    project_id: int
    title: str
    description: Optional[str] = None
    due_date: Optional[str] = None
    duration_minutes: Optional[int] = None
    parent_task_id: Optional[int] = None
    is_recurring: bool = False
    recurrence_rule: Optional[str] = None
    tag_ids: List[int] = []


class TaskUpdate(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    due_date: Optional[str] = None
    duration_minutes: Optional[int] = None
    parent_task_id: Optional[int] = None
    is_recurring: Optional[bool] = None
    recurrence_rule: Optional[str] = None
    tag_ids: Optional[List[int]] = None


class TagCreate(BaseModel):
    name: str
    color: str = "#6366f1"


class TagUpdate(BaseModel):
    name: Optional[str] = None
    color: Optional[str] = None


class SessionStop(BaseModel):
    notes: Optional[str] = None


class SessionRestart(BaseModel):
    mode: str = "session"   # "session" | "task" | "custom"
    started_at: Optional[datetime.datetime] = None


# ── Task endpoints ─────────────────────────────────────────────────────────────

@tasks_router.get("")
async def list_tasks(
    project_id: int,
    include_completed: bool = False,
    tag_id: Optional[int] = None,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Return top-level tasks (no parent) sorted by tree urgency descending."""
    _assert_project_member(project_id, user_id, session)
    query = (
        session.query(Task)
        .filter(Task.project_id == project_id, Task.parent_task_id.is_(None))
        .options(selectinload(Task.tags), selectinload(Task.work_sessions))
    )
    if not include_completed:
        query = query.filter(Task.is_completed.is_(False))
    tasks = query.all()

    if tag_id is not None:
        tasks = [t for t in tasks if any(tg.id == tag_id for tg in t.tags)]

    now = datetime.datetime.utcnow()
    serialized = [_serialize_task(t, now) for t in tasks]
    serialized.sort(key=lambda t: t["urgency_score"], reverse=True)
    return serialized


@tasks_router.get("/calendar")
async def tasks_for_calendar(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """All incomplete tasks that have a due_date, for calendar rendering."""
    _assert_project_member(project_id, user_id, session)
    tasks = (
        session.query(Task)
        .filter(
            Task.project_id == project_id,
            Task.due_date.isnot(None),
            Task.is_completed.is_(False),
        )
        .options(selectinload(Task.tags))
        .all()
    )
    now = datetime.datetime.utcnow()
    return [
        {
            "id": t.id,
            "title": t.title,
            "due_date": t.due_date.isoformat(),
            "urgency_score": _own_urgency(t, now),
            "tags": [{"id": tg.id, "name": tg.name, "color": tg.color} for tg in t.tags],
            "is_completed": t.is_completed,
        }
        for t in tasks
    ]


@tasks_router.get("/gantt")
async def tasks_for_gantt(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Tasks with both start_by and due_date for Gantt chart rendering."""
    _assert_project_member(project_id, user_id, session)
    tasks = (
        session.query(Task)
        .filter(
            Task.project_id == project_id,
            Task.due_date.isnot(None),
            Task.is_completed.is_(False),
        )
        .options(selectinload(Task.tags))
        .all()
    )
    now = datetime.datetime.utcnow()
    result = []
    for t in tasks:
        sb = _start_by(t)
        result.append({
            "id": t.id,
            "title": t.title,
            "parent_task_id": t.parent_task_id,
            "due_date": t.due_date.isoformat(),
            "start_by": sb.isoformat() if sb else None,
            "duration_minutes": t.duration_minutes,
            "urgency_score": _own_urgency(t, now),
            "tags": [{"id": tg.id, "name": tg.name, "color": tg.color} for tg in t.tags],
        })
    return result


# ── Analytics (MUST be before /{id} to avoid route shadowing) ─────────────────

@tasks_router.get("/analytics/estimation")
async def estimation_analytics(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Per-tag estimation accuracy: avg(actual / estimated) for completed tasks."""
    _assert_project_member(project_id, user_id, session)
    tasks = (
        session.query(Task)
        .filter(
            Task.project_id == project_id,
            Task.is_completed.is_(True),
            Task.duration_minutes.isnot(None),
        )
        .options(selectinload(Task.tags), selectinload(Task.work_sessions))
        .all()
    )

    data = []
    for t in tasks:
        actual = _actual_duration_minutes(t)
        if actual is None or t.duration_minutes <= 0:
            continue
        data.append({"ratio": actual / t.duration_minutes, "tags": [tg.name for tg in t.tags]})

    if not data:
        return {"global": None, "by_tag": {}}

    global_ratio = sum(d["ratio"] for d in data) / len(data)
    by_tag: Dict[str, list] = {}
    for d in data:
        for tag in d["tags"]:
            by_tag.setdefault(tag, []).append(d["ratio"])

    return {
        "global": {
            "avg_ratio": global_ratio,
            "sample_count": len(data),
            "note": "avg(actual/estimated): 1.0=perfect, >1=underestimate, <1=overestimate",
        },
        "by_tag": {
            tag: {"avg_ratio": sum(r) / len(r), "sample_count": len(r)}
            for tag, r in by_tag.items()
        },
    }


@tasks_router.get("/analytics/punctuality")
async def punctuality_analytics(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Per-tag on-time rate: tasks completed before their due_date."""
    _assert_project_member(project_id, user_id, session)
    tasks = (
        session.query(Task)
        .filter(
            Task.project_id == project_id,
            Task.is_completed.is_(True),
            Task.due_date.isnot(None),
            Task.completed_at.isnot(None),
        )
        .options(selectinload(Task.tags))
        .all()
    )

    if not tasks:
        return {"global": None, "by_tag": {}}

    rows = [
        {
            "lateness_min": (t.completed_at - t.due_date).total_seconds() / 60.0,
            "on_time": t.completed_at <= t.due_date,
            "tags": [tg.name for tg in t.tags],
        }
        for t in tasks
    ]

    global_on_time = sum(1 for r in rows if r["on_time"]) / len(rows)
    global_lateness = sum(r["lateness_min"] for r in rows) / len(rows)

    by_tag: Dict[str, list] = {}
    for r in rows:
        for tag in r["tags"]:
            by_tag.setdefault(tag, []).append(r)

    return {
        "global": {
            "on_time_rate": global_on_time,
            "avg_lateness_minutes": global_lateness,
            "sample_count": len(tasks),
        },
        "by_tag": {
            tag: {
                "on_time_rate": sum(1 for r in rs if r["on_time"]) / len(rs),
                "avg_lateness_minutes": sum(r["lateness_min"] for r in rs) / len(rs),
                "sample_count": len(rs),
            }
            for tag, rs in by_tag.items()
        },
    }


@tasks_router.get("/analytics/history")
async def analytics_history(
    project_id: int,
    limit: int = 200,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Raw completed task data for charting — estimation + punctuality combined."""
    _assert_project_member(project_id, user_id, session)
    tasks = (
        session.query(Task)
        .filter(Task.project_id == project_id, Task.is_completed.is_(True))
        .options(selectinload(Task.tags), selectinload(Task.work_sessions))
        .order_by(Task.completed_at.desc())
        .limit(limit)
        .all()
    )
    rows = []
    for t in tasks:
        actual = _actual_duration_minutes(t)
        lateness = (
            (t.completed_at - t.due_date).total_seconds() / 60.0
            if t.due_date and t.completed_at
            else None
        )
        rows.append({
            "id": t.id,
            "title": t.title,
            "tags": [tg.name for tg in t.tags],
            "estimated_minutes": t.duration_minutes,
            "actual_minutes": actual,
            "due_date": t.due_date.isoformat() if t.due_date else None,
            "completed_at": t.completed_at.isoformat() if t.completed_at else None,
            "lateness_minutes": lateness,
            "on_time": (lateness is not None and lateness <= 0),
        })
    return rows


# ── Completion history (view + CSV export) ────────────────────────────────────

def _completion_lateness_minutes(c: TaskCompletion) -> Optional[float]:
    if c.due_date and c.completed_at:
        return (c.completed_at - c.due_date).total_seconds() / 60.0
    return None


@tasks_router.get("/completions")
async def list_completions(
    project_id: int,
    task_id: Optional[int] = None,
    limit: int = 500,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Chronological record of every task completion in the project.
    Optionally filter to a single task with task_id."""
    _assert_project_member(project_id, user_id, session)
    query = (
        session.query(TaskCompletion)
        .filter(TaskCompletion.project_id == project_id)
    )
    if task_id is not None:
        query = query.filter(TaskCompletion.task_id == task_id)
    rows = (
        query
        .order_by(TaskCompletion.completed_at.desc())
        .limit(limit)
        .all()
    )
    return [
        {
            "id": c.id,
            "task_id": c.task_id,
            "title": c.title,
            "tags": c.tags,
            "status": c.status or "completed",
            "completed_at": c.completed_at.isoformat() if c.completed_at else None,
            "due_date": c.due_date.isoformat() if c.due_date else None,
            "estimated_minutes": c.duration_minutes,
            "actual_minutes": c.actual_minutes,
            "lateness_minutes": _completion_lateness_minutes(c),
            "note": c.note,
            "work_sessions": _utc_session_list(json.loads(c.work_sessions_json)) if c.work_sessions_json else [],
        }
        for c in rows
    ]


@tasks_router.get("/completions/export")
async def export_completions(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Download the project's completion record as a CSV file."""
    _assert_project_member(project_id, user_id, session)
    rows = (
        session.query(TaskCompletion)
        .filter(TaskCompletion.project_id == project_id)
        .order_by(TaskCompletion.completed_at.asc())
        .all()
    )

    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow([
        "completion_id",
        "task_id",
        "title",
        "tags",
        "status",
        "completed_at",
        "due_date",
        "estimated_minutes",
        "actual_minutes",
        "lateness_minutes",
    ])
    for c in rows:
        writer.writerow([
            c.id,
            c.task_id if c.task_id is not None else "",
            c.title or "",
            c.tags or "",
            c.status or "completed",
            c.completed_at.isoformat() if c.completed_at else "",
            c.due_date.isoformat() if c.due_date else "",
            c.duration_minutes if c.duration_minutes is not None else "",
            round(c.actual_minutes, 2) if c.actual_minutes is not None else "",
            round(_completion_lateness_minutes(c), 2)
            if _completion_lateness_minutes(c) is not None else "",
        ])

    filename = f"task_completions_project_{project_id}.csv"
    return Response(
        content=buffer.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


def _serialize_completion(c: TaskCompletion) -> Dict[str, Any]:
    return {
        "id": c.id,
        "task_id": c.task_id,
        "title": c.title,
        "tags": c.tags,
        "status": c.status or "completed",
        "completed_at": c.completed_at.isoformat() if c.completed_at else None,
        "due_date": c.due_date.isoformat() if c.due_date else None,
        "estimated_minutes": c.duration_minutes,
        "actual_minutes": c.actual_minutes,
        "lateness_minutes": _completion_lateness_minutes(c),
        "note": c.note,
        "work_sessions": _utc_session_list(json.loads(c.work_sessions_json)) if c.work_sessions_json else [],
    }


class CompletionSessionEdit(BaseModel):
    started_at: datetime.datetime
    ended_at: datetime.datetime
    notes: Optional[str] = None


class CompletionSessionsUpdate(BaseModel):
    sessions: List[CompletionSessionEdit]


@tasks_router.patch("/completions/{completion_id}/sessions")
async def update_completion_sessions(
    completion_id: int,
    body: CompletionSessionsUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Edit the recorded work-session intervals of a past completion.

    Each interval's start/stop is revalidated, per-session durations and the
    completion's total ``actual_minutes`` are recomputed, and ``completed_at``
    is set to the latest stop time. Intervals are stored separately, mirroring
    how live work sessions are tracked on the task."""
    c = (
        session.query(TaskCompletion)
        .filter(TaskCompletion.id == completion_id)
        .first()
    )
    if c is None:
        raise HTTPException(status_code=404, detail="Completion not found")
    _assert_can_write(c.project_id, user_id, session)

    now = datetime.datetime.utcnow()
    skew = datetime.timedelta(minutes=1)
    normalized: List[Dict[str, Any]] = []
    total = 0.0
    for s in body.sessions:
        started = _to_naive_utc(s.started_at)
        ended = _to_naive_utc(s.ended_at)
        if ended < started:
            raise HTTPException(status_code=422, detail="ended_at cannot be before started_at")
        if started > now + skew or ended > now + skew:
            raise HTTPException(status_code=422, detail="times cannot be in the future")
        duration = round((ended - started).total_seconds() / 60.0, 2)
        total += duration
        normalized.append({
            "started_at": started.isoformat(),
            "ended_at": ended.isoformat(),
            "duration_minutes": duration,
            "notes": s.notes or None,
        })

    if normalized:
        c.work_sessions_json = json.dumps(normalized)
        c.actual_minutes = round(total, 2)
        # The completion timestamp follows the latest stop time.
        c.completed_at = max(
            _to_naive_utc(s.ended_at) for s in body.sessions
        )
    else:
        c.work_sessions_json = None
        c.actual_minutes = None

    session.commit()
    return _serialize_completion(c)


# ── Tag endpoints (MUST be before /{id}) ──────────────────────────────────────

@tasks_router.get("/tags")
async def list_tags(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _assert_project_member(project_id, user_id, session)
    tags = session.query(Tag).filter(Tag.user_id == user_id).all()
    return [{"id": t.id, "name": t.name, "color": t.color} for t in tags]


@tasks_router.post("/tags")
async def create_tag(
    body: TagCreate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    existing = session.query(Tag).filter(Tag.user_id == user_id, Tag.name == body.name).first()
    if existing:
        raise HTTPException(status_code=400, detail="Tag with this name already exists")
    tag = Tag(user_id=user_id, name=body.name, color=body.color)
    session.add(tag)
    session.commit()
    session.refresh(tag)
    return {"id": tag.id, "name": tag.name, "color": tag.color}


@tasks_router.put("/tags/{tag_id}")
async def update_tag(
    tag_id: int,
    body: TagUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    tag = session.query(Tag).filter(Tag.id == tag_id, Tag.user_id == user_id).first()
    if not tag:
        raise HTTPException(status_code=404, detail="Tag not found")
    if body.name is not None:
        tag.name = body.name
    if body.color is not None:
        tag.color = body.color
    session.commit()
    return {"id": tag.id, "name": tag.name, "color": tag.color}


@tasks_router.delete("/tags/{tag_id}")
async def delete_tag(
    tag_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    tag = session.query(Tag).filter(Tag.id == tag_id, Tag.user_id == user_id).first()
    if not tag:
        raise HTTPException(status_code=404, detail="Tag not found")
    session.delete(tag)
    session.commit()
    return {"message": "Tag deleted"}


@tasks_router.post("/import-csv")
async def import_tasks_csv(
    project_id: int,
    file: UploadFile = File(...),
    dry_run: bool = False,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Import tasks from a CSV file (supports Org export-style columns)."""
    _assert_can_write(project_id, user_id, session)

    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")

    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = raw.decode("latin-1")

    reader = csv.DictReader(io.StringIO(text))
    if not reader.fieldnames:
        raise HTTPException(status_code=400, detail="CSV has no header row")

    tag_cache = {
        t.name.strip().lower(): t for t in session.query(Tag).filter(Tag.user_id == user_id).all()
    }
    title_to_task_id: Dict[str, int] = {
        t.title.strip().lower(): t.id
        for t in session.query(Task).filter(Task.project_id == project_id).all()
        if t.title and t.title.strip()
    }

    created = 0
    created_tags = 0
    skipped = 0
    errors: List[Dict[str, Any]] = []
    now = datetime.datetime.utcnow()
    done_tokens = {"done", "completed", "complete", "closed", "x", "yes", "true"}

    # In dry-run mode we never write to the database and emulate new rows locally.
    virtual_tag_names = set(tag_cache.keys())
    virtual_title_to_task_id = dict(title_to_task_id)
    virtual_next_id = -1

    for row_num, row in enumerate(reader, start=2):
        if not row or all(v is None or str(v).strip() == "" for v in row.values()):
            continue

        title = _csv_get(row, CSV_TITLE_ALIASES)
        if not title:
            skipped += 1
            errors.append({"row": row_num, "error": "Missing title/task column"})
            continue

        row_new_tags: List[tuple[str, Tag]] = []
        row_new_tag_count = 0
        try:
            due_raw = _csv_get(row, CSV_DUE_ALIASES)
            due_date = _parse_due_date(due_raw) if due_raw else None
            duration_minutes = _parse_duration_minutes(_csv_get(row, CSV_DURATION_ALIASES))
            description = _csv_get(row, CSV_DESC_ALIASES)
            parent_ref = _csv_get(row, CSV_PARENT_ALIASES)
            status_raw = (_csv_get(row, CSV_STATUS_ALIASES) or "").strip().lower()
            is_completed = status_raw in done_tokens or status_raw.startswith("done")

            if dry_run:
                for tag_name in _parse_tags(_csv_get(row, CSV_TAG_ALIASES)):
                    key = tag_name.lower()
                    if key not in virtual_tag_names:
                        virtual_tag_names.add(key)
                        row_new_tag_count += 1

                if parent_ref:
                    _ = virtual_title_to_task_id.get(parent_ref.strip().lower())

                created_tags += row_new_tag_count
                created += 1
                virtual_title_to_task_id.setdefault(title.strip().lower(), virtual_next_id)
                virtual_next_id -= 1
                continue

            tags = []
            for tag_name in _parse_tags(_csv_get(row, CSV_TAG_ALIASES)):
                key = tag_name.lower()
                tag = tag_cache.get(key)
                if tag is None:
                    tag = Tag(user_id=user_id, name=tag_name, color="#6366f1")
                    session.add(tag)
                    session.flush()
                    row_new_tags.append((key, tag))
                    row_new_tag_count += 1
                tags.append(tag)

            parent_task_id = None
            if parent_ref:
                parent_task_id = title_to_task_id.get(parent_ref.strip().lower())

            task = Task(
                user_id=user_id,
                project_id=project_id,
                title=title,
                description=description,
                due_date=due_date,
                duration_minutes=duration_minutes,
                parent_task_id=parent_task_id,
                is_completed=is_completed,
                completed_at=now if is_completed else None,
            )
            task.tags = tags
            session.add(task)
            session.flush()
            session.commit()

            for key, tag in row_new_tags:
                tag_cache[key] = tag
            created_tags += row_new_tag_count
            title_to_task_id.setdefault(title.strip().lower(), task.id)
            created += 1
        except Exception as exc:
            session.rollback()
            skipped += 1
            errors.append({"row": row_num, "title": title, "error": str(exc)})

    return {
        "filename": file.filename,
        "dry_run": dry_run,
        "created": created,
        "created_tags": created_tags,
        "skipped": skipped,
        "errors": errors[:50],
        "total_errors": len(errors),
    }


# ── Batch endpoints ────────────────────────────────────────────────────────────

class BatchDeleteBody(BaseModel):
    task_ids: List[int]
    project_id: int


class BatchUpdateBody(BaseModel):
    task_ids: List[int]
    project_id: int
    # Tags — send tag_ids (existing) and/or tag_names (new or existing by name;
    # resolved/created server-side).  Both lists are merged before applying.
    tag_ids: Optional[List[int]] = None
    tag_names: Optional[List[str]] = None  # names to find-or-create
    tag_mode: str = "overwrite"  # "overwrite" | "add"
    # Optional scalar fields (only applied when not None)
    due_date: Optional[str] = None
    duration_minutes: Optional[int] = None
    is_recurring: Optional[bool] = None
    recurrence_rule: Optional[str] = None


class BatchCompleteBody(BaseModel):
    task_ids: List[int]
    project_id: int
    status: str = "completed"  # "completed" | "skipped"
    note: Optional[str] = None


@tasks_router.post("/batch-delete")
async def batch_delete_tasks(
    body: BatchDeleteBody,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Delete multiple tasks at once. Only deletes tasks belonging to the
    specified project that the user has write access to."""
    _assert_can_write(body.project_id, user_id, session)
    if not body.task_ids:
        return {"deleted": 0, "task_ids": []}
    tasks = session.query(Task).filter(
        Task.id.in_(body.task_ids),
        Task.project_id == body.project_id,
    ).all()
    deleted_ids = [t.id for t in tasks]
    for t in tasks:
        session.delete(t)
    session.commit()
    return {"deleted": len(deleted_ids), "task_ids": deleted_ids}


@tasks_router.post("/batch-update")
async def batch_update_tasks(
    body: BatchUpdateBody,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Batch-edit a set of tasks. Each field is optional; only provided fields
    are changed. For tags, tag_mode controls whether the new list replaces
    (overwrite) or extends (add) the existing tags on each task."""
    _assert_can_write(body.project_id, user_id, session)
    if not body.task_ids:
        return {"updated": 0, "task_ids": []}

    tasks = session.query(Task).options(
        selectinload(Task.tags),
    ).filter(
        Task.id.in_(body.task_ids),
        Task.project_id == body.project_id,
    ).all()

    now = datetime.datetime.utcnow()

    # Resolve tags once for all tasks.
    # Merge explicit tag_ids with find-or-create tag_names.
    new_tags = None
    if body.tag_ids is not None or body.tag_names is not None:
        # Start from explicit IDs.
        resolved_ids: List[int] = list(body.tag_ids or [])
        # Find-or-create by name.
        if body.tag_names:
            existing_tags = {t.name.lower(): t for t in session.query(Tag).filter(Tag.user_id == user_id).all()}
            for raw in body.tag_names:
                name = raw.strip()
                if not name:
                    continue
                tag = existing_tags.get(name.lower())
                if tag is None:
                    tag = Tag(user_id=user_id, name=name, color="#6366f1")
                    session.add(tag)
                    session.flush()
                    existing_tags[name.lower()] = tag
                if tag.id not in resolved_ids:
                    resolved_ids.append(tag.id)
        new_tags = session.query(Tag).filter(Tag.id.in_(resolved_ids)).all() if resolved_ids else []

    # Parse due_date once.
    new_due: Optional[datetime.datetime] = None
    if body.due_date is not None:
        try:
            new_due = datetime.datetime.fromisoformat(body.due_date) if body.due_date else None
        except ValueError:
            raise HTTPException(status_code=422, detail="due_date must be ISO datetime string")

    for task in tasks:
        if new_tags is not None:
            if body.tag_mode == "add":
                existing_ids = {t.id for t in task.tags}
                task.tags = list(task.tags) + [t for t in new_tags if t.id not in existing_ids]
            else:  # overwrite
                task.tags = new_tags

        if body.due_date is not None:
            task.due_date = new_due
        if body.duration_minutes is not None:
            task.duration_minutes = body.duration_minutes
        if body.is_recurring is not None:
            task.is_recurring = body.is_recurring
        if body.recurrence_rule is not None:
            task.recurrence_rule = body.recurrence_rule
        task.updated_at = now

    session.commit()
    return {"updated": len(tasks), "task_ids": [t.id for t in tasks]}


@tasks_router.post("/batch-complete")
async def batch_complete_tasks(
    body: BatchCompleteBody,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Mark multiple tasks as completed or skipped in one request.

    Recurring tasks are advanced to their next due date (same as the single-task
    endpoint). Non-recurring tasks are simply marked completed/skipped."""
    _assert_can_write(body.project_id, user_id, session)
    if body.status not in ("completed", "skipped"):
        raise HTTPException(status_code=422, detail="status must be 'completed' or 'skipped'")
    if not body.task_ids:
        return {"processed": 0, "task_ids": []}

    tasks = session.query(Task).options(
        selectinload(Task.tags),
        selectinload(Task.work_sessions),
    ).filter(
        Task.id.in_(body.task_ids),
        Task.project_id == body.project_id,
        Task.is_completed.is_(False),
    ).all()

    now = datetime.datetime.utcnow()
    for task in tasks:
        _mark_task_done(task, user_id, session, now, status=body.status, note=body.note or None)
        task.updated_at = now

    session.commit()
    return {"processed": len(tasks), "task_ids": [t.id for t in tasks]}


# ── Individual task endpoints ──────────────────────────────────────────────────

@tasks_router.get("/{task_id}")
async def get_task(
    task_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    task = _load_task(task_id, user_id, session)
    return _serialize_task(task, datetime.datetime.utcnow())


@tasks_router.post("")
async def create_task(
    body: TaskCreate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _assert_can_write(body.project_id, user_id, session)
    due_date = None
    if body.due_date:
        try:
            due_date = datetime.datetime.fromisoformat(body.due_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="due_date must be ISO datetime")

    if body.parent_task_id:
        parent = session.query(Task).filter(
            Task.id == body.parent_task_id, Task.project_id == body.project_id
        ).first()
        if not parent:
            raise HTTPException(status_code=404, detail="Parent task not found")

    task = Task(
        user_id=user_id,
        project_id=body.project_id,
        title=body.title,
        description=body.description,
        due_date=due_date,
        duration_minutes=body.duration_minutes,
        parent_task_id=body.parent_task_id,
        is_recurring=body.is_recurring,
        recurrence_rule=body.recurrence_rule,
    )
    if body.tag_ids:
        tags = session.query(Tag).filter(Tag.id.in_(body.tag_ids), Tag.user_id == user_id).all()
        task.tags = tags

    session.add(task)
    session.commit()
    session.refresh(task)
    return _serialize_task(task, datetime.datetime.utcnow())


@tasks_router.put("/{task_id}")
async def update_task(
    task_id: int,
    body: TaskUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    task = _load_task(task_id, user_id, session)

    if body.title is not None:
        task.title = body.title
    if body.description is not None:
        task.description = body.description
    if body.due_date is not None:
        try:
            task.due_date = datetime.datetime.fromisoformat(body.due_date) if body.due_date else None
        except ValueError:
            raise HTTPException(status_code=422, detail="due_date must be ISO datetime")
    if body.duration_minutes is not None:
        task.duration_minutes = body.duration_minutes
    if body.parent_task_id is not None:
        task.parent_task_id = body.parent_task_id
    if body.is_recurring is not None:
        task.is_recurring = body.is_recurring
    if body.recurrence_rule is not None:
        task.recurrence_rule = body.recurrence_rule
    if body.tag_ids is not None:
        tags = session.query(Tag).filter(Tag.id.in_(body.tag_ids), Tag.user_id == user_id).all()
        task.tags = tags

    task.updated_at = datetime.datetime.utcnow()
    session.commit()
    return _serialize_task(task, datetime.datetime.utcnow())


@tasks_router.delete("/{task_id}")
async def delete_task(
    task_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    task = session.query(Task).filter(Task.id == task_id, Task.user_id == user_id).first()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    session.delete(task)
    session.commit()
    return {"message": "Task deleted"}


def _mark_task_done(
    task: Task,
    user_id: int,
    session: Session,
    now: datetime.datetime,
    status: str,
    note: Optional[str] = None,
    started_at: Optional[datetime.datetime] = None,
    ended_at: Optional[datetime.datetime] = None,
    advance_mode: Optional[str] = None,
):
    """Close the task (completed or skipped) and record an immutable history row.

    ``started_at`` / ``ended_at`` optionally override the work interval recorded
    for this completion (used by the completion dialog so the user can log a task
    as having been finished at some point in the past).  When supplied they
    adjust the active work session, or create a synthetic one if none was running.
    ``ended_at`` (when given) also becomes the effective completion timestamp.

    For recurring tasks the same task object is reset in-place with the next
    due date so only one Task row ever exists per recurring item.  ``advance_mode``
    controls how the deadline advances: "now" (default) jumps to the first
    iteration after the current moment, skipping missed ones; "stop" jumps to the
    first iteration after the selected stop time.  The chosen mode is persisted on
    the task.  The work sessions from the just-finished occurrence are deleted
    after their total duration has been captured in the TaskCompletion row.

    For non-recurring tasks the task is simply marked completed.
    """
    started_at = _to_naive_utc(started_at)
    ended_at = _to_naive_utc(ended_at)

    # The effective completion timestamp: the user-selected stop time if given,
    # otherwise the current moment.
    completion_time = ended_at or now

    # Reconcile the work interval for this completion.
    active = next((s for s in task.work_sessions if s.ended_at is None), None)
    if active:
        if started_at is not None:
            active.started_at = started_at
        active.ended_at = ended_at or now
    elif started_at is not None or ended_at is not None:
        # No session was running but the user supplied explicit times — record a
        # synthetic session so the actual duration reflects the logged interval.
        ws_start = started_at or ended_at or now
        ws_end = ended_at or now
        if ws_end > ws_start:
            new_ws = WorkSession(
                task_id=task.id,
                user_id=user_id,
                started_at=ws_start,
                ended_at=ws_end,
            )
            session.add(new_ws)
            task.work_sessions.append(new_ws)

    # Capture actual duration before we potentially delete sessions.
    actual = _actual_duration_minutes(task)

    # Snapshot every completed work session so history is permanent.
    sessions_snapshot = [
        {
            "started_at": ws.started_at.isoformat(),
            "ended_at": ws.ended_at.isoformat() if ws.ended_at else None,
            "duration_minutes": round(
                (ws.ended_at - ws.started_at).total_seconds() / 60.0, 2
            ) if ws.ended_at else None,
            "notes": ws.notes,
        }
        for ws in task.work_sessions
        if ws.ended_at is not None
    ]

    # Record an immutable completion-history row (survives future edits and
    # captures every individual recurrence occurrence).
    session.add(TaskCompletion(
        task_id=task.id,
        user_id=user_id,
        project_id=task.project_id,
        title=task.title,
        completed_at=completion_time,
        due_date=task.due_date,
        duration_minutes=task.duration_minutes,
        actual_minutes=actual,
        tags=", ".join(t.name for t in task.tags) if task.tags else None,
        status=status,
        note=note or None,
        work_sessions_json=json.dumps(sessions_snapshot) if sessions_snapshot else None,
    ))

    if task.is_recurring and task.recurrence_rule and task.due_date:
        # Persist the chosen advancement mode (default "now") so future
        # completions remember the user's preference.
        mode = advance_mode or task.recurrence_advance_mode or "now"
        if mode not in ("now", "stop"):
            mode = "now"
        task.recurrence_advance_mode = mode
        # "now": skip every missed iteration up to the present moment.
        # "stop": advance to the first iteration after the selected stop time.
        target = now if mode == "now" else completion_time
        # Reset the task in-place: advance the deadline and clear completion
        # state so it reappears in the todo list.
        task.due_date = _advance_due_date(task.due_date, task.recurrence_rule, target)
        task.is_completed = False
        task.completed_at = None
        # Delete work sessions from the finished occurrence — their total is
        # already captured in TaskCompletion.actual_minutes above.
        for ws in list(task.work_sessions):
            session.delete(ws)
    else:
        task.is_completed = True
        task.completed_at = completion_time


class CompleteBody(BaseModel):
    note: Optional[str] = None
    started_at: Optional[datetime.datetime] = None
    ended_at: Optional[datetime.datetime] = None
    recurrence_advance_mode: Optional[str] = None  # "now" | "stop"


def _validate_completion_times(
    started_at: Optional[datetime.datetime],
    ended_at: Optional[datetime.datetime],
    now: datetime.datetime,
) -> None:
    started = _to_naive_utc(started_at)
    ended = _to_naive_utc(ended_at)
    # Allow a small clock-skew tolerance for "now" submitted by clients.
    skew = datetime.timedelta(minutes=1)
    if started is not None and started > now + skew:
        raise HTTPException(status_code=422, detail="started_at cannot be in the future")
    if ended is not None and ended > now + skew:
        raise HTTPException(status_code=422, detail="ended_at cannot be in the future")
    if started is not None and ended is not None and ended < started:
        raise HTTPException(status_code=422, detail="ended_at cannot be before started_at")


@tasks_router.post("/{task_id}/complete")
async def toggle_complete(
    task_id: int,
    body: CompleteBody = CompleteBody(),
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    task = _load_task(task_id, user_id, session)
    now = datetime.datetime.utcnow()

    if task.is_completed:
        # Un-complete
        task.is_completed = False
        task.completed_at = None
    else:
        _validate_completion_times(body.started_at, body.ended_at, now)
        _mark_task_done(
            task, user_id, session, now,
            status="completed",
            note=body.note,
            started_at=body.started_at,
            ended_at=body.ended_at,
            advance_mode=body.recurrence_advance_mode,
        )

    task.updated_at = now
    session.commit()
    return _serialize_task(task, now)


@tasks_router.post("/{task_id}/skip")
async def skip_task(
    task_id: int,
    body: CompleteBody = CompleteBody(),
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Skip the current task instance: behaves like complete (advances a
    recurring task to its next occurrence) but is recorded as 'skipped'."""
    task = _load_task(task_id, user_id, session)
    now = datetime.datetime.utcnow()
    _validate_completion_times(body.started_at, body.ended_at, now)
    _mark_task_done(
        task, user_id, session, now,
        status="skipped",
        note=body.note,
        started_at=body.started_at,
        ended_at=body.ended_at,
        advance_mode=body.recurrence_advance_mode,
    )
    task.updated_at = now
    session.commit()
    return _serialize_task(task, now)


@tasks_router.post("/{task_id}/start")
async def start_session(
    task_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    task = _load_task(task_id, user_id, session)
    active = _active_session(task)
    if active:
        # Idempotent: a session may already be active (e.g. started on another
        # device). Adopt it rather than failing so every client converges.
        return {
            "message": "Work session already active",
            "session_id": active.id,
            "started_at": active.started_at.isoformat(),
        }

    ws = WorkSession(task_id=task.id, user_id=user_id, started_at=datetime.datetime.utcnow())
    session.add(ws)
    session.commit()
    return {"message": "Work session started", "session_id": ws.id, "started_at": ws.started_at.isoformat()}


@tasks_router.post("/{task_id}/session/restart")
async def restart_session(
    task_id: int,
    body: SessionRestart = SessionRestart(),
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Restart timekeeping for a task while keeping a session active.

    Modes:
      - "session": move the active session's start to now (keep prior history).
      - "task":    delete every work session and start fresh from now.
      - "custom":  set the active session's start to a user-supplied time.
    """
    task = _load_task(task_id, user_id, session)
    now = datetime.datetime.utcnow()
    active = _active_session(task)

    if body.mode == "task":
        for ws in list(task.work_sessions):
            session.delete(ws)
        active = WorkSession(task_id=task.id, user_id=user_id, started_at=now)
        session.add(active)
    elif body.mode == "custom":
        if body.started_at is None:
            raise HTTPException(status_code=422, detail="started_at is required for custom mode")
        started = body.started_at
        if started.tzinfo is not None:
            started = started.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        if started > now:
            raise HTTPException(status_code=422, detail="started_at cannot be in the future")
        if active is None:
            active = WorkSession(task_id=task.id, user_id=user_id, started_at=started)
            session.add(active)
        else:
            active.started_at = started
    elif body.mode == "session":
        if active is None:
            active = WorkSession(task_id=task.id, user_id=user_id, started_at=now)
            session.add(active)
        else:
            active.started_at = now
    else:
        raise HTTPException(status_code=422, detail=f"Unknown restart mode: {body.mode}")

    session.commit()
    return {
        "message": "Work session restarted",
        "session_id": active.id,
        "started_at": active.started_at.isoformat(),
    }



@tasks_router.post("/{task_id}/stop")
async def stop_session(
    task_id: int,
    body: SessionStop = SessionStop(),
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    task = _load_task(task_id, user_id, session)
    active = next((s for s in task.work_sessions if s.ended_at is None), None)
    if not active:
        raise HTTPException(status_code=404, detail="No active work session for this task")

    now = datetime.datetime.utcnow()
    active.ended_at = now
    active.notes = body.notes
    duration = (now - active.started_at).total_seconds() / 60.0
    session.commit()
    return {
        "message": "Work session stopped",
        "duration_minutes": round(duration, 2),
        "ended_at": now.isoformat(),
    }


def _serialize_work_session(s: "WorkSession", now: datetime.datetime) -> Dict[str, Any]:
    ended = s.ended_at
    duration = round(((ended or now) - s.started_at).total_seconds() / 60.0, 2)
    return {
        "id": s.id,
        "started_at": _utc_iso(s.started_at),
        "ended_at": _utc_iso(ended),
        "duration_minutes": duration,
        "active": ended is None,
        "notes": s.notes,
    }


class TaskSessionEdit(BaseModel):
    started_at: datetime.datetime
    ended_at: datetime.datetime
    notes: Optional[str] = None


class TaskSessionsUpdate(BaseModel):
    sessions: List[TaskSessionEdit]


@tasks_router.get("/{task_id}/sessions")
async def list_task_sessions(
    task_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Live work-session history for a task: every interval worked so far,
    including the currently-active one (``ended_at`` is null)."""
    task = _load_task(task_id, user_id, session)
    now = datetime.datetime.utcnow()
    rows = sorted(task.work_sessions, key=lambda s: s.started_at)
    return [_serialize_work_session(s, now) for s in rows]


@tasks_router.patch("/{task_id}/sessions")
async def update_task_sessions(
    task_id: int,
    body: TaskSessionsUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Replace a task's *completed* work-session intervals with the supplied
    list. Each interval is revalidated. The currently-active session (if any)
    is preserved untouched, so time can be edited without stopping the clock."""
    task = _load_task(task_id, user_id, session)
    _assert_can_write(task.project_id, user_id, session)

    now = datetime.datetime.utcnow()
    skew = datetime.timedelta(minutes=1)
    cleaned: List[tuple] = []
    for s in body.sessions:
        started = _to_naive_utc(s.started_at)
        ended = _to_naive_utc(s.ended_at)
        if ended < started:
            raise HTTPException(status_code=422, detail="ended_at cannot be before started_at")
        if started > now + skew or ended > now + skew:
            raise HTTPException(status_code=422, detail="times cannot be in the future")
        cleaned.append((started, ended, s.notes or None))

    # Drop existing completed sessions; keep the active one running.
    for ws in list(task.work_sessions):
        if ws.ended_at is not None:
            session.delete(ws)

    for started, ended, notes in cleaned:
        session.add(WorkSession(
            task_id=task.id,
            user_id=task.user_id,
            started_at=started,
            ended_at=ended,
            notes=notes,
        ))

    session.commit()
    session.refresh(task)
    rows = sorted(task.work_sessions, key=lambda s: s.started_at)
    return [_serialize_work_session(s, now) for s in rows]


# ── Plan endpoints ─────────────────────────────────────────────────────────────

class PlanCreate(BaseModel):
    project_id: int
    title: str
    content: str = ""


class PlanUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None


@plans_router.get("")
async def list_plans(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _assert_project_member(project_id, user_id, session)
    plans = session.query(Plan).filter(Plan.project_id == project_id).order_by(Plan.updated_at.desc()).all()
    return [
        {
            "id": p.id,
            "project_id": p.project_id,
            "title": p.title,
            "created_at": p.created_at.isoformat(),
            "updated_at": p.updated_at.isoformat() if p.updated_at else p.created_at.isoformat(),
        }
        for p in plans
    ]


@plans_router.post("")
async def create_plan(
    body: PlanCreate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _assert_can_write(body.project_id, user_id, session)
    plan = Plan(user_id=user_id, project_id=body.project_id, title=body.title, content=body.content)
    session.add(plan)
    session.commit()
    session.refresh(plan)
    return {"id": plan.id, "project_id": plan.project_id, "title": plan.title, "content": plan.content,
            "created_at": plan.created_at.isoformat(), "updated_at": plan.created_at.isoformat()}


@plans_router.get("/{plan_id}")
async def get_plan(
    plan_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    plan = session.query(Plan).filter(Plan.id == plan_id).first()
    if not plan:
        raise HTTPException(status_code=404, detail="Plan not found")
    _assert_project_member(plan.project_id, user_id, session)

    # Expand {{task:ID}} tokens → include task objects keyed by ID
    token_ids = [int(m.group(1)) for m in re.finditer(r"\{\{task:(\d+)\}\}", plan.content)]
    now = datetime.datetime.utcnow()
    task_map: Dict[str, Any] = {}
    for tid in set(token_ids):
        t = (
            session.query(Task)
            .filter(Task.id == tid, Task.project_id == plan.project_id)
            .options(selectinload(Task.tags), selectinload(Task.work_sessions))
            .first()
        )
        if t:
            task_map[str(tid)] = _serialize_task(t, now)

    return {
        "id": plan.id,
        "project_id": plan.project_id,
        "title": plan.title,
        "content": plan.content,
        "tasks": task_map,
        "created_at": plan.created_at.isoformat(),
        "updated_at": plan.updated_at.isoformat() if plan.updated_at else plan.created_at.isoformat(),
    }


@plans_router.put("/{plan_id}")
async def update_plan(
    plan_id: int,
    body: PlanUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    plan = session.query(Plan).filter(Plan.id == plan_id).first()
    if not plan:
        raise HTTPException(status_code=404, detail="Plan not found")
    _assert_can_write(plan.project_id, user_id, session)
    if body.title is not None:
        plan.title = body.title
    if body.content is not None and body.content != plan.content:
        old_lines = (plan.content or "").splitlines()
        new_lines = body.content.splitlines()
        diff_lines = list(difflib.unified_diff(
            old_lines, new_lines,
            fromfile="before", tofile="after",
            lineterm="",
        ))
        if diff_lines:
            session.add(PlanRevision(
                plan_id=plan.id,
                saved_by=user_id,
                saved_at=datetime.datetime.utcnow(),
                diff="\n".join(diff_lines),
            ))
        plan.content = body.content
    plan.updated_at = datetime.datetime.utcnow()
    session.commit()
    return {
        "id": plan.id,
        "project_id": plan.project_id,
        "title": plan.title,
        "updated_at": plan.updated_at.isoformat(),
    }


@plans_router.get("/{plan_id}/history")
async def get_plan_history(
    plan_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    plan = session.query(Plan).filter(Plan.id == plan_id).first()
    if not plan:
        raise HTTPException(status_code=404, detail="Plan not found")
    _assert_project_member(plan.project_id, user_id, session)
    revisions = (
        session.query(PlanRevision)
        .filter(PlanRevision.plan_id == plan_id)
        .order_by(PlanRevision.saved_at.desc())
        .all()
    )
    return [
        {
            "id": r.id,
            "saved_at": r.saved_at.isoformat(),
            "saved_by": r.saved_by,
            "diff": r.diff,
        }
        for r in revisions
    ]


@plans_router.delete("/{plan_id}")
async def delete_plan(
    plan_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    plan = session.query(Plan).filter(Plan.id == plan_id).first()
    if not plan:
        raise HTTPException(status_code=404, detail="Plan not found")
    _assert_can_write(plan.project_id, user_id, session)
    session.delete(plan)
    session.commit()
    return {"message": "Plan deleted"}
