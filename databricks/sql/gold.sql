CREATE SCHEMA IF NOT EXISTS sc2.gold;

CREATE OR REPLACE TEMPORARY FUNCTION wilson_low(wins BIGINT, games BIGINT) RETURNS DOUBLE
RETURN CASE WHEN games > 0 THEN
  (wins / games + 1.92 / games - 1.96 * sqrt((wins / games) * (1 - wins / games) / games + 0.96 / (games * games)))
  / (1 + 3.84 / games) END;

CREATE OR REPLACE TEMPORARY FUNCTION wilson_high(wins BIGINT, games BIGINT) RETURNS DOUBLE
RETURN CASE WHEN games > 0 THEN
  (wins / games + 1.92 / games + 1.96 * sqrt((wins / games) * (1 - wins / games) / games + 0.96 / (games * games)))
  / (1 + 3.84 / games) END;

-- frames with absolute time: frame_start = season start + number * duration
CREATE OR REPLACE TEMPORARY VIEW frames_ts AS
WITH f AS (
  SELECT *, coalesce(try_cast(regexp_extract(frame_duration, 'P(\\d+)D', 1) AS INT), 7) AS duration_days
  FROM sc2.silver.fct_balance_frame
  WHERE race <> versus_race
)
SELECT
  f.*,
  concat(left(f.race, 1), 'v', left(f.versus_race, 1))                        AS matchup,
  timestampadd(DAY, f.frame_number * f.duration_days, s.start_ts)             AS frame_start,
  timestampadd(DAY, (f.frame_number + 1) * f.duration_days, s.start_ts)       AS frame_end
FROM f
JOIN sc2.silver.dim_season s ON s.season_bnet_id = f.season_bnet_id AND s.region = f.region;

CREATE OR REPLACE TEMPORARY VIEW patch_releases AS
SELECT patch_id, version, r.region, r.release_ts
FROM sc2.silver.dim_patch
LATERAL VIEW stack(3, 'US', release_us, 'EU', release_eu, 'KR', release_kr) r AS region, release_ts
WHERE r.release_ts IS NOT NULL AND is_versus;

CREATE OR REPLACE TABLE sc2.gold.balance_profile AS
SELECT
  region, league, matchup, season_bnet_id,
  date(frame_start) AS frame_date,
  sum(wins) AS wins, sum(games) AS games,
  sum(wins) / sum(games)              AS winrate,
  wilson_low(sum(wins), sum(games))   AS ci_low,
  wilson_high(sum(wins), sum(games))  AS ci_high
FROM frames_ts
GROUP BY ALL;

CREATE OR REPLACE TABLE sc2.gold.patch_event_study AS
WITH windows AS (
  SELECT p.version, p.region, p.release_ts, f.league, f.matchup,
    CASE
      WHEN f.frame_end   <= p.release_ts AND f.frame_start >= timestampadd(DAY, -14, p.release_ts) THEN 'pre'
      WHEN f.frame_start >= p.release_ts AND f.frame_end   <= timestampadd(DAY, 14, p.release_ts) THEN 'post'
    END AS phase,
    f.wins, f.games
  FROM patch_releases p
  JOIN frames_ts f ON f.region = p.region
),
agg AS (
  SELECT version, region, release_ts, league, matchup,
    sum(IF(phase = 'pre', wins, 0))   AS wins_pre,
    sum(IF(phase = 'pre', games, 0))  AS games_pre,
    sum(IF(phase = 'post', wins, 0))  AS wins_post,
    sum(IF(phase = 'post', games, 0)) AS games_post
  FROM windows
  WHERE phase IS NOT NULL
  GROUP BY ALL
)
SELECT
  version, region, release_ts, league, matchup,
  games_pre,
  wins_pre / nullif(games_pre, 0)                 AS winrate_pre,
  wilson_low(wins_pre, games_pre)                 AS ci_low_pre,
  wilson_high(wins_pre, games_pre)                AS ci_high_pre,
  games_post,
  wins_post / nullif(games_post, 0)               AS winrate_post,
  wilson_low(wins_post, games_post)               AS ci_low_post,
  wilson_high(wins_post, games_post)              AS ci_high_post,
  wins_post / nullif(games_post, 0) - wins_pre / nullif(games_pre, 0) AS winrate_delta,
  wilson_low(wins_post, games_post) > wilson_high(wins_pre, games_pre)
    OR wilson_high(wins_post, games_post) < wilson_low(wins_pre, games_pre) AS delta_significant
FROM agg
WHERE games_pre > 0 AND games_post > 0;

CREATE OR REPLACE TABLE sc2.gold.map_balance_attribution AS
WITH per_map AS (
  SELECT season_bnet_id, region, league, matchup, map_id, map_name,
    sum(wins) AS wins, sum(games) AS games
  FROM frames_ts
  GROUP BY ALL
)
SELECT
  *,
  wins / nullif(games, 0) AS map_winrate,
  sum(wins) OVER pool / nullif(sum(games) OVER pool, 0) AS pool_winrate,
  wins / nullif(games, 0) - sum(wins) OVER pool / nullif(sum(games) OVER pool, 0) AS map_deviation,
  games / nullif(sum(games) OVER pool, 0) AS games_share
FROM per_map
WINDOW pool AS (PARTITION BY season_bnet_id, region, league, matchup);

