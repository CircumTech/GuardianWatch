import datetime as dt

from app.models.reading import Reading
from app.services.reading_service import (
    COALESCE_MIN_GAP,
    COALESCE_STALENESS,
    _coalesce,
)


def _reading(user_id="u1", **kwargs):
    defaults = dict(
        id="r",
        user_id=user_id,
        heart_rate=None,
        spo2=None,
        temperature=None,
        ecg_mv=None,
        battery=None,
    )
    defaults.update(kwargs)
    return Reading(**defaults)


def test_emits_as_soon_as_hr_is_present():
    """
    HR is the only required metric. SpO2 and temperature are optional —
    the mobile History screen already renders rows with nulls.
    """
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [_reading(id="1", heart_rate=60, recorded_at=t0)]
    out = _coalesce(readings, visible_from=t0)
    assert len(out) == 1
    assert out[0].heart_rate == 60
    assert out[0].spo2 is None
    assert out[0].temperature is None


def test_attaches_spo2_and_temp_when_fresh():
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", heart_rate=60, recorded_at=t0),
        _reading(id="2", spo2=97, recorded_at=t0 + dt.timedelta(seconds=5)),
        _reading(id="3", temperature=36.6, recorded_at=t0 + dt.timedelta(seconds=10)),
        # A second HR arrives past the 60-second throttle, and both
        # SpO2 and Temp are still within the 5-minute staleness window.
        _reading(id="4", heart_rate=61, recorded_at=t0 + dt.timedelta(seconds=70)),
    ]
    out = _coalesce(readings, visible_from=t0)
    assert len(out) == 2
    assert out[0].heart_rate == 60
    assert out[0].spo2 is None  # nothing yet at emit time
    assert out[1].heart_rate == 61
    assert out[1].spo2 == 97
    assert out[1].temperature == 36.6


def test_drops_stale_spo2_and_temp():
    """
    SpO2 and temp that arrive more than COALESCE_STALENESS before the
    emitted record are dropped — a fresh HR does not retroactively
    attach yesterday's oxygen reading.
    """
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", spo2=97, recorded_at=t0),
        _reading(id="2", temperature=36.6, recorded_at=t0 + dt.timedelta(seconds=1)),
        # HR arrives 10 minutes later — SpO2 and Temp now stale
        _reading(id="3", heart_rate=60, recorded_at=t0 + dt.timedelta(minutes=10)),
    ]
    out = _coalesce(readings, visible_from=t0)
    assert len(out) == 1
    assert out[0].heart_rate == 60
    assert out[0].spo2 is None
    assert out[0].temperature is None


def test_drops_stale_hr():
    """
    If no HR has been seen within the staleness window, no record is
    emitted — even if a SpO2 sample arrives.
    """
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", heart_rate=60, recorded_at=t0),
        _reading(id="2", spo2=97, recorded_at=t0 + dt.timedelta(minutes=10)),
    ]
    out = _coalesce(readings, visible_from=t0)
    # First HR emits immediately at t0 (before visible_from check picks up
    # the second sample); no second emit because HR is stale.
    assert len(out) == 1
    assert out[0].heart_rate == 60


def test_throttles_to_minimum_gap_between_emissions():
    """
    Rapid-fire HR at 1 Hz for 90 seconds should not produce 90 records —
    only one per COALESCE_MIN_GAP.
    """
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [_reading(id="0", heart_rate=60, recorded_at=t0)]
    for i in range(1, 91):
        readings.append(
            _reading(
                id=str(i),
                heart_rate=60 + i,
                recorded_at=t0 + dt.timedelta(seconds=i),
            )
        )
    out = _coalesce(readings, visible_from=t0)
    # 90 seconds / 60-second gap → 1 or 2 records
    assert 1 <= len(out) <= 2


def test_pre_range_records_excluded_via_visible_from():
    """
    Records before `visible_from` warm the carry-forward state but do
    not emit. This lets the coalescer use a lookback window without
    leaking pre-range samples into the response.
    """
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", heart_rate=60, recorded_at=t0 - dt.timedelta(minutes=2)),
        _reading(id="2", spo2=97, recorded_at=t0 - dt.timedelta(minutes=1)),
        _reading(id="3", temperature=36.6, recorded_at=t0 - dt.timedelta(seconds=30)),
    ]
    out = _coalesce(readings, visible_from=t0)
    assert out == []


def test_staleness_boundary_is_exclusive():
    """
    A value at exactly COALESCE_STALENESS is still fresh; one second
    past is stale.
    """
    t0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    readings = [
        _reading(id="1", spo2=97, recorded_at=t0),
        # HR at exactly STALENESS later — SpO2 should attach
        _reading(id="2", heart_rate=60, recorded_at=t0 + COALESCE_STALENESS),
        # HR one second past STALENESS — SpO2 should NOT attach
        _reading(
            id="3",
            heart_rate=61,
            recorded_at=t0 + COALESCE_STALENESS + dt.timedelta(seconds=1),
        ),
    ]
    out = _coalesce(readings, visible_from=t0)
    assert len(out) == 2
    # The first record attaches SpO2 (exactly at boundary)
    assert out[0].spo2 == 97
    # The second is past the boundary, and also past MIN_GAP so it's a
    # separate record — SpO2 is dropped
    assert out[1].spo2 is None