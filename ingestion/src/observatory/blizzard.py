import json

import urllib3

from .http import RateLimitedClient

REGIONS = {"us": 1, "eu": 2, "kr": 3}
QUEUE_1V1 = 201
ARRANGED = 0
DPLUS_LEAGUE_IDS = [4, 5, 6]


class Blizzard:
    def __init__(self, client_id, client_secret):
        auth = urllib3.make_headers(basic_auth=f"{client_id}:{client_secret}")
        r = urllib3.PoolManager().request(
            "POST", "https://oauth.battle.net/token", fields={"grant_type": "client_credentials"}, headers=auth
        )
        if r.status != 200:
            raise RuntimeError(f"oauth token -> HTTP {r.status}")
        token = json.loads(r.data)["access_token"]
        self.clients = {
            host: RateLimitedClient(
                f"https://{host}.api.blizzard.com",
                headers={"Authorization": f"Bearer {token}"},
                min_interval=0.02,
            )
            for host in REGIONS
        }

    def current_season(self, host):
        return self.clients[host].get(f"/sc2/ladder/season/{REGIONS[host]}")

    def league(self, host, season_id, league_id):
        return self.clients[host].get(f"/data/sc2/league/{season_id}/{QUEUE_1V1}/{ARRANGED}/{league_id}")

    def grandmaster(self, host):
        return self.clients[host].get(f"/sc2/ladder/grandmaster/{REGIONS[host]}")
