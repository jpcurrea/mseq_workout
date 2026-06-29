"""
Tests for manual task ordering: the POST /tasks/reorder endpoint and the
sort_order field exposed by the serializer.
"""
from database import Task


def _make_task(db, user, project, title):
    t = Task(user_id=user.id, project_id=project.id, title=title)
    db.add(t)
    db.flush()
    return t


def test_reorder_assigns_sequential_sort_order(http_client):
    client, ctx = http_client
    db, user, project = ctx["db"], ctx["user"], ctx["project"]
    a = _make_task(db, user, project, "A")
    b = _make_task(db, user, project, "B")
    c = _make_task(db, user, project, "C")
    db.commit()

    r = client.post("/tasks/reorder", json={
        "project_id": project.id,
        "ordered_ids": [c.id, a.id, b.id],
    })
    assert r.status_code == 200
    assert r.json()["updated"] == 3

    db.refresh(a); db.refresh(b); db.refresh(c)
    assert c.sort_order == 0.0
    assert a.sort_order == 1.0
    assert b.sort_order == 2.0


def test_reorder_ignores_unknown_ids(http_client):
    client, ctx = http_client
    db, user, project = ctx["db"], ctx["user"], ctx["project"]
    a = _make_task(db, user, project, "A")
    db.commit()

    r = client.post("/tasks/reorder", json={
        "project_id": project.id,
        "ordered_ids": [a.id, 999999],
    })
    assert r.status_code == 200
    assert r.json()["updated"] == 1
    db.refresh(a)
    assert a.sort_order == 0.0


def test_reorder_empty_list_noop(http_client):
    client, ctx = http_client
    project = ctx["project"]
    r = client.post("/tasks/reorder", json={
        "project_id": project.id,
        "ordered_ids": [],
    })
    assert r.status_code == 200
    assert r.json()["updated"] == 0


def test_serializer_exposes_sort_order(http_client):
    client, ctx = http_client
    db, user, project = ctx["db"], ctx["user"], ctx["project"]
    a = _make_task(db, user, project, "A")
    a.sort_order = 3.0
    db.commit()

    r = client.get(f"/tasks?project_id={project.id}")
    assert r.status_code == 200
    tasks = {t["title"]: t for t in r.json()}
    assert tasks["A"]["sort_order"] == 3.0


def test_create_task_accepts_sort_order(http_client):
    client, ctx = http_client
    project = ctx["project"]
    r = client.post("/tasks", json={
        "project_id": project.id,
        "title": "Ordered",
        "sort_order": 5.0,
    })
    assert r.status_code == 200
    assert r.json()["sort_order"] == 5.0
