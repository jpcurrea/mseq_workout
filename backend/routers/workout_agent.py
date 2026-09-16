"""
Workout coach agent — a conversational personal trainer over the workout data.

Mirrors the task agent in `routers/agent.py` (same LLM plumbing, BYO-key runtime,
spend cap, persistent compressed conversation memory, optional approval gate) but
with a workout-specific tool set and system prompt.
"""

from __future__ import annotations

import datetime
import json
from typing import Any, Dict, List, Optional, Tuple

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

import exercises as exercise_db
from database import (
    get_session,
    LLMConversation,
    LLMUsage,
    ScheduleEntry,
    User,
    Workout,
)
from dependencies import get_current_user_id
from routers.agent import (
    _KEEP_RECENT_MESSAGES,
    ChatMessage,
    _call_llm_message,
    _estimate_cost_usd,
    _resolve_runtime_for_user,
    _spend_cap_usd,
    _summarize_history,
    _total_spend_usd,
)
from routers.workouts import (
    MSEQ_BASE_DEFAULT,
    _compute_mseq_rate_stats,
    _validate_generation_params,
    generate_routine_for_user,
    list_routine_configurations,
    solve_routine_params,
    suggest_routine_params,
)

router = APIRouter(prefix="/workout-agent", tags=["workout-agent"])

# Single persistent thread per user; `project_id`/`related_plan_id` stay NULL.
WORKOUT_MODE = "workout_coach"

_MAX_TOOL_ITERATIONS = 8

# Tools that never mutate data — they always run for real, even under approval.
_READ_ONLY_TOOLS = {
    "get_current_datetime",
    "search_exercises",
    "list_exercise_filters",
    "get_exercise_details",
    "list_workouts",
    "get_schedule",
    "get_workout_history",
    "suggest_routine_params",
    "solve_routine_params",
    "list_routine_configurations",
    "preview_routine_stats",
}


# ── Request models ────────────────────────────────────────────────────────────

class WorkoutAgentChatRequest(BaseModel):
    messages: List[ChatMessage]
    require_approval: bool = False


class WorkoutToolCall(BaseModel):
    name: str
    args: Dict[str, Any] = {}


class ApplyWorkoutActionsRequest(BaseModel):
    tool_calls: List[WorkoutToolCall]


# ── Context ───────────────────────────────────────────────────────────────────

def _resolve_exercise_link(
    exercise_id: Any, workout_name: str
) -> Tuple[Optional[str], Optional[str], bool, List[Dict[str, Any]]]:
    """Resolve the free-exercise-db link for a workout.

    If the model supplied an exercise_id we validate it. If it didn't, we fall
    back to a name match so a workout the coach took from the database still
    gets linked — matching what the UI's exercise picker does.

    When nothing matches we return candidate exercises rather than just None.
    An unlinked workout is still a perfectly valid workout, but the coach used
    to treat a failed link as a failed creation; handing back real options
    makes the recoverable case obviously recoverable.

    Returns (exercise_id, exercise_name, auto_linked, suggestions).
    """
    if exercise_id:
        ex = exercise_db.find_exercise(str(exercise_id))
        if not ex:
            raise ValueError(f"exercise_id '{exercise_id}' is not in the exercise database")
        return str(exercise_id), ex["name"], False, []

    match = exercise_db.find_by_name(workout_name)
    if match:
        return match["id"], match["name"], True, []
    return None, None, False, exercise_db.suggest_names(workout_name, limit=5)


def _serialize_workout(w: Workout) -> Dict[str, Any]:
    return {
        "name": w.name,
        "goal": w.goal,
        "units": w.units,
        "at_park": bool(w.at_park),
        "exercise_id": w.exercise_id,
        "linked_to_exercise_db": w.exercise_id is not None,
    }


def _build_workout_context(session: Session, user_id: int) -> Dict[str, Any]:
    """Compact snapshot of the athlete's current state, injected each turn."""
    workouts = session.query(Workout).filter(Workout.user_id == user_id).all()
    today = datetime.date.today()
    horizon = today + datetime.timedelta(days=14)

    upcoming = (
        session.query(ScheduleEntry, Workout)
        .join(Workout, ScheduleEntry.workout_id == Workout.id)
        .filter(
            ScheduleEntry.user_id == user_id,
            ScheduleEntry.date >= today,
            ScheduleEntry.date <= horizon,
        )
        .order_by(ScheduleEntry.date.asc())
        .limit(60)
        .all()
    )

    recent = (
        session.query(ScheduleEntry, Workout)
        .join(Workout, ScheduleEntry.workout_id == Workout.id)
        .filter(
            ScheduleEntry.user_id == user_id,
            ScheduleEntry.date < today,
            ScheduleEntry.score.isnot(None),
        )
        .order_by(ScheduleEntry.date.desc())
        .limit(30)
        .all()
    )

    schedule_range = (
        session.query(
            ScheduleEntry.date.label("d"),
        )
        .filter(ScheduleEntry.user_id == user_id)
        .order_by(ScheduleEntry.date.asc())
        .first()
    )
    schedule_end = (
        session.query(ScheduleEntry.date)
        .filter(ScheduleEntry.user_id == user_id)
        .order_by(ScheduleEntry.date.desc())
        .first()
    )

    return {
        "today": today.isoformat(),
        "workouts": [_serialize_workout(w) for w in workouts],
        "workout_count": len(workouts),
        "schedule_start": schedule_range.d.isoformat() if schedule_range else None,
        "schedule_end": schedule_end.date.isoformat() if schedule_end else None,
        "phase_hint": (
            "phase_1_build_library"
            if not workouts
            else "phase_2_set_schedule" if not schedule_range
            else "maintaining"
        ),
        "upcoming_sessions": [
            {
                "date": entry.date.isoformat(),
                "workout": w.name,
                "goal": w.goal,
                "units": w.units,
                "at_park": bool(w.at_park),
                "score": entry.score,
            }
            for entry, w in upcoming
        ],
        "recent_logged_sessions": [
            {
                "date": entry.date.isoformat(),
                "workout": w.name,
                "score": entry.score,
                "goal": w.goal,
                "units": w.units,
            }
            for entry, w in recent
        ],
    }


# ── System prompt ─────────────────────────────────────────────────────────────

