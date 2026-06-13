"""
FastAPI backend — multi-app hub (workout + tasks + budget).
All business logic lives in routers/. This file handles app setup only.
"""
import os
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.sessions import SessionMiddleware
from slowapi.errors import RateLimitExceeded
from slowapi import _rate_limit_exceeded_handler

from database import init_db, create_session, User, Workout, ScheduleEntry, get_data_dir, Project, ProjectMembership, Task, Plan
from auth import router as auth_router, SECRET_KEY
from exercises import load_exercises
from limiter import limiter

from routers.workouts import router as workouts_router
from routers.tasks import tasks_router, plans_router
from routers.budget import router as budget_router
from routers.projects import router as projects_router
from routers.agent import router as agent_router

# ── App factory ────────────────────────────────────────────────────────────────

app = FastAPI(title="Hub API", version="4.0.0")

# Rate limiter
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Session middleware (required for OAuth) — must come before CORS
app.add_middleware(
    SessionMiddleware,
    secret_key=SECRET_KEY,
    same_site="lax",
    https_only=False,
)

_frontend_url = os.environ.get("FRONTEND_URL", "http://localhost:8080")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[_frontend_url],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Routers
app.include_router(auth_router)
app.include_router(workouts_router)
app.include_router(tasks_router)
app.include_router(plans_router)
app.include_router(budget_router)
app.include_router(projects_router)
app.include_router(agent_router)

# ── Startup ────────────────────────────────────────────────────────────────────

DEFAULT_USERNAME = "default_user"
DEFAULT_EMAIL = "user@workout.app"


def ensure_default_user(session) -> User:
    user = session.query(User).filter(User.username == DEFAULT_USERNAME).first()
    if not user:
        user = User(username=DEFAULT_USERNAME, email=DEFAULT_EMAIL)
        session.add(user)
        session.commit()
        session.refresh(user)
    return user


def migrate_from_files_if_empty(session, user_id: int):
    """On first run, seed DB from workouts.csv and schedule.pkl if empty."""
    if session.query(Workout).filter(Workout.user_id == user_id).count() > 0:
        return

    data_dir = get_data_dir()
    workouts_csv = os.path.join(data_dir, "workouts.csv")
    if not os.path.exists(workouts_csv):
        print("No workouts.csv found — starting with empty database")
        return

    import pandas as pd

    workouts_df = pd.read_csv(workouts_csv)
    workout_map = {}
    for _, row in workouts_df.iterrows():
        w = Workout(
            user_id=user_id,
            name=str(row["name"]),
            goal=float(row["goal"]),
            units=str(row["units"]),
            at_park=bool(row["at_park"]),
        )
        session.add(w)
        session.flush()
        workout_map[row["name"]] = w.id

    print(f"Migrated {len(workout_map)} workouts from workouts.csv")

    schedule_pkl = os.path.join(data_dir, "schedule.pkl")
    if os.path.exists(schedule_pkl) and workout_map:
        try:
            schedule_df = pd.read_pickle(schedule_pkl)
        except Exception as e:
            print(f"Could not read schedule.pkl: {e}")
            session.commit()
            return
        if not schedule_df.empty:
            import math
            schedule_df["date"] = pd.to_datetime(schedule_df["date"]).dt.date
            count = 0
            for _, row in schedule_df.iterrows():
                if row["workout"] not in workout_map:
                    continue
                score = None if (
                    row["score"] is None or (isinstance(row["score"], float) and math.isnan(row["score"]))
                ) else float(row["score"])
                session.add(ScheduleEntry(
                    user_id=user_id,
                    workout_id=workout_map[row["workout"]],
                    date=row["date"],
                    score=score,
                ))
                count += 1
            print(f"Migrated {count} schedule entries from schedule.pkl")

    session.commit()


@app.on_event("startup")
async def startup_event():
    init_db()
    load_exercises()
    session = create_session()
    try:
        user = ensure_default_user(session)
        migrate_from_files_if_empty(session, user.id)
        ensure_personal_project(session, user.id)
    finally:
        session.close()


def ensure_personal_project(session, user_id: int):
    """
    Migration: ensure every user has a 'Personal' project, and assign any
    orphaned tasks/plans (project_id IS NULL) to it.
    """
    # Find or create the Personal project for this user
    personal = (
        session.query(Project)
        .join(ProjectMembership, Project.id == ProjectMembership.project_id)
        .filter(
            ProjectMembership.user_id == user_id,
            ProjectMembership.role == "owner",
            Project.name == "Personal",
        )
        .first()
    )
    if not personal:
        personal = Project(name="Personal", description="My personal workspace", owner_id=user_id)
        session.add(personal)
        session.flush()
        session.add(ProjectMembership(project_id=personal.id, user_id=user_id, role="owner"))

    # Assign orphaned tasks/plans to Personal
    session.query(Task).filter(
        Task.user_id == user_id, Task.project_id.is_(None)
    ).update({"project_id": personal.id}, synchronize_session=False)

    session.query(Plan).filter(
        Plan.user_id == user_id, Plan.project_id.is_(None)
    ).update({"project_id": personal.id}, synchronize_session=False)

    # Set active project if not set
    user = session.query(User).filter(User.id == user_id).first()
    if not user.active_project_id:
        user.active_project_id = personal.id

    session.commit()


@app.get("/")
async def root():
    return {"message": "Hub API is running", "version": "4.0.0"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
