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
    UniqueConstraint,
    Table,
    Text,
    text,
)
from sqlalchemy.orm import declarative_base, Session, sessionmaker, relationship, backref
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
    # Last project the user had open in the task app (restored on next login)
    active_project_id = Column(Integer, nullable=True)  # FK added after Project is defined

    # Optional per-user LLM provider override (BYO key). The key is stored
    # encrypted at rest (Fernet); base_url/model let users pick any
    # OpenAI-compatible provider (OpenAI, Gemini, Claude, local, ...).
    llm_api_key_encrypted = Column(Text, nullable=True)
    llm_api_base_url = Column(String, nullable=True)
    llm_model = Column(String, nullable=True)
    
    # Relationships
    workouts = relationship("Workout", back_populates="user", cascade="all, delete-orphan")
    schedule_entries = relationship("ScheduleEntry", back_populates="user", cascade="all, delete-orphan")
    tasks = relationship("Task", back_populates="user", cascade="all, delete-orphan")
    tags = relationship("Tag", back_populates="user", cascade="all, delete-orphan")
    work_sessions = relationship("WorkSession", back_populates="user", cascade="all, delete-orphan")
    plans = relationship("Plan", back_populates="user", cascade="all, delete-orphan")
    llm_conversations = relationship("LLMConversation", back_populates="user", cascade="all, delete-orphan")
    accounts = relationship("Account", back_populates="user", cascade="all, delete-orphan")
    budget_goals = relationship("BudgetGoal", back_populates="user", cascade="all, delete-orphan")
    project_memberships = relationship("ProjectMembership", back_populates="user", cascade="all, delete-orphan")
    
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
    exercise_id = Column(String, nullable=True)  # free-exercise-db exercise id
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


# ── Project models ─────────────────────────────────────────────────────────────

class Project(Base):
    """A named container for tasks and plans, sharable with other users."""
    __tablename__ = "projects"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    owner_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

    memberships = relationship("ProjectMembership", back_populates="project", cascade="all, delete-orphan")
    invites = relationship("ProjectInvite", back_populates="project", cascade="all, delete-orphan")
    tasks = relationship("Task", back_populates="project")
    plans = relationship("Plan", back_populates="project")

    def __repr__(self):
        return f"<Project(id={self.id}, name='{self.name}')>"


