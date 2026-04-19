# Workout Routine Mobile App - Project Overview

**Last Updated:** February 16, 2026

## 📋 Project Summary

A mobile-first workout routine generator and tracker with a Flutter frontend and FastAPI backend. The app uses M-sequence (maximum length sequence) algorithms to generate balanced workout schedules, tracks progress, and manages workout routines across home and park locations.

---

## 🏗️ Architecture

### Tech Stack
- **Frontend:** Flutter 3.9.2 (Dart)
  - Cross-platform (iOS, Android, Web, Windows)
  - Material Design 3 UI
  - HTTP client for API communication
- **Backend:** FastAPI (Python)
  - RESTful API
  - M-sequence algorithm for workout generation
  - CSV/Pickle data persistence
- **Deployment:**
  - Frontend: Netlify (web build)
  - Backend: Render.com
  - Data storage: Persistent disk on Render

### Data Flow
```
User (Flutter App)
    ↓ HTTP Requests
FastAPI Backend (Render.com)
    ↓ Read/Write
workouts.csv & schedule.pkl (Persistent Disk)
```

---

## 📁 Directory Structure

```
mobile_app/
├── backend/                     # Python FastAPI backend
│   ├── main.py                 # API endpoints & business logic
│   ├── mseq.py                 # M-sequence algorithm implementation
│   ├── requirements.txt        # Python dependencies
│   └── data/
│       ├── workouts.csv        # Workout definitions (name, goal, units, location)
│       └── schedule.pkl        # Generated workout schedule
│
├── flutter_app/                # Flutter mobile/web app
│   ├── lib/
│   │   ├── main.dart          # App entry point & routing
│   │   ├── models/
│   │   │   └── workout.dart   # Data models (Workout, WorkoutScheduleItem)
│   │   ├── screens/
│   │   │   ├── home_screen.dart              # Today's workout view
│   │   │   ├── history_screen.dart           # Past workout history
│   │   │   ├── workout_detail_screen.dart    # Detailed workout view
│   │   │   └── workout_management_screen.dart # CRUD for workouts
│   │   └── services/
│   │       └── api_service.dart              # HTTP client for backend
│   ├── pubspec.yaml           # Flutter dependencies & config
│   ├── web/                   # Web-specific assets
│   ├── android/               # Android build configs
│   ├── ios/                   # iOS build configs
│   └── windows/               # Windows build configs
│
├── netlify.toml               # Netlify deployment config
├── start_backend.bat          # Windows script to start backend
└── README.md                  # Project documentation
```

---

## 🔄 Development Workflow

### 1. Local Development Setup

#### Backend Setup
```bash
cd backend
pip install -r requirements.txt
python main.py
# Server runs at: http://localhost:8000
```

#### Flutter Setup
```bash
cd flutter_app
flutter pub get
flutter run
# Select target device (Chrome, Android, iOS, Windows)
```

### 2. Key Components

#### Backend API Endpoints (`backend/main.py`)
- `GET /` - Health check
- `GET /workouts` - List all workout definitions
- `GET /today` - Get today's scheduled workouts
- `GET /schedule/{date}` - Get workouts for specific date
- `POST /update-score` - Update workout performance score
- `POST /generate-routine` - Generate new workout schedule
- `POST /workouts` - Create new workout
- `PUT /workouts/{name}` - Update workout
- `DELETE /workouts/{name}` - Delete workout
- `GET /workouts.csv` - Download workouts CSV
- `GET /schedule.pkl` - Download schedule pickle

#### Frontend Screens
1. **Home Screen** (`home_screen.dart`)
   - Displays today's workouts
   - Score input with real-time validation
   - Progress bars (green: at/above goal, orange: below goal)
   - Navigate to history or generate new routine

2. **History Screen** (`history_screen.dart`)
   - Date picker for viewing past workouts
   - Historical score viewing
   - Future workout schedule preview

3. **Workout Management Screen** (`workout_management_screen.dart`)
   - Add/edit/delete workout definitions
   - Set goals and units (reps, minutes, miles, etc.)
   - Toggle home vs. park location

