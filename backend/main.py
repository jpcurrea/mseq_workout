"""
FastAPI backend for workout routine mobile app
Converts existing workout routine logic into REST API endpoints
"""

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional
import datetime
import pandas as pd
import numpy as np
import sys
import os

# Add local directory to path to import mseq
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from mseq import mseq

app = FastAPI(title="Workout Routine API", version="1.0.0")

# Add CORS middleware to allow requests from mobile app
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Pydantic models for API requests/responses
class Workout(BaseModel):
    name: str
    goal: float
    units: str
    at_park: bool

class WorkoutScheduleItem(BaseModel):
    date: str
    workout: str
    score: Optional[float] = None
    units: str
    at_park: bool
    goal: float

class WorkoutUpdate(BaseModel):
    workout: str
    date: str
    score: float

class RoutineGenerationRequest(BaseModel):
    start_date: Optional[str] = None
    sequence_power: Optional[int] = 4

class WorkoutCreate(BaseModel):
    name: str
    goal: float
    units: str
    at_park: bool

class WorkoutUpdateRequest(BaseModel):
    goal: float
    units: str
    at_park: bool

# Global variables to cache data
workouts_df = None
schedule_df = None

def get_data_dir():
    """Get the data directory - use /data if it exists (Render), otherwise ./data for local"""
    data_dir = "/data" if os.path.exists("/data") else "./data"
    return data_dir

def load_data():
    """Load workout data from CSV files"""
    global workouts_df, schedule_df
    data_dir = get_data_dir()
    try:
        workouts_df = pd.read_csv(f"{data_dir}/workouts.csv")
        schedule_path = f"{data_dir}/schedule.pkl"
        if os.path.exists(schedule_path):
            schedule_df = pd.read_pickle(schedule_path)
            # Normalize schedule dates to midnight (drop time component)
            schedule_df['date'] = pd.to_datetime(schedule_df['date']).dt.normalize()
        else:
            schedule_df = pd.DataFrame()
    except Exception as e:
        print(f"Error loading data: {e}")
        workouts_df = pd.DataFrame()
        schedule_df = pd.DataFrame()

@app.on_event("startup")
async def startup_event():
    load_data()

@app.get("/")
async def root():
    return {"message": "Workout Routine API is running"}

@app.get("/workouts", response_model=List[Workout])
async def get_workouts():
    """Get all available workouts"""
    if workouts_df.empty:
        load_data()
    
    workouts = []
    for _, row in workouts_df.iterrows():
        workouts.append(Workout(
            name=row['name'],
            goal=row['goal'],
            units=row['units'],
            at_park=bool(row['at_park'])
        ))
    return workouts


@app.get("/workouts.csv")
async def download_workouts_csv():
    """Return the workouts.csv file for download."""
    data_dir = get_data_dir()
    file_path = f"{data_dir}/workouts.csv"
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="workouts.csv not found")
    return FileResponse(path=file_path, filename="workouts.csv", media_type='text/csv')


@app.get("/schedule.pkl")
async def download_schedule_pickle():
    """Return the current schedule.pkl file for download."""
    data_dir = get_data_dir()
    file_path = f"{data_dir}/schedule.pkl"
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="schedule.pkl not found")
    return FileResponse(path=file_path, filename="schedule.pkl", media_type='application/octet-stream')

@app.get("/today", response_model=List[WorkoutScheduleItem])
async def get_today_workouts():
    """Get today's workout schedule, or the most recent previous workout if none scheduled for today"""
    if schedule_df.empty:
        return []
    
    # Use date-only comparison to avoid time-of-day issues
    today = pd.Timestamp(datetime.date.today()).normalize()
    inds = schedule_df['date'] == today
    workouts_today = schedule_df.loc[inds].copy()
    
    # If no workouts today, find the most recent previous date with workouts
    if workouts_today.empty:
        past_workouts = schedule_df[schedule_df['date'] < today]
        if not past_workouts.empty:
            # Get the most recent date
            most_recent_date = past_workouts['date'].max()
            inds = schedule_df['date'] == most_recent_date
            workouts_today = schedule_df.loc[inds].copy()
    
    workouts_today = workouts_today.sort_values(by=['at_park'])
    
    # Merge with workouts to get goals
    workouts_with_goals = workouts_today.merge(
        workouts_df[['name', 'goal']], 
        left_on='workout', 
        right_on='name', 
        how='left'
    )
    
    result = []
    for _, row in workouts_with_goals.iterrows():
        result.append(WorkoutScheduleItem(
            date=row['date'].strftime('%Y-%m-%d'),
            workout=row['workout'],
            score=row['score'] if pd.notna(row['score']) else None,
            units=row['units'],
            at_park=bool(row['at_park']),
            goal=row['goal'] if pd.notna(row['goal']) else 0
        ))
    
    return result

@app.get("/schedule/{date}", response_model=List[WorkoutScheduleItem])
async def get_workouts_for_date(date: str):
    """Get workouts for a specific date (YYYY-MM-DD format)"""
    if schedule_df.empty:
        return []
    
    try:
        target_date = pd.Timestamp(datetime.datetime.strptime(date, '%Y-%m-%d')).normalize()
        inds = schedule_df['date'] == target_date
        workouts_for_date = schedule_df.loc[inds].copy()
        workouts_for_date = workouts_for_date.sort_values(by=['at_park'])
        
        # Merge with workouts to get goals
        workouts_with_goals = workouts_for_date.merge(
            workouts_df[['name', 'goal']], 
            left_on='workout', 
            right_on='name', 
            how='left'
        )
        
        result = []
        for _, row in workouts_with_goals.iterrows():
            result.append(WorkoutScheduleItem(
                date=row['date'].strftime('%Y-%m-%d'),
                workout=row['workout'],
                score=row['score'] if pd.notna(row['score']) else None,
                units=row['units'],
                at_park=bool(row['at_park']),
                goal=row['goal'] if pd.notna(row['goal']) else 0
            ))
        
        return result
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")

