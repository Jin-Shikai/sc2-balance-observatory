from observatory.pulse import DPLUS, QUEUE, REGIONS, TEAM_TYPE, TIERS, Pulse
from observatory.sink import put_raw


def handler(event, context):
    """event: {"seasons": [66, 67]} overrides the default of the current season (backfill)."""
    pulse = Pulse()
    seasons = (event or {}).get("seasons") or [pulse.current_season()]
    base = {"queue": QUEUE, "teamType": TEAM_TYPE}

    put_raw("pulse", "seasons", pulse.seasons())
    put_raw("pulse", "patches", pulse.patches())
    put_raw("pulse", "player-base", pulse.player_base(), base)

    for season in seasons:
        for region in REGIONS:
            for league in DPLUS:
                for tier in TIERS[league]:
                    payload, params = pulse.balance_report(season, region, league, tier)
                    if payload:
                        name = f"s{season}-{region}-{league}-{tier}".lower()
                        put_raw("pulse", "balance-reports", payload, params, name=name)

        for i, (teams, params) in enumerate(pulse.ladder_pages(season)):
            put_raw("pulse", "teams", teams, {**params, "season": season}, name=f"s{season}-p{i:04d}")

    return {"seasons": seasons}
