import datetime
import numpy as np
from matplotlib import pyplot as plt
import pandas as pd

# use the standard matplotlib backend
plt.switch_backend('QtAgg')

schedule = pd.read_pickle("./schedule.pkl")
schedule.date = pd.to_datetime(schedule.date)

# let's plot the histogram of intervals for each workout
bins = np.arange(0, 30)
workouts = schedule.workout.unique()
fig, axes = plt.subplots(ncols=5, nrows=5, figsize=(8, 8), sharex=True, sharey=True)
for ax, workout in zip(axes.flatten(), workouts):
    # get the workout
    w = schedule[schedule.workout == workout]
    # get the intervals
    intervals = w.date.diff().dt.days
    # plot the histogram
    ax.hist(intervals, label=workout, alpha=0.5, bins=bins)
    # set the title
    ax.set_title(workout, fontsize=8)

ax.set_xlim(1)
plt.tight_layout()

# let's also plot the histogram of the number of workouts per day
fig, ax = plt.subplots()
# group the workouts by date
schedule_grouped = schedule.groupby('date').count()
# plot the histogram
ax.hist(schedule_grouped.workout, bins=np.arange(0, 10)-.5)
ax.set_xticks(np.arange(0, 10))
# set the title
ax.set_title("Number of workouts per day")
plt.tight_layout()
plt.show()
