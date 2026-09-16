"""
Workout and exercise routes — extracted from main.py.
"""
import datetime
import math
import numpy as np
from functools import lru_cache
from typing import List, Optional, Dict, Any, Tuple

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError

from database import get_session, User, Workout, ScheduleEntry, get_data_dir
from dependencies import get_current_user_id
import exercises as exercise_db
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


# ── M-sequence helpers ─────────────────────────────────────────────────────────

@lru_cache(maxsize=512)
def _mseq_symbols(mseq_base: int, sequence_power: int, which_seq: int) -> Tuple[int, ...]:
    """Cached raw m-sequence. whichSeq wraps internally once it exceeds the tap count."""
    return tuple(int(v) for v in mseq(mseq_base, sequence_power, whichSeq=which_seq, shift=0, raw=True))


@lru_cache(maxsize=64)
def _distinct_sequence_count(mseq_base: int, sequence_power: int) -> int:
    """How many workouts this base/power can schedule before two of them collide.

    The generator assigns sequences sequentially: workout N uses whichSeq=N+1.
    So what matters is the length of the leading run of distinct sequences, NOT
    the total number of distinct sequences the tap table could ever produce.
    Two separate effects cut that run short:

    1. mseq() wraps whichSeq modulo its tap-table size, so once past the table
       the sequences repeat earlier ones exactly.
    2. Some tap tables contain duplicate entries. Base 3 power 5 is the known
       case: taps 1 and 2 are identical, so whichSeq 1 and 2 produce the same
       sequence and this returns 1 even though ~20 distinct sequences exist
       further along the table.

    Case 2 looks like a bug and is deliberately not "fixed" here. Skipping
    duplicate taps would make base 3 power 5 usable, but it would also renumber
    the sequences for every base/power and silently rewrite the schedule of
    every existing user on their next generation. Treating the affected
    configuration as low-capacity is the conservative, non-breaking choice.
    """
    seen: List[Tuple[int, ...]] = []
    for which_seq in range(1, 65):
        seq = _mseq_symbols(mseq_base, sequence_power, which_seq)
        if seq in seen:
            break
        seen.append(seq)
    return len(seen)


def _active_slot_counts(
    *, mseq_base: int, sequence_power: int, active_symbols: int, workout_count: int
) -> List[int]:
    """Number of scheduled slots each workout receives.

    Counted from the real sequences rather than a closed form: bases 2/3/5 are
    prime and produce balanced sequences, but base 9 is not a prime field under
    this implementation and its symbols are noticeably unbalanced.
    """
    counts = []
    for num in range(workout_count):
        seq = _mseq_symbols(mseq_base, sequence_power, num + 1)
        counts.append(sum(1 for v in seq if 1 <= v <= active_symbols))
    return counts


@lru_cache(maxsize=2048)
def _frame_load_profile(
    mseq_base: int, sequence_power: int, active_symbols: int, workout_count: int
) -> Tuple[int, int, Tuple[Tuple[int, int], ...]]:
    """How many workouts land together on each training day.

    Each active frame maps to its own calendar day (day = frame * interval, and
    distinct frames never collide for interval >= 1), so this shape depends only
    on base/power/active_symbols/workout_count — the interval merely stretches
    the span. That makes it safe to cache independently of the interval.

    Returns (training_day_count, total_slots, ((workouts_on_day, how_many_days), ...)).
    """
    num_frames = mseq_base ** sequence_power - 1
    per_frame = [0] * num_frames
    for num in range(workout_count):
        seq = _mseq_symbols(mseq_base, sequence_power, num + 1)
        for i in range(num_frames):
            if 1 <= seq[i] <= active_symbols:
                per_frame[i] += 1
    histogram: Dict[int, int] = {}
    training_days = 0
    total_slots = 0
    for load in per_frame:
        if load > 0:
            training_days += 1
            total_slots += load
            histogram[load] = histogram.get(load, 0) + 1
    return training_days, total_slots, tuple(sorted(histogram.items()))


