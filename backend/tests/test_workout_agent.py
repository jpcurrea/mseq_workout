"""Workout coach agent — tool execution and conversation endpoints."""
import datetime

import pytest

import exercises as exercise_db
from database import ScheduleEntry, Workout
from routers.workout_agent import _build_workout_context, _execute_workout_tool_call


@pytest.fixture
def workout(db, user):
    w = Workout(user_id=user.id, name="Pushups", goal=20, units="reps", at_park=False)
    db.add(w)
    db.flush()
    return w


def _run(name, args, db, user, dry_run=False):
    return _execute_workout_tool_call(
        name=name, args=args, user_id=user.id, session=db, dry_run=dry_run
    )


# ── Read-only tools ───────────────────────────────────────────────────────────

def test_search_exercises_tool_returns_real_ids(db, user):
    result = _run("search_exercises", {"query": "squat", "limit": 3}, db, user)
    assert result["ok"] and result["count"] > 0
    for item in result["results"]:
        assert exercise_db.find_exercise(item["id"]) is not None


def test_search_exercises_tool_supports_programming_filters(db, user):
    result = _run(
        "search_exercises",
        {"query": "", "force": "push", "mechanic": "compound", "equipment": "barbell", "limit": 5},
        db, user,
    )
    assert result["count"] > 0
    for item in result["results"]:
        assert item["force"] == "push"
        assert item["mechanic"] == "compound"
        assert "barbell" in item["equipment"]


def test_search_exercises_tool_exposes_level_for_ranking(db, user):
    result = _run("search_exercises", {"query": "", "level": "beginner", "limit": 3}, db, user)
    assert all(item["level"] == "beginner" for item in result["results"])


def test_list_exercise_filters_tool(db, user):
    result = _run("list_exercise_filters", {}, db, user)
    assert result["ok"]
    assert set(result["filters"]["force"]) == {"push", "pull", "static"}
    assert result["filters"]["muscle"]["quadriceps"] > 0


def test_filter_discovery_tools_are_read_only():
    from routers.workout_agent import _READ_ONLY_TOOLS

    assert "list_exercise_filters" in _READ_ONLY_TOOLS
    assert "search_exercises" in _READ_ONLY_TOOLS


def test_get_exercise_details_tool_includes_instructions(db, user):
    target = exercise_db.search_exercises("squat", 1)[0]
    result = _run("get_exercise_details", {"exercise_id": target["id"]}, db, user)
    assert result["ok"]
    assert isinstance(result["exercise"]["instructions"], list)


def test_get_exercise_details_rejects_unknown_id(db, user):
    with pytest.raises(ValueError):
        _run("get_exercise_details", {"exercise_id": "nope"}, db, user)


def test_list_workouts_tool(db, user, workout):
    result = _run("list_workouts", {}, db, user)
    assert result["count"] == 1
    assert result["workouts"][0]["name"] == "Pushups"


def test_get_workout_history_tool_aggregates_scores(db, user, workout):
    today = datetime.date.today()
    for offset, score in ((3, 18.0), (1, 22.0)):
        db.add(ScheduleEntry(
            user_id=user.id,
            workout_id=workout.id,
            date=today - datetime.timedelta(days=offset),
            score=score,
        ))
    db.flush()
    result = _run("get_workout_history", {"name": "Pushups"}, db, user)
    assert result["logged_count"] == 2
    assert result["best"] == 22.0
    assert result["average"] == 20.0


def test_preview_routine_stats_is_non_destructive(db, user, workout):
    db.add(ScheduleEntry(user_id=user.id, workout_id=workout.id, date=datetime.date.today()))
    db.flush()
    result = _run("preview_routine_stats", {"mseq_base": 5, "sequence_power": 3}, db, user)
    assert result["ok"] and "stats" in result
    assert db.query(ScheduleEntry).count() == 1


def test_preview_routine_stats_rejects_invalid_params(db, user):
    from fastapi import HTTPException

    with pytest.raises(HTTPException):
        _run("preview_routine_stats", {"mseq_base": 5, "sequence_power": 6}, db, user)


