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
from typing import List, Optional, Dict, Any
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
MSEQ_BASE_DEFAULT = 5

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
    minimum_interval_days: Optional[int] = 2
    mseq_base: Optional[int] = MSEQ_BASE_DEFAULT
    active_symbols: Optional[int] = 1


def _validate_generation_params(
    sequence_power: int,
    minimum_interval_days: int,
    mseq_base: int,
    active_symbols: int,
):
    if sequence_power < 2 or sequence_power > 6:
        raise HTTPException(status_code=422, detail="sequence_power must be between 2 and 6")
    if minimum_interval_days < 1 or minimum_interval_days > 14:
        raise HTTPException(status_code=422, detail="minimum_interval_days must be between 1 and 14")
    if mseq_base not in (2, 3, 5, 9):
        raise HTTPException(status_code=422, detail="mseq_base must be 2, 3, 5, or 9")
    if active_symbols < 1 or active_symbols > (mseq_base - 1):
        raise HTTPException(
            status_code=422,
            detail=f"active_symbols must be between 1 and {mseq_base - 1}",
        )


def _compute_mseq_rate_stats(
    *,
    workout_count: int,
    sequence_power: int,
    minimum_interval_days: int,
    mseq_base: int,
    active_symbols: int,
) -> Dict[str, Any]:
    """Compute schedule/rate statistics for m-sequence parameters."""
    num_frames = mseq_base ** sequence_power - 1
    schedule_span_days = (num_frames - 1) * minimum_interval_days + 1

    if workout_count <= 0:
        return {
            "sequence_power": sequence_power,
            "minimum_interval_days": minimum_interval_days,
            "mseq_base": mseq_base,
            "active_symbols": active_symbols,
            "num_workouts": 0,
            "num_frames": num_frames,
            "schedule_span_days": schedule_span_days,
            "overall_mean_workouts_per_day": 0.0,
            "overall_workouts_per_day_range": {"min": 0.0, "max": 0.0},
            "per_workout_mean_workouts_per_day": 0.0,
            "per_workout_workouts_per_day_range": {"min": 0.0, "max": 0.0},
            "per_workout_mean_days_between_sessions": None,
            "per_workout_days_between_sessions_range": {"min": None, "max": None},
        }

    counts: List[int] = []
    per_workout_rates: List[float] = []
    mean_days_between: List[float] = []
    min_gap_days_all: List[float] = []
    max_gap_days_all: List[float] = []
    daily_workout_load = [0 for _ in range(schedule_span_days)]

    for num in range(workout_count):
        seq = mseq(mseq_base, sequence_power, whichSeq=num, shift=0, raw=True)
        indices = [i for i in range(num_frames) if 1 <= int(seq[i]) <= active_symbols]

        count = len(indices)
        counts.append(count)
        per_workout_rates.append(count / schedule_span_days)

        for idx in indices:
            day_index = idx * minimum_interval_days
            if 0 <= day_index < schedule_span_days:
                daily_workout_load[day_index] += 1

        if len(indices) >= 2:
            gaps = [
                (indices[i + 1] - indices[i]) * minimum_interval_days
                for i in range(len(indices) - 1)
            ]
            mean_days_between.append(sum(gaps) / len(gaps))
            min_gap_days_all.append(min(gaps))
            max_gap_days_all.append(max(gaps))

    total_workouts = sum(counts)
    overall_mean_rate = total_workouts / schedule_span_days
    per_workout_mean_rate = sum(per_workout_rates) / len(per_workout_rates)

    min_count = min(counts)
    max_count = max(counts)
    min_daily_load = min(daily_workout_load)
    max_daily_load = max(daily_workout_load)
    overall_range = {
        "min": float(min_daily_load),
        "max": float(max_daily_load),
    }

    # If m-sequence balancing makes per-workout mean rates identical,
    # derive range from observed cadence extremes (1 / max_gap .. 1 / min_gap).
    if min_gap_days_all and max_gap_days_all:
        per_workout_range = {
            "min": 1.0 / max(max_gap_days_all),
            "max": 1.0 / min(min_gap_days_all),
        }
    else:
        per_workout_range = {
            "min": min_count / schedule_span_days,
            "max": max_count / schedule_span_days,
        }

    if mean_days_between:
        mean_days_between_value = sum(mean_days_between) / len(mean_days_between)
        days_between_range = {
            "min": min(mean_days_between),
            "max": max(mean_days_between),
        }
    else:
        mean_days_between_value = None
        days_between_range = {"min": None, "max": None}

    return {
        "sequence_power": sequence_power,
        "minimum_interval_days": minimum_interval_days,
        "mseq_base": mseq_base,
        "active_symbols": active_symbols,
        "num_workouts": workout_count,
        "num_frames": num_frames,
        "schedule_span_days": schedule_span_days,
        "overall_mean_workouts_per_day": overall_mean_rate,
        "overall_workouts_per_day_range": overall_range,
        "per_workout_mean_workouts_per_day": per_workout_mean_rate,
        "per_workout_workouts_per_day_range": per_workout_range,
        "per_workout_mean_days_between_sessions": mean_days_between_value,
        "per_workout_days_between_sessions_range": days_between_range,
    }

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
    new_name: Optional[str] = None

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
    """Get today's workouts. Falls back to most recent past day, then nearest future day."""
    today = datetime.date.today()

    entries = (
        session.query(ScheduleEntry, Workout)
        .join(Workout, ScheduleEntry.workout_id == Workout.id)
        .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date == today)
        .order_by(Workout.at_park)
        .all()
    )

    if not entries:
        fallback = (
            session.query(ScheduleEntry.date)
            .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date < today)
            .order_by(ScheduleEntry.date.desc())
            .first()
        )
        if not fallback:
            # Nothing in the past — find the next upcoming date
            fallback = (
                session.query(ScheduleEntry.date)
                .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date > today)
                .order_by(ScheduleEntry.date.asc())
                .first()
            )
        if fallback:
            entries = (
                session.query(ScheduleEntry, Workout)
                .join(Workout, ScheduleEntry.workout_id == Workout.id)
                .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date == fallback.date)
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
        fallback = (
            session.query(ScheduleEntry.date)
            .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date < target_date)
            .order_by(ScheduleEntry.date.desc())
            .first()
        )
        if not fallback:
            # Nothing in the past — find the next upcoming date
            fallback = (
                session.query(ScheduleEntry.date)
                .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date > target_date)
                .order_by(ScheduleEntry.date.asc())
                .first()
            )
        if fallback:
            entries = (
                session.query(ScheduleEntry, Workout)
                .join(Workout, ScheduleEntry.workout_id == Workout.id)
                .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.date == fallback.date)
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

    sequence_power = request_body.sequence_power or 4
    minimum_interval_days = request_body.minimum_interval_days or 2
    mseq_base = request_body.mseq_base or MSEQ_BASE_DEFAULT
    active_symbols = request_body.active_symbols or 1
    _validate_generation_params(sequence_power, minimum_interval_days, mseq_base, active_symbols)

    num_frames = mseq_base ** sequence_power - 1

    if request_body.start_date:
        try:
            base = datetime.datetime.strptime(request_body.start_date, '%Y-%m-%d').date()
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid start date format. Use YYYY-MM-DD")
    else:
        base = datetime.date.today()

    date_list = [base + datetime.timedelta(days=minimum_interval_days * x) for x in range(num_frames)]

    # Clear existing schedule for this user
    session.query(ScheduleEntry).filter(ScheduleEntry.user_id == user_id).delete()

    new_entries = []
    for num, workout in enumerate(workouts):
        shift = np.random.randint(0, num_frames - 1)
        seq = mseq(mseq_base, sequence_power, whichSeq=num, shift=shift, raw=True)
        for i in range(num_frames):
            if 1 <= int(seq[i]) <= active_symbols:
                new_entries.append(ScheduleEntry(
                    user_id=user_id,
                    workout_id=workout.id,
                    date=date_list[i],
                    score=None
                ))

    session.add_all(new_entries)
    session.commit()

    stats = _compute_mseq_rate_stats(
        workout_count=len(workouts),
        sequence_power=sequence_power,
        minimum_interval_days=minimum_interval_days,
        mseq_base=mseq_base,
        active_symbols=active_symbols,
    )

    if not new_entries:
        return {
            "message": "New routine generated successfully",
            "total_workouts": 0,
            "date_range": {},
            "stats": stats,
        }

    all_dates = [e.date for e in new_entries]
    return {
        "message": "New routine generated successfully",
        "total_workouts": len(new_entries),
        "date_range": {
            "start": min(all_dates).strftime('%Y-%m-%d'),
            "end": max(all_dates).strftime('%Y-%m-%d')
        },
        "stats": stats,
    }