def _session_shape(
    *, mseq_base: int, sequence_power: int, active_symbols: int,
    workout_count: int, minimum_interval_days: int, schedule_span_days: int,
) -> Dict[str, Any]:
    """The schedule described the way people actually talk about training.

    Users say "3 workouts a day, every other day" — not "10.5 sessions a week" —
    so this translates the m-sequence into that vocabulary. Crucially it also
    reports the spread: the load varies day to day, so quoting only the mean
    would promise a regularity the m-sequence does not provide.
    """
    training_days, total_slots, histogram = _frame_load_profile(
        mseq_base, sequence_power, active_symbols, workout_count
    )
    if training_days == 0:
        return {
            "training_days": 0,
            "rest_day_pct": 100,
            "train_every_n_days": None,
            "mean_workouts_per_training_day": 0.0,
            "workouts_per_training_day_range": {"min": 0, "max": 0},
            "workouts_per_training_day_distribution": {},
            "varies": False,
        }

    loads = [load for load, _ in histogram]
    return {
        "training_days": training_days,
        "rest_day_pct": round(100 * (schedule_span_days - training_days) / schedule_span_days),
        "train_every_n_days": round(schedule_span_days / training_days, 2),
        "mean_workouts_per_training_day": round(total_slots / training_days, 2),
        "workouts_per_training_day_range": {"min": min(loads), "max": max(loads)},
        "workouts_per_training_day_distribution": {
            str(load): days for load, days in histogram
        },
        "varies": len(loads) > 1,
    }


def enumerate_routine_configurations(
    *,
    workout_count: int,
    mseq_base: Optional[int] = None,
    minimum_interval_days: Optional[int] = None,
    max_span_days: Optional[int] = None,
) -> List[Dict[str, Any]]:
    """Every valid m-sequence configuration, with its resulting training rates.

    This is the same parameter space the generation UI exposes through its
    dropdowns, evaluated with the same maths behind the UI's live stats card.
    """
    if workout_count <= 0:
        raise HTTPException(status_code=422, detail="Add at least one workout before choosing a schedule")

    bases = (mseq_base,) if mseq_base is not None else (2, 3, 5, 9)
    for base in bases:
        if base not in SUPPORTED_MSEQ_POWERS_BY_BASE:
            raise HTTPException(status_code=422, detail="mseq_base must be 2, 3, 5, or 9")
    if minimum_interval_days is not None and not (1 <= minimum_interval_days <= 14):
        raise HTTPException(status_code=422, detail="minimum_interval_days must be between 1 and 14")
    intervals = (
        (minimum_interval_days,) if minimum_interval_days is not None else tuple(range(1, 15))
    )

    configs: List[Dict[str, Any]] = []
    for base in bases:
        for power in sorted(p for p in SUPPORTED_MSEQ_POWERS_BY_BASE[base] if 2 <= p <= 6):
            try:
                distinct = _distinct_sequence_count(base, power)
            except ValueError:
                continue
            num_frames = base ** power - 1
            for active_symbols in range(1, base):
                counts = _active_slot_counts(
                    mseq_base=base,
                    sequence_power=power,
                    active_symbols=active_symbols,
                    workout_count=workout_count,
                )
                total_slots = sum(counts)
                if total_slots == 0:
                    continue
                for interval in intervals:
                    span = (num_frames - 1) * interval + 1
                    if max_span_days is not None and span > max_span_days:
                        continue
                    sessions_per_week = total_slots / span * 7.0
                    shape = _session_shape(
                        mseq_base=base,
                        sequence_power=power,
                        active_symbols=active_symbols,
                        workout_count=workout_count,
                        minimum_interval_days=interval,
                        schedule_span_days=span,
                    )
                    configs.append({
                        "mseq_base": base,
                        "sequence_power": power,
                        "minimum_interval_days": interval,
                        "active_symbols": active_symbols,
                        "schedule_span_days": span,
                        "num_frames": num_frames,
                        "sessions_per_week": round(sessions_per_week, 2),
                        "mean_days_between_sessions_per_workout": round(
                            span / (total_slots / workout_count), 2
                        ),
                        "sessions_per_workout": round(total_slots / workout_count, 1),
                        "density_pct": round(active_symbols / base * 100),
                        "distinct_sequences": distinct,
                        "every_workout_unique": distinct >= workout_count,
                        # How the schedule actually feels day to day.
                        "workouts_per_training_day": shape["mean_workouts_per_training_day"],
                        "workouts_per_training_day_range": shape["workouts_per_training_day_range"],
                        "train_every_n_days": shape["train_every_n_days"],
                        "rest_day_pct": shape["rest_day_pct"],
                        "session_size_varies": shape["varies"],
                    })
    return configs


