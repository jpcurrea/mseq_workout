"""
One-time script: transfer all data from default_user to your Google account.

Run this AFTER signing in with Google for the first time:
    python transfer_to_google_user.py

It will list available users and ask you to confirm before making any changes.
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from database import create_session, User, Workout, ScheduleEntry

DEFAULT_USERNAME = "default_user"

def main():
    session = create_session()

    try:
        # Find default_user
        default_user = session.query(User).filter(User.username == DEFAULT_USERNAME).first()
        if not default_user:
            print("No default_user found — nothing to transfer.")
            return

        workout_count = session.query(Workout).filter(Workout.user_id == default_user.id).count()
        schedule_count = session.query(ScheduleEntry).filter(ScheduleEntry.user_id == default_user.id).count()

        if workout_count == 0 and schedule_count == 0:
            print("default_user has no data — nothing to transfer.")
            return

        print(f"default_user (id={default_user.id}) has:")
        print(f"  {workout_count} workouts")
        print(f"  {schedule_count} schedule entries")
        print()

        # List all other users (Google accounts)
        other_users = session.query(User).filter(User.username != DEFAULT_USERNAME).all()
        if not other_users:
            print("No other users found. Sign in with Google first, then re-run this script.")
            return

        print("Available users to transfer to:")
        for u in other_users:
            print(f"  [{u.id}] {u.username} ({u.email}) — provider: {u.oauth_provider or 'none'}")

        print()
        target_id_str = input("Enter the ID of the user to transfer data to: ").strip()
        try:
            target_id = int(target_id_str)
        except ValueError:
            print("Invalid ID.")
            return

        target_user = session.query(User).filter(User.id == target_id).first()
        if not target_user:
            print(f"No user with id={target_id} found.")
            return

        print()
        print(f"This will transfer all data from '{default_user.username}' → '{target_user.username}' ({target_user.email})")
        confirm = input("Type 'yes' to confirm: ").strip().lower()
        if confirm != 'yes':
            print("Cancelled.")
            return

        # Reassign workouts and schedule entries
        session.query(Workout).filter(Workout.user_id == default_user.id).update(
            {Workout.user_id: target_user.id}
        )
        session.query(ScheduleEntry).filter(ScheduleEntry.user_id == default_user.id).update(
            {ScheduleEntry.user_id: target_user.id}
        )
        session.commit()

        print()
        print(f"✅ Transferred {workout_count} workouts and {schedule_count} schedule entries to '{target_user.username}'.")
        print("You can now delete default_user from the DB if you like, or leave it.")

    finally:
        session.close()


if __name__ == "__main__":
    main()
