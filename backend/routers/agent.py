"""
Agent chat scaffold with project-scoped guardrails.

This router is provider-agnostic and can call any OpenAI-compatible endpoint.
"""

from __future__ import annotations

import asyncio
import datetime
import json
import os
import re
from typing import Any, Dict, List, Literal, Optional
from urllib.parse import urlparse

import base64
import binascii
import hashlib
import httpx
from cryptography.fernet import Fernet, InvalidToken


async def _llm_post(
    client: httpx.AsyncClient,
    url: str,
    *,
    headers: Dict[str, str],
    payload: Dict[str, Any],
    max_retries: int = 2,
) -> httpx.Response:
    """POST to the LLM endpoint, honouring 429 Retry-After up to max_retries times."""
    for attempt in range(max_retries + 1):
        resp = await client.post(url, headers=headers, json=payload)
        if resp.status_code != 429 or attempt == max_retries:
            return resp
        # Parse retry delay from header or response body.
        retry_after: float = 15.0  # safe default
        if ra := resp.headers.get("retry-after"):
            try:
                retry_after = float(ra)
            except ValueError:
                pass
        else:
            try:
                body = resp.json()
                msg = body.get("error", {}).get("message", "")
                m = re.search(r"(\d+(?:\.\d+))s", msg)
                if m:
                    retry_after = float(m.group(1))
            except Exception:
                pass
        # Cap wait to 60s so we never block a request indefinitely.
        await asyncio.sleep(min(retry_after + 0.5, 60.0))
    return resp  # unreachable, but satisfies type checker
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session, selectinload
from starlette.config import Config

from database import (
    get_session,
    LLMConversation,
    LLMUsage,
    Plan,
    ProjectMembership,
    Tag,
    Task,
    User,
)
from dependencies import get_current_user_id
from auth import SECRET_KEY

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
    timeout_sec = float(_env_value("LLM_TIMEOUT_SECONDS", "120") or "120")
    return base_url, model, api_key, timeout_sec


# ── Per-user BYO-key encryption (Fernet, derived from SECRET_KEY) ─────────────
# NOTE: SECRET_KEY must be set as a stable env var in production. If it changes
# (e.g. a random default on each restart), previously stored keys can no longer
# be decrypted and users must re-enter them.
def _fernet() -> Fernet:
    digest = hashlib.sha256(SECRET_KEY.encode("utf-8")).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def _encrypt_secret(plaintext: str) -> str:
    return _fernet().encrypt(plaintext.encode("utf-8")).decode("ascii")


def _decrypt_secret(token: str) -> Optional[str]:
    try:
        return _fernet().decrypt(token.encode("ascii")).decode("utf-8")
    except (InvalidToken, ValueError, TypeError):
        return None


def _resolve_runtime_for_user(user: Optional[User]) -> tuple[str, str, Optional[str], float, bool]:
    """Resolve (base_url, model, api_key, timeout, using_user_key).

    A user's own key/base_url/model override the server defaults. When the user
    supplies their own key, they pay their own provider, so the shared spend cap
    does not apply (using_user_key=True).
    """
    base_url, model, api_key, timeout_sec = _llm_runtime_config()
    using_user_key = False
    if user is not None and user.llm_api_key_encrypted:
        user_key = _decrypt_secret(user.llm_api_key_encrypted)
        if user_key:
            api_key = user_key
            using_user_key = True
            if user.llm_api_base_url:
                base_url = user.llm_api_base_url
            if user.llm_model:
                model = user.llm_model
    return base_url, model, api_key, timeout_sec, using_user_key


# Approximate pay-per-use pricing (USD per 1M tokens): (input, output).
# Used only to enforce the spending cap; refine if you switch models/providers.
_MODEL_PRICING_PER_1M: Dict[str, tuple[float, float]] = {
    "gpt-4o-mini": (0.15, 0.60),
    "gpt-4o": (2.50, 10.00),
    "gpt-4.1-mini": (0.40, 1.60),
    "gpt-4.1": (2.00, 8.00),
    "o4-mini": (1.10, 4.40),
}


def _spend_cap_usd() -> float:
    try:
        return float(_env_value("LLM_SPEND_CAP_USD", "10") or "10")
    except (TypeError, ValueError):
        return 10.0


def _estimate_cost_usd(model: str, prompt_tokens: int, completion_tokens: int) -> float:
    inp, out = _MODEL_PRICING_PER_1M.get((model or "").lower(), _MODEL_PRICING_PER_1M["gpt-4o-mini"])
    return (prompt_tokens / 1_000_000.0) * inp + (completion_tokens / 1_000_000.0) * out


def _total_spend_usd(session: Session) -> float:
    total = session.query(func.coalesce(func.sum(LLMUsage.cost_usd), 0.0)).scalar()
    return float(total or 0.0)


# ── Attachment handling (text extraction with a vision fallback) ──────────────
# The agent reads attached files by extracting text first; for scanned/image
# PDFs (little or no extractable text) it rasterizes pages and sends them as
# images to a vision-capable model.
_MAX_ATTACHMENTS = 5
_MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024  # 10 MB per file
_MAX_EXTRACTED_CHARS = 30_000  # cap injected text per file to bound token cost
_MAX_VISION_PAGES = 5  # render at most this many PDF pages when falling back
_MIN_PDF_TEXT_CHARS = 200  # below this, treat a PDF as scanned -> vision path

_TEXT_EXTENSIONS = {".txt", ".md", ".markdown", ".csv", ".json", ".log", ".yaml", ".yml", ".tsv"}
_IMAGE_MIME_BY_EXT = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
}


def _model_supports_vision(model: str) -> bool:
    m = (model or "").lower()
    return any(tok in m for tok in ("gpt-4o", "gpt-4.1", "o4", "o3", "vision"))


def _decode_attachment_bytes(data_base64: str) -> bytes:
    raw = data_base64 or ""
    if raw.startswith("data:") and "," in raw:
        raw = raw.split(",", 1)[1]
    return base64.b64decode(raw, validate=False)


def _ext_of(filename: str) -> str:
    name = (filename or "").lower()
    dot = name.rfind(".")
    return name[dot:] if dot != -1 else ""


