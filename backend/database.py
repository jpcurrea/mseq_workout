"""
Database models and configuration for workout app
Uses SQLAlchemy ORM with SQLite backend
"""

from sqlalchemy import (
    create_engine, 
    Column, 
    Integer, 
    String, 
    Float, 
    Boolean, 
    Date, 
    DateTime,
    ForeignKey,
    UniqueConstraint
)
from sqlalchemy.orm import declarative_base, Session, sessionmaker, relationship
from sqlalchemy.pool import StaticPool
import datetime
import os

Base = declarative_base()


class User(Base):
    """User model for authentication and data ownership"""
    __tablename__ = 'users'
    
    id = Column(Integer, primary_key=True, autoincrement=True)
    email = Column(String, unique=True, nullable=False, index=True)
    username = Column(String, unique=True, nullable=False, index=True)
    
    # Traditional auth (nullable for OAuth-only users)
    hashed_password = Column(String, nullable=True)
    
    # OAuth fields
    oauth_provider = Column(String, nullable=True)  # 'google', 'github', etc.
    oauth_id = Column(String, nullable=True, index=True)  # Provider's user ID
    oauth_picture_url = Column(String, nullable=True)  # Profile picture
    
    created_at = Column(DateTime, default=datetime.datetime.utcnow)
    last_login = Column(DateTime, nullable=True)
    
    # Relationships
    workouts = relationship("Workout", back_populates="user", cascade="all, delete-orphan")
    schedule_entries = relationship("ScheduleEntry", back_populates="user", cascade="all, delete-orphan")
    
    def __repr__(self):
        return f"<User(id={self.id}, username='{self.username}', email='{self.email}')>"


class Workout(Base):
    """Workout model - each user has their own workouts"""
    __tablename__ = 'workouts'
    
    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('users.id'), nullable=False, index=True)
    name = Column(String, nullable=False)
    goal = Column(Float, nullable=False)
    units = Column(String, nullable=False)
    at_park = Column(Boolean, nullable=False, default=False)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)
    
    # Ensure each user can't have duplicate workout names
    __table_args__ = (UniqueConstraint('user_id', 'name', name='uix_user_workout_name'),)
    
    # Relationships
    user = relationship("User", back_populates="workouts")
    schedule_entries = relationship("ScheduleEntry", back_populates="workout", cascade="all, delete-orphan")
    
    def __repr__(self):
        return f"<Workout(id={self.id}, user_id={self.user_id}, name='{self.name}')>"


class ScheduleEntry(Base):
    """Schedule entry model - workout scheduled for a specific date with optional score"""
    __tablename__ = 'schedule'
    
    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('users.id'), nullable=False, index=True)
    workout_id = Column(Integer, ForeignKey('workouts.id'), nullable=False)
    date = Column(Date, nullable=False, index=True)
    score = Column(Float, nullable=True)
    
    # Relationships
    user = relationship("User", back_populates="schedule_entries")
    workout = relationship("Workout", back_populates="schedule_entries")
    
    def __repr__(self):
        return f"<ScheduleEntry(id={self.id}, user_id={self.user_id}, workout_id={self.workout_id}, date={self.date})>"


# Database configuration
def get_data_dir():
    """Get the data directory - check multiple possible locations"""
    # Check for Render persistent disk locations
    if os.path.exists("/backend/data"):
        data_dir = "/backend/data"
    elif os.path.exists("/data"):
        data_dir = "/data"
    else:
        # Fall back to local development
        data_dir = "./data"
    
    # Create directory if it doesn't exist
    os.makedirs(data_dir, exist_ok=True)
    
    return data_dir


def get_db_url():
    """Get database URL for SQLAlchemy"""
    data_dir = get_data_dir()
    db_path = os.path.join(data_dir, "workout_app.db")
    return f"sqlite:///{db_path}"


def create_engine_instance():
    """Create SQLAlchemy engine with proper configuration"""
    db_url = get_db_url()
    
    # For SQLite, use StaticPool to avoid threading issues in FastAPI
    engine = create_engine(
        db_url,
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
        echo=False  # Set to True for SQL query debugging
    )
    
    return engine


def init_db():
    """Initialize database - create all tables"""
    engine = create_engine_instance()
    Base.metadata.create_all(engine)
    return engine


def get_session() -> Session:
    """Get database session for dependency injection in FastAPI"""
    engine = create_engine_instance()
    SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()


# For direct usage (non-FastAPI context)
def create_session() -> Session:
    """Create a new database session"""
    engine = create_engine_instance()
    SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)
    return SessionLocal()