@app.post("/update-score")
async def update_workout_score(update: WorkoutUpdate):
    """Update the score for a specific workout on a specific date"""
    global schedule_df
    
    if schedule_df.empty:
        raise HTTPException(status_code=404, detail="No schedule data found")
    
    try:
        target_date = pd.Timestamp(datetime.datetime.strptime(update.date, '%Y-%m-%d')).normalize()

        # Find the specific workout entry using date equality
        mask = (
            (schedule_df['date'] == target_date) &
            (schedule_df.workout == update.workout)
        )
        
        if not mask.any():
            raise HTTPException(status_code=404, detail="Workout not found for this date")
        
        # Update the score
        schedule_df.loc[mask, 'score'] = update.score
        
        # Save back to pickle file
        data_dir = get_data_dir()
        schedule_df.to_pickle(f"{data_dir}/schedule.pkl")
        
        return {"message": "Score updated successfully"}
    
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")

@app.post("/generate-routine")
async def generate_new_routine(request: RoutineGenerationRequest):
    """Generate a new workout routine using m-sequences"""
    global schedule_df
    
    if workouts_df.empty:
        raise HTTPException(status_code=400, detail="No workouts data found")
    
    SEQUENCE_POWER = request.sequence_power or 4
    NUM_FRAMES = 5 ** SEQUENCE_POWER - 1
    
    # Determine start date
    if request.start_date:
        try:
            base = datetime.datetime.strptime(request.start_date, '%Y-%m-%d')
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid start date format. Use YYYY-MM-DD")
    else:
        base = datetime.datetime.today()
    
    # Generate date list
    date_list = np.array([base + datetime.timedelta(days=2*x) for x in range(NUM_FRAMES)])
    
    # Generate schedule
    schedule = {'date': [], 'workout': [], 'score': [], 'units': [], 'at_park': []}
    
    # Generate msequences for each workout
    for num, workout in workouts_df.iterrows():
        # Generate a random shift
        shift = np.random.randint(0, NUM_FRAMES - 1)
        seq = mseq(5, SEQUENCE_POWER, whichSeq=num, shift=shift)
        
        # Add dates whenever there is a 1 in the sequence
        dates = date_list[seq == 1]
        schedule['date'].extend(dates)
        schedule['workout'].extend([workout['name']] * len(dates))
        schedule['score'].extend([np.nan] * len(dates))
        schedule['units'].extend([workout['units']] * len(dates))
        schedule['at_park'].extend([workout['at_park']] * len(dates))
    
    # Create DataFrame and sort by date
    schedule_df = pd.DataFrame(schedule)
    schedule_df = schedule_df.sort_values(by=['date'])
    
    # Save to pickle file
    data_dir = get_data_dir()
    schedule_df.to_pickle(f"{data_dir}/schedule.pkl")
    
    return {
        "message": "New routine generated successfully",
        "total_workouts": len(schedule_df),
        "date_range": {
            "start": schedule_df.date.min().strftime('%Y-%m-%d'),
            "end": schedule_df.date.max().strftime('%Y-%m-%d')
        }
    }

@app.post("/workouts")
async def create_workout(workout: WorkoutCreate):
    """Add a new workout to the workouts list"""
    global workouts_df
    
    if workouts_df.empty:
        load_data()
    
    # Check if workout name already exists
    if workout.name in workouts_df['name'].values:
        raise HTTPException(status_code=400, detail="Workout with this name already exists")
    
    # Add new workout to dataframe
    new_row = pd.DataFrame([{
        'name': workout.name,
        'goal': workout.goal,
        'units': workout.units,
        'at_park': workout.at_park
    }])
    workouts_df = pd.concat([workouts_df, new_row], ignore_index=True)
    
    # Save to CSV
    data_dir = get_data_dir()
    workouts_df.to_csv(f"{data_dir}/workouts.csv", index=False)
    
    return {"message": "Workout created successfully", "workout": workout.dict()}

@app.put("/workouts/{workout_name}")
async def update_workout(workout_name: str, workout: WorkoutUpdateRequest):
    """Update an existing workout's parameters"""
    global workouts_df
    
    if workouts_df.empty:
        load_data()
    
    # Check if workout exists
    if workout_name not in workouts_df['name'].values:
        raise HTTPException(status_code=404, detail="Workout not found")
    
    # Update workout parameters
    mask = workouts_df['name'] == workout_name
    workouts_df.loc[mask, 'goal'] = workout.goal
    workouts_df.loc[mask, 'units'] = workout.units
    workouts_df.loc[mask, 'at_park'] = workout.at_park
    
    # Save to CSV
    data_dir = get_data_dir()
    workouts_df.to_csv(f"{data_dir}/workouts.csv", index=False)
    
    return {"message": "Workout updated successfully"}

@app.delete("/workouts/{workout_name}")
async def delete_workout(workout_name: str):
    """Delete a workout from the workouts list"""
    global workouts_df
    
    if workouts_df.empty:
        load_data()
    
    # Check if workout exists
    if workout_name not in workouts_df['name'].values:
        raise HTTPException(status_code=404, detail="Workout not found")
    
    # Remove workout from dataframe
    workouts_df = workouts_df[workouts_df['name'] != workout_name]
    
    # Save to CSV
    data_dir = get_data_dir()
    workouts_df.to_csv(f"{data_dir}/workouts.csv", index=False)
    
    return {"message": "Workout deleted successfully"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)