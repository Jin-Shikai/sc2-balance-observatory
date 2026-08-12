-- balance-reports frames are "winrate by match duration minute" buckets per season
-- (frame_number = match duration / 1min, null = unknown duration), NOT a calendar series.
-- Calendar-granular analysis therefore uses: seasons (ladder) and match dates (pro).

CREATE SCHEMA IF NOT EXISTS sc2.gold;

CREATE OR REPLACE TEMPORARY FUNCTION wilson_low(wins BIGINT, games BIGINT) RETURNS DOUBLE
RETURN CASE WHEN games > 0 THEN
  (wins / games + 1.92 / games - 1.96 * sqrt((wins / games) * (1 - wins / games) / games + 0.96 / (games * games)))
  / (1 + 3.84 / games) END;

CREATE OR REPLACE TEMPORARY FUNCTION wilson_high(wins BIGINT, games BIGINT) RETURNS DOUBLE
RETURN CASE WHEN games > 0 THEN
  (wins / games + 1.92 / games + 1.96 * sqrt((wins / games) * (1 - wins / games) / games + 0.96 / (games * games)))
  / (1 + 3.84 / games) END;

CREATE OR REPLACE TEMPORARY VIEW frames AS
SELECT *, concat(left(race, 1), 'v', left(versus_race, 1)) AS matchup
FROM sc2.silver.fct_balance_frame
WHERE race <> versus_race;

CREATE OR REPLACE TEMPORARY VIEW patch_releases AS
SELECT patch_id, version, r.region, r.release_ts
FROM sc2.silver.dim_patch
LATERAL VIEW stack(3, 'US', release_us, 'EU', release_eu, 'KR', release_kr) r AS region, release_ts
WHERE r.release_ts IS NOT NULL AND is_versus;

-- ladder winrate per season (the finest calendar grain the ladder source supports)
CREATE OR REPLACE TABLE sc2.gold.balance_profile AS
SELECT
  season_bnet_id, region, league, matchup,
  sum(wins) AS wins, sum(games) AS games,
  sum(wins) / sum(games)             AS winrate,
  wilson_low(sum(wins), sum(games))  AS ci_low,
  wilson_high(sum(wins), sum(games)) AS ci_high
FROM frames
GROUP BY ALL;

-- unique dataset: winrate by match duration (early/mid/late game balance)
CREATE OR REPLACE TABLE sc2.gold.balance_by_game_length AS
SELECT
  season_bnet_id, region, league, matchup,
  frame_number                       AS game_minute,
  sum(wins) AS wins, sum(games) AS games,
  sum(wins) / sum(games)             AS winrate,
  wilson_low(sum(wins), sum(games))  AS ci_low,
  wilson_high(sum(wins), sum(games)) AS ci_high
FROM frames
WHERE frame_number IS NOT NULL AND frame_number <= 60
GROUP BY ALL;

-- season-over-season winrate shift, annotated with patches released in the season
CREATE OR REPLACE TABLE sc2.gold.balance_season_delta AS
WITH seasons AS (
  SELECT DISTINCT season_bnet_id, region, start_ts, end_ts FROM sc2.silver.dim_season
),
patched AS (
  SELECT s.season_bnet_id, s.region,
    array_join(collect_list(p.version), ', ') AS patches_in_season
  FROM seasons s
  JOIN patch_releases p
    ON p.region = s.region AND p.release_ts >= s.start_ts AND p.release_ts < s.end_ts
  GROUP BY s.season_bnet_id, s.region
)
SELECT
  cur.season_bnet_id, cur.region, cur.league, cur.matchup,
  prev.winrate                       AS winrate_prev,
  prev.games                         AS games_prev,
  cur.winrate                        AS winrate_cur,
  cur.games                          AS games_cur,
  cur.winrate - prev.winrate         AS winrate_delta,
  cur.ci_low > prev.ci_high OR cur.ci_high < prev.ci_low AS delta_significant,
  pt.patches_in_season
FROM sc2.gold.balance_profile cur
JOIN sc2.gold.balance_profile prev
  ON prev.season_bnet_id = cur.season_bnet_id - 1
 AND prev.region = cur.region AND prev.league = cur.league AND prev.matchup = cur.matchup
LEFT JOIN patched pt
  ON pt.season_bnet_id = cur.season_bnet_id AND pt.region = cur.region;