@app.get("/mseq/stats")
@app.get("/schedule/stats")
async def get_schedule_stats(
    sequence_power: int = 4,
    minimum_interval_days: int = 2,
    mseq_base: int = MSEQ_BASE_DEFAULT,
    active_symbols: int = 1,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Return m-sequence schedule/rate stats for the current user's workout count."""
    _validate_generation_params(sequence_power, minimum_interval_days, mseq_base, active_symbols)
    workout_count = session.query(Workout).filter(Workout.user_id == user_id).count()
    return _compute_mseq_rate_stats(
        workout_count=workout_count,
        sequence_power=sequence_power,
        minimum_interval_days=minimum_interval_days,
        mseq_base=mseq_base,
        active_symbols=active_symbols,
    )

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

    if workout.new_name and workout.new_name.strip():
        existing.name = workout.new_name.strip()
    existing.goal = workout.goal
    existing.units = workout.units
    existing.at_park = workout.at_park
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

    since_date: Optional[datetime.date] = None
    if since:
        try:
            since_date = datetime.date.fromisoformat(since)
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


@app.get("/workouts/{workout_name}/interval-distribution")
async def get_workout_interval_distribution(
    workout_name: str,
    max_days: int = 60,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Return histogram data for days-between-sessions for one workout."""
    if max_days < 2 or max_days > 365:
        raise HTTPException(status_code=422, detail="max_days must be between 2 and 365")

    workout = session.query(Workout).filter(
        Workout.user_id == user_id,
        Workout.name == workout_name
    ).first()
    if not workout:
        raise HTTPException(status_code=404, detail="Workout not found")

    entries = (
        session.query(ScheduleEntry)
        .filter(
            ScheduleEntry.user_id == user_id,
            ScheduleEntry.workout_id == workout.id,
        )
        .order_by(ScheduleEntry.date.asc())
        .all()
    )

    if len(entries) < 2:
        return {
            "workout": workout_name,
            "interval_count": 0,
            "intervals": [],
            "bins": [],
        }

    intervals = []
    bins = {}
    for i in range(1, len(entries)):
        days = (entries[i].date - entries[i - 1].date).days
        if days <= 0:
            continue
        clipped = min(days, max_days)
        intervals.append(clipped)
        bins[clipped] = bins.get(clipped, 0) + 1

    bins_list = [
        {"days": day, "count": bins[day]}
        for day in sorted(bins.keys())
    ]

    return {
        "workout": workout_name,
        "interval_count": len(intervals),
        "intervals": intervals,
        "bins": bins_list,
    }

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