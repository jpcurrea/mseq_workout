"""
FastAPI backend for workout routine mobile app
Phase 3: OAuth authentication wired in
"""

from fastapi import FastAPI, HTTPException, Depends, Request
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from starlette.middleware.sessions import SessionMiddleware
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from pydantic import BaseModel
from typing import List, Optional
import datetime
import json
import numpy as np
import secrets
import sys
import os

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from mseq import mseq
from database import init_db, get_session, create_session, User, Workout, ScheduleEntry, get_data_dir
from auth import router as auth_router, SECRET_KEY, ALGORITHM

from sqlalchemy.orm import Session
from jose import jwt, JWTError

# ── Exercise database ──────────────────────────────────────────────────────────
_EXERCISES: list = []
_EXERCISES_IDX: dict = {}

def _load_exercises():
    global _EXERCISES, _EXERCISES_IDX
    # Try data dir first (persistent disk), then fall back to the repo path beside main.py
    path = os.path.join(get_data_dir(), "exercises.json")
    if not os.path.exists(path):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "exercises.json")
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            _EXERCISES = json.load(f)
        _EXERCISES_IDX = {ex["id"]: ex for ex in _EXERCISES}
        print(f"Loaded {len(_EXERCISES)} exercises from exercises.json")
    else:
        print("Warning: exercises.json not found — exercise autocomplete disabled")

_EXERCISE_IMAGE_BASE = (
    "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises"
)

# Rate limiter
limiter = Limiter(key_func=get_remote_address)

app = FastAPI(title="Workout Routine API", version="3.0.0")
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Session middleware required for OAuth (must be added before CORSMiddleware)
app.add_middleware(
    SessionMiddleware,
    secret_key=SECRET_KEY,
    same_site="lax",
    https_only=False,  # Set to True in production behind HTTPS
)

# CORS — restrict to the frontend origin
_frontend_url = os.environ.get('FRONTEND_URL', 'http://localhost:8080')
app.add_middleware(
    CORSMiddleware,
    allow_origins=[_frontend_url],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include auth routes (/auth/google/login, /auth/google/callback, etc.)
app.include_router(auth_router)

# JWT bearer token dependency
_security = HTTPBearer(auto_error=False)

def get_current_user_id(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_security),
    session: Session = Depends(get_session)
) -> int:
    """Return user_id from JWT token. Raises 401 if no valid token provided."""
    if credentials:
        try:
            payload = jwt.decode(credentials.credentials, SECRET_KEY, algorithms=[ALGORITHM])
            return int(payload.get("sub"))
        except (JWTError, ValueError):
            raise HTTPException(status_code=401, detail="Invalid or expired token")
    raise HTTPException(status_code=401, detail="Authentication required")

# Pydantic models for API requests/responses
class WorkoutSchema(BaseModel):
    name: str
    goal: float
    units: str
    at_park: bool
    exercise_id: Optional[str] = None

class WorkoutScheduleItem(BaseModel):
    date: str
    workout: str
    score: Optional[float] = None
    units: str
    at_park: bool
    goal: float
    exercise_id: Optional[str] = None

class WorkoutUpdate(BaseModel):
    workout: str
    date: str
    score: float

class RoutineGenerationRequest(BaseModel):
    start_date: Optional[str] = None
    sequence_power: Optional[int] = 4

class WorkoutCreate(BaseModel):
    name: str
    goal: float
    units: str
    at_park: bool
    exercise_id: Optional[str] = None

class WorkoutUpdateRequest(BaseModel):
    goal: float
    units: str
    at_park: bool
    exercise_id: Optional[str] = None

# Single-user mode: all data belongs to the default user
DEFAULT_USERNAME = "default_user"
DEFAULT_EMAIL = "user@workout.app"

def ensure_default_user(session: Session) -> User:
    """Get or create the single default user."""
    user = session.query(User).filter(User.username == DEFAULT_USERNAME).first()
    if not user:
        user = User(username=DEFAULT_USERNAME, email=DEFAULT_EMAIL)
        session.add(user)
        session.commit()
        session.refresh(user)
    return user

def get_default_user_id(session: Session) -> int:
    return ensure_default_user(session).id