def test_preview_routine_stats_reports_schedule_collisions(db, user):
    # base 5 / power 2 only has 4 distinct sequences, so a 6th workout would
    # silently reuse an earlier workout's exact schedule.
    for i in range(6):
        db.add(Workout(user_id=user.id, name=f"W{i}", goal=10, units="reps", at_park=False))
    db.flush()
    stats = _run("preview_routine_stats", {"mseq_base": 5, "sequence_power": 2}, db, user)["stats"]
    assert stats["capacity"]["every_workout_unique"] is False
    assert "warning" in stats["capacity"]


def test_preview_routine_stats_capacity_ok_when_enough_sequences(db, user, workout):
    stats = _run("preview_routine_stats", {"mseq_base": 5, "sequence_power": 3}, db, user)["stats"]
    assert stats["capacity"]["every_workout_unique"] is True
    assert "warning" not in stats["capacity"]


def test_suggest_routine_params_matches_requested_frequency(db, user):
    for i in range(4):
        db.add(Workout(user_id=user.id, name=f"W{i}", goal=10, units="reps", at_park=False))
    db.flush()
    result = _run("suggest_routine_params", {"target_sessions_per_week": 3}, db, user)
    assert result["ok"]
    assert result["match_quality"] in {"good", "approximate"}
    best = result["candidates"][0]
    # The recommendation must actually be usable by generate_routine.
    _run("preview_routine_stats", {
        "mseq_base": best["mseq_base"],
        "sequence_power": best["sequence_power"],
        "minimum_interval_days": best["minimum_interval_days"],
        "active_symbols": best["active_symbols"],
    }, db, user)
    assert abs(best["sessions_per_week"] - 3) / 3 < 0.3


def test_suggest_routine_params_prefers_collision_free_options(db, user):
    for i in range(6):
        db.add(Workout(user_id=user.id, name=f"W{i}", goal=10, units="reps", at_park=False))
    db.flush()
    result = _run("suggest_routine_params", {"target_sessions_per_week": 4}, db, user)
    assert result["candidates"][0]["every_workout_unique"] is True


def test_suggest_routine_params_is_non_destructive(db, user, workout):
    db.add(ScheduleEntry(user_id=user.id, workout_id=workout.id, date=datetime.date.today()))
    db.flush()
    _run("suggest_routine_params", {"target_sessions_per_week": 3}, db, user)
    assert db.query(ScheduleEntry).count() == 1


def test_suggest_routine_params_requires_a_workout(db, user):
    from fastapi import HTTPException

    with pytest.raises(HTTPException):
        _run("suggest_routine_params", {"target_sessions_per_week": 3}, db, user)


def test_list_routine_configurations_exposes_the_whole_space(db, user, workout):
    result = _run("list_routine_configurations", {"limit": 100}, db, user)
    assert result["ok"]
    assert result["total_matching"] > 50
    assert result["achievable_sessions_per_week"]["min"] > 0
    assert result["achievable_sessions_per_week"]["max"] > result["achievable_sessions_per_week"]["min"]


def test_list_routine_configurations_matches_the_ui_parameters(db, user, workout):
    """Every row must be something the generation screen could also produce."""
    result = _run("list_routine_configurations", {"limit": 100}, db, user)
    for c in result["configurations"]:
        assert c["mseq_base"] in (2, 3, 5, 9)
        assert 2 <= c["sequence_power"] <= 6
        assert 1 <= c["minimum_interval_days"] <= 14
        assert 1 <= c["active_symbols"] <= c["mseq_base"] - 1
        assert c["sessions_per_week"] > 0


def test_list_routine_configurations_filters(db, user, workout):
    result = _run(
        "list_routine_configurations",
        {"mseq_base": 5, "minimum_interval_days": 3, "limit": 50},
        db, user,
    )
    assert result["configurations"]
    for c in result["configurations"]:
        assert c["mseq_base"] == 5
        assert c["minimum_interval_days"] == 3


