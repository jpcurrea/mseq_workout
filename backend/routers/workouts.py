"""
Workout and exercise routes — extracted from main.py.
"""
import datetime
import math
import numpy as np
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError

from database import get_session, User, Workout, ScheduleEntry, get_data_dir
from dependencies import get_current_user_id
from exercises import _EXERCISES, _EXERCISES_IDX, EXERCISE_IMAGE_BASE
from limiter import limiter
from mseq import mseq

router = APIRouter(tags=["workouts"])

# ── M-sequence constants ───────────────────────────────────────────────────────

MSEQ_BASE_DEFAULT = 5
SUPPORTED_MSEQ_POWERS_BY_BASE = {
    2: set(range(2, 31)),
    3: set(range(2, 8)),
    5: {2, 3, 4},
    9: {2},
}

# ── Pydantic schemas ───────────────────────────────────────────────────────────

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


class RoutineGenerationRequest(BaseModel):
    start_date: Optional[str] = None
    sequence_power: Optional[int] = 4
    minimum_interval_days: Optional[int] = 2
    mseq_base: Optional[int] = MSEQ_BASE_DEFAULT
    active_symbols: Optional[int] = 1


# ── Helpers ────────────────────────────────────────────────────────────────────

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
    allowed_powers = SUPPORTED_MSEQ_POWERS_BY_BASE[mseq_base]
    if sequence_power not in allowed_powers:
        allowed_sorted = ", ".join(str(p) for p in sorted(allowed_powers))
        raise HTTPException(
            status_code=422,
            detail=f"sequence_power={sequence_power} is unsupported for mseq_base={mseq_base}. Allowed: {allowed_sorted}",
        )
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
    daily_workout_load = [0] * schedule_span_days

    for num in range(workout_count):
        try:
            seq = mseq(mseq_base, sequence_power, whichSeq=num + 1, shift=0, raw=True)
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
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
    min_count, max_count = min(counts), max(counts)
    min_daily_load, max_daily_load = min(daily_workout_load), max(daily_workout_load)

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
        "overall_workouts_per_day_range": {"min": float(min_daily_load), "max": float(max_daily_load)},
        "per_workout_mean_workouts_per_day": per_workout_mean_rate,
        "per_workout_workouts_per_day_range": per_workout_range,
        "per_workout_mean_days_between_sessions": mean_days_between_value,
        "per_workout_days_between_sessions_range": days_between_range,
    }


# ── Workout endpoints ──────────────────────────────────────────────────────────

@router.get("/workouts", response_model=List[WorkoutSchema])
async def get_workouts(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    workouts = session.query(Workout).filter(Workout.user_id == user_id).all()
    return [
        WorkoutSchema(
            name=w.name, goal=w.goal, units=w.units, at_park=w.at_park,
            exercise_id=w.exercise_id,
        )
        for w in workouts
    ]


@router.get("/today", response_model=List[WorkoutScheduleItem])
async def get_today_workouts(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
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
            date=entry.date.strftime("%Y-%m-%d"),
            workout=workout.name,
            score=entry.score,
            units=workout.units,
            at_park=workout.at_park,
            goal=workout.goal,
            exercise_id=workout.exercise_id,
        )
        for entry, workout in entries
    ]


@router.get("/schedule/{date}", response_model=List[WorkoutScheduleItem])
async def get_workouts_for_date(
    date: str,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    try:
        target_date = datetime.datetime.strptime(date, "%Y-%m-%d").date()
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
            date=entry.date.strftime("%Y-%m-%d"),
            workout=workout.name,
            score=entry.score,
            units=workout.units,
            at_park=workout.at_park,
            goal=workout.goal,
            exercise_id=workout.exercise_id,
        )
        for entry, workout in entries
    ]


