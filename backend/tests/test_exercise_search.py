"""
Exercise search — regression coverage for the free-exercise-db lookup.

The original bug: routers/workouts.py did `from exercises import _EXERCISES` at
import time, while load_exercises() *rebound* that global at startup. The router
therefore held a permanently empty list and /exercises/search always returned [].
"""
import exercises as exercise_db


def test_load_exercises_mutates_in_place_so_early_imports_stay_valid():
    from exercises import _EXERCISES, _EXERCISES_IDX  # early binding, like the router did

    exercise_db.load_exercises()

    assert len(_EXERCISES) > 0
    assert len(_EXERCISES_IDX) == len(_EXERCISES)
    assert _EXERCISES is exercise_db._EXERCISES


def test_search_matches_tokens_in_any_order():
    names = {e["name"] for e in exercise_db.search_exercises("bench press", 10)}
    reversed_names = {e["name"] for e in exercise_db.search_exercises("press bench", 10)}
    assert names
    assert names & reversed_names


def test_search_returns_empty_for_blank_query_without_filters():
    assert exercise_db.search_exercises("   ", 10) == []


def test_search_filters_by_muscle_and_equipment():
    results = exercise_db.search_exercises("", 5, muscle="biceps", equipment="dumbbell")
    assert results
    for r in results:
        assert "dumbbell" in (r["equipment"] or "").lower()


def test_search_filters_by_force_and_mechanic():
    results = exercise_db.search_exercises("", 8, force="push", mechanic="compound")
    assert results
    for r in results:
        assert r["force"] == "push"
        assert r["mechanic"] == "compound"


def test_force_and_mechanic_are_exact_matches():
    assert exercise_db.search_exercises("", 5, force="pus") == []
    assert exercise_db.search_exercises("", 5, mechanic="compoun") == []


def test_search_results_expose_programming_fields():
    result = exercise_db.search_exercises("bench press", 1)[0]
    for field in ("level", "force", "mechanic", "category"):
        assert field in result


def test_facets_report_real_values_with_counts():
    f = exercise_db.facets()
    assert set(f) == {"equipment", "category", "level", "force", "mechanic", "muscle"}
    assert set(f["force"]) == {"push", "pull", "static"}
    assert set(f["mechanic"]) == {"compound", "isolation"}
    assert set(f["level"]) == {"beginner", "intermediate", "expert"}
    # Counts are descending and never include empty/None buckets.
    for values in f.values():
        assert all(v > 0 for v in values.values())
        assert list(values.values()) == sorted(values.values(), reverse=True)


def test_every_facet_value_returns_matches():
    """Guards against advertising a filter value that yields nothing."""
    f = exercise_db.facets()
    for field, values in f.items():
        for value in values:
            assert exercise_db.search_exercises("", 1, **{field: value}), f"{field}={value}"


def test_find_by_name_is_exact_but_forgiving_about_formatting():
    target = exercise_db.search_exercises("bench press", 1)[0]
    assert exercise_db.find_by_name(target["name"])["id"] == target["id"]
    assert exercise_db.find_by_name(target["name"].upper())["id"] == target["id"]
    assert exercise_db.find_by_name(f"  {target['name']}  ")["id"] == target["id"]


def test_find_by_name_refuses_partial_matches():
    """Auto-linking uses this, so a near-miss must not resolve."""
    assert exercise_db.find_by_name("Bench") is None
    assert exercise_db.find_by_name("") is None
    assert exercise_db.find_by_name("Johns Special Circuit") is None


def test_every_exercise_is_reachable_by_its_own_name():
    for ex in exercise_db.all_exercises():
        assert exercise_db.find_by_name(ex["name"])["id"] == ex["id"]


def test_search_results_include_image_url_and_id():
    result = exercise_db.search_exercises("squat", 1)[0]
    assert result["id"]
    assert result["imageUrl"].endswith(f"/{result['id']}/0.jpg")


def test_find_exercise_round_trips():
    first = exercise_db.all_exercises()[0]
    assert exercise_db.find_exercise(first["id"])["name"] == first["name"]
    assert exercise_db.find_exercise("no-such-exercise") is None


def test_search_endpoint_returns_results(http_client):
    client, _ = http_client
    resp = client.get("/exercises/search", params={"q": "squat", "limit": 5})
    assert resp.status_code == 200
    body = resp.json()
    assert len(body) > 0
    assert all("id" in item and "name" in item for item in body)


def test_search_endpoint_supports_filters(http_client):
    client, _ = http_client
    resp = client.get("/exercises/search", params={"q": "", "muscle": "chest", "limit": 3})
    assert resp.status_code == 200
    assert len(resp.json()) == 3


def test_search_endpoint_supports_force_and_mechanic(http_client):
    client, _ = http_client
    resp = client.get(
        "/exercises/search",
        params={"q": "", "force": "pull", "mechanic": "compound", "limit": 5},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body
    assert all(r["force"] == "pull" and r["mechanic"] == "compound" for r in body)


def test_filters_endpoint_is_not_shadowed_by_exercise_id_route(http_client):
    client, _ = http_client
    resp = client.get("/exercises/filters")
    assert resp.status_code == 200
    assert "force" in resp.json()


def test_exercise_detail_endpoint(http_client):
    client, _ = http_client
    target = exercise_db.search_exercises("squat", 1)[0]
    resp = client.get(f"/exercises/{target['id']}")
    assert resp.status_code == 200
    assert resp.json()["name"] == target["name"]

    assert client.get("/exercises/definitely-not-real").status_code == 404