def migrate_from_files_if_empty(session: Session, user_id: int):
    """On first run, seed database from workouts.csv and schedule.pkl if DB is empty."""
    if session.query(Workout).filter(Workout.user_id == user_id).count() > 0:
        return  # Already populated

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
            name=str(row['name']),
            goal=float(row['goal']),
            units=str(row['units']),
            at_park=bool(row['at_park'])
        )
        session.add(w)
        session.flush()
        workout_map[row['name']] = w.id

    print(f"Migrated {len(workout_map)} workouts from workouts.csv")

    schedule_pkl = os.path.join(data_dir, "schedule.pkl")
    if os.path.exists(schedule_pkl) and workout_map:
        try:
            schedule_df = pd.read_pickle(schedule_pkl)
        except Exception as e:
            print(f"⚠️  Could not read schedule.pkl (pandas version mismatch): {e}")
            print("   Schedule not migrated — use 'Generate Routine' in the app to create a new one.")
            session.commit()
            return
        if not schedule_df.empty:
            schedule_df['date'] = pd.to_datetime(schedule_df['date']).dt.date
            count = 0
            for _, row in schedule_df.iterrows():
                if row['workout'] not in workout_map:
                    continue
                import math
                score = None if (row['score'] is None or (isinstance(row['score'], float) and math.isnan(row['score']))) else float(row['score'])
                session.add(ScheduleEntry(
                    user_id=user_id,
                    workout_id=workout_map[row['workout']],
                    date=row['date'],
                    score=score
                ))
                count += 1
            print(f"Migrated {count} schedule entries from schedule.pkl")

    session.commit()

@app.on_event("startup")
async def startup_event():
    init_db()
    _load_exercises()
    session = create_session()
    try:
        user = ensure_default_user(session)
        migrate_from_files_if_empty(session, user.id)
    finally:
        session.close()

@app.get("/")
async def root():
    return {"message": "Workout Routine API is running"}

@app.get("/workouts", response_model=List[WorkoutSchema])
async def get_workouts(user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    workouts = session.query(Workout).filter(Workout.user_id == user_id).all()
    return [
        WorkoutSchema(
            name=w.name, goal=w.goal, units=w.units, at_park=w.at_park,
            exercise_id=w.exercise_id
        )
        for w in workouts
    ]

@app.get("/today", response_model=List[WorkoutScheduleItem])
async def get_today_workouts(user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    """Get today's workouts, or the most recent past day if none scheduled today."""
    today = datetime.date.today()

    entries = (
        session.query(ScheduleEntry, Workout)
        .join(Workout, ScheduleEntry.workout_id == Workout.id)
        .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date == today)
        .order_by(Workout.at_park)
        .all()
    )

    if not entries:
        latest = (
            session.query(ScheduleEntry.date)
            .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date < today)
            .order_by(ScheduleEntry.date.desc())
            .first()
        )
        if latest:
            entries = (
                session.query(ScheduleEntry, Workout)
                .join(Workout, ScheduleEntry.workout_id == Workout.id)
                .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date == latest.date)
                .order_by(Workout.at_park)
                .all()
            )

    return [
        WorkoutScheduleItem(
            date=entry.date.strftime('%Y-%m-%d'),
            workout=workout.name,
            score=entry.score,
            units=workout.units,
            at_park=workout.at_park,
            goal=workout.goal,
            exercise_id=workout.exercise_id
        )
        for entry, workout in entries
    ]

@app.get("/schedule/{date}", response_model=List[WorkoutScheduleItem])
async def get_workouts_for_date(date: str, user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    """Get workouts for a specific date (YYYY-MM-DD format)."""
    try:
        target_date = datetime.datetime.strptime(date, '%Y-%m-%d').date()
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")

    entries = (
        session.query(ScheduleEntry, Workout)
        .join(Workout, ScheduleEntry.workout_id == Workout.id)
        .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date == target_date)
        .order_by(Workout.at_park)
        .all()
    )

    if not entries:
        latest = (
            session.query(ScheduleEntry.date)
            .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date < target_date)
            .order_by(ScheduleEntry.date.desc())
            .first()
        )
        if latest:
            entries = (
                session.query(ScheduleEntry, Workout)
                .join(Workout, ScheduleEntry.workout_id == Workout.id)
                .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date == latest.date)
                .order_by(Workout.at_park)
                .all()
            )

    return [
        WorkoutScheduleItem(
            date=entry.date.strftime('%Y-%m-%d'),
            workout=workout.name,
            score=entry.score,
            units=workout.units,
            at_park=workout.at_park,
            goal=workout.goal,
            exercise_id=workout.exercise_id
        )
        for entry, workout in entries
    ]