# ── Objective-based parameter solving ─────────────────────────────────────────

# Each objective maps a user-facing goal onto a field of an enumerated config.
# Errors are measured as |log(actual / target)|, which is scale-free: it makes
# "sessions per week" and "workouts per training day" directly comparable even
# though they have wildly different magnitudes, and it penalises 2x too much the
# same as half as much.
_OBJECTIVES = {
    "target_sessions_per_week": "sessions_per_week",
    "target_workouts_per_training_day": "workouts_per_training_day",
    "target_train_every_n_days": "train_every_n_days",
    "target_days_between_repeats": "mean_days_between_sessions_per_workout",
}


def _score_config(
    config: Dict[str, Any], targets: Dict[str, float], weights: Dict[str, float]
) -> Tuple[float, Dict[str, Any]]:
    """Weighted multi-objective error for one configuration."""
    total = 0.0
    total_weight = 0.0
    breakdown: Dict[str, Any] = {}
    for target_key, field in _OBJECTIVES.items():
        target = targets.get(target_key)
        if target is None:
            continue
        actual = config.get(field)
        weight = weights.get(target_key, 1.0)
        if not actual or actual <= 0:
            # Unreachable rather than merely a bad fit.
            total += weight * 10.0
            total_weight += weight
            breakdown[target_key] = {"target": target, "actual": actual, "error_pct": None}
            continue
        total += weight * abs(math.log(actual / target))
        total_weight += weight
        breakdown[target_key] = {
            "target": target,
            "actual": actual,
            "error_pct": round(abs(actual - target) / target * 100, 1),
        }
    return (total / total_weight if total_weight else 0.0), breakdown


def solve_routine_params(
    *,
    workout_count: int,
    target_sessions_per_week: Optional[float] = None,
    target_workouts_per_training_day: Optional[float] = None,
    target_train_every_n_days: Optional[float] = None,
    target_days_between_repeats: Optional[float] = None,
    weights: Optional[Dict[str, float]] = None,
    max_span_days: Optional[int] = 365,
    max_results: int = 3,
    collision_free_only: bool = True,
) -> Dict[str, Any]:
    """Find the configuration(s) best matching any combination of training goals.

    Deliberately an exhaustive search rather than a numerical optimiser. The
    search space is ~490 discrete points evaluated in single-digit milliseconds,
    so brute force returns the global optimum exactly. A gradient/continuous
    method would be strictly worse here: the parameters are integers and
    categoricals (mseq_base is not ordinal), the objective is non-differentiable
    because slot counts come from thresholded integer sequences, valid powers
    depend on the chosen base, and a rounded solution could easily be invalid.
    """
    targets = {
        "target_sessions_per_week": target_sessions_per_week,
        "target_workouts_per_training_day": target_workouts_per_training_day,
        "target_train_every_n_days": target_train_every_n_days,
        "target_days_between_repeats": target_days_between_repeats,
    }
    targets = {k: float(v) for k, v in targets.items() if v is not None}
    if not targets:
        raise HTTPException(
            status_code=422,
            detail="Specify at least one target (e.g. target_workouts_per_training_day).",
        )
    for key, value in targets.items():
        if value <= 0:
            raise HTTPException(status_code=422, detail=f"{key} must be greater than 0")

    weights = weights or {}
    for key in weights:
        if key not in _OBJECTIVES:
            raise HTTPException(
                status_code=422,
                detail=f"Unknown weight '{key}'. Valid: {', '.join(_OBJECTIVES)}",
            )

    def _search(span_cap: Optional[int]) -> List[Dict[str, Any]]:
        found = []
        for config in enumerate_routine_configurations(
            workout_count=workout_count, max_span_days=span_cap
        ):
            if collision_free_only and not config["every_workout_unique"]:
                continue
            score, breakdown = _score_config(config, targets, weights)
            found.append({**config, "_score": score, "goal_fit": breakdown})
        return found

    candidates = _search(max_span_days)
    # Widen only if the preferred horizon cannot get close, rather than silently
    # returning a poor match.
    if max_span_days is not None and (
        not candidates or min(c["_score"] for c in candidates) > 0.15
    ):
        seen = {
            (c["mseq_base"], c["sequence_power"], c["minimum_interval_days"], c["active_symbols"])
            for c in candidates
        }
        for config in _search(max_span_days * 8):
            key = (
                config["mseq_base"], config["sequence_power"],
                config["minimum_interval_days"], config["active_symbols"],
            )
            if key not in seen:
                candidates.append(config)

    if not candidates:
        raise HTTPException(
            status_code=422,
            detail="No configuration fits those constraints — try relaxing max_span_days.",
        )

    candidates.sort(key=lambda c: (round(c["_score"], 3), c["schedule_span_days"]))
    top = candidates[: max(1, max_results)]
    best_score = top[0]["_score"]
    worst_error = max(
        (b["error_pct"] for b in top[0]["goal_fit"].values() if b["error_pct"] is not None),
        default=0.0,
    )
    for c in top:
        c.pop("_score", None)

    if worst_error <= 10:
        quality = "good"
    elif worst_error <= 30:
        quality = "approximate"
    else:
        quality = "poor"

    result = {
        "workout_count": workout_count,
        "targets": targets,
        "match_quality": quality,
        "evaluated_configurations": len(candidates),
        "candidates": top,
    }
    if quality != "good":
        misses = ", ".join(
            f"{k.replace('target_', '').replace('_', ' ')}: asked {b['target']}, "
            f"best achievable {b['actual']}"
            for k, b in top[0]["goal_fit"].items()
            if b["error_pct"] is not None and b["error_pct"] > 10
        )
        result["note"] = (
            f"No configuration matches every goal. Closest is — {misses}. "
            "The m-sequence only permits certain combinations for this number of "
            "workouts. Tell the user the real numbers rather than implying an exact "
            "match, and offer to add or remove workouts to get closer."
        )
    if best_score > 0.5:
        result["warning"] = (
            "Even the best fit is far from the request. Consider changing the number "
            "of workouts, or relaxing one of the goals."
        )
    return result


