"""
OAuth authentication implementation
Supports Google and GitHub OAuth 2.0
"""

from authlib.integrations.starlette_client import OAuth
from starlette.config import Config
from starlette.middleware.sessions import SessionMiddleware
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import RedirectResponse
import os
from datetime import datetime, timedelta
from jose import jwt, JWTError
from typing import Optional
import secrets

# Import database models
from database import create_session, User

# Load environment variables
config = Config('.env')

# OAuth configuration
oauth = OAuth(config)

# Register Google OAuth
oauth.register(
    name='google',
    client_id=config.get('GOOGLE_CLIENT_ID', default=None),
    client_secret=config.get('GOOGLE_CLIENT_SECRET', default=None),
    server_metadata_url='https://accounts.google.com/.well-known/openid-configuration',
    client_kwargs={
        'scope': 'openid email profile'
    }
)

# Register GitHub OAuth (optional)
if config.get('GITHUB_CLIENT_ID', default=None):
    oauth.register(
        name='github',
        client_id=config.get('GITHUB_CLIENT_ID', default=None),
        client_secret=config.get('GITHUB_CLIENT_SECRET', default=None),
        access_token_url='https://github.com/login/oauth/access_token',
        authorize_url='https://github.com/login/oauth/authorize',
        api_base_url='https://api.github.com/',
        client_kwargs={'scope': 'user:email'},
    )

# JWT configuration
SECRET_KEY = config.get('SECRET_KEY', default=secrets.token_urlsafe(32))
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24  # 24 hours

# Frontend URL for redirects after auth
# FRONTEND_URL = config.get('FRONTEND_URL', default='http://localhost:8080')
FRONTEND_URL = config.get('FRONTEND_URL', default='https://mseq-workout.netlify.app/')

# Router for auth endpoints
router = APIRouter(prefix="/auth", tags=["authentication"])


def create_access_token(user_id: int, email: str) -> str:
    """Create JWT access token"""
    expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode = {
        "sub": str(user_id),
        "email": email,
        "exp": expire
    }
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt


def get_or_create_user_from_oauth(
    email: str, 
    username: str, 
    oauth_provider: str, 
    oauth_id: str,
    picture_url: Optional[str] = None
) -> dict:
    """Get existing user or create new one from OAuth data. Returns a plain dict."""
    session = create_session()
    
    try:
        # Check if user exists by OAuth ID
        user = session.query(User).filter(
            User.oauth_provider == oauth_provider,
            User.oauth_id == oauth_id
        ).first()
        
        if user:
            user.last_login = datetime.utcnow()
            if picture_url:
                user.oauth_picture_url = picture_url
            session.commit()
            return {"id": user.id, "email": user.email, "username": user.username}
        
        # Check if user exists by email
        user = session.query(User).filter(User.email == email).first()
        
        if user:
            user.oauth_provider = oauth_provider
            user.oauth_id = oauth_id
            user.oauth_picture_url = picture_url
            user.last_login = datetime.utcnow()
            session.commit()
            return {"id": user.id, "email": user.email, "username": user.username}
        
        # Create new user — ensure unique username
        base_username = username.replace(' ', '_').lower()
        unique_username = base_username
        counter = 1
        while session.query(User).filter(User.username == unique_username).first():
            unique_username = f"{base_username}{counter}"
            counter += 1
        
        user = User(
            email=email,
            username=unique_username,
            oauth_provider=oauth_provider,
            oauth_id=oauth_id,
            oauth_picture_url=picture_url,
            hashed_password=None,
            last_login=datetime.utcnow()
        )
        session.add(user)
        session.commit()
        return {"id": user.id, "email": user.email, "username": user.username}
    
    finally:
        session.close()



@router.get("/google/login")
async def google_login(request: Request):
    """Initiate Google OAuth flow"""
    if not config.get('GOOGLE_CLIENT_ID', default=None):
        raise HTTPException(status_code=500, detail="Google OAuth not configured")

    # Use production backend URL for redirect URI
    # Change this to your deployed backend URL
    # redirect_uri = "https://your-backend.onrender.com/auth/google/callback"
    redirect_uri = "https://workout-backend-h6pd.onrender.com/auth/google/callback"
    return await oauth.google.authorize_redirect(request, redirect_uri)


