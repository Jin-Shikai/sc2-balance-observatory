import json
import time
import urllib.parse

import urllib3


class RateLimitedClient:
    """GET-only JSON client. Adapts its request interval to RateLimit-* response headers."""

    def __init__(self, base_url, headers=None, min_interval=0.0):
        self.base = base_url.rstrip("/")
        self.pool = urllib3.PoolManager(headers={"Accept": "application/json", **(headers or {})})
        self.floor = min_interval
        self.interval = min_interval
        self._next_at = 0.0

    def get(self, path, params=None, retries=4):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        for attempt in range(retries + 1):
            self._throttle()
            r = self.pool.request("GET", url)
            self._adapt(r.headers)
            if r.status == 200:
                return json.loads(r.data) if r.data else None
            if r.status == 404:
                return None
            if r.status == 429 or r.status >= 500:
                time.sleep(float(r.headers.get("Retry-After") or 2**attempt))
                continue
            raise RuntimeError(f"GET {url} -> HTTP {r.status}")
        raise RuntimeError(f"GET {url} -> retries exhausted")

    def _throttle(self):
        now = time.monotonic()
        if now < self._next_at:
            time.sleep(self._next_at - now)
        self._next_at = max(now, self._next_at) + self.interval

    def _adapt(self, headers):
        limit, reset = headers.get("RateLimit-Limit"), headers.get("RateLimit-Reset")
        if limit and reset:
            try:
                self.interval = max(self.floor, float(reset) / max(float(limit), 1.0))
            except ValueError:
                pass
