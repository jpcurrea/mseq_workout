"""
Pure unit tests for the _next_due_date recurrence helper.
No database or HTTP calls — these run instantly.

June 2026 calendar reference (for weekday assertions):
  Mon  Tue  Wed  Thu  Fri  Sat  Sun
                    1    2    3    4    5    6    7
   8    9   10   11   12   13   14
  15   16   17   18   19   20   21
  22   23   24   25   26   27   28
  29   30
"""
import datetime
import pytest
from routers.tasks import _next_due_date

MON, TUE, WED, THU, FRI, SAT, SUN = range(7)

# ── DAILY ─────────────────────────────────────────────────────────────────────

def test_daily_advances_one_day():
    d = datetime.datetime(2026, 6, 16)  # Tuesday
    assert _next_due_date(d, "DAILY") == datetime.datetime(2026, 6, 17)

def test_daily_case_insensitive():
    d = datetime.datetime(2026, 6, 16)
    assert _next_due_date(d, "daily") == _next_due_date(d, "DAILY")

def test_daily_crosses_month_boundary():
    d = datetime.datetime(2026, 6, 30)
    assert _next_due_date(d, "DAILY") == datetime.datetime(2026, 7, 1)

# ── WEEKLY ────────────────────────────────────────────────────────────────────

def test_weekly_advances_seven_days():
    d = datetime.datetime(2026, 6, 16)  # Tuesday
    result = _next_due_date(d, "WEEKLY")
    assert result == datetime.datetime(2026, 6, 23)
    assert result.weekday() == TUE

def test_weekly_preserves_time():
    d = datetime.datetime(2026, 6, 16, 9, 30, 0)
    result = _next_due_date(d, "WEEKLY")
    assert result.hour == 9
    assert result.minute == 30

# ── MONTHLY ───────────────────────────────────────────────────────────────────

def test_monthly_advances_one_month():
    d = datetime.datetime(2026, 6, 15)
    result = _next_due_date(d, "MONTHLY")
    assert result.month == 7
    assert result.day == 15
    assert result.year == 2026

def test_monthly_year_rollover():
    d = datetime.datetime(2026, 12, 15)
    result = _next_due_date(d, "MONTHLY")
    assert result.month == 1
    assert result.year == 2027
    assert result.day == 15

# ── WEEKDAYS ──────────────────────────────────────────────────────────────────

def test_weekdays_monday_to_tuesday():
    monday = datetime.datetime(2026, 6, 15)
    assert monday.weekday() == MON
    result = _next_due_date(monday, "WEEKDAYS")
    assert result == datetime.datetime(2026, 6, 16)
    assert result.weekday() == TUE

def test_weekdays_thursday_to_friday():
    thursday = datetime.datetime(2026, 6, 11)
    assert thursday.weekday() == THU
    result = _next_due_date(thursday, "WEEKDAYS")
    assert result == datetime.datetime(2026, 6, 12)
    assert result.weekday() == FRI

def test_weekdays_friday_skips_to_monday():
    friday = datetime.datetime(2026, 6, 12)
    assert friday.weekday() == FRI
    result = _next_due_date(friday, "WEEKDAYS")
    assert result == datetime.datetime(2026, 6, 15)
    assert result.weekday() == MON

def test_weekdays_saturday_skips_to_monday():
    saturday = datetime.datetime(2026, 6, 13)
    assert saturday.weekday() == SAT
    result = _next_due_date(saturday, "WEEKDAYS")
    assert result.weekday() == MON

def test_weekdays_sunday_skips_to_monday():
    sunday = datetime.datetime(2026, 6, 14)
    assert sunday.weekday() == SUN
    result = _next_due_date(sunday, "WEEKDAYS")
    assert result.weekday() == MON

@pytest.mark.parametrize("offset", range(14))
def test_weekdays_never_lands_on_weekend(offset):
    """For any starting day, the result is always Mon–Fri."""
    base = datetime.datetime(2026, 6, 1)
    start = base + datetime.timedelta(days=offset)
    result = _next_due_date(start, "WEEKDAYS")
    assert result.weekday() < 5, (
        f"Started on {start.strftime('%A')} ({start.date()}), "
        f"got {result.strftime('%A')} ({result.date()})"
    )

def test_weekdays_always_after_input():
    """Result must always be strictly in the future."""
    for offset in range(10):
        d = datetime.datetime(2026, 6, 1) + datetime.timedelta(days=offset)
        assert _next_due_date(d, "WEEKDAYS") > d

# ── Unknown rule ──────────────────────────────────────────────────────────────

def test_unknown_rule_defaults_to_daily():
    d = datetime.datetime(2026, 6, 16)
    assert _next_due_date(d, "BOGUS") == d + datetime.timedelta(days=1)
    assert _next_due_date(d, "") == d + datetime.timedelta(days=1)
