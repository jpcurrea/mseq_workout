"""Shared helpers for plan markdown processing.

Kept separate from the routers so both the plans API (routers/tasks.py) and the
planning agent (routers/agent.py) can apply the same behaviour without a
circular import.
"""
import re
from typing import Optional

from sqlalchemy.orm import Session

from database import Task

# A searchable/sortable task-list block: {{tasklist sort=... \n - task:ID ... }}.
TASKLIST_BLOCK_RE = re.compile(r"\{\{tasklist[\s\S]*?\}\}")
# A task reference inside a tasklist block member line (single-brace `task:ID`).
TASKLIST_MEMBER_RE = re.compile(r"task:(\d+)")
# A full task-list member line: optional indent, optional "- " bullet, then
# `task:ID`, then whatever label follows (captured in `rest`).
TASKLIST_MEMBER_LINE_RE = re.compile(r"^(?P<indent>[ \t]*)-?[ \t]*task:(?P<id>\d+)(?P<rest>.*)$")


def annotate_tasklist_titles(content: str, *, project_id: int, session: Session) -> str:
    """Inside every {{tasklist ...}} block, ensure each `task:ID` member line
    carries the task's title as a label.

    Member lines written without a label (e.g. a bare `- task:123`) get the
    current title appended so the raw plan markdown stays human-readable. Lines
    that already have a label are left untouched so intentional custom notes are
    preserved. Ids that do not resolve to a task in this project are left as-is.
    """
    if not content or "{{tasklist" not in content:
        return content

    ids: set[int] = set()
    for block in TASKLIST_BLOCK_RE.finditer(content):
        ids.update(int(m.group(1)) for m in TASKLIST_MEMBER_RE.finditer(block.group(0)))
    if not ids:
        return content

    titles = {
        row[0]: row[1]
        for row in session.query(Task.id, Task.title)
        .filter(Task.id.in_(ids), Task.project_id == project_id)
        .all()
    }

    def _fix_block(match: "re.Match[str]") -> str:
        lines = match.group(0).split("\n")
        for i, line in enumerate(lines):
            lm = TASKLIST_MEMBER_LINE_RE.match(line)
            if not lm:
                continue
            tid = int(lm.group("id"))
            title = titles.get(tid)
            # Only add a label when one is missing; never clobber a `}}` that is
            # attached to the same line or an existing custom label.
            if title and not lm.group("rest").strip():
                lines[i] = f"{lm.group('indent')}- task:{tid}  {title}"
        return "\n".join(lines)

    return TASKLIST_BLOCK_RE.sub(_fix_block, content)
