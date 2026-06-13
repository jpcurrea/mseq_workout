"""
Exercise database loader — extracted so both main.py (startup) and routers can share it.
"""
import os
import json

from database import get_data_dir

_EXERCISES: list = []
_EXERCISES_IDX: dict = {}
EXERCISE_IMAGE_BASE = (
    "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises"
)


def load_exercises() -> None:
    global _EXERCISES, _EXERCISES_IDX
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