def test_list_routine_configurations_frequency_window(db, user, workout):
    result = _run(
        "list_routine_configurations",
        {"min_sessions_per_week": 3, "max_sessions_per_week": 5, "limit": 50},
        db, user,
    )
    assert result["configurations"]
    for c in result["configurations"]:
        assert 3 <= c["sessions_per_week"] <= 5


def test_list_routine_configurations_truncates_honestly(db, user, workout):
    result = _run("list_routine_configurations", {"limit": 5}, db, user)
    assert result["returned"] == 5
    assert result["truncated"] is True
    assert result["total_matching"] > 5
    # The sample must span the range rather than showing only the slowest options.
    rates = [c["sessions_per_week"] for c in result["configurations"]]
    assert rates == sorted(rates)
    assert rates[-1] > rates[0]


def test_list_routine_configurations_hides_colliding_options_by_default(db, user):
    for i in range(6):
        db.add(Workout(user_id=user.id, name=f"W{i}", goal=10, units="reps", at_park=False))
    db.flush()
    default = _run("list_routine_configurations", {"limit": 100}, db, user)
    assert all(c["every_workout_unique"] for c in default["configurations"])
    including = _run(
        "list_routine_configurations", {"collision_free_only": False, "limit": 100}, db, user
    )
    assert including["total_matching"] > default["total_matching"]


def test_list_routine_configurations_rejects_bad_sort(db, user, workout):
    from fastapi import HTTPException

    with pytest.raises(HTTPException):
        _run("list_routine_configurations", {"sort_by": "nonsense"}, db, user)


def test_configurations_agree_with_preview_stats(db, user, workout):
    """The browsing table and the confirmation preview must not disagree."""
    result = _run("list_routine_configurations", {"limit": 10}, db, user)
    for c in result["configurations"][:5]:
        stats = _run("preview_routine_stats", {
            "mseq_base": c["mseq_base"],
            "sequence_power": c["sequence_power"],
            "minimum_interval_days": c["minimum_interval_days"],
            "active_symbols": c["active_symbols"],
        }, db, user)["stats"]
        assert stats["schedule_span_days"] == c["schedule_span_days"]
        assert stats["num_frames"] == c["num_frames"]
        assert stats["capacity"]["every_workout_unique"] == c["every_workout_unique"]
        expected = stats["overall_mean_workouts_per_day"] * 7
        assert abs(expected - c["sessions_per_week"]) < 0.05


def test_phase_hint_tracks_progress(db, user, workout):
    # No workouts yet for a fresh user -> build the library first.
    from database import User

    fresh = User(email="fresh2@example.com", username="fresh2")
    db.add(fresh)
    db.flush()
    assert _build_workout_context(db, fresh.id)["phase_hint"] == "phase_1_build_library"
    # Workouts exist but nothing scheduled -> time to choose a schedule.
    assert _build_workout_context(db, user.id)["phase_hint"] == "phase_2_set_schedule"
    db.add(ScheduleEntry(user_id=user.id, workout_id=workout.id, date=datetime.date.today()))
    db.flush()
    assert _build_workout_context(db, user.id)["phase_hint"] == "maintaining"


# ── Mutating tools ────────────────────────────────────────────────────────────

def test_create_workout_tool(db, user):
    target = exercise_db.search_exercises("squat", 1)[0]
    result = _run(
        "create_workout",
        {"name": "Squats", "goal": 15, "units": "reps", "exercise_id": target["id"]},
        db, user,
    )
    assert result["ok"]
    created = db.query(Workout).filter(Workout.name == "Squats").one()
    assert created.exercise_id == target["id"]


def test_create_workout_rejects_fake_exercise_id(db, user):
    with pytest.raises(ValueError):
        _run("create_workout", {"name": "X", "goal": 1, "units": "reps", "exercise_id": "fake"}, db, user)


# ── Auto-linking to the exercise database ─────────────────────────────────────