def list_routine_configurations(
    *,
    workout_count: int,
    mseq_base: Optional[int] = None,
    minimum_interval_days: Optional[int] = None,
    min_sessions_per_week: Optional[float] = None,
    max_sessions_per_week: Optional[float] = None,
    max_span_days: Optional[int] = None,
    collision_free_only: bool = True,
    sort_by: str = "sessions_per_week",
    limit: int = 30,
) -> Dict[str, Any]:
    """Browsable view over the full configuration space.

    The unfiltered space is ~490 configurations, which is far too large to hand
    back in one piece, so this filters and summarises. `total_matching` always
    reflects the real count so the caller can tell when results were truncated.
    """
    configs = enumerate_routine_configurations(
        workout_count=workout_count,
        mseq_base=mseq_base,
        minimum_interval_days=minimum_interval_days,
        max_span_days=max_span_days,
    )

    all_rates = [c["sessions_per_week"] for c in configs]
    if collision_free_only:
        configs = [c for c in configs if c["every_workout_unique"]]
    if min_sessions_per_week is not None:
        configs = [c for c in configs if c["sessions_per_week"] >= min_sessions_per_week]
    if max_sessions_per_week is not None:
        configs = [c for c in configs if c["sessions_per_week"] <= max_sessions_per_week]

    sort_keys = {
        "sessions_per_week": lambda c: c["sessions_per_week"],
        "schedule_span_days": lambda c: c["schedule_span_days"],
        "days_between_sessions": lambda c: c["mean_days_between_sessions_per_workout"],
    }
    if sort_by not in sort_keys:
        raise HTTPException(
            status_code=422,
            detail=f"sort_by must be one of: {', '.join(sort_keys)}",
        )
    configs.sort(key=sort_keys[sort_by])

    total_matching = len(configs)
    limit = max(1, min(limit, 100))
    if total_matching > limit:
        # Even coverage of the range beats an arbitrary head-of-list slice, which
        # would only ever show the least frequent options. Both endpoints are
        # included so the caller always sees the true extremes.
        if limit == 1:
            shown = [configs[0]]
        else:
            picked = sorted({
                round(i * (total_matching - 1) / (limit - 1)) for i in range(limit)
            })
            shown = [configs[i] for i in picked]
    else:
        shown = configs

    return {
        "workout_count": workout_count,
        "total_matching": total_matching,
        "returned": len(shown),
        "truncated": total_matching > len(shown),
        "achievable_sessions_per_week": {
            "min": round(min(all_rates), 2) if all_rates else None,
            "max": round(max(all_rates), 2) if all_rates else None,
        },
        "filters_applied": {
            "mseq_base": mseq_base,
            "minimum_interval_days": minimum_interval_days,
            "min_sessions_per_week": min_sessions_per_week,
            "max_sessions_per_week": max_sessions_per_week,
            "max_span_days": max_span_days,
            "collision_free_only": collision_free_only,
        },
        "configurations": shown,
    }