class ProjectMembership(Base):
    """Maps a user to a project with a role."""
    __tablename__ = "project_memberships"

    id = Column(Integer, primary_key=True, autoincrement=True)
    project_id = Column(Integer, ForeignKey("projects.id"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    role = Column(String, nullable=False, default="editor")  # "owner" | "editor" | "viewer"
    joined_at = Column(DateTime, default=datetime.datetime.utcnow)

    __table_args__ = (UniqueConstraint("project_id", "user_id", name="uix_project_user"),)

    project = relationship("Project", back_populates="memberships")
    user = relationship("User", back_populates="project_memberships")

    def __repr__(self):
        return f"<ProjectMembership(project={self.project_id}, user={self.user_id}, role='{self.role}')>"


class ProjectInvite(Base):
    """A redeemable token that grants membership to a project."""
    __tablename__ = "project_invites"

    id = Column(Integer, primary_key=True, autoincrement=True)
    token = Column(String, unique=True, nullable=False, index=True)  # random UUID
    project_id = Column(Integer, ForeignKey("projects.id"), nullable=False, index=True)
    created_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    role_to_grant = Column(String, nullable=False, default="editor")  # "editor" | "viewer"
    max_uses = Column(Integer, nullable=True)  # None = unlimited
    use_count = Column(Integer, nullable=False, default=0)
    expires_at = Column(DateTime, nullable=True)  # None = never expires
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

    project = relationship("Project", back_populates="invites")

    def __repr__(self):
        return f"<ProjectInvite(id={self.id}, project={self.project_id})>"

# M2M association table between Task and Tag (no extra columns)
task_tag_link = Table(
    "task_tag_links",
    Base.metadata,
    Column("task_id", Integer, ForeignKey("tasks.id", ondelete="CASCADE"), primary_key=True),
    Column("tag_id", Integer, ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True),
)


class Tag(Base):
    """User-defined label for tasks (name + hex color)."""
    __tablename__ = "tags"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    name = Column(String, nullable=False)
    color = Column(String, nullable=False, default="#6366f1")  # hex color

    __table_args__ = (UniqueConstraint("user_id", "name", name="uix_user_tag_name"),)

    user = relationship("User", back_populates="tags")
    tasks = relationship("Task", secondary=task_tag_link, back_populates="tags")

    def __repr__(self):
        return f"<Tag(id={self.id}, name='{self.name}')>"


class Task(Base):
    """A task or sub-task. Self-referential for hierarchical subtasks."""
    __tablename__ = "tasks"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    project_id = Column(Integer, ForeignKey("projects.id"), nullable=False, index=True)
    title = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    due_date = Column(DateTime, nullable=True)
    duration_minutes = Column(Integer, nullable=True)  # estimated
    parent_task_id = Column(Integer, ForeignKey("tasks.id"), nullable=True, index=True)
    is_completed = Column(Boolean, nullable=False, default=False)
    completed_at = Column(DateTime, nullable=True)
    is_recurring = Column(Boolean, nullable=False, default=False)
    recurrence_rule = Column(String, nullable=True)  # "DAILY" | "WEEKLY" | "MONTHLY"
    # When True (or NULL for legacy parents with subtasks), a parent task's
    # effective duration is the sum of its subtasks' durations; when False the
    # parent uses its own manually-set duration_minutes.
    inherit_subtask_duration = Column(Boolean, nullable=True)
    # Manual ordering position within a list. Seeded from a parameter sort and
    # then adjusted by drag-and-drop. NULL means "no manual position set".
    sort_order = Column(Float, nullable=True)
    # How a recurring task advances on completion: "now" (next iteration after
    # the current moment, skipping missed ones) or "stop" (next iteration after
    # the selected stop time).
    recurrence_advance_mode = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)
    updated_at = Column(
        DateTime,
        default=datetime.datetime.utcnow,
        onupdate=datetime.datetime.utcnow,
    )

    user = relationship("User", back_populates="tasks")
    project = relationship("Project", back_populates="tasks")
    # Self-referential adjacency list: subtasks / parent
    subtasks = relationship(
        "Task",
        foreign_keys=[parent_task_id],
        backref=backref("parent_task", remote_side=[id]),
        cascade="all",
        lazy="select",
    )
    tags = relationship("Tag", secondary=task_tag_link, back_populates="tasks")
    work_sessions = relationship("WorkSession", back_populates="task", cascade="all, delete-orphan")

    def __repr__(self):
        return f"<Task(id={self.id}, title='{self.title}', completed={self.is_completed})>"


class WorkSession(Base):
    """Tracks actual time spent on a task. ended_at=None means currently active."""
    __tablename__ = "work_sessions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    task_id = Column(Integer, ForeignKey("tasks.id"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    started_at = Column(DateTime, nullable=False, default=datetime.datetime.utcnow)
    ended_at = Column(DateTime, nullable=True)   # null = session still active
    notes = Column(Text, nullable=True)

    task = relationship("Task", back_populates="work_sessions")
    user = relationship("User", back_populates="work_sessions")

    def __repr__(self):
        return f"<WorkSession(id={self.id}, task_id={self.task_id}, active={self.ended_at is None})>"


class Plan(Base):
    """A rich markdown document that can embed task widgets via {{task:ID}} tokens."""
    __tablename__ = "plans"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    project_id = Column(Integer, ForeignKey("projects.id"), nullable=False, index=True)
    title = Column(String, nullable=False)
    content = Column(Text, nullable=False, default="")
    created_at = Column(DateTime, default=datetime.datetime.utcnow)
    updated_at = Column(
        DateTime,
        default=datetime.datetime.utcnow,
        onupdate=datetime.datetime.utcnow,
    )

    user = relationship("User", back_populates="plans")
    project = relationship("Project", back_populates="plans")
    llm_conversations = relationship("LLMConversation", back_populates="plan")
    revisions = relationship("PlanRevision", back_populates="plan", cascade="all, delete-orphan", order_by="PlanRevision.saved_at")

    def __repr__(self):
        return f"<Plan(id={self.id}, title='{self.title}')>"


class PlanRevision(Base):
    """Stores a unified diff of each plan save for history tracking."""
    __tablename__ = "plan_revisions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    plan_id = Column(Integer, ForeignKey("plans.id"), nullable=False, index=True)
    saved_by = Column(Integer, ForeignKey("users.id"), nullable=False)
    saved_at = Column(DateTime, default=datetime.datetime.utcnow, nullable=False)
    diff = Column(Text, nullable=False)  # unified diff (old → new content)

    plan = relationship("Plan", back_populates="revisions")

    def __repr__(self):
        return f"<PlanRevision(id={self.id}, plan_id={self.plan_id}, saved_at={self.saved_at})>"


class LLMConversation(Base):
    """Stored LLM agent conversation history (planning or analytics mode)."""
    __tablename__ = "llm_conversations"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    mode = Column(String, nullable=False)           # "planning" | "analytics"
    messages = Column(Text, nullable=False, default="[]")  # JSON array of recent raw turns
    summary = Column(Text, nullable=True)           # compressed memory of older turns
    related_plan_id = Column(Integer, ForeignKey("plans.id"), nullable=True)
    project_id = Column(Integer, ForeignKey("projects.id"), nullable=True, index=True)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)
    updated_at = Column(
        DateTime,
        default=datetime.datetime.utcnow,
        onupdate=datetime.datetime.utcnow,
    )

    user = relationship("User", back_populates="llm_conversations")
    plan = relationship("Plan", back_populates="llm_conversations")


