# Workout App - Task List

**Last Updated:** April 18, 2026

---

## 📋 To Do

Tasks are ordered by priority. Work top to bottom.

---

### 1. Progress Plotting
**Status:** ✅ Done  
**Description:** Add visual score-over-time charts to the workout screens.
- [ ] Add `fl_chart` to pubspec.yaml
- [ ] Line chart of score over time per workout
- [ ] Interactive (tap point for exact values)
- [ ] Date range selector (7d / 30d / all time)
- [ ] Show goal line on chart
- [ ] Add chart to workout details dropdown and workout management screen

**Estimated Time:** 3-4 hours  
**Files:** `flutter_app/pubspec.yaml`, `flutter_app/lib/widgets/progress_chart.dart` (new), `flutter_app/lib/screens/workout_management_screen.dart`, `flutter_app/lib/screens/workout_detail_screen.dart`, `backend/main.py`

---

### 2. Exercise Database + Autocomplete Lookup
**Status:** Not Started  
**Priority:** Medium — quality-of-life improvement for workout creation  
**Description:** Embed a free exercise reference database so users can search and pick named exercises when creating workouts, and optionally show imagery in the workout detail view.

#### Data source
Use **[free-exercise-db](https://github.com/yuhonas/free-exercise-db)** (Unlicense / public domain) — 800+ exercises, single JSON file.  
Fields per exercise: `id`, `name`, `force`, `level`, `mechanic`, `equipment`, `primaryMuscles`, `secondaryMuscles`, `instructions`, `category`, `images` (2 × JPG filename).  
Images served via GitHub CDN — no download needed for images:  
`https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/{id}/0.jpg`

**Alternative for GIFs (optional upgrade):** Download the [ExerciseDB Kaggle open-source tier](https://www.kaggle.com/datasets/exercisedb/fitness-exercises-dataset) (MIT, 1500+ exercises, 180p animated GIFs). Bundle `exercises.json` + `gifs_180x180/` into `backend/data/` and serve GIFs as static files via FastAPI `StaticFiles`. Swaps GitHub-CDN image URLs for local paths — no API keys or network calls.

#### Backend
- [ ] Download `dist/exercises.json` from free-exercise-db and place at `backend/data/exercises.json`
- [ ] Load it once at startup into a module-level list (no DB needed)
- [ ] `GET /exercises/search?q={query}&limit=10` — prefix/substring match on `name`, returns `[{id, name, equipment, primaryMuscles, imageUrl}]`
- [ ] `GET /exercises/{id}` — full record including `instructions` list
- [ ] Add nullable `exercise_id TEXT` column to `workouts` table; include in `WorkoutCreate` / `WorkoutUpdate` schemas
- [ ] `POST /workouts` and `PUT /workouts/{id}` accept and persist the new field

#### Flutter — workout creation / editing
- [ ] In `workout_management_screen.dart` add/edit dialog: replace plain name `TextFormField` with `Autocomplete<Map<String, dynamic>>`
- [ ] Debounce keystrokes 300 ms, call `GET /exercises/search?q=...`, display up to 10 suggestions below the field
- [ ] Selecting a suggestion fills the name field and stores the `exercise_id`
- [ ] Pass `exerciseId` when calling `createWorkout` / `updateWorkout` in `ApiService`
- [ ] Update `Workout` model (`workout.dart`) with optional `exerciseId` field

#### Flutter — workout detail view
- [ ] In `_WorkoutCard` (home_screen.dart), if `exerciseId` is non-null, show `Image.network` of the first JPG at the top of the expanded panel; loading spinner placeholder; silently hidden on 404
- [ ] Optional: add a collapsible "Instructions" tile below the history chart that lists the exercise text steps (fetched from `GET /exercises/{id}` on first expand)

**Estimated Time:** 4-6 hours  
**Files:**  
`backend/main.py`, `backend/data/exercises.json` (new download),  
`flutter_app/lib/screens/workout_management_screen.dart`,  
`flutter_app/lib/screens/home_screen.dart`,  
`flutter_app/lib/services/api_service.dart`,  
`flutter_app/lib/models/workout.dart`

---

### 3. M-Sequence Generation Parameter UI
**Status:** Not Started  
**Priority:** Medium — unlocks meaningful schedule customization  
**Description:** Expose the two hidden routine-generation parameters (workout frequency and sequence power) in the UI, and add a live stats preview so the user can see exactly what schedule they are about to generate.

#### Current hardcoding (reference)
```python
# backend/main.py  — generate_new_routine()
NUM_FRAMES = base ** SEQUENCE_POWER - 1      # 5^4-1 = 624
date_list = [base + timedelta(days=2 * x)   # "2" = every-other-day, hardcoded
             for x in range(NUM_FRAMES)]
```

#### Backend
- [ ] Extend `RoutineGenerationRequest` with `frequency_days: Optional[int] = 2`
- [ ] Replace hardcoded `2` in `generate_new_routine` with `request.frequency_days`
- [ ] Validate: `1 <= frequency_days <= 14`; return 422 with message if out of range
- [ ] Clamp `sequence_power` validation to 3–6 (power 6 → 5^6−1 = 15 624 slots; practical max)
- [ ] Add `GET /schedule/stats` endpoint — returns a summary of the current user's schedule:
  ```json
  {
    "total_slots": 624,
    "slots_with_score": 142,
    "completion_rate": 0.228,
    "earliest_date": "2024-01-01",
    "latest_date": "2027-06-01",
    "schedule_span_days": 1248,
    "avg_days_between_same_workout": 8.5
  }
  ```

#### Flutter — Generate Routine dialog
Find wherever `POST /generate-routine` is called (likely `workout_management_screen.dart` or `home_screen.dart`) and extend the dialog with:
- [ ] **Frequency** `DropdownButtonFormField` — options: 1 (daily), 2 (every other day), 3, 4, 5, 7 (weekly); default 2
- [ ] **Sequence power** `DropdownButtonFormField` — options: 3 → "124 slots", 4 → "624 slots", 5 → "3 124 slots"; default 4
- [ ] **Live stats preview card** that recomputes on every dropdown change:
  - Total slots: `5^power − 1`
  - Schedule span: `(5^power − 1) × frequency_days` days (and approximate years)
  - Effective avg cadence: one workout slot every `frequency_days` days
- [ ] Pass both params to `generateRoutine()` in `ApiService`

#### Flutter — schedule stats card on home screen (optional)
- [ ] Call `GET /schedule/stats` when home screen loads; show a small collapsible summary card beneath the date header (completion rate, span, next date)

**Estimated Time:** 3-4 hours  
**Files:**  
`backend/main.py`,  
`flutter_app/lib/screens/home_screen.dart` and/or `workout_management_screen.dart`,  
`flutter_app/lib/services/api_service.dart`

---

## 🔄 In Progress

_Nothing in progress_

---

## ✅ Done

- **Progress Plotting** — dedicated `ProgressScreen` with workout dropdown, 7d/30d/all segmented range selector, full interactive line chart (touch to highlight, tooltip), goal line with label, summary strip (latest/best/avg/% goal/count), scrollable history table with % goal column and goal-met checkmark; accessible via "Progress Charts" in the hamburger menu
- **Security Hardening** — `flutter_secure_storage` replacing SharedPreferences; CORS locked to `FRONTEND_URL`; `slowapi` rate limiting on all write endpoints; session cookie `SameSite=lax`; JWT expiry reduced to 24h; default_user fallback removed
- **Edit History Scores** — date picker on home screen; past dates use last-scheduled-workout fallback; score entry and submit work identically to today's view
- **Fix Workout Selection Algorithm** — `/today` and `/schedule/{date}` both look backwards to last scheduled date
- **Data transfer to Google account** — `transfer_to_google_user.py` run; all workouts and schedule entries now owned by Google user
- **Google OAuth + Flutter Auth** — JWT auth, `AuthGate`, `LoginScreen`, `ApiService` token sending, multi-user data isolation
- **Database migration** — `main.py` rewritten to SQLAlchemy; 24 workouts + ~3000 schedule entries migrated from production
- **Database schema + OAuth design** — `database.py` (User, Workout, ScheduleEntry models), `auth.py`

---

## 🐛 Known Issues

- [ ] API errors surface raw technical messages to the user
- [ ] No confirmation dialogs before delete operations
- [ ] No validation for duplicate workout names
- [ ] Date timezone handling may cause edge cases across regions
- [ ] No offline support — requires internet connection

---

## 💡 Backlog

### Auth & Users
- [ ] User profile screen (name, avatar, sign-out)
- [ ] Sign-out functionality in Flutter app
- [ ] GitHub OAuth as a second login provider

### Mobile
- [ ] Offline mode with local caching
- [ ] Push notifications for workout reminders
- [ ] Workout timer / stopwatch

### Analytics
- [ ] Statistics dashboard (weekly/monthly trends)
- [ ] Streak tracking (consecutive workout days)
- [ ] Workout intensity/difficulty ratings

### UI/UX
- [ ] Dark mode
- [ ] Onboarding walkthrough for new users
- [ ] Loading skeletons / better loading states
- [ ] Animation polish

### Data
- [ ] Custom notes on workouts
- [ ] Data export / import
- [ ] Workout templates / presets

### Technical
- [ ] State management (Provider / Riverpod / Bloc)
- [ ] Unit, widget, and integration tests
- [ ] CI/CD pipeline
- [ ] Alembic for future database schema migrations
- [ ] Structured error logging
- [ ] Migrate from SQLite to Neon PostgreSQL — one free account covers all future projects; `psycopg2-binary` + one-line change in `database.py`; automatic backups; data survives independent of Render (low priority — current SQLite + persistent disk works fine)

---

## 📝 Deployment Checklist

When ready to push to production:
- [ ] Test locally end-to-end
- [ ] Update `requirements.txt` / `pubspec.yaml` if needed
- [ ] Set env vars on Render: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `SECRET_KEY`, `FRONTEND_URL`
- [ ] Update `FRONTEND_URL` to production Netlify domain
- [ ] Update `baseUrl` in `api_service.dart` for production build
- [ ] Commit and push
- [ ] Verify Render deployment
- [ ] Verify Netlify deployment
- [ ] Smoke test production
- 🔵 Low priority
- ⚪ Future/Nice-to-have