def suggest_routine_params(
    *,
    workout_count: int,
    target_sessions_per_week: float,
    max_results: int = 3,
    max_span_days: Optional[int] = 365,
) -> Dict[str, Any]:
    """Search the valid m-sequence parameter space for the best frequency match.

    Returns candidates ranked by how close their overall training frequency is to
    the target, preferring parameter sets that give every workout its own distinct
    sequence.
    """
    if workout_count <= 0:
        raise HTTPException(status_code=422, detail="Add at least one workout before choosing a schedule")
    if target_sessions_per_week <= 0:
        raise HTTPException(status_code=422, detail="target_sessions_per_week must be greater than 0")

    candidates: List[Dict[str, Any]] = []

    def _enumerate(span_cap: Optional[int]) -> None:
        for config in enumerate_routine_configurations(
            workout_count=workout_count, max_span_days=span_cap
        ):
            sessions_per_week = config["sessions_per_week"]
            if sessions_per_week <= 0:
                continue
            # Relative error, so being 2x too frequent is penalised like being
            # half as frequent.
            error = abs(math.log(sessions_per_week / target_sessions_per_week))
            candidates.append({
                **config,
                "sessions_per_week_error_pct": round(
                    abs(sessions_per_week - target_sessions_per_week)
                    / target_sessions_per_week * 100, 1
                ),
                "exceeds_preferred_span": (
                    max_span_days is not None and config["schedule_span_days"] > max_span_days
                ),
                "_error": error,
            })

    _enumerate(max_span_days)

    def _best_error() -> Optional[float]:
        """Lowest error among the candidates the ranking would actually prefer.

        Must mirror the sort's primary key: a well-matched but colliding
        parameter set is not a real option, so it must not suppress the
        widened search.
        """
        if not candidates:
            return None
        unique = [c for c in candidates if c["every_workout_unique"]]
        return min(c["_error"] for c in (unique or candidates))

    # If nothing within the preferred horizon lands near the target, widen the
    # search rather than silently returning a badly-matched schedule.
    best = _best_error()
    if max_span_days is not None and (best is None or best > 0.15):
        _enumerate(max_span_days * 8)

    if not candidates:
        raise HTTPException(
            status_code=422,
            detail="No m-sequence parameters fit those constraints — try relaxing max_span_days.",
        )

    # Unique sequences first, then closest frequency, then the shorter schedule.
    # The error is bucketed so that two parameter sets which match the target
    # equally well in practice are separated by schedule length rather than by a
    # meaningless third-decimal difference.
    candidates.sort(key=lambda c: (
        not c["every_workout_unique"],
        round(c["_error"], 2),
        c["schedule_span_days"],
    ))
    # Drop duplicates introduced by the widened second pass.
    seen_keys = set()
    unique_candidates = []
    for c in candidates:
        key = (c["mseq_base"], c["sequence_power"], c["minimum_interval_days"], c["active_symbols"])
        if key in seen_keys:
            continue
        seen_keys.add(key)
        unique_candidates.append(c)

    top = unique_candidates[: max(1, max_results)]
    best_error_pct = top[0]["sessions_per_week_error_pct"]
    if best_error_pct <= 10:
        quality = "good"
    elif best_error_pct <= 30:
        quality = "approximate"
    else:
        quality = "poor"
    for c in top:
        c.pop("_error", None)
    result = {
        "workout_count": workout_count,
        "target_sessions_per_week": target_sessions_per_week,
        "match_quality": quality,
        "candidates": top,
    }
    if quality == "poor":
        result["note"] = (
            f"The closest achievable frequency is {top[0]['sessions_per_week']} sessions/week, "
            f"{best_error_pct}% away from the requested {target_sessions_per_week}. "
            "The m-sequence structure only allows certain frequencies for this number of "
            "workouts. Tell the user the real number rather than implying an exact match, "
            "and offer to add or remove workouts to get closer."
        )
    return result


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
    try:
        distinct_sequences = _distinct_sequence_count(mseq_base, sequence_power)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    capacity = {
        "distinct_sequences": distinct_sequences,
        "every_workout_unique": distinct_sequences >= workout_count,
    }
    if workout_count > distinct_sequences:
        capacity["warning"] = (
            f"Only {distinct_sequences} distinct sequences exist for base {mseq_base} "
            f"power {sequence_power}, but there are {workout_count} workouts. Workouts "
            f"beyond the first {distinct_sequences} repeat an earlier workout's exact "
            f"schedule. Raise sequence_power or mseq_base to spread them out."
        )

    if workout_count <= 0:
        return {
            "sequence_power": sequence_power,
            "minimum_interval_days": minimum_interval_days,
            "mseq_base": mseq_base,
            "active_symbols": active_symbols,
            "num_workouts": 0,
            "num_frames": num_frames,
            "schedule_span_days": schedule_span_days,
            "capacity": capacity,
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
        "capacity": capacity,
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


def generate_routine_for_user(
    session: Session,
    user_id: int,
    *,
    start_date: Optional[str] = None,
    sequence_power: int = 4,
    minimum_interval_days: int = 2,
    mseq_base: int = MSEQ_BASE_DEFAULT,
    active_symbols: int = 1,
) -> Dict[str, Any]:
    """Regenerate the user's whole schedule from an m-sequence.

    Shared by the REST endpoint and the workout coach agent. Deletes every
    existing ScheduleEntry for the user, so callers must treat it as destructive.
    """
    workouts = session.query(Workout).filter(Workout.user_id == user_id).all()
    if not workouts:
        raise HTTPException(
            status_code=400,
            detail="No workouts found — add workouts before generating a routine",
        )

    _validate_generation_params(sequence_power, minimum_interval_days, mseq_base, active_symbols)

    num_frames = mseq_base ** sequence_power - 1
    if start_date:
        try:
            base = datetime.datetime.strptime(start_date, "%Y-%m-%d").date()
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


@router.post("/generate-routine")
@limiter.limit("10/minute")
async def generate_new_routine(
    request: Request,
    request_body: RoutineGenerationRequest,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    return generate_routine_for_user(
        session,
        user_id,
        start_date=request_body.start_date,
        sequence_power=request_body.sequence_power or 4,
        minimum_interval_days=request_body.minimum_interval_days or 2,
        mseq_base=request_body.mseq_base or MSEQ_BASE_DEFAULT,
        active_symbols=request_body.active_symbols or 1,
    )


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
    equipment: Optional[str] = None,
    muscle: Optional[str] = None,
    category: Optional[str] = None,
    level: Optional[str] = None,
    force: Optional[str] = None,
    mechanic: Optional[str] = None,
    user_id: int = Depends(get_current_user_id),
):
    return exercise_db.search_exercises(
        q,
        limit=max(1, min(limit, 50)),
        equipment=equipment,
        muscle=muscle,
        category=category,
        level=level,
        force=force,
        mechanic=mechanic,
    )


@router.get("/exercises/filters")
async def get_exercise_filters(user_id: int = Depends(get_current_user_id)):
    """Valid filter values for /exercises/search, with counts."""
    return exercise_db.facets()


@router.get("/exercises/{exercise_id}")
async def get_exercise(
    exercise_id: str,
    user_id: int = Depends(get_current_user_id),
):
    ex = exercise_db.find_exercise(exercise_id)
    if not ex:
        raise HTTPException(status_code=404, detail="Exercise not found")
    return {**ex, "imageUrl": exercise_db.image_url(ex)}