class TaskCompletion(Base):
    """An immutable record of one task-completion event.

    Stored independently of the task (with snapshot fields) so the history
    survives task edits/deletions and captures every recurrence completion.
    """
    __tablename__ = "task_completions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    task_id = Column(Integer, ForeignKey("tasks.id"), nullable=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    project_id = Column(Integer, ForeignKey("projects.id"), nullable=True, index=True)
    title = Column(String, nullable=True)             # snapshot at completion
    completed_at = Column(DateTime, nullable=False, default=datetime.datetime.utcnow, index=True)
    due_date = Column(DateTime, nullable=True)         # snapshot
    duration_minutes = Column(Integer, nullable=True)  # estimated, snapshot
    actual_minutes = Column(Float, nullable=True)      # measured from work sessions
    tags = Column(String, nullable=True)               # comma-joined snapshot
    status = Column(String, nullable=False, default="completed")  # "completed" | "skipped"
    note = Column(Text, nullable=True)                 # optional end-of-task note
    work_sessions_json = Column(Text, nullable=True)   # JSON array of {started_at, ended_at, duration_minutes, notes}
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

    def __repr__(self):
        return f"<TaskCompletion(id={self.id}, task_id={self.task_id}, at={self.completed_at})>"


class LLMUsage(Base):
    """Per-request token usage and estimated cost for the LLM agent.

    Summed to enforce a hard spending cap (LLM_SPEND_CAP_USD).
    """
    __tablename__ = "llm_usage"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=True, index=True)
    model = Column(String, nullable=True)
    prompt_tokens = Column(Integer, nullable=False, default=0)
    completion_tokens = Column(Integer, nullable=False, default=0)
    cost_usd = Column(Float, nullable=False, default=0.0)
    created_at = Column(DateTime, default=datetime.datetime.utcnow, index=True)

    def __repr__(self):
        return f"<LLMUsage(id={self.id}, model={self.model}, cost=${self.cost_usd:.4f})>"



# ── Budget models ──────────────────────────────────────────────────────────────

class Account(Base):
    """A bank/savings account whose balance contributes to 'spendable now'."""
    __tablename__ = "accounts"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    name = Column(String, nullable=False)
    balance = Column(Float, nullable=False, default=0.0)
    updated_at = Column(
        DateTime,
        default=datetime.datetime.utcnow,
        onupdate=datetime.datetime.utcnow,
    )

    user = relationship("User", back_populates="accounts")

    def __repr__(self):
        return f"<Account(id={self.id}, name='{self.name}', balance={self.balance})>"


class BudgetGoal(Base):
    """A savings goal that reserves money from the 'spendable now' balance."""
    __tablename__ = "budget_goals"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    name = Column(String, nullable=False)
    target_amount = Column(Float, nullable=False)
    target_date = Column(Date, nullable=True)
    current_saved = Column(Float, nullable=False, default=0.0)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

    user = relationship("User", back_populates="budget_goals")

    def __repr__(self):
        return f"<BudgetGoal(id={self.id}, name='{self.name}', target={self.target_amount})>"


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
    """Initialize database - create all tables and run lightweight migrations."""
    engine = create_engine_instance()
    Base.metadata.create_all(engine)
    # Lightweight ALTER TABLE migrations for schema upgrades on existing databases
    _migrations = [
        "ALTER TABLE workouts ADD COLUMN exercise_id TEXT",
        "ALTER TABLE users ADD COLUMN active_project_id INTEGER",
        # tasks.project_id: nullable temporarily so old rows survive; migration
        # in main.py startup_event assigns them to the user's Personal project.
        "ALTER TABLE tasks ADD COLUMN project_id INTEGER",
        "ALTER TABLE plans ADD COLUMN project_id INTEGER",
        "ALTER TABLE llm_conversations ADD COLUMN summary TEXT",
        "ALTER TABLE llm_conversations ADD COLUMN project_id INTEGER",
        "ALTER TABLE users ADD COLUMN llm_api_key_encrypted TEXT",
        "ALTER TABLE users ADD COLUMN llm_api_base_url TEXT",
        "ALTER TABLE users ADD COLUMN llm_model TEXT",
        "ALTER TABLE task_completions ADD COLUMN status TEXT DEFAULT 'completed'",
        "ALTER TABLE task_completions ADD COLUMN work_sessions_json TEXT",
        "ALTER TABLE task_completions ADD COLUMN note TEXT",
        "ALTER TABLE tasks ADD COLUMN recurrence_advance_mode TEXT",
        "ALTER TABLE tasks ADD COLUMN inherit_subtask_duration BOOLEAN",
        "ALTER TABLE tasks ADD COLUMN sort_order REAL",
    ]
    with engine.connect() as conn:
        for stmt in _migrations:
            try:
                conn.execute(text(stmt))
                conn.commit()
            except Exception:
                pass  # Column already exists
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
