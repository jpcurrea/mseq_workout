# Workout Routine Mobile App

This mobile app is a port of your Python workout routine generator, split into a FastAPI backend and Flutter frontend.

## Architecture

- **Backend**: FastAPI Python server that wraps your existing workout logic
- **Frontend**: Flutter mobile app for iOS/Android
- **Data**: Uses your existing CSV and pickle files

## Setup Instructions

### 1. Backend Setup

1. Navigate to the backend directory:
   ```bash
   cd mobile_app/backend
   ```

2. Install Python dependencies:
   ```bash
   pip install -r requirements.txt
   ```

3. Run the FastAPI server:
   ```bash
   python main.py
   ```

   The API will be available at `http://localhost:8000`

### 2. Flutter App Setup

1. Install Flutter SDK from https://flutter.dev/docs/get-started/install

2. Navigate to the Flutter app directory:
   ```bash
   cd mobile_app/flutter_app
   ```

3. Install dependencies:
   ```bash
   flutter pub get
   ```

4. Update the API endpoint in `lib/services/api_service.dart` if needed

5. Run the app:
   ```bash
   flutter run
   ```

## Features

### Current Features
- ✅ View today's workout schedule
- ✅ Update workout scores/progress
- ✅ Generate new workout routines
- ✅ View workout history for any date
- ✅ Visual progress tracking
- ✅ Distinguish between home and park workouts

### Mobile App Advantages
- **Accessibility**: Always in your pocket
- **Offline capability**: Can be extended to work offline
- **Better UX**: Touch-friendly interface designed for mobile
- **Notifications**: Can add workout reminders
- **Quick logging**: Fast score entry with optimized keyboard

## API Endpoints

- `GET /workouts` - Get all available workouts
- `GET /today` - Get today's scheduled workouts
- `GET /schedule/{date}` - Get workouts for specific date
- `POST /update-score` - Update workout score
- `POST /generate-routine` - Generate new workout routine

## Alternative Mobile Approaches

### Option 1: Flutter + FastAPI (Current Implementation)
**Pros**: Native performance, your existing Python logic preserved
**Cons**: Requires running a backend server

### Option 2: Pure Flutter with Dart Port
**Pros**: Self-contained app, no backend needed
**Cons**: Would need to port m-sequence logic to Dart

### Option 3: React Native + Node.js
**Pros**: JavaScript ecosystem, good cross-platform support
**Cons**: Would need to port Python logic to JavaScript

### Option 4: Progressive Web App (PWA)
**Pros**: Works on any device with a browser, easier deployment
**Cons**: Limited native features, requires internet connection

## Deployment Options

### For Backend:
- **Local**: Run on your computer (current setup)
- **Cloud**: Deploy to Heroku, Railway, or DigitalOcean
- **Self-hosted**: Run on Raspberry Pi or home server

### For Mobile App:
- **Development**: `flutter run` for testing
- **Android**: Build APK with `flutter build apk`
- **iOS**: Build with `flutter build ios` (requires Mac + Xcode)
- **App Stores**: Publish to Google Play Store / Apple App Store

## Next Steps

1. **Test the current implementation**:
   - Start the backend server
   - Run the Flutter app
   - Generate a routine and test functionality

2. **Enhance features**:
   - Add workout progress charts
   - Implement push notifications for workout reminders
   - Add workout completion celebrations
   - Include exercise instructions/videos

3. **Deploy for production**:
   - Set up cloud hosting for the backend
   - Build and install the mobile app
   - Configure automatic routine generation

Would you like me to help you set up any of these components or explore a different approach?