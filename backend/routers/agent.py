"""
Agent chat scaffold with project-scoped guardrails.

This router is provider-agnostic and can call any OpenAI-compatible endpoint.
"""

import datetime
import json
import os
from typing import Any, Dict, List, Literal, Optional
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session, selectinload
from starlette.config import Config

from database import (
    get_session,
    LLMConversation,
    Plan,
    ProjectMembership,
    Tag,
    Task,
)
from dependencies import get_current_user_id

router = APIRouter(prefix="/agent", tags=["agent"])
_config = Config('.env')


def _env_value(name: str, default: Optional[str] = None) -> Optional[str]:
    value = os.environ.get(name)
    if value is not None and value != "":
        return value
    return _config.get(name, default=default)


def _is_local_base_url(base_url: str) -> bool:
    try:
        parsed = urlparse(base_url)
        host = (parsed.hostname or "").lower()
        return host in {"localhost", "127.0.0.1", "::1"}
    except Exception:
        return False


def _llm_runtime_config() -> tuple[str, str, Optional[str], float]:
    base_url = _env_value("LLM_API_BASE_URL") or _env_value("OPENAI_API_BASE_URL") or "https://api.openai.com/v1"
    model = _env_value("LLM_MODEL", "gpt-4o-mini") or "gpt-4o-mini"
    api_key = _env_value("LLM_API_KEY") or _env_value("OPENAI_API_KEY")
    timeout_sec = float(_env_value("LLM_TIMEOUT_SECONDS", "40") or "40")
    return base_url, model, api_key, timeout_sec


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class AgentChatRequest(BaseModel):
    mode: Literal["planning", "analytics"]
    project_id: int
    messages: List[ChatMessage]
    plan_id: Optional[int] = None
    require_approval: bool = False


class PlanningToolCall(BaseModel):
    name: str
    args: Dict[str, Any] = {}


class ApplyPlanningActionsRequest(BaseModel):
    project_id: int
    plan_id: Optional[int] = None
    tool_calls: List[PlanningToolCall]


