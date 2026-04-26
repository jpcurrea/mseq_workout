# Workout App - Task List

**Last Updated:** April 26, 2026  
**Version:** 1.0 🎉

---

## 📋 To Do

Tasks are ordered by priority. Work top to bottom.

---

### 1. Progress Plotting
**Status:** ✅ Done  
**Description:** Add visual score-over-time charts to the workout screens.
- [x] Add `fl_chart` to pubspec.yaml
- [x] Line chart of score over time per workout
- [x] Interactive (tap point for exact values, white tooltip text)
- [x] Date range selector replaced with pinch/pan zoom (no 7d/30d buttons)
- [x] Show goal line on chart
- [x] Add mini chart to workout card expanded panel (Today's Workout)

**Estimated Time:** 3-4 hours  
**Files:** `flutter_app/pubspec.yaml`, `flutter_app/lib/widgets/progress_chart.dart` (new), `flutter_app/lib/screens/workout_management_screen.dart`, `flutter_app/lib/screens/workout_detail_screen.dart`, `backend/main.py`

---

### 2. Exercise Database + Autocomplete Lookup
**Status:** ✅ Done  
**Priority:** Medium — quality-of-life improvement for workout creation  
**Description:** Embed a free exercise reference database so users can search and pick named exercises when creating workouts, and show imagery in the workout detail view.

#### Backend
- [x] Download `dist/exercises.json` from free-exercise-db → `backend/data/exercises.json` (873 exercises, 978 KB)
- [x] Load it once at startup into module-level list + dict index (no DB needed)
- [x] `GET /exercises/search?q={query}&limit=10` — substring match on `name`
- [x] `GET /exercises/{id}` — full record including `instructions`
- [x] Add nullable `exercise_id TEXT` column to `workouts` table (auto-migrated via `ALTER TABLE` on startup)
- [x] `WorkoutCreate`, `WorkoutUpdateRequest`, `WorkoutSchema`, `WorkoutScheduleItem` all carry `exercise_id`
- [x] `POST /workouts` and `PUT /workouts/{name}` accept and persist `exercise_id`

#### Flutter — workout creation
- [x] `AddWorkoutDialog`: 300ms debounced name field → calls `/exercises/search` → dropdown shows name + primary muscles
- [x] Selecting suggestion fills name and stores `exerciseId`; green link icon confirms linkage
- [x] `ApiService.searchExercises()` added; `createWorkout` passes `exercise_id`
- [x] `Workout` and `WorkoutScheduleItem` models updated with optional `exerciseId` field

#### Flutter — workout detail view
- [x] Expanded `_WorkoutCard`: shows 140px cover photo from GitHub CDN if `exerciseId` is set; spinner while loading; silently hidden on error

**Files:**  
`backend/main.py`, `backend/database.py`, `backend/data/exercises.json`,  
`flutter_app/lib/screens/workout_management_screen.dart`,  
`flutter_app/lib/screens/home_screen.dart`,  
`flutter_app/lib/services/api_service.dart`,  
`flutter_app/lib/models/workout.dart`

---

### 3. M-Sequence Generation Parameter UI
**Status:** ✅ Done  
**Priority:** Medium — unlocks meaningful schedule customization  
**Description:** Expose routine-generation controls in the UI (sequence power, minimum interval, active symbols, and m-sequence base), and add a live stats preview so the user can see exactly what schedule they are about to generate.

#### Current hardcoding (reference)
```python
# backend/main.py  — generate_new_routine()
NUM_FRAMES = base ** SEQUENCE_POWER - 1      # 5^4-1 = 624
date_list = [base + timedelta(days=2 * x)   # "2" = every-other-day, hardcoded
             for x in range(NUM_FRAMES)]
```

#### Backend
- [x] Extend `RoutineGenerationRequest` with `minimum_interval_days`, `mseq_base`, and `active_symbols`
- [x] Replace hardcoded interval logic with `request.minimum_interval_days`
- [x] Validate: `1 <= minimum_interval_days <= 14`; return 422 with message if out of range
- [x] Validate: `2 <= sequence_power <= 6`
- [x] Validate: `mseq_base ∈ {2, 3, 5, 9}` and `1 <= active_symbols <= (mseq_base - 1)`
- [x] Add raw m-sequence mode (`raw=True`) for correct active-symbol filtering before value remapping
- [x] Add `GET /mseq/stats` endpoint — returns a summary of the current user's schedule:
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

#### Flutter — Generate Routine (moved to Manage Workouts, inline — no dialog)
- [x] **Sequence power** dropdown — options: 2 → 6 with dynamic frame count
- [x] **Workout density (active symbols)** dropdown — auto-scales by selected base
- [x] **Advanced m-sequence settings** section with **m-sequence base** selector (2, 3, 5, 9)
- [x] **Minimum interval (days)** dropdown — controls spacing between schedule frames
- [x] **Live stats preview card** with total slots, schedule span, avg cadence — updates on dropdown change
- [x] Pass all generation params to `generateRoutine()` and `getScheduleStats()` in `ApiService`
- [x] Generate Routine moved out of Home popup menu → Section 2 of Manage Workouts (inline)
- [x] Home screen auto-redirects to Manage Workouts when no schedule exists
- [x] Per-workout interval-distribution bar chart (mirrors `plot.py` histogram) in expanded workout card
- [x] Interval chart displayed beside score table via `sidePanel` slot in `WorkoutHistoryPanel`
- [x] Stats range math fixed (min/max computed from actual daily loads / gap extremes)
- [x] Added extra top padding to prevent header cropping in expanded Advanced settings

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

- **M-Sequence Generation Parameter UI** — Sequence power (2-6), minimum interval, active symbols, and advanced base selector (2/3/5/9) with live stats preview and correct raw-symbol density handling. Generate Routine is inline in Manage Workouts; Home auto-redirects when no schedule exists; per-workout interval-distribution chart and stats range math fixes are included.
- **Exercise Database + Autocomplete** — 873-exercise free-exercise-db bundled as `exercises.json`; loaded at startup; `/exercises/search` and `/exercises/{id}` endpoints; `exercise_id` column added to `workouts` table with auto-migration; `AddWorkoutDialog` has 300ms-debounced autocomplete with dropdown (name + muscles); exercise cover photo shown in expanded workout card
- **Progress Plotting** — dedicated `ProgressScreen` with workout dropdown, pinch/pan zoom (replaced 7d/30d/all selector), full interactive line chart (touch to highlight, white tooltip text), goal line with label, summary strip (latest/best/avg/% goal/count), scrollable history table; mini sparkline in Today's Workout card expanded panels; accessible via "Progress Charts" in hamburger menu
- **Logout + Session Management** — Sign Out in hamburger menu; "Stay signed in" remember-me checkbox on login; auto re-auth on JWT expiry when remember-me is set; 24h token expiry
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
- [ ] User profile screen (name, avatar)
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