def test_create_workout_auto_links_by_exact_name(db, user):
    """The model often omits exercise_id; a database name must still link."""
    target = exercise_db.search_exercises("bench press", 1)[0]
    result = _run(
        "create_workout",
        {"name": target["name"], "goal": 10, "units": "reps"},
        db, user,
    )
    assert result["auto_linked"] is True
    assert result["exercise_id"] == target["id"]
    created = db.query(Workout).filter(Workout.name == target["name"]).one()
    assert created.exercise_id == target["id"]


def test_auto_link_ignores_case_and_spacing(db, user):
    target = exercise_db.search_exercises("bench press", 1)[0]
    messy = f"  {target['name'].upper()}  "
    result = _run("create_workout", {"name": messy, "goal": 10, "units": "reps"}, db, user)
    assert result["exercise_id"] == target["id"]


def test_explicit_exercise_id_wins_over_the_name(db, user):
    """A deliberate id must never be overridden by a name that looks like another."""
    other = exercise_db.search_exercises("squat", 1)[0]
    named = exercise_db.search_exercises("bench press", 1)[0]
    assert other["id"] != named["id"]
    result = _run(
        "create_workout",
        {"name": named["name"], "goal": 10, "units": "reps", "exercise_id": other["id"]},
        db, user,
    )
    assert result["exercise_id"] == other["id"]
    assert result["auto_linked"] is False


def test_custom_names_are_not_linked(db, user):
    result = _run(
        "create_workout",
        {"name": "Johns Special Circuit", "goal": 10, "units": "minutes"},
        db, user,
    )
    assert result["exercise_id"] is None
    assert result["auto_linked"] is False


def test_auto_link_does_not_fuzzy_match(db, user):
    """A near-miss must stay unlinked rather than attach the wrong instructions."""
    result = _run("create_workout", {"name": "Bench", "goal": 10, "units": "reps"}, db, user)
    assert result["exercise_id"] is None


def test_dry_run_reports_the_link_it_would_make(db, user):
    target = exercise_db.search_exercises("bench press", 1)[0]
    result = _run(
        "create_workout",
        {"name": target["name"], "goal": 10, "units": "reps"},
        db, user, dry_run=True,
    )
    assert result["exercise_id"] == target["id"]
    assert db.query(Workout).count() == 0


def test_rename_onto_a_database_name_links_it(db, user, workout):
    target = exercise_db.search_exercises("bench press", 1)[0]
    assert workout.exercise_id is None
    _run("update_workout", {"name": "Pushups", "new_name": target["name"]}, db, user)
    db.refresh(workout)
    assert workout.exercise_id == target["id"]


def test_update_can_still_clear_an_existing_link(db, user):
    target = exercise_db.search_exercises("bench press", 1)[0]
    _run("create_workout", {"name": target["name"], "goal": 10, "units": "reps"}, db, user)
    _run("update_workout", {"name": target["name"], "exercise_id": None}, db, user)
    refreshed = db.query(Workout).filter(Workout.name == target["name"]).one()
    assert refreshed.exercise_id is None


def test_context_reports_link_status(db, user, workout):
    target = exercise_db.search_exercises("bench press", 1)[0]
    _run("create_workout", {"name": target["name"], "goal": 10, "units": "reps"}, db, user)
    ctx = _build_workout_context(db, user.id)
    by_name = {w["name"]: w for w in ctx["workouts"]}
    assert by_name[target["name"]]["linked_to_exercise_db"] is True
    assert by_name["Pushups"]["linked_to_exercise_db"] is False


def test_create_workout_rejects_duplicate_name(db, user, workout):
    with pytest.raises(ValueError):
        _run("create_workout", {"name": "Pushups", "goal": 5, "units": "reps"}, db, user)


def test_create_workout_dry_run_does_not_write(db, user):
    result = _run("create_workout", {"name": "Dips", "goal": 10, "units": "reps"}, db, user, dry_run=True)
    assert result["dry_run"] is True
    assert db.query(Workout).filter(Workout.name == "Dips").count() == 0


