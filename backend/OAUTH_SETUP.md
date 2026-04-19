# OAuth Setup Guide

This guide walks through setting up OAuth authentication for the workout app.

## Overview

We're implementing OAuth 2.0 with support for:
- ✅ **Google OAuth** (recommended - everyone has Gmail)
- ✅ **GitHub OAuth** (optional - for technical users)
- ✅ **Email/Password fallback** (for development/testing)

## Step 1: Get OAuth Credentials

### Google OAuth Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or select existing)
3. Enable Google+ API:
   - Navigate to "APIs & Services" > "Library"
   - Search for "Google+ API"
   - Click "Enable"
4. Create OAuth credentials:
   - Go to "APIs & Services" > "Credentials"
   - Click "Create Credentials" > "OAuth client ID"
   - Application type: "Web application"
   - Name: "Workout App"
   - Authorized redirect URIs:
     - `http://localhost:8000/auth/google/callback` (development)
     - `https://your-app.onrender.com/auth/google/callback` (production)
   - Click "Create"
5. Copy your:
   - **Client ID** (looks like: `123456789-abc.apps.googleusercontent.com`)
   - **Client Secret** (looks like: `GOCSPX-abc123xyz`)

### GitHub OAuth Setup (Optional)

1. Go to [GitHub Settings > Developer Settings](https://github.com/settings/developers)
2. Click "New OAuth App"
3. Fill in:
   - **Application name**: "Workout App"
   - **Homepage URL**: `https://your-app.onrender.com`
   - **Authorization callback URL**: `https://your-app.onrender.com/auth/github/callback`
4. Click "Register application"
5. Copy your:
   - **Client ID**
   - **Client Secret** (click "Generate a new client secret")

## Step 2: Set Environment Variables

Create a `.env` file in the `backend/` directory:

```bash
# App Configuration
SECRET_KEY=your-super-secret-key-here-change-this  # Generate with: openssl rand -hex 32
FRONTEND_URL=http://localhost:55905  # Your Flutter web dev server

# Google OAuth
GOOGLE_CLIENT_ID=your-google-client-id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-your-google-client-secret

# GitHub OAuth (optional)
GITHUB_CLIENT_ID=your-github-client-id
GITHUB_CLIENT_SECRET=your-github-client-secret

# Database
DATABASE_URL=sqlite:///data/workout_app.db  # Or PostgreSQL URL for production
```

**IMPORTANT:** 
- Never commit `.env` to git
- Add `.env` to your `.gitignore`
- Use different values for development vs production

## Step 3: Implementation Flow

### Backend Flow
```
1. User clicks "Login with Google" in Flutter app
2. Flutter opens browser to: /auth/google/login
3. Backend redirects to Google's OAuth consent screen
4. User approves permissions
5. Google redirects back to: /auth/google/callback?code=...
6. Backend exchanges code for user info
7. Backend creates/updates user in database
8. Backend generates JWT token
9. Backend redirects to Flutter app with token
```

### Frontend Flow (Flutter)
```dart
// Use flutter_web_auth_2 package for OAuth
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

Future<String> loginWithGoogle() async {
  final url = 'https://your-backend.com/auth/google/login';
  final callbackUrlScheme = 'workoutapp';  // Custom URL scheme
  
  try {
    final result = await FlutterWebAuth2.authenticate(
      url: url,
      callbackUrlScheme: callbackUrlScheme,
    );
    
    // Extract token from callback URL
    final token = Uri.parse(result).queryParameters['token'];
    return token;
  } catch (e) {
    throw Exception('Login failed: $e');
  }
}
```

## Step 4: Database Schema

Already implemented in `database.py`:

```python
class User(Base):
    email = Column(String, unique=True, nullable=False)
    username = Column(String, unique=True, nullable=False)
    hashed_password = Column(String, nullable=True)  # Null for OAuth users
    oauth_provider = Column(String, nullable=True)   # 'google', 'github'
    oauth_id = Column(String, nullable=True)         # Provider's user ID
    oauth_picture_url = Column(String, nullable=True)
```

## Step 5: Security Considerations

1. **HTTPS Required**: OAuth requires HTTPS in production
   - Render provides this automatically
   - Use `http://localhost` for local development only

2. **Token Storage**: Store JWT in Flutter's secure storage
   ```dart
   import 'package:flutter_secure_storage/flutter_secure_storage.dart';
   final storage = FlutterSecureStorage();
   await storage.write(key: 'auth_token', value: token);
   ```

3. **Token Expiration**: Set reasonable expiration (e.g., 7 days)
   ```python
   JWT_EXPIRE_MINUTES = 60 * 24 * 7  # 7 days
   ```

4. **CORS Configuration**: Update allowed origins
   ```python
   allow_origins=[
       "http://localhost:55905",  # Flutter dev
       "https://your-app.netlify.app",  # Flutter production
   ]
   ```

## Step 6: Testing Locally

1. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

2. Create `.env` file with your OAuth credentials

3. Run backend:
   ```bash
   python main.py
   ```

4. Test OAuth flow:
   - Open browser to: `http://localhost:8000/auth/google/login`
   - Should redirect to Google login
   - After approval, should redirect back with token

## Step 7: Production Deployment

### Backend (Render)
1. Add environment variables in Render dashboard
2. Update redirect URIs to use production URL
3. Deploy

### Frontend (Flutter)
1. Update API base URL to production backend
2. Add custom URL scheme for OAuth callbacks:
   - iOS: Update `Info.plist`
   - Android: Update `AndroidManifest.xml`
3. Build and deploy

## Troubleshooting

### "Redirect URI mismatch" error
- Ensure redirect URI in Google Console exactly matches backend URL
- Include the full path: `/auth/google/callback`
- Check for typos (http vs https, trailing slashes)

### "Invalid token" error
- Check SECRET_KEY is set correctly
- Ensure token hasn't expired
- Verify JWT decode settings match encode settings

### "CORS error" in Flutter web
- Add Flutter dev/production URLs to CORS allow_origins
- Check that credentials are included in requests

## Next Steps

After OAuth is working:
1. Add user profile screen (show Google profile picture)
2. Add "Login with Google" button to Flutter app
3. Add logout functionality
4. Add token refresh logic
5. Consider adding email/password as backup login method
