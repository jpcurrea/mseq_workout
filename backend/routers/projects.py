"""
Project routes: CRUD, membership management, and invite tokens.
"""
import datetime
import secrets
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from database import (
    get_session,
    User,
    Project,
    ProjectMembership,
    ProjectInvite,
    Task,
    Plan,
)
from dependencies import get_current_user_id

router = APIRouter(prefix="/projects", tags=["projects"])


# ── Schemas ────────────────────────────────────────────────────────────────────

class ProjectCreate(BaseModel):
    name: str
    description: Optional[str] = None


class ProjectUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None


class InviteCreate(BaseModel):
    role_to_grant: str = "editor"   # "editor" | "viewer"
    max_uses: Optional[int] = None
    expires_hours: Optional[int] = None  # None = never


class InviteRedeem(BaseModel):
    token: str


# ── Helpers ────────────────────────────────────────────────────────────────────

def _get_membership(
    project_id: int, user_id: int, session: Session
) -> ProjectMembership:
    m = session.query(ProjectMembership).filter(
        ProjectMembership.project_id == project_id,
        ProjectMembership.user_id == user_id,
    ).first()
    if not m:
        raise HTTPException(status_code=403, detail="Not a member of this project")
    return m


def _require_owner_or_editor(project_id: int, user_id: int, session: Session):
    m = _get_membership(project_id, user_id, session)
    if m.role == "viewer":
        raise HTTPException(status_code=403, detail="Viewer role cannot modify this project")
    return m


def _serialize_project(project: Project, membership: ProjectMembership) -> dict:
    return {
        "id": project.id,
        "name": project.name,
        "description": project.description,
        "owner_id": project.owner_id,
        "role": membership.role,
        "member_count": len(project.memberships),
        "created_at": project.created_at.isoformat(),
    }


# ── Project CRUD ───────────────────────────────────────────────────────────────

