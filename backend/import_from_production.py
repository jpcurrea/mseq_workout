"""
Import schedule history from the production server into the local database.
Uses the live API instead of the broken pickle file.

Run with:
    python import_from_production.py
"""

import sys
import os
import datetime
import requests

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from database import init_db, create_session, User, Workout, ScheduleEntry

PRODUCTION_URL = "https://workout-backend-h6pd.onrender.com"
DEFAULT_USERNAME = "default_user"

# Scan this many days back and forward from today
DAYS_BACK = 100   # 100 days back
DAYS_FORWARD = 500  # 500 days forward


def fetch_schedule_for_date(date_str: str) -> list:
    """Fetch workouts for a given date from production API."""
    try:
        resp = requests.get(f"{PRODUCTION_URL}/schedule/{date_str}", timeout=10)
        if resp.status_code == 200:
            return resp.json()
    except requests.RequestException:
        pass
    return []


def main():
    print("=" * 60)
    print("Importing schedule from production server")
    print(f"Source: {PRODUCTION_URL}")
    print("=" * 60)

    init_db()
    session = create_session()

    try:
        user = session.query(User).filter(User.username == DEFAULT_USERNAME).first()
        if not user:
            print("❌ default_user not found. Start the backend first to create it.")
            return

        # Build a map of workout name -> workout DB id
        workouts = session.query(Workout).filter(Workout.user_id == user.id).all()
        if not workouts:
            print("❌ No workouts in local DB. Start the backend first to migrate workouts.csv.")
            return

        workout_map = {w.name: w.id for w in workouts}
        print(f"Found {len(workout_map)} local workouts to match against.\n")

        # Clear existing schedule entries for this user
        existing = session.query(ScheduleEntry).filter(ScheduleEntry.user_id == user.id).count()
        if existing > 0:
            confirm = input(f"Local DB already has {existing} schedule entries. Overwrite? (yes/no): ").strip().lower()
            if confirm != 'yes':
                print("Cancelled.")
                return
            session.query(ScheduleEntry).filter(ScheduleEntry.user_id == user.id).delete()
            session.commit()
            print(f"Cleared {existing} existing entries.\n")

        today = datetime.date.today()
        start = today - datetime.timedelta(days=DAYS_BACK)
        end = today + datetime.timedelta(days=DAYS_FORWARD)

        total_days = (end - start).days
        entries_imported = 0
        dates_with_data = 0

        print(f"Scanning {total_days} dates from {start} to {end}...")
        print("(This may take a few minutes — the free Render server can be slow)\n")

        current = start
        while current <= end:
            date_str = current.strftime('%Y-%m-%d')
            day_entries = fetch_schedule_for_date(date_str)

            if day_entries:
                dates_with_data += 1
                for entry in day_entries:
                    workout_name = entry.get('workout')
                    if workout_name not in workout_map:
                        print(f"  ⚠️  Unknown workout '{workout_name}' on {date_str} — skipping")
                        continue
                    score = entry.get('score')
                    session.add(ScheduleEntry(
                        user_id=user.id,
                        workout_id=workout_map[workout_name],
                        date=current,
                        score=float(score) if score is not None else None
                    ))
                    entries_imported += 1

                # Commit in batches to avoid large transactions
                if dates_with_data % 50 == 0:
                    session.commit()
                    print(f"  ...{entries_imported} entries so far (scanned up to {date_str})")

            current += datetime.timedelta(days=1)

        session.commit()
        print(f"\n✅ Done!")
        print(f"   Dates with data: {dates_with_data}")
        print(f"   Schedule entries imported: {entries_imported}")

    finally:
        session.close()


if __name__ == "__main__":
    main()