def _assert_project_member(project_id: int, user_id: int, session: Session):
    membership = session.query(ProjectMembership).filter(
        ProjectMembership.project_id == project_id,
        ProjectMembership.user_id == user_id,
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member of this project")
    return membership


def _assert_can_write_project(project_id: int, user_id: int, session: Session):
    membership = _assert_project_member(project_id, user_id, session)
    if membership.role == "viewer":
        raise HTTPException(status_code=403, detail="Viewer role cannot modify tasks/plans")
    return membership


def _serialize_task_brief(task: Task) -> Dict[str, Optional[str]]:
    return {
        "id": task.id,
        "title": task.title,
        "due_date": task.due_date.isoformat() if task.due_date else None,
        "duration_minutes": task.duration_minutes,
        "is_completed": task.is_completed,
        "parent_task_id": task.parent_task_id,
        "tags": [t.name for t in task.tags],
    }


def _build_project_context(
    *,
    mode: str,
    user_id: int,
    project_id: int,
    plan_id: Optional[int],
    session: Session,
) -> Dict[str, object]:
    if mode == "planning":
        tasks = (
            session.query(Task)
            .filter(Task.project_id == project_id)
            .options(selectinload(Task.tags))
            .order_by(Task.updated_at.desc())
            .limit(30)
            .all()
        )

        plans_query = session.query(Plan).filter(Plan.project_id == project_id)
        if plan_id is not None:
            plans_query = plans_query.filter(Plan.id == plan_id)
        plans = plans_query.order_by(Plan.updated_at.desc()).limit(10).all()

        return {
            "mode": "planning",
            "project_id": project_id,
            "tasks": [_serialize_task_brief(t) for t in tasks],
            "plans": [
                {
                    "id": p.id,
                    "title": p.title,
                    "content": p.content[:3000],
                    "updated_at": p.updated_at.isoformat() if p.updated_at else p.created_at.isoformat(),
                }
                for p in plans
            ],
        }

    completed = (
        session.query(Task)
        .filter(
            Task.project_id == project_id,
            Task.is_completed.is_(True),
            Task.completed_at.isnot(None),
        )
        .options(selectinload(Task.work_sessions), selectinload(Task.tags))
        .order_by(Task.completed_at.desc())
        .limit(300)
        .all()
    )

    ratios = []
    on_time = 0
    with_due = 0
    by_tag: Dict[str, Dict[str, float]] = {}

    for t in completed:
        actual_minutes = 0.0
        for s in t.work_sessions:
            if s.ended_at is None:
                continue
            actual_minutes += (s.ended_at - s.started_at).total_seconds() / 60.0

        if t.duration_minutes and t.duration_minutes > 0 and actual_minutes > 0:
            ratios.append(actual_minutes / t.duration_minutes)

        if t.due_date is not None:
            with_due += 1
            if t.completed_at <= t.due_date:
                on_time += 1

        for tag in t.tags:
            bucket = by_tag.setdefault(tag.name, {"count": 0, "late_count": 0})
            bucket["count"] += 1
            if t.due_date is not None and t.completed_at > t.due_date:
                bucket["late_count"] += 1

    return {
        "mode": "analytics",
        "project_id": project_id,
        "completed_task_count": len(completed),
        "avg_actual_over_estimate": (sum(ratios) / len(ratios)) if ratios else None,
        "on_time_rate": (on_time / with_due) if with_due else None,
        "tags": by_tag,
        "recent_completed": [_serialize_task_brief(t) for t in completed[:40]],
    }


def _build_system_prompt(mode: str, project_id: int) -> str:
    return (
        "You are a project-scoped assistant for a task management app. "
        f"Only reason about project_id={project_id}. "
        "Never suggest actions that read or modify data outside this project. "
        f"Current mode is '{mode}'. Keep answers concise and practical."
    )


async def _call_llm(messages: List[Dict[str, str]], model: str) -> str:
    base_url, resolved_model, api_key, timeout_sec = _llm_runtime_config()
    model = model or resolved_model

    if not api_key and not _is_local_base_url(base_url):
        return (
            "LLM scaffold is active, but no API key is configured. "
            "Set LLM_API_KEY (or OPENAI_API_KEY), LLM_API_BASE_URL, and LLM_MODEL to enable live inference."
        )

    payload = {
        "model": model,
        "messages": messages,
        "temperature": 0.2,
    }

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        resp = await client.post(f"{base_url.rstrip('/')}/chat/completions", headers=headers, json=payload)
    if resp.status_code >= 400:
        detail = resp.text[:500]
        raise HTTPException(status_code=502, detail=f"LLM provider error: {resp.status_code} {detail}")

    data = resp.json()
    try:
        return data["choices"][0]["message"]["content"]
    except Exception:
        raise HTTPException(status_code=502, detail="LLM response shape was invalid")


async def _call_llm_message(
    *,
    messages: List[Dict[str, Any]],
    model: str,
    tools: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    base_url, resolved_model, api_key, timeout_sec = _llm_runtime_config()
    model = model or resolved_model

    if not api_key and not _is_local_base_url(base_url):
        return {
            "role": "assistant",
            "content": (
                "LLM scaffold is active, but no API key is configured. "
                "Set LLM_API_KEY (or OPENAI_API_KEY), LLM_API_BASE_URL, and LLM_MODEL to enable live inference."
            ),
        }

    payload: Dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": 0.2,
    }
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        resp = await client.post(f"{base_url.rstrip('/')}/chat/completions", headers=headers, json=payload)
    if resp.status_code >= 400:
        detail = resp.text[:500]
        raise HTTPException(status_code=502, detail=f"LLM provider error: {resp.status_code} {detail}")

    data = resp.json()
    try:
        return data["choices"][0]["message"]
    except Exception:
        raise HTTPException(status_code=502, detail="LLM response shape was invalid")


def _parse_iso_datetime(value: Optional[str]) -> Optional[datetime.datetime]:
    if not value:
        return None
    normalized = value.strip().replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(normalized)


def _planning_tools_schema() -> List[Dict[str, Any]]:
    return [
        {
            "type": "function",
            "function": {
                "name": "create_task",
                "description": "Create a task in the current project.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string"},
                        "description": {"type": "string"},
                        "due_date": {"type": "string", "description": "ISO datetime"},
                        "duration_minutes": {"type": "integer"},
                        "parent_task_id": {"type": "integer"},
                        "is_recurring": {"type": "boolean"},
                        "recurrence_rule": {"type": "string", "enum": ["DAILY", "WEEKLY", "MONTHLY"]},
                        "tags": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                    },
                    "required": ["title"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "update_task",
                "description": "Update an existing task in the current project.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "task_id": {"type": "integer"},
                        "title": {"type": "string"},
                        "description": {"type": "string"},
                        "due_date": {"type": "string", "description": "ISO datetime"},
                        "duration_minutes": {"type": "integer"},
                        "parent_task_id": {"type": "integer"},
                        "is_recurring": {"type": "boolean"},
                        "recurrence_rule": {"type": "string", "enum": ["DAILY", "WEEKLY", "MONTHLY"]},
                        "is_completed": {"type": "boolean"},
                        "tags": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                    },
                    "required": ["task_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "write_plan",
                "description": "Replace or append plan markdown content.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "plan_id": {"type": "integer"},
                        "content": {"type": "string"},
                        "append": {"type": "boolean"},
                        "title": {"type": "string"},
                    },
                    "required": ["content"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "create_plan",
                "description": "Create a new plan in the current project.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string"},
                        "content": {"type": "string"},
                    },
                    "required": ["title"],
                },
            },
        },
    ]


