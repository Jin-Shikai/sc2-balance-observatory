CREATE SCHEMA IF NOT EXISTS sc2.silver;

CREATE OR REPLACE TEMPORARY FUNCTION league_name(t INT) RETURNS STRING
RETURN element_at(array('BRONZE','SILVER','GOLD','PLATINUM','DIAMOND','MASTER','GRANDMASTER'), t + 1);

CREATE OR REPLACE TEMPORARY FUNCTION race_name(r STRING) RETURNS STRING
RETURN CASE
  WHEN upper(r) IN ('TERRAN', 'PROTOSS', 'ZERG', 'RANDOM') THEN upper(r)
  ELSE element_at(map('1', 'TERRAN', '2', 'PROTOSS', '3', 'ZERG', '4', 'RANDOM'), r)
END;

CREATE OR REPLACE TABLE sc2.silver.dim_season AS
WITH e AS (
  SELECT s.value AS v, b.doc:ingest_ts::TIMESTAMP AS ingest_ts
  FROM sc2.bronze.pulse_seasons b, LATERAL variant_explode(b.doc:payload) s
)
SELECT
  v:battlenetId::INT  AS season_bnet_id,
  v:region::STRING    AS region,
  v:id::INT           AS pulse_season_id,
  v:number::INT       AS season_number,
  v:year::INT         AS season_year,
  v:start::TIMESTAMP  AS start_ts,
  v:`end`::TIMESTAMP  AS end_ts
