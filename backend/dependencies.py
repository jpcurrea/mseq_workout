"""
FastAPI dependency for JWT authentication — shared across all routers.
"""
from typing import Optional

from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from jose import jwt, JWTError
from sqlalchemy.orm import Session

from database import get_session
from auth import SECRET_KEY, ALGORITHM

_security = HTTPBearer(auto_error=False)


def get_current_user_id(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_security),
    session: Session = Depends(get_session),
) -> int:
    """Return user_id from JWT Bearer token. Raises 401 if missing or invalid."""
    if credentials:
        try:
            payload = jwt.decode(credentials.credentials, SECRET_KEY, algorithms=[ALGORITHM])
            return int(payload.get("sub"))
        except (JWTError, ValueError):
            raise HTTPException(status_code=401, detail="Invalid or expired token")
    raise HTTPException(status_code=401, detail="Authentication required")