def _build_system_prompt() -> str:
    return (
        "You are Coach — a knowledgeable, encouraging strength & conditioning coach "
        "embedded in the user's workout app. You design and maintain their training "
        "routine through conversation.\n"
        "\n"
        "HOW THIS APP WORKS (important — the scheduling model is unusual):\n"
        "- The user keeps a library of WORKOUTS. Each workout has a name, a numeric "
        "  goal, a unit (e.g. reps, seconds, minutes, kg, miles), an at_park flag "
        "  (true = needs outdoor/park equipment), and optionally an exercise_id linking "
        "  it to the free-exercise-db for instructions and images.\n"
        "- The SCHEDULE is not a hand-written weekly split. It is generated from an "
        "  m-sequence, which spreads each workout pseudo-randomly and evenly across "
        "  time so no two workouts stay correlated. Parameters:\n"
        "    * mseq_base (2, 3, 5 or 9) and sequence_power (2-6) set the number of "
        "      slots: num_frames = base^power - 1.\n"
        "    * minimum_interval_days is the number of days between consecutive slots.\n"
        "    * active_symbols (1 .. base-1) controls training frequency — higher means "
        "      each workout is scheduled more often.\n"
        "    * Total schedule span = (num_frames - 1) * minimum_interval_days + 1 days.\n"
        "- generate_routine REPLACES THE ENTIRE EXISTING SCHEDULE, wiping logged future "
        "  entries. Never call it without the user explicitly agreeing in this turn.\n"
        "\n"
        "YOUR PROCESS — TWO PHASES, IN ORDER:\n"
        "\n"
        "PHASE 1 — AGREE THE WORKOUT LIBRARY. Do this first, and finish it before you "
        "talk about scheduling at all.\n"
        "- Understand the person: goals, experience, available equipment (home / gym / "
        "  park / bodyweight only), time per session, injuries or limitations. Ask at "
        "  most 2-3 questions per message; do not interrogate. If they've already told "
        "  you, don't ask again — check the context JSON and your memory first.\n"
        "- Propose a concrete set of workouts with names, goals and units. Talk it "
        "  through and adjust until the user is happy with the LIST ITSELF.\n"
        "- Before creating anything, call search_exercises for each movement and use "
        "  the id and the NAME EXACTLY AS THE DATABASE SPELLS IT. The database has its "
        "  own spellings — 'Pullups', not 'Pull-Ups'; 'Dumbbell Flyes', not 'Dumbbell "
        "  Flys'. You do not know the 873 names from memory, so do not invent them: "
        "  search, then copy. A workout created from a name you guessed usually ends "
        "  up with no instructions or images.\n"
        "- Where a search returns several variants ('Dumbbell Rows' could be a "
        "  one-arm, incline or upright row), pick the one that fits and tell the user "
        "  which you chose, or ask if it matters.\n"
        "- Create them with create_workout once agreed.\n"
        "- A workout that comes back unlinked was still CREATED and works fine — it "
        "  simply has no instructions or images. Never tell the user it could not be "
        "  created. If it matters, use link_suggestions or relink_workouts to fix it.\n"
        "- Some things the user wants are not single database exercises at all (a "
        "  'bodyweight circuit', a 'stretching routine'). Either create them as plain "
        "  unlinked workouts or split them into real exercises — just say which.\n"
        "- Then explicitly confirm the library is settled — say what the final list is "
        "  and ask whether they want to add or change anything before moving on.\n"
        "- Do NOT call solve_routine_params or generate_routine while the library is "
        "  still in flux. Every workout must exist first, because the right schedule "
        "  parameters depend on how many workouts there are.\n"
        "\n"
        "PHASE 2 — SET THE SCHEDULE. Only once the library is settled.\n"
        "- The ONLY schedule this app can produce is an m-sequence schedule, built by "
        "  generate_routine. You cannot create a rotation, a split, a weekly template, "
        "  an A/B/C cycle, or 'do these three on Monday'. Never describe the plan in "
        "  those terms, and never write out a schedule yourself in a message — if you "
        "  describe a shape the generator cannot produce, the user ends up with "
        "  something different from what you promised.\n"
        "- Listen for how the user phrases the goal and pass it straight through to "
        "  solve_routine_params, which searches every valid configuration:\n"
        "    'about 3 workouts a day'      -> target_workouts_per_training_day=3\n"
        "    'every other day'             -> target_train_every_n_days=2\n"
        "    '5 sessions a week'           -> target_sessions_per_week=5\n"
        "    'hit each workout weekly'     -> target_days_between_repeats=7\n"
        "  You can combine several at once — that is the normal case. Do NOT convert "
        "  '3 workouts a day, every other day' into a single sessions-per-week number "
        "  yourself; pass both targets and let the solver weigh them.\n"
        "- Never hand-pick mseq_base, sequence_power, minimum_interval_days or "
        "  active_symbols yourself. The relationship between them is not obvious and "
        "  guessing produces a schedule that does not match the request.\n"
        "- CRITICAL — the number of workouts per training day VARIES. The m-sequence "
        "  spreads workouts unevenly on purpose. A plan averaging 3.4 a day may have "
        "  days with 1 and days with 8. Always quote the average AND the range from "
        "  workouts_per_training_day_range, and say it varies day to day. Never promise "
        "  'exactly 3 each session' — that is never true.\n"
        "- Read match_quality and any note. If it is 'approximate' or 'poor', say "
        "  plainly what IS achievable and offer to add or remove workouts to get "
        "  closer. Do not present a poor match as if it were what they asked for.\n"
        "- If the user wants to explore rather than name a number — 'what are my "
        "  options?', 'can I train more often?', 'what if the schedule were shorter?' — "
        "  use list_routine_configurations to look across the whole space, and quote "
        "  achievable_sessions_per_week so expectations are set by what is actually "
        "  possible for their number of workouts.\n"
        "- Describe the leading option in plain language: roughly how many workouts on "
        "  a training day and how much that varies, how often training days come up, "
        "  and how long the schedule runs. Don't read out the raw parameters unless "
        "  asked.\n"
        "- Call preview_routine_stats with the chosen parameters to confirm, and check "
        "  stats.capacity. If every_workout_unique is false, some workouts will land on "
        "  exactly the same days as others — say so and pick different parameters.\n"
        "- Get an explicit yes, then call generate_routine with those exact parameters.\n"
        "- generate_routine REPLACES the entire existing schedule. Make sure the user "
        "  understands that before calling it.\n"
        "\n"
        "If the user already has a settled library and just wants to re-time things, go "
        "straight to Phase 2. If they want to change exercises, return to Phase 1 and "
        "regenerate the schedule afterwards.\n"
        "\n"
        "COACHING BEHAVIOUR:\n"
        "- Use search_exercises to ground every exercise you propose in the real "
        "  free-exercise-db. Filter by muscle, equipment, category, level, force "
        "  (push/pull/static) and mechanic (compound/isolation). Always attach the "
        "  returned exercise_id when creating a workout so the app can show "
        "  instructions and images. Never invent an exercise_id or an exercise name — "
        "  if it isn't in the database, pick the closest one that is.\n"
        "- Name the workout exactly as the database names it unless the user asks for "
        "  something different. Passing exercise_id is what links a workout to its "
        "  instructions and images, and a workout created without it is a worse "
        "  experience than one added by hand through the app.\n"
        "- If a search returns nothing, call list_exercise_filters and retry with a "
        "  valid value rather than guessing or giving up.\n"
        "- Build balanced programmes: roughly match push volume to pull volume, include "
        "  a knee-dominant and a hip-dominant leg movement, and add core work. Anchor "
        "  each session on compound lifts (mechanic='compound') and use isolation work "
        "  as accessories. Respect the equipment they actually have — filter by it — and "
        "  match volume to their stated time budget and level.\n"
        "- Set realistic starting goals based on their reported level and, when "
        "  available, get_workout_history. Progress goals gradually — if recent scores "
        "  consistently meet or beat the goal, propose a small increase and explain why.\n"
        "- When the user asks how to perform something, call get_exercise_details and "
        "  summarise the instructions in your own words.\n"
        "\n"
        "SAFETY:\n"
        "- You are a training coach, not a doctor. Do not diagnose, and do not give "
        "  medical, rehab, or nutrition-prescription advice. If the user mentions pain, "
        "  injury, dizziness, chest symptoms, pregnancy, or a medical condition, tell "
        "  them plainly to check with a qualified professional, and offer to work around "
        "  it with gentler alternatives rather than pushing through.\n"
        "- Prefer conservative starting loads and volumes. Emphasise warm-ups, form, "
        "  and rest days.\n"
        "\n"
        "STYLE:\n"
        "- Be warm, concise and concrete. Replies may be read aloud, so keep them short "
        "  and avoid markdown tables, long bullet lists, and raw JSON.\n"
        "- Be agentic: once the user agrees on a plan, actually call the tools to create "
        "  the workouts rather than describing what you would do. Confirm briefly "
        "  afterwards.\n"
        "- Before any destructive action (delete_workout, generate_routine), state "
        "  exactly what will happen and get an explicit yes."
    )