def _process_attachments(
    attachments: List[ChatAttachment], model: str
) -> tuple[List[Dict[str, Any]], List[str]]:
    """Turn uploaded files into OpenAI chat content parts.

    Returns (content_parts, notes). content_parts is a list of text and/or
    image_url parts to append as a user message; notes are human-readable
    status lines (e.g. skipped/too large) surfaced back to the client.
    """
    content_parts: List[Dict[str, Any]] = []
    notes: List[str] = []
    vision_ok = _model_supports_vision(model)

    for att in attachments[:_MAX_ATTACHMENTS]:
        name = att.filename or "attachment"
        try:
            data = _decode_attachment_bytes(att.data_base64)
        except (binascii.Error, ValueError):
            notes.append(f"{name}: could not decode (invalid data).")
            continue

        if not data:
            notes.append(f"{name}: empty file, skipped.")
            continue
        if len(data) > _MAX_ATTACHMENT_BYTES:
            notes.append(f"{name}: too large ({len(data) // (1024 * 1024)} MB), skipped (max 10 MB).")
            continue

        ext = _ext_of(name)
        mime = (att.mime_type or "").lower()
        is_image = mime.startswith("image/") or ext in _IMAGE_MIME_BY_EXT
        is_pdf = mime == "application/pdf" or ext == ".pdf"
        is_text = mime.startswith("text/") or ext in _TEXT_EXTENSIONS

        if is_image:
            if not vision_ok:
                notes.append(f"{name}: image skipped (configured model has no vision support).")
                continue
            img_mime = mime if mime.startswith("image/") else _IMAGE_MIME_BY_EXT.get(ext, "image/png")
            b64 = base64.b64encode(data).decode("ascii")
            content_parts.append({"type": "text", "text": f"Attached image: {name}"})
            content_parts.append(
                {"type": "image_url", "image_url": {"url": f"data:{img_mime};base64,{b64}"}}
            )
            continue

        if is_pdf:
            parts, note = _process_pdf(name, data, vision_ok)
            content_parts.extend(parts)
            if note:
                notes.append(note)
            continue

        if is_text:
            try:
                text = data.decode("utf-8", errors="replace")
            except Exception:
                notes.append(f"{name}: could not read as text, skipped.")
                continue
            text = text[:_MAX_EXTRACTED_CHARS]
            content_parts.append(
                {"type": "text", "text": f"Attached file {name}:\n```\n{text}\n```"}
            )
            continue

        notes.append(f"{name}: unsupported file type, skipped.")

    return content_parts, notes


def _process_pdf(name: str, data: bytes, vision_ok: bool) -> tuple[List[Dict[str, Any]], Optional[str]]:
    try:
        import fitz  # PyMuPDF
    except Exception:
        return [], f"{name}: PDF support unavailable (PyMuPDF not installed)."

    try:
        doc = fitz.open(stream=data, filetype="pdf")
    except Exception:
        return [], f"{name}: could not open PDF, skipped."

    try:
        text_chunks: List[str] = []
        for page in doc:
            text_chunks.append(page.get_text("text"))
        extracted = "\n".join(text_chunks).strip()

        if len(extracted) >= _MIN_PDF_TEXT_CHARS:
            extracted = extracted[:_MAX_EXTRACTED_CHARS]
            return (
                [{"type": "text", "text": f"Attached PDF {name} (extracted text):\n```\n{extracted}\n```"}],
                None,
            )

        # Scanned / image-only PDF -> vision fallback.
        if not vision_ok:
            return [], f"{name}: appears scanned and the configured model has no vision support."

        parts: List[Dict[str, Any]] = [
            {"type": "text", "text": f"Attached PDF {name} appears scanned; showing page images:"}
        ]
        rendered = 0
        for page in doc:
            if rendered >= _MAX_VISION_PAGES:
                break
            pix = page.get_pixmap(dpi=150)
            png = pix.tobytes("png")
            b64 = base64.b64encode(png).decode("ascii")
            parts.append(
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}}
            )
            rendered += 1
        note = None
        if doc.page_count > rendered:
            note = f"{name}: only first {rendered} of {doc.page_count} pages sent (vision limit)."
        return parts, note
    finally:
        doc.close()



class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class ChatAttachment(BaseModel):
    filename: str
    mime_type: Optional[str] = None
    # Raw file bytes, base64-encoded (a "data:...;base64," prefix is tolerated).
    data_base64: str


