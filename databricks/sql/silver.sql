CREATE SCHEMA IF NOT EXISTS sc2.silver;

CREATE OR REPLACE TEMPORARY FUNCTION league_name(t INT) RETURNS STRING
RETURN element_at(array('BRONZE','SILVER','GOLD','PLATINUM','DIAMOND','MASTER','GRANDMASTER'), t + 1);

CREATE OR REPLACE TEMPORARY FUNCTION race_name(r STRING) RETURNS STRING
RETURN CASE r WHEN '1' THEN 'TERRAN' WHEN '2' THEN 'PROTOSS' WHEN '3' THEN 'ZERG' WHEN '4' THEN 'RANDOM' END;

CREATE OR REPLACE TABLE sc2.silver.dim_season AS
SELECT DISTINCT
  s.value:battlenetId::INT  AS season_bnet_id,
  s.value:region::STRING    AS region,
  s.value:id::INT           AS pulse_season_id,
  s.value:number::INT       AS season_number,
  s.value:year::INT         AS season_year,
  s.value:start::TIMESTAMP  AS start_ts,
  s.value:`end`::TIMESTAMP  AS end_ts
FROM sc2.bronze.pulse_seasons b, LATERAL variant_explode(b.doc:payload) s
QUALIFY ROW_NUMBER() OVER (PARTITION BY season_bnet_id, region ORDER BY b.doc:ingest_ts::TIMESTAMP DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.dim_patch AS
SELECT
  p.value:patch:id::BIGINT              AS patch_id,
  p.value:patch:build::BIGINT           AS build,
  p.value:patch:version::STRING         AS version,
  p.value:patch:versus::BOOLEAN         AS is_versus,
  p.value:releases:US::TIMESTAMP        AS release_us,
  p.value:releases:EU::TIMESTAMP        AS release_eu,
  p.value:releases:KR::TIMESTAMP        AS release_kr
FROM sc2.bronze.pulse_patches b, LATERAL variant_explode(b.doc:payload) p
QUALIFY ROW_NUMBER() OVER (PARTITION BY patch_id ORDER BY b.doc:ingest_ts::TIMESTAMP DESC) = 1;

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
  SELECT r._file, f.value:mapStatsFilmId::STRING AS film_id,
         f.value:number::INT AS frame_number, f.value:wins::BIGINT AS wins, f.value:games::BIGINT AS games
  FROM reports r, LATERAL variant_explode(r.p:frames) f
),
films AS (
  SELECT r._file, f.key AS film_id, f.value:mapId::STRING AS map_id,
         f.value:mapStatsFilmSpecId::STRING AS spec_id
  FROM reports r, LATERAL variant_explode(r.p:films) f
),
specs AS (
  SELECT r._file, s.key AS spec_id,
         race_name(s.value:race::STRING) AS race,
         race_name(s.value:versusRace::STRING) AS versus_race,
         s.value:frameDuration::STRING AS frame_duration
  FROM reports r, LATERAL variant_explode(r.p:specs) s
),
maps AS (
  SELECT r._file, m.key AS map_id, m.value:name::STRING AS map_name
  FROM reports r, LATERAL variant_explode(r.p:maps) m
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
    doc:ingest_ts::TIMESTAMP::DATE          AS snapshot_date,
    doc:ingest_ts::TIMESTAMP                AS ingest_ts,
    doc:request_params:season::INT          AS season_bnet_id,
    t.value                                 AS team
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
  any_value(region)                                       AS region,
  max_by(character_name, snapshot_date)                   AS name,
  max_by(pro_id, snapshot_date)                           AS pro_id,
  max_by(pro_nickname, snapshot_date)                     AS pro_nickname,
  min(snapshot_date)                                      AS first_seen,
  max(snapshot_date)                                      AS last_seen
FROM sc2.silver.fct_ladder_team_snapshot
GROUP BY character_id;

CREATE OR REPLACE TABLE sc2.silver.fct_activity_snapshot AS
WITH snap AS (
  SELECT doc:ingest_ts::TIMESTAMP AS snapshot_ts, doc:payload AS p
  FROM sc2.bronze.pulse_activity
),
per_season AS (
  SELECT snapshot_ts, s.key::INT AS season_bnet_id, s.value AS stats
  FROM snap, LATERAL variant_explode(snap.p) s
),
unpivoted AS (
  SELECT snapshot_ts, season_bnet_id, 'region' AS dimension, e.key AS dimension_value,
         NULL::BIGINT AS team_count, e.value::BIGINT AS games_played
  FROM per_season, LATERAL variant_explode(stats:regionGamesPlayed) e
  UNION ALL
  SELECT snapshot_ts, season_bnet_id, 'league', e.key, NULL, e.value::BIGINT
  FROM per_season, LATERAL variant_explode(stats:leagueGamesPlayed) e
  UNION ALL
  SELECT snapshot_ts, season_bnet_id, 'race', e.key, NULL, e.value::BIGINT
  FROM per_season, LATERAL variant_explode(stats:raceGamesPlayed) e
  UNION ALL
  SELECT snapshot_ts, season_bnet_id, 'race_teams', e.key, e.value::BIGINT, NULL
  FROM per_season, LATERAL variant_explode(stats:raceTeamCount) e
)
SELECT * FROM unpivoted
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY date_trunc('hour', snapshot_ts), season_bnet_id, dimension, dimension_value
  ORDER BY snapshot_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_tier_threshold_snapshot AS
WITH snap AS (
  SELECT doc:ingest_ts::TIMESTAMP AS snapshot_ts,
         doc:request_params:season::INT AS season_bnet_id,
         doc:payload AS p
  FROM sc2.bronze.pulse_tier_thresholds
)
SELECT
  snapshot_ts, season_bnet_id,
  region.key                AS region,
  league.key                AS league,
  tier.key                  AS tier,
  tier.value[0]::INT        AS mmr_min,
  tier.value[1]::INT        AS mmr_max
FROM snap,
  LATERAL variant_explode(snap.p) region,
  LATERAL variant_explode(region.value) league,
  LATERAL variant_explode(league.value) tier
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY date_trunc('hour', snapshot_ts), season_bnet_id, region.key, league.key, tier.key
  ORDER BY snapshot_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_player_base AS
SELECT
  doc:ingest_ts::TIMESTAMP::DATE   AS snapshot_date,
  q.value:season::INT              AS season_bnet_id,
  q.value:playerBase::BIGINT       AS player_base,
  q.value:playerCount::BIGINT      AS player_count,
  q.value:lowActivityPlayerCount::BIGINT    AS low_activity_cnt,
  q.value:mediumActivityPlayerCount::BIGINT AS medium_activity_cnt,
  q.value:highActivityPlayerCount::BIGINT   AS high_activity_cnt
FROM sc2.bronze.pulse_player_base b, LATERAL variant_explode(b.doc:payload) q
QUALIFY ROW_NUMBER() OVER (PARTITION BY snapshot_date, season_bnet_id ORDER BY doc:ingest_ts::TIMESTAMP DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_league_composition AS
WITH leagues AS (
  SELECT
    doc:ingest_ts::TIMESTAMP::DATE       AS snapshot_date,
    doc:ingest_ts::TIMESTAMP             AS ingest_ts,
    doc:request_params:region::STRING    AS region,
    doc:request_params:seasonId::INT     AS season_id,
    doc:request_params:leagueId::INT     AS league_id,
    doc:payload                          AS p
  FROM sc2.bronze.blizzard_league
)
SELECT
  snapshot_date, region, season_id, league_id,
  t.value:id::INT                        AS tier,
  t.value:min_rating::INT                AS mmr_min,
  t.value:max_rating::INT                AS mmr_max,
  size(t.value:division)                 AS division_count,
  aggregate(
    from_json(to_json(t.value:division), 'ARRAY<STRUCT<member_count INT>>'),
    0, (acc, d) -> acc + coalesce(d.member_count, 0)
  )                                      AS player_count
FROM leagues, LATERAL variant_explode(p:tier) t
QUALIFY ROW_NUMBER() OVER (PARTITION BY snapshot_date, region, season_id, league_id, tier ORDER BY ingest_ts DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.fct_pro_match AS
WITH matches AS (
  SELECT m.value AS m, doc:ingest_ts::TIMESTAMP AS ingest_ts
  FROM sc2.bronze.aligulac_matches b, LATERAL variant_explode(b.doc:payload) m
),
deduped AS (
  SELECT * FROM matches
  QUALIFY ROW_NUMBER() OVER (PARTITION BY m:id::BIGINT ORDER BY ingest_ts DESC) = 1
),
sides AS (
  SELECT m:id::BIGINT match_id, m:date::DATE match_date, m:period::STRING period_uri,
         m:pla:id::BIGINT player_id, m:plb:id::BIGINT opponent_id,
         upper(m:rca::STRING) race, upper(m:rcb::STRING) versus_race,
         m:sca::INT score, m:scb::INT opponent_score, m:offline::BOOLEAN offline
  FROM deduped
  UNION ALL
  SELECT m:id::BIGINT, m:date::DATE, m:period::STRING,
         m:plb:id::BIGINT, m:pla:id::BIGINT,
         upper(m:rcb::STRING), upper(m:rca::STRING),
         m:scb::INT, m:sca::INT, m:offline::BOOLEAN
  FROM deduped
)
SELECT *, CAST(regexp_extract(period_uri, '(\\d+)/?$', 1) AS INT) AS period_id, score > opponent_score AS is_win
FROM sides
WHERE race IN ('T', 'P', 'Z') AND versus_race IN ('T', 'P', 'Z');

CREATE OR REPLACE TABLE sc2.silver.fct_pro_rating AS
SELECT
  doc:request_params:period::INT     AS period_id,
  r.value:player:id::BIGINT          AS player_id,
  r.value:player:tag::STRING         AS player_tag,
  upper(r.value:player:race::STRING) AS race,
  r.value:rating::DOUBLE             AS rating,
  r.value:rating_vt::DOUBLE          AS rating_vt,
  r.value:rating_vz::DOUBLE          AS rating_vz,
  r.value:rating_vp::DOUBLE          AS rating_vp,
  r.value:decay::INT                 AS decay
FROM sc2.bronze.aligulac_ratings b, LATERAL variant_explode(b.doc:payload) r
QUALIFY ROW_NUMBER() OVER (PARTITION BY period_id, player_id ORDER BY doc:ingest_ts::TIMESTAMP DESC) = 1;

CREATE OR REPLACE TABLE sc2.silver.dim_pro_player AS
SELECT
  c.pro_id,
  c.pro_nickname                       AS nickname,
  any_value(c.character_id)            AS sample_character_id,
  max_by(r.player_id, r.period_id)     AS aligulac_id
FROM sc2.silver.dim_character c
LEFT JOIN sc2.silver.fct_pro_rating r ON lower(r.player_tag) = lower(c.pro_nickname)
WHERE c.pro_id IS NOT NULL
GROUP BY c.pro_id, c.pro_nickname;
