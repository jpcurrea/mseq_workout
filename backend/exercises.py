"""
Exercise database loader — extracted so both main.py (startup) and routers can share it.

IMPORTANT: `load_exercises()` mutates the module-level containers **in place**.
Rebinding them (``_EXERCISES = [...]``) silently breaks any module that did
``from exercises import _EXERCISES`` at import time, because that module keeps
referencing the original (empty) object. Consumers should prefer the accessor
functions below (`all_exercises`, `find_exercise`, `search_exercises`).
"""
import os
import json
import re
from typing import Any, Dict, List, Optional

from database import get_data_dir

_EXERCISES: List[Dict[str, Any]] = []
_EXERCISES_IDX: Dict[str, Dict[str, Any]] = {}
_EXERCISES_BY_NAME: Dict[str, Dict[str, Any]] = {}
EXERCISE_IMAGE_BASE = (
    "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises"
)

_PUNCTUATION = re.compile(r"[^a-z0-9]+")


def _normalize_name(name: str) -> str:
    """Fold the ways the same exercise gets written differently.

    Drops case, whitespace and punctuation, then a single trailing 's'. This is
    what lets 'Pull-Ups' find 'Pullups' and 'Planks' find 'Plank' — writing
    variants people and language models use constantly, which an exact match
    would reject even though there is only one exercise it could possibly mean.

    Still a deterministic fold, NOT fuzzy matching: two names either normalise
    to the same key or they don't. Verified collision-free across all 873
    exercises, so it can never link a workout to the wrong entry. Genuinely
    ambiguous names like 'Dumbbell Rows' (dozens of row variants) still fail to
    match, which is correct — see suggest_names().
    """
    key = _PUNCTUATION.sub("", str(name).casefold())
    return key[:-1] if key.endswith("s") else key


def _exercises_path() -> Optional[str]:
    path = os.path.join(get_data_dir(), "exercises.json")
    if os.path.exists(path):
        return path
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "exercises.json")
    return path if os.path.exists(path) else None


def load_exercises() -> None:
    path = _exercises_path()
    if not path:
        print("Warning: exercises.json not found — exercise autocomplete disabled")
        return

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    # Mutate in place — see module docstring.
    _EXERCISES.clear()
    _EXERCISES.extend(data)
    _EXERCISES_IDX.clear()
    _EXERCISES_IDX.update({ex["id"]: ex for ex in _EXERCISES if ex.get("id")})
    _EXERCISES_BY_NAME.clear()
    _EXERCISES_BY_NAME.update({
        _normalize_name(ex["name"]): ex for ex in _EXERCISES if ex.get("name")
    })
    print(f"Loaded {len(_EXERCISES)} exercises from {path}")


def _ensure_loaded() -> None:
    """Lazy-load safety net for contexts that skip the FastAPI startup event (e.g. tests)."""
    if not _EXERCISES:
        load_exercises()


def image_url(exercise: Dict[str, Any]) -> str:
    return f"{EXERCISE_IMAGE_BASE}/{exercise['id']}/0.jpg"


def all_exercises() -> List[Dict[str, Any]]:
    _ensure_loaded()
    return _EXERCISES


def find_exercise(exercise_id: str) -> Optional[Dict[str, Any]]:
    _ensure_loaded()
    return _EXERCISES_IDX.get(exercise_id)


def find_by_name(name: str) -> Optional[Dict[str, Any]]:
    """Exact name lookup under the normalisation in _normalize_name.

    Deliberately not fuzzy: this auto-links workouts to the database, and a
    near-miss would silently attach the wrong instructions and images.
    """
    if not name:
        return None
    _ensure_loaded()
    return _EXERCISES_BY_NAME.get(_normalize_name(name))


def suggest_names(name: str, limit: int = 5) -> List[Dict[str, Any]]:
    """Closest database entries for a name that failed to match exactly.

    Used to turn a failed auto-link into something actionable: the caller can
    show real options instead of reporting a dead end. Ranked by how much of
    the requested name the candidate accounts for, so 'Dumbbell Rows' surfaces
    the actual row variants rather than anything merely containing 'dumbbell'.
    """
    if not name:
        return []
    _ensure_loaded()
    tokens = [t for t in _PUNCTUATION.sub(" ", str(name).casefold()).split() if t]
    if not tokens:
        return []
    stems = [t[:-1] if len(t) > 3 and t.endswith("s") else t for t in tokens]

    scored = []
    for ex in _EXERCISES:
        if not ex.get("name"):
            continue
        haystack = _PUNCTUATION.sub(" ", ex["name"].casefold())
        hits = sum(1 for s in stems if s in haystack)
        if hits:
            # Prefer covering more of the request, then the least padded name.
            scored.append((-hits / len(stems), len(haystack), ex))
    scored.sort(key=lambda row: (row[0], row[1]))
    return [_summarize(ex) for _, _, ex in scored[:limit]]


