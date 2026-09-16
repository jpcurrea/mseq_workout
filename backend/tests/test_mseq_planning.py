"""
Pure unit tests for the m-sequence schedule planner.
No database or HTTP calls.
"""
import io
import contextlib

import pytest
from fastapi import HTTPException

from mseq import mseq
from routers.workouts import (
    SUPPORTED_MSEQ_POWERS_BY_BASE,
    _active_slot_counts,
    _distinct_sequence_count,
    _frame_load_profile,
    _session_shape,
    enumerate_routine_configurations,
    list_routine_configurations,
    solve_routine_params,
    suggest_routine_params,
)

VALID_COMBOS = [
    (base, power)
    for base, powers in SUPPORTED_MSEQ_POWERS_BY_BASE.items()
    for power in sorted(powers)
    if 2 <= power <= 6
]


# ── mseq itself ───────────────────────────────────────────────────────────────

@pytest.mark.parametrize("base,power", VALID_COMBOS)
def test_supported_params_produce_a_sequence_of_the_right_length(base, power):
    seq = mseq(base, power, whichSeq=1, shift=0, raw=True)
    assert len(seq) == base ** power - 1


@pytest.mark.parametrize("base,power", VALID_COMBOS)
def test_supported_params_do_not_print_a_not_defined_warning(base, power):
    """Regression: base 5 used separate `if` chains, so powers 2 and 3 printed
    'M-sequence 5**N is not defined' on every call despite working correctly."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        mseq(base, power, whichSeq=1, shift=0, raw=True)
    assert "not defined" not in buf.getvalue()


def test_undefined_params_still_raise():
    with pytest.raises(ValueError):
        mseq(5, 5, whichSeq=1, shift=0, raw=True)


# ── Capacity ──────────────────────────────────────────────────────────────────

def test_distinct_sequence_count_detects_the_wrap_limit():
    # whichSeq wraps modulo the tap-table size; base 2 power 2 has a single tap.
    assert _distinct_sequence_count(2, 2) == 1
    assert _distinct_sequence_count(5, 2) == 4
    assert _distinct_sequence_count(5, 4) > 20


def test_workouts_beyond_capacity_reuse_an_earlier_schedule():
    """Documents why capacity matters: the 5th workout on base 5 / power 2 lands
    on exactly the same days as an earlier one."""
    capacity = _distinct_sequence_count(5, 2)
    seqs = [
        tuple(int(v) for v in mseq(5, 2, whichSeq=k, shift=0, raw=True))
        for k in range(1, capacity + 2)
    ]
    assert len(set(seqs[:capacity])) == capacity
    assert seqs[capacity] in seqs[:capacity]


def test_active_slot_counts_are_measured_not_assumed():
    """Bases 2/3/5 are prime and balanced, but base 9 is not a prime field under
    this implementation, so its symbols are unbalanced. Counts must come from the
    real sequence rather than base**(power-1)."""
    balanced = _active_slot_counts(mseq_base=5, sequence_power=3, active_symbols=1, workout_count=1)
    assert balanced[0] == 5 ** 2

    unbalanced = _active_slot_counts(mseq_base=9, sequence_power=2, active_symbols=1, workout_count=1)
    assert unbalanced[0] != 9 ** 1


def test_more_active_symbols_means_more_sessions():
    low = sum(_active_slot_counts(mseq_base=5, sequence_power=3, active_symbols=1, workout_count=3))
    high = sum(_active_slot_counts(mseq_base=5, sequence_power=3, active_symbols=4, workout_count=3))
    assert high > low


# ── Solver ────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("workout_count,target", [(3, 2), (4, 3), (6, 4), (8, 5), (10, 4)])
def test_solver_finds_a_close_match(workout_count, target):
    result = suggest_routine_params(
        workout_count=workout_count, target_sessions_per_week=target
    )
    best = result["candidates"][0]
    assert result["match_quality"] == "good"
    assert best["sessions_per_week_error_pct"] <= 10


def test_solver_recommends_only_valid_parameters():
    from routers.workouts import _validate_generation_params

    result = suggest_routine_params(workout_count=5, target_sessions_per_week=4, max_results=5)
    for c in result["candidates"]:
        # Must not raise.
        _validate_generation_params(
            c["sequence_power"], c["minimum_interval_days"], c["mseq_base"], c["active_symbols"]
        )


def test_solver_prefers_collision_free_parameters():
    result = suggest_routine_params(workout_count=10, target_sessions_per_week=5, max_results=3)
    assert result["candidates"][0]["every_workout_unique"] is True


def test_solver_widens_horizon_when_nothing_fits_within_a_year():
    """A well-matched but colliding option must not suppress the widened search."""
    result = suggest_routine_params(workout_count=12, target_sessions_per_week=3)
    best = result["candidates"][0]
    assert best["every_workout_unique"] is True
    assert best["sessions_per_week_error_pct"] <= 10
    assert best["schedule_span_days"] > 365
    assert best["exceeds_preferred_span"] is True


def test_solver_respects_a_tight_span_preference():
    result = suggest_routine_params(
        workout_count=4, target_sessions_per_week=2, max_span_days=120
    )
    assert result["candidates"][0]["schedule_span_days"] <= 120


def test_solver_reports_poor_matches_honestly():
    # An absurdly low frequency for many workouts is not achievable.
    result = suggest_routine_params(workout_count=12, target_sessions_per_week=0.05)
    assert result["match_quality"] == "poor"
    assert "note" in result


def test_solver_rejects_empty_library():
    with pytest.raises(HTTPException):
        suggest_routine_params(workout_count=0, target_sessions_per_week=3)


def test_solver_rejects_nonpositive_target():
    with pytest.raises(HTTPException):
        suggest_routine_params(workout_count=3, target_sessions_per_week=0)


def test_candidates_do_not_leak_internal_scoring_field():
    result = suggest_routine_params(workout_count=4, target_sessions_per_week=3)
    assert all("_error" not in c for c in result["candidates"])


# ── Configuration enumeration ─────────────────────────────────────────────────

# Mirrors _supportedPowersByBase in workout_management_screen.dart. If the app's
# dropdowns change, this must change too — otherwise the coach and the UI would
# offer different schedules.
UI_POWERS_BY_BASE = {2: [2, 3, 4, 5, 6], 3: [2, 3, 4, 5, 6], 5: [2, 3, 4], 9: [2]}
UI_INTERVAL_CHOICES = [1, 2, 3, 4, 5, 7, 10, 14]


def test_enumeration_covers_exactly_the_ui_parameter_space():
    configs = enumerate_routine_configurations(workout_count=3)
    offered = {(c["mseq_base"], c["sequence_power"]) for c in configs}
    expected = {(b, p) for b, powers in UI_POWERS_BY_BASE.items() for p in powers}
    assert offered == expected

    for base, powers in UI_POWERS_BY_BASE.items():
        symbols = {c["active_symbols"] for c in configs if c["mseq_base"] == base}
        assert symbols == set(range(1, base))


def test_enumeration_includes_every_interval_the_ui_offers():
    configs = enumerate_routine_configurations(workout_count=3)
    intervals = {c["minimum_interval_days"] for c in configs}
    assert set(UI_INTERVAL_CHOICES).issubset(intervals)


def test_enumeration_rates_match_the_stats_used_by_the_ui():
    """The table must agree with _compute_mseq_rate_stats, which drives the UI card."""
    from routers.workouts import _compute_mseq_rate_stats

    for config in enumerate_routine_configurations(workout_count=4, mseq_base=5)[:12]:
        stats = _compute_mseq_rate_stats(
            workout_count=4,
            sequence_power=config["sequence_power"],
            minimum_interval_days=config["minimum_interval_days"],
            mseq_base=config["mseq_base"],
            active_symbols=config["active_symbols"],
        )
        assert stats["schedule_span_days"] == config["schedule_span_days"]
        assert abs(
            stats["overall_mean_workouts_per_day"] * 7 - config["sessions_per_week"]
        ) < 0.05


def test_enumeration_rejects_an_empty_library():
    with pytest.raises(HTTPException):
        enumerate_routine_configurations(workout_count=0)


def test_listing_reports_the_true_total_when_truncated():
    result = list_routine_configurations(workout_count=3, limit=10)
    assert result["returned"] == 10
    assert result["total_matching"] > 10
    assert result["truncated"] is True


def test_listing_samples_across_the_range_not_just_the_head():
    """A truncated listing must still show the extremes, or the coach would
    never learn that the fastest schedules exist."""
    everything = [
        c for c in enumerate_routine_configurations(workout_count=3)
        if c["every_workout_unique"]
    ]
    fastest = max(c["sessions_per_week"] for c in everything)
    slowest = min(c["sessions_per_week"] for c in everything)

    sample = list_routine_configurations(workout_count=3, limit=8)
    rates = [c["sessions_per_week"] for c in sample["configurations"]]
    assert rates[0] == slowest
    assert rates[-1] == fastest


def test_listing_rejects_invalid_filters():
    with pytest.raises(HTTPException):
        list_routine_configurations(workout_count=3, mseq_base=4)
    with pytest.raises(HTTPException):
        list_routine_configurations(workout_count=3, minimum_interval_days=99)
    with pytest.raises(HTTPException):
        list_routine_configurations(workout_count=3, sort_by="bogus")


def test_listing_sort_orders():
    for key in ("sessions_per_week", "schedule_span_days", "days_between_sessions"):
        result = list_routine_configurations(workout_count=3, sort_by=key, limit=100)
        field = {
            "sessions_per_week": "sessions_per_week",
            "schedule_span_days": "schedule_span_days",
            "days_between_sessions": "mean_days_between_sessions_per_workout",
        }[key]
        values = [c[field] for c in result["configurations"]]
        assert values == sorted(values)


def test_achievable_range_ignores_filters_so_it_stays_honest():
    """The advertised range must describe what is possible, not what survived
    the current filter — otherwise the coach would understate the options."""
    narrow = list_routine_configurations(
        workout_count=3, min_sessions_per_week=3, max_sessions_per_week=4
    )
    wide = list_routine_configurations(workout_count=3)
    assert narrow["achievable_sessions_per_week"] == wide["achievable_sessions_per_week"]


# -- session shape: the vocabulary users actually speak in -------------------

@pytest.mark.parametrize("base,power", VALID_COMBOS)
def test_frame_load_profile_is_self_consistent(base, power):
    """Histogram must account for exactly the training days and slots reported."""
    training_days, total_slots, histogram = _frame_load_profile(base, power, 1, 4)
    assert training_days == sum(days for _, days in histogram)
    assert total_slots == sum(load * days for load, days in histogram)
    assert all(load > 0 for load, _ in histogram), "rest days must not be in the histogram"


@pytest.mark.parametrize("combo", [(5, 3, 2), (3, 4, 1), (2, 5, 1), (9, 2, 4)])
def test_load_profile_is_independent_of_interval(combo):
    """The interval stretches the span but never merges two frames onto one day.

    This is what justifies caching _frame_load_profile without the interval.
    """
    base, power, active = combo
    shapes = [
        _session_shape(
            mseq_base=base, sequence_power=power, active_symbols=active,
            workout_count=6, minimum_interval_days=interval,
            schedule_span_days=(base ** power - 1 - 1) * interval + 1,
        )
        for interval in (1, 2, 5, 14)
    ]
    first = shapes[0]
    for other in shapes[1:]:
        assert other["workouts_per_training_day_distribution"] == \
            first["workouts_per_training_day_distribution"]
        assert other["mean_workouts_per_training_day"] == \
            first["mean_workouts_per_training_day"]


def test_session_shape_reports_spread_not_just_mean():
    """The coach must be able to see that daily load varies, not promise 'exactly N'."""
    shape = _session_shape(
        mseq_base=5, sequence_power=3, active_symbols=2,
        workout_count=8, minimum_interval_days=2, schedule_span_days=247,
    )
    assert shape["varies"] is True
    lo = shape["workouts_per_training_day_range"]["min"]
    hi = shape["workouts_per_training_day_range"]["max"]
    assert lo < shape["mean_workouts_per_training_day"] < hi
    assert 0 < shape["rest_day_pct"] < 100


def test_every_configuration_carries_human_vocabulary():
    for config in enumerate_routine_configurations(workout_count=5):
        for field in (
            "workouts_per_training_day", "workouts_per_training_day_range",
            "train_every_n_days", "rest_day_pct", "session_size_varies",
        ):
            assert field in config, f"{field} missing from enumerated configuration"


# -- multi-objective solver --------------------------------------------------

def test_solver_requires_at_least_one_target():
    with pytest.raises(HTTPException) as exc:
        solve_routine_params(workout_count=6)
    assert exc.value.status_code == 422


def test_solver_rejects_unknown_weight_key():
    with pytest.raises(HTTPException) as exc:
        solve_routine_params(
            workout_count=6, target_sessions_per_week=5, weights={"target_nonsense": 2},
        )
    assert exc.value.status_code == 422


@pytest.mark.parametrize("target", [2, 3, 5, 8])
def test_solver_matches_a_single_frequency_target(target):
    result = solve_routine_params(workout_count=6, target_sessions_per_week=target)
    best = result["candidates"][0]
    assert result["match_quality"] in {"good", "approximate"}
    assert abs(best["sessions_per_week"] - target) / target < 0.3


def test_solver_expresses_the_request_that_broke_the_agent():
    """'About 3 workouts a day, every other day' must be directly expressible."""
    result = solve_routine_params(
        workout_count=8,
        target_workouts_per_training_day=3,
        target_train_every_n_days=2,
    )
    best = result["candidates"][0]
    assert abs(best["workouts_per_training_day"] - 3) < 1.0
    assert abs(best["train_every_n_days"] - 2) < 0.5
    # and it must expose the spread so the coach cannot promise "exactly 3"
    assert best["workouts_per_training_day_range"]["max"] > 3


def test_solver_honours_weights():
    """Up-weighting a goal must not make that goal fit worse."""
    balanced = solve_routine_params(
        workout_count=8, target_workouts_per_training_day=3, target_train_every_n_days=2,
    )["candidates"][0]
    weighted = solve_routine_params(
        workout_count=8, target_workouts_per_training_day=3, target_train_every_n_days=2,
        weights={"target_workouts_per_training_day": 8},
    )["candidates"][0]
    assert abs(weighted["workouts_per_training_day"] - 3) <= \
        abs(balanced["workouts_per_training_day"] - 3) + 1e-9


def test_solver_reports_impossible_requests_honestly():
    result = solve_routine_params(workout_count=3, target_workouts_per_training_day=25)
    assert result["match_quality"] == "poor"
    assert "note" in result and "warning" in result


def test_solver_returns_only_collision_free_by_default():
    result = solve_routine_params(workout_count=8, target_sessions_per_week=5)
    assert all(c["every_workout_unique"] for c in result["candidates"])


def test_solver_goal_fit_reports_every_supplied_target():
    result = solve_routine_params(
        workout_count=6, target_sessions_per_week=4, target_train_every_n_days=2,
    )
    fit = result["candidates"][0]["goal_fit"]
    assert set(fit) == {"target_sessions_per_week", "target_train_every_n_days"}
    assert result["candidates"][0].get("_score") is None, "internal score must not leak"


def test_solver_breaks_ties_on_shorter_span():
    """Fit dominates; span only separates configurations that fit equally well.

    Ranking is on |log(actual/target)|, not linear percent, so 'a bit over' and
    'a bit under' are penalised symmetrically. An 18-year schedule must never
    outrank a 6-month one that matches just as closely.
    """
    import math

    target = 4
    result = solve_routine_params(
        workout_count=6, target_sessions_per_week=target, max_results=5,
    )
    candidates = result["candidates"]
    errors = [abs(math.log(c["sessions_per_week"] / target)) for c in candidates]
    for i in range(len(candidates) - 1):
        if abs(errors[i] - errors[i + 1]) < 5e-4:
            assert candidates[i]["schedule_span_days"] <= candidates[i + 1]["schedule_span_days"]
        else:
            assert errors[i] <= errors[i + 1], "a worse-fitting option must not rank higher"

# -- capacity regression -----------------------------------------------------

def test_base3_power5_capacity_is_one_due_to_duplicate_tap():
    """Taps 1 and 2 are identical, so sequential assignment collides immediately.

    Pinned deliberately: "fixing" this by skipping duplicate taps would renumber
    sequences and silently rewrite every existing user's schedule.
    """
    assert _distinct_sequence_count(3, 5) == 1


def test_low_capacity_configs_are_excluded_when_collision_free_required():
    configs = list_routine_configurations(
        workout_count=8, collision_free_only=True, limit=200,
    )["configurations"]
    assert configs, "expected at least one usable configuration for 8 workouts"
    for c in configs:
        assert not (c["mseq_base"] == 3 and c["sequence_power"] == 5)