@router.get("")
async def list_projects(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """All projects the current user is a member of."""
    memberships = (
        session.query(ProjectMembership)
        .filter(ProjectMembership.user_id == user_id)
        .all()
    )
    result = []
    for m in memberships:
        result.append(_serialize_project(m.project, m))
    return result


@router.post("")
async def create_project(
    body: ProjectCreate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    project = Project(
        name=body.name,
        description=body.description,
        owner_id=user_id,
    )
    session.add(project)
    session.flush()  # get project.id

    membership = ProjectMembership(
        project_id=project.id,
        user_id=user_id,
        role="owner",
    )
    session.add(membership)
    session.commit()
    session.refresh(project)
    return _serialize_project(project, membership)


@router.get("/{project_id}")
async def get_project(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    m = _get_membership(project_id, user_id, session)
    return _serialize_project(m.project, m)


@router.put("/{project_id}")
async def update_project(
    project_id: int,
    body: ProjectUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    m = _require_owner_or_editor(project_id, user_id, session)
    if body.name is not None:
        m.project.name = body.name
    if body.description is not None:
        m.project.description = body.description
    session.commit()
    return _serialize_project(m.project, m)


@router.delete("/{project_id}")
async def delete_project(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    m = _get_membership(project_id, user_id, session)
    if m.role != "owner":
        raise HTTPException(status_code=403, detail="Only the owner can delete a project")
    session.delete(m.project)
    session.commit()
    return {"message": "Project deleted"}


# ── Active project preference ──────────────────────────────────────────────────

@router.post("/{project_id}/activate")
async def set_active_project(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Remember this as the user's active project (restored on next login)."""
    _get_membership(project_id, user_id, session)  # verify membership
    user = session.query(User).filter(User.id == user_id).first()
    user.active_project_id = project_id
    session.commit()
    return {"active_project_id": project_id}


@router.get("/me/active")
async def get_active_project(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Return the user's active project, or the first available project."""
    user = session.query(User).filter(User.id == user_id).first()
    project_id = user.active_project_id

    # Validate membership still exists
    if project_id:
        m = session.query(ProjectMembership).filter(
            ProjectMembership.project_id == project_id,
            ProjectMembership.user_id == user_id,
        ).first()
        if not m:
            project_id = None

    # Fall back to first project
    if not project_id:
        m = (
            session.query(ProjectMembership)
            .filter(ProjectMembership.user_id == user_id)
            .first()
        )
        if m:
            project_id = m.project_id
            user.active_project_id = project_id
            session.commit()

    if not project_id:
        raise HTTPException(status_code=404, detail="No projects found. Create one first.")

    project = session.query(Project).filter(Project.id == project_id).first()
    membership = session.query(ProjectMembership).filter(
        ProjectMembership.project_id == project_id,
        ProjectMembership.user_id == user_id,
    ).first()
    return _serialize_project(project, membership)


# ── Members ────────────────────────────────────────────────────────────────────

@router.get("/{project_id}/members")
async def list_members(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _get_membership(project_id, user_id, session)
    memberships = (
        session.query(ProjectMembership)
        .filter(ProjectMembership.project_id == project_id)
        .all()
    )
    return [
        {
            "user_id": m.user_id,
            "username": m.user.username,
            "picture_url": m.user.oauth_picture_url,
            "role": m.role,
            "joined_at": m.joined_at.isoformat(),
        }
        for m in memberships
    ]


@router.delete("/{project_id}/members/{target_user_id}")
async def remove_member(
    project_id: int,
    target_user_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    my_m = _get_membership(project_id, user_id, session)

    # Only owners can remove others; anyone can remove themselves
    if target_user_id != user_id and my_m.role != "owner":
        raise HTTPException(status_code=403, detail="Only the owner can remove other members")

    # Owner cannot leave their own project — they must delete it instead
    target_m = session.query(ProjectMembership).filter(
        ProjectMembership.project_id == project_id,
        ProjectMembership.user_id == target_user_id,
    ).first()
    if not target_m:
        raise HTTPException(status_code=404, detail="Member not found")
    if target_m.role == "owner":
        raise HTTPException(status_code=400, detail="Owner cannot leave — delete the project instead")

    session.delete(target_m)
    session.commit()
    return {"message": "Member removed"}


# ── Invite tokens ──────────────────────────────────────────────────────────────

@router.post("/{project_id}/invites")
async def create_invite(
    project_id: int,
    body: InviteCreate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    m = _require_owner_or_editor(project_id, user_id, session)

    if body.role_to_grant not in ("editor", "viewer"):
        raise HTTPException(status_code=422, detail="role_to_grant must be 'editor' or 'viewer'")

    expires_at = None
    if body.expires_hours is not None:
        expires_at = datetime.datetime.utcnow() + datetime.timedelta(hours=body.expires_hours)

    invite = ProjectInvite(
        token=secrets.token_urlsafe(24),
        project_id=project_id,
        created_by=user_id,
        role_to_grant=body.role_to_grant,
        max_uses=body.max_uses,
        expires_at=expires_at,
    )
    session.add(invite)
    session.commit()
    return {
        "token": invite.token,
        "role_to_grant": invite.role_to_grant,
        "max_uses": invite.max_uses,
        "expires_at": invite.expires_at.isoformat() if invite.expires_at else None,
    }


@router.post("/join")
async def redeem_invite(
    body: InviteRedeem,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    invite = session.query(ProjectInvite).filter(
        ProjectInvite.token == body.token
    ).first()

    if not invite:
        raise HTTPException(status_code=404, detail="Invalid invite code")

    if invite.expires_at and datetime.datetime.utcnow() > invite.expires_at:
        raise HTTPException(status_code=410, detail="Invite code has expired")

    if invite.max_uses is not None and invite.use_count >= invite.max_uses:
        raise HTTPException(status_code=410, detail="Invite code has reached its maximum uses")

    # Already a member?
    existing = session.query(ProjectMembership).filter(
        ProjectMembership.project_id == invite.project_id,
        ProjectMembership.user_id == user_id,
    ).first()
    if existing:
        raise HTTPException(status_code=409, detail="Already a member of this project")

    membership = ProjectMembership(
        project_id=invite.project_id,
        user_id=user_id,
        role=invite.role_to_grant,
    )
    session.add(membership)
    invite.use_count += 1
    session.commit()

    project = session.query(Project).filter(Project.id == invite.project_id).first()
    return {
        "message": f"Joined project '{project.name}'",
        "project_id": project.id,
        "project_name": project.name,
        "role": invite.role_to_grant,
    }


@router.get("/{project_id}/invites")
async def list_invites(
    project_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _require_owner_or_editor(project_id, user_id, session)
    invites = session.query(ProjectInvite).filter(
        ProjectInvite.project_id == project_id
    ).all()
    return [
        {
            "id": inv.id,
            "token": inv.token,
            "role_to_grant": inv.role_to_grant,
            "use_count": inv.use_count,
            "max_uses": inv.max_uses,
            "expires_at": inv.expires_at.isoformat() if inv.expires_at else None,
        }
        for inv in invites
    ]


@router.delete("/{project_id}/invites/{invite_id}")
async def revoke_invite(
    project_id: int,
    invite_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _require_owner_or_editor(project_id, user_id, session)
    invite = session.query(ProjectInvite).filter(
        ProjectInvite.id == invite_id,
        ProjectInvite.project_id == project_id,
    ).first()
    if not invite:
        raise HTTPException(status_code=404, detail="Invite not found")
    session.delete(invite)
    session.commit()
    return {"message": "Invite revoked"}