def test_update_workout_tool(db, user, workout):
    result = _run("update_workout", {"name": "Pushups", "goal": 30, "new_name": "Push-ups"}, db, user)
    assert result["ok"]
    db.refresh(workout)
    assert workout.goal == 30
    assert workout.name == "Push-ups"


def test_update_workout_unknown_name(db, user):
    with pytest.raises(ValueError):
        _run("update_workout", {"name": "Ghost", "goal": 1}, db, user)


def test_delete_workout_removes_schedule_entries(db, user, workout):
    db.add(ScheduleEntry(user_id=user.id, workout_id=workout.id, date=datetime.date.today()))
    db.flush()
    assert _run("delete_workout", {"name": "Pushups"}, db, user)["ok"]
    assert db.query(Workout).count() == 0
    assert db.query(ScheduleEntry).count() == 0


def test_log_score_tool(db, user, workout):
    today = datetime.date.today()
    db.add(ScheduleEntry(user_id=user.id, workout_id=workout.id, date=today))
    db.flush()
    result = _run("log_score", {"workout": "Pushups", "date": today.isoformat(), "score": 25}, db, user)
    assert result["ok"]
    assert db.query(ScheduleEntry).one().score == 25


def test_log_score_requires_scheduled_session(db, user, workout):
    with pytest.raises(ValueError):
        _run("log_score", {"workout": "Pushups", "date": "2020-01-01", "score": 5}, db, user)


def test_log_score_rejects_bad_date(db, user, workout):
    with pytest.raises(ValueError):
        _run("log_score", {"workout": "Pushups", "date": "01/01/2020", "score": 5}, db, user)


def test_generate_routine_tool_creates_schedule(db, user, workout):
    result = _run("generate_routine", {"mseq_base": 5, "sequence_power": 2, "minimum_interval_days": 2}, db, user)
    assert result["ok"] and result["total_workouts"] > 0
    assert db.query(ScheduleEntry).count() == result["total_workouts"]


def test_generate_routine_dry_run_keeps_schedule(db, user, workout):
    db.add(ScheduleEntry(user_id=user.id, workout_id=workout.id, date=datetime.date.today()))
    db.flush()
    result = _run("generate_routine", {"mseq_base": 5, "sequence_power": 2}, db, user, dry_run=True)
    assert result["dry_run"] is True
    assert db.query(ScheduleEntry).count() == 1


def test_generate_routine_requires_a_workout(db, user):
    with pytest.raises(ValueError):
        _run("generate_routine", {}, db, user)


def test_unknown_tool_raises(db, user):
    with pytest.raises(ValueError):
        _run("launch_rocket", {}, db, user)


# ── Context & endpoints ───────────────────────────────────────────────────────

def test_build_workout_context_splits_past_and_future(db, user, workout):
    today = datetime.date.today()
    db.add(ScheduleEntry(user_id=user.id, workout_id=workout.id, date=today + datetime.timedelta(days=1)))
    db.add(ScheduleEntry(user_id=user.id, workout_id=workout.id, date=today - datetime.timedelta(days=1), score=12.0))
    db.flush()
    ctx = _build_workout_context(db, user.id)
    assert ctx["workout_count"] == 1
    assert len(ctx["upcoming_sessions"]) == 1
    assert len(ctx["recent_logged_sessions"]) == 1


def test_conversation_endpoints_round_trip(http_client):
    client, _ = http_client
    assert client.get("/workout-agent/conversation").json() == {
        "messages": [], "summary": None, "has_memory": False
    }
    assert client.delete("/workout-agent/conversation").json()["deleted"] == 0


def test_apply_actions_endpoint_commits_queued_calls(http_client):
    client, _ = http_client
    resp = client.post("/workout-agent/apply-actions", json={
        "tool_calls": [{"name": "create_workout", "args": {"name": "Plank", "goal": 60, "units": "seconds"}}]
    })
    assert resp.status_code == 200
    assert resp.json()["applied"] == 1


