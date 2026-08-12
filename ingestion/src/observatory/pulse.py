from .http import RateLimitedClient

QUEUE = "LOTV_1V1"
TEAM_TYPE = "ARRANGED"
REGIONS = ["US", "EU", "KR"]
DPLUS = ["DIAMOND", "MASTER", "GRANDMASTER"]
TIERS = {"DIAMOND": ["FIRST", "SECOND", "THIRD"], "MASTER": ["FIRST", "SECOND", "THIRD"], "GRANDMASTER": ["FIRST"]}


class Pulse:
    def __init__(self):
        self.c = RateLimitedClient("https://sc2pulse.nephest.com/sc2/api", min_interval=0.5)

    def seasons(self):
        return self.c.get("/seasons")

    def current_season(self):
        return max(s["battlenetId"] for s in self.seasons())

    def patches(self):
        return self.c.get("/patches")

    def player_base(self):
        return self.c.get("/stats/player-base", {"queue": QUEUE, "teamType": TEAM_TYPE})

    def activity(self):
        return self.c.get("/stats/activity", {"queue": QUEUE, "teamType": TEAM_TYPE})

    def tier_thresholds(self, season):
        return self.c.get("/tier-thresholds", {"queue": QUEUE, "teamType": TEAM_TYPE, "season": season})

    def balance_report(self, season, region, league, tier):
        params = {
            "queue": QUEUE,
            "teamType": TEAM_TYPE,
            "season": season,
            "region": region,
            "league": league,
            "tier": tier,
        }
        return self.c.get("/stats/balance-reports", params), params

    def ladder_pages(self, season, leagues=DPLUS):
        params = {
            "queue": QUEUE,
            "teamType": TEAM_TYPE,
            "season": season,
            "league": ",".join(leagues),
            "sort": "-rating",
        }
        after = None
        while True:
            page = self.c.get("/teams", {**params, **({"after": after} if after else {})})
            teams = (page or {}).get("result") or []
            if not teams:
                return
            yield teams, params
            after = page["navigation"].get("after")
            if not after:
                return