CREATE OR REPLACE TABLE sc2.gold.race_migration_flow AS
WITH char_race AS (
  SELECT p.version, p.region, t.character_id,
    CASE WHEN t.snapshot_date <  date(p.release_ts)
          AND t.snapshot_date >= date(timestampadd(DAY, -28, p.release_ts)) THEN 'pre'
         WHEN t.snapshot_date >= date(p.release_ts)
          AND t.snapshot_date <  date(timestampadd(DAY, 28, p.release_ts)) THEN 'post' END AS phase,
    t.race, sum(t.games_delta) AS games
  FROM patch_releases p
  JOIN sc2.silver.fct_ladder_team_snapshot t
    ON t.region = p.region
   AND t.snapshot_date BETWEEN date(timestampadd(DAY, -28, p.release_ts))
                           AND date(timestampadd(DAY, 28, p.release_ts))
  WHERE t.race IS NOT NULL AND t.games_delta > 0
  GROUP BY ALL
),
dominant AS (
  SELECT version, region, character_id, phase, max_by(race, games) AS race
  FROM char_race
  WHERE phase IS NOT NULL
  GROUP BY version, region, character_id, phase
),
pivoted AS (
  SELECT version, region, character_id,
    max(IF(phase = 'pre', race, NULL))  AS race_pre,
    max(IF(phase = 'post', race, NULL)) AS race_post
  FROM dominant
  GROUP BY version, region, character_id
)
SELECT
  version, region,
  coalesce(race_pre, 'NEW')    AS race_from,
  coalesce(race_post, 'CHURN') AS race_to,
  count(*)                     AS character_count
FROM pivoted
GROUP BY ALL;

CREATE OR REPLACE TABLE sc2.gold.climb_rate_by_race AS
WITH per_team_month AS (
  SELECT date_trunc('month', snapshot_date)::DATE AS month, region, league, race, team_id,
    max_by(rating, snapshot_date) - min_by(rating, snapshot_date) AS rating_gain,
    sum(games_delta) AS games
  FROM sc2.silver.fct_ladder_team_snapshot
  WHERE race IS NOT NULL
  GROUP BY ALL
  HAVING games >= 10
)
SELECT
  month, region, league, race,
  count(*) AS teams,
  percentile(rating_gain / games * 30, 0.25) AS gain_per_30games_p25,
  percentile(rating_gain / games * 30, 0.50) AS gain_per_30games_p50,
  percentile(rating_gain / games * 30, 0.75) AS gain_per_30games_p75
FROM per_team_month
GROUP BY ALL;

CREATE OR REPLACE TABLE sc2.gold.population_trend AS
WITH daily AS (
  SELECT t.snapshot_date, t.region, t.race,
    IF(t.league IN ('MASTER', 'GRANDMASTER'), 'MASTER+', t.league) AS league_group,
    t.character_id, sum(t.games_delta) AS games, min(c.first_seen) AS first_seen
  FROM sc2.silver.fct_ladder_team_snapshot t
  JOIN sc2.silver.dim_character c USING (character_id)
  WHERE t.games_delta > 0 AND t.race IS NOT NULL
  GROUP BY ALL
)
SELECT
  snapshot_date AS date, region, league_group, race,
  count(DISTINCT character_id) AS active_characters,
  sum(games)                   AS games_played,
  count(DISTINCT IF(first_seen = snapshot_date, character_id, NULL)) AS new_characters
FROM daily
GROUP BY ALL;

CREATE OR REPLACE TABLE sc2.gold.pro_vs_ladder_gap AS
WITH pro AS (
  SELECT p.version, m.race, m.versus_race,
    sum(IF(m.is_win, 1, 0)) AS wins, count(*) AS games
  FROM patch_releases p
  JOIN sc2.silver.fct_pro_match m
    ON m.match_date >= date(p.release_ts) AND m.match_date < date(timestampadd(DAY, 28, p.release_ts))
  WHERE p.region = 'EU'
  GROUP BY ALL
),
ladder AS (
  SELECT p.version, f.league, f.matchup,
    sum(f.wins) AS wins, sum(f.games) AS games
  FROM patch_releases p
  JOIN frames_ts f
    ON f.region = p.region
   AND f.frame_start >= p.release_ts AND f.frame_end <= timestampadd(DAY, 28, p.release_ts)
  GROUP BY ALL
)
SELECT
  pro.version,
  concat(pro.race, 'v', pro.versus_race)     AS matchup,
  pro.wins / nullif(pro.games, 0)            AS pro_winrate,
  pro.games                                  AS pro_games,
  max(IF(l.league = 'GRANDMASTER', l.wins / nullif(l.games, 0), NULL)) AS gm_winrate,
  max(IF(l.league = 'MASTER', l.wins / nullif(l.games, 0), NULL))      AS masters_winrate,
  max(IF(l.league = 'DIAMOND', l.wins / nullif(l.games, 0), NULL))     AS diamond_winrate,
  pro.wins / nullif(pro.games, 0)
    - max(IF(l.league = 'DIAMOND', l.wins / nullif(l.games, 0), NULL)) AS pro_diamond_gap
FROM pro
JOIN ladder l ON l.version = pro.version AND l.matchup = concat(pro.race, 'v', pro.versus_race)
GROUP BY pro.version, pro.race, pro.versus_race, pro.wins, pro.games;