@router.post("/update-score")
@limiter.limit("60/minute")
async def update_workout_score(
    request: Request,
    update: WorkoutUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    try:
        target_date = datetime.datetime.strptime(update.date, "%Y-%m-%d").date()
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")

    workout = session.query(Workout).filter(
        Workout.user_id == user_id, Workout.name == update.workout
    ).first()
    if not workout:
        raise HTTPException(status_code=404, detail="Workout not found")

    entry = session.query(ScheduleEntry).filter(
        ScheduleEntry.user_id == user_id,
        ScheduleEntry.workout_id == workout.id,
        ScheduleEntry.date == target_date,
    ).first()
    if not entry:
        raise HTTPException(status_code=404, detail="Workout not found for this date")

    entry.score = update.score
    session.commit()
    return {"message": "Score updated successfully"}


@router.post("/generate-routine")
@limiter.limit("10/minute")
async def generate_new_routine(
    request: Request,
    request_body: RoutineGenerationRequest,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    workouts = session.query(Workout).filter(Workout.user_id == user_id).all()
    if not workouts:
        raise HTTPException(
            status_code=400,
            detail="No workouts found — add workouts before generating a routine",
        )

    sequence_power = request_body.sequence_power or 4
    minimum_interval_days = request_body.minimum_interval_days or 2
    mseq_base = request_body.mseq_base or MSEQ_BASE_DEFAULT
    active_symbols = request_body.active_symbols or 1
    _validate_generation_params(sequence_power, minimum_interval_days, mseq_base, active_symbols)

    num_frames = mseq_base ** sequence_power - 1
    if request_body.start_date:
        try:
            base = datetime.datetime.strptime(request_body.start_date, "%Y-%m-%d").date()
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid start date format. Use YYYY-MM-DD")
    else:
        base = datetime.date.today()

    date_list = [base + datetime.timedelta(days=minimum_interval_days * x) for x in range(num_frames)]
    session.query(ScheduleEntry).filter(ScheduleEntry.user_id == user_id).delete()

    new_entries = []
    for num, workout in enumerate(workouts):
        shift = np.random.randint(0, num_frames - 1)
        try:
            seq = mseq(mseq_base, sequence_power, whichSeq=num + 1, shift=shift, raw=True)
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
        for i in range(num_frames):
            if 1 <= int(seq[i]) <= active_symbols:
                new_entries.append(ScheduleEntry(
                    user_id=user_id,
                    workout_id=workout.id,
                    date=date_list[i],
                    score=None,
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
        return {"message": "New routine generated successfully", "total_workouts": 0, "date_range": {}, "stats": stats}

    all_dates = [e.date for e in new_entries]
    return {
        "message": "New routine generated successfully",
        "total_workouts": len(new_entries),
        "date_range": {
            "start": min(all_dates).strftime("%Y-%m-%d"),
            "end": max(all_dates).strftime("%Y-%m-%d"),
        },
        "stats": stats,
    }


@router.get("/mseq/stats")
@router.get("/schedule/stats")
async def get_schedule_stats(
    sequence_power: int = 4,
    minimum_interval_days: int = 2,
    mseq_base: int = MSEQ_BASE_DEFAULT,
    active_symbols: int = 1,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    _validate_generation_params(sequence_power, minimum_interval_days, mseq_base, active_symbols)
    workout_count = session.query(Workout).filter(Workout.user_id == user_id).count()
    return _compute_mseq_rate_stats(
        workout_count=workout_count,
        sequence_power=sequence_power,
        minimum_interval_days=minimum_interval_days,
        mseq_base=mseq_base,
        active_symbols=active_symbols,
    )


@router.post("/workouts")
@limiter.limit("30/minute")
async def create_workout(
    request: Request,
    workout: WorkoutCreate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    existing = session.query(Workout).filter(
        Workout.user_id == user_id, Workout.name == workout.name
    ).first()
    if existing:
        raise HTTPException(status_code=400, detail="Workout with this name already exists")
    new_workout = Workout(
        user_id=user_id,
        name=workout.name,
        goal=workout.goal,
        units=workout.units,
        at_park=workout.at_park,
        exercise_id=workout.exercise_id,
    )
    session.add(new_workout)
    session.commit()
    return {"message": "Workout created successfully", "workout": workout.dict()}


@router.put("/workouts/{workout_name}")
@limiter.limit("30/minute")
async def update_workout(
    request: Request,
    workout_name: str,
    workout: WorkoutUpdateRequest,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    existing = session.query(Workout).filter(
        Workout.user_id == user_id, Workout.name == workout_name
    ).first()
    if not existing:
        raise HTTPException(status_code=404, detail="Workout not found")

    if workout.new_name and workout.new_name.strip():
        new_name = workout.new_name.strip()
        if new_name != existing.name:
            duplicate = session.query(Workout).filter(
                Workout.user_id == user_id,
                Workout.name == new_name,
                Workout.id != existing.id,
            ).first()
            if duplicate:
                raise HTTPException(status_code=400, detail="Workout with this name already exists")
        existing.name = new_name

    existing.goal = workout.goal
    existing.units = workout.units
    existing.at_park = workout.at_park
    existing.exercise_id = workout.exercise_id
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        raise HTTPException(status_code=400, detail="Workout with this name already exists")
    return {"message": "Workout updated successfully"}


@router.delete("/workouts/{workout_name}")
@limiter.limit("30/minute")
async def delete_workout(
    request: Request,
    workout_name: str,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    existing = session.query(Workout).filter(
        Workout.user_id == user_id, Workout.name == workout_name
    ).first()
    if not existing:
        raise HTTPException(status_code=404, detail="Workout not found")
    session.delete(existing)
    session.commit()
    return {"message": "Workout deleted successfully"}


@router.get("/workouts/{workout_name}/history")
async def get_workout_history(
    workout_name: str,
    limit: int = 20,
    since: Optional[str] = None,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    workout = session.query(Workout).filter(
        Workout.user_id == user_id, Workout.name == workout_name
    ).first()
    if not workout:
        raise HTTPException(status_code=404, detail="Workout not found")

    since_date: Optional[datetime.date] = None
    if since:
        try:
            since_date = datetime.date.fromisoformat(since)
        except ValueError:
            raise HTTPException(status_code=422, detail="since must be YYYY-MM-DD")

    query = session.query(ScheduleEntry).filter(
        ScheduleEntry.user_id == user_id,
        ScheduleEntry.workout_id == workout.id,
        ScheduleEntry.score.isnot(None),
    )
    if since_date:
        query = query.filter(ScheduleEntry.date >= since_date)

    entries = query.order_by(ScheduleEntry.date.desc()).limit(limit).all()
    return [{"date": e.date.strftime("%Y-%m-%d"), "score": e.score} for e in entries]


@router.get("/workouts/{workout_name}/interval-distribution")
async def get_workout_interval_distribution(
    workout_name: str,
    max_days: int = 60,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    if max_days < 2 or max_days > 365:
        raise HTTPException(status_code=422, detail="max_days must be between 2 and 365")

    workout = session.query(Workout).filter(
        Workout.user_id == user_id, Workout.name == workout_name
    ).first()
    if not workout:
        raise HTTPException(status_code=404, detail="Workout not found")

    entries = (
        session.query(ScheduleEntry)
        .filter(ScheduleEntry.user_id == user_id, ScheduleEntry.workout_id == workout.id)
        .order_by(ScheduleEntry.date.asc())
        .all()
    )

    if len(entries) < 2:
        return {"workout": workout_name, "interval_count": 0, "intervals": [], "bins": []}

    intervals = []
    bins: Dict[int, int] = {}
    for i in range(1, len(entries)):
        days = (entries[i].date - entries[i - 1].date).days
        if days <= 0:
            continue
        clipped = min(days, max_days)
        intervals.append(clipped)
        bins[clipped] = bins.get(clipped, 0) + 1

    return {
        "workout": workout_name,
        "interval_count": len(intervals),
        "intervals": intervals,
        "bins": [{"days": d, "count": bins[d]} for d in sorted(bins)],
    }


@router.get("/export")
async def export_schedule_csv(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
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
            entry.date.strftime("%Y-%m-%d"),
            workout.name,
            entry.score if entry.score is not None else "",
            workout.goal,
            workout.units,
            workout.at_park,
        ])
    output.seek(0)
    return StreamingResponse(
        iter([output.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=workout_history.csv"},
    )


# ── Exercise endpoints ─────────────────────────────────────────────────────────

@router.get("/exercises/search")
async def search_exercises(
    q: str = "",
    limit: int = 10,
    user_id: int = Depends(get_current_user_id),
):
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
                "imageUrl": f"{EXERCISE_IMAGE_BASE}/{ex['id']}/0.jpg",
            })
            if len(results) >= limit:
                break
    return results


@router.get("/exercises/{exercise_id}")
async def get_exercise(
    exercise_id: str,
    user_id: int = Depends(get_current_user_id),
):
    ex = _EXERCISES_IDX.get(exercise_id)
    if not ex:
        raise HTTPException(status_code=404, detail="Exercise not found")
    return {**ex, "imageUrl": f"{EXERCISE_IMAGE_BASE}/{ex['id']}/0.jpg"}