FROM e
QUALIFY ROW_NUMBER() OVER (PARTITION BY season_bnet_id, region ORDER BY ingest_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.dim_patch AS
WITH e AS (
  SELECT p.value AS v, b.doc:ingest_ts::TIMESTAMP AS ingest_ts
  FROM sc2.bronze.pulse_patches b, LATERAL variant_explode(b.doc:payload) p
)
SELECT
  v:patch:id::BIGINT       AS patch_id,
  v:patch:build::BIGINT    AS build,
  v:patch:version::STRING  AS version,
  v:patch:versus::BOOLEAN  AS is_versus,
  v:releases:US::TIMESTAMP AS release_us,
  v:releases:EU::TIMESTAMP AS release_eu,
  v:releases:KR::TIMESTAMP AS release_kr
FROM e
QUALIFY ROW_NUMBER() OVER (PARTITION BY patch_id ORDER BY ingest_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_balance_frame AS
WITH reports AS (
  SELECT
    _file,
    doc:request_params:season::INT    AS season_bnet_id,
    doc:request_params:region::STRING AS region,
    doc:request_params:league::STRING AS league,
    doc:request_params:tier::STRING   AS tier,
    doc:payload                       AS p,
    doc:ingest_ts::TIMESTAMP          AS ingest_ts
  FROM sc2.bronze.pulse_balance_reports
),
frames AS (
  SELECT _file, v:mapStatsFilmId::STRING AS film_id,
         v:number::INT AS frame_number, v:wins::BIGINT AS wins, v:games::BIGINT AS games
  FROM (SELECT r._file, f.value AS v FROM reports r, LATERAL variant_explode(r.p:frames) f)
),
films AS (
  SELECT _file, k AS film_id, v:mapId::STRING AS map_id, v:mapStatsFilmSpecId::STRING AS spec_id
  FROM (SELECT r._file, f.key AS k, f.value AS v FROM reports r, LATERAL variant_explode(r.p:films) f)
),
specs AS (
  SELECT _file, k AS spec_id,
         race_name(v:race::STRING) AS race,
         race_name(v:versusRace::STRING) AS versus_race,
         v:frameDuration::STRING AS frame_duration
  FROM (SELECT r._file, s.key AS k, s.value AS v FROM reports r, LATERAL variant_explode(r.p:specs) s)
),
maps AS (
  SELECT _file, k AS map_id, v:name::STRING AS map_name
  FROM (SELECT r._file, m.key AS k, m.value AS v FROM reports r, LATERAL variant_explode(r.p:maps) m)
)
SELECT
  r.season_bnet_id, r.region, r.league, r.tier,
  fi.map_id::INT AS map_id, m.map_name,
  s.race, s.versus_race, s.frame_duration,
  f.frame_number, f.wins, f.games
FROM frames f
JOIN reports r USING (_file)
JOIN films fi ON fi._file = f._file AND fi.film_id = f.film_id
JOIN specs s ON s._file = f._file AND s.spec_id = fi.spec_id
LEFT JOIN maps m ON m._file = f._file AND m.map_id = fi.map_id
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY r.season_bnet_id, r.region, r.league, r.tier, fi.map_id, s.race, s.versus_race, f.frame_number
  ORDER BY r.ingest_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_ladder_team_snapshot AS
WITH snap AS (
  SELECT
    b.doc:ingest_ts::TIMESTAMP::DATE AS snapshot_date,
    b.doc:ingest_ts::TIMESTAMP       AS ingest_ts,
    b.doc:request_params:season::INT AS season_bnet_id,
    t.value                          AS team
  FROM sc2.bronze.pulse_teams b, LATERAL variant_explode(b.doc:payload) t
),
teams AS (
  SELECT
    snapshot_date, ingest_ts, season_bnet_id,
    team:id::BIGINT                          AS team_id,
    team:legacyUid::STRING                   AS legacy_uid,
    team:region::STRING                      AS region,
    league_name(team:leagueType::INT)        AS league,
    team:tierType::INT                       AS tier,
    team:divisionId::BIGINT                  AS division_id,
    team:rating::INT                         AS rating,
    team:wins::INT                           AS wins,
    team:losses::INT                         AS losses,
    team:members[0]:character:id::BIGINT     AS character_id,
    team:members[0]:character:name::STRING   AS character_name,
    team:members[0]:proId::BIGINT            AS pro_id,
    team:members[0]:proNickname::STRING      AS pro_nickname,
    race_name(regexp_extract(team:legacyUid::STRING, '\\.([1-4])$', 1)) AS race,
    team:lastPlayed::TIMESTAMP               AS last_played,
    team:globalRank::INT                     AS global_rank,
    team:regionRank::INT                     AS region_rank
  FROM snap
  QUALIFY ROW_NUMBER() OVER (PARTITION BY team:id::BIGINT, snapshot_date ORDER BY ingest_ts DESC) = 1
)
SELECT
  *,
  CASE
    WHEN (wins + losses) - LAG(wins + losses) OVER w < 0 THEN wins + losses
    ELSE COALESCE((wins + losses) - LAG(wins + losses) OVER w, wins + losses)
  END AS games_delta
FROM teams
WINDOW w AS (PARTITION BY team_id ORDER BY snapshot_date);

CREATE OR REPLACE TABLE sc2.silver.dim_character AS
SELECT
  character_id,
  any_value(region)                     AS region,
  max_by(character_name, snapshot_date) AS name,
  max_by(pro_id, snapshot_date)         AS pro_id,
  max_by(pro_nickname, snapshot_date)   AS pro_nickname,
  min(snapshot_date)                    AS first_seen,
  max(snapshot_date)                    AS last_seen
FROM sc2.silver.fct_ladder_team_snapshot
GROUP BY character_id;

CREATE OR REPLACE TABLE sc2.silver.fct_activity_snapshot AS
WITH per_season AS (
  SELECT snapshot_ts, k::INT AS season_bnet_id, stats
  FROM (
    SELECT b.doc:ingest_ts::TIMESTAMP AS snapshot_ts, s.key AS k, s.value AS stats
    FROM sc2.bronze.pulse_activity b, LATERAL variant_explode(b.doc:payload) s
  )
),
unpivoted AS (
  SELECT snapshot_ts, season_bnet_id, 'region' AS dimension, k AS dimension_value,
         NULL::BIGINT AS team_count, v::BIGINT AS games_played
  FROM (SELECT p.*, e.key AS k, e.value AS v FROM per_season p, LATERAL variant_explode(p.stats:regionGamesPlayed) e)
  UNION ALL
  SELECT snapshot_ts, season_bnet_id, 'league', k, NULL, v::BIGINT
  FROM (SELECT p.*, e.key AS k, e.value AS v FROM per_season p, LATERAL variant_explode(p.stats:leagueGamesPlayed) e)
  UNION ALL
  SELECT snapshot_ts, season_bnet_id, 'race', k, NULL, v::BIGINT
  FROM (SELECT p.*, e.key AS k, e.value AS v FROM per_season p, LATERAL variant_explode(p.stats:raceGamesPlayed) e)
  UNION ALL
  SELECT snapshot_ts, season_bnet_id, 'race_teams', k, v::BIGINT, NULL
  FROM (SELECT p.*, e.key AS k, e.value AS v FROM per_season p, LATERAL variant_explode(p.stats:raceTeamCount) e)
)
SELECT * FROM unpivoted
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY date_trunc('hour', snapshot_ts), season_bnet_id, dimension, dimension_value
  ORDER BY snapshot_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_tier_threshold_snapshot AS
WITH snap AS (
  SELECT b.doc:ingest_ts::TIMESTAMP AS snapshot_ts,
         b.doc:request_params:season::INT AS season_bnet_id,
         b.doc:payload AS p
  FROM sc2.bronze.pulse_tier_thresholds b
),
r1 AS (
  SELECT s.snapshot_ts, s.season_bnet_id, region.key AS region, region.value AS rv
  FROM snap s, LATERAL variant_explode(s.p) region
),
r2 AS (
  SELECT r1.snapshot_ts, r1.season_bnet_id, r1.region, league.key AS league, league.value AS lv
  FROM r1, LATERAL variant_explode(r1.rv) league
),
r3 AS (
  SELECT r2.snapshot_ts, r2.season_bnet_id, r2.region, r2.league, tier.key AS tier, tier.value AS tv
  FROM r2, LATERAL variant_explode(r2.lv) tier
)
SELECT
  snapshot_ts, season_bnet_id, region, league, tier,
  variant_get(tv, '$[0]', 'INT') AS mmr_min,
  variant_get(tv, '$[1]', 'INT') AS mmr_max
FROM r3
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY date_trunc('hour', snapshot_ts), season_bnet_id, region, league, tier
  ORDER BY snapshot_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_player_base AS
WITH e AS (
  SELECT q.value AS v, b.doc:ingest_ts::TIMESTAMP AS ingest_ts
  FROM sc2.bronze.pulse_player_base b, LATERAL variant_explode(b.doc:payload) q
)
SELECT
  ingest_ts::DATE                           AS snapshot_date,
  v:season::INT                             AS season_bnet_id,
  v:playerBase::BIGINT                      AS player_base,
  v:playerCount::BIGINT                     AS player_count,
  v:lowActivityPlayerCount::BIGINT          AS low_activity_cnt,
  v:mediumActivityPlayerCount::BIGINT       AS medium_activity_cnt,
  v:highActivityPlayerCount::BIGINT         AS high_activity_cnt
FROM e
QUALIFY ROW_NUMBER() OVER (PARTITION BY ingest_ts::DATE, v:season::INT ORDER BY ingest_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_league_composition AS
WITH tiers AS (
  SELECT
    b.doc:ingest_ts::TIMESTAMP::DATE    AS snapshot_date,
    b.doc:ingest_ts::TIMESTAMP          AS ingest_ts,
    b.doc:request_params:region::STRING AS region,
    b.doc:request_params:seasonId::INT  AS season_id,
    b.doc:request_params:leagueId::INT  AS league_id,
    t.value                             AS tv
  FROM sc2.bronze.blizzard_league b, LATERAL variant_explode(b.doc:payload:tier) t
),
parsed AS (
  SELECT
    snapshot_date, ingest_ts, region, season_id, league_id,
    tv:id::INT         AS tier,
    tv:min_rating::INT AS mmr_min,
    tv:max_rating::INT AS mmr_max,
    from_json(to_json(tv:division), 'ARRAY<STRUCT<member_count INT>>') AS divisions
  FROM tiers
)
SELECT
  snapshot_date, region, season_id, league_id, tier, mmr_min, mmr_max,
  size(divisions) AS division_count,
  aggregate(divisions, 0, (acc, d) -> acc + coalesce(d.member_count, 0)) AS player_count
FROM parsed
QUALIFY ROW_NUMBER() OVER (PARTITION BY snapshot_date, region, season_id, league_id, tier ORDER BY ingest_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_pro_match AS
WITH matches AS (
  SELECT x.m, x.ingest_ts
  FROM (
    SELECT mm.value AS m, b.doc:ingest_ts::TIMESTAMP AS ingest_ts
    FROM sc2.bronze.aligulac_matches b, LATERAL variant_explode(b.doc:payload) mm
  ) x
  QUALIFY ROW_NUMBER() OVER (PARTITION BY x.m:id::BIGINT ORDER BY x.ingest_ts DESC) = 1
),
sides AS (
  SELECT m:id::BIGINT match_id, m:date::DATE match_date, m:period::STRING period_uri,
         m:pla:id::BIGINT player_id, m:plb:id::BIGINT opponent_id,
         upper(m:rca::STRING) race, upper(m:rcb::STRING) versus_race,
         m:sca::INT score, m:scb::INT opponent_score, m:offline::BOOLEAN offline
  FROM matches
  UNION ALL
  SELECT m:id::BIGINT, m:date::DATE, m:period::STRING,
         m:plb:id::BIGINT, m:pla:id::BIGINT,
         upper(m:rcb::STRING), upper(m:rca::STRING),
         m:scb::INT, m:sca::INT, m:offline::BOOLEAN
  FROM matches
)
SELECT *, CAST(regexp_extract(period_uri, '(\\d+)/?$', 1) AS INT) AS period_id, score > opponent_score AS is_win
FROM sides
WHERE race IN ('T', 'P', 'Z') AND versus_race IN ('T', 'P', 'Z');

CREATE OR REPLACE TABLE sc2.silver.fct_pro_rating AS
WITH e AS (
  SELECT r.value AS v,
         b.doc:request_params:period::INT AS period_id,
         b.doc:ingest_ts::TIMESTAMP AS ingest_ts
  FROM sc2.bronze.aligulac_ratings b, LATERAL variant_explode(b.doc:payload) r
)
SELECT
  period_id,
  v:player:id::BIGINT          AS player_id,
  v:player:tag::STRING         AS player_tag,
  upper(v:player:race::STRING) AS race,
  v:rating::DOUBLE             AS rating,
  v:rating_vt::DOUBLE          AS rating_vt,
  v:rating_vz::DOUBLE          AS rating_vz,
  v:rating_vp::DOUBLE          AS rating_vp,
  v:decay::INT                 AS decay
FROM e
QUALIFY ROW_NUMBER() OVER (PARTITION BY period_id, v:player:id::BIGINT ORDER BY ingest_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.dim_pro_player AS
SELECT
  c.pro_id,
  c.pro_nickname                   AS nickname,
  any_value(c.character_id)        AS sample_character_id,
  max_by(r.player_id, r.period_id) AS aligulac_id
FROM sc2.silver.dim_character c
LEFT JOIN sc2.silver.fct_pro_rating r ON lower(r.player_tag) = lower(c.pro_nickname)
WHERE c.pro_id IS NOT NULL
GROUP BY c.pro_id, c.pro_nickname;
