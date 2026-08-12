from observatory.blizzard import DPLUS_LEAGUE_IDS, REGIONS, Blizzard
from observatory.sink import put_raw, secret


def handler(event, context):
    creds = secret("BLIZZARD_SECRET_ARN")
    bz = Blizzard(creds["client_id"], creds["client_secret"])

    for host in REGIONS:
        season = bz.current_season(host)
        put_raw("blizzard", "season", season, {"region": host}, name=f"season-{host}")
        season_id = season["seasonId"]

        for league_id in DPLUS_LEAGUE_IDS:
            payload = bz.league(host, season_id, league_id)
            if payload:
                params = {"region": host, "seasonId": season_id, "leagueId": league_id}
                put_raw("blizzard", "league", payload, params, name=f"league-{host}-{league_id}")

        gm = bz.grandmaster(host)
        if gm:
            put_raw("blizzard", "gm-ladder", gm, {"region": host}, name=f"gm-{host}")

    return {"ok": True}