def _ensure_tag_ids(
    *,
    user_id: int,
    tag_names: List[str],
    session: Session,
) -> List[int]:
    if not tag_names:
        return []
    normalized = [t.strip() for t in tag_names if t and t.strip()]
    if not normalized:
        return []

    existing = session.query(Tag).filter(Tag.user_id == user_id).all()
    by_name = {t.name.lower(): t for t in existing}
    ids: List[int] = []
    for raw in normalized:
        key = raw.lower()
        tag = by_name.get(key)
        if tag is None:
            tag = Tag(user_id=user_id, name=raw, color="#6366f1")
            session.add(tag)
            session.flush()
            by_name[key] = tag
        ids.append(tag.id)
    return ids


def _execute_planning_tool_call(
    *,
    name: str,
    args: Dict[str, Any],
    project_id: int,
    default_plan_id: Optional[int],
    user_id: int,
    session: Session,
    dry_run: bool = False,
) -> Dict[str, Any]:
    _assert_can_write_project(project_id, user_id, session)

    if name == "create_task":
        title = str(args.get("title", "")).strip()
        if not title:
            raise HTTPException(status_code=400, detail="create_task requires title")

        if dry_run:
            return {
                "ok": True,
                "action": "create_task",
                "dry_run": True,
                "title": title,
                "due_date": args.get("due_date"),
                "duration_minutes": args.get("duration_minutes"),
            }

        task = Task(
            user_id=user_id,
            project_id=project_id,
            title=title,
            description=args.get("description"),
            due_date=_parse_iso_datetime(args.get("due_date")),
            duration_minutes=args.get("duration_minutes"),
            parent_task_id=args.get("parent_task_id"),
            is_recurring=bool(args.get("is_recurring", False)),
            recurrence_rule=args.get("recurrence_rule"),
        )

        tag_ids = _ensure_tag_ids(
            user_id=user_id,
            tag_names=[str(t) for t in args.get("tags", [])],
            session=session,
        )
        if tag_ids:
            task.tags = session.query(Tag).filter(Tag.id.in_(tag_ids)).all()

        session.add(task)
        session.commit()
        session.refresh(task)
        return {"ok": True, "action": "create_task", "task_id": task.id, "title": task.title}

    if name == "update_task":
        task_id = args.get("task_id")
        if not isinstance(task_id, int):
            raise HTTPException(status_code=400, detail="update_task requires integer task_id")
        task = session.query(Task).filter(Task.id == task_id, Task.project_id == project_id).first()
        if not task:
            raise HTTPException(status_code=404, detail="Task not found in this project")

        if dry_run:
            return {
                "ok": True,
                "action": "update_task",
                "dry_run": True,
                "task_id": task.id,
                "fields": sorted(list(args.keys())),
            }

        if "title" in args:
            task.title = str(args.get("title") or "").strip() or task.title
        if "description" in args:
            task.description = args.get("description")
        if "due_date" in args:
            task.due_date = _parse_iso_datetime(args.get("due_date"))
        if "duration_minutes" in args:
            task.duration_minutes = args.get("duration_minutes")
        if "parent_task_id" in args:
            task.parent_task_id = args.get("parent_task_id")
        if "is_recurring" in args:
            task.is_recurring = bool(args.get("is_recurring"))
        if "recurrence_rule" in args:
            task.recurrence_rule = args.get("recurrence_rule")
        if "is_completed" in args:
            is_completed = bool(args.get("is_completed"))
            task.is_completed = is_completed
            task.completed_at = datetime.datetime.utcnow() if is_completed else None
        if "tags" in args:
            tag_ids = _ensure_tag_ids(
                user_id=user_id,
                tag_names=[str(t) for t in args.get("tags", [])],
                session=session,
            )
            task.tags = session.query(Tag).filter(Tag.id.in_(tag_ids)).all() if tag_ids else []

        task.updated_at = datetime.datetime.utcnow()
        session.commit()
        return {"ok": True, "action": "update_task", "task_id": task.id, "title": task.title}

    if name == "write_plan":
        plan_id = args.get("plan_id") if isinstance(args.get("plan_id"), int) else default_plan_id
        if plan_id is None:
            raise HTTPException(status_code=400, detail="write_plan requires plan_id when no default plan is selected")

        plan = session.query(Plan).filter(Plan.id == plan_id, Plan.project_id == project_id).first()
        if not plan:
            raise HTTPException(status_code=404, detail="Plan not found in this project")

        content = str(args.get("content") or "")
        if not content:
            raise HTTPException(status_code=400, detail="write_plan requires non-empty content")

        append = bool(args.get("append", False))
        if dry_run:
            return {
                "ok": True,
                "action": "write_plan",
                "dry_run": True,
                "plan_id": plan.id,
                "append": append,
                "title": plan.title,
            }

        plan.content = f"{plan.content.rstrip()}\n\n{content}" if append and plan.content else content
        if "title" in args and args.get("title"):
            plan.title = str(args.get("title"))
        plan.updated_at = datetime.datetime.utcnow()
        session.commit()
        return {"ok": True, "action": "write_plan", "plan_id": plan.id, "title": plan.title}

    if name == "create_plan":
        title = str(args.get("title", "")).strip()
        if not title:
            raise HTTPException(status_code=400, detail="create_plan requires title")
        content = str(args.get("content") or "")
        if dry_run:
            return {
                "ok": True,
                "action": "create_plan",
                "dry_run": True,
                "title": title,
            }

        plan = Plan(user_id=user_id, project_id=project_id, title=title, content=content)
        session.add(plan)
        session.commit()
        session.refresh(plan)
        return {"ok": True, "action": "create_plan", "plan_id": plan.id, "title": plan.title}

    raise HTTPException(status_code=400, detail=f"Unsupported tool: {name}")