@router.get("/google/callback")
async def google_callback(request: Request):
    """Handle Google OAuth callback"""
    try:
        # Get access token from Google
        token = await oauth.google.authorize_access_token(request)
        
        # Get user info from Google
        user_info = token.get('userinfo')
        if not user_info:
            raise HTTPException(status_code=400, detail="Failed to get user info from Google")
        
        # Extract user data
        email = user_info.get('email')
        name = user_info.get('name', email.split('@')[0])
        oauth_id = user_info.get('sub')
        picture = user_info.get('picture')
        
        if not email or not oauth_id:
            raise HTTPException(status_code=400, detail="Invalid user info from Google")
        
        # Create or get user
        user = get_or_create_user_from_oauth(
            email=email,
            username=name,
            oauth_provider='google',
            oauth_id=oauth_id,
            picture_url=picture
        )
        
        # Create JWT token
        access_token = create_access_token(user["id"], user["email"])
        
        # Redirect to frontend with token
        # For mobile apps, use custom URL scheme: workoutapp://auth?token=...
        # For web, redirect to frontend URL with token as query param
        redirect_url = f"{FRONTEND_URL}/auth/callback?token={access_token}"
        return RedirectResponse(url=redirect_url)
    
    except Exception as e:
        # Redirect to frontend with error
        error_url = f"{FRONTEND_URL}/auth/error?message={str(e)}"
        return RedirectResponse(url=error_url)


@router.get("/github/login")
async def github_login(request: Request):
    """Initiate GitHub OAuth flow"""
    if not config.get('GITHUB_CLIENT_ID', default=None):
        raise HTTPException(status_code=500, detail="GitHub OAuth not configured")
    
    redirect_uri = request.url_for('github_callback')
    return await oauth.github.authorize_redirect(request, redirect_uri)


@router.get("/github/callback")
async def github_callback(request: Request):
    """Handle GitHub OAuth callback"""
    try:
        # Get access token from GitHub
        token = await oauth.github.authorize_access_token(request)
        
        # Get user info from GitHub
        resp = await oauth.github.get('user', token=token)
        user_info = resp.json()
        
        # Extract user data
        email = user_info.get('email')
        username = user_info.get('login')
        oauth_id = str(user_info.get('id'))
        picture = user_info.get('avatar_url')
        
        # If email is private, fetch from /user/emails
        if not email:
            emails_resp = await oauth.github.get('user/emails', token=token)
            emails = emails_resp.json()
            primary_email = next(
                (e['email'] for e in emails if e['primary']),
                None
            )
            if primary_email:
                email = primary_email
            else:
                raise HTTPException(status_code=400, detail="Could not get email from GitHub")
        
        # Create or get user
        user = get_or_create_user_from_oauth(
            email=email,
            username=username,
            oauth_provider='github',
            oauth_id=oauth_id,
            picture_url=picture
        )
        
        # Create JWT token
        access_token = create_access_token(user["id"], user["email"])
        
        # Redirect to frontend with token
        redirect_url = f"{FRONTEND_URL}/auth/callback?token={access_token}"
        return RedirectResponse(url=redirect_url)
    
    except Exception as e:
        error_url = f"{FRONTEND_URL}/auth/error?message={str(e)}"
        return RedirectResponse(url=error_url)


@router.get("/me")
async def get_current_user_info(user_id: int):
    """Get current user info (requires authentication)"""
    session = create_session()
    try:
        user = session.query(User).filter(User.id == user_id).first()
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        
        return {
            "id": user.id,
            "email": user.email,
            "username": user.username,
            "oauth_provider": user.oauth_provider,
            "picture_url": user.oauth_picture_url,
            "created_at": user.created_at.isoformat() if user.created_at else None,
            "last_login": user.last_login.isoformat() if user.last_login else None,
        }
    finally:
        session.close()


# Dependency for protecting routes
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

security = HTTPBearer()


async def get_current_user_id(
    credentials: HTTPAuthorizationCredentials = Depends(security)
) -> int:
    """
    Dependency to extract and verify JWT token
    Use this to protect endpoints that require authentication
    
    Example:
        @app.get("/protected")
        async def protected_route(user_id: int = Depends(get_current_user_id)):
            return {"user_id": user_id}
    """
    token = credentials.credentials
    
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id = int(payload.get("sub"))
        
        if user_id is None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid authentication token"
            )
        
        return user_id
    
    except JWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid authentication token"
        )