@app.post("/update-score")
@limiter.limit("60/minute")
async def update_workout_score(request: Request, update: WorkoutUpdate, user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    """Update the score for a specific workout on a specific date."""
    try:
        target_date = datetime.datetime.strptime(update.date, '%Y-%m-%d').date()
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")

    workout = session.query(Workout).filter(
        Workout.user_id == user_id,
        Workout.name == update.workout
    ).first()
    if not workout:
        raise HTTPException(status_code=404, detail="Workout not found")

    entry = session.query(ScheduleEntry).filter(
        ScheduleEntry.user_id == user_id,
        ScheduleEntry.workout_id == workout.id,
        ScheduleEntry.date == target_date
    ).first()
    if not entry:
        raise HTTPException(status_code=404, detail="Workout not found for this date")

    entry.score = update.score
    session.commit()
    return {"message": "Score updated successfully"}

@app.post("/generate-routine")
@limiter.limit("10/minute")
async def generate_new_routine(request: Request, request_body: RoutineGenerationRequest, user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    """Generate a new workout routine using m-sequences."""
    workouts = session.query(Workout).filter(Workout.user_id == user_id).all()

    if not workouts:
        raise HTTPException(status_code=400, detail="No workouts found — add workouts before generating a routine")

    SEQUENCE_POWER = request_body.sequence_power or 4
    NUM_FRAMES = 5 ** SEQUENCE_POWER - 1

    if request_body.start_date:
        try:
            base = datetime.datetime.strptime(request_body.start_date, '%Y-%m-%d').date()
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid start date format. Use YYYY-MM-DD")
    else:
        base = datetime.date.today()

    date_list = [base + datetime.timedelta(days=2 * x) for x in range(NUM_FRAMES)]

    # Clear existing schedule for this user
    session.query(ScheduleEntry).filter(ScheduleEntry.user_id == user_id).delete()

    new_entries = []
    for num, workout in enumerate(workouts):
        shift = np.random.randint(0, NUM_FRAMES - 1)
        seq = mseq(5, SEQUENCE_POWER, whichSeq=num, shift=shift)
        for i in range(NUM_FRAMES):
            if seq[i] == 1:
                new_entries.append(ScheduleEntry(
                    user_id=user_id,
                    workout_id=workout.id,
                    date=date_list[i],
                    score=None
                ))

    session.add_all(new_entries)
    session.commit()

    if not new_entries:
        return {"message": "New routine generated successfully", "total_workouts": 0, "date_range": {}}

    all_dates = [e.date for e in new_entries]
    return {
        "message": "New routine generated successfully",
        "total_workouts": len(new_entries),
        "date_range": {
            "start": min(all_dates).strftime('%Y-%m-%d'),
            "end": max(all_dates).strftime('%Y-%m-%d')
        }
    }

@app.post("/workouts")
@limiter.limit("30/minute")
async def create_workout(request: Request, workout: WorkoutCreate, user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    """Add a new workout."""

    existing = session.query(Workout).filter(
        Workout.user_id == user_id,
        Workout.name == workout.name
    ).first()
    if existing:
        raise HTTPException(status_code=400, detail="Workout with this name already exists")

    new_workout = Workout(
        user_id=user_id,
        name=workout.name,
        goal=workout.goal,
        units=workout.units,
        at_park=workout.at_park,
        exercise_id=workout.exercise_id
    )
    session.add(new_workout)
    session.commit()
    return {"message": "Workout created successfully", "workout": workout.dict()}

@app.put("/workouts/{workout_name}")
@limiter.limit("30/minute")
async def update_workout(request: Request, workout_name: str, workout: WorkoutUpdateRequest, user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    """Update an existing workout's parameters."""

    existing = session.query(Workout).filter(
        Workout.user_id == user_id,
        Workout.name == workout_name
    ).first()
    if not existing:
        raise HTTPException(status_code=404, detail="Workout not found")

    existing.goal = workout.goal
    existing.units = workout.units
    existing.at_park = workout.at_park
    if workout.exercise_id is not None:
        existing.exercise_id = workout.exercise_id
    session.commit()
    return {"message": "Workout updated successfully"}

@app.delete("/workouts/{workout_name}")
@limiter.limit("30/minute")
async def delete_workout(request: Request, workout_name: str, user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    """Delete a workout."""

    existing = session.query(Workout).filter(
        Workout.user_id == user_id,
        Workout.name == workout_name
    ).first()
    if not existing:
        raise HTTPException(status_code=404, detail="Workout not found")

    session.delete(existing)
    session.commit()
    return {"message": "Workout deleted successfully"}

@app.get("/workouts/{workout_name}/history")
async def get_workout_history(
    workout_name: str,
    limit: int = 20,
    since: Optional[str] = None,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session)
):
    """Return past scored entries for a single workout, most recent first.

    Args:
        limit: max rows to return (ignored when since is provided, unless both supplied)
        since: ISO date string (YYYY-MM-DD); if provided, only entries on or after this date
    """
    workout = session.query(Workout).filter(
        Workout.user_id == user_id,
        Workout.name == workout_name
    ).first()
    if not workout:
        raise HTTPException(status_code=404, detail="Workout not found")

    since_date: Optional[date] = None
    if since:
        try:
            since_date = date.fromisoformat(since)
        except ValueError:
            raise HTTPException(status_code=422, detail="since must be YYYY-MM-DD")

    query = (
        session.query(ScheduleEntry)
        .filter(
            ScheduleEntry.user_id == user_id,
            ScheduleEntry.workout_id == workout.id,
            ScheduleEntry.score.isnot(None)
        )
    )
    if since_date:
        query = query.filter(ScheduleEntry.date >= since_date)

    entries = (
        query
        .order_by(ScheduleEntry.date.desc())
        .limit(limit)
        .all()
    )

    return [
        {"date": e.date.strftime('%Y-%m-%d'), "score": e.score}
        for e in entries
    ]

@app.get("/export")
async def export_schedule_csv(user_id: int = Depends(get_current_user_id), session: Session = Depends(get_session)):
    """Export full schedule history as a CSV file."""
    import csv
    import io


    entries = (
        session.query(ScheduleEntry, Workout)
        .join(Workout, ScheduleEntry.workout_id == Workout.id)
        .filter(ScheduleEntry.user_id == user_id)
        .order_by(ScheduleEntry.date, Workout.name)
        .all()
    )

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["date", "workout", "score", "goal", "units", "at_park"])
    for entry, workout in entries:
        writer.writerow([
            entry.date.strftime('%Y-%m-%d'),
            workout.name,
            entry.score if entry.score is not None else "",
            workout.goal,
            workout.units,
            workout.at_park
        ])

    output.seek(0)
    return StreamingResponse(
        iter([output.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=workout_history.csv"}
    )

# ── Exercise database endpoints ────────────────────────────────────────────────

@app.get("/exercises/search")
async def search_exercises(
    q: str = "",
    limit: int = 10,
    user_id: int = Depends(get_current_user_id),
):
    """Prefix/substring search against the bundled exercise database."""
    if not q.strip() or not _EXERCISES:
        return []
    q_lower = q.strip().lower()
    results = []
    for ex in _EXERCISES:
        if q_lower in ex.get("name", "").lower():
            results.append({
                "id": ex["id"],
                "name": ex["name"],
                "equipment": ex.get("equipment"),
                "primaryMuscles": ex.get("primaryMuscles", []),
                "imageUrl": f"{_EXERCISE_IMAGE_BASE}/{ex['id']}/0.jpg",
            })
            if len(results) >= limit:
                break
    return results


@app.get("/exercises/{exercise_id}")
async def get_exercise(
    exercise_id: str,
    user_id: int = Depends(get_current_user_id),
):
    """Return full exercise record including instructions."""
    ex = _EXERCISES_IDX.get(exercise_id)
    if not ex:
        raise HTTPException(status_code=404, detail="Exercise not found")
    return {
        **ex,
        "imageUrl": f"{_EXERCISE_IMAGE_BASE}/{ex['id']}/0.jpg",
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)