@router.post("/chat")
async def agent_chat(
    body: AgentChatRequest,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _assert_project_member(body.project_id, user_id, session)

    if body.plan_id is not None:
        plan = session.query(Plan).filter(Plan.id == body.plan_id).first()
        if not plan or plan.project_id != body.project_id:
            raise HTTPException(status_code=400, detail="plan_id does not belong to this project")

    context_payload = _build_project_context(
        mode=body.mode,
        user_id=user_id,
        project_id=body.project_id,
        plan_id=body.plan_id,
        session=session,
    )

    _, model, _, _ = _llm_runtime_config()

    llm_messages: List[Dict[str, Any]] = [
        {
            "role": "system",
            "content": _build_system_prompt(body.mode, body.project_id)
            + (
                " In planning mode, be agentic: when user asks to add/edit tasks or rewrite plan, use tool calls."
                if body.mode == "planning"
                else ""
            ),
        },
        {
            "role": "system",
            "content": "Project-scoped context JSON (do not expose raw unless asked):\n"
            + json.dumps(context_payload, ensure_ascii=True),
        },
    ]
    llm_messages.extend([m.model_dump() for m in body.messages])

    tool_defs = _planning_tools_schema() if body.mode == "planning" else None
    executed_actions: List[Dict[str, Any]] = []
    proposed_tool_calls: List[Dict[str, Any]] = []
    reply: Optional[str] = None

    for _ in range(6):
        ai_msg = await _call_llm_message(messages=llm_messages, model=model, tools=tool_defs)
        tool_calls = ai_msg.get("tool_calls") if isinstance(ai_msg, dict) else None

        if tool_calls:
            llm_messages.append(
                {
                    "role": "assistant",
                    "content": ai_msg.get("content") or "",
                    "tool_calls": tool_calls,
                }
            )

            for tool_call in tool_calls:
                fn = tool_call.get("function", {})
                tool_name = fn.get("name")
                raw_args = fn.get("arguments") or "{}"
                try:
                    parsed_args = json.loads(raw_args)
                    if not isinstance(parsed_args, dict):
                        raise ValueError("Tool arguments must be a JSON object")

                    if body.mode == "planning" and body.require_approval:
                        proposed_tool_calls.append({"name": tool_name, "args": parsed_args})

                    result = _execute_planning_tool_call(
                        name=tool_name,
                        args=parsed_args,
                        project_id=body.project_id,
                        default_plan_id=body.plan_id,
                        user_id=user_id,
                        session=session,
                        dry_run=(body.mode == "planning" and body.require_approval),
                    )
                except Exception as exc:
                    result = {"ok": False, "action": tool_name, "error": str(exc)}

                executed_actions.append(result)
                llm_messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tool_call.get("id"),
                        "content": json.dumps(result, ensure_ascii=True),
                    }
                )
            continue

        reply = ai_msg.get("content") if isinstance(ai_msg, dict) else None
        if reply is None:
            reply = ""
        break

    if reply is None:
        reply = "I completed the requested actions, but did not produce a final response."

    history = [m.model_dump() for m in body.messages]
    history.append({"role": "assistant", "content": reply})

    convo = LLMConversation(
        user_id=user_id,
        mode=body.mode,
        related_plan_id=body.plan_id,
        messages=json.dumps(history, ensure_ascii=True),
        created_at=datetime.datetime.utcnow(),
        updated_at=datetime.datetime.utcnow(),
    )
    session.add(convo)
    session.commit()

    return {
        "reply": reply,
        "mode": body.mode,
        "project_id": body.project_id,
        "model": model,
        "actions": executed_actions,
        "pending_approval": body.mode == "planning" and body.require_approval and len(proposed_tool_calls) > 0,
        "proposed_tool_calls": proposed_tool_calls,
        "context_summary": {
            "tasks_considered": len(context_payload.get("tasks", [])) if isinstance(context_payload, dict) else 0,
            "plans_considered": len(context_payload.get("plans", [])) if isinstance(context_payload, dict) else 0,
            "completed_tasks_considered": context_payload.get("completed_task_count") if isinstance(context_payload, dict) else 0,
        },
        "conversation_id": convo.id,
    }


@router.post("/planning/apply-actions")
async def apply_planning_actions(
    body: ApplyPlanningActionsRequest,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _assert_can_write_project(body.project_id, user_id, session)

    if body.plan_id is not None:
        plan = session.query(Plan).filter(Plan.id == body.plan_id).first()
        if not plan or plan.project_id != body.project_id:
            raise HTTPException(status_code=400, detail="plan_id does not belong to this project")

    actions: List[Dict[str, Any]] = []
    for tc in body.tool_calls:
        try:
            result = _execute_planning_tool_call(
                name=tc.name,
                args=tc.args,
                project_id=body.project_id,
                default_plan_id=body.plan_id,
                user_id=user_id,
                session=session,
                dry_run=False,
            )
        except Exception as exc:
            result = {"ok": False, "action": tc.name, "error": str(exc)}
        actions.append(result)

    return {
        "applied": sum(1 for a in actions if a.get("ok") is True),
        "failed": sum(1 for a in actions if a.get("ok") is not True),
        "actions": actions,
    }
