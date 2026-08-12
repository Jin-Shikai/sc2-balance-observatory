from .http import RateLimitedClient

PAGE = 200


class Aligulac:
    def __init__(self, apikey):
        self.c = RateLimitedClient("https://aligulac.com/api/v1", min_interval=1.0)
        self.key = apikey

    def _pages(self, resource, params):
        offset = 0
        while True:
            page = self.c.get(f"/{resource}/", {**params, "apikey": self.key, "limit": PAGE, "offset": offset})
            objects = (page or {}).get("objects") or []
            if not objects:
                return
            yield objects
            if not page["meta"].get("next"):
                return
            offset += PAGE

    def latest_period(self):
        page = self.c.get("/period/", {"apikey": self.key, "order_by": "-id", "limit": 1})
        return page["objects"][0]

    def matches_since(self, date_iso):
        yield from self._pages("match", {"date__gte": date_iso, "order_by": "date"})

    def active_ratings(self, period_id, top=1000):
        fetched = 0
        for objects in self._pages("activerating", {"period": period_id, "order_by": "-rating"}):
            yield objects
            fetched += len(objects)
            if fetched >= top:
                return