4. **Workout Detail Screen** (`workout_detail_screen.dart`)
   - Detailed view of individual workout

#### M-Sequence Algorithm (`mseq.py`)
- Generates balanced, pseudo-random workout schedules
- Configurable sequence power (typically 4-6)
- Ensures even distribution of workout types
- Avoids repetitive patterns

### 3. Data Models

#### Workout Definition
```dart
{
  name: String,       // e.g., "Push-ups", "Running"
  goal: double,       // Target performance
  units: String,      // "reps", "minutes", "miles"
  atPark: bool        // Location requirement
}
```

#### Workout Schedule Item
```dart
{
  date: String,       // ISO format date
  workout: String,    // Workout name
  score: double?,     // Actual performance (null if not done)
  units: String,
  atPark: bool,
  goal: double
}
```

### 4. Configuration

#### API Base URL (`api_service.dart`)
```dart
static const String baseUrl = 'https://workout-backend-h6pd.onrender.com';
// For local dev: 'http://localhost:8000'
```

#### Data Persistence (`main.py`)
```python
# Checks for persistent disk locations (Render deployment)
# Falls back to local ./data/ for development
```

---

## 🚀 Deployment

### Backend (Render.com)
- Web service connected to GitHub repo
- Build command: `pip install -r requirements.txt`
- Start command: `gunicorn -w 4 -k uvicorn.workers.UvicornWorker backend.main:app --bind 0.0.0.0:$PORT`
- Persistent disk mounted for data storage
- Environment: Python 3.10+

### Frontend (Netlify)
- Build command in `netlify.toml`:
  ```bash
  flutter pub get
  flutter build web --release
  ```
- Publish directory: `build/web`
- SPA redirect: `/* → /index.html`

---

## ✅ Current Features

- ✅ View today's scheduled workouts
- ✅ Update workout scores/progress in real-time
- ✅ Generate new workout routines with M-sequence algorithm
- ✅ View workout history for any date
- ✅ Visual progress tracking (progress bars)
- ✅ Distinguish between home and park workouts
- ✅ CRUD operations for workout definitions
- ✅ Cross-platform support (iOS, Android, Web, Windows)
- ✅ Persistent data storage
- ✅ CSV/Pickle data backup endpoints

---

## 📝 Task List

> **📌 See [TASKS.md](TASKS.md) for detailed task tracking and progress updates**

### 🔴 Critical Priority - Current Sprint
1. **Database Migration** - Replace pandas CSV/Pickle with proper database (PostgreSQL/SQLite)
   - [ ] Design schema and set up database
   - [ ] Migrate workout data from CSV
   - [ ] Migrate schedule data from Pickle
   - [ ] Update all API endpoints
   - [ ] Add Alembic migrations
   - [ ] Update deployment config

2. **Fix Workout Selection Algorithm** - Show last occurring workout (not exact date match)
   - [ ] Update `/today` endpoint to find most recent scheduled workout
   - [ ] Handle every-other-day schedules correctly
   - [ ] Test with various schedule patterns

3. **Edit History Scores** - Allow editing workout scores in history screen
   - [ ] Add edit controls to history workout cards
   - [ ] Enable score updates for past dates
   - [ ] Add confirmation and feedback

### 🟡 High Priority - Next Up
4. **Workout Details Dropdown** - Add expandable details for each workout
   - [ ] Create expandable card widget with workout history
   - [ ] Show progress and goals
   - [ ] Add smooth animations

5. **Progress Plotting** - Visual charts for workout progress
   - [ ] Add fl_chart library
   - [ ] Create line charts showing score over time
   - [ ] Integrate into workout management and detail screens
   - [ ] Add date range selector

### 🔄 In Progress
- [ ] Testing deployment on Render.com backend
- [ ] Testing Netlify frontend deployment
- [ ] Verifying persistent disk data storage

### 🟢 Medium Priority
- [ ] Add user authentication/multi-user support
- [ ] Implement offline mode with local caching
- [ ] Add push notifications for workout reminders
- [ ] Create onboarding tutorial/walkthrough
- [ ] Improve error handling and user feedback messages
- [ ] Add loading states and skeleton screens
- [ ] Implement data export/import functionality

