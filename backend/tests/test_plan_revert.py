"""
Tests for reverting a plan to an earlier stage.

Covers:
  - _reverse_apply_unified_diff reconstructs the "before" content from the
    "after" content + the unified diff that produced it (patch -R).
  - The full revert flow over HTTP: editing a plan several times, reverting to
    an earlier revision reconstructs that stage's content, records the revert as
    a NEW revision, and the revert can itself be reverted.
  - Guardrails: unknown revision -> 404, viewer role -> 403.
"""
import difflib
import pytest

from database import Plan, ProjectMembership
from routers.tasks import (
    _reverse_apply_unified_diff,
    _reconstruct_plan_content_at_revision,
)


def _make_diff(old: str, new: str) -> str:
    return "\n".join(difflib.unified_diff(
        old.splitlines(), new.splitlines(),
        fromfile="before", tofile="after", lineterm="",
    ))


# ── _reverse_apply_unified_diff ───────────────────────────────────────────────

def test_reverse_apply_single_line_change():
    old = "line1\nline2\nline3"
    new = "line1\nCHANGED\nline3"
    assert _reverse_apply_unified_diff(new, _make_diff(old, new)) == old


def test_reverse_apply_addition():
    old = "a\nb"
    new = "a\nb\nc\nd"
    assert _reverse_apply_unified_diff(new, _make_diff(old, new)) == old


def test_reverse_apply_removal():
    old = "a\nb\nc\nd"
    new = "a\nd"
    assert _reverse_apply_unified_diff(new, _make_diff(old, new)) == old


def test_reverse_apply_from_empty():
    old = ""
    new = "x\ny\nz"
    assert _reverse_apply_unified_diff(new, _make_diff(old, new)) == old


def test_reverse_apply_to_empty():
    old = "a\nb\nc"
    new = ""
    assert _reverse_apply_unified_diff(new, _make_diff(old, new)) == old


def test_reverse_apply_multi_hunk():
    old = "\n".join(f"row{i}" for i in range(20))
    new_lines = [f"row{i}" for i in range(20)]
    new_lines[2] = "EDIT-A"
    new_lines[15] = "EDIT-B"
    new = "\n".join(new_lines)
    assert _reverse_apply_unified_diff(new, _make_diff(old, new)) == old


def test_reverse_apply_empty_diff_is_identity():
    content = "unchanged\ncontent"
    assert _reverse_apply_unified_diff(content, "") == content


# ── _reconstruct_plan_content_at_revision ─────────────────────────────────────

class _FakePlan:
    def __init__(self, content):
        self.content = content


class _FakeRev:
    def __init__(self, id_, diff):
        self.id = id_
        self.diff = diff


def test_reconstruct_walks_back_to_target():
    v0, v1, v2, v3 = "v0", "v1", "v2", "v3"
    rev1 = _FakeRev(1, _make_diff(v0, v1))
    rev2 = _FakeRev(2, _make_diff(v1, v2))
    rev3 = _FakeRev(3, _make_diff(v2, v3))
    plan = _FakePlan(v3)
    revs = [rev1, rev2, rev3]  # chronological ascending

    # Reverting to rev1 restores the state right after rev1 was saved (v1).
    assert _reconstruct_plan_content_at_revision(plan, revs, 1) == v1
    assert _reconstruct_plan_content_at_revision(plan, revs, 2) == v2
    # Reverting to the newest revision is a no-op.
    assert _reconstruct_plan_content_at_revision(plan, revs, 3) == v3


# ── HTTP: full revert flow ────────────────────────────────────────────────────

def _create_plan(client, project_id, content):
    r = client.post("/plans", json={"project_id": project_id, "title": "Doc", "content": content})
    assert r.status_code == 200, r.text
    return r.json()["id"]


def _put(client, plan_id, content):
    r = client.put(f"/plans/{plan_id}", json={"content": content})
    assert r.status_code == 200, r.text


def test_revert_flow_end_to_end(http_client):
    client, ctx = http_client
    project_id = ctx["project"].id

    plan_id = _create_plan(client, project_id, "Version zero")
    _put(client, plan_id, "Version one")
    _put(client, plan_id, "Version two")
    _put(client, plan_id, "Version three")

    history = client.get(f"/plans/{plan_id}/history").json()
    assert len(history) == 3  # newest first
    # history[0] = v2->v3, history[1] = v1->v2, history[2] = v0->v1
    rev_v0_v1 = history[2]["id"]
    rev_v2_v3 = history[0]["id"]

    # Preview reverting to the first revision => "Version one".
    prev = client.get(f"/plans/{plan_id}/revisions/{rev_v0_v1}/preview").json()
    assert prev["content"] == "Version one"
    assert prev["is_current"] is False

    # Revert to the first revision.
    resp = client.post(f"/plans/{plan_id}/revert", json={"revision_id": rev_v0_v1})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["reverted"] is True
    assert body["content"] == "Version one"

    # Plan now reads "Version one".
    assert client.get(f"/plans/{plan_id}").json()["content"] == "Version one"

    # The revert was recorded as a NEW revision (4 total now).
    history2 = client.get(f"/plans/{plan_id}/history").json()
    assert len(history2) == 4

    # Reversals can be reversed: revert to the v2->v3 revision restores "Version three".
    resp2 = client.post(f"/plans/{plan_id}/revert", json={"revision_id": rev_v2_v3})
    assert resp2.status_code == 200, resp2.text
    assert resp2.json()["content"] == "Version three"
    assert client.get(f"/plans/{plan_id}").json()["content"] == "Version three"


def test_revert_noop_when_already_at_revision(http_client):
    client, ctx = http_client
    project_id = ctx["project"].id
    plan_id = _create_plan(client, project_id, "start")
    _put(client, plan_id, "end")
    history = client.get(f"/plans/{plan_id}/history").json()
    latest = history[0]["id"]
    resp = client.post(f"/plans/{plan_id}/revert", json={"revision_id": latest})
    assert resp.status_code == 200
    assert resp.json()["reverted"] is False


def test_revert_unknown_revision_404(http_client):
    client, ctx = http_client
    project_id = ctx["project"].id
    plan_id = _create_plan(client, project_id, "content")
    resp = client.post(f"/plans/{plan_id}/revert", json={"revision_id": 999999})
    assert resp.status_code == 404


def test_revert_viewer_forbidden(http_client):
    client, ctx = http_client
    db = ctx["db"]
    project_id = ctx["project"].id
    user = ctx["user"]

    plan_id = _create_plan(client, project_id, "a")
    _put(client, plan_id, "b")
    rev = client.get(f"/plans/{plan_id}/history").json()[0]["id"]

    # Demote the caller to viewer.
    membership = db.query(ProjectMembership).filter(
        ProjectMembership.project_id == project_id,
        ProjectMembership.user_id == user.id,
    ).first()
    membership.role = "viewer"
    db.commit()

    resp = client.post(f"/plans/{plan_id}/revert", json={"revision_id": rev})
    assert resp.status_code == 403
