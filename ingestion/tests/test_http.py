from observatory.http import RateLimitedClient


def test_adapts_interval_from_headers():
    c = RateLimitedClient("https://example.com", min_interval=0.1)
    c._adapt({"RateLimit-Limit": "20", "RateLimit-Reset": "10"})
    assert c.interval == 0.5


def test_interval_never_below_floor():
    c = RateLimitedClient("https://example.com", min_interval=0.5)
    c._adapt({"RateLimit-Limit": "1000", "RateLimit-Reset": "1"})
    assert c.interval == 0.5


def test_ignores_malformed_headers():
    c = RateLimitedClient("https://example.com", min_interval=0.1)
    c._adapt({"RateLimit-Limit": "x", "RateLimit-Reset": "y"})
    assert c.interval == 0.1