class AgentChatRequest(BaseModel):
    mode: Literal["planning", "analytics", "todo"]
    project_id: int
    messages: List[ChatMessage]
    plan_id: Optional[int] = None
    require_approval: bool = False
    attachments: List[ChatAttachment] = []


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
    if mode in ("planning", "todo"):
        tasks = (
            session.query(Task)
            .filter(Task.project_id == project_id)
            .options(selectinload(Task.tags))
            .order_by(Task.updated_at.desc())
            .limit(150)
            .all()
        )

        plans_query = session.query(Plan).filter(Plan.project_id == project_id)
        if plan_id is not None:
            plans_query = plans_query.filter(Plan.id == plan_id)
        plans = plans_query.order_by(Plan.updated_at.desc()).limit(10).all()

        # When a specific plan is open, list the OTHER plans in this project
        # (id + title only) so the agent knows they exist and can pull one in
        # full via the read_plan tool when relevant (e.g. read a 5-year plan to
        # draft a year-1 plan). Read-only; it cannot write to these.
        other_plans: List[Dict[str, object]] = []
        if plan_id is not None:
            siblings = (
                session.query(Plan)
                .filter(Plan.project_id == project_id, Plan.id != plan_id)
                .order_by(Plan.updated_at.desc())
                .limit(50)
                .all()
            )
            other_plans = [{"id": p.id, "title": p.title} for p in siblings]

        if mode == "todo":
            # Todo mode: tasks only — no plan content needed.
            now = datetime.datetime.utcnow()
            incomplete = [t for t in tasks if not t.is_completed]
            overdue = [t for t in incomplete if t.due_date and t.due_date < now]
            return {
                "mode": "todo",
                "project_id": project_id,
                "tasks": [_serialize_task_brief(t) for t in tasks],
                "overdue_count": len(overdue),
                "plan_titles": [{"id": p.id, "title": p.title} for p in
                                session.query(Plan).filter(Plan.project_id == project_id)
                                .order_by(Plan.updated_at.desc()).limit(20).all()],
            }

        return {
            "mode": "planning",
            "project_id": project_id,
            "tasks": [_serialize_task_brief(t) for t in tasks],
            "plans": [
                {
                    "id": p.id,
                    "title": p.title,
                    "content": p.content[:8000],
                    "updated_at": p.updated_at.isoformat() if p.updated_at else p.created_at.isoformat(),
                }
                for p in plans
            ],
            "other_plans": other_plans,
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
    if mode == "todo":
        return f"""You are a task assistant embedded in the daily todo list for a personal task-management app.
The current project_id is {project_id}.

YOUR ROLE
- Help the user manage, understand, and act on their tasks for today and the near future.
- You can create, update, delete, and query tasks. You cannot write or read plan documents — use the todo screen tools only.
- When the user asks what they should work on, prioritise by due date and urgency; mention duration so they can plan their time.
- When the user asks to add something, call create_task immediately — don't ask for confirmation unless the request is genuinely ambiguous.

TOOL GUIDELINES
- Use list_tasks to answer questions ("what's due today?", "anything tagged work?") before replying.
- For marking tasks done: call update_task with is_completed=true. For recurring tasks, tell the user to use the app's complete button so the recurrence advances correctly.
- For any relative date ("today", "tomorrow", "next Monday"), use the current date/time provided to you (or call get_current_datetime) — never guess today's date.
- Keep changes minimal. Don't delete tasks unless explicitly asked.

STYLE
- Be brief and actionable. Bullet-point task lists when listing more than two items.
- You will often be spoken aloud via text-to-speech, so keep responses conversational and avoid markdown tables or heavy formatting.
- Contractions and a friendly tone are fine.
"""

    return f"""You are the planning assistant for a personal task-management app.
You help the user break goals into tasks, set realistic durations and due
dates, and organize their plan. The current mode is '{mode}'.

SCOPE
- You operate ONLY within project_id={project_id}. Never read, reference, or
  modify data from any other project or user.
- Use only the provided tools to change data. Never claim to have taken an
  action you did not perform via a tool call.
- If a request needs data you were not given, say so; do not invent task IDs,
  dates, or facts.
- Other plans in this project are listed (id + title) under other_plans. You may
  read any of them with the read_plan tool to inform your work — e.g. consult a
  high-level/long-term plan while drafting a more specific one. You can read
  other plans but only write to the current plan.
- Use list_tasks to search, query, or inspect tasks in the current project — for
  example, to find overdue tasks, tasks matching a keyword, or tasks with a
  specific tag. The project context already contains a summary of tasks, but
  list_tasks gives you full detail and supports filtering.
- The user may attach files (PDFs, text, images). Use their contents to inform
  planning. Scanned PDFs may be shown to you as page images. If an attachment is
  unreadable or missing, say so rather than guessing its contents.

DATA & PRIVACY
- Treat all task content as private personal data. Do not repeat it back beyond
  what is needed to answer, and never summarize it for any third party.
- Do not request, store, or echo credentials, payment details, government IDs,
  health details, or other sensitive personal information. If the user pastes a
  secret (API key, password), do not repeat it and remind them to remove it.
- Do not include external URLs, tracking links, or instructions to contact
  outside services unless the user explicitly asks.

SAFETY
- Refuse to help with anything illegal, harmful, or that targets other people
  (harassment, doxxing, weapons, malware). Decline briefly and offer a safe
  alternative where reasonable.
- Do not give medical, legal, or financial advice as fact; frame general info
  as non-professional and suggest consulting a professional.
- You are not a crisis service. If the user expresses intent to harm themselves
  or others, respond with empathy and point them to professional help; do not
  attempt clinical counseling.

ACTIONS & APPROVAL
- Prefer the smallest set of changes that satisfies the request. Do not delete
  or overwrite existing tasks/plans unless explicitly asked.
- Before creating a task, check the provided project context for an existing
  task with the same/similar title. If it already exists, update it instead of
  creating a duplicate. Never create the same task twice in one request.
- To remove a task, call delete_task with the exact id from the project
  context. To clean up duplicates, delete the extras and keep one. Do not
  "recreate" tasks to fix mistakes — update or delete the existing ones.
- CRITICAL: When a plan is open, you may ONLY call delete_task for tasks that
  are already embedded in that plan via {{{{task:ID}}}} tokens. Never delete tasks
  that are not referenced in the current plan — doing so will be rejected. If
  a task is not in the plan, do not delete it; update or ignore it instead.
- After you finish your tool calls, always reply to the user in plain text
  summarizing what you created, updated, or deleted.
- To embed a task in a plan (whether interspersed with text OR at the end),
  ALWAYS use write_plan. Place {{{{task:ID}}}} tokens on their own line exactly
  where each task should appear in the document. The plan content is given to
  you in the context (or call read_plan on the current plan id to get the full
  text). Rewrite the full content with the tokens in the right positions.
  NEVER use insert_task_into_plan — it only appends to the end and has been
  removed. Never reference a task id you have not seen in the project context
  or a create_task result — such tokens are rejected.
- CREATE-THEN-EMBED — MANDATORY ORDER (do both in ONE turn, no back-and-forth):
  When the user asks you to create tasks AND place them in a plan, you MUST:
    1. Call create_task for EVERY new task FIRST, and WAIT for the results.
       Each successful create_task returns the new integer "task_id".
    2. Only AFTER you have those real task_id values, call write_plan with
       {{{{task:ID}}}} tokens using those exact ids, placed where each task
       belongs in the document.
    3. Do NOT call create_task and write_plan in the same step — you cannot know
       a task's id until create_task has returned it. Create first, read the
       ids from the tool results, then write the plan in a later step.
  Newly created tasks are saved immediately; the plan rewrite is the change the
  user approves. NEVER tell the user a task was "added to the plan", "embedded",
  or "placed" unless a write_plan call returned ok:true containing that exact
  {{{{task:ID}}}} token. If you have created tasks but not yet written them into
  the plan, do not stop and do not claim success — continue and call write_plan.

TASK WIDGET RENDERING — CRITICAL
  Token format: {{{{task:42}}}} where 42 is the integer task id. Two opening
  curly braces, then task:ID, then two closing curly braces. Single braces
  are NOT recognised — always use the double-brace form.
  When the plan is displayed in the app, every {{{{task:ID}}}} token is replaced
  by a rich interactive widget that automatically shows:
    • Title
    • Due date and time
    • Estimated duration
    • Tags (colored chips)
    • Urgency color bar (based on time remaining vs. duration)
    • Actual time logged vs. estimate (progress bar)
    • Start/stop work-session button, complete button, skip button, edit button
    • Completion history and punctuality badges
  Because the widget already renders all this information beautifully, you
  MUST NOT re-state task titles, due dates, durations, or tags in plain text
  next to a {{{{task:ID}}}} token. Do not write bullet lists or tables that repeat
  task details — use the token and let the widget do the work.
  RULE: Any time you are about to write a task title, due date, or duration
  in plain markdown, ask yourself: does this task exist in the project?
  If yes, embed it with {{{{task:ID}}}} instead. Only use plain text for tasks
  that cannot be created (e.g. conceptual placeholders you have not yet
  decided to create).
- For bulk or destructive changes, describe what you will do and ask for
  confirmation before calling tools.
- Set durations and due dates realistically; flag when a deadline looks
  infeasible rather than silently packing the schedule.

STYLE
- Be concise and practical. Explain reasoning briefly, then act.
"""


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

    try:
        async with httpx.AsyncClient(timeout=timeout_sec) as client:
            resp = await _llm_post(client, f"{base_url.rstrip('/')}/chat/completions", headers=headers, payload=payload)
    except httpx.TimeoutException:
        raise HTTPException(
            status_code=504,
            detail=(
                f"The LLM provider did not respond within {timeout_sec:.0f}s. "
                "Try again, send fewer/smaller attachments, or raise LLM_TIMEOUT_SECONDS."
            ),
        )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Could not reach LLM provider: {exc}")
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
    runtime: Optional[tuple[str, str, Optional[str], float]] = None,
) -> Dict[str, Any]:
    if runtime is not None:
        base_url, resolved_model, api_key, timeout_sec = runtime
    else:
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

    try:
        async with httpx.AsyncClient(timeout=timeout_sec) as client:
            resp = await _llm_post(client, f"{base_url.rstrip('/')}/chat/completions", headers=headers, payload=payload)
    except httpx.TimeoutException:
        raise HTTPException(
            status_code=504,
            detail=(
                f"The LLM provider did not respond within {timeout_sec:.0f}s. "
                "Try again, send fewer/smaller attachments, or raise LLM_TIMEOUT_SECONDS."
            ),
        )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Could not reach LLM provider: {exc}")
    if resp.status_code >= 400:
        detail = resp.text[:500]
        raise HTTPException(status_code=502, detail=f"LLM provider error: {resp.status_code} {detail}")

    data = resp.json()
    try:
        message = data["choices"][0]["message"]
    except Exception:
        raise HTTPException(status_code=502, detail="LLM response shape was invalid")
    if isinstance(message, dict):
        usage = data.get("usage") or {}
        message["_usage"] = {
            "prompt_tokens": int(usage.get("prompt_tokens") or 0),
            "completion_tokens": int(usage.get("completion_tokens") or 0),
        }
    return message


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
                        "recurrence_rule": {"type": "string", "enum": ["DAILY", "WEEKDAYS", "WEEKLY", "MONTHLY"]},
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
                        "recurrence_rule": {"type": "string", "enum": ["DAILY", "WEEKDAYS", "WEEKLY", "MONTHLY"]},
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
                "name": "delete_task",
                "description": (
                    "Permanently delete a task in the current project by its id. "
                    "Use this to remove duplicate or unwanted tasks. Use the exact "
                    "id from the provided project context; never guess ids."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "task_id": {"type": "integer"},
                    },
                    "required": ["task_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "write_plan",
                "description": (
                    "Replace or append a plan's markdown content. To embed a task "
                    "as a live widget INLINE (interspersed with your text), put a "
                    "{{task:ID}} token on its own line exactly where you want it. "
                    "Every id must be an EXISTING task in this project (create it "
                    "first with create_task and use the returned id); referencing a "
                    "non-existent id is rejected. Prefer this over insert_task_into_plan "
                    "when you want tasks mixed with explanatory text."
                ),
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
                "description": (
                    "Create a new plan in the current project. You may embed existing "
                    "tasks inline by placing {{task:ID}} tokens in the content; every "
                    "id must already exist in this project."
                ),
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
        {
            "type": "function",
            "function": {
                "name": "list_tasks",
                "description": (
                    "List tasks in the current project. Use this to query, search, "
                    "or inspect tasks — e.g. find overdue tasks, tasks with a specific tag, "
                    "or tasks without due dates. Returns id, title, due_date, duration_minutes, "
                    "is_completed, is_recurring, recurrence_rule, and tags for each task."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "include_completed": {
                            "type": "boolean",
                            "description": "Include completed tasks (default false).",
                        },
                        "tag": {
                            "type": "string",
                            "description": "Filter to tasks whose tags contain this string (case-insensitive).",
                        },
                        "search": {
                            "type": "string",
                            "description": "Filter to tasks whose title or description contains this substring (case-insensitive).",
                        },
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "read_plan",
                "description": (
                    "Read the full markdown content of any plan in THIS project (read-only). "
                    "Use this to get the complete current plan content before calling write_plan "
                    "(the context only shows the first 8000 characters). You can also use it to "
                    "consult other plans listed in other_plans."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "plan_id": {
                            "type": "integer",
                            "description": "Id of a plan in this project (see other_plans).",
                        },
                    },
                    "required": ["plan_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_current_datetime",
                "description": (
                    "Return the current date and time (UTC). Use this whenever you "
                    "need to know today's date or resolve relative dates like "
                    "'today', 'tomorrow', or 'next week'."
                ),
                "parameters": {"type": "object", "properties": {}, "required": []},
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


_TASK_TOKEN_RE = re.compile(r"\{\{task:(\d+)\}\}")

# Tools that only read data — they execute immediately and never require approval.
_READ_ONLY_TOOLS = {"read_plan", "list_tasks", "get_current_datetime"}

# Tools that are safe to execute immediately even in approval mode because they
# are additive and trivially reversible. Creating a task right away (instead of
# as a dry-run) gives the model the real task_id it needs to embed that task in
# a plan via {task:ID} in the SAME turn — without a real id, embedding silently
# fails and the model wrongly claims success. Plan writes, updates and deletes
# still go through the approval queue.
_IMMEDIATE_PLANNING_TOOLS = {"create_task"}


def _validate_plan_task_tokens(
    *,
    content: str,
    project_id: int,
    session: Session,
) -> None:
    """Ensure every {{task:ID}} token in plan content references a task that
    actually exists in this project. This lets the agent place task widgets
    inline (interspersed with text) via write_plan/create_plan while still
    preventing references to non-existent or other-project tasks."""
    ids = {int(m.group(1)) for m in _TASK_TOKEN_RE.finditer(content or "")}
    if not ids:
        return
    found = {
        row[0]
        for row in session.query(Task.id)
        .filter(Task.id.in_(ids), Task.project_id == project_id)
        .all()
    }
    missing = sorted(ids - found)
    if missing:
        raise HTTPException(
            status_code=400,
            detail=(
                "Plan references task id(s) not in this project: "
                + ", ".join(str(i) for i in missing)
                + ". Create the task first, then reference its id."
            ),
        )


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

    if name == "get_current_datetime":
        now = datetime.datetime.utcnow()
        return {
            "ok": True,
            "action": "get_current_datetime",
            "utc_datetime": now.isoformat() + "Z",
            "date": now.date().isoformat(),
            "weekday": now.strftime("%A"),
            "note": "Times are UTC. Task due dates are stored in UTC.",
        }

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

    if name == "delete_task":
        task_id = args.get("task_id")
        if not isinstance(task_id, int):
            raise HTTPException(status_code=400, detail="delete_task requires integer task_id")
        task = session.query(Task).filter(Task.id == task_id, Task.project_id == project_id).first()
        if not task:
            raise HTTPException(status_code=404, detail="Task not found in this project")

        # Safety guardrail: when operating within a plan, only allow deleting
        # tasks that are explicitly embedded in that plan via {task:ID} tokens.
        # This prevents the agent from accidentally deleting unrelated tasks.
        if default_plan_id is not None:
            plan = session.query(Plan).filter(
                Plan.id == default_plan_id, Plan.project_id == project_id
            ).first()
            if plan:
                plan_task_ids = {
                    int(m.group(1))
                    for m in _TASK_TOKEN_RE.finditer(plan.content or "")
                }
                if task_id not in plan_task_ids:
                    raise HTTPException(
                        status_code=403,
                        detail=(
                            f"Cannot delete task #{task_id} (\'{task.title}\') — it is not "
                            "embedded in this plan. Only tasks referenced via {task:ID} "
                            "tokens in the current plan may be deleted from the plan editor."
                        ),
                    )

        title = task.title
        if dry_run:
            return {
                "ok": True,
                "action": "delete_task",
                "dry_run": True,
                "task_id": task_id,
                "title": title,
            }

        session.delete(task)
        session.commit()
        return {"ok": True, "action": "delete_task", "task_id": task_id, "title": title}

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
        new_content = (
            f"{plan.content.rstrip()}\n\n{content}" if append and plan.content else content
        )
        _validate_plan_task_tokens(content=new_content, project_id=project_id, session=session)
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
        _validate_plan_task_tokens(content=content, project_id=project_id, session=session)
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

    if name == "insert_task_into_plan":
        task_id = args.get("task_id")
        if not isinstance(task_id, int):
            raise HTTPException(status_code=400, detail="insert_task_into_plan requires integer task_id")

        # The task must already exist in this project — this is what prevents
        # the agent from embedding non-existent tasks.
        task = session.query(Task).filter(Task.id == task_id, Task.project_id == project_id).first()
        if not task:
            raise HTTPException(status_code=404, detail="Task not found in this project")

        plan_id = args.get("plan_id") if isinstance(args.get("plan_id"), int) else default_plan_id
        if plan_id is None:
            raise HTTPException(
                status_code=400,
                detail="insert_task_into_plan requires plan_id when no default plan is selected",
            )
        plan = session.query(Plan).filter(Plan.id == plan_id, Plan.project_id == project_id).first()
        if not plan:
            raise HTTPException(status_code=404, detail="Plan not found in this project")

        position = str(args.get("position") or "end").lower()
        token = f"{{{{task:{task_id}}}}}"

        if dry_run:
            return {
                "ok": True,
                "action": "insert_task_into_plan",
                "dry_run": True,
                "task_id": task_id,
                "plan_id": plan.id,
                "position": position,
                "title": task.title,
            }

        existing = plan.content or ""
        if token in existing:
            # Idempotent: don't embed the same task twice.
            return {
                "ok": True,
                "action": "insert_task_into_plan",
                "task_id": task_id,
                "plan_id": plan.id,
                "already_present": True,
                "title": task.title,
            }

        if position == "start":
            plan.content = f"{token}\n\n{existing.lstrip()}" if existing.strip() else token
        else:
            plan.content = f"{existing.rstrip()}\n\n{token}" if existing.strip() else token
        plan.updated_at = datetime.datetime.utcnow()
        session.commit()
        return {
            "ok": True,
            "action": "insert_task_into_plan",
            "task_id": task_id,
            "plan_id": plan.id,
            "position": position,
            "title": task.title,
        }

    if name == "list_tasks":
        include_completed = bool(args.get("include_completed", False))
        tag_filter = (args.get("tag") or "").strip().lower()
        search_filter = (args.get("search") or "").strip().lower()

        q = session.query(Task).options(selectinload(Task.tags)).filter(
            Task.project_id == project_id
        )
        if not include_completed:
            q = q.filter(Task.is_completed.is_(False))
        tasks = q.order_by(Task.due_date.asc().nulls_last(), Task.created_at.asc()).all()

        results = []
        for t in tasks:
            if tag_filter and not any(tag_filter in tg.name.lower() for tg in t.tags):
                continue
            if search_filter and search_filter not in (t.title or "").lower() and search_filter not in (t.description or "").lower():
                continue
            results.append({
                "id": t.id,
                "title": t.title,
                "due_date": t.due_date.isoformat() if t.due_date else None,
                "duration_minutes": t.duration_minutes,
                "is_completed": t.is_completed,
                "is_recurring": t.is_recurring,
                "recurrence_rule": t.recurrence_rule,
                "tags": [tg.name for tg in t.tags],
            })
        return {
            "ok": True,
            "action": "list_tasks",
            "count": len(results),
            "tasks": results,
        }

    if name == "read_plan":
        plan_id = args.get("plan_id")
        if not isinstance(plan_id, int):
            raise HTTPException(status_code=400, detail="read_plan requires integer plan_id")
        plan = session.query(Plan).filter(Plan.id == plan_id, Plan.project_id == project_id).first()
        if not plan:
            raise HTTPException(status_code=404, detail="Plan not found in this project")
        # Read-only: return content even in dry-run/approval mode so the agent
        # can reason over it. Cap length to keep token usage bounded.
        return {
            "ok": True,
            "action": "read_plan",
            "plan_id": plan.id,
            "title": plan.title,
            "content": (plan.content or "")[:8000],
        }

    raise HTTPException(status_code=400, detail=f"Unsupported tool: {name}")


def _todo_tools_schema() -> List[Dict[str, Any]]:
    """Trimmed tool set for the todo-screen agent.

    No plan read/write — it operates directly on tasks and conversation.
    """
    return [
        {
            "type": "function",
            "function": {
                "name": "list_tasks",
                "description": (
                    "List tasks in the current project with optional filters. "
                    "Use this to answer questions about what's due, overdue, tagged, etc."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "include_completed": {"type": "boolean"},
                        "tag": {"type": "string"},
                        "search": {"type": "string"},
                    },
                    "required": [],
                },
            },
        },
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
                        "recurrence_rule": {
                            "type": "string",
                            "enum": ["DAILY", "WEEKDAYS", "WEEKLY", "MONTHLY"],
                        },
                        "tags": {"type": "array", "items": {"type": "string"}},
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
                        "due_date": {"type": "string"},
                        "duration_minutes": {"type": "integer"},
                        "is_recurring": {"type": "boolean"},
                        "recurrence_rule": {
                            "type": "string",
                            "enum": ["DAILY", "WEEKDAYS", "WEEKLY", "MONTHLY"],
                        },
                        "is_completed": {"type": "boolean"},
                        "tags": {"type": "array", "items": {"type": "string"}},
                    },
                    "required": ["task_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "delete_task",
                "description": "Permanently delete a task by its id.",
                "parameters": {
                    "type": "object",
                    "properties": {"task_id": {"type": "integer"}},
                    "required": ["task_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_current_datetime",
                "description": (
                    "Return the current date and time (UTC). Use this whenever you "
                    "need to know today's date or resolve relative dates like "
                    "'today', 'tomorrow', or 'next week'."
                ),
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
    ]


# ── Persistent conversation memory ────────────────────────────────────────────
# One resumable thread per (user, mode, plan/project). Older turns are folded
# into a compact LLM-written summary so storage and per-request tokens stay
# bounded while the agent still "remembers" earlier context.
_KEEP_RECENT_MESSAGES = 20


def _find_conversation(
    session: Session,
    user_id: int,
    mode: str,
    plan_id: Optional[int],
    project_id: int,
) -> Optional[LLMConversation]:
    q = session.query(LLMConversation).filter(
        LLMConversation.user_id == user_id,
        LLMConversation.mode == mode,
    )
    if mode == "planning" and plan_id is not None:
        q = q.filter(LLMConversation.related_plan_id == plan_id)
    else:
        q = q.filter(
            LLMConversation.related_plan_id.is_(None),
            LLMConversation.project_id == project_id,
        )
    return q.order_by(LLMConversation.updated_at.desc()).first()


async def _summarize_history(
    prior_summary: Optional[str],
    messages: List[Dict[str, Any]],
    model: str,
    runtime: Optional[tuple[str, str, Optional[str], float]] = None,
) -> tuple[str, int, int]:
    """Fold older turns into a concise running memory. Returns (text, p_tok, c_tok)."""
    convo_text = "\n".join(
        f"{m.get('role', 'user')}: {str(m.get('content', ''))[:2000]}" for m in messages
    )
    system = (
        "You maintain a compact running memory of a planning chat. Merge the "
        "existing memory with the new messages into one concise summary. Preserve "
        "concrete facts: decisions, task titles/IDs, dates, durations, and "
        "unresolved threads. Drop greetings and filler. Reply with the updated "
        "memory only, max 200 words."
    )
    user = ""
    if prior_summary:
        user += f"Existing memory:\n{prior_summary}\n\n"
    user += f"New messages to fold in:\n{convo_text}"
    msg = await _call_llm_message(
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        model=model,
        runtime=runtime,
    )
    usage = msg.pop("_usage", {}) if isinstance(msg, dict) else {}
    text = msg.get("content") if isinstance(msg, dict) else None
    return (
        (text or prior_summary or ""),
        int(usage.get("prompt_tokens", 0)),
        int(usage.get("completion_tokens", 0)),
    )


@router.post("/chat")
async def agent_chat(
    body: AgentChatRequest,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _assert_project_member(body.project_id, user_id, session)

    # Resolve runtime: a user's own key/base_url/model override the server
    # defaults. BYO-key users pay their own provider, so the shared cap is
    # only enforced when falling back to the server key.
    user = session.query(User).filter(User.id == user_id).first()
    base_url, model, api_key, timeout_sec, using_user_key = _resolve_runtime_for_user(user)
    runtime = (base_url, model, api_key, timeout_sec)

    spend_cap = _spend_cap_usd()
    spent_before = _total_spend_usd(session)
    if not using_user_key and spent_before >= spend_cap:
        raise HTTPException(
            status_code=429,
            detail=(
                f"LLM spending cap reached (${spent_before:.2f} of ${spend_cap:.2f}). "
                "Add your own API key in AI settings, or increase LLM_SPEND_CAP_USD to continue."
            ),
        )

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

    # Resume the single persistent thread for this plan/project (if any).
    convo = _find_conversation(session, user_id, body.mode, body.plan_id, body.project_id)
    prior_summary = convo.summary if convo else None

    llm_messages: List[Dict[str, Any]] = [
        {
            "role": "system",
            "content": _build_system_prompt(body.mode, body.project_id)
            + (
                " In planning mode, be agentic: when user asks to add/edit tasks or rewrite plan, use tool calls."
                if body.mode == "planning"
                else " In todo mode, be agentic: use tool calls immediately to create/update/query tasks. Keep replies short — they may be spoken aloud."
                if body.mode == "todo"
                else ""
            )
            + (
                f"\n\nCURRENT DATE/TIME (UTC): "
                f"{datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M')} "
                f"({datetime.datetime.utcnow().strftime('%A')}). "
                "Treat this as 'today' when resolving relative dates (today, "
                "tomorrow, this Friday, next week, etc.). Task due dates are "
                "stored in UTC. You can also call get_current_datetime to "
                "re-check the current date at any time."
            ),
        },
        {
            "role": "system",
            "content": "Project-scoped context JSON (do not expose raw unless asked):\n"
            + json.dumps(context_payload, ensure_ascii=True),
        },
    ]
    if prior_summary:
        llm_messages.append({
            "role": "system",
            "content": "Compressed memory of earlier conversation turns:\n" + prior_summary,
        })
    llm_messages.extend([m.model_dump() for m in body.messages])

    attachment_notes: List[str] = []
    if body.attachments:
        attachment_parts, attachment_notes = _process_attachments(body.attachments, model)
        if attachment_parts:
            llm_messages.append({"role": "user", "content": attachment_parts})

    tool_defs = (
        _planning_tools_schema() if body.mode == "planning"
        else _todo_tools_schema() if body.mode == "todo"
        else None
    )
    executed_actions: List[Dict[str, Any]] = []
    proposed_tool_calls: List[Dict[str, Any]] = []
    reply: Optional[str] = None
    total_prompt_tokens = 0
    total_completion_tokens = 0

    for _ in range(8):
        ai_msg = await _call_llm_message(messages=llm_messages, model=model, tools=tool_defs, runtime=runtime)
        if isinstance(ai_msg, dict):
            usage = ai_msg.pop("_usage", None)
            if usage:
                total_prompt_tokens += usage.get("prompt_tokens", 0)
                total_completion_tokens += usage.get("completion_tokens", 0)
        tool_calls = ai_msg.get("tool_calls") if isinstance(ai_msg, dict) else None

        if tool_calls:
            # OpenAI rejects messages with >128 tool_calls when they are
            # replayed in the conversation. Process in chunks of 128 so
            # parallel execution is preserved within each batch.
            _TOOL_CALL_BATCH = 128
            for batch_start in range(0, len(tool_calls), _TOOL_CALL_BATCH):
                batch = tool_calls[batch_start : batch_start + _TOOL_CALL_BATCH]

                llm_messages.append(
                    {
                        "role": "assistant",
                        "content": ai_msg.get("content") or "",
                        "tool_calls": batch,
                    }
                )

                for tool_call in batch:
                    fn = tool_call.get("function", {})
                    tool_name = fn.get("name")
                    raw_args = fn.get("arguments") or "{}"
                    try:
                        parsed_args = json.loads(raw_args)
                        if not isinstance(parsed_args, dict):
                            raise ValueError("Tool arguments must be a JSON object")

                        result = _execute_planning_tool_call(
                            name=tool_name,
                            args=parsed_args,
                            project_id=body.project_id,
                            default_plan_id=body.plan_id,
                            user_id=user_id,
                            session=session,
                            dry_run=(
                                body.mode == "planning"
                                and body.require_approval
                                and tool_name not in _READ_ONLY_TOOLS
                                and tool_name not in _IMMEDIATE_PLANNING_TOOLS
                            ),
                        )

                        if body.mode == "planning" and body.require_approval:
                            # Read-only and immediate tools don't go through the
                            # approval queue: read-only tools don't mutate data,
                            # and immediate tools (create_task) run now so the
                            # model gets a real task_id to embed in the same turn.
                            if (
                                tool_name not in _READ_ONLY_TOOLS
                                and tool_name not in _IMMEDIATE_PLANNING_TOOLS
                            ):
                                entry: Dict[str, Any] = {"name": tool_name, "args": parsed_args}
                                # Include the resolved task title so the approval UI
                                # can show names instead of raw IDs.
                                if result.get("ok") and result.get("title"):
                                    entry["resolved_title"] = result["title"]
                                proposed_tool_calls.append(entry)

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

            # In approval mode, once we've collected proposed tool calls we
            # must stop looping — otherwise the model sees the dry-run "ok"
            # results and proposes the exact same actions again on the next
            # iteration, duplicating every entry in the approval queue.
            if proposed_tool_calls:
                break
            continue

        reply = ai_msg.get("content") if isinstance(ai_msg, dict) else None
        if reply is None:
            reply = ""
        break

    # If the loop ended without a usable text reply (e.g. the model kept making
    # tool calls until the iteration cap, or returned empty content), make one
    # final call WITHOUT tools so it must summarize what it did in plain text.
    if (reply is None or not reply.strip()) and executed_actions:
        llm_messages.append(
            {
                "role": "system",
                "content": (
                    "Stop calling tools. Briefly tell the user, in plain text, what "
                    "you just changed (created/updated/deleted tasks) and any next steps."
                ),
            }
        )
        final_msg = await _call_llm_message(messages=llm_messages, model=model, runtime=runtime)
        if isinstance(final_msg, dict):
            usage = final_msg.pop("_usage", None)
            if usage:
                total_prompt_tokens += usage.get("prompt_tokens", 0)
                total_completion_tokens += usage.get("completion_tokens", 0)
            reply = final_msg.get("content") or reply

    if reply is None or not reply.strip():
        if executed_actions:
            ok_count = sum(1 for a in executed_actions if a.get("ok"))
            reply = f"Done. Applied {ok_count} change(s) to your tasks."
        else:
            reply = "I completed the requested actions, but did not produce a final response."

    history = [m.model_dump() for m in body.messages]
    history.append({"role": "assistant", "content": reply})

    # Compress older turns into a running memory so storage/tokens stay bounded.
    new_summary = prior_summary
    stored_messages = history
    if len(history) > _KEEP_RECENT_MESSAGES:
        overflow = history[: len(history) - _KEEP_RECENT_MESSAGES]
        recent = history[len(history) - _KEEP_RECENT_MESSAGES:]
        try:
            new_summary, sp, sc = await _summarize_history(prior_summary, overflow, model, runtime=runtime)
            total_prompt_tokens += sp
            total_completion_tokens += sc
            stored_messages = recent
        except Exception:
            stored_messages = history  # keep full this round; compress next time

    now = datetime.datetime.utcnow()
    if convo is None:
        convo = LLMConversation(
            user_id=user_id,
            mode=body.mode,
            related_plan_id=body.plan_id if body.mode == "planning" else None,
            project_id=body.project_id,
            created_at=now,
        )
        session.add(convo)
    convo.messages = json.dumps(stored_messages, ensure_ascii=True)
    convo.summary = new_summary
    convo.updated_at = now

    # Only the shared (server-key) usage counts toward the spending cap.
    # BYO-key users bill their own provider, so we don't record it here.
    request_cost = _estimate_cost_usd(model, total_prompt_tokens, total_completion_tokens)
    if not using_user_key and (total_prompt_tokens or total_completion_tokens):
        session.add(LLMUsage(
            user_id=user_id,
            model=model,
            prompt_tokens=total_prompt_tokens,
            completion_tokens=total_completion_tokens,
            cost_usd=request_cost,
            created_at=datetime.datetime.utcnow(),
        ))
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
        "usage": {
            "request_cost_usd": round(request_cost, 6) if not using_user_key else 0.0,
            "total_spend_usd": round(spent_before + (0.0 if using_user_key else request_cost), 4),
            "spend_cap_usd": spend_cap,
            "using_own_key": using_user_key,
        },
        "attachment_notes": attachment_notes,
        "conversation_id": convo.id,
    }


@router.get("/usage")
async def agent_usage(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Current cumulative LLM spend vs. the configured cap."""
    spent = _total_spend_usd(session)
    cap = _spend_cap_usd()
    return {
        "total_spend_usd": round(spent, 4),
        "spend_cap_usd": cap,
        "remaining_usd": round(max(cap - spent, 0.0), 4),
    }


@router.get("/conversation")
async def get_conversation(
    mode: Literal["planning", "analytics", "todo"],
    project_id: int,
    plan_id: Optional[int] = None,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Restore the saved chat thread for a plan/project, if one exists."""
    _assert_project_member(project_id, user_id, session)
    convo = _find_conversation(session, user_id, mode, plan_id, project_id)
    if not convo:
        return {"messages": [], "summary": None, "has_memory": False, "updated_at": None}
    try:
        raw = json.loads(convo.messages or "[]")
    except Exception:
        raw = []
    messages = [
        {"role": m.get("role"), "content": m.get("content", "")}
        for m in raw
        if isinstance(m, dict) and m.get("role") in ("user", "assistant")
    ]
    return {
        "messages": messages,
        "summary": convo.summary,
        "has_memory": bool(convo.summary),
        "updated_at": convo.updated_at.isoformat() if convo.updated_at else None,
    }


@router.delete("/conversation")
async def delete_conversation(
    mode: Literal["planning", "analytics", "todo"],
    project_id: int,
    plan_id: Optional[int] = None,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Delete the saved chat thread for a plan/project."""
    _assert_project_member(project_id, user_id, session)
    convo = _find_conversation(session, user_id, mode, plan_id, project_id)
    if convo:
        session.delete(convo)
        session.commit()
    return {"ok": True}


class AgentSettingsUpdate(BaseModel):
    # Provide api_key to set/replace; omit to leave the stored key unchanged.
    api_key: Optional[str] = None
    base_url: Optional[str] = None
    model: Optional[str] = None
    # Set true to remove the stored key and revert to the server default.
    clear: bool = False


def _mask_key_hint(plaintext: Optional[str]) -> Optional[str]:
    if not plaintext:
        return None
    tail = plaintext[-4:] if len(plaintext) >= 4 else plaintext
    return f"…{tail}"


@router.get("/settings")
async def get_agent_settings(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Return the user's LLM override status (never the raw key)."""
    user = session.query(User).filter(User.id == user_id).first()
    server_base, server_model, _, _ = _llm_runtime_config()
    has_key = bool(user and user.llm_api_key_encrypted)
    key_hint = None
    if has_key:
        key_hint = _mask_key_hint(_decrypt_secret(user.llm_api_key_encrypted))
    return {
        "using_own_key": has_key,
        "key_hint": key_hint,
        "base_url": (user.llm_api_base_url if user else None) or server_base,
        "model": (user.llm_model if user else None) or server_model,
        "server_model": server_model,
        "server_base_url": server_base,
    }


@router.put("/settings")
async def update_agent_settings(
    body: AgentSettingsUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Set or clear the user's BYO LLM key / base URL / model."""
    user = session.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if body.clear:
        user.llm_api_key_encrypted = None
        user.llm_api_base_url = None
        user.llm_model = None
        session.commit()
        return {"ok": True, "using_own_key": False}

    if body.api_key is not None:
        key = body.api_key.strip()
        if key:
            user.llm_api_key_encrypted = _encrypt_secret(key)
        # An explicit empty string clears the key.
        elif key == "":
            user.llm_api_key_encrypted = None

    if body.base_url is not None:
        url = body.base_url.strip()
        user.llm_api_base_url = url or None

    if body.model is not None:
        m = body.model.strip()
        user.llm_model = m or None

    session.commit()
    return {
        "ok": True,
        "using_own_key": bool(user.llm_api_key_encrypted),
        "base_url": user.llm_api_base_url,
        "model": user.llm_model,
    }


@router.delete("/settings")
async def delete_agent_settings(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Remove the user's LLM override and revert to the server default."""
    user = session.query(User).filter(User.id == user_id).first()
    if user:
        user.llm_api_key_encrypted = None
        user.llm_api_base_url = None
        user.llm_model = None
        session.commit()
    return {"ok": True, "using_own_key": False}


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