def test_apply_actions_endpoint_reports_failures(http_client):
    client, _ = http_client
    resp = client.post("/workout-agent/apply-actions", json={
        "tool_calls": [
            {"name": "update_workout", "args": {"name": "Ghost", "goal": 1}},
            {"name": "list_workouts", "args": {}},
        ]
    })
    body = resp.json()
    assert body["applied"] == 0
    assert all(not r["ok"] for r in body["results"])


# -- solve_routine_params: the tool that replaced the agent's improvising -----

def test_solve_routine_params_is_exposed_and_read_only():
    from routers.workout_agent import _READ_ONLY_TOOLS, _workout_tools_schema
    names = {t["function"]["name"] for t in _workout_tools_schema()}
    assert "solve_routine_params" in names
    assert "solve_routine_params" in _READ_ONLY_TOOLS


def test_solve_routine_params_executes(db, user):
    """Schema without an executor branch raises 'Unknown tool' - guard against it."""
    for i in range(6):
        _run("create_workout", {"name": f"Solver Move {i}", "goal": 10, "units": "reps"}, db, user)
    result = _run(
        "solve_routine_params",
        {"target_workouts_per_training_day": 3, "target_train_every_n_days": 2},
        db, user,
    )
    assert result["ok"] is True
    best = result["candidates"][0]
    for field in ("mseq_base", "sequence_power", "minimum_interval_days", "active_symbols"):
        assert field in best
    assert "workouts_per_training_day_range" in best


def test_solve_routine_params_needs_a_target(db, user, workout):
    with pytest.raises(ValueError, match="at least one target"):
        _run("solve_routine_params", {}, db, user)


def test_solve_routine_params_refuses_before_library_exists(db, user):
    """Phase 2 must not start while Phase 1 is unfinished."""
    with pytest.raises(ValueError, match="No workouts exist"):
        _run("solve_routine_params", {"target_sessions_per_week": 4}, db, user)


def test_solver_params_feed_generate_routine(db, user):
    """The solver's output must be directly usable - no translation step."""
    for i in range(6):
        _run("create_workout", {"name": f"Chain Move {i}", "goal": 10, "units": "reps"}, db, user)
    best = _run("solve_routine_params", {"target_sessions_per_week": 4}, db, user)["candidates"][0]
    preview = _run(
        "preview_routine_stats",
        {k: best[k] for k in
         ("mseq_base", "sequence_power", "minimum_interval_days", "active_symbols")},
        db, user,
    )
    assert preview["ok"] is True


def test_prompt_forbids_inventing_schedules():
    """Regression for the coach describing a rotation the generator cannot build."""
    from routers.workout_agent import _build_system_prompt
    prompt = _build_system_prompt().lower()
    assert "rotation" in prompt or "split" in prompt
    assert "solve_routine_params" in prompt
    assert "varies" in prompt


# -- name-variant linking (the "Pull-Ups" vs "Pullups" failure) ---------------

@pytest.mark.parametrize("written,expected", [
    ("Pull-Ups", "Pullups"),
    ("pull ups", "Pullups"),
    ("Push-Ups", "Pushups"),
    ("Sit-Ups", "Sit-Up"),
    ("Chin-Ups", "Chin-Up"),
    ("Planks", "Plank"),
])
def test_links_across_punctuation_and_plural_variants(db, user, written, expected):
    """Writing variants must link; the coach cannot recall exact DB spellings."""
    result = _run("create_workout", {"name": written, "goal": 10, "units": "reps"}, db, user)
    assert result["auto_linked"] is True
    assert result["linked_exercise"] == expected


def test_normalization_is_collision_free_across_the_database():
    """Folding punctuation/plurals must never merge two different exercises.

    If it did, a workout could silently link to the wrong instructions.
    """
    from exercises import _normalize_name
    names = [e["name"] for e in exercise_db.all_exercises()]
    keys = {}
    for n in names:
        key = _normalize_name(n)
        assert key not in keys, f"collision: {n!r} and {keys[key]!r}"
        keys[key] = n
    assert len(keys) == len(names)


