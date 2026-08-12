from datetime import timedelta

from observatory.aligulac import Aligulac
from observatory.sink import put_raw, secret, utcnow


def handler(event, context):
    """event: {"since": "2015-11-10"} overrides the default 3-day lookback (backfill)."""
    ag = Aligulac(secret("ALIGULAC_SECRET_ARN")["apikey"])
    since = (event or {}).get("since") or (utcnow() - timedelta(days=3)).strftime("%Y-%m-%d")

    period = ag.latest_period()
    put_raw("aligulac", "periods", period)

    for i, matches in enumerate(ag.matches_since(since)):
        put_raw("aligulac", "matches", matches, {"date__gte": since}, name=f"since-{since}-p{i:04d}")

    for i, ratings in enumerate(ag.active_ratings(period["id"])):
        put_raw("aligulac", "ratings", ratings, {"period": period["id"]}, name=f"period-{period['id']}-p{i:04d}")

    return {"since": since, "period": period["id"]}
