import datetime as dt

from app.models.reading import Reading
from app.services.reading_service import _coalesce


def _reading(user_id="u1", **kwargs):
    defaults = dict(id="r", user_id=user_id, heart_rate=None, spo2=None, temperature=None, ecg_mv=None, battery=None)
    defaults.update(kwargs)
    return Reading(**defaults)


def test_no_output_until_all_three_fields_seen():
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", heart_rate=60, recorded_at=t0),
        _reading(id="2", spo2=97, recorded_at=t0 + dt.timedelta(seconds=1)),
        # temperature never arrives — no record should ever be emitted
    ]
    out = _coalesce(readings, visible_from=t0)
    assert out == []


def test_emits_once_all_three_fields_carry_forward():
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", heart_rate=60, recorded_at=t0),
        _reading(id="2", spo2=97, recorded_at=t0 + dt.timedelta(seconds=5)),
        _reading(id="3", temperature=36.6, recorded_at=t0 + dt.timedelta(seconds=10)),
    ]
    out = _coalesce(readings, visible_from=t0)
    assert len(out) == 1
    assert out[0].heart_rate == 60
    assert out[0].spo2 == 97
    assert out[0].temperature == 36.6


def test_stale_value_is_not_carried_forward():
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", heart_rate=60, recorded_at=t0),
        _reading(id="2", spo2=97, recorded_at=t0 + dt.timedelta(minutes=10)),  # HR now stale (>5 min)
        _reading(id="3", temperature=36.6, recorded_at=t0 + dt.timedelta(minutes=10, seconds=1)),
    ]
    out = _coalesce(readings, visible_from=t0)
    assert out == []  # HR from 10 minutes ago no longer counts


def test_throttles_to_minimum_gap_between_emissions():
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", heart_rate=60, recorded_at=t0),
        _reading(id="2", spo2=97, recorded_at=t0 + dt.timedelta(seconds=1)),
        _reading(id="3", temperature=36.6, recorded_at=t0 + dt.timedelta(seconds=2)),
    ]
    # Once primed, rapid-fire HR updates every second for 90s should not
    # each produce a new coalesced record — only one per COALESCE_MIN_GAP.
    for i in range(3, 93):
        readings.append(_reading(id=str(i), heart_rate=60 + i, recorded_at=t0 + dt.timedelta(seconds=i)))
    out = _coalesce(readings, visible_from=t0)
    assert 1 <= len(out) <= 2  # ~90 seconds / 60s min-gap, not 90 records


def test_pre_range_records_excluded_via_visible_from():
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", heart_rate=60, recorded_at=t0 - dt.timedelta(minutes=2)),
        _reading(id="2", spo2=97, recorded_at=t0 - dt.timedelta(minutes=1)),
        _reading(id="3", temperature=36.6, recorded_at=t0 - dt.timedelta(seconds=30)),
    ]
    # All three fields are known before `visible_from` — nothing should
    # leak into a query for a range that starts at t0.
    out = _coalesce(readings, visible_from=t0)
    assert out == []