-- calendar-accurate event study on pro matches (Aligulac dates), EU release as global reference
CREATE OR REPLACE TABLE sc2.gold.patch_event_study AS
WITH windows AS (
  SELECT p.version, p.release_ts,
    concat(m.race, 'v', m.versus_race) AS matchup,
    CASE
      WHEN m.match_date <  date(p.release_ts) AND m.match_date >= date(timestampadd(DAY, -28, p.release_ts)) THEN 'pre'
      WHEN m.match_date >= date(p.release_ts) AND m.match_date <  date(timestampadd(DAY, 28, p.release_ts)) THEN 'post'
    END AS phase,
    m.is_win
  FROM patch_releases p
  JOIN sc2.silver.fct_pro_match m
    ON m.match_date BETWEEN date(timestampadd(DAY, -28, p.release_ts))
                        AND date(timestampadd(DAY, 28, p.release_ts))
  WHERE p.region = 'EU' AND m.race <> m.versus_race
),
agg AS (
  SELECT version, release_ts, matchup,
    sum(IF(phase = 'pre' AND is_win, 1, 0))  AS wins_pre,
    sum(IF(phase = 'pre', 1, 0))             AS games_pre,
    sum(IF(phase = 'post' AND is_win, 1, 0)) AS wins_post,
    sum(IF(phase = 'post', 1, 0))            AS games_post
  FROM windows
  WHERE phase IS NOT NULL
  GROUP BY ALL
)
SELECT
  version, release_ts, matchup,
  games_pre,
  wins_pre / nullif(games_pre, 0)   AS winrate_pre,
  wilson_low(wins_pre, games_pre)   AS ci_low_pre,
  wilson_high(wins_pre, games_pre)  AS ci_high_pre,
  games_post,
  wins_post / nullif(games_post, 0) AS winrate_post,
  wilson_low(wins_post, games_post) AS ci_low_post,
  wilson_high(wins_post, games_post) AS ci_high_post,
  wins_post / nullif(games_post, 0) - wins_pre / nullif(games_pre, 0) AS winrate_delta,
  wilson_low(wins_post, games_post) > wilson_high(wins_pre, games_pre)
    OR wilson_high(wins_post, games_post) < wilson_low(wins_pre, games_pre) AS delta_significant
FROM agg
WHERE games_pre > 0 AND games_post > 0;

CREATE OR REPLACE TABLE sc2.gold.map_balance_attribution AS
WITH per_map AS (
  SELECT season_bnet_id, region, league, matchup, map_id, map_name,
    sum(wins) AS wins, sum(games) AS games
  FROM frames
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

-- pro vs ladder winrate per season (season window from EU dates, pro scene is global)
CREATE OR REPLACE TABLE sc2.gold.pro_vs_ladder_gap AS
WITH season_windows AS (
  SELECT season_bnet_id, start_ts, end_ts FROM sc2.silver.dim_season WHERE region = 'EU'
),
pro AS (
  SELECT w.season_bnet_id,
    concat(m.race, 'v', m.versus_race) AS matchup,
    sum(IF(m.is_win, 1, 0)) AS wins, count(*) AS games
  FROM season_windows w
  JOIN sc2.silver.fct_pro_match m
    ON m.match_date >= date(w.start_ts) AND m.match_date < date(w.end_ts)
  WHERE m.race <> m.versus_race
  GROUP BY ALL
)
SELECT
  pro.season_bnet_id, pro.matchup,
  pro.wins / nullif(pro.games, 0) AS pro_winrate,
  pro.games                       AS pro_games,
  max(IF(l.league = 'GRANDMASTER', l.winrate, NULL)) AS gm_winrate,
  max(IF(l.league = 'MASTER', l.winrate, NULL))      AS masters_winrate,
  max(IF(l.league = 'DIAMOND', l.winrate, NULL))     AS diamond_winrate,
  pro.wins / nullif(pro.games, 0)
    - max(IF(l.league = 'DIAMOND', l.winrate, NULL)) AS pro_diamond_gap
FROM pro
JOIN sc2.gold.balance_profile l
  ON l.season_bnet_id = pro.season_bnet_id AND l.matchup = pro.matchup
GROUP BY pro.season_bnet_id, pro.matchup, pro.wins, pro.games;
