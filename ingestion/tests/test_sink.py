from datetime import datetime, timezone

from observatory.sink import raw_key

TS = datetime(2026, 8, 12, 7, 30, tzinfo=timezone.utc)


def test_daily_key():
    assert raw_key("pulse", "patches", TS) == "raw/source=pulse/endpoint=patches/dt=2026-08-12/data.json.gz"


def test_hourly_key():
    key = raw_key("pulse", "activity", TS, hourly=True)
    assert key == "raw/source=pulse/endpoint=activity/dt=2026-08-12/hh=07/data.json.gz"
