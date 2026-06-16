"""
Shared fixtures for all backend tests.

Each test gets a fresh in-memory SQLite database so tests are fully
isolated and never touch the production DB file.
"""
import sys
import os

# Ensure the backend directory is importable regardless of where pytest runs.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from database import (
    Base,
    User,
    Project,
    ProjectMembership,
    Task,
    Plan,
    get_session,
)
from dependencies import get_current_user_id


# ── Per-test in-memory DB ─────────────────────────────────────────────────────

@pytest.fixture
def db():
    """Fresh in-memory SQLite session for each test.

    StaticPool is required so that all SQLAlchemy connections (create_all,
    session queries, TestClient requests) share the exact same underlying
    sqlite3 connection — without it, each new connection opens a brand-new
    empty in-memory database.
    """
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    session = sessionmaker(bind=engine)()
    yield session
    session.close()
    engine.dispose()


# ── Common ORM object fixtures ────────────────────────────────────────────────

@pytest.fixture
def user(db):
    u = User(email="test@example.com", username="testuser")
    db.add(u)
    db.flush()
    return u


@pytest.fixture
def project(db, user):
    p = Project(name="Test Project", owner_id=user.id)
    db.add(p)
    db.flush()
    db.add(ProjectMembership(project_id=p.id, user_id=user.id, role="editor"))
    db.flush()
    return p


@pytest.fixture
def plan(db, user, project):
    p = Plan(user_id=user.id, project_id=project.id, title="Test Plan", content="")
    db.add(p)
    db.flush()
    return p


@pytest.fixture
def task(db, user, project):
    t = Task(user_id=user.id, project_id=project.id, title="Test Task")
    db.add(t)
    db.flush()
    return t


# ── HTTP client fixture (wires app to the test DB) ────────────────────────────

@pytest.fixture
def http_client(db, user, project):
    """
    Returns (TestClient, context_dict).

    The app's get_session and get_current_user_id dependencies are overridden
    to use the test DB and a hard-coded test user ID.
    """
    from fastapi.testclient import TestClient
    import main as app_module

    # Create a task embedded in a plan so HTTP plan-endpoint tests have data.
    embedded_task = Task(user_id=user.id, project_id=project.id, title="Embedded Task")
    db.add(embedded_task)
    db.flush()

    test_plan = Plan(
        user_id=user.id,
        project_id=project.id,
        title="HTTP Test Plan",
        content=f"{{{{task:{embedded_task.id}}}}}",
    )
    db.add(test_plan)
    db.commit()

    def _override_session():
        yield db

    app_module.app.dependency_overrides[get_session] = _override_session
    app_module.app.dependency_overrides[get_current_user_id] = lambda: user.id

    client = TestClient(app_module.app, raise_server_exceptions=True)
    yield client, {
        "user": user,
        "project": project,
        "task": embedded_task,
        "plan": test_plan,
        "db": db,
    }

    app_module.app.dependency_overrides.clear()