# ── Tool schemas ──────────────────────────────────────────────────────────────

def _workout_tools_schema() -> List[Dict[str, Any]]:
    return [
        {
            "type": "function",
            "function": {
                "name": "get_current_datetime",
                "description": (
                    "Return the current date and time (UTC). Use this to resolve "
                    "relative dates like 'today', 'next Monday', or 'in two weeks'."
                ),
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "list_exercise_filters",
                "description": (
                    "List every valid filter value for search_exercises (muscles, equipment, "
                    "categories, levels, force, mechanic) with how many exercises each has. "
                    "Call this if a search returns nothing, so you filter with real values "
                    "instead of guessing."
                ),
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "search_exercises",
                "description": (
                    "Search the free-exercise-db (873 exercises) by name and/or filters. "
                    "Always use this to find a real exercise_id before creating a workout. "
                    "Results include level, force and mechanic so you can judge difficulty "
                    "and balance without a follow-up call. Combine filters to build a "
                    "balanced programme, e.g. force='push' + equipment='dumbbell'."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Free text, e.g. 'romanian deadlift'. May be empty when filtering."},
                        "muscle": {
                            "type": "string",
                            "description": "Target muscle, e.g. abdominals, biceps, chest, glutes, hamstrings, lats, quadriceps, shoulders, triceps, calves, forearms, traps, middle back, lower back, adductors, abductors, neck.",
                        },
                        "equipment": {
                            "type": "string",
                            "description": "e.g. body only, dumbbell, barbell, kettlebells, bands, cable, machine, medicine ball, exercise ball, foam roll, e-z curl bar, other.",
                        },
                        "category": {
                            "type": "string",
                            "description": "strength, stretching, plyometrics, strongman, powerlifting, cardio, olympic weightlifting.",
                        },
                        "level": {"type": "string", "enum": ["beginner", "intermediate", "expert"]},
                        "force": {
                            "type": "string",
                            "enum": ["push", "pull", "static"],
                            "description": "Movement direction. Use this to balance push vs pull volume.",
                        },
                        "mechanic": {
                            "type": "string",
                            "enum": ["compound", "isolation"],
                            "description": "Prefer compound lifts for the core of a programme, isolation for accessories.",
                        },
                        "limit": {"type": "integer", "description": "Max results (default 8, max 25)."},
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_exercise_details",
                "description": "Full record for one exercise id: instructions, force, mechanic, level, muscles, equipment.",
                "parameters": {
                    "type": "object",
                    "properties": {"exercise_id": {"type": "string"}},
                    "required": ["exercise_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "list_workouts",
                "description": "List every workout in the user's library with goal, units, at_park and exercise_id.",
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_schedule",
                "description": "Scheduled sessions between two dates (inclusive), with logged scores.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "start_date": {"type": "string", "description": "YYYY-MM-DD. Defaults to today."},
                        "end_date": {"type": "string", "description": "YYYY-MM-DD. Defaults to start_date + 14 days."},
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_workout_history",
                "description": "Past logged scores for one workout, newest first. Use this to judge progress before changing a goal.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "Exact workout name."},
                        "limit": {"type": "integer", "description": "Max entries (default 20)."},
                    },
                    "required": ["name"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "solve_routine_params",
                "description": (
                    "Find the m-sequence parameters that best match how the user wants "
                    "to train. Searches every valid configuration exactly. ALWAYS use "
                    "this to pick schedule parameters — never work out mseq_base / "
                    "sequence_power / minimum_interval_days / active_symbols yourself. "
                    "Pass the user's wording directly as one or more targets rather than "
                    "converting it to a single number: 'about 3 workouts a day, every "
                    "other day' is target_workouts_per_training_day=3 AND "
                    "target_train_every_n_days=2. At least one target is required. "
                    "Check match_quality ('good' / 'approximate' / 'poor') and the note, "
                    "and when describing a result ALWAYS quote "
                    "workouts_per_training_day_range as well as the average, because the "
                    "number of workouts per day genuinely varies."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "target_workouts_per_training_day": {
                            "type": "number",
                            "description": (
                                "Average workouts on a day the user actually trains. Use for "
                                "'about 3 workouts a day'. The real count varies around this."
                            ),
                        },
                        "target_train_every_n_days": {
                            "type": "number",
                            "description": (
                                "Average gap between training days. 'Every other day' is 2, "
                                "'daily' is 1, 'a few times a week' is about 2.5."
                            ),
                        },
                        "target_sessions_per_week": {
                            "type": "number",
                            "description": (
                                "Total workout sessions per week across ALL workouts. If the "
                                "user says '3 days a week' and each day has 2 workouts, that is 6."
                            ),
                        },
                        "target_days_between_repeats": {
                            "type": "number",
                            "description": (
                                "Average days before the SAME workout comes round again. Use "
                                "for 'hit each muscle group weekly' (7)."
                            ),
                        },
                        "weights": {
                            "type": "object",
                            "description": (
                                "Optional relative importance per target, keyed by the target "
                                "name, default 1. Use when the user says one goal matters more, "
                                "e.g. {\"target_workouts_per_training_day\": 3}."
                            ),
                            "additionalProperties": {"type": "number"},
                        },
                        "max_span_days": {
                            "type": "integer",
                            "description": (
                                "Preferred length of the generated schedule in days. Defaults "
                                "to 365. The search widens automatically if nothing fits."
                            ),
                        },
                        "max_results": {"type": "integer", "description": "How many options to return (default 3)."},
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "list_routine_configurations",
                "description": (
                    "Browse the full space of valid schedule configurations with the "
                    "training frequency each one produces — the same parameters and live "
                    "stats the generation screen shows, for every combination at once. "
                    "Use this when the user wants to explore options, asks what is "
                    "possible, wants to trade off frequency against schedule length, or "
                    "asks about a specific base/interval. Use suggest_routine_params "
                    "instead when they have simply told you a target frequency. Check "
                    "achievable_sessions_per_week before promising anything."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "mseq_base": {
                            "type": "integer",
                            "enum": [2, 3, 5, 9],
                            "description": "Restrict to one base. Omit to see all.",
                        },
                        "minimum_interval_days": {
                            "type": "integer",
                            "description": "Restrict to one spacing, 1-14. Omit to see all.",
                        },
                        "min_sessions_per_week": {"type": "number"},
                        "max_sessions_per_week": {"type": "number"},
                        "max_span_days": {"type": "integer", "description": "Only schedules no longer than this."},
                        "collision_free_only": {
                            "type": "boolean",
                            "description": (
                                "Default true — hide configurations where some workouts "
                                "would share an identical schedule."
                            ),
                        },
                        "sort_by": {
                            "type": "string",
                            "enum": ["sessions_per_week", "schedule_span_days", "days_between_sessions"],
                        },
                        "limit": {"type": "integer", "description": "Max rows (default 30, max 100)."},
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "preview_routine_stats",
                "description": (
                    "Non-destructive preview of the training frequency that a given set of "
                    "m-sequence parameters would produce. Call this before generate_routine "
                    "to confirm the chosen parameters, and check stats.capacity for schedule "
                    "collisions."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "sequence_power": {"type": "integer"},
                        "minimum_interval_days": {"type": "integer"},
                        "mseq_base": {"type": "integer", "enum": [2, 3, 5, 9]},
                        "active_symbols": {"type": "integer"},
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "create_workout",
                "description": (
                    "Add a workout to the user's library. Names must be unique. "
                    "Search the exercise database FIRST and pass the exercise_id you "
                    "get back, so the workout gets instructions and images. A workout "
                    "created without a link is still created and fully usable — never "
                    "tell the user it failed."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": (
                            "Use the database's own name verbatim when the exercise came "
                            "from a search — don't restyle it."
                        )},
                        "goal": {"type": "number", "description": "Target amount per session."},
                        "units": {"type": "string", "description": "e.g. reps, seconds, minutes, kg, lbs, miles."},
                        "at_park": {"type": "boolean", "description": "True if it needs outdoor/park equipment. Default false."},
                        "exercise_id": {"type": "string", "description": (
                            "free-exercise-db id from search_exercises. Always pass this "
                            "when the exercise came from the database. If omitted, the "
                            "workout is auto-linked when its name matches a database "
                            "entry, ignoring case, punctuation and a trailing 's'."
                        )},
                    },
                    "required": ["name", "goal", "units"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "relink_workouts",
                "description": (
                    "Retry the exercise-database link for every workout that currently "
                    "has none. Use when the user says a workout is missing instructions "
                    "or images, or after creating workouts that came back unlinked. "
                    "Returns what got linked, plus link_suggestions for the ones still "
                    "unmatched so you can offer the user a real choice."
                ),
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "update_workout",
                "description": "Change an existing workout's goal, units, park flag, linked exercise, or name.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "Current workout name."},
                        "goal": {"type": "number"},
                        "units": {"type": "string"},
                        "at_park": {"type": "boolean"},
                        "exercise_id": {"type": "string"},
                        "new_name": {"type": "string"},
                    },
                    "required": ["name"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "delete_workout",
                "description": "Permanently remove a workout and all of its scheduled sessions. Destructive — confirm first.",
                "parameters": {
                    "type": "object",
                    "properties": {"name": {"type": "string"}},
                    "required": ["name"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "log_score",
                "description": "Record the score the user achieved for a scheduled workout on a given date.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "workout": {"type": "string"},
                        "date": {"type": "string", "description": "YYYY-MM-DD."},
                        "score": {"type": "number"},
                    },
                    "required": ["workout", "date", "score"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "generate_routine",
                "description": (
                    "Regenerate the training schedule from the workout library. DESTRUCTIVE: "
                    "erases the entire existing schedule, including logged scores. Requires "
                    "explicit user confirmation in the current turn."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "start_date": {"type": "string", "description": "YYYY-MM-DD. Defaults to today."},
                        "sequence_power": {"type": "integer", "description": "2-6, must be valid for mseq_base."},
                        "minimum_interval_days": {"type": "integer", "description": "1-14 days between slots."},
                        "mseq_base": {"type": "integer", "enum": [2, 3, 5, 9]},
                        "active_symbols": {"type": "integer", "description": "1 .. mseq_base-1; higher = train more often."},
                    },
                    "required": [],
                },
            },
        },
    ]


# ── Tool execution ────────────────────────────────────────────────────────────

def _parse_date(value: Optional[str], field: str) -> Optional[datetime.date]:
    if not value:
        return None
    try:
        return datetime.datetime.strptime(value.strip(), "%Y-%m-%d").date()
    except ValueError:
        raise ValueError(f"{field} must be YYYY-MM-DD")


def _get_workout(session: Session, user_id: int, name: str) -> Workout:
    workout = (
        session.query(Workout)
        .filter(Workout.user_id == user_id, Workout.name == name)
        .first()
    )
    if not workout:
        raise ValueError(f"No workout named '{name}'. Call list_workouts to see valid names.")
    return workout


def _execute_workout_tool_call(
    *,
    name: str,
    args: Dict[str, Any],
    user_id: int,
    session: Session,
    dry_run: bool = False,
) -> Dict[str, Any]:
    """Run one tool. `dry_run` validates a mutating tool without committing."""

    if name == "get_current_datetime":
        now = datetime.datetime.utcnow()
        return {
            "ok": True,
            "action": name,
            "utc_datetime": now.isoformat(timespec="minutes"),
            "date": now.date().isoformat(),
            "weekday": now.strftime("%A"),
        }

    if name == "list_exercise_filters":
        return {"ok": True, "action": name, "filters": exercise_db.facets()}

    if name == "search_exercises":
        limit = int(args.get("limit") or 8)
        results = exercise_db.search_exercises(
            str(args.get("query") or ""),
            limit=max(1, min(limit, 25)),
            muscle=args.get("muscle"),
            equipment=args.get("equipment"),
            category=args.get("category"),
            level=args.get("level"),
            force=args.get("force"),
            mechanic=args.get("mechanic"),
        )
        return {
            "ok": True,
            "action": name,
            "count": len(results),
            "results": [
                {
                    "id": r["id"],
                    "name": r["name"],
                    "equipment": r["equipment"],
                    "primaryMuscles": r["primaryMuscles"],
                    "level": r["level"],
                    "force": r["force"],
                    "mechanic": r["mechanic"],
                }
                for r in results
            ],
        }

    if name == "get_exercise_details":
        ex = exercise_db.find_exercise(str(args.get("exercise_id") or ""))
        if not ex:
            raise ValueError("Unknown exercise_id. Use search_exercises to find a valid id.")
        return {
            "ok": True,
            "action": name,
            "exercise": {
                "id": ex["id"],
                "name": ex["name"],
                "level": ex.get("level"),
                "force": ex.get("force"),
                "mechanic": ex.get("mechanic"),
                "equipment": ex.get("equipment"),
                "category": ex.get("category"),
                "primaryMuscles": ex.get("primaryMuscles", []),
                "secondaryMuscles": ex.get("secondaryMuscles", []),
                "instructions": ex.get("instructions", []),
            },
        }

    if name == "list_workouts":
        workouts = session.query(Workout).filter(Workout.user_id == user_id).all()
        return {
            "ok": True,
            "action": name,
            "count": len(workouts),
            "workouts": [_serialize_workout(w) for w in workouts],
        }

    if name == "get_schedule":
        start = _parse_date(args.get("start_date"), "start_date") or datetime.date.today()
        end = _parse_date(args.get("end_date"), "end_date") or (start + datetime.timedelta(days=14))
        if end < start:
            raise ValueError("end_date must not be before start_date")
        rows = (
            session.query(ScheduleEntry, Workout)
            .join(Workout, ScheduleEntry.workout_id == Workout.id)
            .filter(
                ScheduleEntry.user_id == user_id,
                ScheduleEntry.date >= start,
                ScheduleEntry.date <= end,
            )
            .order_by(ScheduleEntry.date.asc())
            .limit(200)
            .all()
        )
        return {
            "ok": True,
            "action": name,
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "sessions": [
                {
                    "date": entry.date.isoformat(),
                    "workout": w.name,
                    "goal": w.goal,
                    "units": w.units,
                    "at_park": bool(w.at_park),
                    "score": entry.score,
                }
                for entry, w in rows
            ],
        }

    if name == "get_workout_history":
        workout = _get_workout(session, user_id, str(args.get("name") or ""))
        limit = max(1, min(int(args.get("limit") or 20), 100))
        rows = (
            session.query(ScheduleEntry)
            .filter(
                ScheduleEntry.user_id == user_id,
                ScheduleEntry.workout_id == workout.id,
                ScheduleEntry.score.isnot(None),
            )
            .order_by(ScheduleEntry.date.desc())
            .limit(limit)
            .all()
        )
        scores = [r.score for r in rows]
        return {
            "ok": True,
            "action": name,
            "workout": workout.name,
            "goal": workout.goal,
            "units": workout.units,
            "logged_count": len(scores),
            "best": max(scores) if scores else None,
            "average": round(sum(scores) / len(scores), 2) if scores else None,
            "history": [{"date": r.date.isoformat(), "score": r.score} for r in rows],
        }

    if name == "solve_routine_params":
        workout_count = session.query(Workout).filter(Workout.user_id == user_id).count()
        if workout_count == 0:
            raise ValueError(
                "No workouts exist yet. Finish agreeing the workout library before "
                "choosing a schedule."
            )
        targets = {
            key: float(args[key])
            for key in (
                "target_sessions_per_week",
                "target_workouts_per_training_day",
                "target_train_every_n_days",
                "target_days_between_repeats",
            )
            if args.get(key) is not None
        }
        if not targets:
            raise ValueError(
                "Provide at least one target, e.g. target_workouts_per_training_day "
                "or target_train_every_n_days."
            )
        raw_weights = args.get("weights") or {}
        if not isinstance(raw_weights, dict):
            raise ValueError("weights must be an object keyed by target name")
        return {
            "ok": True,
            "action": name,
            **solve_routine_params(
                workout_count=workout_count,
                weights={k: float(v) for k, v in raw_weights.items()},
                max_results=int(args.get("max_results") or 3),
                max_span_days=int(args["max_span_days"]) if args.get("max_span_days") else 365,
                **targets,
            ),
        }

    if name == "suggest_routine_params":
        workout_count = session.query(Workout).filter(Workout.user_id == user_id).count()
        target = args.get("target_sessions_per_week")
        if target is None:
            raise ValueError("target_sessions_per_week is required")
        return {
            "ok": True,
            "action": name,
            **suggest_routine_params(
                workout_count=workout_count,
                target_sessions_per_week=float(target),
                max_results=int(args.get("max_results") or 3),
                max_span_days=int(args["max_span_days"]) if args.get("max_span_days") else 365,
            ),
        }

    if name == "list_routine_configurations":
        workout_count = session.query(Workout).filter(Workout.user_id == user_id).count()
        return {
            "ok": True,
            "action": name,
            **list_routine_configurations(
                workout_count=workout_count,
                mseq_base=int(args["mseq_base"]) if args.get("mseq_base") else None,
                minimum_interval_days=(
                    int(args["minimum_interval_days"]) if args.get("minimum_interval_days") else None
                ),
                min_sessions_per_week=(
                    float(args["min_sessions_per_week"]) if args.get("min_sessions_per_week") else None
                ),
                max_sessions_per_week=(
                    float(args["max_sessions_per_week"]) if args.get("max_sessions_per_week") else None
                ),
                max_span_days=int(args["max_span_days"]) if args.get("max_span_days") else None,
                collision_free_only=bool(args.get("collision_free_only", True)),
                sort_by=str(args.get("sort_by") or "sessions_per_week"),
                limit=int(args.get("limit") or 30),
            ),
        }

    if name == "preview_routine_stats":
        sequence_power = int(args.get("sequence_power") or 4)
        minimum_interval_days = int(args.get("minimum_interval_days") or 2)
        mseq_base = int(args.get("mseq_base") or MSEQ_BASE_DEFAULT)
        active_symbols = int(args.get("active_symbols") or 1)
        _validate_generation_params(sequence_power, minimum_interval_days, mseq_base, active_symbols)
        workout_count = session.query(Workout).filter(Workout.user_id == user_id).count()
        stats = _compute_mseq_rate_stats(
            workout_count=workout_count,
            sequence_power=sequence_power,
            minimum_interval_days=minimum_interval_days,
            mseq_base=mseq_base,
            active_symbols=active_symbols,
        )
        return {"ok": True, "action": name, "params": {
            "sequence_power": sequence_power,
            "minimum_interval_days": minimum_interval_days,
            "mseq_base": mseq_base,
            "active_symbols": active_symbols,
        }, "stats": stats}

    # ── Mutating tools ────────────────────────────────────────────────────────

    if name == "create_workout":
        workout_name = str(args.get("name") or "").strip()
        if not workout_name:
            raise ValueError("name is required")
        units = str(args.get("units") or "").strip()
        if not units:
            raise ValueError("units is required")
        goal = float(args.get("goal"))
        exercise_id, linked_exercise, auto_linked, suggestions = _resolve_exercise_link(
            args.get("exercise_id"), workout_name
        )
        existing = (
            session.query(Workout)
            .filter(Workout.user_id == user_id, Workout.name == workout_name)
            .first()
        )
        if existing:
            raise ValueError(f"A workout named '{workout_name}' already exists — use update_workout instead")
        if dry_run:
            return {
                "ok": True,
                "action": name,
                "dry_run": True,
                "name": workout_name,
                "exercise_id": exercise_id,
                "linked_exercise": linked_exercise,
                "auto_linked": auto_linked,
            }
        session.add(Workout(
            user_id=user_id,
            name=workout_name,
            goal=goal,
            units=units,
            at_park=bool(args.get("at_park", False)),
            exercise_id=exercise_id,
        ))
        session.commit()
        result = {
            "ok": True,
            "action": name,
            # Stated explicitly because linking is optional: the coach has
            # previously read a null exercise_id as "creation failed" and told
            # the user the workout did not exist.
            "created": True,
            "name": workout_name,
            "goal": goal,
            "units": units,
            "exercise_id": exercise_id,
            "linked_exercise": linked_exercise,
            "auto_linked": auto_linked,
        }
        if exercise_id is None:
            result["linked"] = False
            result["link_note"] = (
                f"'{workout_name}' was created and is fully usable, but no exercise "
                "in the database has that name, so it has no instructions or images."
            )
            if suggestions:
                result["link_suggestions"] = suggestions
                result["link_note"] += (
                    " Close matches are listed in link_suggestions — if one is what "
                    "the user meant, call update_workout with its exercise_id "
                    "(and new_name to match). Otherwise leave it as is."
                )
        return result

    if name == "relink_workouts":
        unlinked = (
            session.query(Workout)
            .filter(Workout.user_id == user_id, Workout.exercise_id.is_(None))
            .all()
        )
        linked, still_unlinked = [], []
        for w in unlinked:
            match = exercise_db.find_by_name(w.name)
            if match:
                if not dry_run:
                    w.exercise_id = match["id"]
                linked.append({"workout": w.name, "exercise": match["name"], "exercise_id": match["id"]})
            else:
                still_unlinked.append({
                    "workout": w.name,
                    "link_suggestions": exercise_db.suggest_names(w.name, limit=5),
                })
        if not dry_run and linked:
            session.commit()
        return {
            "ok": True,
            "action": name,
            "dry_run": dry_run,
            "checked": len(unlinked),
            "linked_count": len(linked),
            "linked": linked,
            "still_unlinked": still_unlinked,
            "note": (
                "Workouts in still_unlinked have no database entry with that name. "
                "They work fine without a link — they just have no instructions or "
                "images. Offer the user the link_suggestions, and only rename to a "
                "suggestion if they agree."
            ) if still_unlinked else None,
        }

    if name == "update_workout":
        workout = _get_workout(session, user_id, str(args.get("name") or ""))
        new_name = (args.get("new_name") or "").strip()
        if new_name and new_name != workout.name:
            clash = (
                session.query(Workout)
                .filter(Workout.user_id == user_id, Workout.name == new_name, Workout.id != workout.id)
                .first()
            )
            if clash:
                raise ValueError(f"A workout named '{new_name}' already exists")
        if "exercise_id" in args and args["exercise_id"]:
            if not exercise_db.find_exercise(str(args["exercise_id"])):
                raise ValueError(f"exercise_id '{args['exercise_id']}' is not in the exercise database")
        if dry_run:
            return {"ok": True, "action": name, "dry_run": True, "name": workout.name}
        if new_name:
            workout.name = new_name
        if args.get("goal") is not None:
            workout.goal = float(args["goal"])
        if args.get("units"):
            workout.units = str(args["units"])
        if args.get("at_park") is not None:
            workout.at_park = bool(args["at_park"])
        if "exercise_id" in args:
            workout.exercise_id = args["exercise_id"] or None
        elif workout.exercise_id is None:
            # A rename may have turned an unlinked workout into one that matches
            # the database exactly.
            match = exercise_db.find_by_name(workout.name)
            if match:
                workout.exercise_id = match["id"]
        session.commit()
        return {
            "ok": True,
            "action": name,
            "name": workout.name,
            "goal": workout.goal,
            "units": workout.units,
            "exercise_id": workout.exercise_id,
        }

    if name == "delete_workout":
        workout = _get_workout(session, user_id, str(args.get("name") or ""))
        if dry_run:
            return {"ok": True, "action": name, "dry_run": True, "name": workout.name}
        session.query(ScheduleEntry).filter(
            ScheduleEntry.user_id == user_id,
            ScheduleEntry.workout_id == workout.id,
        ).delete()
        session.delete(workout)
        session.commit()
        return {"ok": True, "action": name, "name": workout.name}

    if name == "log_score":
        workout = _get_workout(session, user_id, str(args.get("workout") or ""))
        target_date = _parse_date(args.get("date"), "date")
        if target_date is None:
            raise ValueError("date is required (YYYY-MM-DD)")
        entry = (
            session.query(ScheduleEntry)
            .filter(
                ScheduleEntry.user_id == user_id,
                ScheduleEntry.workout_id == workout.id,
                ScheduleEntry.date == target_date,
            )
            .first()
        )
        if not entry:
            raise ValueError(f"'{workout.name}' is not scheduled on {target_date.isoformat()}")
        score = float(args.get("score"))
        if dry_run:
            return {"ok": True, "action": name, "dry_run": True, "workout": workout.name, "date": target_date.isoformat()}
        entry.score = score
        session.commit()
        return {"ok": True, "action": name, "workout": workout.name, "date": target_date.isoformat(), "score": score}

    if name == "generate_routine":
        sequence_power = int(args.get("sequence_power") or 4)
        minimum_interval_days = int(args.get("minimum_interval_days") or 2)
        mseq_base = int(args.get("mseq_base") or MSEQ_BASE_DEFAULT)
        active_symbols = int(args.get("active_symbols") or 1)
        _validate_generation_params(sequence_power, minimum_interval_days, mseq_base, active_symbols)
        workout_count = session.query(Workout).filter(Workout.user_id == user_id).count()
        if workout_count == 0:
            raise ValueError("Add at least one workout before generating a routine")
        if dry_run:
            return {
                "ok": True,
                "action": name,
                "dry_run": True,
                "warning": "This will erase the entire existing schedule.",
                "stats": _compute_mseq_rate_stats(
                    workout_count=workout_count,
                    sequence_power=sequence_power,
                    minimum_interval_days=minimum_interval_days,
                    mseq_base=mseq_base,
                    active_symbols=active_symbols,
                ),
            }
        result = generate_routine_for_user(
            session,
            user_id,
            start_date=args.get("start_date"),
            sequence_power=sequence_power,
            minimum_interval_days=minimum_interval_days,
            mseq_base=mseq_base,
            active_symbols=active_symbols,
        )
        return {"ok": True, "action": name, **result}

    raise ValueError(f"Unknown tool: {name}")


# ── Conversation persistence ──────────────────────────────────────────────────

def _find_conversation(session: Session, user_id: int) -> Optional[LLMConversation]:
    return (
        session.query(LLMConversation)
        .filter(
            LLMConversation.user_id == user_id,
            LLMConversation.mode == WORKOUT_MODE,
        )
        .order_by(LLMConversation.updated_at.desc())
        .first()
    )


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/chat")
async def workout_agent_chat(
    body: WorkoutAgentChatRequest,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    user = session.query(User).filter(User.id == user_id).first()
    base_url, model, api_key, timeout_sec, using_user_key = _resolve_runtime_for_user(user)
    runtime = (base_url, model, api_key, timeout_sec)

    spend_cap = _spend_cap_usd()
    spent_before = _total_spend_usd(session)
    if not using_user_key and spent_before >= spend_cap:
        raise HTTPException(
            status_code=429,
            detail=(
                f"LLM spending cap reached (${spent_before:.2f} of ${spend_cap:.2f}). "
                "Add your own API key in AI settings, or increase LLM_SPEND_CAP_USD to continue."
            ),
        )

    context_payload = _build_workout_context(session, user_id)
    convo = _find_conversation(session, user_id)
    prior_summary = convo.summary if convo else None

    now_utc = datetime.datetime.utcnow()
    llm_messages: List[Dict[str, Any]] = [
        {
            "role": "system",
            "content": _build_system_prompt()
            + (
                f"\n\nCURRENT DATE/TIME (UTC): {now_utc.strftime('%Y-%m-%d %H:%M')} "
                f"({now_utc.strftime('%A')}). Treat this as 'today'."
            ),
        },
        {
            "role": "system",
            "content": "Athlete context JSON (do not read raw JSON aloud):\n"
            + json.dumps(context_payload, ensure_ascii=True),
        },
    ]
    if prior_summary:
        llm_messages.append({
            "role": "system",
            "content": "Compressed memory of earlier conversation turns:\n" + prior_summary,
        })
    llm_messages.extend([m.model_dump() for m in body.messages])

    tool_defs = _workout_tools_schema()
    executed_actions: List[Dict[str, Any]] = []
    proposed_tool_calls: List[Dict[str, Any]] = []
    reply: Optional[str] = None
    total_prompt_tokens = 0
    total_completion_tokens = 0

    for _ in range(_MAX_TOOL_ITERATIONS):
        ai_msg = await _call_llm_message(messages=llm_messages, model=model, tools=tool_defs, runtime=runtime)
        if isinstance(ai_msg, dict):
            usage = ai_msg.pop("_usage", None)
            if usage:
                total_prompt_tokens += usage.get("prompt_tokens", 0)
                total_completion_tokens += usage.get("completion_tokens", 0)
        tool_calls = ai_msg.get("tool_calls") if isinstance(ai_msg, dict) else None

        if not tool_calls:
            reply = (ai_msg.get("content") if isinstance(ai_msg, dict) else None) or ""
            break

        llm_messages.append({
            "role": "assistant",
            "content": ai_msg.get("content") or "",
            "tool_calls": tool_calls,
        })

        for tool_call in tool_calls:
            fn = tool_call.get("function", {})
            tool_name = fn.get("name")
            try:
                parsed_args = json.loads(fn.get("arguments") or "{}")
                if not isinstance(parsed_args, dict):
                    raise ValueError("Tool arguments must be a JSON object")
                is_mutating = tool_name not in _READ_ONLY_TOOLS
                result = _execute_workout_tool_call(
                    name=tool_name,
                    args=parsed_args,
                    user_id=user_id,
                    session=session,
                    dry_run=body.require_approval and is_mutating,
                )
                if body.require_approval and is_mutating and result.get("ok"):
                    proposed_tool_calls.append({"name": tool_name, "args": parsed_args})
            except HTTPException as exc:
                session.rollback()
                result = {"ok": False, "action": tool_name, "error": str(exc.detail)}
            except Exception as exc:
                session.rollback()
                result = {"ok": False, "action": tool_name, "error": str(exc)}

            executed_actions.append(result)
            llm_messages.append({
                "role": "tool",
                "tool_call_id": tool_call.get("id"),
                "content": json.dumps(result, ensure_ascii=True, default=str),
            })

        # In approval mode, stop once something is queued — otherwise the model
        # sees the dry-run "ok" results and proposes the same actions again.
        if proposed_tool_calls:
            break

    if (reply is None or not reply.strip()) and executed_actions:
        llm_messages.append({
            "role": "system",
            "content": (
                "Stop calling tools. In one or two short sentences, tell the user what "
                "you just did or found, and what the next step is."
            ),
        })
        final_msg = await _call_llm_message(messages=llm_messages, model=model, runtime=runtime)
        if isinstance(final_msg, dict):
            usage = final_msg.pop("_usage", None)
            if usage:
                total_prompt_tokens += usage.get("prompt_tokens", 0)
                total_completion_tokens += usage.get("completion_tokens", 0)
            reply = final_msg.get("content") or reply

    if reply is None or not reply.strip():
        ok_count = sum(1 for a in executed_actions if a.get("ok"))
        reply = (
            f"Done — applied {ok_count} change(s) to your training."
            if executed_actions
            else "I wasn't able to produce a response. Try rephrasing that."
        )

    history = [m.model_dump() for m in body.messages]
    history.append({"role": "assistant", "content": reply})

    new_summary = prior_summary
    stored_messages = history
    if len(history) > _KEEP_RECENT_MESSAGES:
        overflow = history[: len(history) - _KEEP_RECENT_MESSAGES]
        recent = history[len(history) - _KEEP_RECENT_MESSAGES:]
        try:
            new_summary, sp, sc = await _summarize_history(prior_summary, overflow, model, runtime=runtime)
            total_prompt_tokens += sp
            total_completion_tokens += sc
            stored_messages = recent
        except Exception:
            stored_messages = history  # keep full this round; compress next time

    saved_at = datetime.datetime.utcnow()
    if convo is None:
        convo = LLMConversation(
            user_id=user_id,
            mode=WORKOUT_MODE,
            related_plan_id=None,
            project_id=None,
            created_at=saved_at,
        )
        session.add(convo)
    convo.messages = json.dumps(stored_messages, ensure_ascii=True)
    convo.summary = new_summary
    convo.updated_at = saved_at

    request_cost = _estimate_cost_usd(model, total_prompt_tokens, total_completion_tokens)
    if not using_user_key and (total_prompt_tokens or total_completion_tokens):
        session.add(LLMUsage(
            user_id=user_id,
            model=model,
            prompt_tokens=total_prompt_tokens,
            completion_tokens=total_completion_tokens,
            cost_usd=request_cost,
            created_at=saved_at,
        ))
    session.commit()

    return {
        "reply": reply,
        "mode": WORKOUT_MODE,
        "model": model,
        "actions": executed_actions,
        "pending_approval": body.require_approval and len(proposed_tool_calls) > 0,
        "proposed_tool_calls": proposed_tool_calls,
        "context_summary": {
            "workouts_considered": context_payload.get("workout_count", 0),
            "upcoming_sessions_considered": len(context_payload.get("upcoming_sessions", [])),
        },
        "usage": {
            "request_cost_usd": round(request_cost, 6) if not using_user_key else 0.0,
            "total_spend_usd": round(spent_before + (0.0 if using_user_key else request_cost), 4),
            "spend_cap_usd": spend_cap,
            "using_own_key": using_user_key,
        },
        "conversation_id": convo.id,
    }


@router.post("/apply-actions")
async def apply_workout_actions(
    body: ApplyWorkoutActionsRequest,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """Commit tool calls that were queued by a require_approval=true chat turn."""
    results: List[Dict[str, Any]] = []
    for call in body.tool_calls:
        if call.name in _READ_ONLY_TOOLS:
            results.append({"ok": False, "action": call.name, "error": "Read-only tool needs no approval"})
            continue
        try:
            results.append(
                _execute_workout_tool_call(
                    name=call.name,
                    args=call.args,
                    user_id=user_id,
                    session=session,
                    dry_run=False,
                )
            )
        except HTTPException as exc:
            session.rollback()
            results.append({"ok": False, "action": call.name, "error": str(exc.detail)})
        except Exception as exc:
            session.rollback()
            results.append({"ok": False, "action": call.name, "error": str(exc)})
    return {"results": results, "applied": sum(1 for r in results if r.get("ok"))}


@router.get("/conversation")
async def get_workout_conversation(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    convo = _find_conversation(session, user_id)
    if not convo:
        return {"messages": [], "summary": None, "has_memory": False}
    try:
        messages = json.loads(convo.messages or "[]")
    except json.JSONDecodeError:
        messages = []
    return {
        "messages": messages,
        "summary": convo.summary,
        "has_memory": bool(convo.summary),
        "conversation_id": convo.id,
        "updated_at": convo.updated_at.isoformat() if convo.updated_at else None,
    }


@router.delete("/conversation")
async def clear_workout_conversation(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    deleted = (
        session.query(LLMConversation)
        .filter(LLMConversation.user_id == user_id, LLMConversation.mode == WORKOUT_MODE)
        .delete()
    )
    session.commit()
    return {"deleted": deleted}