def _summarize(ex: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": ex["id"],
        "name": ex["name"],
        "equipment": ex.get("equipment"),
        "primaryMuscles": ex.get("primaryMuscles", []),
        "level": ex.get("level"),
        "force": ex.get("force"),
        "mechanic": ex.get("mechanic"),
        "category": ex.get("category"),
        "imageUrl": image_url(ex),
    }


# Fields whose distinct values are useful as search filters.
_FACET_FIELDS = ("equipment", "category", "level", "force", "mechanic")


def facets() -> Dict[str, Dict[str, int]]:
    """Distinct filter values actually present in the database, with counts.

    Lets callers (and the coach agent) pick valid filter values instead of
    guessing and silently getting zero results.
    """
    _ensure_loaded()
    result: Dict[str, Dict[str, int]] = {field: {} for field in _FACET_FIELDS}
    result["muscle"] = {}
    for ex in _EXERCISES:
        for field in _FACET_FIELDS:
            value = ex.get(field)
            if value:
                result[field][value] = result[field].get(value, 0) + 1
        for muscle in ex.get("primaryMuscles") or []:
            result["muscle"][muscle] = result["muscle"].get(muscle, 0) + 1
    return {k: dict(sorted(v.items(), key=lambda kv: -kv[1])) for k, v in result.items()}


def search_exercises(
    query: str,
    limit: int = 10,
    *,
    equipment: Optional[str] = None,
    muscle: Optional[str] = None,
    category: Optional[str] = None,
    level: Optional[str] = None,
    force: Optional[str] = None,
    mechanic: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Rank-ordered token search over the free-exercise-db.

    Every whitespace-separated token in `query` must match somewhere in the
    exercise name, primary muscles, equipment or category, so "bench press" and
    "press bench" both work. Results are ordered: exact name > name prefix >
    name substring > name tokens > other.

    `force` (push/pull/static) and `mechanic` (compound/isolation) are exact
    matches; the others are substring matches. Use `facets()` for valid values.
    """
    _ensure_loaded()
    if not _EXERCISES:
        return []

    tokens = [t for t in query.strip().lower().split() if t]
    filters_active = any([equipment, muscle, category, level, force, mechanic])
    if not tokens and not filters_active:
        return []

    eq = (equipment or "").strip().lower() or None
    mu = (muscle or "").strip().lower() or None
    cat = (category or "").strip().lower() or None
    lvl = (level or "").strip().lower() or None
    frc = (force or "").strip().lower() or None
    mech = (mechanic or "").strip().lower() or None

    scored: List[tuple] = []
    for idx, ex in enumerate(_EXERCISES):
        name = (ex.get("name") or "").lower()
        ex_equipment = (ex.get("equipment") or "").lower()
        ex_category = (ex.get("category") or "").lower()
        ex_level = (ex.get("level") or "").lower()
        ex_force = (ex.get("force") or "").lower()
        ex_mechanic = (ex.get("mechanic") or "").lower()
        primary = [m.lower() for m in (ex.get("primaryMuscles") or [])]
        secondary = [m.lower() for m in (ex.get("secondaryMuscles") or [])]

        if eq and eq not in ex_equipment:
            continue
        if cat and cat not in ex_category:
            continue
        if lvl and lvl != ex_level:
            continue
        if frc and frc != ex_force:
            continue
        if mech and mech != ex_mechanic:
            continue
        if mu and not any(mu in m for m in primary + secondary):
            continue

        if tokens:
            haystack = " ".join([name, ex_equipment, ex_category, *primary])
            if not all(t in haystack for t in tokens):
                continue
            joined = " ".join(tokens)
            if name == joined:
                rank = 0
            elif name.startswith(joined):
                rank = 1
            elif joined in name:
                rank = 2
            elif all(t in name for t in tokens):
                rank = 3
            else:
                rank = 4
        else:
            rank = 0

        scored.append((rank, idx, ex))

    scored.sort(key=lambda item: (item[0], item[1]))
    return [_summarize(ex) for _, _, ex in scored[: max(1, limit)]]
