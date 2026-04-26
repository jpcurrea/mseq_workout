"""
Seed production database from a CSV exported by GET /export.

Usage
-----
1. Export your local data:
       http://localhost:8000/export   (opens in browser, downloads workout_history.csv)
   Save the file to  backend/data/workout_history.csv

2. Set GOOGLE_EMAIL below to the Google account email you log in with.

3. On Render Shell (or locally against the target db), run:
       python seed_from_export.py

The script is safe to re-run: it skips rows that already exist and never
creates duplicate workout definitions.
"""

import csv
import os
import sys
from datetime import date, datetime

# ── CONFIGURE THIS ────────────────────────────────────────────────────────────
GOOGLE_EMAIL = "johnpaulcurrea@gmail.com"          # e.g. "john@gmail.com"
CSV_PATH = os.path.join(os.path.dirname(__file__), "data", "workout_history.csv")
# ─────────────────────────────────────────────────────────────────────────────

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from database import init_db, create_session, User, Workout, ScheduleEntry


def parse_bool(val: str) -> bool:
    return val.strip().lower() in ("true", "1", "yes")


def main():
    if GOOGLE_EMAIL == "YOUR_GOOGLE_EMAIL_HERE":
        print("ERROR: Set GOOGLE_EMAIL at the top of this script before running.")
        sys.exit(1)

    if not os.path.exists(CSV_PATH):
        print(f"ERROR: CSV not found at {CSV_PATH}")
        print("Export it from http://localhost:8000/export and save to backend/data/workout_history.csv")
        sys.exit(1)

    print("Initialising database …")
    init_db()
    session = create_session()

    # ── 1. Find or create the Google user ────────────────────────────────────
    user = session.query(User).filter(
        User.email == GOOGLE_EMAIL,
        User.oauth_provider == "google",
    ).first()

    if user is None:
        # User hasn't logged in yet on this instance — create a placeholder.
        # The next Google login will match by email and update oauth_id etc.
        print(f"User {GOOGLE_EMAIL} not found — creating placeholder account.")
        user = User(
            email=GOOGLE_EMAIL,
            username=GOOGLE_EMAIL.split("@")[0],
            hashed_password=None,
            oauth_provider="google",
            oauth_id=None,         # filled in on first real login
            oauth_picture_url=None,
            created_at=datetime.utcnow(),
        )
        session.add(user)
        session.flush()
    else:
        print(f"Found existing user: {user.email} (id={user.id})")

    # ── 2. Read CSV ───────────────────────────────────────────────────────────
    with open(CSV_PATH, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    print(f"CSV has {len(rows)} rows.")

    # ── 3. Build workout definitions (upsert) ─────────────────────────────────
    workout_map: dict[str, Workout] = {}   # name → Workout ORM object

    for row in rows:
        name = row["workout"].strip()
        if name in workout_map:
            continue

        existing = session.query(Workout).filter(
            Workout.user_id == user.id,
            Workout.name == name,
        ).first()

        if existing:
            workout_map[name] = existing
        else:
            w = Workout(
                user_id=user.id,
                name=name,
                goal=float(row["goal"]),
                units=row["units"].strip(),
                at_park=parse_bool(row["at_park"]),
            )
            session.add(w)
            session.flush()
            workout_map[name] = w
            print(f"  Created workout: {name}")

    # ── 4. Insert schedule entries (skip duplicates) ───────────────────────────
    inserted = 0
    skipped = 0

    for row in rows:
        name = row["workout"].strip()
        entry_date = date.fromisoformat(row["date"].strip())
        workout = workout_map[name]

        existing_entry = session.query(ScheduleEntry).filter(
            ScheduleEntry.user_id == user.id,
            ScheduleEntry.workout_id == workout.id,
            ScheduleEntry.date == entry_date,
        ).first()

        if existing_entry:
            skipped += 1
            continue

        score_raw = row.get("score", "").strip()
        score = float(score_raw) if score_raw else None

        entry = ScheduleEntry(
            user_id=user.id,
            workout_id=workout.id,
            date=entry_date,
            score=score,
        )
        session.add(entry)
        inserted += 1

    session.commit()
    print(f"\nDone. Inserted {inserted} schedule entries, skipped {skipped} already-existing rows.")
    print("You can now delete this script and the CSV from the repo.")


if __name__ == "__main__":
    main()
