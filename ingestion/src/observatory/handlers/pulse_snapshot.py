from observatory.pulse import QUEUE, TEAM_TYPE, Pulse
from observatory.sink import put_raw


def handler(event, context):
    pulse = Pulse()
    season = pulse.current_season()
    base = {"queue": QUEUE, "teamType": TEAM_TYPE}

    put_raw("pulse", "activity", pulse.activity(), base, hourly=True)
    put_raw("pulse", "tier-thresholds", pulse.tier_thresholds(season), {**base, "season": season}, hourly=True)
    return {"season": season}