def test_ambiguous_names_stay_unlinked_but_offer_suggestions(db, user):
    """'Dumbbell Rows' matches dozens of variants - guessing one would be wrong."""
    result = _run("create_workout", {"name": "Dumbbell Rows", "goal": 10, "units": "reps"}, db, user)
    assert result["exercise_id"] is None
    assert result["created"] is True, "an unlinked workout is still created"
    assert result["link_suggestions"], "should offer real options instead of a dead end"
    assert any("row" in s["name"].lower() for s in result["link_suggestions"])


def test_unlinked_creation_is_reported_as_success(db, user):
    """Regression: the coach told the user these workouts could not be created."""
    result = _run("create_workout", {"name": "Bodyweight Circuit", "goal": 10, "units": "minutes"}, db, user)
    assert result["ok"] is True and result["created"] is True
    assert result["linked"] is False
    assert "created" in result["link_note"]
    assert db.query(Workout).filter(Workout.name == "Bodyweight Circuit").one_or_none() is not None


def test_suggestions_rank_by_covering_the_request():
    hits = exercise_db.suggest_names("Dumbbell Tricep Extensions", limit=5)
    assert hits
    top = hits[0]["name"].lower()
    assert "tricep" in top and "dumbbell" in top


def test_suggest_names_handles_unknown_input():
    assert exercise_db.suggest_names("") == []
    assert exercise_db.suggest_names("zzzzqqq") == []


# -- relink_workouts ---------------------------------------------------------

def test_relink_workouts_is_exposed():
    from routers.workout_agent import _READ_ONLY_TOOLS, _workout_tools_schema
    names = {t["function"]["name"] for t in _workout_tools_schema()}
    assert "relink_workouts" in names
    assert "relink_workouts" not in _READ_ONLY_TOOLS, "it writes, so it must be confirmable"


def test_relink_workouts_repairs_existing_unlinked_rows(db, user):
    """Workouts created before the matching fix must be repairable in place."""
    db.add(Workout(user_id=user.id, name="Pull-Ups", goal=10, units="reps", at_park=False))
    db.add(Workout(user_id=user.id, name="Bodyweight Circuit", goal=10, units="minutes", at_park=False))
    db.flush()

    result = _run("relink_workouts", {}, db, user)
    assert result["linked_count"] >= 1
    assert any(item["workout"] == "Pull-Ups" for item in result["linked"])

    repaired = db.query(Workout).filter(Workout.name == "Pull-Ups").one()
    assert repaired.exercise_id is not None

    leftover = [item["workout"] for item in result["still_unlinked"]]
    assert "Bodyweight Circuit" in leftover
    assert result["note"]


def test_relink_workouts_dry_run_writes_nothing(db, user):
    db.add(Workout(user_id=user.id, name="Push-Ups", goal=10, units="reps", at_park=False))
    db.flush()
    result = _run("relink_workouts", {}, db, user, dry_run=True)
    assert result["dry_run"] is True and result["linked_count"] >= 1
    assert db.query(Workout).filter(Workout.name == "Push-Ups").one().exercise_id is None


def test_relink_workouts_leaves_linked_workouts_alone(db, user):
    target = exercise_db.search_exercises("bench press", 1)[0]
    _run("create_workout", {"name": target["name"], "goal": 10, "units": "reps"}, db, user)
    result = _run("relink_workouts", {}, db, user)
    assert all(item["workout"] != target["name"] for item in result["linked"])


def test_prompt_tells_the_coach_to_search_before_naming():
    # Collapse whitespace: the prompt is wrapped with indentation, so asserting
    # on phrases that straddle a line break is brittle.
    from routers.workout_agent import _build_system_prompt
    prompt = " ".join(_build_system_prompt().lower().split())
    assert "search_exercises" in prompt
    assert "do not invent" in prompt
    assert "never tell the user it could not be created" in prompt
    assert "relink_workouts" in prompt