### 🚀 Feature Enhancements
- [ ] Add workout statistics dashboard (weekly/monthly trends)
- [ ] Implement streak tracking (consecutive days)
- [ ] Add custom workout notes/comments
- [ ] Create workout presets/templates
- [ ] Add photo/video logging for exercises
- [ ] Implement social sharing features
- [ ] Add workout timer/stopwatch integration
- [ ] Create rest day scheduling
- [ ] Add workout intensity/difficulty ratings

### 🎨 UI/UX Improvements
- [ ] Dark mode support
- [ ] Custom theme colors
- [ ] Animation improvements (page transitions, progress bars)
- [ ] Better responsive design for tablets
- [ ] Accessibility improvements (screen readers, font scaling)
- [ ] Add tutorial tooltips for first-time users
- [ ] Improve date picker UX in history screen

### 🏗️ Technical Debt
- [ ] Add comprehensive error logging
- [ ] Implement proper state management (Provider/Riverpod/Bloc)
- [ ] Add unit tests for business logic
- [ ] Add integration tests for API
- [ ] Add widget tests for Flutter screens
- [ ] Set up CI/CD pipeline
- [ ] Add API versioning
- [ ] Implement rate limiting on backend
- [ ] Refactor code duplication in screens

### 🐛 Known Issues
- [ ] No offline support - requires internet connection
- [ ] API errors show technical messages to users
- [ ] No validation for duplicate workout names
- [ ] Date timezone handling may cause issues across regions
- [ ] No confirmation dialogs for delete operations

### 📚 Documentation
- [ ] Add API documentation (Swagger/OpenAPI)
- [ ] Create user guide/help section in app
- [ ] Document M-sequence algorithm parameters
- [ ] Add code comments and docstrings
- [ ] Create developer onboarding guide
- [ ] Document deployment process

### 🔮 Future Ideas (Low Priority)
- [ ] Apple Watch / Wear OS companion app
- [ ] Integration with fitness trackers (Fitbit, Apple Health)
- [ ] AI-powered workout recommendations
- [ ] Community features (leaderboards, challenges)
- [ ] Personal trainer mode (generate routines based on goals)
- [ ] Meal planning integration
- [ ] Rest and recovery tracking
- [ ] Injury prevention recommendations
- [ ] Voice command support
- [ ] AR workout demonstrations

---

## 🛠️ Development Commands

### Backend
```bash
# Start development server
cd backend
python main.py

# Install dependencies
pip install -r requirements.txt

# Test API endpoint
curl http://localhost:8000/workouts
```

### Flutter
```bash
# Get dependencies
flutter pub get

# Run on web
flutter run -d chrome

# Run on mobile emulator
flutter run

# Build for production
flutter build web --release       # Web
flutter build apk --release       # Android
flutter build ios --release       # iOS
flutter build windows --release   # Windows

# Run tests
flutter test

# Analyze code
flutter analyze

# Format code
dart format .
```

---

## 📊 Data Management

### Adding New Workouts
1. Use the Workout Management screen in the app, OR
2. Manually edit `backend/data/workouts.csv`:
   ```csv
   name,goal,units,at_park
   Push-ups,50,reps,False
   Running,3.0,miles,True
   ```

### Generating New Schedule
1. Use "Generate New Routine" from home screen menu
2. Select start date (defaults to today)
3. Choose sequence power (4-6, default 4)
4. Schedule generated and saved to `schedule.pkl`

### Backup Data
- Access `GET /workouts.csv` to download workout definitions
- Access `GET /schedule.pkl` to download current schedule

---

## 🤝 Contributing Guidelines

1. Create feature branch from `main`
2. Make changes with clear commit messages
3. Test locally (both backend and frontend)
4. Ensure no linting errors (`flutter analyze`, `flake8`)
5. Update this document if architecture changes
6. Submit PR with description of changes

---

## 📞 Contact & Support

**Project Owner:** johnp  
**Repository:** Local development  
**Backend URL:** https://workout-backend-h6pd.onrender.com  
**Frontend URL:** (Netlify URL pending)

---

## 📄 License

Private project - All rights reserved.
