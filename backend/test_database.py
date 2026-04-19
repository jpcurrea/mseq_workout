"""
Test script to verify database setup
Run this to test that the database schema works correctly
"""

import sys
import os

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from database import (
    init_db,
    create_session,
    User,
    Workout,
    ScheduleEntry,
    get_data_dir
)
import bcrypt
from datetime import date, datetime

def hash_password(password: str) -> str:
    """Hash a password using bcrypt"""
    return bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')


def test_database():
    """Test database operations"""
    print("="*60)
    print("Testing Database Schema")
    print("="*60)
    
    # Initialize database
    print("\n1. Initializing database...")
    engine = init_db()
    print(f"✅ Database created at: {get_data_dir()}/workout_app.db")
    
    session = create_session()
    
    try:
        # Create test user
        print("\n2. Creating test user...")
        test_user = User(
            username="test_user",
            email="test@example.com",
            hashed_password=hash_password("testpass123")
        )
        session.add(test_user)
        session.flush()
        print(f"✅ User created: {test_user}")
        
        # Create test workouts
        print("\n3. Creating test workouts...")
        workout1 = Workout(
            user_id=test_user.id,
            name="Push-ups",
            goal=50.0,
            units="reps",
            at_park=False
        )
        workout2 = Workout(
            user_id=test_user.id,
            name="Pull-ups",
            goal=15.0,
            units="reps",
            at_park=True
        )
        session.add_all([workout1, workout2])
        session.flush()
        print(f"✅ Workout 1 created: {workout1}")
        print(f"✅ Workout 2 created: {workout2}")
        
        # Create test schedule entries
        print("\n4. Creating test schedule entries...")
        entry1 = ScheduleEntry(
            user_id=test_user.id,
            workout_id=workout1.id,
            date=date.today(),
            score=45.0
        )
        entry2 = ScheduleEntry(
            user_id=test_user.id,
            workout_id=workout2.id,
            date=date.today(),
            score=None  # Not completed yet
        )
        session.add_all([entry1, entry2])
        session.flush()
        print(f"✅ Entry 1 created: {entry1}")
        print(f"✅ Entry 2 created: {entry2}")
        
        # Query test
        print("\n5. Testing queries...")
        
        # Get all workouts for user
        user_workouts = session.query(Workout).filter(
            Workout.user_id == test_user.id
        ).all()
        print(f"✅ Found {len(user_workouts)} workouts for user")
        
        # Get schedule for today
        todays_schedule = session.query(ScheduleEntry).filter(
            ScheduleEntry.user_id == test_user.id,
            ScheduleEntry.date == date.today()
        ).all()
        print(f"✅ Found {len(todays_schedule)} schedule entries for today")
        
        # Join query (schedule with workout details)
        schedule_with_workouts = session.query(
            ScheduleEntry, Workout
        ).join(
            Workout, ScheduleEntry.workout_id == Workout.id
        ).filter(
            ScheduleEntry.user_id == test_user.id,
            ScheduleEntry.date == date.today()
        ).all()
        print(f"✅ Join query returned {len(schedule_with_workouts)} results")
        
        for entry, workout in schedule_with_workouts:
            print(f"   - {workout.name}: score={entry.score}, goal={workout.goal}")
        
        # Test user isolation
        print("\n6. Testing user data isolation...")
        test_user2 = User(
            username="test_user2",
            email="test2@example.com",
            hashed_password=hash_password("testpass456")
        )
        session.add(test_user2)
        session.flush()
        
        user2_workouts = session.query(Workout).filter(
            Workout.user_id == test_user2.id
        ).all()
        print(f"✅ User 2 has {len(user2_workouts)} workouts (should be 0)")
        
        print("\n" + "="*60)
        print("✅ All tests passed!")
        print("="*60)
        print("\nDatabase is ready to use!")
        print(f"Location: {get_data_dir()}/workout_app.db")
        
    except Exception as e:
        print(f"\n❌ Error during testing: {e}")
        session.rollback()
        raise
    
    finally:
        # Cleanup (optional - comment out to keep test data)
        print("\n7. Cleaning up test data...")
        session.rollback()  # Don't commit test data
        session.close()
        print("✅ Test data rolled back")


if __name__ == "__main__":
    test_database()
