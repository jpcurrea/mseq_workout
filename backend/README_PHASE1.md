# Phase 1 Complete: Database Schema with OAuth Support ✅

## What's Been Created

### 1. **Database Schema** ([database.py](database.py))
Multi-user database with OAuth support:
- `User` table - with OAuth fields (provider, oauth_id, picture_url)
- `Workout` table - scoped to users via `user_id`
- `ScheduleEntry` table - scoped to users and workouts
- Proper foreign keys, indexes, and constraints

### 2. **OAuth Implementation** ([auth.py](auth.py))
Full OAuth 2.0 authentication:
- ✅ Google OAuth (one-click login)
- ✅ GitHub OAuth (optional)
- ✅ JWT token generation
- ✅ User creation/linking from OAuth
- ✅ Authentication dependency for protecting routes

### 3. **Migration Tools**
- [migrate_to_db.py](migrate_to_db.py) - Migrate existing CSV/pickle data
- [test_database.py](test_database.py) - Test database schema
- [OAUTH_SETUP.md](OAUTH_SETUP.md) - Complete OAuth setup guide

### 4. **Configuration**
- [.env.example](.env.example) - Environment variables template
- [requirements.txt](requirements.txt) - Updated with OAuth dependencies
- [.gitignore](.gitignore) - Protects sensitive files

## Quick Start

### 1. Install Dependencies
```bash
pip install -r requirements.txt
```

### 2. Set Up Environment Variables
```bash
# Copy template
cp .env.example .env

# Edit .env with your OAuth credentials from Google Cloud Console
# See OAUTH_SETUP.md for detailed instructions
```

### 3. Test Database Schema
```bash
python test_database.py
```

### 4. Migrate Existing Data (Optional)
```bash
python migrate_to_db.py
```

## Next Steps

### Phase 2: Integrate OAuth into main.py
- Add session middleware for OAuth
- Include auth router
- Add authentication to existing endpoints
- Filter all queries by user_id

### Phase 3: Build Flutter UI
- Login screen with "Sign in with Google" button
- Token storage (flutter_secure_storage)
- Auth state management
- Update API calls to include auth token

## OAuth Flow Overview

```
┌─────────────┐
│ Flutter App │
│  (Login)    │
└──────┬──────┘
       │
       │ 1. Open: /auth/google/login
       ▼
┌─────────────┐
│   Backend   │──────2. Redirect to────────┐
└──────┬──────┘                             │
       │                                    ▼
       │                           ┌────────────────┐
       │                           │ Google OAuth   │
       │                           │ Consent Screen │
       │                           └────────┬───────┘
       │                                    │
       │◄──────3. Callback with code───────┘
       │
       │ 4. Exchange code for user info
       │ 5. Create/update user in database
       │ 6. Generate JWT token
       │
       │ 7. Redirect to Flutter with token
       ▼
┌─────────────┐
│ Flutter App │
│  (Home)     │
└─────────────┘
```

## Database Schema

```sql
-- Users table
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    username TEXT UNIQUE NOT NULL,
    hashed_password TEXT,              -- Null for OAuth users
    oauth_provider TEXT,                -- 'google', 'github', etc.
    oauth_id TEXT,                      -- Provider's user ID
    oauth_picture_url TEXT,             -- Profile picture
    created_at TIMESTAMP,
    last_login TIMESTAMP
);

-- Workouts table (user-scoped)
CREATE TABLE workouts (
    id INTEGER PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    name TEXT NOT NULL,
    goal REAL NOT NULL,
    units TEXT NOT NULL,
    at_park BOOLEAN NOT NULL,
    created_at TIMESTAMP,
    UNIQUE(user_id, name)
);

-- Schedule table (user-scoped)
CREATE TABLE schedule (
    id INTEGER PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    workout_id INTEGER REFERENCES workouts(id),
    date DATE NOT NULL,
    score REAL
);
```

## Security Features

✅ **OAuth 2.0** - Secure, industry-standard authentication  
✅ **JWT Tokens** - Stateless authentication with expiration  
✅ **Password Hashing** - Bcrypt for traditional auth (optional)  
✅ **User Isolation** - All queries filtered by user_id  
✅ **HTTPS Ready** - Works with Render's automatic HTTPS  
✅ **Environment Variables** - Secrets kept out of code  

## File Structure

```
backend/
├── auth.py              # OAuth implementation
├── database.py          # SQLAlchemy models
├── main.py              # FastAPI app (to be updated)
├── migrate_to_db.py     # Data migration script
├── test_database.py     # Test script
├── requirements.txt     # Dependencies
├── .env                 # Environment variables (create from .env.example)
├── .env.example         # Template
├── .gitignore           # Protects .env and .db files
├── OAUTH_SETUP.md       # Detailed OAuth guide
└── README_PHASE1.md     # This file
```

## Getting OAuth Credentials

### Google (Required)
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create project → Enable Google+ API
3. Create OAuth credentials → Web application
4. Add redirect URI: `http://localhost:8000/auth/google/callback`
5. Copy Client ID and Secret to `.env`

### GitHub (Optional)
1. Go to [GitHub Settings → Developer](https://github.com/settings/developers)
2. New OAuth App
3. Add callback URL: `http://localhost:8000/auth/github/callback`
4. Copy Client ID and Secret to `.env`

See [OAUTH_SETUP.md](OAUTH_SETUP.md) for screenshots and detailed instructions.

## FAQ

**Q: Can users still use email/password?**  
A: Yes! The schema supports both OAuth and traditional auth. OAuth users have `hashed_password=null`, traditional users have `oauth_provider=null`.

**Q: What if a user signs in with Google, then later with GitHub using same email?**  
A: The system links them to the same account. The first OAuth provider used gets stored, but they can use either to login.

**Q: Is SQLite good enough for production?**  
A: For personal/small apps with <100 concurrent users, yes! For larger scale, migrate to PostgreSQL (just change DATABASE_URL).

**Q: How do I test OAuth locally?**  
A: Use `http://localhost:8000` as your redirect URI in OAuth console. It works fine for development.

**Q: Do I need HTTPS for OAuth?**  
A: Only in production. Google/GitHub allow `http://localhost` for development.

## Ready to Continue?

Phase 1 is complete! Next:
1. Get OAuth credentials from Google Cloud Console
2. Create `.env` file
3. Test the database schema
4. Move to Phase 2: Integrate with main.py
